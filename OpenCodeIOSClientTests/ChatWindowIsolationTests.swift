import XCTest
@testable import OpenClient

@MainActor
final class ChatWindowIsolationTests: XCTestCase {
    private func fixture() -> (AppViewModel, WindowBackend) {
        let backend = WindowBackend()
        let model = AppViewModel()
        model.connectionStore.backendMode = .server
        model.connectionStore.isConnected = true
        model.backendConnection = backend.connection()
        model.commerceFacade.store.debugEntitlementOverride = .unlocked
        model.startEventStream()
        return (model, backend)
    }

    private func facade(_ model: AppViewModel, id: String, directory: String = "/repo", workspace: String? = nil) -> ChatFacade {
        let session = OpenCodeSession(id: id, title: id, workspaceID: workspace, directory: directory, projectID: "project", parentID: nil)
        let owner = model.directoryStoreRegistry.store(for: directory)
        owner.insertV2Session(session)
        return ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
            connection: model.backendConnection!, session: session, owner: owner))
    }

    func testTwoFacadesShareCanonicalIdentityButNotSelectionDraftsFocusOrBrowser() async throws {
        for directory in ["/repo", "/other"] {
            let (model, backend) = fixture()
            let rootStops = backend.stops
            defer { model.disconnect() }
            let a = facade(model, id: "a")
            let b = facade(model, id: "b", directory: directory, workspace: "workspace-b")
            defer { a.windowContext?.close(); b.windowContext?.close() }
            let selected = model.selectedSession
            let active = model.directoryStoreRegistry.activeStore
            a.saveMessageDraft("draft A", forSessionID: "a")
            b.saveMessageDraft("draft B", forSessionID: "b")
            a.setComposerStreamingFocus(true)
            XCTAssertEqual(a.composerStore.draftMessage, "draft A")
            XCTAssertEqual(b.composerStore.draftMessage, "draft B")
            XCTAssertTrue(a.composerStore.isStreamingFocused)
            XCTAssertFalse(b.composerStore.isStreamingFocused)
            XCTAssertFalse(a.composerStore === b.composerStore)
            XCTAssertFalse(a.windowContext!.browser === b.windowContext!.browser)
            XCTAssertTrue(a.chatStore === b.chatStore)
            XCTAssertTrue(a.directoryStore(forSessionID: "a") === model.directoryStoreRegistry.store(for: "/repo"))
            XCTAssertTrue(b.directoryStore(forSessionID: "b") === model.directoryStoreRegistry.store(for: directory))
            async let hydrateA: Void = a.hydrateSessionForPresentation(a.selectedSession!)
            async let hydrateB: Void = b.hydrateSessionForPresentation(b.selectedSession!)
            _ = await (hydrateA, hydrateB)
            XCTAssertEqual(a.presentationMessages.first?.parts.first?.text, "answer a")
            XCTAssertEqual(b.presentationMessages.first?.parts.first?.text, "answer b")
            XCTAssertTrue(backend.scopes.contains(.init(projectID: "project", directory: directory, workspaceID: "workspace-b")))
            XCTAssertEqual(model.selectedSession, selected)
            XCTAssertTrue(model.directoryStoreRegistry.activeStore === active)
            XCTAssertEqual(backend.starts, 1)
            a.windowContext?.close()
            XCTAssertTrue(b.windowContext!.isCurrent)
            XCTAssertEqual(backend.stops, rootStops)
        }
    }

    func testNavigationInOneWindowDoesNotInvalidateOtherHydrationAndRetainsAttachments() async throws {
        let (model, backend) = fixture()
        defer { model.disconnect() }
        let a = facade(model, id: "a")
        let b = facade(model, id: "b", directory: "/other")
        defer { a.windowContext?.close(); b.windowContext?.close() }
        let c = facade(model, id: "c")
        defer { c.windowContext?.close() }
        let started = expectation(description: "B read suspended")
        var release: CheckedContinuation<Void, Never>?
        backend.beforeRead = { id in
            if id == "b" { await withCheckedContinuation { release = $0; started.fulfill() } }
        }
        let pending = Task { await b.hydrateSessionForPresentation(b.selectedSession!) }
        await fulfillment(of: [started], timeout: 2)
        a.saveMessageDraft("keep A", forSessionID: "a")
        let attachment = OpenCodeComposerAttachment(id: "attachment", kind: .file, filename: "a.txt",
            mime: "text/plain", dataURL: "data:text/plain;base64,QQ==")
        a.addDraftAttachments([attachment])
        let old = a.selectedSession!
        await a.selectSession(c.selectedSession!)
        XCTAssertTrue(a.composerStore.draftAttachments.isEmpty)
        XCTAssertTrue(b.composerStore.draftAttachments.isEmpty)
        a.saveMessageDraft("keep C", forSessionID: "c")
        model.sessionNavigationGeneration &+= 1
        release?.resume()
        await pending.value
        XCTAssertEqual(b.presentationMessages.first?.info.sessionID, "b")
        XCTAssertFalse(b.isLoadingPresentation)
        await a.selectSession(old)
        XCTAssertEqual(a.composerStore.draftMessage, "keep A")
        XCTAssertEqual(a.composerStore.draftAttachments, [attachment])
        XCTAssertEqual(b.selectedSession?.id, "b")
        XCTAssertEqual(a.advanceSessionSwitcher(from: "a")?.id, "c")
        a.windowContext?.revealSessionSwitcher()
        XCTAssertEqual(a.sessionSwitcherPresentation?.selectedSessionID, "c")
        XCTAssertNil(b.sessionSwitcherPresentation)
        XCTAssertNil(model.directoryStore.sessionSwitcherPresentation)
    }

    func testConnectionReplacementInvalidatesReadsActionsFormsAndAudioWithoutStoppingRoot() async throws {
        let (model, backend) = fixture()
        defer { model.disconnect() }
        let a = facade(model, id: "a")
        let oldOwner = a.directoryStore(forSessionID: "a")
        let form = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"form","sessionID":"a","title":"Input","fields":[{"key":"value","type":"string"}]}"#.utf8)).backendForm
        oldOwner.sessionFormStore.upsert(form)
        XCTAssertTrue(a.allowsSessionForms)
        a.sessionFormStore(forSessionID: "a").setValue(.string("A"), fieldID: "value", for: form.key)
        var stoppedAudio = 0
        a.windowContext?.stopAudio = { stoppedAudio += 1 }
        let started = expectation(description: "Read suspended")
        var release: CheckedContinuation<Void, Never>?
        backend.beforeRead = { _ in await withCheckedContinuation { release = $0; started.fulfill() } }
        let session = a.selectedSession!
        let pending = Task { await a.hydrateSessionForPresentation(session) }
        await fulfillment(of: [started], timeout: 2)
        model.backendConnection = WindowBackend().connection()
        release?.resume()
        await pending.value
        XCTAssertTrue(a.windowContext!.isClosed)
        XCTAssertEqual(stoppedAudio, 1)
        XCTAssertTrue(oldOwner.syncState.messageEnvelopes(forSessionID: "a").isEmpty)
        XCTAssertTrue(a.presentationMessages.isEmpty)
        let sent = await a.sendMessage("stale", in: session, userVisible: true, meterPrompt: false)
        XCTAssertFalse(sent)
        XCTAssertTrue(backend.submissions.isEmpty)
        await a.submitSessionForm(form)
        XCTAssertFalse(a.allowsSessionForms)
        XCTAssertEqual(backend.formReplies, 0)
    }

    func testClosingWindowADoesNotCancelWindowBRead() async {
        let (model, backend) = fixture()
        defer { model.disconnect() }
        let a = facade(model, id: "a")
        let b = facade(model, id: "b")
        defer { b.windowContext?.close() }
        let started = expectation(description: "B read suspended")
        var release: CheckedContinuation<Void, Never>?
        backend.beforeRead = { _ in await withCheckedContinuation { release = $0; started.fulfill() } }
        let pending = Task { await b.hydrateSessionForPresentation(b.selectedSession!) }
        await fulfillment(of: [started], timeout: 2)
        a.windowContext?.close()
        XCTAssertTrue(b.isLoadingPresentation)
        release?.resume()
        await pending.value
        XCTAssertEqual(b.presentationMessages.first?.parts.first?.text, "answer b")
        XCTAssertFalse(b.isLoadingPresentation)
        XCTAssertEqual(backend.starts, 1)
    }

    func testOneReductionIsVisibleInBothWindowsAndClosingEitherDoesNotStopSSE() async throws {
        let (model, backend) = fixture()
        let rootStops = backend.stops
        defer { model.disconnect() }
        let a = facade(model, id: "same")
        let b = facade(model, id: "same")
        await a.hydrateSessionForPresentation(a.selectedSession!)
        let owner = a.directoryStore(forSessionID: "same")
        let version = owner.syncStore.version
        backend.receive?(.mutation(directory: "/repo", event: .messagePartDelta(sessionID: "same",
            messageID: "message-same", partID: "part-same", field: "text", delta: "!")))
        for _ in 0..<20 where owner.syncStore.version == version { await Task.yield() }
        XCTAssertEqual(a.presentationMessages.first?.parts.first?.text, "answer same!")
        XCTAssertEqual(b.presentationMessages, a.presentationMessages)
        XCTAssertEqual(owner.syncStore.version, version + 1)
        a.windowContext?.close()
        b.windowContext?.close()
        XCTAssertEqual(backend.starts, 1)
        XCTAssertEqual(backend.stops, rootStops)
    }

    func testWindowSendDoesNotClearRootOrOtherWindowDraftAndUsesCanonicalScope() async throws {
        let (model, backend) = fixture()
        defer { model.disconnect() }
        let a = facade(model, id: "a", directory: "/other", workspace: "workspace")
        let b = facade(model, id: "b")
        defer { a.windowContext?.close(); b.windowContext?.close() }
        model.composerStore.draftMessage = "root draft"
        a.saveMessageDraft("A", forSessionID: "a")
        b.saveMessageDraft("B", forSessionID: "b")
        let sent = await a.sendMessage("A", in: a.selectedSession!, userVisible: true, messageID: "send-a", meterPrompt: false)
        XCTAssertTrue(sent)
        XCTAssertEqual(backend.submissions.last?.scope, .init(projectID: "project", directory: "/other", workspaceID: "workspace"))
        XCTAssertEqual(model.composerStore.draftMessage, "root draft")
        XCTAssertEqual(b.composerStore.draftMessage, "B")
        XCTAssertEqual(a.composerStore.draftMessage, "")
    }

    func testFormEditorsShareArbitrationNotDraftsAndSettlementInvalidatesBoth() throws {
        let (model, _) = fixture()
        defer { model.disconnect() }
        let first = facade(model, id: "s")
        let second = facade(model, id: "s")
        defer { first.windowContext?.close(); second.windowContext?.close() }
        let canonical = first.directoryStore(forSessionID: "s").sessionFormStore
        let form = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"form","sessionID":"s","title":"Input","fields":[{"key":"value","type":"string"}]}"#.utf8)).backendForm
        canonical.upsert(form)
        let a = first.sessionFormStore(forSessionID: "s")
        let b = second.sessionFormStore(forSessionID: "s")
        a.setValue(.string("A"), fieldID: "value", for: form.key)
        b.setValue(.string("B"), fieldID: "value", for: form.key)
        XCTAssertEqual(a.state(for: form.key).draft["value"], .string("A"))
        XCTAssertEqual(b.state(for: form.key).draft["value"], .string("B"))
        let reference = BackendFormReference(key: form.key, directory: "/repo", workspaceID: nil, projectID: nil)
        let connection = UUID()
        XCTAssertNotNil(a.begin(.submitting, reference: reference, connectionID: connection))
        XCTAssertNil(b.begin(.submitting, reference: reference, connectionID: connection))
        a.settle(form.key)
        XCTAssertNil(canonical.forms[form.key])
        XCTAssertNil(b.forms[form.key])
        XCTAssertTrue(b.state(for: form.key).draft.isEmpty)
    }

    func testInactiveAudioOwnerCannotReleaseCurrentOwner() {
        let lease = ConversationAudioLease()
        let a = UUID(), b = UUID()
        var revoked = 0
        lease.acquire(a) { revoked += 1; lease.release(a) }
        lease.acquire(b) {}
        XCTAssertEqual(revoked, 1)
        XCTAssertFalse(lease.release(a))
        XCTAssertEqual(lease.ownerID, b)
        XCTAssertTrue(lease.release(b))
    }
}

@MainActor
private final class WindowBackend: BackendChatService, BackendSessionsService, BackendProjectsService, BackendModelsService, BackendEventSource, BackendSessionFormsService {
    var starts = 0
    var stops = 0
    var receive: (@MainActor (BackendEvent) -> Void)?
    var beforeRead: ((String) async -> Void)?
    var scopes: [BackendScope] = []
    var submissions: [BackendSubmission] = []
    var formReplies = 0
    func connection() -> BackendConnection {
        BackendConnection(descriptor: .init(id: "window-tests", name: "Windows", version: "test"),
            projects: self, sessions: self, chat: self, models: self, events: self, sessionForms: self)
    }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { starts += 1; self.receive = receive }
    func stop() { stops += 1 }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        scopes.append(scope)
        await beforeRead?(sessionID)
        return .init(messages: [.local(role: "assistant", text: "answer \(sessionID)", messageID: "message-\(sessionID)",
            sessionID: sessionID, partID: "part-\(sessionID)")])
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        submissions.append(request)
        return .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }
    func interrupt(sessionID: String, scope: BackendScope) async throws {}
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { .init() }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot { .init(projects: []) }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        .init(id: id, title: id, workspaceID: scope.workspaceID, directory: scope.directory, projectID: scope.projectID, parentID: nil)
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage { .init(sessions: []) }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws {}
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func pendingForms(sessionID: String, scope: BackendScope) async throws -> [BackendForm] { [] }
    func readForm(_ reference: BackendFormReference) async throws -> BackendForm { throw BackendSessionFormsError.unavailable }
    func readState(_ reference: BackendFormReference) async throws -> BackendFormState { .pending }
    func reply(_ reference: BackendFormReference, answer: BackendFormAnswer) async throws { formReplies += 1 }
    func cancel(_ reference: BackendFormReference) async throws {}
}
