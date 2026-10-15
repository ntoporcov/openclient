import Combine
import Foundation

/// Profile-owned stock MCP declarations, not MCP network-connection statuses.
/// Reads public inventory only; never reads plugin configuration or credentials.
@MainActor
final class DSHMCPService: BackendMCPService {
    typealias Call = @MainActor (String, [String: DSHJSON]) async throws -> DSHJSON
    static let stockModule = "@deepseek-ai/dsh-mcp-client"

    @Published private(set) var state = BackendMCPState()
    var statePublisher: AnyPublisher<BackendMCPState, Never> { $state.eraseToAnyPublisher() }
    private let call: Call
    private var generation = UUID()
    private var readRevision = UUID()
    private var refreshTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var refreshAfterMutation = false
    private var eventRefreshRequested = false
    private var stopped = false

    init(call: @escaping Call) { self.call = call }

    func activate() { stopped = false }

    func invalidate(stopping: Bool = false) {
        stopped = stopping
        generation = UUID()
        readRevision = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        mutationTask?.cancel()
        mutationTask = nil
        eventTask?.cancel()
        eventTask = nil
        refreshAfterMutation = false
        eventRefreshRequested = false
        state = .init()
    }

    /// Called by the adapter's existing $events observer; never opens another stream.
    func handleEvent(_ frame: DSHJSON) {
        guard !stopped else { return }
        let ready = frame[dsh: "type"].dshString == "ready"
        let changed = frame[dsh: "type"].dshString == "emit"
            && frame[dsh: "event"].dshString == "plugin-manager/changed"
        guard ready || changed else { return }
        eventRefreshRequested = true
        guard eventTask == nil else { return }
        let generation = generation
        eventTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                guard self.isValid(generation) else { return }
                self.eventRefreshRequested = false
                await self.refresh(clearingError: false)
            } while self.eventRefreshRequested
            guard self.isValid(generation) else { return }
            self.eventTask = nil
        }
    }

    func refresh() async { await refresh(clearingError: true) }

    private func refresh(clearingError: Bool) async {
        guard !stopped else { return }
        // Changes and all windows share a single mutation lane. A trailing read
        // catches events that arrived while the mutation's readback was in flight.
        if mutationTask != nil { refreshAfterMutation = true; return }
        refreshTask?.cancel()
        let generation = generation
        let revision = UUID()
        readRevision = revision
        state.isLoading = true
        if clearingError { state.errorMessage = nil }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.inventory(generation: generation)
                guard self.isValid(generation), self.readRevision == revision else { return }
                self.state.servers = snapshot.servers
                self.state.isCurrent = true
            } catch {
                guard self.isValid(generation), self.readRevision == revision else { return }
                self.state.isCurrent = false
                self.state.errorMessage = String(localized: "MCP inventory could not be refreshed. Try again.")
            }
            guard self.isValid(generation), self.readRevision == revision else { return }
            self.state.isLoading = false
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    func setEnabled(id: String, enabled: Bool) async {
        guard !stopped else { return }
        guard mutationTask == nil else {
            state.errorMessage = String(localized: "Another MCP setting is being updated. Wait for it to finish.")
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        readRevision = UUID()
        let generation = generation
        state.isLoading = true
        state.togglingIDs = [id]
        state.errorMessage = nil
        state.notice = nil
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performChange(id: id, enabled: enabled, generation: generation)
            guard self.isValid(generation) else { return }
            self.state.isLoading = false
            self.state.togglingIDs = []
            self.mutationTask = nil
            if self.refreshAfterMutation {
                self.refreshAfterMutation = false
                await self.refresh(clearingError: false)
            }
        }
        mutationTask = task
        await task.value
    }

    private func performChange(id: String, enabled: Bool, generation: UUID) async {
        let before: InventorySnapshot
        do {
            before = try await inventory(generation: generation)
        } catch {
            guard isValid(generation) else { return }
            state.isCurrent = false
            state.errorMessage = String(localized: "MCP inventory could not be verified. No setting was changed.")
            return
        }
        guard isValid(generation) else { return }
        state.servers = before.servers
        state.isCurrent = true
        // UI IDs are opaque namespaces. Only this fresh, uniquely owned stock
        // declaration can supply the manager's full Loader entry ID.
        guard let entryID = before.targets[id] else {
            state.errorMessage = String(localized: "This MCP declaration is read-only or is no longer available.")
            return
        }
        var outcome: Outcome?
        do {
            let result = try await call("pluginManager/setPluginEnabled", ["id": .string(entryID), "enabled": .bool(enabled)])
            guard isValid(generation) else { return }
            outcome = try Self.outcome(result, target: entryID, enabled: enabled)
        } catch {
            guard isValid(generation) else { return }
            // A timeout can occur after persistence. Never invert the old value.
            state.errorMessage = String(localized: "The MCP change could not be confirmed. Inventory was requested again.")
        }
        guard isValid(generation) else { return }
        switch outcome {
        case .restartRequired:
            state.notice = String(localized: "The MCP setting was saved, but the DSH host must restart to apply it.")
        case .overridden:
            state.notice = String(localized: "The MCP setting is overridden by another configuration layer.")
        case .failed:
            state.errorMessage = String(localized: "DSH could not apply the MCP setting. Review the server configuration.")
        case .cancelled:
            state.notice = String(localized: "The MCP change was cancelled by the server.")
        case .applied, nil: break
        }
        do {
            let after = try await inventory(generation: generation)
            guard isValid(generation) else { return }
            state.servers = after.servers
            state.isCurrent = true
            if outcome == .applied {
                if after.servers.first(where: { $0.id == id })?.enabled == enabled {
                    state.notice = String(localized: "MCP setting applied. Plugin phase is not a network connection status.")
                } else {
                    state.errorMessage = String(localized: "DSH reported the MCP change, but the effective setting does not match. Refresh to verify.")
                }
            }
        } catch {
            guard isValid(generation) else { return }
            state.isCurrent = false
            state.errorMessage = String(localized: "MCP inventory could not be read after the change. The outcome is unknown; refresh before trying again.")
        }
    }

    private func isValid(_ generation: UUID) -> Bool {
        !stopped && self.generation == generation && !Task.isCancelled
    }

    private func inventory(generation: UUID) async throws -> InventorySnapshot {
        guard isValid(generation) else { throw CancellationError() }
        let response = try await call("pluginInventory/list", [:])
        guard isValid(generation) else { throw CancellationError() }
        let inventory: Inventory = try response.dshDecode()
        let manageable: [ManagedEntry]
        if inventory.managementAvailable == true {
            let response = try await call("pluginManager/listPlugins", [:])
            guard isValid(generation) else { throw CancellationError() }
            manageable = try response.dshDecode()
        } else { manageable = [] }
        return Self.snapshot(inventory, manageable: manageable)
    }

    private struct Inventory: Decodable {
        let managementAvailable: Bool?
        let entries: [Entry]
        let agentPresets: [Preset]?
    }
    private struct Entry: Decodable {
        let entryId: String
        let moduleName: String
        let enabled: Bool
        let fiberPhase: String?
    }
    private struct ManagedEntry: Decodable {
        let entryId: String
        let moduleName: String
        let patchId: String?
        let readOnlyReason: String?
    }
    private struct Preset: Decodable {
        let id: String
        let name: String?
        let rows: [PresetRow]
    }
    private struct PresetRow: Decodable {
        let entryId: String?
        let moduleName: String
        let enabled: DSHJSON
        let fiberPhase: String?

        private enum CodingKeys: String, CodingKey { case entryId, moduleName, enabled, fiberPhase }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            entryId = try values.decodeIfPresent(String.self, forKey: .entryId)
            moduleName = try values.decode(String.self, forKey: .moduleName)
            enabled = try values.decode(DSHJSON.self, forKey: .enabled)
            switch enabled {
            case .bool, .string("conditional"): break
            default: throw DecodingError.dataCorruptedError(forKey: .enabled, in: values, debugDescription: "Invalid declaration enablement")
            }
            fiberPhase = try values.decodeIfPresent(String.self, forKey: .fiberPhase)
        }
    }
    private struct InventorySnapshot {
        var servers: [BackendMCPServer] = []
        var targets: [String: String] = [:]
    }

    private static func namespace(_ value: String) -> String { Data(value.utf8).base64EncodedString() }

    private static func snapshot(_ inventory: Inventory, manageable: [ManagedEntry]) -> InventorySnapshot {
        var result = InventorySnapshot()
        let declarations = Dictionary(grouping: inventory.entries, by: \.entryId)
        let managed = Dictionary(grouping: manageable, by: \.entryId)
        var seen: [String: Int] = [:]
        for entry in inventory.entries where entry.moduleName == stockModule {
            let ordinal = seen[entry.entryId, default: 0]
            seen[entry.entryId] = ordinal + 1
            let id = "profile:" + namespace(entry.entryId) + ":\(ordinal)"
            let owner = managed[entry.entryId]
            let restriction: BackendMCPRestriction?
            if inventory.managementAvailable != true { restriction = .managementUnavailable }
            else if owner?.first?.readOnlyReason == "management-required" { restriction = .managementUnavailable }
            else if entry.entryId.isEmpty || declarations[entry.entryId]?.count != 1 || owner?.count != 1
                || owner?.first?.moduleName != stockModule || owner?.first?.readOnlyReason != nil
                || owner?.first?.patchId?.isEmpty != false { restriction = .unaddressable }
            else { restriction = nil }
            let canToggle = restriction == nil
            result.servers.append(.init(id: id, name: entry.entryId.isEmpty ? entry.moduleName : entry.entryId, enabled: entry.enabled,
                phase: entry.fiberPhase.flatMap(BackendMCPPluginPhase.init(rawValue:)), scope: .profile,
                canToggle: canToggle, restriction: restriction))
            if canToggle { result.targets[id] = entry.entryId }
        }
        var presetOccurrences: [String: Int] = [:]
        for preset in inventory.agentPresets ?? [] {
            let ordinal = presetOccurrences[preset.id, default: 0]
            presetOccurrences[preset.id] = ordinal + 1
            for (index, entry) in preset.rows.enumerated() where entry.moduleName == stockModule {
                let enabled: Bool?
                if case .bool(let value) = entry.enabled { enabled = value } else { enabled = nil }
                result.servers.append(.init(id: "preset:" + namespace(preset.id) + ":\(ordinal):\(index)",
                    name: entry.entryId ?? entry.moduleName, enabled: enabled,
                    phase: entry.fiberPhase.flatMap(BackendMCPPluginPhase.init(rawValue:)),
                    scope: .agentPreset(id: preset.id, name: preset.name ?? preset.id), canToggle: false, restriction: .preset))
            }
        }
        return result
    }

    private enum Outcome: String {
        case applied, restartRequired = "restart-required", overridden, failed, cancelled
    }
    private static func outcome(_ result: DSHJSON, target: String, enabled: Bool) throws -> Outcome {
        guard case .bool = result[dsh: "changed"],
              result[dsh: "stage"].dshString == "enable", result[dsh: "target"].dshString == target,
              let raw = result[dsh: "application"].dshString, let outcome = Outcome(rawValue: raw),
              result[dsh: "enabled"] == .null || result[dsh: "enabled"] == .bool(enabled),
              outcome != .applied || (result[dsh: "enabled"] == .bool(enabled) && result[dsh: "error"] == .null)
        else { throw URLError(.cannotParseResponse) }
        return outcome
    }
}
