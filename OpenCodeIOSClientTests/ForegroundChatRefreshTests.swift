import XCTest
@testable import OpenClient

@MainActor
final class ForegroundChatRefreshTests: XCTestCase {
    private var originalDraftData: Data?

    override func setUp() async throws {
        originalDraftData = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        _ = URLProtocol.registerClass(ForegroundRefreshURLProtocol.self)
    }

    override func tearDown() async throws {
        ForegroundRefreshURLProtocol.handler = nil
        URLProtocol.unregisterClass(ForegroundRefreshURLProtocol.self)
        UserDefaults.standard.set(originalDraftData, forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    func testAppForegroundReconcilesPreparedV2ChatWithHealthyRetainedStream() async throws {
        for injected in [false, true] {
            let (model, source) = makeModel(injected: injected)
            defer { model.stopEventStream(); model.backendConnection?.close() }
            let connection = try XCTUnwrap(model.backendConnection)
            let stops = source.stops
            XCTAssertEqual(model.directoryStore.sessions.map(\.id), ["ses_refresh"])
            XCTAssertEqual(model.messages.map(\.id), ["msg_old"])
            XCTAssertEqual(model.messages.first?.parts.first?.text, "old")
            XCTAssertNil(model.directoryStore.sessionStatuses["ses_refresh"])
            var paths: [String] = []
            ForegroundRefreshURLProtocol.handler = { request in
                paths.append(request.url!.path)
                return try Self.response(request)
            }

            // No ChatView, replay, or "stream open" event participates in this refresh.
            model.applicationActivityChanged(isActive: false)
            model.applicationActivityChanged(isActive: true)
            model.scheduleForegroundChatCatchUp(reason: "app scene active")
            let task = try XCTUnwrap(model.foregroundChatCatchUpTask)
            await task.value

            XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
            XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: "ses_refresh").map(\.id), ["msg_old", "msg_new"])
            XCTAssertEqual(model.messages.map { $0.parts.compactMap(\.text).joined() }, ["canonical msg_old", "canonical msg_new"])
            XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: "ses_refresh").map {
                $0.parts.compactMap(\.text).joined()
            }, ["canonical msg_old", "canonical msg_new"])
            XCTAssertEqual(model.directoryStore.sessionStatuses["ses_refresh"], "busy")
            XCTAssertEqual(model.directoryStore.sessionFormStore.forms.values.map(\.id), ["frm_refresh"])
            XCTAssertEqual(Set(paths), Set([Self.messagesPath, "/api/session/active",
                "/api/session/ses_refresh/permission", "/api/session/ses_refresh/form"]))
            XCTAssertEqual(paths.count, 4)
            XCTAssertEqual(model.backendConnection?.id, connection.id)
            XCTAssertFalse(connection.isClosed)
            XCTAssertEqual(source.starts, 1)
            XCTAssertEqual(source.stops, stops)
            XCTAssertEqual(model.backendFactory != nil, injected)
        }
    }

    func testAppAndViewActivationsCoalesceWhileSnapshotIsInFlight() async throws {
        let (model, _) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        let requested = expectation(description: "Snapshot suspended")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                reads += 1
                await withCheckedContinuation { release = $0; requested.fulfill() }
            }
            return try Self.response(request)
        }

        model.scheduleForegroundChatCatchUp(reason: "app scene active")
        model.chatFacade.scheduleForegroundChatCatchUp(reason: "chat scene active")
        let task = try XCTUnwrap(model.foregroundChatCatchUpTask)
        await fulfillment(of: [requested], timeout: 1)
        model.scheduleForegroundChatCatchUp(reason: "application did become active")
        let shared = try XCTUnwrap(model.chatFacade.scheduleForegroundChatCatchUp(reason: "chat did become active"))
        let viewWaiter = Task { await shared.value }
        viewWaiter.cancel()
        release?.resume()
        await task.value
        await viewWaiter.value

        XCTAssertFalse(shared.isCancelled)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.messages.last?.id, "msg_new")
        XCTAssertEqual(model.messages.last?.parts.first?.text, "canonical msg_new")

        // A later foreground is a new snapshot, not a permanent prepared/cooldown shortcut.
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                reads += 1
                return (200, Self.page(["msg_old", "msg_new"], textPrefix: "updated"))
            }
            return try Self.response(request)
        }
        model.scheduleForegroundChatCatchUp(reason: "next foreground")
        await model.foregroundChatCatchUpTask?.value
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
        XCTAssertEqual(model.messages.map { $0.parts.compactMap(\.text).joined() }, ["updated msg_old", "updated msg_new"])
    }

    func testReactivationStartsFreshSnapshotWhilePreviousForegroundIsSuspended() async throws {
        let (model, source) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        let requested = expectation(description: "Pre-background snapshot suspended")
        let oldResponseReturned = expectation(description: "Pre-background response returned late")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { release = $0; requested.fulfill() }
                    oldResponseReturned.fulfill()
                    return (200, Self.page(["msg_old"], textPrefix: "stale"))
                }
            }
            return try Self.response(request)
        }
        let first = try XCTUnwrap(model.scheduleForegroundChatCatchUp(reason: "first activation"))
        await fulfillment(of: [requested], timeout: 1)
        model.applicationActivityChanged(isActive: false)
        XCTAssertTrue(first.isCancelled)
        XCTAssertNil(model.foregroundChatCatchUpTask)
        model.applicationActivityChanged(isActive: true)
        let second = try XCTUnwrap(model.scheduleForegroundChatCatchUp(reason: "reactivation"))
        model.chatFacade.scheduleForegroundChatCatchUp(reason: "same reactivation view callback")
        await second.value
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
        release?.resume()
        await fulfillment(of: [oldResponseReturned], timeout: 1)
        await first.value
        XCTAssertEqual(model.messages.map { $0.parts.compactMap(\.text).joined() }, ["canonical msg_old", "canonical msg_new"])
        XCTAssertEqual(source.starts, 1)
    }

    func testLatestHTTPReadWinsAcrossInitialHydrationAndReconciliationWithoutSSE() async throws {
        for (olderInitial, newerInitial) in [(false, false), (true, false), (false, true), (true, true)] {
            let (model, _) = makeModel()
            defer { model.stopEventStream(); model.backendConnection?.close() }
            if olderInitial || newerInitial { _ = model.beginSessionNavigation(Self.session) }
            let streamRevision = model.chatStore.v2StreamRevision(sessionID: Self.session.id)
            let requested = expectation(description: "Older canonical HTTP snapshot suspended")
            var release: CheckedContinuation<Void, Never>?
            var reads = 0
            ForegroundRefreshURLProtocol.handler = { request in
                guard request.url?.path == Self.messagesPath else { return try Self.response(request) }
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { release = $0; requested.fulfill() }
                    return (200, Self.page(["msg_old"], textPrefix: "stale"))
                }
                return (200, Self.page(["msg_old", "msg_new"], textPrefix: "newest"))
            }
            let old = Task {
                if olderInitial {
                    _ = await model.hydrateV2Transcript(for: Self.session, navigationGeneration: model.sessionNavigationGeneration,
                        expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
                } else if !newerInitial {
                    await model.scheduleForegroundChatCatchUp(reason: "foreground racing event reconciliation")?.value
                } else {
                    await model.reconcileV2TimelineFromEvent(sessionID: Self.session.id)
                }
            }
            await fulfillment(of: [requested], timeout: 1)
            if newerInitial {
                _ = await model.hydrateV2Transcript(for: Self.session, navigationGeneration: model.sessionNavigationGeneration,
                    expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
            } else {
                await model.reconcileV2TimelineFromEvent(sessionID: Self.session.id)
            }
            XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
            model.errorMessage = "newer state"
            release?.resume()
            await old.value
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(model.messages.map { $0.parts.compactMap(\.text).joined() }, ["newest msg_old", "newest msg_new"])
            XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: Self.session.id), model.messages)
            XCTAssertEqual(model.chatStore.v2StreamRevision(sessionID: Self.session.id), streamRevision)
            XCTAssertEqual(model.errorMessage, "newer state")
            XCTAssertFalse(model.chatStore.isHydratingV2Transcript(sessionID: Self.session.id))
            XCTAssertNil(model.v2TimelineReconcileTask)
        }
    }

    func testFailedSupersedingReadRetriesOnceAndReleasesInitialHydration() async throws {
        let (model, _) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        _ = model.beginSessionNavigation(Self.session)
        let requested = expectation(description: "Initial read suspended")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { release = $0; requested.fulfill() }
                    return (200, Self.page(["msg_old"], textPrefix: "stale"))
                }
                return (503, "{}")
            }
            if request.url?.path == "/api/session/ses_refresh" {
                return (200, #"{"data":{"id":"ses_refresh","projectID":"global","location":{"directory":"/repo"},"time":{"created":1,"updated":2},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
            }
            return try Self.response(request)
        }
        let initial = Task {
            await model.hydrateV2Transcript(for: Self.session, navigationGeneration: model.sessionNavigationGeneration,
                expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        }
        await fulfillment(of: [requested], timeout: 1)
        await model.reconcileV2TimelineFromEvent(sessionID: Self.session.id)
        let retry = try XCTUnwrap(model.v2TimelineReconcileTask)
        await retry.value
        release?.resume()
        _ = await initial.value
        XCTAssertEqual(reads, 3)
        XCTAssertFalse(model.chatStore.isHydratingV2Transcript(sessionID: Self.session.id))
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
        XCTAssertFalse(model.messages.contains { $0.parts.first?.text == "stale msg_old" })
        XCTAssertNil(model.v2TimelineReconcileTask)
        XCTAssertTrue(model.directoryStoreRegistry.v2PendingSessionIDs.isEmpty)

        // A later real trigger can recover failed initial hydration; the retry bound is not a dead end.
        ForegroundRefreshURLProtocol.handler = { try Self.response($0) }
        await model.reconcileV2TimelineFromEvent(sessionID: Self.session.id)
        XCTAssertEqual(model.chatStore.preparedSessionID, Self.session.id)
        XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
        XCTAssertFalse(model.chatStore.isHydratingV2Transcript(sessionID: Self.session.id))
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
    }

    func testOlderHistoryCannotApplyAcrossANewerCanonicalHTTPSnapshot() async throws {
        let (model, _) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        let cached = model.messages
        model.chatStore.beginV2TranscriptHydration(sessionID: Self.session.id)
        model.chatStore.applyInitialV2Transcript(cached, olderCursor: "older", sessionID: Self.session.id)
        let requested = expectation(description: "History request suspended")
        var release: CheckedContinuation<Void, Never>?
        ForegroundRefreshURLProtocol.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            if query?.contains(URLQueryItem(name: "cursor", value: "older")) == true {
                await withCheckedContinuation { release = $0; requested.fulfill() }
                return (200, Self.page(["msg_reverted"]))
            }
            return try Self.response(request)
        }
        let older = Task { await model.loadOlderV2Messages(sessionID: Self.session.id) }
        await fulfillment(of: [requested], timeout: 1)
        await model.reconcileV2TimelineFromEvent(sessionID: Self.session.id)
        release?.resume()
        let accepted = await older.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.messages.map(\.id), ["msg_old", "msg_new"])
        XCTAssertFalse(model.chatStore.isLoadingOlderV2Messages(sessionID: Self.session.id))
    }

    func testCanonicalHTTPGenerationsAreSessionLocalAndRecoveryIsBounded() {
        let store = ChatStore()
        let first = store.beginV2CanonicalRead(sessionID: "a")
        let other = store.beginV2CanonicalRead(sessionID: "b")
        let second = store.beginV2CanonicalRead(sessionID: "a")
        XCTAssertFalse(store.isCurrentV2CanonicalRead(first, sessionID: "a"))
        XCTAssertTrue(store.isCurrentV2CanonicalRead(other, sessionID: "b"))
        XCTAssertFalse(store.finishV2CanonicalRead(first, sessionID: "a", applied: true, needsRetry: false))
        XCTAssertTrue(store.finishV2CanonicalRead(second, sessionID: "a", applied: false, needsRetry: false))
        let retry = store.beginV2CanonicalRead(sessionID: "a")
        XCTAssertFalse(store.finishV2CanonicalRead(retry, sessionID: "a", applied: false, needsRetry: true))
        XCTAssertEqual(store.v2StreamRevision(sessionID: "a"), 0)
        store.clearCachedMessages(forSessionID: "a")
        XCTAssertFalse(store.isCurrentV2CanonicalRead(retry, sessionID: "a"))
        XCTAssertTrue(store.isCurrentV2CanonicalRead(other, sessionID: "b"))
    }

    func testQueuedForegroundRejectsNavigationAndSameURLConnectionReplacement() async throws {
        for replaceConnection in [false, true] {
            let (model, _) = makeModel()
            defer { model.stopEventStream(); model.backendConnection?.close() }
            ForegroundRefreshURLProtocol.handler = { request in
                XCTFail("Stale queued context must not read: \(request.url!.path)")
                return (500, "{}")
            }
            model.scheduleForegroundChatCatchUp(reason: "queued")
            let task = try XCTUnwrap(model.foregroundChatCatchUpTask)
            if replaceConnection {
                replaceRetainedConnection(model)
            } else {
                _ = model.beginSessionNavigation(Self.otherSession)
            }
            await task.value
            XCTAssertFalse(model.messages.contains { $0.id == "msg_new" })
        }
    }

    func testInFlightForegroundRejectsNavigationAndSameURLConnectionReplacement() async throws {
        for replaceConnection in [false, true] {
            let (model, _) = makeModel(injected: true)
            defer { model.stopEventStream(); model.backendConnection?.close() }
            let owner = model.directoryStore
            var paths: [String] = []
            ForegroundRefreshURLProtocol.handler = { request in
                paths.append(request.url!.path)
                XCTAssertEqual(request.url?.path, Self.messagesPath)
                if replaceConnection {
                    self.replaceRetainedConnection(model)
                } else {
                    _ = model.beginSessionNavigation(Self.otherSession)
                }
                model.errorMessage = "new context"
                return try Self.response(request)
            }
            model.scheduleForegroundChatCatchUp(reason: "in flight")
            await model.foregroundChatCatchUpTask?.value

            XCTAssertEqual(paths, [Self.messagesPath])
            XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: "ses_refresh").map(\.id), ["msg_old"])
            XCTAssertFalse(model.messages.contains { $0.id == "msg_new" })
            XCTAssertEqual(model.errorMessage, "new context")
            XCTAssertTrue(owner.sessionFormStore.forms.isEmpty)
        }
    }

    func testNewNavigationCanScheduleWhileOldSnapshotIsSuspended() async throws {
        let (model, _) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        let requested = expectation(description: "Old snapshot suspended")
        var release: CheckedContinuation<Void, Never>?
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                await withCheckedContinuation { release = $0; requested.fulfill() }
                throw CancellationError()
            }
            if request.url?.path == "/api/session/ses_other/message" {
                return (200, Self.page(["msg_other"]))
            }
            if request.url?.path == "/api/session/active" { return (200, #"{"data":{}}"#) }
            return (200, #"{"data":[]}"#)
        }
        model.scheduleForegroundChatCatchUp(reason: "old navigation")
        let oldTask = try XCTUnwrap(model.foregroundChatCatchUpTask)
        await fulfillment(of: [requested], timeout: 1)
        _ = model.beginSessionNavigation(Self.otherSession)
        model.chatFacade.scheduleForegroundChatCatchUp(reason: "new navigation")
        let newTask = try XCTUnwrap(model.foregroundChatCatchUpTask)
        release?.resume()
        await oldTask.value
        await newTask.value

        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertEqual(model.selectedSession?.id, "ses_other")
        XCTAssertEqual(model.messages.map(\.id), ["msg_other"])
    }

    func testStatusFailureDoesNotPreventTranscriptOrFormRefresh() async {
        let (model, _) = makeModel()
        defer { model.stopEventStream(); model.backendConnection?.close() }
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == "/api/session/active" { return (503, "{}") }
            return try Self.response(request)
        }
        model.scheduleForegroundChatCatchUp(reason: "status unavailable")
        await model.foregroundChatCatchUpTask?.value
        XCTAssertEqual(model.messages.last?.id, "msg_new")
        XCTAssertEqual(model.messages.last?.parts.first?.text, "canonical msg_new")
        XCTAssertEqual(model.directoryStore.sessionFormStore.forms.values.map(\.id), ["frm_refresh"])
    }

    func testFreshConnectionInitialSelectionAndReopenStillReadCanonicalTranscript() async {
        let (model, _) = makeModel(prepared: false)
        defer { model.stopEventStream(); model.backendConnection?.close() }
        var reads = 0
        ForegroundRefreshURLProtocol.handler = { request in
            if request.url?.path == Self.messagesPath {
                reads += 1
                return (200, Self.page([reads == 1 ? "msg_fresh" : "msg_reopened"]))
            }
            return try Self.response(request)
        }

        await model.chatFacade.selectSession(Self.session)
        XCTAssertEqual(model.messages.map(\.id), ["msg_fresh"])
        _ = model.beginSessionNavigation(Self.otherSession)
        await model.chatFacade.selectSession(Self.session)
        XCTAssertEqual(model.messages.map(\.id), ["msg_reopened"])
        XCTAssertEqual(reads, 2)
    }

    private static let messagesPath = "/api/session/ses_refresh/message"
    private static var session: OpenCodeSession {
        .init(id: "ses_refresh", title: nil, workspaceID: nil, directory: "/repo", projectID: nil, parentID: nil)
    }
    private static var otherSession: OpenCodeSession {
        .init(id: "ses_other", title: nil, workspaceID: nil, directory: "/other", projectID: nil, parentID: nil)
    }

    private func makeModel(injected: Bool = false, prepared: Bool = true) -> (AppViewModel, ForegroundRefreshEventSource) {
        let config = OpenCodeServerConfig(baseURL: "https://foreground-refresh.invalid", apiPreference: .v2)
        let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: config), eventManager: OpenCodeEventManager())
        let model = AppViewModel(backendFactory: injected ? factory : nil)
        model.config = config
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        // Keep real OpenCode factory services; replace only the live transport with a silent healthy source.
        let services = factory.makeConnection(profile: .v2, version: "test", healthy: true)
        let source = ForegroundRefreshEventSource()
        model.backendConnection = BackendConnection(descriptor: services.descriptor, capabilities: services.capabilities,
            projects: services.projects, sessions: services.sessions, chat: services.chat, models: services.models, events: source)
        model.directoryStoreRegistry.activate("/repo")
        model.directoryStore.insertV2Session(Self.session)
        if prepared {
            _ = model.beginSessionNavigation(Self.session)
            let old = OpenCodeMessageEnvelope.local(role: "user", text: "old", messageID: "msg_old", sessionID: Self.session.id)
            model.chatStore.applyInitialV2Transcript([old], olderCursor: nil, sessionID: Self.session.id)
            model.directoryStore.applyV2Messages([old], forSessionID: Self.session.id)
        }
        model.startEventStream()
        return (model, source)
    }

    private func replaceRetainedConnection(_ model: AppViewModel) {
        model.backendConnection?.close()
        model.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: model.config), eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "test", healthy: true)
    }

    private static func response(_ request: URLRequest) throws -> (Int, String) {
        XCTAssertEqual(request.httpMethod, "GET")
        switch request.url?.path {
        case messagesPath:
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: "200"),
            ])
            return (200, page(["msg_old", "msg_new"]))
        case "/api/session/active": return (200, #"{"data":{"ses_refresh":{"type":"running"}}}"#)
        case "/api/session/ses_refresh/permission": return (200, #"{"data":[]}"#)
        case "/api/session/ses_refresh/form":
            return (200, #"{"data":[{"id":"frm_refresh","sessionID":"ses_refresh","title":"Fixture","fields":[{"key":"name","type":"string"}]}]}"#)
        default:
            XCTFail("Unexpected request: \(request.url!.path)")
            throw URLError(.unsupportedURL)
        }
    }

    private static func page(_ chronologicalIDs: [String], textPrefix: String = "canonical") -> String {
        // V2 returns newest first for order=desc; the client reverses this wire page for display.
        let records = chronologicalIDs.enumerated().reversed().map { index, id in
            #"{"id":"\#(id)","type":"user","text":"\#(textPrefix) \#(id)","time":{"created":\#((index + 1) * 1_000)}}"#
        }.joined(separator: ",")
        return #"{"data":[\#(records)],"cursor":{}}"#
    }
}

@MainActor
private final class ForegroundRefreshEventSource: BackendEventSource {
    var starts = 0
    var stops = 0
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) {
        starts += 1
        receive(.status("healthy retained stream"))
    }
    func stop() { stops += 1 }
}

private final class ForegroundRefreshURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: ForegroundRefreshURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "foreground-refresh.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}
