import XCTest
@testable import OpenClient

@MainActor
final class ChatWindowRestorationTests: XCTestCase {
    func testLegacyRouteWithoutProfileValidatesCanonicalSession() async {
        let (model, sessions) = makeModel()
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        let route = route()
        await gate.validate(route)
        XCTAssertTrue(gate.isApproved(route))
        XCTAssertEqual(sessions.scopes, [.init(directory: "/repo")])
    }

    func testPersistedLegacyRouteDecodesAndUnknownProfileFailsClosed() throws {
        let data = Data(#"{"serverID":"server","directoryKey":"global","sessionID":"session"}"#.utf8)
        let old = try JSONDecoder().decode(OpenClientChatWindowRoute.self, from: data)
        XCTAssertNil(old.apiProfile)
        XCTAssertNil(old.canonicalDirectoryKey)
        XCTAssertNil(old.workspaceID)
        XCTAssertThrowsError(try JSONDecoder().decode(OpenClientChatWindowRoute.self,
            from: Data(#"{"serverID":"server","directoryKey":"global","sessionID":"session","apiProfile":"future"}"#.utf8)))
    }

    func testExplicitV2RouteValidatesOwnedProfileAndCanonicalLocationNotListScope() async {
        let (model, sessions) = makeModel()
        model.backendConnection = connection(sessions: sessions, profile: .v2)
        model.connectionStore.backendMode = .serverV2
        sessions.result = session(directory: "/workspace", workspaceID: "ws")
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        var route = route()
        route = .init(serverID: route.serverID, directoryKey: "global", sessionID: route.sessionID,
            apiProfile: .v2, canonicalDirectoryKey: "/workspace", workspaceID: "ws")
        await gate.validate(route)
        XCTAssertTrue(gate.isApproved(route))
        XCTAssertEqual(sessions.scopes, [.init(directory: "/workspace", workspaceID: "ws")])
        route = .init(serverID: route.serverID, directoryKey: route.directoryKey, sessionID: route.sessionID,
            apiProfile: .v2, canonicalDirectoryKey: route.canonicalDirectoryKey, workspaceID: "wrong")
        await gate.validate(route)
        XCTAssertFalse(gate.isApproved(route))
    }

    func testSameSessionIDOnAnotherServerMakesNoRequestsDespiteMutableConfig() async {
        let (model, sessions) = makeModel(server: "https://other.invalid")
        model.config = .init(baseURL: "https://restoration.invalid")
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        await gate.validate(route())
        XCTAssertFalse(gate.isApproved(route()))
        XCTAssertTrue(sessions.scopes.isEmpty)
    }

    func testCanonicalDirectoryWorkspaceAndSessionMismatchReject() async {
        for session in [
            session(directory: "/other"), session(workspaceID: "workspace"), session(id: "other"),
        ] {
            let (model, sessions) = makeModel()
            sessions.result = session
            let gate = ChatWindowRestorationCoordinator(viewModel: model)
            await gate.validate(route())
            XCTAssertFalse(gate.isApproved(route()))
        }
    }

    func testPriorConnectionValidationCannotApproveReplacementLifetime() async {
        let (model, sessions) = makeModel()
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        let old = model.backendConnection
        sessions.onRead = {
            model.backendConnection = self.connection(sessions: sessions)
        }
        await gate.validate(route())
        XCTAssertNotEqual(old?.id, model.backendConnection?.id)
        XCTAssertFalse(gate.isApproved(route()))
        sessions.onRead = nil
        await gate.validate(route())
        XCTAssertTrue(gate.isApproved(route()))
        model.backendConnection = nil
        XCTAssertFalse(gate.isApproved(route()))
    }

    func testConflictingCachedOwnerCannotOverrideCanonicalDirectory() async {
        let (model, _) = makeModel()
        model.directoryStoreRegistry.activate("/other")
        model.directoryStore.insertV2Session(session(directory: "/other"))
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        await gate.validate(route())
        XCTAssertFalse(gate.isApproved(route()))
    }

    func testDisconnectDuringValidationAndAfterApprovalInvalidates() async {
        let (model, sessions) = makeModel()
        let gate = ChatWindowRestorationCoordinator(viewModel: model)
        sessions.onRead = { model.connectionStore.isConnected = false }
        await gate.validate(route())
        XCTAssertFalse(gate.isApproved(route()))
        sessions.onRead = nil
        model.connectionStore.isConnected = true
        await gate.validate(route())
        XCTAssertTrue(gate.isApproved(route()))
        model.backendConnection?.close()
        XCTAssertFalse(gate.isApproved(route()))
    }

    func testUnsupportedInjectedDisconnectedAndMissingRoutesMakeNoRequests() async {
        for kind in ["v2", "injected", "unsupported", "disconnected", "closed", "missing", "unknown"] {
            let sessions = RestorationSessions()
            let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: .init()), eventManager: OpenCodeEventManager())
            let model = AppViewModel(backendFactory: kind == "injected" ? factory : nil)
            model.connectionStore.backendMode = .server
            model.connectionStore.isConnected = kind != "disconnected"
            model.backendConnection = connection(sessions: sessions, profile: kind == "v2" ? .v2 : .legacy)
            if kind == "unsupported", let previous = model.backendConnection {
                model.backendConnection = BackendConnection(descriptor: previous.descriptor,
                    projects: RestorationProjects(), sessions: sessions, chat: previous.chat,
                    models: previous.models, events: RestorationEvents())
            }
            if kind == "closed" { model.backendConnection?.close() }
            if kind == "unknown" { model.backendConnection = nil }
            let gate = ChatWindowRestorationCoordinator(viewModel: model)
            await gate.validate(kind == "missing" ? nil : route())
            XCTAssertFalse(gate.isApproved(route()), kind)
            XCTAssertTrue(sessions.scopes.isEmpty, kind)
        }
    }

    private func makeModel(server: String = "https://restoration.invalid") -> (AppViewModel, RestorationSessions) {
        let model = AppViewModel()
        let sessions = RestorationSessions()
        model.connectionStore.backendMode = .server
        model.connectionStore.isConnected = true
        model.backendConnection = connection(sessions: sessions, server: server)
        return (model, sessions)
    }

    private func connection(sessions: RestorationSessions, server: String = "https://restoration.invalid",
                            profile: OpenCodeAPIProfile = .legacy) -> BackendConnection {
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: .init(baseURL: server)), profile: profile)
        return BackendConnection(descriptor: .init(id: "restoration", name: "Test", version: "test"),
            projects: adapter, sessions: sessions, chat: adapter, models: adapter, events: RestorationEvents())
    }

    private func route() -> OpenClientChatWindowRoute {
        .init(serverID: OpenCodeServerConfig(baseURL: "https://restoration.invalid").recentServerID,
              directoryKey: "/repo", sessionID: "same-session")
    }

    private func session(id: String = "same-session", directory: String = "/repo", workspaceID: String? = nil) -> OpenCodeSession {
        .init(id: id, title: nil, workspaceID: workspaceID, directory: directory, projectID: nil, parentID: nil)
    }
}

@MainActor
private final class RestorationSessions: BackendSessionsService {
    var scopes: [BackendScope] = []
    var onRead: (() -> Void)?
    var result = OpenCodeSession(id: "same-session", title: nil, workspaceID: nil, directory: "/repo", projectID: nil, parentID: nil)
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        scopes.append(scope)
        await Task.yield()
        onRead?()
        return result
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage { XCTFail(); throw BackendError.invalidScope }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession { XCTFail(); throw BackendError.invalidScope }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { XCTFail(); throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws { XCTFail() }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { XCTFail(); throw BackendError.invalidScope }
}

@MainActor
private final class RestorationEvents: BackendEventSource {
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { XCTFail("Restoration must not start SSE") }
    func stop() {}
}

@MainActor
private struct RestorationProjects: BackendProjectsService {
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        XCTFail("Unsupported restoration must not fetch projects")
        throw BackendError.invalidScope
    }
}
