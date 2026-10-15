import Combine
import XCTest
@testable import OpenClient

@MainActor
final class DSHMCPServiceTests: XCTestCase {
    private let module = "@deepseek-ai/dsh-mcp-client"

    func testInventoryFiltersExactModuleAndSeparatesEnabledFromPhaseAndPresetScope() async throws {
        let stock = entry("root/mcp", enabled: true, phase: "failed")
        let unrelated = entry("imposter", module: "@vendor/dsh-mcp-client")
        let conditional: DSHJSON = .object(["entryId": .null, "moduleName": .string(module), "enabled": .string("conditional"), "fiberPhase": .string("active")])
        let rpc = RPC([inventory([stock, unrelated], presets: [.object(["id": .string("standard"), "name": .string("Standard"), "rows": .array([conditional])])]), managed([stock])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertEqual(service.state.servers.count, 2)
        let profile = try XCTUnwrap(service.state.servers.first)
        XCTAssertEqual(profile.name, "root/mcp")
        XCTAssertEqual(profile.enabled, true)
        XCTAssertEqual(profile.phase, .failed)
        XCTAssertTrue(profile.canToggle)
        let preset = service.state.servers[1]
        XCTAssertEqual(preset.scope, .agentPreset(id: "standard", name: "Standard"))
        XCTAssertNil(preset.enabled)
        XCTAssertEqual(preset.phase, .active)
        XCTAssertFalse(preset.canToggle)
        XCTAssertEqual(preset.restriction, .preset)
        XCTAssertNotEqual(profile.id, preset.id)
        XCTAssertTrue(rpc.calls.allSatisfy { $0.arguments.isEmpty }, "No session/directory/scope arguments")
    }

    func testUnavailableManagementStillShowsReadOnlyInventoryWithoutManagerRPC() async {
        let rpc = RPC([inventory([entry("mcp")], available: false)])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertEqual(service.state.servers.first?.restriction, .managementUnavailable)
        XCTAssertEqual(rpc.calls.map(\.endpoint), ["pluginInventory/list"])
    }

    func testMissingManagementAvailabilityIsConservativelyReadOnly() async {
        let rpc = RPC([.object(["entries": .array([entry("mcp")])])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertFalse(service.state.servers[0].canToggle)
        XCTAssertEqual(rpc.calls.count, 1)
    }

    func testDuplicateIDsUnknownPhaseAndReadOnlyDeclarationsAreSafe() async {
        let duplicate = entry("same")
        let unknown = entry("future", phase: "future-phase")
        let unaddressable = entry("readonly")
        var control = unaddressable.objectValue!
        control["readOnlyReason"] = .string("unaddressable")
        let rpc = RPC([inventory([duplicate, duplicate, unknown, unaddressable]),
                       .array([managedEntry(duplicate), managedEntry(unknown), .object(control)])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertEqual(Set(service.state.servers.map(\.id)).count, 4)
        XCTAssertFalse(service.state.servers[0].canToggle)
        XCTAssertFalse(service.state.servers[1].canToggle)
        XCTAssertNil(service.state.servers[2].phase)
        XCTAssertTrue(service.state.servers[2].canToggle)
        XCTAssertEqual(service.state.servers[3].restriction, .unaddressable)
    }

    func testChangedFalseCanBeAppliedAndRPCUsesEntryIDNotPatchID() async throws {
        let old = entry("root/mcp", enabled: false)
        let new = entry("root/mcp", enabled: true, phase: "loading")
        let rpc = RPC([inventory([old]), managed([old]), inventory([old]), managed([old]),
                       change(target: "root/mcp", application: "applied", changed: false), inventory([new]), managed([new])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        let id = try XCTUnwrap(service.state.servers.first?.id)
        await service.setEnabled(id: id, enabled: true)
        let mutation = try XCTUnwrap(rpc.calls.first { $0.endpoint == "pluginManager/setPluginEnabled" })
        XCTAssertEqual(mutation.arguments, ["id": .string("root/mcp"), "enabled": .bool(true)])
        XCTAssertEqual(service.state.servers[0].enabled, true)
        XCTAssertEqual(service.state.servers[0].phase, .loading)
        XCTAssertNil(service.state.errorMessage)
        XCTAssertNotNil(service.state.notice)
        XCTAssertTrue(service.state.togglingIDs.isEmpty)
        XCTAssertFalse(service.state.isLoading)
    }

    func testAllNonAppliedOutcomesRereadWithoutOptimisticFlip() async throws {
        for application in ["restart-required", "overridden", "failed", "cancelled"] {
            let old = entry("mcp", enabled: false)
            let rpc = RPC([inventory([old]), managed([old]), inventory([old]), managed([old]),
                           change(target: "mcp", application: application), inventory([old]), managed([old])])
            let service = DSHMCPService(call: rpc.call)
            await service.refresh()
            await service.setEnabled(id: try XCTUnwrap(service.state.servers.first?.id), enabled: true)
            XCTAssertEqual(service.state.servers.first?.enabled, false, application)
            XCTAssertTrue(service.state.isCurrent)
            if application == "failed" { XCTAssertNotNil(service.state.errorMessage) }
            else { XCTAssertNotNil(service.state.notice) }
            XCTAssertEqual(rpc.calls.suffix(2).map(\.endpoint), ["pluginInventory/list", "pluginManager/listPlugins"])
        }
    }

    func testWrongTargetStageEnablementAndUnknownApplicationAreNotSuccess() async throws {
        for (field, value) in [("target", "other"), ("stage", "install"), ("application", "future"), ("enabled", "wrong")] {
            let old = entry("mcp", enabled: false)
            var response = change(target: "mcp", application: "applied").objectValue!
            response[field] = .string(value)
            let rpc = RPC([inventory([old]), managed([old]), inventory([old]), managed([old]), .object(response), inventory([old]), managed([old])])
            let service = DSHMCPService(call: rpc.call)
            await service.refresh()
            await service.setEnabled(id: try XCTUnwrap(service.state.servers.first?.id), enabled: true)
            XCTAssertNotNil(service.state.errorMessage, field)
            XCTAssertEqual(service.state.servers.first?.enabled, false)
            XCTAssertEqual(rpc.calls.count, 7)
        }
    }

    func testTimeoutRereadsAndCanRevealAppliedValueWithoutClaimingConfirmedSuccess() async throws {
        let old = entry("mcp", enabled: false), new = entry("mcp", enabled: true)
        let rpc = RPC([inventory([old]), managed([old]), inventory([old]), managed([old]), .null, inventory([new]), managed([new])])
        rpc.failureAt = 4
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        await service.setEnabled(id: try XCTUnwrap(service.state.servers.first?.id), enabled: true)
        XCTAssertEqual(service.state.servers[0].enabled, true)
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertNotNil(service.state.errorMessage)
        XCTAssertNil(service.state.notice)
    }

    func testWriteReadbackFailureMarksPreviouslyKnownRowsStale() async throws {
        let old = entry("mcp", enabled: false)
        let rpc = RPC([inventory([old]), managed([old]), inventory([old]), managed([old]), change(target: "mcp", application: "applied"), .null])
        rpc.failureAt = 5
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        await service.setEnabled(id: try XCTUnwrap(service.state.servers.first?.id), enabled: true)
        XCTAssertFalse(service.state.isCurrent)
        XCTAssertEqual(service.state.servers[0].enabled, false)
        XCTAssertNotNil(service.state.errorMessage)
    }

    func testFreshInventoryRejectsReusedIDOwnedByDifferentPlugin() async throws {
        let old = entry("mcp")
        let replacement = entry("mcp", module: "@other/plugin")
        let rpc = RPC([inventory([old]), managed([old]), inventory([replacement]), managed([replacement])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        await service.setEnabled(id: try XCTUnwrap(service.state.servers.first?.id), enabled: true)
        XCTAssertFalse(rpc.calls.contains { $0.endpoint == "pluginManager/setPluginEnabled" })
        XCTAssertNotNil(service.state.errorMessage)
        XCTAssertTrue(service.state.servers.isEmpty)
    }

    func testPresetAndForgedIDsNeverBecomeManagementTargets() async throws {
        let stock = entry("mcp")
        let list = inventory([stock], presets: [.object(["id": .string("preset"), "rows": .array([stock])])])
        let rpc = RPC([list, managed([stock]), list, managed([stock]), list, managed([stock])])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        await service.setEnabled(id: try XCTUnwrap(service.state.servers.last?.id), enabled: false)
        await service.setEnabled(id: "mcp", enabled: false)
        XCTAssertFalse(rpc.calls.contains { $0.endpoint == "pluginManager/setPluginEnabled" })
    }

    func testMalformedInventoryIsErrorNotEmptyAndGenuineEmptyIsCurrent() async {
        for response in [DSHJSON.null, .object(["entries": .array([.object(["entryId": .string("mcp"), "moduleName": .string(module), "enabled": .string("true")])])])] {
            let rpc = RPC([response])
            let service = DSHMCPService(call: rpc.call)
            await service.refresh()
            XCTAssertFalse(service.state.isCurrent)
            XCTAssertNotNil(service.state.errorMessage)
        }
        let rpc = RPC([inventory([], available: false)])
        let service = DSHMCPService(call: rpc.call)
        await service.refresh()
        XCTAssertTrue(service.state.isCurrent)
        XCTAssertTrue(service.state.servers.isEmpty)
        XCTAssertNil(service.state.errorMessage)
    }

    func testOlderReadCannotOverwriteNewGenerationRead() async {
        let arrival = AsyncStream<Void>.makeStream()
        var held: CheckedContinuation<DSHJSON, Error>?
        var reads = 0
        let old = inventory([entry("old")], available: false)
        let new = inventory([entry("new")], available: false)
        let service = DSHMCPService { _, _ in
            reads += 1
            if reads == 1 {
                return try await withCheckedThrowingContinuation { continuation in
                    held = continuation
                    arrival.continuation.yield(())
                }
            }
            return new
        }
        let oldRead = Task { await service.refresh() }
        for await _ in arrival.stream { break }
        service.invalidate()
        await service.refresh()
        held?.resume(returning: old)
        await oldRead.value
        XCTAssertEqual(service.state.servers.map(\.name), ["new"])
        XCTAssertTrue(service.state.isCurrent)
    }

    func testOlderReadCannotOverwriteCompletedWrite() async throws {
        let old = entry("mcp", enabled: false), new = entry("mcp", enabled: true)
        let oldList = inventory([old]), newList = inventory([new]), control = managed([old])
        let arrival = AsyncStream<Void>.makeStream()
        var held: CheckedContinuation<DSHJSON, Error>?
        var reads = 0
        var written = false
        let response = change(target: "mcp", application: "applied")
        let service = DSHMCPService { endpoint, _ in
            if endpoint == "pluginManager/listPlugins" { return control }
            if endpoint == "pluginManager/setPluginEnabled" { written = true; return response }
            reads += 1
            if reads == 2 {
                return try await withCheckedThrowingContinuation { continuation in
                    held = continuation
                    arrival.continuation.yield(())
                }
            }
            return written ? newList : oldList
        }
        await service.refresh()
        let id = try XCTUnwrap(service.state.servers.first?.id)
        let oldRead = Task { await service.refresh() }
        for await _ in arrival.stream { break }
        await service.setEnabled(id: id, enabled: true)
        held?.resume(returning: oldList)
        await oldRead.value
        XCTAssertEqual(service.state.servers.first?.enabled, true)
        XCTAssertTrue(service.state.isCurrent)
    }

    func testTrailingEventRefreshPreservesMutationFailure() async throws {
        let old = entry("mcp", enabled: false)
        let list = inventory([old]), control = managed([old])
        let arrival = AsyncStream<Void>.makeStream()
        var held: CheckedContinuation<DSHJSON, Error>?
        let service = DSHMCPService { endpoint, _ in
            if endpoint == "pluginInventory/list" { return list }
            if endpoint == "pluginManager/listPlugins" { return control }
            return try await withCheckedThrowingContinuation { continuation in
                held = continuation
                arrival.continuation.yield(())
            }
        }
        await service.refresh()
        let id = try XCTUnwrap(service.state.servers.first?.id)
        let write = Task { await service.setEnabled(id: id, enabled: true) }
        for await _ in arrival.stream { break }
        await service.refresh() // Another window/change event requests a trailing read.
        held?.resume(returning: change(target: "mcp", application: "failed"))
        await write.value
        XCTAssertNotNil(service.state.errorMessage)
        XCTAssertEqual(service.state.servers.first?.enabled, false)
        XCTAssertTrue(service.state.isCurrent)
    }

    func testConcurrentTogglesSerializeAndStopDiscardsLateMutationResponse() async throws {
        let old = entry("mcp", enabled: false)
        let list = inventory([old]), management = managed([old])
        let arrival = AsyncStream<Void>.makeStream()
        var held: CheckedContinuation<DSHJSON, Error>?
        var writes = 0
        let service = DSHMCPService { endpoint, _ in
            if endpoint == "pluginInventory/list" { return list }
            if endpoint == "pluginManager/listPlugins" { return management }
            writes += 1
            return try await withCheckedThrowingContinuation { continuation in
                held = continuation
                arrival.continuation.yield(())
            }
        }
        await service.refresh()
        let id = try XCTUnwrap(service.state.servers.first?.id)
        let first = Task { await service.setEnabled(id: id, enabled: true) }
        for await _ in arrival.stream { break }
        await service.setEnabled(id: id, enabled: false)
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(service.state.servers.first?.enabled, false)
        XCTAssertEqual(service.state.togglingIDs, [id])
        service.invalidate(stopping: true)
        held?.resume(returning: change(target: "mcp", application: "applied"))
        await first.value
        XCTAssertEqual(service.state, BackendMCPState())
        await service.refresh()
        XCTAssertEqual(writes, 1)
    }

    func testReadyAndExternalChangedRefreshPublisherWithoutExtraStream() async {
        let snapshots = AsyncStream<BackendMCPState>.makeStream()
        var reads = 0
        let first = inventory([entry("first")], available: false)
        let second = inventory([entry("second")], available: false)
        let service = DSHMCPService { endpoint, arguments in
            XCTAssertEqual(endpoint, "pluginInventory/list")
            XCTAssertTrue(arguments.isEmpty)
            reads += 1
            return reads == 1 ? first : second
        }
        let observation = service.statePublisher.sink { value in
            if value.isCurrent && !value.isLoading { snapshots.continuation.yield(value) }
        }
        defer { observation.cancel(); service.invalidate(stopping: true) }
        service.handleEvent(.object(["type": .string("ready")]))
        for await state in snapshots.stream { XCTAssertEqual(state.servers.first?.name, "first"); break }
        service.handleEvent(.object(["type": .string("emit"), "event": .string("plugin-manager/changed"), "args": .array([])]))
        for await state in snapshots.stream { XCTAssertEqual(state.servers.first?.name, "second"); break }
        XCTAssertEqual(reads, 2)
    }

    private func entry(_ id: String, enabled: Bool = true, phase: String? = "active", module: String? = nil) -> DSHJSON {
        .object(["entryId": .string(id), "moduleName": .string(module ?? self.module), "enabled": .bool(enabled), "fiberPhase": phase.map(DSHJSON.string) ?? .null])
    }
    private func inventory(_ entries: [DSHJSON], available: Bool = true, presets: [DSHJSON] = []) -> DSHJSON {
        .object(["entries": .array(entries), "managementAvailable": .bool(available), "agentPresets": .array(presets)])
    }
    private func managedEntry(_ entry: DSHJSON) -> DSHJSON {
        var values = entry.objectValue!
        values["patchId"] = .string("patch-id-not-the-rpc-target")
        return .object(values)
    }
    private func managed(_ entries: [DSHJSON]) -> DSHJSON { .array(entries.map(managedEntry)) }
    private func change(target: String, application: String, changed: Bool = true) -> DSHJSON {
        .object(["changed": .bool(changed), "application": .string(application), "stage": .string("enable"), "target": .string(target), "enabled": .bool(true)])
    }

    @MainActor
    private final class RPC {
        struct Invocation { let endpoint: String; let arguments: [String: DSHJSON] }
        var calls: [Invocation] = []
        var failureAt: Int?
        let responses: [DSHJSON]
        init(_ responses: [DSHJSON]) { self.responses = responses }
        func call(_ endpoint: String, _ arguments: [String: DSHJSON]) async throws -> DSHJSON {
            let index = calls.count
            calls.append(.init(endpoint: endpoint, arguments: arguments))
            if index == failureAt { throw URLError(.timedOut) }
            guard responses.indices.contains(index) else {
                XCTFail("Unexpected RPC \(endpoint)")
                throw URLError(.badServerResponse)
            }
            return responses[index]
        }
    }
}
