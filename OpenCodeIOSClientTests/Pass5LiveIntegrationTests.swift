import Foundation
import XCTest
@testable import OpenClient

/// Opt-in real-service coverage. Discovery, session creation, and model selection
/// never submit a prompt, authenticate a provider, or touch the persistent servers.
@MainActor
final class Pass5LiveIntegrationTests: XCTestCase {
    func testShortcutDiscoveryAndSessionCreationAgainstIsolatedBackend() async throws {
        let (client, service, connection, directory) = try await context()
        XCTAssertEqual(service.connections().filter { $0.id == connection.id }, [connection])
        let projects = try await service.projects(connection: connection)
        let project = try XCTUnwrap(projects.first { $0.directory == directory } ?? projects.first)
        XCTAssertEqual(project.connectionID, connection.id)
        XCTAssertEqual(project.directory, directory)
        let matchedProjects = try await service.projects(matching: [project.id])
        XCTAssertEqual(matchedProjects.map(\.id), [project.id])

        let models = try await service.models(connection: connection)
        XCTAssertTrue(models.allSatisfy { $0.connectionID == connection.id })
        if let model = models.first {
            let matchedModels = try await service.models(matching: [model.id])
            XCTAssertEqual(matchedModels.map(\.id), [model.id])
        }
        let created = try await createOwnedSession(client: client, service: service, connection: connection,
                                                   project: project, directory: directory)
        let sessions = try await service.sessions(connection: connection, project: project)
        XCTAssertEqual(sessions.filter { $0.sessionID == created.sessionID }.map(\.id), [created.id])
        let matched = try await service.sessions(matching: [created.id])
        XCTAssertEqual(matched.map(\.sessionID), [created.sessionID])
        XCTAssertEqual(matched.first?.connectionID, connection.id)
        XCTAssertEqual(matched.first?.directory, directory)
        try await assertNoProviderTurn(client, sessionID: created.sessionID)
    }

    func testExistingSessionModelSelectionUsesLiveCatalogWithoutShortcutSendAgainstIsolatedBackend() async throws {
        let (client, service, connection, directory) = try await context()
        let projects = try await service.projects(connection: connection)
        let project = try XCTUnwrap(projects.first { $0.directory == directory } ?? projects.first)
        let models = try await service.models(connection: connection)
        // Prefer the disposable server's test model, but any enabled catalog reference
        // is safe here: the model-selection endpoint does not execute a provider turn.
        let testModel = try XCTUnwrap(models.first { $0.modelID == "test-model" } ?? models.first,
                                     "The isolated server must expose an enabled model for selection coverage")
        let created = try await createOwnedSession(client: client, service: service, connection: connection,
                                                   project: project, directory: directory)
        let factory = OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager())
        let backend = try await factory.connect()
        defer { backend.close() }
        let selection = try XCTUnwrap(backend.sessionSelection)
        let scope = BackendScope(projectID: project.projectID, directory: directory)
        try await selection.setModel(sessionID: created.sessionID, model: testModel.modelReference, variant: nil, scope: scope)
        let canonical = try await client.getV2Session(sessionID: created.sessionID)
        XCTAssertEqual(canonical.model?.providerID, testModel.providerID)
        XCTAssertEqual(canonical.model?.modelID, testModel.modelID)
        XCTAssertTrue(canonical.model?.variant == nil || canonical.model?.variant == "default")
        try await assertNoProviderTurn(client, sessionID: created.sessionID)
        // OpenCodeShortcutService.sendMessage has no paused-submit option. Do not
        // call it and do not describe a model-selection response as prompt admission.
    }

    private func context() async throws -> (OpenCodeAPIClient, OpenCodeShortcutService, OpenCodeShortcutConnectionEntity, String) {
        let fixture = try OpenCodeV2LiveFixture.load()
        let base = OpenCodeV2LiveFixture.baseURL
        guard let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw Pass5LiveFailure("Only http://127.0.0.1:14097 is permitted; persistent 4096/4097 are forbidden")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: Pass5LiveRedirectGuard(), delegateQueue: nil)
        addTeardownBlock { session.invalidateAndCancel() }
        // The trailing-slash identity is distinct from the usual UI saved connection.
        // Even this identity is never overwritten if already present in defaults/Keychain.
        let config = OpenCodeServerConfig(name: "Pass5 \(UUID().uuidString)", baseURL: "http://127.0.0.1:14097/",
                                          username: fixture.username, password: fixture.password, apiPreference: .v2)
        let client = OpenCodeAPIClient(config: config, session: session)
        let info = try await object(client, "/api/info")
        guard info["version"] == .string(OpenCodeV2LiveFixture.version) else { throw Pass5LiveFailure("Unexpected disposable server version") }
        let location = try await client.getV2Location()
        let directory = URL(fileURLWithPath: location.directory).resolvingSymlinksInPath().standardizedFileURL
        let projectDirectory = URL(fileURLWithPath: location.project.directory).resolvingSymlinksInPath().standardizedFileURL
        guard directory == fixture.workspace, projectDirectory == fixture.workspace, fixture.owns(directory) else {
            throw Pass5LiveFailure("Refusing a server outside the manifest-owned v2 workspace")
        }

        let saved = OpenCodeSavedServer(config: config)
        let key = "recentServerConfigs"
        let store = OpenCodeServerPasswordStore()
        let previousMetadata = UserDefaults.standard.data(forKey: key)
        let previousMirror = UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: key)
        let previousPassword = store.loadPassword(for: saved.recentServerID)
        // Register before the first write. The live shortcut test gets an isolated saved-server
        // view, then restores personal metadata and the exact pre-test credential byte-for-byte.
        addTeardownBlock { @MainActor in
            if let previousMetadata {
                UserDefaults.standard.set(previousMetadata, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            OpenClientSharePayloadStore.mirrorRecentServersData(previousMirror)
            if let previousPassword {
                store.savePassword(previousPassword, for: saved.recentServerID)
            } else {
                store.deletePassword(for: saved.recentServerID)
            }
        }
        let isolatedMetadata = try JSONEncoder().encode([saved])
        UserDefaults.standard.set(isolatedMetadata, forKey: key)
        OpenClientSharePayloadStore.mirrorRecentServersData(isolatedMetadata)
        store.savePassword(fixture.password, for: saved.recentServerID)
        guard store.loadPassword(for: saved.recentServerID) == fixture.password else {
            throw Pass5LiveFailure("The test host cannot round-trip its own Keychain identity")
        }
        let suite = "Pass5LiveIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { @MainActor in defaults.removePersistentDomain(forName: suite) }
        var service = OpenCodeShortcutService(session: session, usageGate: .init(isProUnlocked: { true }))
        service.pendingOperations = .init(defaults: defaults)
        let connection = try XCTUnwrap(service.connections().first { $0.id == saved.recentServerID })
        return (client, service, connection, location.directory)
    }

    private func createOwnedSession(client: OpenCodeAPIClient, service: OpenCodeShortcutService,
                                    connection: OpenCodeShortcutConnectionEntity, project: OpenCodeShortcutProjectEntity,
                                    directory: String) async throws -> OpenCodeShortcutSessionEntity {
        let title = "Pass5 Shortcut \(UUID().uuidString)"
        // The real shortcut service allocates the ID, so register an exact unique-title
        // lookup before POST, covering response loss without a broad session cleanup.
        addTeardownBlock { @MainActor in
            let request = try client.makeRequest(path: "/api/session", method: "GET", queryItems: [
                .init(name: "search", value: title), .init(name: "project", value: project.projectID)
            ])
            let (data, response) = try await client.session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Pass5LiveFailure("Owned session cleanup discovery failed") }
            let envelope = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: data)
            for entry in try XCTUnwrap(envelope["data"]?.arrayValue) {
                guard let value = entry.objectValue, value["title"] == .string(title) else { continue }
                let id = try XCTUnwrap(value["id"]?.literalStringValue)
                guard id.range(of: #"^ses_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                    throw Pass5LiveFailure("Invalid owned session ID")
                }
                let canonical = try await client.getV2Session(sessionID: id)
                guard canonical.id == id, canonical.title == title, canonical.directory == directory,
                      canonical.projectID == project.projectID else {
                    throw Pass5LiveFailure("Refusing cleanup without exact ID/title/directory/project ownership")
                }
                try await client.deleteV2Session(sessionID: id)
            }
        }
        let created = try await service.createSession(connection: connection, project: project, title: title, model: nil, reasoning: nil)
        XCTAssertEqual(created.title, title)
        XCTAssertEqual(created.directory, directory)
        XCTAssertEqual(created.connectionID, connection.id)
        let canonical = try await client.getV2Session(sessionID: created.sessionID)
        XCTAssertEqual(canonical.title, title)
        XCTAssertEqual(canonical.directory, directory)
        XCTAssertEqual(canonical.projectID, project.projectID)
        return created
    }

    private func assertNoProviderTurn(_ client: OpenCodeAPIClient, sessionID: String) async throws {
        let pending = try await object(client, "/api/session/\(sessionID)/inbox")
        XCTAssertEqual(pending["data"]?.arrayValue, [])
        let transcript = try await object(client, "/api/session/\(sessionID)/message")
        let messages = try XCTUnwrap(transcript["data"]?.arrayValue)
        // A model-switched marker is valid, but no user input or assistant turn is.
        for message in messages {
            let type = try XCTUnwrap(message.objectValue?["type"]?.literalStringValue)
            XCTAssertFalse(["user", "assistant"].contains(type))
        }
    }

    private func object(_ client: OpenCodeAPIClient, _ path: String) async throws -> [String: OpenCodeJSONValue] {
        let request = try client.makeRequest(path: path, method: "GET", queryItems: [])
        let (data, response) = try await client.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Pass5LiveFailure("Read-only fixture request failed: \(path)") }
        return try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: data)
    }
}

private struct Pass5LiveFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class Pass5LiveRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
