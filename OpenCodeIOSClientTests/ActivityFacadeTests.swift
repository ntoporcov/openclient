import Combine
import XCTest
import UIKit
import SwiftUI
@testable import OpenClient

private final class ActivityMetadataURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/api/session/active":
            body = #"{"data":{"home-session":{"type":"running"},"sandbox-session":{"type":"running"}}}"#
        case "/api/permission/request":
            body = #"{"data":[]}"#
        case "/api/form":
            let directory = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first { $0.name == "location[directory]" }?.value
            body = directory == "/home-sandbox"
                ? #"{"location":{"directory":"/home-sandbox","project":{"id":"project","directory":"/home-sandbox","canonical":"/home"}},"data":[{"id":"external-form","sessionID":"sandbox-session","title":"Authenticate","fields":[{"key":"auth","type":"external","required":true}]}]}"#
                : #"{"location":{"directory":"/home","project":{"id":"project","directory":"/home","canonical":"/home"}},"data":[]}"#
        default:
            XCTFail("Activity must not call legacy routes or bypass core session/transcript services: \(request.url?.path ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class ActivityLegacyMetadataURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/session/status":
            body = #"{"home-session":{"type":"busy"},"sandbox-session":{"type":"busy"}}"#
        case "/permission", "/question", "/session/preload-0/todo":
            body = "[]"
        default:
            XCTFail("Unexpected legacy Activity request: \(request.url?.path ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ActivityPreloadChatBackend: BackendChatService {
    struct Request: Equatable {
        let sessionID: String
        let scope: BackendScope
        let cursor: String?
        let limit: Int
    }

    var requests: [Request] = []
    var gatedSessionID: String?
    var onSuspension: (() -> Void)?
    var onReturn: (() -> Void)?
    var transcriptFailuresRemaining = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        requests.append(.init(sessionID: sessionID, scope: scope, cursor: cursor, limit: limit))
        if transcriptFailuresRemaining > 0 {
            transcriptFailuresRemaining -= 1
            throw URLError(.timedOut)
        }
        let foreground = limit == 200
        let page = BackendTranscriptPage(messages: [
            .local(role: "user", text: "Prompt for \(sessionID)", messageID: "z-user-\(sessionID)", sessionID: sessionID),
            .local(role: "assistant", text: "\(foreground ? "Foreground" : "Preloaded") \(sessionID)",
                messageID: "a-answer-\(sessionID)", sessionID: sessionID),
        ], olderCursor: foreground ? "foreground-older" : "preload-older")
        if gatedSessionID == sessionID, !foreground {
            gatedSessionID = nil
            // Deliberately ignore cancellation so a late HTTP success can exercise the commit guards.
            await withCheckedContinuation {
                continuation = $0
                onSuspension?()
            }
        }
        onReturn?()
        return page
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        XCTFail("Activity preloading must not submit prompts")
        throw BackendError.disconnected
    }

    func interrupt(sessionID: String, scope: BackendScope) async throws {
        XCTFail("Activity preloading must not interrupt sessions")
        throw BackendError.disconnected
    }
}

@MainActor
final class ActivityFacadeTests: XCTestCase {
    func testInjectedBackendDoesNotAdvertiseActivityWithoutStatusService() async throws {
        let viewModel = AppViewModel(backendFactory: HomeTestBackend())
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }

        XCTAssertFalse(viewModel.activityFacade.isAvailable)
        XCTAssertFalse(viewModel.projectFacade.allowsActivity)
        viewModel.appShellFacade.selectActivity()
        XCTAssertFalse(viewModel.appShellFacade.isActivitySelected)
        await viewModel.activityFacade.prepareForPresentation()
        XCTAssertTrue(viewModel.activityFacade.snapshot.isEmpty)
    }

    func testV2ActivityLoadsCatalogScopesAndCanonicalStatusAndPreview() async throws {
        let backend = HomeTestBackend()
        backend.storedSessions.append(.init(id: "sandbox-session", title: "Sandbox work", workspaceID: nil,
            directory: "/home-sandbox", projectID: "home-project", parentID: nil))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://activity.invalid", password: "test"), session: session)
        let adapter = OpenCodeBackendAdapter(client: client, profile: .v2)
        let viewModel = AppViewModel(backendFactory: backend)
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: "activity-test", name: "OpenCode", version: "next"),
            capabilities: [.interactions], projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        viewModel.projects = try await backend.projectsSnapshot().projects
        defer { viewModel.disconnect() }

        XCTAssertTrue(viewModel.activityFacade.isAvailable)
        viewModel.appShellFacade.selectActivity()
        XCTAssertEqual(viewModel.appShellFacade.contentRoute(isCompact: true), .activity)
        await viewModel.activityFacade.prepareForPresentation()

        XCTAssertTrue(backend.listScopes.contains(.init(projectID: "global", directory: nil)))
        XCTAssertTrue(backend.listScopes.contains(.init(projectID: "home-project", directory: "/home-sandbox")))
        XCTAssertEqual(viewModel.activityFacade.snapshot.workingRows.map(\.recent.session.id), ["home-session"])
        XCTAssertEqual(viewModel.activityFacade.snapshot.needsInputRows.map(\.recent.session.id), ["sandbox-session"])
        XCTAssertEqual(viewModel.activityFacade.snapshot.needsInputRows.first?.pendingInteractionCount, 1)
        XCTAssertTrue(viewModel.directoryStoreRegistry.store(for: nil).v2FormsByID.isEmpty)
        let row = try XCTUnwrap(viewModel.activityFacade.snapshot.workingRows.first { $0.recent.session.id == "home-session" })
        await viewModel.activityFacade.hydrateIfNeeded(row)

        let hydrated = try XCTUnwrap(viewModel.activityFacade.snapshot.workingRows.first { $0.recent.session.id == "home-session" })
        XCTAssertEqual(hydrated.latestAssistantText, "Backend preview")
        XCTAssertEqual(viewModel.sessionPreviews["home-session"]?.text, "Backend preview")
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)

        let listRequestCount = backend.listScopes.count
        let liveRow = expectation(description: "Activity observes live directory sessions without refreshing")
        let observation = viewModel.activityFacade.$snapshot
            .filter { $0.workingRows.contains { $0.recent.session.id == "live-created" } }
            .prefix(1)
            .sink { _ in liveRow.fulfill() }
        let owner = viewModel.directoryStoreRegistry.store(for: "/home-project")
        owner.insertV2Session(.init(id: "live-created", title: "Live creation", workspaceID: nil,
            directory: "/home-project", projectID: "home-project", parentID: nil))
        owner.applySessionStatus("busy", forSessionID: "live-created")
        await fulfillment(of: [liveRow], timeout: 1)
        XCTAssertEqual(backend.listScopes.count, listRequestCount)
        withExtendedLifetime(observation) {}
    }

    func testPreparationEagerlyPreloadsEveryLiteralRecentInitialPageWithoutRowHydration() async throws {
        let recent = makePreloadSessions(count: 21)
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let older = try [1, 4, 8].map { days in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: today))
            return makeSession(id: "older-\(days)", title: "Older", directory: "/home-project",
                projectID: "home-project", updated: date.timeIntervalSince1970 * 1_000)
        }
        let (viewModel, backend, chat) = try await makePreloadFixture(sessions: recent + older)
        let navigationGeneration = viewModel.sessionNavigationGeneration

        await viewModel.activityFacade.prepareForPresentation()

        XCTAssertEqual(chat.requests.count, recent.count, "All offscreen Recent cards must preload, not just the first five")
        XCTAssertEqual(Set(chat.requests.map(\.sessionID)), Set(recent.map(\.id)))
        XCTAssertEqual(backend.listScopes.count, 3)
        XCTAssertTrue(chat.requests.allSatisfy { $0.cursor == nil && $0.limit == 20 },
            "Preloading must fetch only the initial page even when an older cursor is returned")
        let snapshot = viewModel.activityFacade.snapshot
        XCTAssertEqual(snapshot.workingRows.map(\.recent.session.id), ["home-session"])
        XCTAssertEqual(snapshot.needsInputRows.map(\.recent.session.id), ["sandbox-session"])
        XCTAssertEqual(Set(snapshot.recentRows.map(\.recent.session.id)), Set((recent + older).map(\.id)))
        for session in recent {
            let request = try XCTUnwrap(chat.requests.first { $0.sessionID == session.id })
            XCTAssertEqual(request.scope, .init(projectID: session.projectID, directory: session.directory))
            let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: session.directory))
            let messages = owner.syncState.messageEnvelopes(forSessionID: session.id)
            XCTAssertEqual(messages.map(\.id), ["z-user-\(session.id)", "a-answer-\(session.id)"],
                "The backend's v2 transcript order must survive cache seeding")
            XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[session.id], messages)
            XCTAssertEqual(viewModel.sessionPreviews[session.id]?.text, "Preloaded \(session.id)")
            let row = try XCTUnwrap(snapshot.recentRows.first { $0.recent.session.id == session.id })
            XCTAssertEqual(row.latestUserText, "Prompt for \(session.id)")
            XCTAssertEqual(row.latestAssistantText, "Preloaded \(session.id)")
            XCTAssertFalse(row.isHydrating)
            XCTAssertFalse(viewModel.chatStore.isHydratingV2Transcript(sessionID: session.id))
            XCTAssertEqual(viewModel.chatStore.v2StreamRevision(sessionID: session.id), 0)
        }
        for id in older.map(\.id) + ["home-session", "sandbox-session"] {
            XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[id])
            XCTAssertNil(viewModel.sessionPreviews[id])
        }
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.chatStore.v2TranscriptStates.isEmpty)
        XCTAssertFalse(viewModel.isLoadingSelectedSession)
        XCTAssertEqual(viewModel.sessionNavigationGeneration, navigationGeneration)
    }

    func testRepeatedPreparationAndVisibleRowHydrationJoinTheEagerPreload() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, backend, chat) = try await makePreloadFixture(sessions: sessions)
        let suspended = expectation(description: "Eager preload suspended")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let row = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)
        let joined = expectation(description: "Both callers join the suspended preload")
        joined.expectedFulfillmentCount = 2
        let repeatedPreparation = Task {
            joined.fulfill()
            await viewModel.activityFacade.prepareForPresentation()
        }
        let rowHydration = Task {
            joined.fulfill()
            await viewModel.activityFacade.hydrateIfNeeded(row)
        }
        await fulfillment(of: [joined], timeout: 1)
        XCTAssertEqual(chat.requests.count, 1)
        XCTAssertEqual(backend.listScopes.count, 3)

        chat.release()
        await preparation.value
        await repeatedPreparation.value
        await rowHydration.value
        await viewModel.activityFacade.prepareForPresentation()
        let hydratedRow = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)
        await viewModel.activityFacade.hydrateIfNeeded(hydratedRow)

        XCTAssertEqual(chat.requests.count, 1)
        XCTAssertEqual(backend.listScopes.count, 3)
        XCTAssertEqual(hydratedRow.latestAssistantText, "Preloaded \(target.id)")
        XCTAssertFalse(hydratedRow.isHydrating)
    }

    func testEagerPreloadCannotResurrectADeletedSession() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
        let suspended = expectation(description: "Preload suspended before deletion")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let row = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)
        let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))

        await viewModel.activityFacade.delete(row)
        XCTAssertTrue(viewModel.directoryStoreRegistry.isV2SessionDeleted(target.id))
        chat.release()
        await preparation.value

        XCTAssertNil(viewModel.directoryStoreRegistry.session(matching: target.id))
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty)
        XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[target.id])
        XCTAssertNil(viewModel.sessionPreviews[target.id])
        XCTAssertFalse(viewModel.activityFacade.snapshot.recentRows.contains { $0.recent.session.id == target.id })
        XCTAssertEqual(chat.requests.count, 1)
    }

    func testEagerPreloadDropsAResponseAfterAStreamRevisionEvenWithoutMessageChanges() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
        let suspended = expectation(description: "Preload suspended before stream event")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))
        let revision = viewModel.chatStore.v2StreamRevision(sessionID: target.id)
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            """
            {"type":"session.input.cancelled","data":{"sessionID":"\(target.id)","inputID":"cancelled-input"}}
            """))

        _ = viewModel.chatStore.applyV2StreamEvent(event, sessionID: target.id)
        XCTAssertGreaterThan(viewModel.chatStore.v2StreamRevision(sessionID: target.id), revision)
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty)
        chat.release()
        await preparation.value

        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty)
        XCTAssertTrue(viewModel.chatStore.cachedMessagesBySessionID[target.id]?.isEmpty != false)
        XCTAssertNil(viewModel.sessionPreviews[target.id])
        XCTAssertNil(viewModel.activityFacade.snapshot.recentRows.first?.latestAssistantText)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertEqual(chat.requests.count, 1)
    }

    func testForegroundSelectionOwnsHydrationWhileAnEagerPreloadIsInFlight() async throws {
        for completesForeground in [false, true] {
            let sessions = makePreloadSessions(count: 1)
            let target = try XCTUnwrap(sessions.first)
            let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
            let suspended = expectation(description: "Preload suspended before foreground selection")
            chat.gatedSessionID = target.id
            chat.onSuspension = { suspended.fulfill() }
            let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
            await fulfillment(of: [suspended], timeout: 2)
            let row = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)

            viewModel.activityFacade.prepareSelection(row)
            XCTAssertEqual(viewModel.selectedSession?.id, target.id)
            XCTAssertTrue(viewModel.chatStore.isHydratingV2Transcript(sessionID: target.id))
            if completesForeground {
                let hydrated = await viewModel.hydrateV2Transcript(for: target,
                    navigationGeneration: viewModel.sessionNavigationGeneration,
                    expectedDirectoryKey: DirectoryStoreRegistry.key(for: target.directory))
                XCTAssertTrue(hydrated)
                XCTAssertEqual(viewModel.chatStore.preparedSessionID, target.id)
            }
            let owner = viewModel.directoryStore
            let directoryMessages = owner.syncState.messageEnvelopes(forSessionID: target.id)
            let cached = viewModel.chatStore.cachedMessagesBySessionID[target.id]
            let active = viewModel.messages
            let preview = viewModel.sessionPreviews[target.id]
            let generation = viewModel.sessionNavigationGeneration
            let transcriptState = viewModel.chatStore.v2TranscriptStates[target.id]
            chat.release()
            await preparation.value

            XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: target.id), directoryMessages)
            XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id], cached)
            XCTAssertEqual(viewModel.messages, active)
            XCTAssertEqual(viewModel.sessionPreviews[target.id], preview)
            XCTAssertEqual(viewModel.sessionNavigationGeneration, generation)
            XCTAssertEqual(viewModel.chatStore.v2TranscriptStates[target.id], transcriptState)
            XCTAssertEqual(viewModel.chatStore.isHydratingV2Transcript(sessionID: target.id), !completesForeground)
            XCTAssertEqual(viewModel.isLoadingSelectedSession, !completesForeground)
            XCTAssertEqual(chat.requests.map(\.limit), completesForeground ? [20, 200] : [20])
            if completesForeground {
                XCTAssertEqual(viewModel.sessionPreviews[target.id]?.text, "Foreground \(target.id)")
                XCTAssertEqual(viewModel.chatStore.v2TranscriptStates[target.id]?.olderCursor, "foreground-older")
            } else {
                XCTAssertNil(viewModel.chatStore.preparedSessionID)
                XCTAssertTrue(active.isEmpty)
            }
            viewModel.disconnect()
        }
    }

    func testDisconnectedEagerPreloadCannotRepopulateCachesWithALateSuccess() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
        let suspended = expectation(description: "Preload suspended before disconnect")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))

        viewModel.disconnect()
        let staleCache = expectation(description: "Late response must not repopulate the disconnected cache")
        staleCache.isInverted = true
        let observation = viewModel.chatStore.$cachedMessagesBySessionID
            .filter { $0[target.id]?.isEmpty == false }
            .sink { _ in staleCache.fulfill() }
        let returned = expectation(description: "Cancelled backend still returns its captured response")
        chat.onReturn = { returned.fulfill() }
        chat.release()
        await preparation.value
        await fulfillment(of: [returned], timeout: 1)
        // Disconnect releases queue waiters before cancelled workers finish, so observe a bounded rejection window.
        await fulfillment(of: [staleCache], timeout: 0.1)

        XCTAssertNil(viewModel.directoryStoreRegistry.session(matching: target.id))
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty)
        XCTAssertTrue(viewModel.chatStore.cachedMessagesBySessionID.isEmpty)
        XCTAssertNil(viewModel.sessionPreviews[target.id])
        XCTAssertTrue(viewModel.activityFacade.snapshot.isEmpty)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        withExtendedLifetime(observation) {}
    }

    func testAcceptedEagerPreloadRefreshesNonemptyChatCacheAlongsideDirectory() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
        let stale = [makeMessage(id: "stale", sessionID: target.id, role: "assistant", text: "Old cache", created: 1_000)]
        let owner = viewModel.directoryStoreRegistry.store(for: target.directory)
        owner.sessions = sessions
        owner.applyV2Messages(stale, forSessionID: target.id)
        viewModel.chatStore.cacheMessages(stale, forSessionID: target.id)
        viewModel.refreshSessionPreview(for: target.id, messages: stale)

        await viewModel.activityFacade.prepareForPresentation()

        let messages = owner.syncState.messageEnvelopes(forSessionID: target.id)
        XCTAssertEqual(messages.map(\.id), ["z-user-\(target.id)", "a-answer-\(target.id)"])
        XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id], messages)
        XCTAssertEqual(viewModel.sessionPreviews[target.id]?.text, "Preloaded \(target.id)")
        XCTAssertEqual(viewModel.activityFacade.snapshot.recentRows.first?.latestAssistantText, "Preloaded \(target.id)")
        XCTAssertEqual(chat.requests.count, 1)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.chatStore.v2TranscriptStates.isEmpty)
    }

    func testInterveningChatCacheWriteRejectsEagerPreloadWithoutAStreamRevisionChange() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: sessions)
        let previous = [makeMessage(id: "previous", sessionID: target.id, role: "assistant", text: "Previous", created: 1_000)]
        let newer = [makeMessage(id: "newer", sessionID: target.id, role: "assistant", text: "New cache writer", created: 2_000)]
        let owner = viewModel.directoryStoreRegistry.store(for: target.directory)
        owner.sessions = sessions
        owner.applyV2Messages(previous, forSessionID: target.id)
        viewModel.chatStore.cacheMessages(previous, forSessionID: target.id)
        viewModel.refreshSessionPreview(for: target.id, messages: previous)
        let suspended = expectation(description: "Preload suspended before independent cache write")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let revision = viewModel.chatStore.v2StreamRevision(sessionID: target.id)

        viewModel.chatStore.cacheMessages(newer, forSessionID: target.id)
        chat.release()
        await preparation.value

        XCTAssertEqual(viewModel.chatStore.v2StreamRevision(sessionID: target.id), revision)
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: target.id), previous)
        XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id], newer)
        XCTAssertEqual(viewModel.sessionPreviews[target.id]?.text, "Previous")
        XCTAssertEqual(viewModel.activityFacade.snapshot.recentRows.first?.latestAssistantText, "Previous")
        XCTAssertEqual(chat.requests.count, 1)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
    }

    func testEagerPreloadRejectsLiveScopeMovement() async throws {
        let target = try XCTUnwrap(makePreloadSessions(count: 1).first)
        for moved in scopeMovements(of: target) {
            let (viewModel, _, chat) = try await makePreloadFixture(sessions: [target])
            let suspended = expectation(description: "Preload suspended before live scope movement")
            chat.gatedSessionID = target.id
            chat.onSuspension = { suspended.fulfill() }
            let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
            await fulfillment(of: [suspended], timeout: 2)
            let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))

            owner.insertV2Session(moved)
            chat.release()
            await preparation.value

            XCTAssertEqual(owner.sessions.first { $0.id == target.id }, moved)
            XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty)
            XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[target.id])
            XCTAssertNil(viewModel.sessionPreviews[target.id])
            XCTAssertEqual(chat.requests.count, 1)
            XCTAssertEqual(chat.requests.first?.scope, .init(projectID: target.projectID, directory: target.directory))
            viewModel.disconnect()
        }
    }

    func testEagerPreloadRejectsCanonicalResponseScopeMovement() async throws {
        let target = try XCTUnwrap(makePreloadSessions(count: 1).first)
        for moved in scopeMovements(of: target) {
            let (viewModel, backend, chat) = try await makePreloadFixture(sessions: [target])
            // The list establishes the original scope; the subsequent detail read discovers the move.
            backend.beforeSessionFetch = {
                backend.storedSessions = backend.storedSessions.map { $0.id == target.id ? moved : $0 }
            }

            await viewModel.activityFacade.prepareForPresentation()

            let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))
            XCTAssertEqual(owner.sessions.first { $0.id == target.id }, target, "Moved detail must not be installed into the old scope")
            XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: target.id).isEmpty, "Moved scope: \(moved)")
            XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[target.id], "Moved scope: \(moved)")
            XCTAssertNil(viewModel.sessionPreviews[target.id])
            XCTAssertEqual(chat.requests.count, 1)
            XCTAssertEqual(chat.requests.first?.scope, .init(projectID: target.projectID, directory: target.directory))
            backend.beforeSessionFetch = nil
            viewModel.disconnect()
        }
    }

    func testFailedEagerPreloadCanBeRetriedByRowHydrationWithoutRepeatingPreparation() async throws {
        let sessions = makePreloadSessions(count: 1)
        let target = try XCTUnwrap(sessions.first)
        let (viewModel, backend, chat) = try await makePreloadFixture(sessions: sessions)
        chat.transcriptFailuresRemaining = 1

        await viewModel.activityFacade.prepareForPresentation()

        let failedRow = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)
        XCTAssertFalse(failedRow.isHydrating)
        XCTAssertNil(failedRow.latestAssistantText)
        XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[target.id])
        XCTAssertEqual(chat.requests.count, 1)
        await viewModel.activityFacade.prepareForPresentation()
        XCTAssertEqual(chat.requests.count, 1, "Failed eager attempts must not create an automatic retry loop")

        await viewModel.activityFacade.hydrateIfNeeded(failedRow)

        let retriedRow = try XCTUnwrap(viewModel.activityFacade.snapshot.recentRows.first)
        XCTAssertFalse(retriedRow.isHydrating)
        XCTAssertEqual(retriedRow.latestAssistantText, "Preloaded \(target.id)")
        XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id]?.count, 2)
        XCTAssertEqual(viewModel.sessionPreviews[target.id]?.text, "Preloaded \(target.id)")
        XCTAssertEqual(chat.requests.count, 2)
        await viewModel.activityFacade.hydrateIfNeeded(retriedRow)
        XCTAssertEqual(chat.requests.count, 2)
        XCTAssertEqual(backend.listScopes.count, 3)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testV2DiskTranscriptsNeverSeedCanonicalActivityStateBeforeGatedHTTP() async throws {
        let target = try XCTUnwrap(makePreloadSessions(count: 1).first)
        let calendar = Calendar.autoupdatingCurrent
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())))
        let older = makeSession(id: "disk-only-older", title: "Yesterday", directory: "/home-project",
            projectID: "home-project", updated: yesterday.timeIntervalSince1970 * 1_000)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: [target, older], usesLocalCache: true)
        let namespace = try XCTUnwrap(viewModel.localCacheNamespace)
        XCTAssertTrue(OpenCodeLocalCacheIdentity.isV2(namespace))
        let repository = viewModel.localCacheRepository
        try await repository.saveDirectorySessions([target, older], serverID: namespace,
            directory: OpenCodeLocalCacheIdentity.directory(target.directory, workspaceID: nil, namespace: namespace))
        for session in [target, older] {
            try await repository.saveChatMessages([
                makeMessage(id: "disk-\(session.id)", sessionID: session.id, role: "assistant", text: "Unvalidated disk text", created: 1_000),
            ], serverID: namespace, sessionID: session.id)
        }
        let suspended = expectation(description: "HTTP suspended after the disk hydration phase")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))

        for session in [target, older] {
            XCTAssertTrue(owner.sessions.contains { $0.id == session.id })
            XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
            XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[session.id])
            XCTAssertNil(viewModel.sessionPreviews[session.id])
            XCTAssertNil(viewModel.activityFacade.snapshot.recentRows.first { $0.recent.session.id == session.id }?.latestAssistantText)
        }
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertTrue(viewModel.chatStore.v2TranscriptStates.isEmpty)

        chat.release()
        await preparation.value

        let canonical = owner.syncState.messageEnvelopes(forSessionID: target.id)
        XCTAssertEqual(canonical.map(\.id), ["z-user-\(target.id)", "a-answer-\(target.id)"])
        XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id], canonical)
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: older.id).isEmpty)
        XCTAssertNil(viewModel.chatStore.cachedMessagesBySessionID[older.id])
        XCTAssertEqual(chat.requests.map(\.sessionID), [target.id])
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        for task in Array(viewModel.localCacheWriteTasksByKey.values) { await task.value }
    }

    func testLegacyEagerPreloadPersistsMergedHistoryInsteadOfOnlyTheHTTPPage() async throws {
        let target = try XCTUnwrap(makePreloadSessions(count: 1).first)
        let (viewModel, _, chat) = try await makePreloadFixture(sessions: [target], profile: .legacy, usesLocalCache: true)
        let namespace = try XCTUnwrap(viewModel.localCacheNamespace)
        XCTAssertFalse(OpenCodeLocalCacheIdentity.isV2(namespace))
        let repository = viewModel.localCacheRepository
        let history = [makeMessage(id: "old-history", sessionID: target.id, role: "assistant", text: "Keep old history", created: 1_000)]
        try await repository.saveDirectorySessions([target], serverID: namespace, directory: target.directory)
        try await repository.saveChatMessages(history, serverID: namespace, sessionID: target.id)
        let suspended = expectation(description: "Legacy HTTP suspended after restoring old disk history")
        chat.gatedSessionID = target.id
        chat.onSuspension = { suspended.fulfill() }
        let preparation = Task { await viewModel.activityFacade.prepareForPresentation() }
        await fulfillment(of: [suspended], timeout: 2)
        let owner = try XCTUnwrap(viewModel.directoryStoreRegistry.existingStore(for: target.directory))
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: target.id), history)

        chat.release()
        await preparation.value
        for task in Array(viewModel.localCacheWriteTasksByKey.values) { await task.value }

        let loaded = try await repository.loadChat(serverID: namespace, sessionID: target.id)
        let persisted = try XCTUnwrap(loaded)
        let expectedIDs: Set<String> = ["old-history", "z-user-\(target.id)", "a-answer-\(target.id)"]
        let merged = owner.syncState.messageEnvelopes(forSessionID: target.id)
        XCTAssertEqual(Set(merged.map(\.id)), expectedIDs)
        XCTAssertEqual(Set(persisted.messages.map(\.id)), expectedIDs)
        XCTAssertEqual(persisted.messages.first { $0.id == "old-history" }, history.first)
        XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[target.id], merged)
        XCTAssertEqual(chat.requests.count, 1)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testRecentBucketsUseCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))

        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-3_600), now: now, calendar: calendar), .recent)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-30 * 3_600), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-4 * 86_400), now: now, calendar: calendar), .lastWeek)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-8 * 86_400), now: now, calendar: calendar), .older)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: nil, now: now, calendar: calendar), .older)
    }

    func testOnlyRecentBucketUsesFullContextCards() {
        XCTAssertEqual(ActivityRecentBucket.recent.rowPresentation, .fullContext)
        XCTAssertEqual(ActivityRecentBucket.yesterday.rowPresentation, .summary)
        XCTAssertEqual(ActivityRecentBucket.lastWeek.rowPresentation, .summary)
        XCTAssertEqual(ActivityRecentBucket.older.rowPresentation, .summary)
    }

    func testActivityToolAppearanceMatchesChatMapping() {
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("bash").icon, "terminal.fill")
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("bash").tint, .green)
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("read").tint, .blue)
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("apply_patch").tint, .orange)
    }

    func testNewChatPresentationIsNotLockedToAProject() throws {
        let viewModel = AppViewModel()

        viewModel.activityFacade.presentNewChat()

        let request = try XCTUnwrap(viewModel.newProjectChatSheetRequest)
        XCTAssertNil(request.projectID)
        XCTAssertNil(request.workspaceDirectory)
        XCTAssertFalse(request.locksProject)
    }

    func testNewTalkPresentationAsksForAProject() async {
        let viewModel = AppViewModel(backendFactory: HomeTestBackend())
        await viewModel.connectionFacade.connect()
        defer { viewModel.talkSessionCoordinator.stop(); viewModel.disconnect() }
        XCTAssertTrue(viewModel.projectFacade.allowsNewTalk)

        viewModel.activityFacade.presentNewTalk()

        XCTAssertEqual(viewModel.talkSessionCoordinator.phase, .choosingProject)
        XCTAssertNil(viewModel.newProjectChatSheetRequest)
        XCTAssertNil(viewModel.selectedSession)
    }

    func testSelectingTalkProjectStartsListeningBeforeCreatingSession() async {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        await viewModel.connectionFacade.connect()
        defer { viewModel.talkSessionCoordinator.stop(); viewModel.disconnect() }
        let project = makeProject(id: "voice-project", directory: "/tmp/voice-project")
        viewModel.projects = [project]
        let initialSessionCount = backend.storedSessions.count
        XCTAssertTrue(viewModel.projectFacade.allowsNewTalk)
        viewModel.talkSessionCoordinator.setHoldToTalkEnabled(true)
        viewModel.talkSessionCoordinator.presentProjectSelection()

        viewModel.talkSessionCoordinator.selectProject(project)

        XCTAssertEqual(viewModel.talkSessionCoordinator.phase, .listening)
        XCTAssertEqual(viewModel.talkSessionCoordinator.selectedProjectID, project.id)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertEqual(backend.storedSessions.count, initialSessionCount)
        XCTAssertTrue(backend.submissions.isEmpty)

        viewModel.talkSessionCoordinator.applicationActivityChanged(isActive: false)
        XCTAssertEqual(viewModel.talkSessionCoordinator.conversationController.state, .paused)
        viewModel.talkSessionCoordinator.applicationActivityChanged(isActive: true)
        XCTAssertEqual(viewModel.talkSessionCoordinator.conversationController.state, .ready)
    }

    func testPreparationHydratesCardMetadataFromPersistentCacheBeforeServerReconciliation() async throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project-cache", directory: "/tmp/cache")
        let session = makeSession(
            id: "cached",
            title: "Cached activity",
            directory: project.worktree,
            projectID: project.id,
            updated: 2_000
        )
        let messages = [
            makeMessage(id: "user-cache", sessionID: session.id, role: "user", text: "Restore everything"),
            makeMessage(id: "assistant-cache", sessionID: session.id, role: "assistant", text: "Restored from SwiftData"),
        ]
        let todo = OpenCodeTodo(content: "Verify cache", status: "in_progress", priority: "high")
        let permission = OpenCodePermission(
            id: "permission-cache",
            sessionID: session.id,
            permission: "bash",
            patterns: ["xcodebuild test"],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let config = OpenCodeServerConfig(
            name: "Cache Test",
            baseURL: "https://cache.example",
            username: "opencode",
            password: "password",
            apiPreference: .legacy
        )
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.config = config
        viewModel.projects = [project]
        viewModel.localCacheRepository = repository
        try await repository.saveDirectorySessions(
            [session],
            serverID: config.recentServerID,
            directory: project.worktree
        )
        try await repository.saveChatMessages(
            messages,
            serverID: config.recentServerID,
            sessionID: session.id
        )
        try await repository.saveTodos(
            [todo],
            serverID: config.recentServerID,
            sessionID: session.id
        )
        let metadataDate = Date()
        try await repository.saveDirectoryMetadata(
            statuses: [session.id: "busy"],
            permissions: [permission],
            questions: [],
            serverID: config.recentServerID,
            directory: project.worktree,
            refreshedAt: metadataDate,
            writtenAt: metadataDate
        )

        XCTAssertTrue(viewModel.activityFacade.snapshot.isLoading)

        await viewModel.activityFacade.prepareForPresentation()

        let row = try XCTUnwrap(viewModel.activityFacade.snapshot.needsInputRows.first)
        XCTAssertFalse(viewModel.activityFacade.snapshot.isLoading)
        XCTAssertEqual(row.recent.session.id, session.id)
        XCTAssertEqual(row.latestUserText, "Restore everything")
        XCTAssertEqual(row.latestAssistantText, "Restored from SwiftData")
        XCTAssertTrue(row.isWorking)
        XCTAssertEqual(row.pendingInteractionCount, 1)
        XCTAssertEqual(row.statusTitle, "Needs input")
        XCTAssertEqual(row.todoCount, 1)
        XCTAssertEqual(row.completedTodoCount, 0)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSnapshotPlacesWorkingSessionsFirstAndUsesPerDirectoryTranscripts() {
        let viewModel = AppViewModel()
        viewModel.config.apiPreference = .legacy
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        viewModel.liveActivityStore.bind(viewModel.liveActivityFacade.currentLifetime!)
        let projectA = makeProject(id: "project-a", directory: "/tmp/a")
        let projectB = makeProject(id: "project-b", directory: "/tmp/b")
        let working = makeSession(
            id: "working",
            title: "Build release",
            directory: projectA.worktree,
            projectID: projectA.id,
            updated: 1_000
        )
        let idle = makeSession(
            id: "idle",
            title: "Review logs",
            directory: projectB.worktree,
            projectID: projectB.id,
            updated: 2_000
        )
        viewModel.projects = [projectA, projectB]
        viewModel.activeLiveActivitySessionIDs = [working.id]
        viewModel.sessionListStore.setRecentSessions([working], for: projectA.worktree)
        viewModel.sessionListStore.setRecentSessions([idle], for: projectB.worktree)

        let workingStore = viewModel.directoryStoreRegistry.store(for: projectA.worktree)
        _ = workingStore.upsertSessions([working])
        _ = workingStore.applySessionStatuses([working.id: "busy"])
        workingStore.applyCanonicalMessages(
            [
                makeMessage(id: "user-1", sessionID: working.id, role: "user", text: "Ship the release build"),
                makeMessage(id: "assistant-1", sessionID: working.id, role: "assistant", text: "Running the full test suite now"),
            ],
            forSessionID: working.id
        )

        let idleStore = viewModel.directoryStoreRegistry.store(for: projectB.worktree)
        _ = idleStore.upsertSessions([idle])
        _ = idleStore.applySessionStatuses([idle.id: "idle"])
        idleStore.applyCanonicalMessages(
            [makeMessage(id: "assistant-2", sessionID: idle.id, role: "assistant", text: "The logs look clean")],
            forSessionID: idle.id
        )

        let snapshot = viewModel.activityFacade.snapshot

        XCTAssertEqual(snapshot.workingRows.map(\.recent.session.id), [working.id])
        XCTAssertEqual(snapshot.recentRows.map(\.recent.session.id), [idle.id])
        XCTAssertEqual(snapshot.workingRows.first?.latestUserText, "Ship the release build")
        XCTAssertEqual(snapshot.workingRows.first?.latestAssistantText, "Running the full test suite now")
        XCTAssertEqual(snapshot.recentRows.first?.latestAssistantText, "The logs look clean")
        XCTAssertEqual(snapshot.projects.map(\.id), [projectA.id, projectB.id])
        XCTAssertEqual(snapshot.workingRows.first?.projectID, projectA.id)
        XCTAssertEqual(snapshot.recentRows.first?.projectID, projectB.id)
        XCTAssertTrue(snapshot.workingRows.first?.isLiveActivityActive == true)
        XCTAssertFalse(snapshot.recentRows.first?.isLiveActivityActive == true)
        XCTAssertEqual(snapshot.workingRows.first?.statusTitle, "Working")
        XCTAssertEqual(snapshot.recentRows.first?.statusTitle, "Idle")
    }

    func testSnapshotOrdersIdleSessionsByMostRecentUpdate() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let older = makeSession(id: "older", title: "Older", directory: project.worktree, projectID: project.id, updated: 1_000)
        let newer = makeSession(id: "newer", title: "Newer", directory: project.worktree, projectID: project.id, updated: 2_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([older, newer], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([older, newer])

        XCTAssertEqual(viewModel.activityFacade.snapshot.recentRows.map(\.recent.session.id), [newer.id, older.id])
    }

    func testSessionSwitcherCandidatesUseOnlyLiteralRecentSectionInExistingOrder() throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        let recentTime = today.addingTimeInterval(12 * 3_600).timeIntervalSince1970 * 1_000
        let recent = (0..<7).map {
            makeSession(id: "recent-\($0)", title: "Recent", directory: project.worktree,
                projectID: project.id, updated: recentTime + Double($0))
        }
        let working = makeSession(id: "working", title: "Working", directory: project.worktree, projectID: project.id, updated: recentTime)
        let blocked = makeSession(id: "blocked", title: "Blocked", directory: project.worktree, projectID: project.id, updated: recentTime)
        let deleted = makeSession(id: "deleted", title: "Deleted", directory: project.worktree, projectID: project.id, updated: recentTime)
        var archived = makeSession(id: "archived", title: "Archived", directory: project.worktree, projectID: project.id, updated: recentTime)
        archived.time = .init(created: recentTime, updated: recentTime, archived: recentTime)
        let child = OpenCodeSession(id: "child", title: "Child", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: recent[0].id)
        let older = try [1, 4, 8].map { days in
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: today))
            return makeSession(id: "older-\(days)", title: "Older", directory: project.worktree,
                projectID: project.id, updated: date.timeIntervalSince1970 * 1_000)
        }
        let sessions = recent + older + [working, blocked, deleted, archived, child]
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions(sessions + [recent[0]], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        store.sessions = sessions
        store.applySessionStatuses([working.id: "busy", blocked.id: "busy"])
        store.syncState.permissionsBySessionID[blocked.id] = [
            .init(id: "permission", sessionID: blocked.id, permission: "bash", patterns: ["rm"],
                always: nil, metadata: nil, tool: nil),
        ]
        for (index, session) in recent.enumerated() {
            store.applyCanonicalMessages([
                makeMessage(id: "user-\(index)", sessionID: session.id, role: "user", text: "Prompt",
                    created: recentTime - Double(index)),
            ], forSessionID: session.id)
        }
        let facade = ActivityFacade(viewModel: viewModel)
        viewModel.directoryStoreRegistry.markV2SessionDeleted(deleted.id)

        XCTAssertEqual(facade.snapshot.workingRows.map(\.recent.session.id), [working.id])
        XCTAssertEqual(facade.snapshot.needsInputRows.map(\.recent.session.id), [blocked.id])
        XCTAssertTrue(older.allSatisfy { session in facade.snapshot.recentRows.contains { $0.recent.session.id == session.id } })
        XCTAssertEqual(facade.sessionSwitcherCandidates, recent)
        XCTAssertEqual(facade.sessionSwitcherCandidates.map(\.id), facade.snapshot.recentRows
            .map(\.recent.session.id).filter { $0.hasPrefix("recent-") })
        XCTAssertEqual(facade.sessionSwitcherTarget(id: working.id), working)
        XCTAssertEqual(facade.sessionSwitcherTarget(id: blocked.id), blocked)
        XCTAssertEqual(facade.sessionSwitcherTarget(id: older[0].id), older[0])
        XCTAssertNil(facade.sessionSwitcherTarget(id: deleted.id))
        XCTAssertNil(facade.sessionSwitcherTarget(id: archived.id))
        XCTAssertNil(facade.sessionSwitcherTarget(id: child.id))
    }

    func testProjectSessionSwitcherCandidatesUseNewestFiveVisibleRootChatsIncludingIdle() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "switcher-project", directory: "/tmp/switcher-project")
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        let updated = makeSession(id: "updated", title: "Updated", directory: project.worktree, projectID: project.id, updated: 6_000)
        var created = makeSession(id: "created", title: "Created", directory: project.worktree, projectID: project.id, updated: 0)
        created.time = .init(created: 5_000)
        var preview = makeSession(id: "preview", title: "Preview", directory: project.worktree, projectID: project.id, updated: 0)
        preview.time = nil
        let tieA = makeSession(id: "tie-a", title: "Tie A", directory: project.worktree, projectID: project.id, updated: 3_000)
        let tieZ = makeSession(id: "tie-z", title: "Tie Z", directory: project.worktree, projectID: project.id, updated: 3_000)
        let oldest = makeSession(id: "oldest", title: "Oldest", directory: project.worktree, projectID: project.id, updated: 1_000)
        var undated = makeSession(id: "undated", title: "Undated", directory: project.worktree, projectID: project.id, updated: 0)
        undated.time = nil
        var archived = makeSession(id: "archived", title: "Archived", directory: project.worktree, projectID: project.id, updated: 9_000)
        archived.time = .init(updated: 9_000, archived: 9_000)
        let deleted = makeSession(id: "deleted", title: "Deleted", directory: project.worktree, projectID: project.id, updated: 9_000)
        let child = OpenCodeSession(id: "child", title: "Child", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: updated.id)
        let outside = makeSession(id: "outside", title: "Outside", directory: "/tmp/other", projectID: "other", updated: 10_000)
        viewModel.allSessions = [oldest, tieZ, preview, updated, created, tieA, undated, archived, deleted, child, updated]
        viewModel.sessionListStore.previews = [
            preview.id: .init(text: "Preview", date: Date(timeIntervalSince1970: 4)),
            oldest.id: .init(text: "Newer preview must not override session time", date: Date(timeIntervalSince1970: 20)),
        ]
        viewModel.sessionListStore.pinnedSessionIDsByScope = [viewModel.currentPinScopeKey: [oldest.id, updated.id, updated.id]]
        viewModel.directoryStoreRegistry.store(for: outside.directory).sessions = [outside]
        viewModel.sessionListStore.setWorkspaceSessionState(.init(sessions: [outside]), for: "/tmp/other")
        viewModel.directoryStore.applySessionStatuses([updated.id: "idle", created.id: "busy"])
        let facade = SessionListFacade(viewModel: viewModel)
        viewModel.directoryStoreRegistry.markV2SessionDeleted(deleted.id)

        XCTAssertFalse(facade.snapshot.showsWorkspaces)
        XCTAssertEqual(facade.snapshot.pinnedRows.map(\.id), [oldest.id, updated.id, updated.id])
        XCTAssertEqual(facade.sessionSwitcherCandidates, [updated, created, preview, tieA, tieZ])
        XCTAssertEqual(viewModel.directoryStore.openedSessionHistory, [])
        XCTAssertEqual(facade.sessionSwitcherTarget(id: oldest.id), oldest)
        XCTAssertNil(facade.sessionSwitcherTarget(id: outside.id))
        XCTAssertNil(facade.sessionSwitcherTarget(id: deleted.id))
        XCTAssertNil(facade.sessionSwitcherTarget(id: archived.id))
        XCTAssertNil(facade.sessionSwitcherTarget(id: child.id))
    }

    func testSessionListCoalescesFourHundredTranscriptInvalidationsAndEscalatesImmediateRefresh() async {
        let viewModel = AppViewModel()
        let project = makeProject(id: "large-project", directory: "/tmp/large-project")
        let sessions = (0..<400).map { index in
            makeSession(id: "session-\(index)", title: "Session \(index)", directory: project.worktree,
                projectID: project.id, updated: Double(index))
        }
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.allSessions = sessions
        let facade = SessionListFacade(viewModel: viewModel)
        XCTAssertEqual(facade.snapshot.unpinnedRows.count, 400)
        XCTAssertEqual(facade.snapshotBuildCount, 1)

        for _ in 0..<400 {
            facade.invalidateWorkspaceSnapshot(transcriptOnly: true)
        }

        XCTAssertEqual(facade.snapshotBuildCount, 1)
        facade.invalidateWorkspaceSnapshot()
        for _ in 0..<10 where facade.snapshotBuildCount == 1 { await Task.yield() }
        XCTAssertEqual(facade.snapshotBuildCount, 2)
    }

    func testSelectedSimpleRowPrefersCanonicalTranscriptOverStaleCachedPreview() async throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "preview-project", directory: "/tmp/preview-project")
        let session = makeSession(id: "preview-session", title: "Preview", directory: project.worktree,
            projectID: project.id, updated: 1_000)
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.allSessions = [session]
        viewModel.selectedSession = session
        viewModel.sessionListStore.previews[session.id] = .init(text: "No messages yet", date: nil)
        let facade = SessionListFacade(viewModel: viewModel)
        XCTAssertEqual(facade.snapshot.unpinnedRows.first?.preview?.text, "No messages yet")

        viewModel.directoryStore.syncState.replaceMessages([
            makeMessage(id: "answer", sessionID: session.id, role: "assistant", text: "Canonical answer"),
        ], forSessionID: session.id)
        facade.invalidateWorkspaceSnapshot()
        for _ in 0..<10 where facade.snapshot.unpinnedRows.first?.preview?.text != "Canonical answer" {
            await Task.yield()
        }

        let row = try XCTUnwrap(facade.snapshot.unpinnedRows.first)

        XCTAssertEqual(facade.snapshot.cardStyle, .simple)
        XCTAssertEqual(row.preview?.text, "Canonical answer")
        XCTAssertEqual(viewModel.sessionPreviews[session.id]?.text, "No messages yet")
    }

    func testProjectSessionSwitcherCandidatesIncludeOnlyShownWorkspaceRows() throws {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://switcher.invalid", password: "test"))
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: "switcher-test", name: "Test", version: "1"),
            projects: backend, sessions: backend, chat: backend, models: backend, events: backend,
            worktrees: OpenCodeWorktreeServices(client: client, profile: .v2))
        let project = OpenCodeProject(id: "workspace-switcher", worktree: "/tmp/main", vcs: "git", name: "Project",
            sandboxes: ["/tmp/sandbox"], icon: nil, time: nil)
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.projectPreferencesStore.projectWorkspacesEnabledByScope[viewModel.currentProjectPreferenceScopeKey] = true
        let main = makeSession(id: "main", title: "Main", directory: project.worktree, projectID: project.id, updated: 1_000)
        let sandbox = makeSession(id: "sandbox", title: "Sandbox", directory: "/tmp/sandbox", projectID: project.id, updated: 3_000)
        let pinned = makeSession(id: "pinned", title: "Pinned", directory: "/tmp/sandbox", projectID: project.id, updated: 2_000)
        let hidden = makeSession(id: "hidden", title: "Hidden workspace", directory: "/tmp/hidden", projectID: project.id, updated: 10_000)
        viewModel.allSessions = [main, sandbox, pinned, hidden]
        viewModel.sessionListStore.pinnedSessionIDsByScope = [viewModel.currentPinScopeKey: [pinned.id]]
        for (directory, sessions) in [(project.worktree, [main]), ("/tmp/sandbox", [sandbox, pinned]), ("/tmp/hidden", [hidden])] {
            let key = try XCTUnwrap(viewModel.workspacePageKey(directory: directory))
            let requestID = try XCTUnwrap(viewModel.sessionListStore.beginWorkspacePage(key, replacing: true))
            XCTAssertTrue(viewModel.sessionListStore.finishWorkspacePage(key, requestID: requestID, sessions: sessions,
                nextCursor: nil, limit: 10, hasMore: false))
        }
        let facade = SessionListFacade(viewModel: viewModel)

        XCTAssertTrue(facade.snapshot.showsWorkspaces)
        XCTAssertTrue(facade.snapshot.unpinnedRows.isEmpty)
        XCTAssertEqual(facade.snapshot.workspaceSections.map(\.directory), [project.worktree, "/tmp/sandbox"])
        XCTAssertEqual(facade.sessionSwitcherCandidates, [sandbox, pinned, main])
        XCTAssertEqual(facade.sessionSwitcherTarget(id: sandbox.id), sandbox)
        XCTAssertEqual(facade.sessionSwitcherTarget(id: pinned.id), pinned)
        XCTAssertNil(facade.sessionSwitcherTarget(id: hidden.id))
    }

    func testSessionSwitcherCandidatesExcludeHiddenActionsBeforeSnapshotRefresh() throws {
        let journalKey = "openclient.project-action-journal.v1"
        let savedJournal = UserDefaults.standard.data(forKey: journalKey)
        addTeardownBlock {
            if let savedJournal { UserDefaults.standard.set(savedJournal, forKey: journalKey) }
            else { UserDefaults.standard.removeObject(forKey: journalKey) }
        }
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://switcher.invalid", password: "test"))
        let commands = try XCTUnwrap(OpenCodeCommandsService.make(client: client, profile: .legacy,
            version: "1", sessions: backend, chat: backend))
        let backendID = UUID().uuidString
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: backendID, name: "Test", version: "1"),
            projects: backend, sessions: backend, chat: backend, models: backend, events: backend, commands: commands)
        let project = makeProject(id: "action-switcher", directory: "/tmp/action-switcher")
        let time = Calendar.autoupdatingCurrent.startOfDay(for: Date()).addingTimeInterval(12 * 3_600).timeIntervalSince1970 * 1_000
        let actionSession = makeSession(id: "action", title: "Action", directory: project.worktree, projectID: project.id, updated: time)
        let ordinary = makeSession(id: "ordinary", title: "Ordinary", directory: project.worktree, projectID: project.id, updated: time)
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.allSessions = [actionSession, ordinary]
        viewModel.sessionListStore.pinnedSessionIDsByScope = [:]
        viewModel.sessionListStore.setRecentSessions([actionSession, ordinary], for: project.worktree)
        let activity = ActivityFacade(viewModel: viewModel)
        let sessions = SessionListFacade(viewModel: viewModel)
        XCTAssertEqual(activity.sessionSwitcherCandidates.count, 2)
        XCTAssertEqual(sessions.sessionSwitcherCandidates.count, 2)

        let scope = ProjectActionScope(backendID: backendID, contractID: commands.actionContractID,
            projectID: project.id, directory: project.worktree, workspaceID: nil)
        let run = try XCTUnwrap(viewModel.projectActionStore.begin(
            action: OpenCodeAction(commandName: "test", iconName: "bolt.fill"), scope: scope))
        viewModel.projectActionStore.update(id: run.id) {
            $0.sessionID = actionSession.id
            $0.state = .succeeded
        }

        XCTAssertEqual(activity.sessionSwitcherCandidates, [ordinary])
        XCTAssertEqual(sessions.sessionSwitcherCandidates, [ordinary])
        XCTAssertNil(activity.sessionSwitcherTarget(id: actionSession.id))
        XCTAssertNil(sessions.sessionSwitcherTarget(id: actionSession.id))
    }

    func testActivitySessionSwitcherTargetSurvivesRecentToWorkingButRejectsRemovedRow() async {
        let viewModel = AppViewModel()
        let project = makeProject(id: "switcher-activity", directory: "/tmp/switcher-activity")
        let time = Calendar.autoupdatingCurrent.startOfDay(for: Date()).addingTimeInterval(12 * 3_600).timeIntervalSince1970 * 1_000
        let target = makeSession(id: "target", title: "Target", directory: project.worktree, projectID: project.id, updated: time)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([target], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        store.sessions = [target]
        let facade = ActivityFacade(viewModel: viewModel)
        XCTAssertEqual(facade.sessionSwitcherCandidates, [target])

        let movedToWorking = expectation(description: "Target moves out of Recent into Working")
        let workingObservation = facade.$snapshot
            .filter { $0.workingRows.contains { $0.recent.session.id == target.id } }
            .prefix(1).sink { _ in movedToWorking.fulfill() }
        store.applySessionStatus("busy", forSessionID: target.id)
        await fulfillment(of: [movedToWorking], timeout: 1)

        XCTAssertTrue(facade.sessionSwitcherCandidates.isEmpty)
        XCTAssertEqual(facade.sessionSwitcherTarget(id: target.id), target)

        let removed = expectation(description: "Target row leaves Activity")
        let removalObservation = facade.$snapshot.filter(\.isEmpty)
            .prefix(1).sink { _ in removed.fulfill() }
        store.selectedSession = target
        store.sessions = []
        viewModel.sessionListStore.setRecentSessions([], for: project.worktree)
        await fulfillment(of: [removed], timeout: 1)

        XCTAssertEqual(viewModel.directoryStoreRegistry.session(matching: target.id), target)
        XCTAssertNil(facade.sessionSwitcherTarget(id: target.id))
        withExtendedLifetime((workingObservation, removalObservation)) {}
    }

    func testProjectSessionSwitcherTargetSurvivesRecencyDropButRejectsRemovedRow() async {
        let viewModel = AppViewModel()
        let project = makeProject(id: "switcher-ranking", directory: "/tmp/switcher-ranking")
        let target = makeSession(id: "target", title: "Target", directory: project.worktree, projectID: project.id, updated: 1_000)
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.sessionListStore.pinnedSessionIDsByScope = [:]
        viewModel.allSessions = [target]
        let facade = SessionListFacade(viewModel: viewModel)
        XCTAssertEqual(facade.sessionSwitcherCandidates, [target])

        let newer = (0..<5).map {
            makeSession(id: "newer-\($0)", title: "Newer", directory: project.worktree,
                projectID: project.id, updated: 2_000 + Double($0))
        }
        let reranked = expectation(description: "Five newer rows move target outside candidate limit")
        let rankingObservation = facade.$snapshot.filter { $0.unpinnedRows.count == 6 }
            .prefix(1).sink { _ in reranked.fulfill() }
        viewModel.allSessions = newer + [target]
        await fulfillment(of: [reranked], timeout: 1)

        XCTAssertEqual(facade.sessionSwitcherCandidates.count, 5)
        XCTAssertFalse(facade.sessionSwitcherCandidates.contains { $0.id == target.id })
        XCTAssertEqual(facade.sessionSwitcherTarget(id: target.id), target)

        let renamed = makeSession(id: target.id, title: "Canonical title", directory: project.worktree,
            projectID: project.id, updated: 1_000)
        viewModel.directoryStore.insertV2Session(renamed)
        XCTAssertEqual(facade.sessionSwitcherTarget(id: target.id), renamed)

        let removed = expectation(description: "Target row leaves project list")
        let removalObservation = facade.$snapshot.filter { !$0.unpinnedRows.contains { $0.id == target.id } }
            .prefix(1).sink { _ in removed.fulfill() }
        viewModel.directoryStore.selectedSession = renamed
        viewModel.allSessions = newer
        await fulfillment(of: [removed], timeout: 1)

        XCTAssertEqual(viewModel.directoryStoreRegistry.session(matching: target.id), renamed)
        XCTAssertNil(facade.sessionSwitcherTarget(id: target.id))
        withExtendedLifetime((rankingObservation, removalObservation)) {}
    }

    func testSessionSwitcherTargetsValidateCanonicalSessionBeforeSnapshotRefresh() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "switcher-validation", directory: "/tmp/switcher-validation")
        let original = makeSession(id: "target", title: "Target", directory: project.worktree, projectID: project.id, updated: 1_000)
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.allSessions = [original]
        viewModel.sessionListStore.pinnedSessionIDsByScope = [:]
        let activity = ActivityFacade(viewModel: viewModel)
        let sessions = SessionListFacade(viewModel: viewModel)
        XCTAssertEqual(activity.sessionSwitcherTarget(id: original.id), original)
        XCTAssertEqual(sessions.sessionSwitcherTarget(id: original.id), original)

        var archived = original
        archived.time = .init(created: 1_000, updated: 1_000, archived: 2_000)
        let child = OpenCodeSession(id: original.id, title: "Child", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: "parent")
        for invalid in [archived, child] {
            viewModel.allSessions = [invalid]
            XCTAssertNil(activity.sessionSwitcherTarget(id: original.id))
            XCTAssertNil(sessions.sessionSwitcherTarget(id: original.id))
        }
        for moved in [
            OpenCodeSession(id: original.id, title: "Moved directory", workspaceID: nil,
                directory: "/tmp/elsewhere", projectID: project.id, parentID: nil),
            OpenCodeSession(id: original.id, title: "Moved workspace", workspaceID: "remote",
                directory: project.worktree, projectID: project.id, parentID: nil),
            OpenCodeSession(id: original.id, title: "Moved project", workspaceID: nil,
                directory: project.worktree, projectID: "other-project", parentID: nil),
        ] {
            viewModel.allSessions = [moved]
            XCTAssertNil(sessions.sessionSwitcherTarget(id: original.id))
        }
        viewModel.allSessions = [original]
        viewModel.directoryStoreRegistry.markV2SessionDeleted(original.id)
        XCTAssertNil(activity.sessionSwitcherTarget(id: original.id))
        XCTAssertNil(sessions.sessionSwitcherTarget(id: original.id))
    }

    func testSnapshotTracksSelectedActivitySessionBeforeDeferredRowRebuild() throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(
            id: "selected",
            title: "Selected",
            directory: project.worktree,
            projectID: project.id,
            updated: 1_000
        )
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        let facade = viewModel.activityFacade
        let row = try XCTUnwrap(facade.snapshot.recentRows.first)
        let rows = facade.snapshot.recentRows

        facade.prepareSelection(row)

        XCTAssertEqual(facade.snapshot.selectedSessionID, session.id)
        XCTAssertEqual(facade.snapshot.recentRows, rows)
    }

    func testSnapshotOrdersWithinSectionByLatestUserMessageInsteadOfSessionUpdate() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let assistantRecentlyUpdated = makeSession(
            id: "assistant-recent",
            title: "Assistant still working",
            directory: project.worktree,
            projectID: project.id,
            updated: 3_000
        )
        let userRecentlyUpdated = makeSession(
            id: "user-recent",
            title: "New user request",
            directory: project.worktree,
            projectID: project.id,
            updated: 2_000
        )
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([assistantRecentlyUpdated, userRecentlyUpdated], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([assistantRecentlyUpdated, userRecentlyUpdated])
        store.applyCanonicalMessages(
            [makeMessage(id: "user-old", sessionID: assistantRecentlyUpdated.id, role: "user", text: "Earlier", created: 1_000)],
            forSessionID: assistantRecentlyUpdated.id
        )
        store.applyCanonicalMessages(
            [makeMessage(id: "user-new", sessionID: userRecentlyUpdated.id, role: "user", text: "Later", created: 2_000)],
            forSessionID: userRecentlyUpdated.id
        )

        XCTAssertEqual(
            viewModel.activityFacade.snapshot.recentRows.map(\.recent.session.id),
            [userRecentlyUpdated.id, assistantRecentlyUpdated.id]
        )
    }

    func testBareScopeAttributionSurvivesCanonicalRepositorySessionInDirectoryStore() {
        let viewModel = AppViewModel()
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        let repository = makeProject(id: "opencode", directory: "/tmp/opencode")
        let canonical = makeSession(
            id: "free-space",
            title: "Freeing up disk space",
            directory: "/tmp/opencode/BlueBubbles",
            projectID: repository.id,
            updated: 2_000
        )
        viewModel.projects = [global, repository]
        viewModel.sessionListStore.setRecentSessions([canonical], for: nil)
        let globalStore = viewModel.directoryStoreRegistry.store(for: nil)
        _ = globalStore.upsertSessions([canonical])

        let row = viewModel.activityFacade.snapshot.recentRows.first

        XCTAssertEqual(row?.recent.projectTitle, "Global")
        XCTAssertEqual(row?.projectID, "global")
        XCTAssertEqual(row?.recent.session.projectID, "global")
        XCTAssertTrue(row?.usesGlobalProjectAvatar == true)

        var updated = makeSession(id: canonical.id, title: "Canonical rename", directory: canonical.directory!,
            projectID: repository.id, updated: 3_000)
        globalStore.sessions = [updated]
        let target = viewModel.activityFacade.sessionSwitcherTarget(id: canonical.id)
        XCTAssertEqual(target?.title, updated.title)
        XCTAssertEqual(target?.projectID, "global")
        XCTAssertEqual(target?.directory, updated.directory)
        XCTAssertEqual(target?.time, updated.time)
        updated.time = .init(created: 2_000, updated: 3_000, archived: 4_000)
        globalStore.sessions = [updated]
        XCTAssertNil(viewModel.activityFacade.sessionSwitcherTarget(id: canonical.id))
    }

    func testNeedsInputSectionTakesPrecedenceOverWorking() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let blocked = makeSession(id: "blocked", title: "Blocked", directory: project.worktree, projectID: project.id, updated: 2_000)
        let working = makeSession(id: "working", title: "Working", directory: project.worktree, projectID: project.id, updated: 1_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([blocked, working], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([blocked, working])
        _ = store.applySessionStatuses([blocked.id: "busy", working.id: "busy"])
        store.syncState.permissionsBySessionID[blocked.id] = [
            OpenCodePermission(
                id: "permission",
                sessionID: blocked.id,
                permission: "bash",
                patterns: ["rm"],
                always: nil,
                metadata: nil,
                tool: nil
            ),
        ]

        let snapshot = viewModel.activityFacade.snapshot

        XCTAssertEqual(snapshot.needsInputRows.map(\.id), ["/tmp/project:blocked"])
        XCTAssertEqual(snapshot.workingRows.map(\.id), ["/tmp/project:working"])
        XCTAssertTrue(snapshot.recentRows.isEmpty)
        XCTAssertEqual(snapshot.needsInputRows.first?.statusTitle, "Needs input")
    }

    func testSnapshotTracksLiveChildInteractionsAndNativeFormSettlementBySessionTree() async throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let root = makeSession(id: "root", title: "Root", directory: project.worktree, projectID: project.id, updated: 2_000)
        let otherRoot = makeSession(id: "other-root", title: "Other", directory: project.worktree, projectID: project.id, updated: 1_000)
        let childA = OpenCodeSession(id: "child-a", title: "Child A", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: root.id)
        let childB = OpenCodeSession(id: "child-b", title: "Child B", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: root.id)
        let otherChild = OpenCodeSession(id: "other-child", title: "Other child", workspaceID: nil,
            directory: project.worktree, projectID: project.id, parentID: otherRoot.id)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([root, otherRoot], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        store.sessions = [root, childA, childB, otherRoot, otherChild]
        let facade = ActivityFacade(viewModel: viewModel)

        let childPermission = expectation(description: "Child permission moves root to Needs Input")
        let permissionObservation = facade.$snapshot.filter {
            $0.needsInputRows.first(where: { $0.recent.session.id == root.id })?.pendingInteractionCount == 1
                && $0.needsInputRows.first(where: { $0.recent.session.id == otherRoot.id })?.pendingInteractionCount == 1
        }.prefix(1).sink { _ in childPermission.fulfill() }
        let permission = OpenCodePermission(id: "permission", sessionID: childA.id, permission: "bash",
            patterns: ["xcodebuild"], always: nil, metadata: nil, tool: nil)
        let unrelatedPermission = OpenCodePermission(id: "other-permission", sessionID: otherChild.id, permission: "edit",
            patterns: [], always: nil, metadata: nil, tool: nil)
        XCTAssertTrue(store.applyPermissions([permission, unrelatedPermission], ifUnchangedSince: store.permissionRevision))
        await fulfillment(of: [childPermission], timeout: 1)

        let questionsVisible = expectation(description: "Questions from sibling children aggregate under root")
        let questionsObservation = facade.$snapshot.filter {
            $0.needsInputRows.first(where: { $0.recent.session.id == root.id })?.pendingInteractionCount == 3
        }.prefix(1).sink { _ in questionsVisible.fulfill() }
        let questionA = OpenCodeQuestionRequest(id: "shared", sessionID: childA.id, questions: [], tool: nil)
        let questionB = OpenCodeQuestionRequest(id: "shared", sessionID: childB.id, questions: [], tool: nil)
        XCTAssertTrue(store.applyQuestions([questionA, questionB], ifUnchangedSince: store.questionRevision))
        await fulfillment(of: [questionsVisible], timeout: 1)

        let formsVisible = expectation(description: "Native forms refresh Activity and deduplicate by session and form ID")
        let formsObservation = facade.$snapshot.filter {
            $0.needsInputRows.first(where: { $0.recent.session.id == root.id })?.pendingInteractionCount == 4
        }.prefix(1).sink { _ in formsVisible.fulfill() }
        let duplicateForm = BackendForm(id: questionA.id, sessionID: childA.id, title: "Duplicate", fields: [])
        let nativeForm = BackendForm(id: "native", sessionID: childA.id, title: "Native", fields: [])
        store.sessionFormStore.upsert(duplicateForm)
        store.sessionFormStore.upsert(nativeForm)
        await fulfillment(of: [formsVisible], timeout: 1)
        XCTAssertEqual(facade.snapshot.needsInputRows.first(where: { $0.recent.session.id == otherRoot.id })?.pendingInteractionCount, 1)

        let nativeSettled = expectation(description: "Native form settlement refreshes Activity")
        let nativeSettlementObservation = facade.$snapshot.filter {
            $0.needsInputRows.first(where: { $0.recent.session.id == root.id })?.pendingInteractionCount == 3
        }.prefix(1).sink { _ in nativeSettled.fulfill() }
        store.applySessionFormSettled(nativeForm.key)
        await fulfillment(of: [nativeSettled], timeout: 1)

        let allRootInteractionsSettled = expectation(description: "Root leaves Needs Input after child interactions settle")
        let settlementObservation = facade.$snapshot.filter {
            $0.needsInputRows.allSatisfy { $0.recent.session.id != root.id }
                && $0.recentRows.contains { $0.recent.session.id == root.id }
                && $0.needsInputRows.first(where: { $0.recent.session.id == otherRoot.id })?.pendingInteractionCount == 1
        }.prefix(1).sink { _ in allRootInteractionsSettled.fulfill() }
        store.applySessionFormSettled(duplicateForm.key)
        store.removeV2Question(id: questionB.id, sessionID: questionB.sessionID)
        store.removeV2Permission(id: permission.id, sessionID: permission.sessionID)
        await fulfillment(of: [allRootInteractionsSettled], timeout: 1)
        withExtendedLifetime((permissionObservation, questionsObservation, formsObservation,
            nativeSettlementObservation, settlementObservation)) {}
    }

    func testPreparationDiscoversMissingAncestorsWhenPendingChildIsAlreadyCached() async throws {
        let backend = HomeTestBackend()
        let child = OpenCodeSession(id: "sandbox-session", title: "Pending child", workspaceID: nil,
            directory: "/home-sandbox", projectID: "home-project", parentID: "middle-session")
        let middle = OpenCodeSession(id: "middle-session", title: "Middle", workspaceID: nil,
            directory: "/home-sandbox", projectID: "home-project", parentID: "older-root")
        let root = OpenCodeSession(id: "older-root", title: "Older root", workspaceID: nil,
            directory: "/home-sandbox", projectID: "home-project", parentID: nil)
        backend.storedSessions.append(child)
        var fetchCount = 0
        backend.beforeSessionFetch = {
            fetchCount += 1
            if !backend.storedSessions.contains(where: { $0.id == middle.id }) {
                backend.storedSessions.append(contentsOf: [middle, root])
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://activity.invalid", password: "test"), session: session)
        let adapter = OpenCodeBackendAdapter(client: client, profile: .v2)
        let viewModel = AppViewModel(backendFactory: backend)
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: "ancestor-test", name: "OpenCode", version: "next"),
            capabilities: [.interactions], projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        viewModel.projects = try await backend.projectsSnapshot().projects
        _ = viewModel.directoryStoreRegistry.store(for: child.directory).upsertSessions([child])
        defer { viewModel.disconnect() }

        await viewModel.activityFacade.prepareForPresentation()

        let owner = viewModel.directoryStoreRegistry.store(for: "/home-sandbox")
        XCTAssertEqual(fetchCount, 2)
        XCTAssertTrue(owner.sessions.contains { $0.id == child.id })
        XCTAssertTrue(owner.sessions.contains { $0.id == middle.id })
        XCTAssertTrue(owner.sessions.contains { $0.id == root.id })
        XCTAssertEqual(viewModel.activityFacade.snapshot.needsInputRows.map(\.recent.session.id), [root.id])
        XCTAssertEqual(viewModel.activityFacade.snapshot.needsInputRows.first?.pendingInteractionCount, 1)
    }

    func testSnapshotFlattensMarkdownAndIncludesRunningTools() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(id: "session", title: "Streaming", directory: project.worktree, projectID: project.id, updated: 2_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        _ = store.applySessionStatuses([session.id: "busy"])
        store.applyCanonicalMessages(
            [
                makeMessage(id: "assistant", sessionID: session.id, role: "assistant", text: "**Checking**\n`disk usage`"),
                makeToolMessage(id: "tool", sessionID: session.id),
            ],
            forSessionID: session.id
        )

        let row = viewModel.activityFacade.snapshot.workingRows.first

        XCTAssertEqual(row?.latestAssistantText, "Checking · disk usage")
        XCTAssertEqual(row?.runningTools.first?.tool, "bash")
        XCTAssertEqual(row?.runningTools.first?.title, "Checking disk space")
        XCTAssertEqual(row?.runningTools.first?.detail, "du -sh ~")
    }

    func testSnapshotHidesRunningToolWhenNewerTextIsLatestAndPreservesTextForLayout() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(id: "session", title: "Streaming", directory: project.worktree, projectID: project.id, updated: 2_000)
        let finalText = String(repeating: "old ", count: 100) + "latest streaming news"
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        _ = store.applySessionStatuses([session.id: "busy"])
        store.applyCanonicalMessages(
            [
                makeToolMessage(id: "a-tool", sessionID: session.id),
                makeMessage(id: "z-text", sessionID: session.id, role: "assistant", text: finalText),
            ],
            forSessionID: session.id
        )

        let row = viewModel.activityFacade.snapshot.workingRows.first

        XCTAssertTrue(row?.runningTools.isEmpty == true)
        XCTAssertEqual(row?.latestAssistantText, finalText)
    }

    func testPreviewTextFlattensMarkdownListsAndKeepsNewestTextWhenLimited() {
        let markdown = """
        # Summary
        - First item
        - [x] Fixed issue
        1. Latest sentence
        """

        XCTAssertEqual(
            opencodePreviewText(markdown, limit: nil),
            "Summary · First item · Fixed issue · Latest sentence"
        )
        XCTAssertEqual(opencodePreviewText(markdown, limit: 20), "…e · Latest sentence")
    }

    func testSessionPreviewFlattensListsAndKeepsLatestSentence() {
        let viewModel = AppViewModel()
        let text = String(repeating: "Older context ", count: 12) + "\n- First result\n- Latest sentence"

        let preview = viewModel.buildSessionPreview(
            from: [makeMessage(id: "assistant", sessionID: "session", role: "assistant", text: text)]
        )

        XCTAssertTrue(preview.text.hasPrefix("…"))
        XCTAssertTrue(preview.text.hasSuffix("First result · Latest sentence"))
        XCTAssertFalse(preview.text.contains(String(repeating: "Older context ", count: 10)))
    }

    func testActivityTailPreviewStartsFirstLineWithEllipsisAndFillsTwoLines() {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let source = String(repeating: "older words ", count: 20) + "the latest streaming sentence"
        let fitted = ActivityTailPreview.fittingText(source, width: 180, font: font)
        let height = (fitted as NSString).boundingRect(
            with: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        let twoLineHeight = ("Ag\nAg" as NSString).boundingRect(
            with: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height

        XCTAssertTrue(fitted.hasPrefix("…"))
        XCTAssertTrue(fitted.hasSuffix("the latest streaming sentence"))
        XCTAssertGreaterThan(height, font.lineHeight)
        XCTAssertLessThanOrEqual(height, twoLineHeight)
    }

    func testActivityTailPreviewFillsTwoLinesWhenOlderTextContainsLongPath() {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let source = "Checked /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneSimulator.platform and verified every deterministic preview. The newest sentence remains visible."
        let fitted = ActivityTailPreview.fittingText(source, width: 300, font: font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let height = (fitted as NSString).boundingRect(
            with: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle],
            context: nil
        ).height

        XCTAssertTrue(fitted.hasPrefix("…"))
        XCTAssertTrue(fitted.hasSuffix("The newest sentence remains visible."))
        XCTAssertGreaterThan(height, font.lineHeight)
    }

    private func makePreloadSessions(count: Int) -> [OpenCodeSession] {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        let time = today.addingTimeInterval(12 * 3_600).timeIntervalSince1970 * 1_000
        let directories: [String?] = ["/home-project", "/home-sandbox", nil]
        return (0..<count).map { index in
            let directory = directories[index % directories.count]
            var session = OpenCodeSession(id: "preload-\(index)", title: "Recent \(index)", workspaceID: nil,
                directory: directory, projectID: directory == nil ? "global" : "home-project", parentID: nil)
            session.time = .init(created: time, updated: time)
            return session
        }
    }

    private func scopeMovements(of session: OpenCodeSession) -> [OpenCodeSession] {
        [
            OpenCodeSession(id: session.id, title: "Moved directory", workspaceID: session.workspaceID,
                directory: "/home-sandbox", projectID: session.projectID, parentID: nil),
            OpenCodeSession(id: session.id, title: "Moved workspace", workspaceID: "remote-workspace",
                directory: session.directory, projectID: session.projectID, parentID: nil),
            OpenCodeSession(id: session.id, title: "Moved project", workspaceID: session.workspaceID,
                directory: session.directory, projectID: "other-project", parentID: nil),
        ].map { moved in
            var moved = moved
            moved.time = session.time
            return moved
        }
    }

    private func makePreloadFixture(
        sessions: [OpenCodeSession], profile: OpenCodeAPIProfile = .v2, usesLocalCache: Bool = false
    ) async throws -> (AppViewModel, HomeTestBackend, ActivityPreloadChatBackend) {
        let backend = HomeTestBackend()
        let time = Calendar.autoupdatingCurrent.startOfDay(for: Date()).addingTimeInterval(12 * 3_600).timeIntervalSince1970 * 1_000
        backend.storedSessions = sessions + [
            makeSession(id: "home-session", title: "Working", directory: "/home-project", projectID: "home-project", updated: time),
            makeSession(id: "sandbox-session", title: "Needs input", directory: "/home-sandbox", projectID: "home-project", updated: time),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = profile == .v2 ? [ActivityMetadataURLProtocol.self] : [ActivityLegacyMetadataURLProtocol.self]
        let transport = URLSession(configuration: configuration)
        let viewModel = usesLocalCache ? AppViewModel() : AppViewModel(backendFactory: backend)
        if usesLocalCache { viewModel.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory() }
        let chat = ActivityPreloadChatBackend()
        viewModel.config = .init(baseURL: "https://activity-preload.invalid", password: "test", apiPreference: profile == .v2 ? .v2 : .legacy)
        let adapter = OpenCodeBackendAdapter(client: .init(config: viewModel.config, session: transport), profile: profile)
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: "activity-preload", name: "OpenCode", version: "next"),
            capabilities: usesLocalCache ? [.interactions, .localCache] : [.interactions],
            projects: adapter, sessions: backend, chat: chat, models: backend, events: backend)
        if profile == .v2 {
            viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        } else {
            viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        }
        viewModel.projects = try await backend.projectsSnapshot().projects
        addTeardownBlock { @MainActor in
            backend.beforeSessionFetch = nil
            chat.release()
            viewModel.disconnect()
            transport.invalidateAndCancel()
        }
        return (viewModel, backend, chat)
    }

    private func makeProject(id: String, directory: String) -> OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: directory,
            vcs: "git",
            name: id,
            sandboxes: nil,
            icon: nil,
            time: nil
        )
    }

    private func makeSession(
        id: String,
        title: String,
        directory: String,
        projectID: String,
        updated: Double
    ) -> OpenCodeSession {
        var session = OpenCodeSession(
            id: id,
            title: title,
            workspaceID: nil,
            directory: directory,
            projectID: projectID,
            parentID: nil
        )
        session.time = OpenCodeMessageTime(created: updated, updated: updated, completed: nil, archived: nil)
        return session
    }

    private func makeMessage(
        id: String,
        sessionID: String,
        role: String,
        text: String,
        created: Double? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: created.map { OpenCodeMessageTime(created: $0) },
                agent: nil,
                model: nil
            ),
            parts: [
                OpenCodePart(
                    id: "part-\(id)",
                    messageID: id,
                    sessionID: sessionID,
                    type: "text",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: nil,
                    callID: nil,
                    state: nil,
                    text: text
                ),
            ]
        )
    }

    private func makeToolMessage(id: String, sessionID: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(
                    id: "part-\(id)",
                    messageID: id,
                    sessionID: sessionID,
                    type: "tool",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: "bash",
                    callID: "call-\(id)",
                    state: OpenCodeToolState(
                        status: "running",
                        title: "Checking disk space",
                        error: nil,
                        input: OpenCodeToolInput(
                            command: "du -sh ~",
                            description: nil,
                            filePath: nil,
                            name: nil,
                            path: nil,
                            query: nil,
                            pattern: nil,
                            subagentType: nil,
                            url: nil
                        ),
                        output: nil,
                        metadata: nil
                    ),
                    text: nil
                ),
            ]
        )
    }
}
