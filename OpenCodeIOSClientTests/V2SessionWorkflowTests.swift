import XCTest
import Combine
@testable import OpenClient

@MainActor
final class V2SessionWorkflowTests: XCTestCase {
    private var originalDraftData: Data?

    override func setUp() async throws {
        originalDraftData = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        _ = URLProtocol.registerClass(V2SessionWorkflowURLProtocol.self)
    }

    override func tearDown() async throws {
        V2SessionWorkflowURLProtocol.handler = nil
        URLProtocol.unregisterClass(V2SessionWorkflowURLProtocol.self)
        UserDefaults.standard.set(originalDraftData, forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    func testInteractionHydrationRetriesAfterReplyAndDiscoversOtherPendingRequest() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_interactions", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        var permissionReads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/form") { return (200, #"{"data":[]}"#) }
            XCTAssertTrue(request.url!.path.hasSuffix("/permission"))
            permissionReads += 1
            if permissionReads == 1 {
                model.directoryStore.removeV2Permission(id: "a", sessionID: session.id)
            }
            return (200, #"{"data":[{"id":"b","sessionID":"ses_interactions","action":"shell","resources":["*"]}]}"#)
        }
        let complete = await model.hydrateV2Interactions(for: session)
        XCTAssertTrue(complete)
        XCTAssertEqual(permissionReads, 2)
        XCTAssertEqual(model.directoryStore.syncState.permissionsBySessionID[session.id]?.map(\.id), ["b"])
    }

    func testProjectListDiscoversWorktreeSessionsWithoutDirectoryFilter() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        model.currentProject = OpenCodeProject(id: "proj_repo", worktree: "/repo", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path == "/api/session/active" { return (200, #"{"data":{"ses_copy":{"type":"running"}}}"#) }
            XCTAssertEqual(request.url?.path, "/api/session")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "project" }?.value, "proj_repo")
            XCTAssertNil(query.first { $0.name == "directory" })
            XCTAssertEqual(query.first { $0.name == "parentID" }?.value, "null")
            return (200, #"{"data":[{"id":"ses_copy","projectID":"proj_repo","location":{"directory":"/copies/feature"},"time":{"created":1,"updated":2}}]}"#)
        }
        try await model.reloadV2Sessions(replacing: true)
        let snapshot = model.sessionListFacade.makeSnapshot()
        let row = try XCTUnwrap(snapshot.unpinnedRows.first { $0.id == "ses_copy" })
        XCTAssertEqual(row.session.directory, "/copies/feature")
        XCTAssertNotNil(row.workspaceOverline)
        XCTAssertTrue(row.workspaceOverline?.contains("feature") == true)
        XCTAssertEqual(row.activityRow.worktreeLabel, row.workspaceOverline)
        XCTAssertTrue(row.isBusy)
        XCTAssertFalse(model.v2SessionListStore.sessions.contains { $0.id == "ses_copy" })
        XCTAssertTrue(model.directoryStoreRegistry.existingStore(for: "/copies/feature")?.sessions.contains { $0.id == "ses_copy" } == true)
    }

    func testActivityDiscoversEveryRootPageWithoutKnowingWorktreeDirectories() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        model.projects = [OpenCodeProject(id: "proj_repo", worktree: "/repo", vcs: "git", name: "Repository", sandboxes: nil, icon: nil, time: nil)]
        var continuations = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertNil(query.first { $0.name == "directory" })
            if query.contains(where: { $0.name == "cursor" }) {
                continuations += 1
                return (200, #"{"data":[{"id":"ses_old","projectID":"proj_repo","location":{"directory":"/copies/unlisted"},"time":{"created":1,"updated":1}},{"id":"ses_child","parentID":"ses_old","projectID":"proj_repo","location":{"directory":"/copies/unlisted"},"time":{"created":1,"updated":1}}]}"#)
            }
            XCTAssertEqual(query.first { $0.name == "project" }?.value, "proj_repo")
            XCTAssertEqual(query.first { $0.name == "parentID" }?.value, "null")
            let rows = (0..<100).map { index in
                #"{"id":"ses_\#(index)","projectID":"proj_repo","location":{"directory":"/repo"},"time":{"created":2,"updated":2}}"#
            }.joined(separator: ",")
            return (200, #"{"data":[\#(rows)],"cursor":{"next":"older"}}"#)
        }
        await model.loadRecentProjectSessionsAcrossProjects()
        let snapshot = model.activityFacade.snapshot
        XCTAssertEqual(snapshot.recentRows.count, 101)
        XCTAssertFalse(snapshot.recentRows.contains { $0.recent.session.id == "ses_child" })
        let moved = try XCTUnwrap(snapshot.recentRows.first { $0.recent.session.id == "ses_old" })
        XCTAssertEqual(moved.recent.projectTitle, "Repository")
        XCTAssertTrue(moved.worktreeLabel?.contains("unlisted") == true)
        XCTAssertGreaterThanOrEqual(continuations, 1)
    }

    func testActivityLoadsProjectsSharingOneCanonicalDirectory() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        model.projects = ["old-project", "new-project"].map {
            OpenCodeProject(id: $0, worktree: "/shared", vcs: "git", name: $0, sandboxes: nil, icon: nil, time: nil)
        }
        let sessions = model.projects.map {
            var session = OpenCodeSession(id: "ses_\($0.id)", title: nil, workspaceID: nil, directory: "/shared", projectID: $0.id, parentID: nil)
            session.time = .init(created: 1, updated: 1)
            return session
        }
        model.directoryStoreRegistry.store(for: "/shared").sessions = sessions
        model.sessionListStore.setRecentSessions(sessions, for: "/shared")
        var requestedProjects = Set<String>()
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            let project = try XCTUnwrap(query.first { $0.name == "project" }?.value)
            requestedProjects.insert(project)
            return (200, #"{"data":[{"id":"ses_\#(project)","projectID":"\#(project)","location":{"directory":"/shared"},"time":{"created":1,"updated":1}}]}"#)
        }
        await model.loadRecentProjectSessionsAcrossProjects()
        XCTAssertEqual(requestedProjects, ["old-project", "new-project"])
        XCTAssertEqual(Set(model.sessionListStore.recentSessionsByDirectory["/shared", default: []].map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(Set(model.activityFacade.snapshot.recentRows.map(\.recent.session.id)), Set(sessions.map(\.id)))
    }

    func testProjectCardsKeepBackgroundMovedSessionAndExcludeOtherProjects() throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        model.currentProject = OpenCodeProject(id: "proj_repo", worktree: "/repo", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        let root = OpenCodeSession(id: "ses_root", title: nil, workspaceID: nil, directory: "/repo", projectID: "proj_repo", parentID: nil)
        let moving = OpenCodeSession(id: "ses_moving", title: nil, workspaceID: nil, directory: "/repo", projectID: "proj_repo", parentID: nil)
        model.directoryStore.insertV2Session(root)
        model.directoryStore.insertV2Session(moving)
        model.directoryStoreRegistry.store(for: "/other").insertV2Session(
            OpenCodeSession(id: "ses_other", title: nil, workspaceID: nil, directory: "/other", projectID: "other", parentID: nil))
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.moved","location":{"directory":"/repo"},"data":{"sessionID":"ses_moving","location":{"directory":"/copies/feature"},"projectID":"proj_repo"}}"#))
        model.handleV2Event(event)
        model.directoryStoreRegistry.store(for: "/copies/feature").applySessionStatus("busy", forSessionID: moving.id)
        let rows = model.sessionListFacade.makeSnapshot().unpinnedRows
        XCTAssertEqual(Set(rows.map(\.id)), [root.id, moving.id])
        XCTAssertNil(rows.first { $0.id == root.id }?.workspaceOverline)
        XCTAssertEqual(rows.first { $0.id == moving.id }?.session.directory, "/copies/feature")
        XCTAssertNotNil(rows.first { $0.id == moving.id }?.workspaceOverline)
        XCTAssertEqual(rows.first { $0.id == moving.id }?.isBusy, true)
        // Opening the moved chat must not replace project pagination with the
        // destination owner's (unloaded) directory cursor.
        model.v2SessionListStore.applyV2SessionPage(.init(sessions: [root], nextCursor: "next-project-page"),
            replacing: true, requestedCursor: nil, limit: 50)
        model.directoryStoreRegistry.activate("/copies/feature")
        let movedSnapshot = model.sessionListFacade.makeSnapshot()
        XCTAssertEqual(Set(movedSnapshot.unpinnedRows.map(\.id)), [root.id, moving.id])
        XCTAssertTrue(movedSnapshot.hasMoreSessions)
    }

    func testMarkReadAcknowledgesObservedCompletionAndKeepsNewerCompletionUnread() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let connection = try model.requireBackendConnection()
        var session = Self.session(id: "ses_read", directory: "/repo")
        session.time = .init(created: 1, updated: 2, idle: 100)
        var paths: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            let path = request.url!.path
            paths.append(path)
            if path.hasSuffix("/view") {
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Double]
                XCTAssertEqual(body, ["idle": 100])
                return (204, "")
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, #"{"data":{"id":"ses_read","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2,"idle":200,"viewed":100}}}"#)
        }
        let updated = try await model.sessionCoordinator.markRead(session: session, connection: connection)
        XCTAssertEqual(paths, ["/api/session/ses_read/view", "/api/session/ses_read"])
        XCTAssertEqual(updated?.time?.viewed, 100)
        XCTAssertEqual(updated?.time?.updated, 2)
        XCTAssertEqual(updated?.isUnread, true)
    }

    func testYOLOModePreservesSessionRulesAndReadsBackServerState() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let client = try XCTUnwrap(model.requireBackendConnection().openCodeCompatibility?.client)
        let original = [OpenCodePermissionRule(action: "shell", resource: "git push *", effect: "ask")]
        var rules = original
        var methods: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_yolo")
            methods.append(request.httpMethod!)
            if request.httpMethod == "PATCH" {
                let payload = try JSONDecoder().decode([String: [OpenCodePermissionRule]].self, from: Self.body(request))
                XCTAssertEqual(Set(payload.keys), ["permissions"])
                rules = try XCTUnwrap(payload["permissions"])
                return (204, "")
            }
            let raw = String(data: try JSONEncoder().encode(rules), encoding: .utf8)!
            return (200, #"{"data":{"id":"ses_yolo","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2},"permissions":\#(raw)}}"#)
        }
        let enabled = try await model.sessionCoordinator.setYOLOMode(true, sessionID: "ses_yolo", client: client)
        XCTAssertTrue(enabled.allowsAllSessionPermissions)
        XCTAssertEqual(rules, original + [.allowAll])
        let disabled = try await model.sessionCoordinator.setYOLOMode(false, sessionID: "ses_yolo", client: client)
        XCTAssertFalse(disabled.allowsAllSessionPermissions)
        XCTAssertEqual(disabled.permissions, original)
        XCTAssertEqual(methods, ["GET", "PATCH", "GET", "GET", "PATCH", "GET"])
    }

    func testYOLOModeFailedWriteDoesNotChangeCanonicalSession() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let client = try XCTUnwrap(model.requireBackendConnection().openCodeCompatibility?.client)
        let session = Self.session(id: "ses_yolo", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.httpMethod == "PATCH" { return (500, #"{"message":"Failed"}"#) }
            return (200, #"{"data":{"id":"ses_yolo","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2}}}"#)
        }
        do {
            _ = try await model.sessionCoordinator.setYOLOMode(true, sessionID: "ses_yolo", client: client)
            XCTFail("A failed write must be surfaced")
        } catch { }
        XCTAssertEqual(model.directoryStore.sessions.first, session)
    }

    func testWorkflowAssignmentReadModifyWritesMetadataAndSurfacesFailure() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let connection = try model.requireBackendConnection()
        let session = Self.session(id: "ses_workflow", directory: "/repo")
        var metadata: [String: OpenCodeJSONValue] = ["another-client": .object(["keep": .string("value")])]
        var methods: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_workflow")
            methods.append(request.httpMethod!)
            if request.httpMethod == "PATCH" {
                let body = try JSONDecoder().decode([String: [String: OpenCodeJSONValue]].self, from: Self.body(request))
                metadata = try XCTUnwrap(body["metadata"])
                XCTAssertEqual(metadata["another-client"], .object(["keep": .string("value")]))
                return (204, "")
            }
            let raw = String(data: try JSONEncoder().encode(metadata), encoding: .utf8)!
            return (200, #"{"data":{"id":"ses_workflow","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2},"metadata":\#(raw)}}"#)
        }
        let updated = try await ActivityWorkflowCoordinator.assign(.inProgress, to: session, connection: connection)
        XCTAssertEqual(ActivityWorkflowStatus.annotation(in: try XCTUnwrap(updated)), .inProgress)
        XCTAssertEqual(methods, ["GET", "PATCH", "GET"])
        V2SessionWorkflowURLProtocol.handler = { _ in (500, #"{"message":"Failed"}"#) }
        do {
            _ = try await ActivityWorkflowCoordinator.assign(.archived, to: session, connection: connection)
            XCTFail("A failed server write must not become a local assignment")
        } catch { }
    }

    func testViewedEventsAreMonotonicAndRenamePreservesUnreadState() throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        var session = Self.session(id: "ses_read", directory: "/repo")
        XCTAssertFalse(session.isUnread)
        session.time = .init(created: 1, updated: 2, idle: 200, viewed: 100)
        model.directoryStore.insertV2Session(session)
        func apply(_ type: String, _ data: String) throws {
            let raw = #"{"type":"session.\#(type)","location":{"directory":"/repo"},"data":{"sessionID":"ses_read",\#(data)}}"#
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw))
            XCTAssertTrue(model.directoryStore.applyV2Event(event))
        }
        try apply("renamed", #""title":"Renamed""#)
        XCTAssertEqual(model.directoryStore.sessions.first?.isUnread, true)
        try apply("viewed", #""idle":100"#)
        XCTAssertEqual(model.directoryStore.sessions.first?.isUnread, true)
        try apply("viewed", #""idle":200"#)
        XCTAssertEqual(model.directoryStore.sessions.first?.isUnread, false)
        try apply("viewed", #""idle":100"#)
        XCTAssertEqual(model.directoryStore.sessions.first?.time?.viewed, 200)
    }

    func testMarkReadFailureLeavesSessionUnread() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        _ = try model.requireBackendConnection()
        var session = Self.session(id: "ses_read", directory: "/repo")
        session.time = .init(idle: 100)
        model.directoryStore.insertV2Session(session)
        V2SessionWorkflowURLProtocol.handler = { _ in (500, #"{"message":"Failed"}"#) }
        await model.markSessionRead(session)
        XCTAssertEqual(model.directoryStore.sessions.first?.isUnread, true)
        XCTAssertNotNil(model.errorMessage)
    }

    func testVisibleChatMarksReadOnOpenAndNewCompletionButNotWhileInactiveOrLoading() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        var session = Self.session(id: "ses_read", directory: "/repo")
        session.time = .init(idle: 100)
        _ = model.beginSessionNavigation(session)
        model.directoryStore.insertV2Session(session)
        let facade = model.chatFacade
        XCTAssertNil(facade.presentedReadKey(for: session, isSceneActive: true), "Do not mark a blank transcript read")
        let message = try JSONDecoder().decode(OpenCodeMessageEnvelope.self,
            from: Data(#"{"info":{"id":"msg_read","sessionID":"ses_read","role":"assistant"},"parts":[]}"#.utf8))
        model.directoryStore.applyV2Messages([message], forSessionID: session.id)
        model.chatStore.isLoadingSelectedSession = true
        XCTAssertNil(facade.presentedReadKey(for: session, isSceneActive: true))
        model.chatStore.isLoadingSelectedSession = false
        XCTAssertNil(facade.presentedReadKey(for: session, isSceneActive: false))
        let firstKey = try XCTUnwrap(facade.presentedReadKey(for: session, isSceneActive: true))
        var acknowledgements: [Double] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Double]
                acknowledgements.append(try XCTUnwrap(body?["idle"]))
                return (204, "")
            }
            let idle = Int(acknowledgements.last ?? 0)
            return (200, #"{"data":{"id":"ses_read","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2,"idle":\#(idle),"viewed":\#(idle)}}}"#)
        }
        await facade.markPresentedSessionRead(session, isSceneActive: false)
        XCTAssertTrue(acknowledgements.isEmpty)
        await facade.markPresentedSessionRead(session, isSceneActive: true)
        let read = try XCTUnwrap(model.directoryStore.sessions.first)
        XCTAssertFalse(read.isUnread)
        XCTAssertEqual(facade.presentedReadKey(for: read, isSceneActive: true), firstKey)
        await facade.markPresentedSessionRead(read, isSceneActive: true)
        session.time = .init(idle: 200, viewed: 100)
        model.directoryStore.insertV2Session(session)
        XCTAssertNotEqual(facade.presentedReadKey(for: session, isSceneActive: true), firstKey)
        await facade.markPresentedSessionRead(session, isSceneActive: true)
        XCTAssertEqual(acknowledgements, [100, 200])
        _ = model.beginSessionNavigation(Self.session(id: "ses_other", directory: "/repo"))
        await facade.markPresentedSessionRead(session, isSceneActive: true)
        XCTAssertEqual(acknowledgements, [100, 200], "An old presentation cannot acknowledge after navigation")
    }

    func testMarkReadMergesAcknowledgementDespiteConcurrentSessionChangesAndClearsListCaches() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        _ = try model.requireBackendConnection()
        var session = Self.session(id: "ses_read", directory: "/repo")
        session.time = .init(created: 1, updated: 2, idle: 100)
        model.directoryStore.insertV2Session(session)
        model.sessionListStore.recentSessionsByDirectory["/repo"] = [session]
        var workspace = OpenCodeWorkspaceSessionState()
        workspace.sessions = [session]
        model.sessionListStore.workspaceSessionsByDirectory["/repo"] = workspace
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let raw = #"{"type":"session.renamed","location":{"directory":"/repo"},"data":{"sessionID":"ses_read","title":"New title"}}"#
                _ = model.directoryStore.applyV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw)))
                return (204, "")
            }
            return (200, #"{"data":{"id":"ses_read","title":"Old title","projectID":"proj_root","location":{"directory":"/repo"},"time":{"created":1,"updated":2,"idle":100,"viewed":100}}}"#)
        }
        await model.markSessionRead(session)
        XCTAssertEqual(model.directoryStore.sessions.first?.title, "New title")
        XCTAssertEqual(model.directoryStore.sessions.first?.isUnread, false)
        XCTAssertEqual(model.sessionListStore.recentSessionsByDirectory["/repo"]?.first?.isUnread, false)
        XCTAssertEqual(model.sessionListStore.workspaceSessionsByDirectory["/repo"]?.sessions.first?.isUnread, false)
    }

    func testMarkAllReadEnumeratesProjectPagesAndPreservesTapTimeWatermarks() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let connection = try model.requireBackendConnection()
        var observed = Self.session(id: "ses_observed", directory: "/repo")
        observed.time = .init(idle: 100)
        var alreadyRead = Self.session(id: "ses_read", directory: "/repo")
        alreadyRead.time = .init(idle: 80, viewed: 80)
        func record(_ id: String, idle: Int, viewed: Int = 0, directory: String = "/repo") -> String {
            #"{"id":"\#(id)","projectID":"proj_root","location":{"directory":"\#(directory)"},"time":{"created":1,"updated":2,"idle":\#(idle),"viewed":\#(viewed)}}"#
        }
        let first = [record("ses_observed", idle: 300), record("ses_read", idle: 150)]
            + (0..<98).map { record("ses_filler\($0)", idle: 50, viewed: 50) }
        let second = [record("ses_workspace", idle: 90, directory: "/worktree"), record("ses_new", idle: 300)]
        var cursors: [String?] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Discovery must finish before acknowledgements begin")
            XCTAssertEqual(request.url?.path, "/api/session")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let cursor = query.first { $0.name == "cursor" }?.value
            cursors.append(cursor)
            XCTAssertFalse(query.contains { $0.name == "directory" || $0.name == "workspace" })
            if cursor == nil {
                XCTAssertEqual(query.first { $0.name == "project" }?.value, "proj_root")
                return (200, #"{"data":[\#(first.joined(separator: ","))],"cursor":{"next":"page2"}}"#)
            }
            return (200, #"{"data":[\#(second.joined(separator: ","))]}"#)
        }
        let targets = try await model.sessionCoordinator.unreadSessions(connection: connection,
            projectIDs: ["proj_root", "proj_root"], observed: [observed, alreadyRead], before: 200)
        XCTAssertEqual(targets.map(\.id), ["ses_observed", "ses_workspace"])
        XCTAssertEqual(targets.map { $0.time?.idle }, [100, 90])
        XCTAssertEqual(cursors, [nil, "page2", "page2"])
    }

    func testSideQuestionUsesGenerateWhileIdleOrBusyWithoutMutatingChatOrDraft() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_side", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        model.directoryStore.insertV2Session(session)
        let connection = try model.requireBackendConnection()
        let window = ChatWindowContext(model: model, connection: connection, session: session, owner: model.directoryStore)
        defer { window.close() }
        XCTAssertTrue(window.isCurrent)
        let facades = [model.chatFacade, ChatFacade(viewModel: model, windowContext: window)]
        var calls = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/ses_side/generate")
            XCTAssertNil(request.url?.query)
            let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String]
            XCTAssertEqual(body, ["prompt": "Why did the test fail?"])
            return (200, #"{"data":{"text":"An explanation, not a new turn"}}"#)
        }
        for facade in facades {
            facade.composerStore.draftMessage = "Keep my main draft"
            for busy in [false, true] {
                model.directoryStore.sessionStatuses[session.id] = busy ? "busy" : "idle"
                XCTAssertTrue(facade.canAskSideQuestion)
                XCTAssertTrue(facade.commands(forSessionID: session.id, canFork: false).contains { $0.name == "btw" && $0.source == "client" })
                let messages = facade.presentationMessages
                let presentation = try XCTUnwrap(facade.makeSideQuestion(prompt: "Why did the test fail?", submitsImmediately: true))
                XCTAssertTrue(presentation.store.isGenerating)
                await presentation.coordinator.answer(store: presentation.store)
                XCTAssertEqual(presentation.store.answer, "An explanation, not a new turn")
                XCTAssertEqual(facade.composerStore.draftMessage, "")
                XCTAssertEqual(facade.presentationMessages, messages)
                XCTAssertTrue(facade.recoveryInputs(sessionID: session.id).isEmpty)
                XCTAssertEqual(model.directoryStore.sessionStatuses[session.id], busy ? "busy" : "idle")
            }
        }
        XCTAssertEqual(calls, 4, "Side questions must only call generate, never prompt, command, or interrupt")
        let empty = try XCTUnwrap(model.chatFacade.makeSideQuestion(prompt: " \n", submitsImmediately: true))
        XCTAssertFalse(empty.store.isGenerating, "An empty side question opens the editor without a request")
    }

    func testSideQuestionCannotStartAfterSessionNavigation() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        _ = model.beginSessionNavigation(Self.session(id: "ses_first", directory: "/repo"))
        let presentation = try XCTUnwrap(model.chatFacade.makeSideQuestion(prompt: "Old context"))
        _ = model.beginSessionNavigation(Self.session(id: "ses_second", directory: "/repo"))
        V2SessionWorkflowURLProtocol.handler = { _ in
            XCTFail("A stale sheet must not send against the old or new session")
            return (500, "")
        }
        presentation.store.ask()
        await presentation.coordinator.answer(store: presentation.store)
        XCTAssertNil(presentation.store.answer)
        XCTAssertFalse(presentation.store.isGenerating)
        model.connectionStore.beginConnecting()
        XCTAssertFalse(model.chatFacade.canAskSideQuestion)
        XCTAssertNil(model.chatFacade.makeSideQuestion(prompt: "Disconnected"))
    }

    func testV2StreamHapticsFollowVisibleAnswerDeltasAndThrottle() throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        model.activeChatSessionID = session.id
        var time = Date(timeIntervalSince1970: 100)
        var impacts = 0
        model.chatStore.streamHapticFeedback = .init(now: { time }, impact: { impacts += 1 }, interval: { 0.1 })
        func emit(_ type: String, delta: String = "Hello", ordinal: Int = 0) throws {
            let raw = #"{"type":"session.\#(type)","location":{"directory":"/repo"},"data":{"sessionID":"ses_v2","assistantMessageID":"msg_answer","ordinal":\#(ordinal),"delta":"\#(delta)"}}"#
            model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw)))
        }
        try emit("text.started")
        XCTAssertEqual(impacts, 0)
        try emit("text.delta")
        XCTAssertEqual(impacts, 1)
        try emit("text.delta")
        XCTAssertEqual(impacts, 1, "Rapid chunks share the legacy throttle")
        time = time.addingTimeInterval(1)
        try emit("text.delta", delta: " ")
        try emit("reasoning.started")
        try emit("reasoning.delta")
        try emit("text.delta", ordinal: 9)
        XCTAssertEqual(impacts, 1, "Whitespace, reasoning, and unprojected parts are silent")
        model.activeChatSessionID = nil
        try emit("text.delta")
        XCTAssertEqual(impacts, 1, "Background chat is silent")
        model.activeChatSessionID = session.id
        try emit("text.delta")
        XCTAssertEqual(impacts, 2)
    }

    func testReconnectKeepsV2ProjectCatalogConsistentWithRefresh() async throws {
        for projectID in ["proj_root", "global"] {
            let model = makeModel()
            defer { model.stopEventStream() }
            var projectReads = 0
            V2SessionWorkflowURLProtocol.handler = { request in
                switch request.url?.path {
                case "/api/location":
                    return (200, #"{"directory":"/workspace","project":{"id":"\#(projectID)","directory":"/","canonical":"/"}}"#)
                case "/api/project":
                    projectReads += 1
                    return (200, #"[{"id":"\#(projectID)","canonical":"/","time":{"created":1,"updated":1},"sandboxes":[]}]"#)
                default:
                    return (404, #"{"message":"Not configured"}"#)
                }
            }
            try await model.refreshProjects()
            let initialProjects = model.projects
            XCTAssertEqual(initialProjects.map(\.id), [projectID])

            model.directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
            model.scheduleV2TimelineReconciliation(immediate: true)
            await model.v2TimelineReconcileTask?.value

            XCTAssertEqual(projectReads, 2)
            XCTAssertEqual(model.projects, initialProjects, "Reconnect must not synthesize a legacy Global row")
            try await model.refreshProjects()
            XCTAssertEqual(model.projects, initialProjects)
        }
    }

    func testReconnectDoesNotReadIdleHistoryAndReconcilesOpenActiveAndPendingChatsOnce() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let ids = (0..<200).map { "idle-\($0)" } + ["selected", "running", "resolved", "window"]
        model.directoryStore.sessions = ids.map { Self.session(id: $0, directory: "/repo") }
        model.directoryStore.selectedSession = Self.session(id: "selected", directory: "/repo")
        model.windowSessionInterests[UUID()] = "window"
        model.directoryStore.syncState.permissionsBySessionID["resolved"] = [
            .init(id: "old", sessionID: "resolved", permission: "shell", patterns: [], always: nil, metadata: nil, tool: nil)
        ]
        var transcriptReads: [String] = []
        var sessionReads: [String] = []
        let permission = #"{"id":"pending","sessionID":"attention","action":"shell","resources":["*"]}"#
        func info(_ id: String) -> String {
            #"{"id":"\#(id)","projectID":"global","location":{"directory":"/repo"},"time":{"created":1,"updated":1}}"#
        }
        V2SessionWorkflowURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            switch path {
            case "/api/location": return (200, #"{"directory":"/repo","project":{"id":"global","directory":"/","canonical":"/"}}"#)
            case "/api/project": return (200, #"[{"id":"global","canonical":"/","time":{"created":1,"updated":1},"sandboxes":[]}]"#)
            case "/api/session": return (200, #"{"data":[\#(ids.map(info).joined(separator: ","))],"cursor":{}}"#)
            case "/api/session/active": return (200, #"{"data":{"running":{"type":"running"}}}"#)
            case "/api/permission/request": return (200, #"{"data":[\#(permission)]}"#)
            case "/api/form": return (200, #"{"location":{"directory":"/repo"},"data":[]}"#)
            default: break
            }
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 3, components[0] == "api", components[1] == "session" else { return (404, "{}") }
            let id = components[2]
            if components.count == 3 {
                sessionReads.append(id)
                return (200, #"{"data":\#(info(id))}"#)
            }
            switch components.last {
            case "message":
                transcriptReads.append(id)
                return (200, Self.page("message-\(id)"))
            case "permission": return (200, #"{"data":[\#(id == "attention" ? permission : "")]}"#)
            case "form": return (200, #"{"data":[]}"#)
            default: return (404, "{}")
            }
        }
        model.directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
        model.scheduleV2TimelineReconciliation(immediate: true)
        await model.v2TimelineReconcileTask?.value

        let expected = ["selected", "attention", "resolved", "running", "window"]
        XCTAssertEqual(transcriptReads, expected, "Visible chat first; no idle-history scan or duplicate pass")
        XCTAssertEqual(sessionReads, expected)
        XCTAssertTrue(model.directoryStoreRegistry.v2PendingSessionIDs.isEmpty)
        XCTAssertNil(model.directoryStore.syncState.permissionsBySessionID["resolved"])
        XCTAssertEqual(model.directoryStoreRegistry.ownerStore(forSessionID: "attention")?.syncState.permissionsBySessionID["attention"]?.map(\.id), ["pending"])
    }

    func testCommittedRootTranscriptReachesExistingGlobalOwnerWindowsBeforeBridgeRetirement() async throws {
        for viaHTTP in [true, false] {
            let model = makeModel()
            defer { model.stopEventStream() }
            let session = Self.session(id: "ses_v2", directory: "/repo/worktree")
            let global = model.directoryStoreRegistry.activate(nil)
            global.insertV2Session(session)
            let connection = try model.requireBackendConnection()
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "local longer content", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            let header = OpenCodeMessageEnvelope(info: input.info, parts: [])
            model.chatStore.beginV2TranscriptHydration(sessionID: session.id)
            XCTAssertTrue(model.chatStore.applyInitialV2Transcript([header], olderCursor: nil, sessionID: session.id))
            global.applyV2Messages([header], forSessionID: session.id)
            let windows = (0..<2).map { _ in ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                connection: connection, session: session, owner: global)) }
            defer { windows.forEach { $0.windowContext?.close() } }
            windows[0].composerStore.draftMessage = "Window draft"
            _ = model.beginSessionNavigation(session)
            let root = model.directoryStore
            XCTAssertFalse(root === global)
            let otherWorkspace = OpenCodeSession(id: session.id, title: nil, workspaceID: "other-workspace",
                directory: session.directory, projectID: nil, parentID: nil)
            let foreign = model.directoryStoreRegistry.store(for: "/foreign-container")
            foreign.insertV2Session(otherWorkspace)
            let foreignMessage = OpenCodeMessageEnvelope.local(role: "user", text: "Other workspace", messageID: input.id, sessionID: session.id)
            foreign.applyV2Messages([foreignMessage], forSessionID: session.id)
            let facades = [model.chatFacade] + windows
            func visible(_ facade: ChatFacade, recoveries: [ChatStore.SubmissionRecovery]) -> [OpenCodeMessageEnvelope] {
                let canonical = facade.directoryStore(forSessionID: session.id).syncState.messageEnvelopes(forSessionID: session.id)
                return SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: recoveries)
                    .filter { MessageBubbleMessageVisibilityPolicy.shouldDisplay($0, showsToolCalls: true, showsReasoningBlocks: true) }
            }
            for facade in facades {
                XCTAssertEqual(visible(facade, recoveries: facade.recoveryInputs(sessionID: session.id)).map(\.id), [input.id])
            }
            var retirementSnapshots = 0
            let observation = model.chatStore.$submissionRecoveries.dropFirst().sink { recoveries in
                guard recoveries[input.id] == nil else { return }
                retirementSnapshots += 1
                for facade in facades {
                    let rows = visible(facade, recoveries: Array(recoveries.values))
                    XCTAssertEqual(rows.map(\.id), [input.id], "Every actual presentation source must be committed before retirement")
                    XCTAssertEqual(rows.first?.parts.first?.text, "canonical")
                }
            }
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET", "Propagating a commit must not submit or retry a prompt")
                XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
                return (200, Self.page(input.id))
            }
            if viaHTTP {
                let hydrated = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
                    expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
                XCTAssertTrue(hydrated)
            } else {
                XCTAssertTrue(model.chatStore.applyInitialV2Transcript([header], olderCursor: nil, sessionID: session.id))
                root.applyV2Messages([header], forSessionID: session.id)
                for json in [
                    #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_local","input":{"type":"user","delivery":"steer","data":{"text":"canonical"}}}}"#,
                    #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"msg_local"}}"#
                ] {
                    model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
                }
            }
            await Task.yield()
            XCTAssertEqual(retirementSnapshots, 1)
            XCTAssertTrue(model.chatStore.recoveryInputs(sessionID: session.id).isEmpty)
            for facade in facades {
                XCTAssertEqual(visible(facade, recoveries: []).first?.parts.first?.text, "canonical")
                XCTAssertEqual(facade.presentationMessages, root.syncState.messageEnvelopes(forSessionID: session.id))
            }
            XCTAssertEqual(windows[0].composerStore.draftMessage, "Window draft")
            XCTAssertEqual(foreign.syncState.messageEnvelopes(forSessionID: session.id), [foreignMessage])
            for json in [
                #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_answer","ordinal":0}}"#,
                #"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_answer","ordinal":0,"delta":"Live answer"}}"#
            ] {
                model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
            }
            for facade in facades {
                XCTAssertEqual(facade.presentationMessages.last?.parts.first?.text, "Live answer", "Copies stay current after the bridge retires")
            }
            withExtendedLifetime(observation) {}
        }
    }

    func testRevertAfterHeaderClearsOnlyInclusiveCanonicalRangeAndHTTPDoesNotResurrectBridge() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        owner.insertV2Session(session)
        let connection = try model.requireBackendConnection()
        let ids = ["before", "boundary", "after"]
        for id in ids {
            XCTAssertTrue(model.chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: id,
                text: "Local \(id)", scope: .init(directory: session.directory)), connectionID: connection.id))
            model.chatStore.applyPromptAdmission(.admitted, messageID: id, connectionID: connection.id)
        }
        var canonicalIDs = ids
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
            reads += 1
            let records = canonicalIDs.enumerated().reversed().map { index, id in
                #"{"id":"\#(id)","type":"user","text":"","time":{"created":\#(index + 1)}}"#
            }.joined(separator: ",")
            return (200, #"{"data":[\#(records)],"cursor":{}}"#)
        }
        let hydrated = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(hydrated)
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ids)
        let unknown = OpenCodeMessageEnvelope.local(role: "user", text: "Unknown input", messageID: "unknown", sessionID: session.id)
        model.chatStore.stageSubmissionPresentation(unknown, sessionID: session.id,
            canonical: owner.syncState.messageEnvelopes(forSessionID: session.id), attachments: [], agentMentions: [])
        model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"unknown","input":{"type":"user","delivery":"steer","data":{"text":"Canonical unknown"}}}}"#)))
        let ledger = model.chatStore.canonicalSubmissionSessions
        let usage = model.usageMeter
        for boundary in ["not-loaded", "boundary"] {
            let json = #"{"type":"session.revert.committed","data":{"sessionID":"ses_v2","to":"\#(boundary)"}}"#
            model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
            if boundary == "not-loaded" {
                XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), Set(ids + ["unknown"]))
            }
        }
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["before"], "The boundary is removed inclusively before any HTTP reconciliation")
        XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), ["before", "unknown"])
        canonicalIDs = ["before"]
        for _ in 0..<2 {
            await model.reconcileV2TimelineFromEvent(sessionID: session.id)
            XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["before"])
            XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), ["before", "unknown"])
            let projected = SubmissionTranscriptPresentation.messages(canonical: model.chatFacade.presentationMessages,
                recoveries: model.chatFacade.recoveryInputs(sessionID: session.id))
            XCTAssertFalse(projected.contains { $0.id == "boundary" || $0.id == "after" })
            XCTAssertEqual(model.chatStore.canonicalSubmissionSessions, ledger)
            XCTAssertEqual(model.chatStore.applyPromptAdmission(.rejected, messageID: "boundary", connectionID: connection.id), .admitted)
            XCTAssertFalse(model.chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: "boundary", text: "Resend", scope: .init()), connectionID: connection.id))
            XCTAssertEqual(model.usageMeter, usage)
        }
        XCTAssertGreaterThanOrEqual(reads, 3)
        model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"unknown"}}"#)))
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).last?.parts.first?.text, "Canonical unknown",
            "An input outside the explicit canonical range must keep its admission payload")
    }

    func testInitialHydrationRetriesStreamRaceBeforePublishingDirectory() async throws {
        let model = makeModel()
        var session = Self.session(id: "ses_v2", directory: "/repo")
        session.agent = "plan"
        model.modelConfigurationStore.selectedAgentNamesBySessionID[session.id] = "build"
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
            reads += 1
            if reads == 1 {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: session.id)
                return (200, Self.page("msg_stale"))
            }
            XCTAssertFalse(owner.syncState.messageEnvelopes(forSessionID: session.id).contains { $0.id == "msg_stale" })
            return (200, Self.page("msg_canonical"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertTrue(accepted)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_canonical"])
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["msg_canonical"])
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.modelConfigurationStore.selectedAgentNamesBySessionID[session.id], "plan")
        XCTAssertEqual(model.sessionPreviews[session.id]?.text, "canonical")
    }

    func testV2ProjectActionsAreUnavailableAtBothSnapshotAndIntent() async {
        let model = makeModel()
        let action = OpenCodeAction(commandName: "review", iconName: "bolt")
        model.projectActionsByScope[model.currentProjectPreferenceScopeKey] = [action]
        model.directoryCommands = [.init(name: "review", description: nil, agent: nil, model: nil,
            source: "command", template: "review", subtask: false, hints: [])]
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTFail("Unsupported action must not create hidden work: \(request.url?.path ?? "nil")")
            return (500, "{}")
        }
        XCTAssertFalse(model.supportsProjectActionExecution)
        XCTAssertTrue(model.sessionListFacade.snapshot.currentProjectActions.isEmpty)
        await model.sessionListFacade.runAction(action)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.pendingActionRunsBySessionID.isEmpty)
    }

    func testInitialHydrationCannotPublishAfterServerReset() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        V2SessionWorkflowURLProtocol.handler = { _ in
            model.directoryStoreRegistry.reset()
            model.chatStore.clearActiveTranscript()
            model.errorMessage = "new connection"
            return (200, Self.page("msg_stale"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertFalse(accepted)
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        XCTAssertEqual(model.errorMessage, "new connection")
        XCTAssertEqual(model.chatDetailPresentationRequest, 0)
    }

    func testReconcilerCompletingInitialHydrationPresentsDetailOnlyOnce() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: session.id)
                await model.reconcileV2TimelineFromEvent(sessionID: session.id)
                XCTAssertEqual(model.chatDetailPresentationRequest, 1)
                return (200, Self.page("msg_stale"))
            }
            return (200, Self.page("msg_canonical"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_canonical"])
    }

    func testHydrationCannotPresentDetailAfterNavigatingAway() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        V2SessionWorkflowURLProtocol.handler = { _ in
            _ = model.beginSessionNavigation(Self.session(id: "ses_other", directory: "/other"))
            return (200, Self.page("msg_stale"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatDetailPresentationRequest, 0)
        XCTAssertEqual(model.selectedSession?.id, "ses_other")
        XCTAssertEqual(model.directoryStoreRegistry.activeKey, "/other")
    }

    func testListNavigationPreservesOutgoingTextAndMentionsAndResetsIncomingComposer() {
        let model = makeModel()
        let first = Self.session(id: "ses_v2", directory: "/repo")
        let second = Self.session(id: "ses_other", directory: "/other")
        let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 0, end: 8)
        _ = model.beginSessionNavigation(first)
        model.composerStore.resetActiveDraft(text: "@explore inspect", agentMentions: [mention], attachments: [
            .init(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        ])
        model.composerStore.draftsByChatKey[model.messageDraftStorageKey(for: second)] = .init(text: "second draft")

        _ = model.beginSessionNavigation(second)

        XCTAssertEqual(model.composerStore.draft(forKey: model.messageDraftStorageKey(for: first))?.text, "@explore inspect")
        XCTAssertEqual(model.composerStore.draft(forKey: model.messageDraftStorageKey(for: first))?.agentMentions, [mention])
        XCTAssertEqual(model.draftMessage, "second draft")
        XCTAssertTrue(model.draftAgentMentions.isEmpty)
        XCTAssertTrue(model.draftAttachments.isEmpty)

        _ = model.beginSessionNavigation(first)
        XCTAssertEqual(model.draftMessage, "@explore inspect")
        XCTAssertEqual(model.draftAgentMentions, [mention])
    }

    func testGlobalCreationUsesConcreteLocationAndPresentsHydratedSession() async throws {
        let model = makeModel()
        guard model.hasProUnlock else { throw XCTSkip("Creation tests require the debug entitlement to avoid metering persistence.") }
        model.currentProject = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        model.selectedDirectory = nil
        // This test bypasses connection bootstrap; provide its concrete execution location.
        model.projectStore.defaultServerDirectory = "/actual/workspace"
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                XCTAssertEqual((body["location"] as? [String: Any])?["directory"] as? String, "/actual/workspace")
                return (200, #"{"data":{"id":"ses_created","projectID":"global","location":{"directory":"/actual/workspace"},"agent":"plan","model":{"providerID":"openai","id":"server-model","variant":"high"},"time":{"created":1,"updated":2},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
            case "/api/session/active":
                return (200, #"{"data":{}}"#)
            case "/api/session/ses_created/message":
                XCTAssertEqual(model.selectedSession?.id, "ses_created")
                XCTAssertEqual(model.chatDetailPresentationRequest, 0)
                return (200, #"{"data":[],"cursor":{}}"#)
            case "/api/session/ses_created/permission", "/api/session/ses_created/form":
                return (200, #"{"data":[]}"#)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }

        await model.createSession()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.directoryStoreRegistry.activeKey, "/actual/workspace")
        XCTAssertEqual(model.chatStore.preparedSessionID, "ses_created")
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.modelConfigurationStore.selectedAgentNamesBySessionID["ses_created"], "plan")
        XCTAssertEqual(model.modelConfigurationStore.selectedModelsBySessionID["ses_created"], .init(providerID: "openai", modelID: "server-model"))
        XCTAssertEqual(model.modelConfigurationStore.selectedVariantsBySessionID["ses_created"], "high")
    }

    func testRejectedBackgroundPromptRollsBackCacheWithoutTouchingNewChatOrUsage() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        let other = Self.session(id: "ses_other", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let usage = model.usageMeter
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/prompt")
            XCTAssertEqual(model.chatStore.cachedMessagesBySessionID[session.id]?.first?.parts.first?.id,
                model.chatStore.cachedMessagesBySessionID[session.id]?.first.map { "\($0.id):v2:text:0" })
            _ = model.beginSessionNavigation(other)
            let message = OpenCodeMessageEnvelope.local(role: "user", text: "other chat", messageID: "other", sessionID: other.id)
            model.chatStore.applyInitialV2Transcript([message], olderCursor: nil, sessionID: other.id)
            model.errorMessage = "other error"
            return (422, #"{"message":"Rejected"}"#)
        }

        let accepted = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.selectedSession?.id, other.id)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["other"])
        XCTAssertTrue(model.chatStore.cachedMessagesBySessionID[session.id]?.isEmpty == true)
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertEqual(model.errorMessage, "other error")
        XCTAssertEqual(model.usageMeter, usage)
    }

    func testUncertainAdmissionPreservesDraftAndBlocksDuplicatePOST() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        model.draftMessage = "hello"
        var posts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1
                return (503, #"{"message":"Receipt unavailable"}"#)
            }
            return (404, #"{"message":"Projection not ready"}"#)
        }

        let accepted = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)
        model.stopEventStream()
        let retry = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)

        XCTAssertFalse(accepted)
        XCTAssertFalse(retry)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.draftMessage, "hello")
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testReconciliationBridgesGapAndRemovesRevertedLoadedRecords() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let old = OpenCodeMessageEnvelope.local(role: "user", text: "old", messageID: "msg_old", sessionID: session.id)
        let reverted = OpenCodeMessageEnvelope.local(role: "user", text: "reverted", messageID: "msg_reverted", sessionID: session.id)
        model.chatStore.applyInitialV2Transcript([old, reverted], olderCursor: nil, sessionID: session.id)
        let newestIDs = (0 ..< 200).map { "msg_new_\($0)" }
        let records = newestIDs.reversed().map { #"{"id":"\#($0)","type":"user","text":"canonical","time":{"created":1}}"# }.joined(separator: ",")
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            reads += 1
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            if reads == 1 {
                XCTAssertEqual(query, [.init(name: "order", value: "desc"), .init(name: "limit", value: "200")])
                return (200, #"{"data":[\#(records)],"cursor":{"next":"older"}}"#)
            }
            XCTAssertEqual(query, [.init(name: "cursor", value: "older"), .init(name: "limit", value: reads == 2 ? "1" : "200")])
            return (200, Self.page("msg_old"))
        }

        await model.reconcileV2TimelineFromEvent(sessionID: session.id)

        XCTAssertEqual(reads, 3, "Existence probe must not consume the older page needed for reconciliation")
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_old"] + newestIDs)
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["msg_old"] + newestIDs)
        XCTAssertFalse(model.chatStore.hasOlderV2Messages(sessionID: session.id))
    }

    func testHydratingOneSessionPreservesOtherSessionsAndRacingPermission() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let other = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"permission.asked","data":{"sessionID":"ses_other","id":"perm_other","action":"read","resources":["*"]}}"#))
        _ = model.directoryStore.applyV2Event(other)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasPrefix("/api/session/ses_v2/") == true)
            if request.url?.path.hasSuffix("/permission") == true {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"permission.asked","data":{"sessionID":"ses_v2","id":"perm_live","action":"read","resources":["*"]}}"#))
                _ = model.directoryStore.applyV2Event(event)
            }
            return (200, #"{"data":[]}"#)
        }

        await model.hydrateV2Interactions(for: session)

        XCTAssertEqual(model.directoryStore.syncState.permissionsBySessionID["ses_other"]?.map(\.id), ["perm_other"])
        XCTAssertEqual(model.directoryStore.syncState.permissionsBySessionID[session.id]?.map(\.id), ["perm_live"])
    }

    func testOnlyDefinitiveAdmissionFailuresAllowRollbackAndRetry() {
        for code in [400, 401, 403, 404, 422, 429] { XCTAssertTrue(AppViewModel.isDefinitiveV2PromptRejection(code)) }
        for code in [200, 408, 409, 500, 502, 503, 504] { XCTAssertFalse(AppViewModel.isDefinitiveV2PromptRejection(code)) }
    }

    func testPendingInboxReadResolvesExactIDWithoutResendingPrompt() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: message.id, sessionID: session.id)
        var paths: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/inbox") == true {
                return (200, #"{"data":[{"id":"msg_pending"}]}"#)
            }
            return (404, #"{"message":"Still queued"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: message.id)

        XCTAssertTrue(accepted)
        XCTAssertEqual(paths, ["/api/session/ses_v2/message/msg_pending", "/api/session/ses_v2/inbox"])
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertEqual(model.chatStore.submissionRecoveries[message.id]?.phase, .admitted)
    }

    func testPendingInputAbsenceDoesNotUnlockOrSwitchEndpoint() async {
        let model = makeModel()
        model.connectionStore.serverVersion = "2.0.0-next-17155"
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: message.id, sessionID: session.id)
        var paths: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/pending") == true { return (200, #"{"data":[{"id":"msg_unrelated"}]}"#) }
            return (404, #"{"message":"Not found"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: message.id)

        XCTAssertFalse(accepted)
        XCTAssertEqual(paths, ["/api/session/ses_v2/message/msg_pending", "/api/session/ses_v2/pending"])
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testUncertainPOSTIsConfirmedByQueuedInputWithoutAnotherPOST() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        var promptPosts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_v2/prompt":
                promptPosts += 1
                return (503, #"{"message":"Receipt lost"}"#)
            case "/api/session/ses_v2/message/msg_queued":
                return (404, #"{"message":"Still queued"}"#)
            case "/api/session/ses_v2/inbox":
                return (200, #"{"data":[{"id":"msg_queued"}]}"#)
            case "/api/experimental/session/ses_v2/wait":
                XCTAssertEqual(model.chatStore.submissionRecoveries["msg_queued"]?.phase, .admitted)
                return (204, "")
            case "/api/session/ses_v2/message":
                return (200, #"{"data":[],"cursor":{}}"#)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }

        let accepted = await model.sendV2TextPrompt("queued", in: session, meterPrompt: false, messageID: "msg_queued")

        XCTAssertTrue(accepted)
        XCTAssertEqual(promptPosts, 1)
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_queued"]?.phase, .admitted)
    }

    func testAdmissionReturnsWhileCompletionIsHeld() async {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let waiting = expectation(description: "Completion wait is held")
        let returned = expectation(description: "Admission returns before completion")
        let reconciled = expectation(description: "Completion still reconciles canonical messages")
        var release: CheckedContinuation<Void, Never>?
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_v2/prompt":
                return (200, #"{"data":{"id":"msg_first","sessionID":"ses_v2","time":{"created":1},"type":"user","payload":{},"delivery":"queue"}}"#)
            case "/api/experimental/session/ses_v2/wait":
                await withCheckedContinuation { release = $0; waiting.fulfill() }
                return (204, "")
            case "/api/session/ses_v2/message":
                reconciled.fulfill()
                return (200, Self.page("msg_first"))
            default:
                XCTFail("Unexpected request")
                throw URLError(.unsupportedURL)
            }
        }
        let submission = Task {
            let accepted = await model.sendV2TextPrompt("first", in: session, meterPrompt: false, messageID: "msg_first")
            XCTAssertTrue(accepted)
            returned.fulfill()
        }
        await fulfillment(of: [waiting, returned], timeout: 1)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_first"]?.phase, .admitted)
        release?.resume()
        await submission.value
        await fulfillment(of: [reconciled], timeout: 1)
    }

    func testFinishingAnAdmittedRequestCannotChangeNewerAdmissionState() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let completionObserved = expectation(description: "Completion observes a newer submission")
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/prompt") == true {
                return (200, #"{"data":{"id":"msg_first","sessionID":"ses_v2","time":{"created":1},"type":"user","payload":{},"delivery":"queue"}}"#)
            }
            XCTAssertTrue(request.url?.path.hasSuffix("/wait") == true)
            let second = OpenCodeMessageEnvelope.local(role: "user", text: "second", messageID: "msg_second", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(second, sessionID: session.id))
            completionObserved.fulfill()
            throw URLError(.timedOut)
        }

        let accepted = await model.sendV2TextPrompt("first", in: session, meterPrompt: false, messageID: "msg_first")
        await fulfillment(of: [completionObserved], timeout: 1)
        model.stopEventStream()

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_first"]?.phase, .admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_second"]?.phase, .submitting)
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testInterruptedCompletionWaitReconcilesWithoutComposerErrorOrResending() async {
        for existingError in [nil, "A newer action failed"] as [String?] {
            let model = makeModel()
            let session = Self.session(id: "ses_v2", directory: "/repo")
            _ = model.beginSessionNavigation(session)
            let reconciled = expectation(description: "Interrupted completion schedules reconciliation")
            var posts = 0
            V2SessionWorkflowURLProtocol.handler = { request in
                switch request.url?.path {
                case "/api/session/ses_v2/prompt":
                    posts += 1
                    return (200, #"{"data":{"id":"msg_first","sessionID":"ses_v2","time":{"created":1},"type":"user","payload":{},"delivery":"queue"}}"#)
                case "/api/experimental/session/ses_v2/wait":
                    model.errorMessage = existingError
                    throw URLError(.networkConnectionLost)
                case "/api/session/ses_v2":
                    XCTAssertEqual(model.errorMessage, existingError)
                    reconciled.fulfill()
                    return (503, #"{"message":"Reconnecting"}"#)
                default:
                    XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                    throw URLError(.unsupportedURL)
                }
            }
            let accepted = await model.sendV2TextPrompt("first", in: session, meterPrompt: false, messageID: "msg_first")
            await fulfillment(of: [reconciled], timeout: 2)
            XCTAssertTrue(accepted)
            XCTAssertEqual(posts, 1)
            XCTAssertEqual(model.errorMessage, existingError)
            XCTAssertEqual(model.chatStore.submissionRecoveries["msg_first"]?.phase, .admitted)
            XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
            model.disconnect()
        }
    }

    func testLateInboxReadCannotConfirmAdmissionInNewServerGeneration() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let original = OpenCodeMessageEnvelope.local(role: "user", text: "original", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(original, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: original.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/inbox") == true {
                model.directoryStoreRegistry.reset()
                model.chatStore.clearCachedMessages(forSessionID: session.id)
                let replacement = OpenCodeMessageEnvelope.local(role: "user", text: "new server", messageID: original.id, sessionID: session.id)
                XCTAssertTrue(model.chatStore.beginV2Prompt(replacement, sessionID: session.id))
                return (200, #"{"data":[{"id":"msg_pending"}]}"#)
            }
            return (404, #"{"message":"Not projected"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: original.id)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[original.id]?.phase, .submitting)
    }

    func testConfirmedPendingIDCannotBeSubmittedAgain() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.confirmSubmissionAdmission(messageID: message.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { _ in
            XCTFail("A confirmed pending ID must not be submitted again")
            throw URLError(.unsupportedURL)
        }

        let accepted = await model.sendV2TextPrompt("queued", in: session, meterPrompt: false, messageID: message.id)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[message.id]?.phase, .admitted)
        XCTAssertFalse(model.chatStore.cachedMessagesBySessionID[session.id]?.contains { $0.id == message.id } == true)
    }

    func testFacadeOlderMessagesCountsCanonicalIDsForRootAndWindow() async throws {
        for inWindow in [false, true] {
            for pageKind in ["empty", "duplicate", "200-new"] {
                let model = makeModel()
                defer { model.disconnect() }
                let connection = try model.requireBackendConnection()
                let root = Self.session(id: "ses_root", directory: "/repo")
                _ = model.beginSessionNavigation(root)
                let session = inWindow ? Self.session(id: "ses_window", directory: "/window") : root
                let owner = model.directoryStoreRegistry.store(for: session.directory)
                owner.insertV2Session(session)
                let context = inWindow ? ChatWindowContext(model: model, connection: connection,
                    session: session, owner: owner) : nil
                defer { context?.close() }
                let facade = inWindow ? ChatFacade(viewModel: model, windowContext: context) : model.chatFacade
                let existing = OpenCodeMessageEnvelope.local(role: "user", text: "canonical",
                    messageID: "msg_existing", sessionID: session.id)
                model.chatStore.beginV2TranscriptHydration(sessionID: session.id)
                XCTAssertTrue(model.chatStore.applyInitialV2Transcript([existing], olderCursor: "older", sessionID: session.id))
                owner.applyV2Messages([existing], forSessionID: session.id)
                let ids = pageKind == "empty" ? [] : pageKind == "duplicate" ? [existing.id]
                    : (1...200).map { "msg_older_\($0)" }
                var reads = 0
                V2SessionWorkflowURLProtocol.handler = { request in
                    reads += 1
                    XCTAssertEqual(request.url?.path, "/api/session/\(session.id)/message")
                    let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                    XCTAssertEqual(query?.first { $0.name == "cursor" }?.value, "older")
                    XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "200")
                    // Growth in another session must not contribute to the facade's result.
                    let unrelated = OpenCodeMessageEnvelope.local(role: "assistant", text: "live",
                        messageID: "msg_unrelated", sessionID: "ses_unrelated")
                    model.directoryStore.applyV2Messages([unrelated], forSessionID: "ses_unrelated")
                    let records = ids.map {
                        #"{"id":"\#($0)","type":"user","text":"canonical","time":{"created":1}}"#
                    }.joined(separator: ",")
                    return (200, #"{"data":[\#(records)],"cursor":{}}"#)
                }

                let added = await facade.loadOlderMessages(for: session, count: 12)

                XCTAssertEqual(reads, 1, "window=\(inWindow), page=\(pageKind)")
                XCTAssertEqual(added, pageKind == "200-new" ? 200 : 0,
                    "window=\(inWindow), page=\(pageKind)")
                XCTAssertEqual(Set(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id)),
                    Set(ids).union([existing.id]))
                XCTAssertEqual(model.selectedSession?.id, root.id)
            }
        }
    }

    private static func session(id: String, directory: String) -> OpenCodeSession {
        OpenCodeSession(id: id, title: nil, workspaceID: nil, directory: directory, projectID: nil, parentID: nil)
    }

    func testRootAndDedicatedWindowsShareCanonicalOrderButNotRecoveryDrafts() throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let connection = try model.requireBackendConnection()
        let owner = model.directoryStore
        owner.insertV2Session(session)
        let a = ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model, connection: connection, session: session, owner: owner))
        let b = ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model, connection: connection, session: session, owner: owner))
        defer { a.windowContext?.close(); b.windowContext?.close() }
        model.composerStore.draftMessage = "New root draft"
        a.composerStore.draftMessage = "New A draft"
        b.composerStore.draftMessage = "New B draft"
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Unconfirmed", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        let first = OpenCodeMessageEnvelope.local(role: "user", text: "Other input", messageID: "msg_other", sessionID: session.id)
        let answer = OpenCodeMessageEnvelope.local(role: "assistant", text: "Canonical answer", messageID: "msg_answer", sessionID: session.id)
        for page in [[first], [first, answer]] {
            model.chatStore.applyV2EventProjection(page, olderCursor: nil, sessionID: session.id)
            owner.applyV2Messages(model.chatStore.cachedMessagesBySessionID[session.id] ?? [], forSessionID: session.id)
            for facade in [model.chatFacade, a, b] {
                XCTAssertEqual(facade.presentationMessages, page)
                XCTAssertEqual(facade.recoveryInputs(sessionID: session.id).map(\.message), [input])
            }
        }
        model.chatStore.applyV2EventProjection([input, first, answer], olderCursor: nil, sessionID: session.id)
        owner.applyV2Messages(model.chatStore.cachedMessagesBySessionID[session.id] ?? [], forSessionID: session.id)
        model.chatStore.retireSubmissionPresentations(in: owner.syncState.messageEnvelopes(forSessionID: session.id), sessionID: session.id)
        for facade in [model.chatFacade, a, b] {
            XCTAssertEqual(facade.presentationMessages, [input, first, answer])
            XCTAssertTrue(facade.recoveryInputs(sessionID: session.id).isEmpty)
            XCTAssertTrue(facade.isPromptAdmitted(messageID: input.id, sessionID: session.id))
        }
        XCTAssertEqual(model.composerStore.draftMessage, "New root draft")
        XCTAssertEqual(a.composerStore.draftMessage, "New A draft")
        XCTAssertEqual(b.composerStore.draftMessage, "New B draft")
    }

    func testCheckRecoveryStatusUsesOnlyReadsForUncertainAndAdmittedInputs() async throws {
        for queued in [false, true] {
            let model = makeModel()
            model.connectionStore.serverVersion = "0.0.0-next-17155"
            let session = Self.session(id: "ses_v2", directory: "/repo")
            _ = model.beginSessionNavigation(session)
            model.directoryStore.insertV2Session(session)
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "Keep", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
            if queued { model.chatStore.confirmSubmissionAdmission(messageID: input.id, sessionID: session.id) }
            var paths: [String] = []
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET", "Check status must never submit or wait via POST")
                let path = request.url!.path
                paths.append(path)
                if path.hasSuffix("/message/msg_local") { return (404, "{}") }
                return (200, #"{"data":[]}"#)
            }
            await model.chatFacade.checkRecoveryStatus(messageID: input.id, sessionID: session.id)
            XCTAssertTrue(paths.contains("/api/session/ses_v2/message/msg_local"))
            XCTAssertTrue(paths.contains("/api/session/ses_v2/pending"))
            XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, queued ? .admitted : .uncertain)
            XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.pendingStatusUnknown, queued)
            XCTAssertTrue(model.chatStore.messages.isEmpty)
        }
    }

    func testReadPromotionBetweenExactAndPendingMissesRemainsUnknownUntilCanonicalPage() async {
        let model = makeModel()
        model.connectionStore.serverVersion = "0.0.0-next-17155"
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/message/msg_local") { return (404, "{}") }
            if request.url!.path.hasSuffix("/pending") { return (200, #"{"data":[]}"#) }
            return (200, Self.page("msg_local"))
        }
        let admitted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id)
        XCTAssertFalse(admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .uncertain)
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertNil(model.chatStore.submissionRecoveries[input.id])
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: input.id, sessionID: session.id))
        XCTAssertEqual(model.chatStore.messages.first?.parts.first?.text, "canonical")
    }

    func testExactReadKeepsRecoveryUntilCanonicalPageCanSupplyServerOrder() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local content", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/message/msg_local") {
                return (200, #"{"data":{"id":"msg_local","type":"user","text":"Canonical content","time":{"created":1}}}"#)
            }
            return (503, "{}")
        }
        await model.chatFacade.checkRecoveryStatus(messageID: input.id, sessionID: session.id)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.text, "Local content")
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Self.page("msg_local"))
        }
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertNil(model.chatStore.submissionRecoveries[input.id])
        XCTAssertEqual(model.chatStore.messages.first?.parts.first?.text, "canonical")
    }

    func testLatePendingReadCannotAffectReplacementConnectionOrForeignCollidingInput() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "A", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/inbox") {
                model.disconnect()
                model.config = .init(baseURL: "https://foreign.invalid", apiPreference: .v2)
                model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
                _ = try model.requireBackendConnection()
                let foreign = OpenCodeMessageEnvelope.local(role: "user", text: "B", messageID: input.id, sessionID: session.id)
                XCTAssertTrue(model.chatStore.beginV2Prompt(foreign, sessionID: session.id))
                return (200, #"{"data":[{"id":"msg_local"}]}"#)
            }
            return (404, "{}")
        }
        let result = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id, checkPendingStatus: true)
        XCTAssertFalse(result)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.text, "B")
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .submitting)
    }

    func testConnectionTransitionsIsolateCollidingRecoveryAndRestoreSameOwnerInMemory() throws {
        let model = makeModel()
        let configA = model.config
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Server A", messageID: "msg_same", sessionID: "ses_same")
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: "ses_same"))
        model.disconnect()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        model.config = .init(baseURL: "https://foreign.invalid", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        let foreign = OpenCodeMessageEnvelope.local(role: "user", text: "Server B", messageID: "msg_same", sessionID: "ses_same")
        XCTAssertTrue(model.chatStore.beginV2Prompt(foreign, sessionID: "ses_same"))
        model.chatStore.confirmSubmissionAdmission(messageID: foreign.id, sessionID: "ses_same")
        model.disconnect()
        model.config = configA
        model.connectionStore.applySuccessfulServerConnection(version: "legacy", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        model.disconnect()
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.message, input)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .uncertain)
        XCTAssertTrue(model.chatStore.cachedMessagesBySessionID.isEmpty)
        XCTAssertTrue(ChatStore().submissionRecoveries.isEmpty, "Recovery is not persisted across app process restarts")
    }

    func testAdmissionEvidenceClearsOnlyOwnedWarningNotAnUnrelatedIdenticalError() async throws {
        for evidence in ["pending", "event", "page"] {
            let model = makeModel()
            let session = Self.session(id: "ses_v2", directory: "/repo")
            _ = model.beginSessionNavigation(session)
            let connection = try model.requireBackendConnection()
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
            model.composerStore.draftMessage = "Newer draft"
            let warning = "Same error text"
            model.connectionStore.applyPromptError(warning, connectionID: connection.id, sessionID: session.id, messageID: input.id)
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                if request.url!.path.hasSuffix("/message/msg_local") { return (404, "{}") }
                if request.url!.path.hasSuffix("/inbox") { return (200, #"{"data":[{"id":"msg_local"}]}"#) }
                return (200, Self.page("msg_local"))
            }
            if evidence == "pending" {
                _ = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id)
            } else if evidence == "event" {
                model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_local","input":{"type":"user","delivery":"queue","data":{"text":"Local"}}}}"#)))
            } else {
                await model.reconcileV2TimelineFromEvent(sessionID: session.id)
            }
            XCTAssertNil(model.errorMessage, evidence)
            model.connectionStore.applyPromptError(warning, connectionID: connection.id, sessionID: session.id, messageID: input.id)
            model.errorMessage = warning // Different error, even though the visible text happens to match.
            _ = model.confirmCanonicalPromptAdmission(input.info, connectionID: connection.id)
            XCTAssertEqual(model.errorMessage, warning)
            XCTAssertEqual(model.composerStore.draftMessage, "Newer draft")
            model.stopEventStream()
        }
    }

    func testSessionListReselectionPreservesReadyTranscriptHistoryAndRequestsDetail() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        let facade = model.sessionListFacade
        let first = facade.beginSelection(session)
        let prepared = await facade.prepareSelectionForNavigation(first)
        XCTAssertTrue(prepared)
        await facade.completeSelection(first)
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            reads += 1
            return (200, Self.page("msg_ready"))
        }
        let accepted = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(accepted)
        let loaded = model.messages
        model.chatStore.beginV2TranscriptHydration(sessionID: session.id, preservingCanonicalRead: true)
        XCTAssertTrue(model.chatStore.applyInitialV2Transcript(loaded, olderCursor: "older", sessionID: session.id))
        let generation = model.sessionNavigationGeneration
        let read = try XCTUnwrap(model.chatStore.v2CanonicalReadID(sessionID: session.id))
        let request = model.chatDetailPresentationRequest
        let messages = model.messages
        model.setDraftMessage("Keep typing", forSessionID: session.id)
        let ticket = facade.beginSelection(session)
        let reselected = await facade.prepareSelectionForNavigation(ticket)
        XCTAssertTrue(reselected)
        await facade.completeSelection(ticket)
        XCTAssertEqual(model.sessionNavigationGeneration, generation)
        XCTAssertEqual(model.chatStore.v2CanonicalReadID(sessionID: session.id), read)
        XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
        XCTAssertEqual(model.messages, messages)
        XCTAssertEqual(model.chatStore.beginLoadingOlderV2Messages(sessionID: session.id), "older")
        XCTAssertEqual(model.draftMessage, "Keep typing")
        XCTAssertEqual(model.chatDetailPresentationRequest, request + 1)
        XCTAssertEqual(reads, 1, "Reselection must not issue another read or submission")
    }

    func testSessionListReselectionDuringInitialReadKeepsTicketAndAcceptsResponse() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        let facade = model.sessionListFacade
        let first = facade.beginSelection(session)
        let prepared = await facade.prepareSelectionForNavigation(first)
        XCTAssertTrue(prepared)
        await facade.completeSelection(first)
        let generation = model.sessionNavigationGeneration
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { httpRequest in
            XCTAssertEqual(httpRequest.httpMethod, "GET")
            reads += 1
            let read = try XCTUnwrap(model.chatStore.v2CanonicalReadID(sessionID: session.id))
            let request = model.chatDetailPresentationRequest
            let ticket = facade.beginSelection(session)
            let reselected = await facade.prepareSelectionForNavigation(ticket)
            XCTAssertTrue(reselected)
            await facade.completeSelection(ticket)
            XCTAssertEqual(model.sessionNavigationGeneration, generation)
            XCTAssertEqual(model.chatStore.v2CanonicalReadID(sessionID: session.id), read)
            XCTAssertTrue(model.chatStore.isHydratingV2Transcript(sessionID: session.id))
            XCTAssertEqual(model.chatDetailPresentationRequest, request + 1)
            return (200, Self.page("msg_arrived"))
        }
        let accepted = await model.hydrateV2Transcript(for: session, navigationGeneration: generation,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.messages.map(\.id), ["msg_arrived"])
        XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
        XCTAssertEqual(reads, 1, "The original suspended read must finish without a replacement")
    }

    func testSessionListSameIDInDifferentScopeStillBeginsNavigation() async {
        for changesDirectory in [true, false] {
            let model = makeModel()
            defer { model.stopEventStream() }
            let first = Self.session(id: "ses_v2", directory: "/repo")
            let facade = model.sessionListFacade
            _ = facade.beginSelection(first)
            XCTAssertTrue(model.chatStore.applyInitialV2Transcript([], olderCursor: nil, sessionID: first.id))
            let generation = model.sessionNavigationGeneration
            let request = model.chatDetailPresentationRequest
            let second = OpenCodeSession(id: first.id, title: nil,
                workspaceID: changesDirectory ? nil : "other-workspace",
                directory: changesDirectory ? "/other" : first.directory, projectID: nil, parentID: nil)
            let ticket = facade.beginSelection(second)
            let prepared = await facade.prepareSelectionForNavigation(ticket)
            XCTAssertTrue(prepared)
            await facade.completeSelection(ticket)
            XCTAssertEqual(model.sessionNavigationGeneration, generation + 1)
            XCTAssertTrue(model.chatStore.isHydratingV2Transcript(sessionID: second.id))
            XCTAssertNil(model.chatStore.preparedSessionID)
            XCTAssertEqual(model.selectedSession?.workspaceID, second.workspaceID)
            XCTAssertEqual(model.directoryStoreRegistry.activeKey, DirectoryStoreRegistry.key(for: second.directory))
            XCTAssertEqual(model.chatDetailPresentationRequest, request)
        }
    }

    private func makeModel(version: String = "test") -> AppViewModel {
        let model = AppViewModel()
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.config = .init(baseURL: "https://v2-session-workflows.invalid", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: version, healthy: true)
        _ = try? model.requireBackendConnection()
        #if DEBUG
        model.commerceFacade.debugEntitlementOverride = .unlocked
        #endif
        model.composerStore.draftsByChatKey = [:]
        model.directoryStoreRegistry.activate("/repo")
        return model
    }

    func testTurnChangesUsesPromptBoundaryAndPreservesFullPatch() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        let scope = model.chatFacade.headerScope(for: session)
        let store = SessionToolsStore()
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/diff")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query, [.init(name: "from", value: "msg_prompt")])
            return (200, #"{"data":[{"file":"src/main.swift","patch":"@@ -1 +1 @@\n-old\n+new","additions":1,"deletions":1,"status":"modified"}]}"#)
        }
        await model.chatFacade.loadTurnChanges(scope: scope, promptID: "msg_prompt", store: store)
        XCTAssertEqual(store.diffs.first?.file, "src/main.swift")
        XCTAssertTrue(store.diffs.first?.patch.contains("+new") == true)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testSessionMoveQueuesDestinationWithoutOptimisticRelocation() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        let scope = model.chatFacade.headerScope(for: session)
        let store = SessionToolsStore()
        let read = store.beginRead()
        store.finishRead(read, search: .init(directories: ["/destination"], selectedDirectory: "/destination"))
        var posts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path == "/api/session/ses_v2/move" {
                posts += 1
                let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: String]
                XCTAssertEqual(body, ["directory": "/destination", "delivery": "queue"])
                return (204, "")
            }
            return (503, #"{"message":"Reconciliation pending"}"#)
        }
        let moved = await model.chatFacade.moveSession(scope: scope, directory: "/destination", store: store)
        XCTAssertTrue(moved)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.selectedSession?.directory, "/repo")
        XCTAssertFalse(store.isMoving)
        _ = model.beginSessionNavigation(Self.session(id: "ses_other", directory: "/repo"))
        let stale = await model.chatFacade.moveSession(scope: scope, directory: "/destination", store: store)
        XCTAssertFalse(stale)
        XCTAssertEqual(posts, 1)
    }

    func testLiveSessionMoveKeepsOpenChatAndWindowsWithDraftsAndTranscript() throws {
        for destination in ["/repo/worktree", "/repo"] {
            let model = makeModel()
            defer { model.stopEventStream() }
            let session = Self.session(id: "ses_move", directory: "/repo")
            let source = model.directoryStore
            source.insertV2Session(session)
            _ = model.beginSessionNavigation(session)
            let message = OpenCodeMessageEnvelope.local(role: "assistant", text: "Before move", messageID: "msg_before", sessionID: session.id)
            XCTAssertTrue(model.chatStore.applyInitialV2Transcript([message], olderCursor: nil, sessionID: session.id))
            source.applyV2Messages([message], forSessionID: session.id)
            source.applySessionStatus("busy", forSessionID: session.id)
            let window = ChatWindowContext(model: model, connection: try model.requireBackendConnection(), session: session, owner: source)
            defer { window.close() }
            let facade = ChatFacade(viewModel: model, windowContext: window)
            model.composerStore.draftMessage = "Root draft"
            window.composer.draftMessage = "Window draft"
            let moved = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                #"{"type":"session.moved","location":{"directory":"/repo"},"data":{"sessionID":"ses_move","location":{"directory":"\#(destination)","workspaceID":"wrk_destination"},"projectID":"proj_repo"}}"#))

            model.handleV2Event(moved)

            let owner = try XCTUnwrap(model.directoryStoreRegistry.ownerStore(forSessionID: session.id))
            XCTAssertEqual(model.selectedSession?.id, session.id)
            XCTAssertEqual(model.selectedSession?.directory, destination)
            XCTAssertEqual(model.selectedSession?.workspaceID, "wrk_destination")
            XCTAssertTrue(model.directoryStore === owner)
            XCTAssertTrue(window.isCurrent)
            XCTAssertTrue(window.owner === owner)
            XCTAssertEqual(facade.selectedSession?.directory, destination)
            XCTAssertEqual(facade.presentationMessages, [message])
            XCTAssertEqual(model.chatFacade.presentationMessages, [message])
            XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
            XCTAssertEqual(owner.sessionStatuses[session.id], "busy")
            XCTAssertEqual(model.composerStore.draftMessage, "Root draft")
            XCTAssertEqual(window.composer.draftMessage, "Window draft")
            if owner !== source {
                XCTAssertFalse(source.sessions.contains { $0.id == session.id })
            }
            for type in ["session.text.started", "session.text.delta"] {
                model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"\#(type)","location":{"directory":"\#(destination)","workspaceID":"wrk_destination"},"data":{"sessionID":"ses_move","assistantMessageID":"msg_after","ordinal":0,"delta":"After move"}}"#)))
            }
            for presentation in [model.chatFacade.presentationMessages, facade.presentationMessages] {
                XCTAssertEqual(presentation.first(where: { $0.id == "msg_after" })?.parts.first?.text, "After move")
            }
        }
    }

    func testReconciliationFollowsMovedSessionWithoutLosingWindowOrRootSelection() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_move", directory: "/repo")
        let source = model.directoryStore
        source.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        let window = ChatWindowContext(model: model, connection: try model.requireBackendConnection(), session: session, owner: source)
        defer { window.close() }
        model.composerStore.draftMessage = "Root draft"
        window.composer.draftMessage = "Window draft"
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_move":
                return (200, #"{"data":{"id":"ses_move","projectID":"proj_repo","location":{"directory":"/repo/worktree"},"time":{"created":1,"updated":2}}}"#)
            case "/api/session/ses_move/permission", "/api/session/ses_move/form":
                return (200, #"{"data":[]}"#)
            case "/api/session/ses_move/message":
                return (200, #"{"data":[],"cursor":{}}"#)
            default: return (503, #"{"message":"Not configured"}"#)
            }
        }
        model.directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
        model.scheduleV2TimelineReconciliation(immediate: true)
        await model.v2TimelineReconcileTask?.value

        XCTAssertEqual(model.selectedSession?.id, session.id)
        XCTAssertEqual(model.selectedSession?.directory, "/repo/worktree")
        XCTAssertTrue(window.isCurrent)
        XCTAssertEqual(window.session.directory, "/repo/worktree")
        XCTAssertTrue(window.owner === model.directoryStore)
        XCTAssertEqual(model.composerStore.draftMessage, "Root draft")
        XCTAssertEqual(window.composer.draftMessage, "Window draft")
    }

    func testBackgroundMovePreservesRootSelectionAndWindowFormDraftAcrossReturnMove() throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let root = Self.session(id: "ses_root", directory: "/repo")
        let session = Self.session(id: "ses_background", directory: "/repo")
        let source = model.directoryStore
        source.insertV2Session(root)
        source.insertV2Session(session)
        _ = model.beginSessionNavigation(root)
        let window = ChatWindowContext(model: model, connection: try model.requireBackendConnection(), session: session, owner: source)
        defer { window.close() }
        let form = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(
            #"{"id":"frm_move","sessionID":"ses_background","title":"Input","fields":[{"key":"answer","type":"string"}]}"#.utf8)).backendForm
        source.sessionFormStore.upsert(form)
        let editor = window.formEditor(for: source.sessionFormStore)
        editor.setValue(.string("Keep this answer"), fieldID: "answer", for: form.key)
        for (origin, destination) in [("/repo", "/repo/worktree"), ("/repo/worktree", "/repo")] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                #"{"type":"session.moved","location":{"directory":"\#(origin)"},"data":{"sessionID":"ses_background","location":{"directory":"\#(destination)"},"projectID":"proj_repo"}}"#))
            model.handleV2Event(event)
            XCTAssertEqual(model.selectedSession?.id, root.id)
            XCTAssertTrue(model.directoryStore === source)
            XCTAssertTrue(window.isCurrent)
            XCTAssertEqual(window.session.directory, destination)
            let currentEditor = window.formEditor(for: window.owner.sessionFormStore)
            XCTAssertTrue(currentEditor === editor)
            XCTAssertEqual(currentEditor.forms[form.key], form)
            XCTAssertEqual(currentEditor.state(for: form.key).draft["answer"], .string("Keep this answer"))
        }
    }

    func testReconnectInventoryRelocatesGlobalListedOpenSession() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_move", directory: "/repo")
        let source = model.directoryStoreRegistry.activate(nil)
        source.insertV2Session(session)
        source.selectedSession = session
        let window = ChatWindowContext(model: model, connection: try model.requireBackendConnection(), session: session, owner: source)
        defer { window.close() }
        let moved = #"{"id":"ses_move","projectID":"global","location":{"directory":"/repo/worktree"},"time":{"created":1,"updated":2}}"#
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/location": return (200, #"{"directory":"/repo","project":{"id":"global","directory":"/","canonical":"/"}}"#)
            case "/api/project": return (200, #"[{"id":"global","canonical":"/","time":{"created":1,"updated":1},"sandboxes":[]}]"#)
            case "/api/session":
                let directory = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "directory" }?.value
                return (200, #"{"data":[\#(directory == "/repo" ? "" : moved)],"cursor":{}}"#)
            case "/api/session/active": return (200, #"{"data":{}}"#)
            case "/api/permission/request": return (200, #"{"data":[]}"#)
            case "/api/form": return (200, #"{"location":{"directory":"/repo"},"data":[]}"#)
            case "/api/session/ses_move": return (200, #"{"data":\#(moved)}"#)
            case "/api/session/ses_move/permission", "/api/session/ses_move/form": return (200, #"{"data":[]}"#)
            case "/api/session/ses_move/message": return (200, #"{"data":[],"cursor":{}}"#)
            default: return (503, #"{"message":"Not configured"}"#)
            }
        }
        model.directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
        model.scheduleV2TimelineReconciliation(immediate: true)
        await model.v2TimelineReconcileTask?.value

        XCTAssertEqual(model.selectedSession?.id, session.id)
        XCTAssertEqual(model.selectedSession?.directory, "/repo/worktree")
        XCTAssertTrue(window.isCurrent)
        XCTAssertEqual(window.session.directory, "/repo/worktree")
        XCTAssertTrue(source.sessions.isEmpty)
    }

    func testStalePreMoveReadCannotUndoMoveOrStealNewSelection() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_move", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        let started = expectation(description: "Old location read suspended")
        var release: CheckedContinuation<Void, Never>?
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_move":
                reads += 1
                let directory = reads == 1 ? "/repo" : "/repo/worktree"
                if reads == 1 { await withCheckedContinuation { release = $0; started.fulfill() } }
                return (200, #"{"data":{"id":"ses_move","projectID":"global","location":{"directory":"\#(directory)"},"time":{"created":1,"updated":2}}}"#)
            case "/api/session/ses_move/permission", "/api/session/ses_move/form": return (200, #"{"data":[]}"#)
            case "/api/session/ses_move/message": return (200, #"{"data":[],"cursor":{}}"#)
            default: return (503, #"{"message":"Not configured"}"#)
            }
        }
        model.directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
        model.scheduleV2TimelineReconciliation(immediate: true)
        await fulfillment(of: [started], timeout: 3)
        model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.moved","location":{"directory":"/repo"},"data":{"sessionID":"ses_move","location":{"directory":"/repo/worktree"},"projectID":"global"}}"#)))
        _ = model.beginSessionNavigation(Self.session(id: "ses_other", directory: "/other"))
        release?.resume()
        await model.v2TimelineReconcileTask?.value

        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.directoryStoreRegistry.session(matching: session.id)?.directory, "/repo/worktree")
        XCTAssertEqual(model.selectedSession?.id, "ses_other")
        XCTAssertEqual(model.directoryStoreRegistry.activeKey, "/other")
    }

    func testMoveDiscoversDestinationAndRemovesStaleSourceWorkspaceRow() async throws {
        let model = makeModel(version: "2.0.16")
        defer { model.stopEventStream() }
        let project = OpenCodeProject(id: "proj_repo", worktree: "/repo", vcs: "git", name: "Repo", sandboxes: [], icon: nil, time: nil)
        model.projects = [project]
        model.currentProject = project
        let session = OpenCodeSession(id: "ses_move", title: "Moving", workspaceID: nil, directory: "/repo", projectID: project.id, parentID: nil)
        model.directoryStore.insertV2Session(session)
        let key = try XCTUnwrap(model.worktreeInventoryKey(for: project))
        let inventory = model.projectStore.beginWorktreeInventoryRequest(for: key)
        XCTAssertTrue(model.projectStore.applyWorktreeInventory([.init(directory: "/repo", kind: .root)], for: key, requestID: inventory))
        let pageKey = BackendWorkspacePageKey(inventory: key, directory: "/repo")
        let page = try XCTUnwrap(model.sessionListStore.beginWorkspacePage(pageKey, replacing: true))
        XCTAssertTrue(model.sessionListStore.finishWorkspacePage(pageKey, requestID: page, sessions: [session], nextCursor: nil, limit: 50, hasMore: false))
        // Test the sidebar even when the moved session was not open in the root chat.
        model.projectWorkspacesEnabledByScope["server|\(model.config.recentServerID)|\(project.worktree)"] = true
        var inventoryReads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_move":
                return (200, #"{"data":{"id":"ses_move","projectID":"proj_repo","location":{"directory":"/repo/worktree"},"time":{"created":1,"updated":2}}}"#)
            case "/api/session/ses_move/permission", "/api/session/ses_move/form": return (200, #"{"data":[]}"#)
            case "/api/session/ses_move/message": return (200, #"{"data":[],"cursor":{}}"#)
            case "/api/worktree":
                inventoryReads += 1
                return (200, #"[{"directory":"/repo"},{"directory":"/repo/worktree","strategy":"git"}]"#)
            default: return (503, #"{"message":"Not configured"}"#)
            }
        }
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.moved","location":{"directory":"/repo"},"data":{"sessionID":"ses_move","location":{"directory":"/repo/worktree"},"projectID":"proj_repo"}}"#))
        model.handleV2Event(event)
        await model.v2TimelineReconcileTask?.value

        XCTAssertEqual(inventoryReads, 1)
        XCTAssertEqual(model.workspaceDirectories(), ["/repo", "/repo/worktree"])
        let sections = model.sessionListFacade.makeSnapshot().workspaceSections
        XCTAssertEqual(sections.first(where: { $0.directory == "/repo/worktree" })?.rows.map(\.id), [session.id])
        XCTAssertEqual(sections.first(where: { $0.directory == "/repo" })?.rows.map(\.id), [])
    }

    func testSessionToolsIgnoresSupersededSearchResultsAndSurfacesDiffErrors() async {
        let store = SessionToolsStore()
        let first = store.beginRead()
        let second = store.beginRead()
        store.finishRead(second, search: .init(directories: ["/new"], selectedDirectory: "/new"))
        store.finishRead(first, search: .init(directories: ["/old"], selectedDirectory: "/old"))
        XCTAssertEqual(store.selectedDirectory, "/new")
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        V2SessionWorkflowURLProtocol.handler = { _ in (400, #"{"message":"Range crosses a location change"}"#) }
        await model.chatFacade.loadTurnChanges(scope: model.chatFacade.headerScope(for: session), promptID: "msg_prompt", store: store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.diffs.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func testV2ComposerDiscoversCommandsAndSkillsInWorkspaceWithoutEnablingAutomation() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        V2SessionWorkflowURLProtocol.handler = { request in
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains { $0.name == "location[directory]" && $0.value == "/repo" })
            switch request.url?.path {
            case "/api/command":
                return (200, #"{"data":[{"name":"review","description":"Review changes"}]}"#)
            case "/api/skill":
                return (200, #"{"data":[{"id":"review","name":"Review skill","description":"Skill review"},{"id":"install-iphone","name":"Install iPhone"}]}"#)
            default:
                XCTFail("Unexpected request")
                throw URLError(.unsupportedURL)
            }
        }
        let client = try XCTUnwrap(model.backendConnection?.openCodeCompatibility?.client)
        let commands = try await client.listV2Commands(directory: "/repo")
        let skills = try await client.listV2Skills(directory: "/repo")
        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertEqual(skills.map(\.id), ["review", "install-iphone"])
        XCTAssertEqual(skills.first?.name, "Review skill")
        model.directoryCommands = commands
        XCTAssertFalse(model.chatFacade.commands(forSessionID: session.id, canFork: false).contains { $0.name == "install-iphone" })
        XCTAssertNil(model.chatFacade.slashCommandInput(from: "/install-iphone"))
        XCTAssertNil(model.backendConnection?.commands)
    }

    func testV2ComposerCallbackUses204ContractAndRebasesAgentMentions() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let command = OpenCodeCommand(name: "review", description: nil, agent: nil, model: nil,
            source: nil, template: "", subtask: nil, hints: [])
        var posts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path == "/api/session/ses_v2/command" {
                posts += 1
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                XCTAssertEqual(body["name"] as? String, "review")
                XCTAssertEqual(body["text"] as? String, "@general @review check")
                XCTAssertNil(body["id"])
                let agents = try XCTUnwrap(body["agents"] as? [[String: Any]])
                let mention = try XCTUnwrap(agents.first?["mention"] as? [String: Any])
                XCTAssertEqual(mention["start"] as? Int, 0)
                XCTAssertEqual(mention["end"] as? Int, 8)
                let skills = try XCTUnwrap(body["skills"] as? [[String: Any]])
                XCTAssertEqual(skills.first?["id"] as? String, "review")
                let skillMention = try XCTUnwrap(skills.first?["mention"] as? [String: Any])
                XCTAssertEqual(skillMention["start"] as? Int, 9)
                XCTAssertEqual(skillMention["end"] as? Int, 16)
                return (204, "")
            }
            return (503, #"{"message":"Reconciliation pending"}"#)
        }
        let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            arguments: "@general @review check", agentMentions: [
                .init(name: "general", content: "@general", start: 8, end: 16),
                .init(name: "review", content: "@review", start: 17, end: 24, kind: .skill)
            ])
        XCTAssertTrue(accepted)
        XCTAssertEqual(posts, 1)
        XCTAssertFalse(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        XCTAssertNil(model.errorMessage)
    }

    func testV2ComposerSkillUsesDurablePromptWithSkillAttachment() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        var posted = false
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_v2/prompt":
                posted = true
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                let skills = try XCTUnwrap(body["skills"] as? [[String: Any]])
                XCTAssertEqual(skills.first?["id"] as? String, "install-iphone")
                let mention = try XCTUnwrap(skills.first?["mention"] as? [String: Any])
                XCTAssertEqual(mention["start"] as? Int, 0)
                XCTAssertEqual(mention["end"] as? Int, 15)
                XCTAssertEqual(mention["text"] as? String, "@install-iphone")
                XCTAssertNil(body["agents"])
                XCTAssertEqual(body["text"] as? String, "@install-iphone debug")
                return (200, #"{"data":{"id":"msg_skill","sessionID":"ses_v2","time":{"created":1},"type":"user","payload":{},"delivery":"queue"}}"#)
            case "/api/experimental/session/ses_v2/wait": return (204, "")
            case "/api/session/ses_v2/message": return (200, Self.page("msg_skill"))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }
        let accepted = await model.chatFacade.sendV2TextPrompt("@install-iphone debug", in: session,
            agentMentions: [
                .init(name: "install-iphone", content: "@install-iphone", start: 0, end: 15, kind: .skill)
            ], messageID: "msg_skill")
        XCTAssertTrue(accepted)
        XCTAssertTrue(posted)
    }

    func testV2PromptKeepsSkillsAgentsAndFilesSeparateAndDeduplicatesSkills() async throws {
        let model = makeModel()
        defer { model.disconnect() }
        let client = try XCTUnwrap(model.backendConnection?.openCodeCompatibility?.client)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/prompt")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
            let agents = try XCTUnwrap(body["agents"] as? [[String: Any]])
            let skills = try XCTUnwrap(body["skills"] as? [[String: Any]])
            XCTAssertEqual(agents.map { $0["name"] as? String }, ["review"])
            XCTAssertEqual(skills.map { $0["id"] as? String }, ["review", "release"])
            XCTAssertEqual((body["files"] as? [[String: String]])?.first?["name"], "notes.txt")
            return (200, #"{"data":{"id":"msg_multi","sessionID":"ses_v2","time":{"created":1},"type":"user","payload":{},"delivery":"queue"}}"#)
        }
        _ = try await client.admitV2TextPrompt(sessionID: "ses_v2", messageID: "msg_multi",
            text: "@review @review @release @review", attachments: [
                .init(id: "file", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
            ], agentMentions: [
                .init(name: "review", content: "@review", start: 0, end: 7),
                .init(name: "review", content: "@review", start: 8, end: 15, kind: .skill),
                .init(name: "release", content: "@release", start: 16, end: 24, kind: .skill),
                .init(name: "review", content: "@review", start: 25, end: 32, kind: .skill)
            ], skillIDs: ["review"])
    }

    func testSelectingV2ChatPresentsTranscriptWhileStatusesAreStillPending() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        let statusStarted = expectation(description: "status request started")
        let presented = expectation(description: "transcript presented before status response")
        var releaseStatus: CheckedContinuation<Void, Never>?
        var statusFinished = false
        let observation = model.chatStore.$preparedSessionID.dropFirst().sink { id in
            if id == session.id {
                XCTAssertFalse(statusFinished)
                presented.fulfill()
            }
        }
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/active":
                await withCheckedContinuation { releaseStatus = $0; statusStarted.fulfill() }
                statusFinished = true
                return (200, #"{"data":{}}"#)
            case "/api/session/ses_v2/message":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "20")
                return (200, Self.page("msg_first"))
            default:
                return (200, #"{"data":[]}"#)
            }
        }
        let selection = Task { await model.selectSession(session) }
        await fulfillment(of: [statusStarted, presented], timeout: 3)
        releaseStatus?.resume()
        await selection.value
        XCTAssertEqual(model.messages.map(\.id), ["msg_first"])
        withExtendedLifetime(observation) {}
    }

    func testRecentV2SelectionPreservesWorkspaceStateOnlyWithinSameWorkspace() {
        for change in ["none", "directory", "workspace"] {
            let model = makeModel()
            defer { model.stopEventStream() }
            model.selectedDirectory = "/repo"
            model.directoryStore.syncState.todosBySessionID["first"] = [
                .init(content: "First chat only", status: "pending", priority: "high")
            ]
            _ = model.beginSessionNavigation(Self.session(id: "first", directory: "/repo"))
            XCTAssertEqual(model.sessionInteractionStore.todos.count, 1)
            model.mcpStore.isReady = true
            let generation = model.sessionNavigationGeneration
            let next = OpenCodeSession(id: "next", title: nil, workspaceID: change == "workspace" ? "other-workspace" : nil,
                directory: change == "directory" ? "/other" : "/repo", projectID: nil, parentID: nil)
            model.prepareRecentProjectSessionSelection(.init(session: next, projectTitle: "Project", preview: nil, isBusy: false))
            XCTAssertEqual(model.selectedSession?.id, next.id)
            XCTAssertEqual(model.mcpStore.isReady, change == "none")
            XCTAssertTrue(model.sessionInteractionStore.todos.isEmpty)
            XCTAssertEqual(model.sessionNavigationGeneration, generation + (change == "none" ? 1 : 2))
        }
    }

    private static func page(_ id: String, cursor: String? = nil) -> String {
        let cursorJSON = cursor.map { #""next":"\#($0)""# } ?? ""
        return #"{"data":[{"id":"\#(id)","type":"user","text":"canonical","time":{"created":1}}],"cursor":{\#(cursorJSON)}}"#
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class V2SessionWorkflowURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?

    // Immutable bridge to Foundation callbacks; delivery is confined to the loading task.
    private struct Delivery: @unchecked Sendable {
        let loader: V2SessionWorkflowURLProtocol
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "v2-session-workflows.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(V2SessionWorkflowURLProtocol.handler)
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
