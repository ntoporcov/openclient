import XCTest
@testable import OpenClient

@MainActor
final class GlobalFormsTests: XCTestCase {
    private let a = BackendFormLocation(directory: "/a", workspaceID: "wrk_one")
    private let b = BackendFormLocation(directory: "/b", workspaceID: "wrk_one")
    private let otherWorkspace = BackendFormLocation(directory: "/a", workspaceID: "wrk_two")
    private var form: BackendForm {
        .init(id: "frm_same", sessionID: "global", title: "Input", fields: [
            .init(raw: ["key": .string("value"), "type": .string("boolean")])
        ])
    }

    private func connection(_ service: GlobalFormFake) -> BackendConnection {
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: .init(baseURL: "https://unused.invalid")), profile: .v2)
        return .init(descriptor: .init(id: "fake", name: "Fake", version: "17155"), projects: adapter,
                     sessions: adapter, chat: adapter, models: adapter, events: GlobalFormEvents(), sessionForms: service)
    }

    func testExactLocationIdentityDraftsAndImmutableMutationOrigin() async throws {
        let service = GlobalFormFake(location: a)
        let facade = GlobalFormsFacade()
        facade.configure(connection(service))
        for location in [a, b, otherWorkspace] { facade.receive(location: location, event: .created(form)) }
        let store = try XCTUnwrap(facade.store(for: a))
        store.setValue(.bool(false), fieldID: "value", for: form.key)
        XCTAssertTrue(try XCTUnwrap(facade.store(for: b)).state(for: form.key).draft.isEmpty)
        XCTAssertTrue(try XCTUnwrap(facade.store(for: otherWorkspace)).state(for: form.key).draft.isEmpty)
        await facade.submit(form, at: a)
        XCTAssertEqual(service.replies.first?.directory, a.directory)
        XCTAssertEqual(service.replies.first?.workspaceID, a.workspaceID)
        XCTAssertEqual(service.answers, [["value": .boolean(false)]])
        XCTAssertTrue(facade.pending(for: a).isEmpty)
        XCTAssertEqual(facade.pending(for: b).count, 1)
        XCTAssertEqual(facade.pending(for: otherWorkspace).count, 1)
        facade.configure(nil)
    }

    func testSettlementDuringHydrationCannotResurrectAndCanonicalLocationIsRetained() async throws {
        let service = GlobalFormFake(location: a)
        let facade = GlobalFormsFacade()
        facade.configure(connection(service))
        await facade.hydrate(nil)
        XCTAssertEqual(facade.defaultLocation, a)
        facade.receive(location: a, event: .created(form))
        let gate = GlobalFormGate()
        service.load = { .init(location: self.a, forms: [self.form]) }
        service.gate = gate
        let task = Task { await facade.hydrate(a) }
        await gate.started()
        facade.receive(location: a, event: .cancelled(form.key))
        service.gate = nil
        gate.resume()
        await task.value
        await facade.hydrate(a)
        facade.receive(location: a, event: .created(form))
        XCTAssertTrue(facade.pending(for: a).isEmpty)
        facade.configure(nil)
    }

    func testOldConnectionCallbackAndContextCannotAffectNewConnection() async throws {
        let old = GlobalFormFake(location: a)
        let facade = GlobalFormsFacade()
        facade.configure(connection(old))
        facade.receive(location: a, event: .created(form))
        let context = try XCTUnwrap(facade.context(form: form, location: a))
        let gate = GlobalFormGate()
        old.gate = gate
        old.load = { .init(location: self.a, forms: [self.form]) }
        let task = Task { await facade.hydrate(a) }
        await gate.started()
        let next = GlobalFormFake(location: b)
        facade.configure(connection(next))
        gate.resume()
        await task.value
        XCTAssertFalse(context.isCurrent())
        XCTAssertTrue(facade.pending(for: a).isEmpty)
        XCTAssertTrue(facade.stores[a] == nil)
        facade.configure(nil)
    }

    func testReconnectInvalidatesOldReadAndUnlocatedEventNeverUsesActiveLocation() async throws {
        let service = GlobalFormFake(location: a)
        let facade = GlobalFormsFacade()
        facade.configure(connection(service))
        await facade.hydrate(nil)
        facade.receive(location: b, event: .created(form))
        let gate = GlobalFormGate()
        service.gate = gate
        service.load = { .init(location: self.a, forms: [self.form]) }
        let task = Task { await facade.hydrate(a) }
        await gate.started()
        service.gate = nil
        service.load = { .init(location: self.a, forms: []) }
        facade.receive(location: nil, event: .created(form))
        gate.resume()
        await task.value
        await facade.hydrate(a)
        XCTAssertTrue(facade.pending(for: a).isEmpty)
        XCTAssertNil(facade.store(for: a)?.forms[form.key])
        facade.configure(nil)
    }

    func testUncertainMutationUsesStateOnlyAndNoAutomaticRetry() async throws {
        let service = GlobalFormFake(location: a)
        service.replyError = BackendSessionFormsError.uncertain
        service.state = .answered(["value": .boolean(false)])
        let facade = GlobalFormsFacade()
        facade.configure(connection(service))
        facade.receive(location: a, event: .created(form))
        facade.store(for: a)?.setValue(.bool(false), fieldID: "value", for: form.key)
        await facade.submit(form, at: a)
        XCTAssertEqual(service.replies.count, 1)
        XCTAssertEqual(service.stateReads.count, 1)
        XCTAssertEqual(service.stateReads.first?.workspaceID, a.workspaceID)
        XCTAssertTrue(service.cancels.isEmpty)
        XCTAssertTrue(facade.pending(for: a).isEmpty)
        facade.configure(nil)
    }

    func testNativeEnvelopePreservesGlobalOwnerAndLocationForAllLifecycleEvents() throws {
        let fixtures = [
            #"{"id":"evt_one","created":123,"type":"form.created","location":{"directory":"/a","workspaceID":"wrk_two"},"data":{"form":{"id":"frm_same","sessionID":"global","title":"Input","fields":[{"key":"value","type":"boolean"}]}}}"#,
            #"{"id":"evt_two","created":124,"type":"form.replied","location":{"directory":"/a","workspaceID":"wrk_two"},"data":{"id":"frm_same","sessionID":"global","answer":{"value":false}}}"#,
            #"{"id":"evt_three","created":125,"type":"form.cancelled","data":{"id":"frm_same","sessionID":"global"}}"#
        ]
        for (index, raw) in fixtures.enumerated() {
            let event = try JSONDecoder().decode(OpenCodeV2ManagedEvent.self, from: Data(raw.utf8))
            XCTAssertEqual(event.globalFormEvent?.sessionID, "global")
            if index < 2 { XCTAssertEqual(event.location?.workspaceID, "wrk_two") }
            else { XCTAssertNil(event.location) }
        }
    }

    func testOverlappingDefaultAndExplicitInventoriesRefreshRejectedCanonicalReplacement() async throws {
        let facade = GlobalFormsFacade()
        let service = GlobalFormFake(location: a)
        facade.configure(connection(service))
        defer { facade.configure(nil) }
        let defaultGate = GlobalFormGate()
        let explicitGate = GlobalFormGate()
        let refreshed = expectation(description: "Fresh canonical inventory after overlapping owners")
        var second = form
        second = .init(id: "frm_next", sessionID: "global", title: second.title, fields: second.fields)
        var scopes: [BackendScope] = []
        service.loadAsync = { scope in
            scopes.append(scope)
            switch scopes.count {
            case 1: await defaultGate.wait(); return .init(location: self.a, forms: [self.form])
            case 2: await explicitGate.wait(); return .init(location: self.a, forms: [self.form, second])
            default: refreshed.fulfill(); return .init(location: self.a, forms: [self.form, second])
            }
        }
        let first = Task { await facade.hydrate(nil) }
        await defaultGate.started()
        let overlapping = Task { await facade.hydrate(a) }
        await explicitGate.started()
        defaultGate.resume()
        await first.value
        explicitGate.resume()
        await overlapping.value
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(scopes.count, 3)
        XCTAssertEqual(scopes.last, a.scope)
        XCTAssertEqual(Set(facade.pending(for: nil).map(\.id)), [form.id, second.id])
        XCTAssertTrue(facade.store(for: nil) === facade.store(for: a))
    }

    func testLocalSettlementDuringInventoryTriggersFreshReadWithoutResurrection() async throws {
        let facade = GlobalFormsFacade()
        let service = GlobalFormFake(location: a)
        facade.configure(connection(service))
        defer { facade.configure(nil) }
        facade.receive(location: a, event: .created(form))
        let gate = GlobalFormGate()
        let refreshed = expectation(description: "Refresh after local settlement changed only the store revision")
        let next = BackendForm(id: "frm_next", sessionID: "global", title: "Next", fields: form.fields)
        var reads = 0
        service.loadAsync = { _ in
            reads += 1
            if reads == 1 { await gate.wait() } else { refreshed.fulfill() }
            return .init(location: self.a, forms: [self.form, next])
        }
        let task = Task { await facade.hydrate(a) }
        await gate.started()
        await facade.cancel(form, at: a)
        gate.resume()
        await task.value
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(facade.pending(for: a).map(\.id), [next.id])
        XCTAssertEqual(service.cancels.count, 1)
    }

    func testCancelledStaleInventoryDoesNotScheduleRetry() async {
        let facade = GlobalFormsFacade()
        let service = GlobalFormFake(location: a)
        facade.configure(connection(service))
        defer { facade.configure(nil) }
        facade.receive(location: a, event: .created(form))
        let gate = GlobalFormGate()
        var reads = 0
        service.loadAsync = { _ in
            reads += 1
            await gate.wait()
            return .init(location: self.a, forms: [self.form])
        }
        let task = Task { await facade.hydrate(a) }
        await gate.started()
        await facade.cancel(form, at: a)
        task.cancel()
        gate.resume()
        await task.value
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(facade.pending(for: a).isEmpty)
    }

    func testGlobalInputGatePreservesBusyInterruptAndActiveAudioStopControls() {
        var policy = MessageComposerInputPolicy(blocksNewInput: true, isBusy: true, hasDraftContent: true,
            isDictating: false, isConversationActive: false, attachmentCount: 0)
        XCTAssertFalse(policy.canSend)
        XCTAssertTrue(policy.canStop)
        XCTAssertFalse(policy.canToggleDictation)
        XCTAssertFalse(policy.canToggleConversation)
        policy.isDictating = true
        XCTAssertTrue(policy.canToggleDictation, "An active dictation must remain stoppable")
        policy.isConversationActive = true
        XCTAssertTrue(policy.canToggleConversation, "An active conversation must remain stoppable")
        policy.isBusy = false
        XCTAssertFalse(policy.canStop)
        XCTAssertFalse(policy.canSend)
        policy.blocksNewInput = false
        XCTAssertTrue(policy.canSend)
    }
}

@MainActor private final class GlobalFormFake: BackendGlobalFormsService {
    let location: BackendFormLocation
    var load: (() -> BackendGlobalFormInventory)?
    var loadAsync: ((BackendScope) async -> BackendGlobalFormInventory)?
    var gate: GlobalFormGate?
    var replies: [BackendFormReference] = []
    var answers: [BackendFormAnswer] = []
    var cancels: [BackendFormReference] = []
    var stateReads: [BackendFormReference] = []
    var replyError: Error?
    var state: BackendFormState = .pending
    init(location: BackendFormLocation) { self.location = location }
    func pendingGlobalForms(scope: BackendScope) async throws -> BackendGlobalFormInventory {
        if let loadAsync { return await loadAsync(scope) }
        let value = load?() ?? .init(location: location, forms: [])
        if let gate, scope.directory != nil { await gate.wait() }
        return value
    }
    func pendingForms(sessionID: String, scope: BackendScope) async throws -> [BackendForm] { XCTFail("Not a session inventory"); return [] }
    func readForm(_ reference: BackendFormReference) async throws -> BackendForm { throw BackendSessionFormsError.unavailable }
    func readState(_ reference: BackendFormReference) async throws -> BackendFormState { stateReads.append(reference); return state }
    func reply(_ reference: BackendFormReference, answer: BackendFormAnswer) async throws {
        replies.append(reference); answers.append(answer)
        if let replyError { throw replyError }
    }
    func cancel(_ reference: BackendFormReference) async throws { cancels.append(reference) }
}

@MainActor private final class GlobalFormEvents: BackendEventSource {
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) {}
    func stop() {}
}

@MainActor private final class GlobalFormGate {
    var waiting: CheckedContinuation<Void, Never>?
    var start: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiting = $0; start?.resume(); start = nil } }
    func started() async { if waiting == nil { await withCheckedContinuation { start = $0 } } }
    func resume() { waiting?.resume(); waiting = nil }
}
