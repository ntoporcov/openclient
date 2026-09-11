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
        case "/api/form/request":
            body = #"{"data":[{"id":"external-form","sessionID":"sandbox-session","title":"Authenticate","fields":[{"key":"auth","type":"external","required":true}]}]}"#
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
