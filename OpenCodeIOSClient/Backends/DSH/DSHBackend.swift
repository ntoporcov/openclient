import CryptoKit
import Foundation

@MainActor
struct DSHBackendFactory: BackendFactory {
    let configuration: DSHConfiguration

    func connect() async throws -> BackendConnection {
        let adapter = DSHBackendAdapter(configuration: configuration)
        do { try await adapter.bootstrap() }
        catch { adapter.stop(); throw error }
        let namespace = SHA256.hash(data: Data(configuration.baseURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return BackendConnection(descriptor: .init(id: "dsh:" + namespace, name: "DSH", version: "0.2 prototype"),
            capabilities: adapter.supportsSessionPermissions ? [.sessionPermissions, .sessionMetadata, .mcp] : [.sessionMetadata, .mcp],
            projects: adapter, sessions: adapter, chat: adapter, models: adapter, events: adapter,
            projectLifecycle: adapter, sessionActivity: adapter, agentSelectionPolicy: .creationOnly,
            sessionPermissions: adapter.supportsSessionPermissions ? adapter : nil, mcp: adapter.mcpService)
    }
}

struct DSHWorkspace: Decodable, Sendable {
    let workspaceId: String
    let path: String
    let title: String
    let sessionIds: [String]

    var project: OpenCodeProject {
        .init(id: workspaceId, worktree: path, vcs: nil, name: title, sandboxes: nil, icon: nil, time: nil)
    }
}

/// Preset IDs are request identities; display names must never be sent in their place.
struct DSHAgentPresetRoster: Decodable, Sendable {
    struct Preset: Decodable, Sendable {
        let id: String
        let isDefault: Bool
        let name: String?
        let description: String?
        let broken: String?

        var agent: OpenCodeAgent {
            .init(name: id, description: description, mode: "primary", hidden: broken != nil,
                  model: nil, variant: nil, displayName: name)
        }
    }
    let presets: [Preset]
    var agents: [OpenCodeAgent] { presets.map(\.agent) }
}

struct DSHSessionPermissionCatalog: Decodable, Sendable {
    struct Option: Decodable, Sendable { let value: String }
    let options: [Option]

    var supportsToggle: Bool {
        supports(.workspaceWrite) && supports(.fullAccess)
    }

    func supports(_ preset: BackendSessionPermissionPreset) -> Bool {
        options.contains { $0.value == preset.rawValue }
    }
}

/// Canonical sequenced state, kept separate from potentially stale session-list hints.
struct DSHSessionPermissionProjection: Equatable, Sendable {
    let sequence: Int
    let state: BackendSessionPermissionState

    init(baseline: DSHJSON) throws {
        guard let sequence = baseline[dsh: "asOfSeq"].intValue,
              baseline[dsh: "values"].objectValue != nil else { throw URLError(.cannotParseResponse) }
        self.sequence = sequence
        self.state = .init(currentPreset: baseline[dsh: "values"][dsh: "permissions"][dsh: "currentValue"].dshString)
    }

    init(sequence: Int, value: DSHJSON) {
        self.sequence = sequence
        self.state = .init(currentPreset: value[dsh: "currentValue"].dshString)
    }

    func accepting(_ incoming: Self) -> Self {
        incoming.sequence >= sequence ? incoming : self
    }
}

@MainActor
struct DSHSessionPermissionWorkflow {
    enum Failure: LocalizedError {
        case unconfirmed
        case updateInProgress
        var errorDescription: String? {
            switch self {
            case .unconfirmed: return String(localized: "Session permissions could not be confirmed. Refresh before trying again.")
            case .updateInProgress: return String(localized: "Session permissions are already being updated.")
            }
        }
    }

    /// Callers validate the catalog before applying. This never sends a model prompt.
    static func apply(sessionID: String, preset: BackendSessionPermissionPreset,
                      call: (String, [String: DSHJSON]) async throws -> DSHJSON) async throws -> DSHJSON {
        try Task.checkCancellation()
        let execution = try await call("commands/execute", [
            "agentId": .string(sessionID), "line": .string("/permission " + preset.rawValue),
            "submittedAttachments": .array([])
        ])
        guard execution[dsh: "result"][dsh: "kind"].dshString == "success" else { throw Failure.unconfirmed }
        let projection = try await call("session/projections", ["request": .object(["sessionId": .string(sessionID)])])
        guard projection[dsh: "values"][dsh: "permissions"][dsh: "currentValue"].dshString == preset.rawValue else {
            throw Failure.unconfirmed
        }
        return projection
    }
}

/// Creates a blank session and confirms explicit permissions before exposing it to
/// the initial-prompt workflow. No prompt RPC or future-session settings write belongs here.
@MainActor
struct DSHSessionCreationWorkflow {
    enum Failure: LocalizedError {
        case permissionsUnavailable
        case permissionsUnconfirmed(sessionID: String)

        var errorDescription: String? {
            switch self {
            case .permissionsUnavailable:
                return String(localized: "The server does not offer the requested session permissions.")
            case let .permissionsUnconfirmed(sessionID):
                return String(localized: "Session \(sessionID) was created, but its permissions could not be confirmed. No prompt was sent.")
            }
        }
    }

    static func create(
        workspaceID: String,
        agent: String?,
        permissionPreset: BackendSessionPermissionPreset?,
        call: (String, [String: DSHJSON]) async throws -> DSHJSON
    ) async throws -> String {
        if let permissionPreset {
            let catalog: DSHSessionPermissionCatalog = try await call("permissionPresets/catalog", [:]).dshDecode()
            guard catalog.supports(permissionPreset) else { throw Failure.permissionsUnavailable }
        }
        try Task.checkCancellation()
        var body: [String: DSHJSON] = ["workspaceId": .string(workspaceID)]
        if let agent { body["agentPreset"] = .string(agent) }
        let created = try await call("session/create", ["request": .object(body)])
        guard let id = created[dsh: "sessionId"].dshString else { throw URLError(.cannotParseResponse) }
        if let permissionPreset {
            do {
                _ = try await DSHSessionPermissionWorkflow.apply(sessionID: id, preset: permissionPreset, call: call)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.permissionsUnconfirmed(sessionID: id)
            }
        }
        return id
    }
}

struct DSHSessionSummary: Decodable, Sendable {
    let sessionId: String
    let updatedAt: Double
    var running: Bool
    let cwd: String?
    let parentSessionId: String?
    let origin: String?
    var projections: DSHJSON?

    var agentPreset: String? { projections?[dsh: "values"][dsh: "agentPreset"].dshString }

    mutating func applyProjectionEvent(_ event: DSHJSON) {
        let key: String
        let value: DSHJSON
        switch event[dsh: "type"].dshString {
        case "session/title":
            key = "title"
            value = event[dsh: "data"][dsh: "title"]
        case "agent-preset/selected":
            key = "agentPreset"
            value = event[dsh: "data"][dsh: "agentPreset"]
        default: return
        }
        var values = projections?[dsh: "values"].objectValue ?? [:]
        values[key] = value
        var projection = projections?.objectValue ?? [:]
        projection["values"] = .object(values)
        projections = .object(projection)
    }
}

/// Adapts DSH wire snapshots into the existing store/reducer-facing contracts.
/// One transport owns all global, workspace, and retained-session logical streams.
@MainActor
final class DSHBackendAdapter: BackendProjectsService, BackendSessionsService, BackendChatService,
    BackendModelsService, BackendEventSource, BackendSessionActivityService, BackendProjectLifecycleService,
    BackendSessionPermissionsService {
    private let configuration: DSHConfiguration
    private var transport: DSHTransport
    lazy var mcpService = DSHMCPService { [weak self] endpoint, arguments in
        guard let self, !self.stopped else { throw BackendError.disconnected }
        return try await self.transport.call(endpoint, args: arguments)
    }
    private var workspaceState = DSHWorkspaceState()
    private var workspaces: [DSHWorkspace] { workspaceState.workspaces }
    private var archived: Set<String> { workspaceState.archived }
    private var summaries: [String: DSHSessionSummary] = [:]
    private var statusRevisions: [String: UInt] = [:]
    private var transcripts: [String: DSHTranscript] = [:]
    private var followTasks: [String: Task<Void, Never>] = [:]
    private var openings: [String: Task<Void, Error>] = [:]
    private var globalTasks: [Task<Void, Never>] = []
    private var receive: (@MainActor (BackendEvent) -> Void)?
    private var lifetime = UUID()
    private var stopped = false
    private var eventClientID: String?
    private(set) var supportsSessionPermissions = false
    private var projectionStates: [String: DSHSessionProjectionState] = [:]
    private var awaitingControlBaseline = true
    private var permissionGeneration = UUID()
    private var permissionUpdates: Set<String> = []
    private var permissionReadRevisions: [String: UInt] = [:]

    init(configuration: DSHConfiguration) {
        self.configuration = configuration
        transport = DSHTransport(configuration: configuration)
    }

    func bootstrap() async throws {
        let lifetime = lifetime
        mcpService.activate()
        transport.onReconnect = { [weak self] in
            self?.mcpService.invalidate()
            self?.invalidateProjectionState()
            self?.receive?(.status("reconnecting"))
        }
        try await transport.connect()
        // Match DSH: install the event observer before reading baselines.
        let eventStream = try await transport.open("$events")
        var events = eventStream.makeAsyncIterator()
        guard let ready = try await events.next(), ready[dsh: "type"].dshString == "ready" else {
            throw URLError(.cannotParseResponse)
        }
        eventClientID = ready[dsh: "clientId"].dshString
        mcpService.handleEvent(ready)
        globalTasks.append(Task { [weak self] in
            do {
                for try await value in eventStream {
                    guard let self, self.lifetime == lifetime else { return }
                    try await self.globalEvent(value)
                }
            } catch { self?.report(error) }
        })
        let workspaceStream = try await transport.open("workspace/follow")
        var workspaceOpening = workspaceStream.makeAsyncIterator()
        guard let baseline = try await workspaceOpening.next() else { throw URLError(.badServerResponse) }
        try applyWorkspaces(baseline)
        globalTasks.append(Task { [weak self] in
            do {
                for try await value in workspaceStream {
                    guard let self, self.lifetime == lifetime else { return }
                    try self.applyWorkspaces(value)
                }
            } catch { self?.report(error) }
        })
        try await refreshSummaries()
        // Never turn a failed permission read into a hidden toggle and an unknown
        // server-default grant. Authentication, transport and decoding failures
        // fail bootstrap; a successfully read catalog determines availability.
        let catalog: DSHSessionPermissionCatalog = try await transport.call("permissionPresets/catalog").dshDecode()
        supportsSessionPermissions = catalog.supportsToggle
        // Always one host-wide control stream on the existing multiplexed transport.
        // Metadata support is independent of permission-toggle availability.
        let control = try await transport.open("session/control")
        var opening = control.makeAsyncIterator()
        guard let baseline = try await opening.next(), baseline[dsh: "type"].dshString == "baseline" else {
            throw URLError(.cannotParseResponse)
        }
        try applySessionControl(baseline)
        globalTasks.append(Task { [weak self] in
            do {
                for try await frame in control {
                    guard let self, self.lifetime == lifetime else { return }
                    try self.applySessionControl(frame)
                }
            } catch {
                guard let self, self.lifetime == lifetime else { return }
                self.invalidateProjectionState()
                self.report(error)
            }
        })
    }

    func start(receive: @escaping @MainActor (BackendEvent) -> Void) {
        self.receive = receive
        if stopped {
            stopped = false
            transport = DSHTransport(configuration: configuration)
            globalTasks.append(Task { [weak self] in
                do { try await self?.bootstrap() } catch { self?.report(error) }
            })
        } else {
            receive(.status("live"))
            receive(.projectsSnapshot(workspaceState.snapshot))
            for row in summaries.values { publish(row) }
        }
    }

    func stop() {
        stopped = true
        mcpService.invalidate(stopping: true)
        lifetime = UUID()
        receive = nil
        eventClientID = nil
        invalidateProjectionState()
        globalTasks.forEach { $0.cancel() }
        globalTasks.removeAll()
        followTasks.values.forEach { $0.cancel() }
        followTasks.removeAll()
        openings.values.forEach { $0.cancel() }
        openings.removeAll()
        transport.close()
    }

    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        workspaceState.snapshot
    }

    func searchDirectories(query: String, root: String) async throws -> BackendDirectorySearch {
        let generation = lifetime
        let input = query.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let home: DSHDirectoryListing
        do { home = try await transport.call("directoryPicker/list").dshDecode() }
        catch let error as DSHRemoteError where error.code == "directory-picker/unavailable" {
            // Native host choosers cannot be operated from the phone. An explicit
            // absolute path still works; workspace/create validates it on the host.
            guard !stopped, lifetime == generation else { throw BackendError.disconnected }
            return .init(directories: [], selectedDirectory: input.hasPrefix("/") ? input : nil,
                requiresDSHBrowseConfiguration: true)
        }
        let request = DSHDirectoryListing.searchPath(input: input, home: home.home)
        let listing: DSHDirectoryListing
        if request.path == home.path { listing = home }
        else { listing = try await transport.call("directoryPicker/list", args: ["path": .string(request.path)]).dshDecode() }
        guard !stopped, lifetime == generation else { throw BackendError.disconnected }
        return listing.searchResult(partial: request.partial)
    }

    func resolveProject(directory: String) async throws -> BackendProjectResolution {
        guard !stopped else { throw BackendError.disconnected }
        let generation = lifetime
        let result = try await call("workspace/create", request: ["path": .string(directory)])
        let workspace: DSHWorkspace = try result[dsh: "workspace"].dshDecode()
        guard !Task.isCancelled, !stopped, lifetime == generation else { throw BackendError.disconnected }
        try applyWorkspaces(.object(["type": .string("upsert"), "workspace": result[dsh: "workspace"]]))
        return .init(project: workspace.project,
            scope: .init(projectID: workspace.workspaceId, directory: workspace.path), canonicalDirectory: workspace.path)
    }

    func sessionStatuses(scope: BackendScope) async throws -> [String: String] {
        guard !stopped else { throw BackendError.disconnected }
        return Dictionary(uniqueKeysWithValues: summaries.values.filter {
            !archived.contains($0.sessionId) && matches($0, scope: scope)
        }.map { ($0.sessionId, $0.running ? "busy" : "idle") })
    }

    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        guard cursor == nil else { throw BackendError.invalidScope }
        try await refreshSummaries()
        let rows = summaries.values.filter { row in
            !archived.contains(row.sessionId) && (!roots || row.origin != "subagent") && matches(row, scope: scope)
        }.map(normalize).sorted { ($0.time?.updated ?? 0) > ($1.time?.updated ?? 0) }
        // DSH list is unpaged. Returning all rows avoids advertising a fake cursor.
        return .init(sessions: rows)
    }

    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        if summaries[id] == nil { try await refreshSummaries() }
        guard let row = summaries[id], matches(row, scope: scope) else { throw BackendError.invalidScope }
        return normalize(row)
    }

    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        guard let workspace = workspace(for: request.scope) else { throw BackendError.invalidScope }
        let generation = lifetime
        let id = try await DSHSessionCreationWorkflow.create(workspaceID: workspace.workspaceId,
            agent: request.agent, permissionPreset: request.permissionPreset) { endpoint, args in
                guard !self.stopped, self.lifetime == generation else { throw BackendError.disconnected }
                let result = try await self.transport.call(endpoint, args: args)
                guard !self.stopped, self.lifetime == generation else { throw BackendError.disconnected }
                return result
            }
        try Task.checkCancellation()
        if let model = request.model { try await selectModel(model, variant: request.variant, sessionID: id) }
        if let title = request.title, !title.isEmpty { _ = try await call("session/rename", request: ["sessionId": .string(id), "title": .string(title)]) }
        try await refreshSummaries()
        return try await session(id: id, scope: request.scope)
    }

    func refreshPermissions(sessionID: String, scope: BackendScope) async throws -> OpenCodeSession {
        guard !permissionUpdates.contains(sessionID) else { throw DSHSessionPermissionWorkflow.Failure.updateInProgress }
        let generation = lifetime
        let permissionGeneration = permissionGeneration
        let revision = permissionReadRevisions[sessionID, default: 0]
        _ = try await session(id: sessionID, scope: scope)
        let projection = try await call("session/projections", request: ["sessionId": .string(sessionID)])
        guard !stopped, lifetime == generation, self.permissionGeneration == permissionGeneration,
              permissionReadRevisions[sessionID, default: 0] == revision,
              let row = summaries[sessionID], matches(row, scope: scope) else { throw BackendError.disconnected }
        try applyProjectionBaseline(projection, sessionID: sessionID)
        return normalize(row)
    }

    func setPermissions(sessionID: String, preset: BackendSessionPermissionPreset, scope: BackendScope) async throws -> OpenCodeSession {
        guard permissionUpdates.insert(sessionID).inserted else { throw DSHSessionPermissionWorkflow.Failure.updateInProgress }
        defer { permissionUpdates.remove(sessionID) }
        permissionReadRevisions[sessionID, default: 0] &+= 1
        let generation = lifetime
        let permissionGeneration = permissionGeneration
        _ = try await session(id: sessionID, scope: scope)
        do {
            let catalog: DSHSessionPermissionCatalog = try await transport.call("permissionPresets/catalog").dshDecode()
            guard catalog.supports(preset) else { throw DSHSessionCreationWorkflow.Failure.permissionsUnavailable }
            let projection = try await DSHSessionPermissionWorkflow.apply(sessionID: sessionID, preset: preset) { endpoint, args in
                // A moved/deleted session or replaced connection must not receive a stale confirmation.
                guard !self.stopped, self.lifetime == generation, self.permissionGeneration == permissionGeneration,
                      let row = self.summaries[sessionID], self.matches(row, scope: scope) else { throw BackendError.disconnected }
                let value = try await self.transport.call(endpoint, args: args)
                guard !self.stopped, self.lifetime == generation, self.permissionGeneration == permissionGeneration else {
                    throw BackendError.disconnected
                }
                return value
            }
            try applyProjectionBaseline(projection, sessionID: sessionID)
            guard let row = summaries[sessionID], matches(row, scope: scope) else { throw BackendError.invalidScope }
            return normalize(row)
        } catch {
            // A timeout can occur after the host applied the command. Unknown is
            // honest until a fresh read/control frame, never an optimistic rollback.
            if !stopped, lifetime == generation, self.permissionGeneration == permissionGeneration {
                projectionStates[sessionID, default: .init()].invalidate(key: "permissions")
                if let row = summaries[sessionID] { publish(row) }
            }
            throw error
        }
    }

    private func applyProjectionBaseline(_ baseline: DSHJSON, sessionID: String) throws {
        try projectionStates[sessionID, default: .init()].applyBaseline(baseline)
        if let row = summaries[sessionID] { publish(row) }
    }

    private func invalidateProjectionState() {
        awaitingControlBaseline = true
        permissionGeneration = UUID()
        for id in Array(projectionStates.keys) { projectionStates[id]?.invalidate() }
        for row in summaries.values { publish(row) }
    }

    private func applySessionControl(_ frame: DSHJSON) throws {
        switch frame[dsh: "type"].dshString {
        case "baseline":
            guard let baselines = frame[dsh: "value"][dsh: "projections"].objectValue else { throw URLError(.cannotParseResponse) }
            // Reconnect invalidated the previous generation already. A follow/read
            // can arrive first, so merge the first control baseline without losing
            // its newer values or cold sessions absent from this loaded-session list.
            let startsNewGeneration = !awaitingControlBaseline
            let states = try DSHSessionProjectionState.applyingControlBaseline(
                baselines, to: projectionStates, startsNewGeneration: startsNewGeneration)
            if startsNewGeneration { permissionGeneration = UUID() }
            awaitingControlBaseline = false
            projectionStates = states
            for row in summaries.values { publish(row) }
        case "projection":
            guard let id = frame[dsh: "sessionId"].dshString,
                  let key = frame[dsh: "key"].dshString, !key.isEmpty,
                  let seq = frame[dsh: "seq"].intValue, seq >= -1,
                  let value = frame.objectValue?["value"] else { throw URLError(.cannotParseResponse) }
            if projectionStates[id, default: .init()].applyDelta(key: key, value: value, sequence: seq),
               let row = summaries[id] { publish(row) }
        default: throw URLError(.cannotParseResponse)
        }
    }

    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        _ = try await session(id: id, scope: scope)
        _ = try await call("session/rename", request: ["sessionId": .string(id), "title": .string(title)])
        try await refreshSummaries()
        return try await session(id: id, scope: scope)
    }

    func deleteSession(id: String, scope: BackendScope) async throws {
        // DSH offers archival, not deletion. Never turn the shared Delete action into archival.
        throw URLError(.unsupportedURL)
    }

    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] {
        let page = try await sessions(scope: scope, cursor: nil, limit: limit, roots: true)
        return Array(page.sessions.filter { $0.title?.localizedCaseInsensitiveContains(query) == true }.prefix(max(0, limit)))
    }

    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        let roster: DSHAgentPresetRoster = try await transport.call("agentPresets/list").dshDecode()
        let value = try await transport.call("session/modelCatalog")
        guard let groups = value[dsh: "groups"].arrayValue else { throw URLError(.cannotParseResponse) }
        let providers = try groups.map { group -> OpenCodeProvider in
            guard let id = group[dsh: "id"].dshString, let name = group[dsh: "name"].dshString,
                  let entries = group[dsh: "models"].arrayValue else { throw URLError(.cannotParseResponse) }
            var models: [String: OpenCodeModel] = [:]
            for item in entries {
                guard let modelID = item[dsh: "id"].dshString, let modelName = item[dsh: "name"].dshString else { throw URLError(.cannotParseResponse) }
                let efforts = item[dsh: "reasoning"][dsh: "efforts"].dshArray.compactMap { $0[dsh: "id"].dshString }
                models[modelID] = .init(id: modelID, providerID: id, name: modelName,
                    capabilities: .init(reasoning: !efforts.isEmpty, attachment: false, toolcall: true),
                    variants: efforts.isEmpty ? nil : Dictionary(uniqueKeysWithValues: efforts.map { ($0, DSHJSON.object([:])) }))
            }
            return .init(id: id, name: name, models: models)
        }
        var defaults: [String: String] = [:]
        if let provider = value[dsh: "default"][dsh: "provider"].dshString,
           let model = value[dsh: "default"][dsh: "model"].dshString { defaults[provider] = model }
        return .init(agents: roster.agents, providers: providers, defaults: defaults)
    }

    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        _ = try await session(id: sessionID, scope: scope)
        try await ensureFollow(sessionID)
        guard var transcript = transcripts[sessionID] else { throw URLError(.badServerResponse) }
        if let cursor {
            guard let before = Int(cursor), before == transcript.records.keys.min() else { throw BackendError.invalidScope }
            let page = try await call("session/page", request: [
                "address": address(sessionID), "throughSeq": .number(Double(transcript.cursor)),
                "beforeSeq": .number(Double(before)), "maxMessages": .number(Double(max(50, min(limit, 500))))
            ])
            // Live frames may have arrived during the page request.
            guard var current = transcripts[sessionID] else { throw BackendError.disconnected }
            try current.prepend(page)
            transcripts[sessionID] = current
            transcript = current
        }
        return .init(messages: transcript.messages,
            olderCursor: transcript.hasMore ? transcript.records.keys.min().map(String.init) : nil)
    }

    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        // Core prototype is text-only. Reject unsupported intent before admission.
        guard request.attachments.isEmpty, request.agentMentions.isEmpty, request.skillIDs.isEmpty else {
            return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        }
        do {
            _ = try await session(id: request.sessionID, scope: request.scope)
            try await ensureFollow(request.sessionID)
            if let model = request.model { try await selectModel(model, variant: request.variant, sessionID: request.sessionID) }
        } catch { return .rejected(sessionID: request.sessionID, messageID: request.messageID) }
        do {
            let result = try await call("session/prompt", request: [
                "requestId": .string(request.messageID), "sessionId": .string(request.sessionID),
                "mode": .string(request.delivery?.rawValue == "steer" ? "steer" : "queue"),
                "content": .array([.object(["type": .string("text"), "text": .string(request.text)])]),
                "clientTimeZone": .string(TimeZone.current.identifier)
            ])
            guard result[dsh: "accepted"].dshBool else { throw URLError(.cannotParseResponse) }
            return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        } catch is DSHRemoteError {
            return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        } catch {
            // Do not resend. The durable user source rpcId reconciles an uncertain admission.
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
    }

    func interrupt(sessionID: String, scope: BackendScope) async throws {
        _ = try await session(id: sessionID, scope: scope)
        _ = try await call("session/cancel", request: ["sessionId": .string(sessionID)])
    }

    private func selectModel(_ model: OpenCodeModelReference, variant: String?, sessionID: String) async throws {
        var fields: [String: DSHJSON] = ["sessionId": .string(sessionID), "provider": .string(model.providerID), "model": .string(model.modelID)]
        if let variant { fields["reasoningEffort"] = .string(variant) }
        _ = try await call("session/selectModel", request: fields)
    }

    private func call(_ endpoint: String, request: [String: DSHJSON]) async throws -> DSHJSON {
        try await transport.call(endpoint, args: ["request": .object(request)])
    }

    private func address(_ id: String) -> DSHJSON { .object(["kind": .string("session"), "sessionId": .string(id)]) }

    private func ensureFollow(_ id: String) async throws {
        if let opening = openings[id] { return try await opening.value }
        if followTasks[id] != nil { return }
        let generation = lifetime
        let opening = Task { [weak self] in
            guard let self else { throw BackendError.disconnected }
            let stream = try await transport.open("session/follow", args: ["request": .object([
                "address": address(id), "assistantStream": .bool(true), "maxMessages": .number(100)
            ])])
            var iterator = stream.makeAsyncIterator()
            guard let first = try await iterator.next(), self.lifetime == generation else { throw BackendError.disconnected }
            try self.applyTranscript(first, id: id)
            self.followTasks[id] = Task { [weak self] in
                do {
                    for try await frame in stream {
                        guard let self, self.lifetime == generation else { return }
                        try self.applyTranscript(frame, id: id)
                    }
                } catch {
                    guard let self, self.lifetime == generation else { return }
                    self.followTasks[id] = nil
                    self.report(error, sessionID: id)
                }
            }
        }
        openings[id] = opening
        defer { openings[id] = nil }
        try await opening.value
    }

    private func applyTranscript(_ value: DSHJSON, id: String) throws {
        var transcript = transcripts[id] ?? DSHTranscript(sessionID: id)
        let changes = try transcript.apply(value)
        transcripts[id] = transcript
        let directory = summaries[id].map(normalize)?.directory
        for event in changes { receive?(.mutation(directory: directory, event: event)) }
        if value[dsh: "type"].dshString == "snapshot" {
            projectionStates[id, default: .init()].applyHeader(value[dsh: "header"])
            try applyProjectionBaseline(value[dsh: "projections"], sessionID: id)
        }
        // Durable transcript events do not carry freshly computed metrics. The
        // shared control stream owns projection updates (including title/preset).
    }

    private func refreshSummaries() async throws {
        let generation = lifetime
        let revisions = statusRevisions
        let value = try await transport.call("session/list", args: ["_request": .object([:])])
        let rows = try value[dsh: "items"].dshDecode([DSHSessionSummary].self)
        guard generation == lifetime, !stopped else { throw BackendError.disconnected }
        for var row in rows {
            if statusRevisions[row.sessionId] != revisions[row.sessionId], let current = summaries[row.sessionId] {
                row.running = current.running
            }
            summaries[row.sessionId] = row
            publish(row)
        }
    }

    private func workspace(for scope: BackendScope) -> DSHWorkspace? {
        workspaces.first { $0.workspaceId == scope.projectID || $0.path == scope.directory }
    }

    private func matches(_ row: DSHSessionSummary, scope: BackendScope) -> Bool {
        if let workspace = workspace(for: scope) {
            return workspaceState.workspace(forSession: row.sessionId, cwd: row.cwd)?.workspaceId == workspace.workspaceId
        }
        return scope.projectID == nil && (scope.directory == nil || row.cwd == scope.directory)
    }

    private func normalize(_ row: DSHSessionSummary) -> OpenCodeSession {
        let state = projectionStates[row.sessionId] ?? .init()
        let cwd = state.header.cwd ?? row.cwd
        let origin = state.header.origin ?? row.origin
        let workspace = workspaceState.workspace(forSession: row.sessionId, cwd: cwd)
        // List hints may decorate unloaded rows, but never hydrate canonical metrics
        // or overwrite a known projection (including its explicit absence).
        let values: DSHJSON = state.isCurrent ? .object(state.values) : (row.projections?[dsh: "values"] ?? .null)
        var session = OpenCodeSession(id: row.sessionId, title: values[dsh: "title"].dshString,
            workspaceID: nil, directory: workspace?.path ?? cwd, projectID: workspace?.workspaceId,
            parentID: origin == "subagent" ? (state.header.parentSession ?? row.parentSessionId) : nil)
        session.time = .init(created: state.header.createdAt, updated: row.updatedAt)
        session.agent = values[dsh: "agentPreset"].dshString
        session.backendMetadata = state.metadata
        session.backendMetadata?.origin = origin
        session.backendMetadata?.parentSession = state.header.parentSession ?? row.parentSessionId
        if supportsSessionPermissions {
            session.permissions = .init(currentPreset: state.values["permissions"]?[dsh: "currentValue"].dshString)
        }
        let model = values[dsh: "modelSelection"][dsh: "next"]
        if let provider = model[dsh: "provider"].dshString, let id = model[dsh: "model"].dshString {
            session.model = .init(providerID: provider, modelID: id, variant: model[dsh: "reasoningEffort"].dshString)
        }
        return session
    }

    private func publish(_ row: DSHSessionSummary) {
        guard !archived.contains(row.sessionId) else { return }
        let session = normalize(row)
        receive?(.mutation(directory: session.directory, event: .sessionUpdated(session)))
        receive?(.mutation(directory: session.directory, event: .sessionStatus(sessionID: session.id, status: row.running ? "busy" : "idle")))
    }

    private func applyWorkspaces(_ frame: DSHJSON) throws {
        let previous = summaries.values.map(normalize)
        try workspaceState.apply(frame)
        receive?(.projectsSnapshot(workspaceState.snapshot))
        for session in previous {
            if archived.contains(session.id) || summaries[session.id].map({ normalize($0).directory != session.directory }) == true {
                receive?(.mutation(directory: session.directory, event: .sessionDeleted(session)))
            }
        }
        for row in summaries.values { publish(row) }
    }

    private func globalEvent(_ frame: DSHJSON) async throws {
        mcpService.handleEvent(frame)
        switch frame[dsh: "type"].dshString {
        case "ready":
            eventClientID = frame[dsh: "clientId"].dshString
            receive?(.status("live"))
            try await refreshSummaries()
        case "waterfall":
            guard let clientID = eventClientID, let eventID = frame[dsh: "eventId"].dshString else {
                throw URLError(.cannotParseResponse)
            }
            try await transport.delegateInteraction(clientID: clientID, eventID: eventID)
        case "emit":
            let args = frame[dsh: "args"].dshArray
            switch frame[dsh: "event"].dshString {
            case "api-session/added":
                guard let value = args.first else { return }
                let row = try value.dshDecode(DSHSessionSummary.self)
                summaries[row.sessionId] = row
                publish(row)
            case "api-session/status":
                guard args.count == 2, let id = args[0].dshString else { return }
                statusRevisions[id, default: 0] &+= 1
                summaries[id]?.running = args[1].dshBool
                receive?(.mutation(directory: summaries[id].map(normalize)?.directory, event: .sessionStatus(sessionID: id, status: args[1].dshBool ? "busy" : "idle")))
            case "api-session/error":
                guard args.count == 2, let id = args[0].dshString else { return }
                receive?(.mutation(directory: summaries[id].map(normalize)?.directory, event: .sessionError(sessionID: id, message: args[1].dshString)))
            case "api-session/activity": try await refreshSummaries()
            default: break
            }
        default: break
        }
    }

    private func report(_ error: Error, sessionID: String? = nil) {
        guard !stopped, !(error is CancellationError) else { return }
        receive?(.diagnostic("DSH stream failed: \(String(describing: type(of: error)))"))
        receive?(.mutation(directory: sessionID.flatMap { summaries[$0]?.cwd },
                           event: .sessionError(sessionID: sessionID, message: error.localizedDescription)))
    }
}
