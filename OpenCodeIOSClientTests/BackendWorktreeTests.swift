import XCTest
@testable import OpenClient

@MainActor
final class BackendWorktreeTests: XCTestCase {
    override func tearDown() async throws {
        WorktreeURLProtocol.handler = nil
    }

    func testNext17155InventoryPreservesRootAndUnknownStrategy() async throws {
        let client = makeClient()
        WorktreeURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/project/project/directories")
            XCTAssertEqual(Self.query(request), ["location[directory]": "/repo"])
            return Self.response(request, body: #"[{"directory":"/repo"},{"directory":"/copies/a","strategy":"git_worktree"},{"directory":"/other","strategy":"plugin-copy"}]"#)
        }
        let result = try await client.listV2Worktrees(scope: .init(projectID: "project", directory: "/repo"))
        XCTAssertEqual(result, [.init(directory: "/repo", kind: .root), .init(directory: "/copies/a", kind: .gitCopy),
                                .init(directory: "/other", kind: .unknownStrategy("plugin-copy"))])
        XCTAssertFalse(result[2].isManaged)
    }

    func testNext17155CreateUsesParentAndActualReturnedDirectoryWithoutReadiness() async throws {
        let service = OpenCodeWorktreeServices(client: makeClient(), profile: .v2)
        var requests = 0
        WorktreeURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/experimental/project/project/copy")
            XCTAssertEqual(Self.query(request), ["location[directory]": "/repo"])
            let body = try Self.body(request)
            XCTAssertEqual(Set(body.keys), ["strategy", "directory", "name"])
            XCTAssertEqual(body["strategy"] as? String, "git_worktree")
            XCTAssertEqual(body["directory"] as? String, "/copies")
            XCTAssertEqual(body["name"] as? String, "topic")
            return Self.response(request, body: #"{"directory":"/copies/topic-2"}"#)
        }
        let result = try await service.create(.init(scope: .init(projectID: "project", directory: "/repo"),
                                                    name: "topic", destinationParent: "/copies"))
        XCTAssertTrue(service.requiresDestinationParent)
        XCTAssertEqual(result.directory, "/copies/topic-2")
        XCTAssertEqual(result.readiness, .ready)
        XCTAssertEqual(requests, 1)
    }

    func testNext17155RejectsMissingParentTraversalAndRemoteWorkspaceBeforeSending() async throws {
        let client = makeClient()
        WorktreeURLProtocol.handler = { request in
            XCTFail("Invalid worktree intent must not reach transport")
            return Self.response(request, status: 500)
        }
        let scope = BackendScope(projectID: "project", directory: "/repo")
        for request in [BackendWorktreeCreation(scope: scope),
                        .init(scope: scope, name: "../escape", destinationParent: "/copies"),
                        .init(scope: .init(projectID: "project", directory: "/repo", workspaceID: "wrk_remote"), destinationParent: "/copies")] {
            do {
                _ = try await client.createV2Worktree(request)
                XCTFail("Expected invalid creation")
            } catch { XCTAssertTrue(error is BackendWorktreeError) }
        }
    }

    func testRemovalRequiresExplicitForceAndRefreshIsInventoryOnly() async throws {
        let client = makeClient()
        let scope = BackendScope(projectID: "project", directory: "/repo")
        var requests: [(String, String)] = []
        WorktreeURLProtocol.handler = { request in
            requests.append((request.httpMethod ?? "", request.url?.path ?? ""))
            XCTAssertEqual(Self.query(request), ["location[directory]": "/repo"])
            if request.httpMethod == "DELETE" {
                let body = try Self.body(request)
                XCTAssertEqual(Set(body.keys), ["directory", "force"])
                XCTAssertEqual(body["directory"] as? String, "/copies/topic")
                XCTAssertEqual(body["force"] as? Bool, false)
                return Self.response(request, status: 400,
                    body: #"{"name":"ProjectCopyError","data":{"message":"Dirty checkout","forceRequired":true}}"#)
            }
            XCTAssertEqual(request.url?.path, "/experimental/project/project/copy/refresh")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            return Self.response(request, status: 204)
        }
        do {
            try await client.removeV2Worktree(scope: scope, directory: "/copies/topic", force: false)
            XCTFail("Expected explicit force requirement")
        } catch {
            XCTAssertEqual(error as? BackendWorktreeError, .forceRequired("Dirty checkout"))
        }
        XCTAssertEqual(requests.count, 1)
        try await client.refreshV2Worktrees(scope: scope)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.0, "POST")
    }

    func testLegacyCreationUsesLegacyDefaultsAndPreservesPreparingBranch() async throws {
        let service = OpenCodeWorktreeServices(client: makeClient(), profile: .legacy)
        WorktreeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/experimental/worktree")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(Self.query(request), ["directory": "/repo"])
            let body = try Self.body(request)
            XCTAssertEqual(body["name"] as? String, "topic")
            XCTAssertNil(body["directory"])
            XCTAssertNil(body["strategy"])
            return Self.response(request, body: #"{"name":"topic","branch":"opencode/topic","directory":"/legacy/topic"}"#)
        }
        let result = try await service.create(.init(scope: .init(projectID: "project", directory: "/repo"), name: "topic"))
        XCTAssertFalse(service.requiresDestinationParent)
        XCTAssertEqual(result.readiness, .preparing(name: "topic", branch: "opencode/topic"))
    }

    func testExplicitForceRemovalDecodesNoContentWithoutAdditionalRequests() async throws {
        let client = makeClient()
        var count = 0
        WorktreeURLProtocol.handler = { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/experimental/project/project/copy")
            XCTAssertEqual(try Self.body(request)["force"] as? Bool, true)
            return Self.response(request, status: 204)
        }
        try await client.removeV2Worktree(scope: .init(projectID: "project", directory: "/repo"), directory: "/copies/topic", force: true)
        XCTAssertEqual(count, 1)
    }

    func testNonGitDiscoveryPreservesGlobalIdentityAndConcreteDirectoryWithoutWrites() async throws {
        let service = OpenCodeWorktreeServices(client: makeClient(), profile: .v2)
        var paths: [String] = []
        WorktreeURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let path = request.url!.path
            paths.append(path)
            switch path {
            case "/api/location":
                return Self.response(request, body: #"{"directory":"/notes","project":{"id":"global","directory":"/","canonical":"/"}}"#)
            case "/api/project/current":
                return Self.response(request, body: #"{"id":"global","directory":"/","canonical":"/"}"#)
            case "/api/project":
                return Self.response(request, body: #"[{"id":"global","canonical":"/","sandboxes":[]}]"#)
            default:
                XCTFail("Discovery must not warm sessions or write project metadata")
                return Self.response(request, status: 404)
            }
        }
        let resolution = try await service.resolveProject(directory: "/notes")
        XCTAssertEqual(resolution.project.id, "global")
        XCTAssertEqual(resolution.scope, .init(projectID: "global", directory: "/notes"))
        XCTAssertEqual(resolution.canonicalDirectory, "/")
        XCTAssertEqual(paths, ["/api/location", "/api/project/current", "/api/project"])
    }

    func testSharedProjectCanonicalDoesNotBecomeWorktreeSource() async throws {
        let service = OpenCodeWorktreeServices(client: makeClient(), profile: .v2)
        WorktreeURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/location":
                XCTAssertEqual(Self.query(request)["location[directory]"], "/clones/fixture/subdir")
                return Self.response(request, body: #"{"directory":"/clones/fixture/subdir","project":{"id":"project","directory":"/clones/fixture","canonical":"/original"}}"#)
            case "/api/project/current":
                XCTAssertEqual(Self.query(request)["location[directory]"], "/clones/fixture/subdir")
                return Self.response(request, body: #"{"id":"project","directory":"/clones/fixture","canonical":"/original"}"#)
            case "/api/project":
                return Self.response(request, body: #"[{"id":"project","canonical":"/original","vcs":"git","sandboxes":[]}]"#)
            case "/experimental/project/project/copy":
                XCTAssertEqual(Self.query(request), ["location[directory]": "/clones/fixture/subdir"])
                let body = try Self.body(request)
                if request.httpMethod == "POST" {
                    XCTAssertEqual(body["directory"] as? String, "/clones/copies")
                    return Self.response(request, body: #"{"directory":"/clones/copies/topic"}"#)
                }
                XCTAssertEqual(request.httpMethod, "DELETE")
                XCTAssertEqual(body["directory"] as? String, "/clones/copies/topic")
                return Self.response(request, status: 204)
            default:
                XCTFail("Unexpected source lookup")
                return Self.response(request, status: 404)
            }
        }
        let resolution = try await service.resolveProject(directory: "/clones/fixture/subdir")
        XCTAssertEqual(resolution.project.worktree, "/clones/fixture")
        XCTAssertEqual(resolution.scope.directory, "/clones/fixture/subdir")
        XCTAssertEqual(resolution.canonicalDirectory, "/original")
        let created = try await service.create(.init(scope: resolution.scope, name: "topic", destinationParent: "/clones/copies"))
        try await service.remove(scope: resolution.scope, directory: created.directory, force: false)
    }

    func testCatalogRefreshAndStaleProjectValuePreserveSelectedCloneSource() async throws {
        let harness = WorktreeHarness()
        let model = AppViewModel(backendFactory: harness)
        await model.connectionFacade.connect()
        defer { model.disconnect() }
        let connection = try model.requireBackendConnection()
        let selected = OpenCodeProject(id: harness.project.id, worktree: "/fixture", vcs: "git",
                                       name: nil, sandboxes: [], icon: nil, time: nil)
        model.projectStore.rememberProjectResolution(.init(project: selected,
            scope: .init(projectID: selected.id, directory: "/fixture/subdir"), canonicalDirectory: "/repo"), connectionID: connection.id)
        model.currentProject = selected
        model.selectedDirectory = "/fixture"
        try await model.refreshProjects()
        XCTAssertEqual(model.currentProject?.worktree, "/fixture")
        XCTAssertEqual(model.projects.first?.worktree, "/fixture")
        let key = BackendWorktreeInventoryKey(connectionID: connection.id, projectID: selected.id)
        XCTAssertEqual(model.projectStore.canonicalProjectDirectories[key], "/repo")
        XCTAssertEqual(model.projectStore.resolvedProjectScopes[key]?.directory, "/fixture/subdir")
        XCTAssertEqual(model.projectStore.preservingSelectedDirectory(harness.project, connectionID: UUID()).worktree, "/repo")

        harness.entries = [.init(directory: "/fixture", kind: .root)]
        model.projectWorkspacesEnabledByScope[model.currentProjectPreferenceScopeKey] = true
        _ = try await model.createManagedWorktree(name: "new", destinationParent: "/copies", project: harness.project)
        XCTAssertEqual(harness.creations.last?.scope, .init(projectID: selected.id, directory: "/fixture"))
        XCTAssertEqual(model.currentProject?.worktree, "/fixture")
    }

    func testDirectorySearchUsesDirectoryTypeAndResolvedLocation() async throws {
        let service = OpenCodeWorktreeServices(client: makeClient(), profile: .v2)
        WorktreeURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/fs/find")
            XCTAssertEqual(Self.query(request)["type"], "directory")
            return Self.response(request, body: #"{"location":{"directory":"/resolved","project":{"id":"project","directory":"/resolved","canonical":"/resolved"}},"data":[{"path":"notes","type":"directory"},{"path":"notes.txt","type":"file"}]}"#)
        }
        let result = try await service.searchDirectories(query: "notes", root: "/requested")
        XCTAssertEqual(result.directories, ["/resolved/notes"])
        XCTAssertNil(result.selectedDirectory)
    }

    func testInventoryAndPageEpochsRejectLateResultsAndRemovedWorkspace() throws {
        let projects = ProjectStore()
        let key = BackendWorktreeInventoryKey(connectionID: UUID(), projectID: "project")
        let old = projects.beginWorktreeInventoryRequest(for: key)
        let newer = projects.beginWorktreeInventoryRequest(for: key)
        XCTAssertTrue(projects.applyWorktreeInventory([.init(directory: "/repo", kind: .root)], for: key, requestID: newer))
        XCTAssertFalse(projects.applyWorktreeInventory([.init(directory: "/deleted", kind: .gitCopy)], for: key, requestID: old))
        let store = SessionListStore()
        let pageKey = BackendWorkspacePageKey(inventory: key, directory: "/copies/topic")
        let first = try XCTUnwrap(store.beginWorkspacePage(pageKey, replacing: true))
        let second = try XCTUnwrap(store.beginWorkspacePage(pageKey, replacing: true))
        XCTAssertFalse(store.finishWorkspacePage(pageKey, requestID: first, sessions: [], nextCursor: "old", limit: 5, hasMore: true))
        XCTAssertTrue(store.finishWorkspacePage(pageKey, requestID: second, sessions: [], nextCursor: "next", limit: 5, hasMore: true))
        let late = try XCTUnwrap(store.beginWorkspacePage(pageKey, replacing: true))
        store.removeWorkspacePage(pageKey)
        XCTAssertFalse(store.finishWorkspacePage(pageKey, requestID: late, sessions: [], nextCursor: nil, limit: 5, hasMore: false))
        XCTAssertNil(store.workspacePages[pageKey])
    }

    func testInjectedWorktreesUseCorePagesAndRequireSeparateForceConfirmation() async throws {
        let harness = WorktreeHarness()
        let viewModel = AppViewModel(backendFactory: harness)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        viewModel.currentProject = harness.project
        viewModel.selectedDirectory = harness.project.worktree
        viewModel.projectWorkspacesEnabledByScope[viewModel.currentProjectPreferenceScopeKey] = true
        await viewModel.loadWorkspaceSessions()
        XCTAssertTrue(viewModel.projectFacade.allowsProjectCreation)
        XCTAssertTrue(viewModel.projectFacade.supportsWorkspaceManagement)
        XCTAssertNil(viewModel.backendConnection?.openCodeCompatibility)
        let key = try XCTUnwrap(viewModel.workspacePageKey(directory: "/copies/topic"))
        XCTAssertEqual(viewModel.sessionListStore.workspacePages[key]?.nextCursor, "page-2")
        await viewModel.loadMoreWorkspaceSessions(directory: "/copies/topic")
        XCTAssertEqual(viewModel.sessionListStore.workspacePages[key]?.state.sessions.map(\.id), ["one", "two"])
        XCTAssertEqual(harness.cursors.compactMap { $0 }, ["page-2"])
        XCTAssertTrue(harness.scopes.allSatisfy { $0.workspaceID == nil })

        let created = await viewModel.createWorkspace(name: "new", destinationParent: "/copies")
        XCTAssertTrue(created)
        XCTAssertNil(viewModel.sessionListStore.workspaceOperation(for: "/copies/new"))
        XCTAssertEqual(harness.creations.last?.destinationParent, "/copies")
        XCTAssertNil(viewModel.backendConnection?.worktreeReset)

        let facade = viewModel.sessionListFacade
        await facade.deleteWorktree(directory: "/copies/topic")
        XCTAssertEqual(harness.removalForces, [false])
        XCTAssertNotNil(facade.pendingWorktreeRemoval)
        await facade.confirmForceWorktreeRemoval()
        XCTAssertEqual(harness.removalForces, [false, true])
        XCTAssertNil(viewModel.sessionListStore.workspacePages[key])
        XCTAssertEqual(harness.deletedSessions, [])
        XCTAssertNotNil(viewModel.directoryStoreRegistry.existingStore(for: "/copies/topic")?.sessions.first { $0.id == "one" })
    }

    func testReadyBeforeCreateResponseIsNotOverwrittenByPreparing() {
        let store = ProjectStore()
        let connectionID = UUID()
        let revision = store.worktreeReadinessRevision
        store.recordWorktreeReadiness(directory: "/copies/topic", connectionID: connectionID, error: nil)
        XCTAssertNotNil(store.worktreeReadinessEvent(directory: "/copies/topic", connectionID: connectionID, after: revision))
        XCTAssertNil(store.worktreeReadinessEvent(directory: "/copies/topic", connectionID: UUID(), after: revision))
        XCTAssertNil(store.worktreeReadinessEvent(directory: "/copies/topic", connectionID: connectionID, after: store.worktreeReadinessRevision))
    }

    func testRemovedWorkspaceRejectsInFlightCorePage() async throws {
        let harness = WorktreeHarness()
        let viewModel = AppViewModel(backendFactory: harness)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        viewModel.currentProject = harness.project
        viewModel.selectedDirectory = "/repo"
        viewModel.projectWorkspacesEnabledByScope[viewModel.currentProjectPreferenceScopeKey] = true
        await viewModel.loadWorkspaceSessions()
        let key = try XCTUnwrap(viewModel.workspacePageKey(directory: "/copies/topic"))
        let started = expectation(description: "Core workspace page suspended")
        var continuation: CheckedContinuation<Void, Never>?
        harness.beforePage = {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let loading = Task { await viewModel.refreshWorkspaceSessions(directory: "/copies/topic") }
        await fulfillment(of: [started], timeout: 1)
        viewModel.projectStore.setWorktreeInventory([.init(directory: "/repo", kind: .root)], for: key.inventory)
        viewModel.sessionListStore.removeWorkspacePage(key)
        continuation?.resume()
        await loading.value
        XCTAssertNil(viewModel.sessionListStore.workspacePages[key])
        XCTAssertNil(viewModel.workspaceSessionsByDirectory["/copies/topic"])
    }

    func testExecutionScopeKeepsRemoteIdentitySeparateFromLocalCopyPath() async throws {
        let harness = WorktreeHarness()
        let viewModel = AppViewModel(backendFactory: harness)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let connection = try viewModel.requireBackendConnection()
        let scope = BackendScope(projectID: harness.project.id, directory: "/remote/source", workspaceID: "wrk_remote")
        viewModel.projectStore.rememberProjectResolution(.init(project: harness.project, scope: scope, canonicalDirectory: "/repo"),
                                                        connectionID: connection.id)
        XCTAssertEqual(viewModel.projectExecutionScope(for: harness.project), scope)
        XCTAssertNil(viewModel.worktreeInventoryKey(for: harness.project), "A remote location must not become a local copy source")
        XCTAssertEqual(viewModel.projectExecutionScope(for: harness.project, directory: "/copies/topic"),
                       .init(projectID: "project", directory: "/copies/topic"))
    }

    private func makeClient() -> OpenCodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorktreeURLProtocol.self]
        return OpenCodeAPIClient(config: .init(baseURL: "http://worktree.test", username: "opencode", password: "fixture"),
                                 session: URLSession(configuration: configuration))
    }

    nonisolated private static func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    nonisolated private static func response(_ request: URLRequest, status: Int = 200, body: String = "") -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
    }

    nonisolated private static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class WorktreeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
private final class WorktreeHarness: BackendFactory, BackendProjectsService, BackendSessionsService, BackendChatService,
    BackendModelsService, BackendEventSource, BackendProjectLifecycleService, BackendWorktreesService {
    let project = OpenCodeProject(id: "project", worktree: "/repo", vcs: "git", name: "Project", sandboxes: [], icon: nil, time: nil)
    var entries: [BackendWorktree] = [.init(directory: "/repo", kind: .root), .init(directory: "/copies/topic", kind: .gitCopy)]
    var scopes: [BackendScope] = []
    var cursors: [String?] = []
    var creations: [BackendWorktreeCreation] = []
    var removalForces: [Bool] = []
    var deletedSessions: [String] = []
    var beforePage: (@MainActor () async -> Void)?
    var requiresDestinationParent: Bool { true }

    func connect() async throws -> BackendConnection {
        BackendConnection(descriptor: .init(id: "worktree-harness", name: "Harness", version: "1"),
            projects: self, sessions: self, chat: self, models: self, events: self,
            projectLifecycle: self, worktrees: self)
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        .init(projects: [project], currentProject: project, defaultDirectory: "/repo")
    }
    func searchDirectories(query: String, root: String) async throws -> BackendDirectorySearch { .init(directories: ["/repo"], selectedDirectory: "/repo") }
    func resolveProject(directory: String) async throws -> BackendProjectResolution {
        .init(project: project, scope: .init(projectID: project.id, directory: directory), canonicalDirectory: "/repo")
    }
    func inventory(scope: BackendScope) async throws -> [BackendWorktree] { entries }
    func refresh(scope: BackendScope) async throws -> [BackendWorktree] { entries }
    func create(_ request: BackendWorktreeCreation) async throws -> BackendWorktreeCreationResult {
        creations.append(request)
        let entry = BackendWorktree(directory: "/copies/new", kind: .gitCopy)
        entries.append(entry)
        return .init(worktree: entry, readiness: .ready)
    }
    func remove(scope: BackendScope, directory: String, force: Bool) async throws {
        removalForces.append(force)
        if !force { throw BackendWorktreeError.forceRequired("Dirty checkout") }
        entries.removeAll { $0.directory == directory }
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        scopes.append(scope)
        cursors.append(cursor)
        guard scope.directory == "/copies/topic" else { return .init(sessions: []) }
        await beforePage?()
        return .init(sessions: [.init(id: cursor == nil ? "one" : "two", title: "Session", workspaceID: nil,
            directory: "/copies/topic", projectID: "project", parentID: nil)], nextCursor: cursor == nil ? "page-2" : nil)
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        .init(id: id, title: "Session", workspaceID: scope.workspaceID, directory: scope.directory, projectID: scope.projectID, parentID: nil)
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { try await session(id: "created", scope: request.scope) }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { try await session(id: id, scope: scope) }
    func deleteSession(id: String, scope: BackendScope) async throws { deletedSessions.append(id) }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage { .init(messages: []) }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission { .accepted(sessionID: request.sessionID, messageID: request.messageID) }
    func interrupt(sessionID: String, scope: BackendScope) async throws {}
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { .init() }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) {}
    func stop() {}
}
