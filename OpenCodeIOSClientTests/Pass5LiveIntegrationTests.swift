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
        let global = try XCTUnwrap(projects.first { $0.projectID == "global" })
        XCTAssertEqual(global.connectionID, connection.id)
        XCTAssertNil(global.directory, "Global discovery retains its special scope; creation resolves the server directory")
        let matchedProjects = try await service.projects(matching: [global.id])
        XCTAssertEqual(matchedProjects.map(\.id), [global.id])

        let models = try await service.models(connection: connection)
        XCTAssertTrue(models.allSatisfy { $0.connectionID == connection.id })
        if let model = models.first {
            let matchedModels = try await service.models(matching: [model.id])
            XCTAssertEqual(matchedModels.map(\.id), [model.id])
        }
        let created = try await createOwnedSession(client: client, service: service, connection: connection,
                                                   project: global, directory: directory)
        let sessions = try await service.sessions(connection: connection, project: global)
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
        let global = try XCTUnwrap(projects.first { $0.projectID == "global" })
        let models = try await service.models(connection: connection)
        // Prefer the disposable server's test model, but any enabled catalog reference
        // is safe here: the model-selection endpoint does not execute a provider turn.
        let testModel = try XCTUnwrap(models.first { $0.modelID == "testModel" } ?? models.first,
                                     "The isolated server must expose an enabled model for selection coverage")
        let created = try await createOwnedSession(client: client, service: service, connection: connection,
                                                   project: global, directory: directory)
        let factory = OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager())
        let backend = try await factory.connect()
        defer { backend.close() }
        let selection = try XCTUnwrap(backend.sessionSelection)
        let scope = BackendScope(projectID: global.projectID, directory: directory)
        try await selection.setModel(sessionID: created.sessionID, model: testModel.modelReference, variant: nil, scope: scope)
        let canonical = try await client.getV2Session(sessionID: created.sessionID)
        XCTAssertEqual(canonical.model?.providerID, testModel.providerID)
        XCTAssertEqual(canonical.model?.modelID, testModel.modelID)
        // Runtime next-17155 canonicalizes an omitted variant to "default".
        XCTAssertEqual(canonical.model?.variant, "default")
        try await assertNoProviderTurn(client, sessionID: created.sessionID)
        // OpenCodeShortcutService.sendMessage has no paused-submit option. Do not
        // call it and do not describe a model-selection response as prompt admission.
    }

    private func context() async throws -> (OpenCodeAPIClient, OpenCodeShortcutService, OpenCodeShortcutConnectionEntity, String) {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["OPENCODE_V2_TEST_BASE_URL"], !base.isEmpty,
              let username = env["OPENCODE_V2_TEST_USERNAME"], !username.isEmpty,
              let password = env["OPENCODE_V2_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set OPENCODE_V2_TEST_BASE_URL/USERNAME/PASSWORD for disposable pass5 integration tests")
        }
        guard let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw Pass5LiveFailure("Only http://127.0.0.1:14097 is permitted; persistent 4096/4097 are forbidden")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: Pass5LiveRedirectGuard(), delegateQueue: nil)
        addTeardownBlock { session.invalidateAndCancel() }
        // The trailing-slash identity is distinct from the usual UI saved connection.
        // Even this identity is never overwritten if already present in defaults/Keychain.
        let config = OpenCodeServerConfig(name: "Pass5 \(UUID().uuidString)", baseURL: "http://127.0.0.1:14097/",
                                          username: username, password: password, apiPreference: .v2)
        let client = OpenCodeAPIClient(config: config, session: session)
        let health = try await object(client, "/api/health")
        guard health["version"] == .string("0.0.0-next-17155") else { throw Pass5LiveFailure("Unexpected disposable server version") }
        let location = try await client.getV2Location()
        let expected = "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass2-VwCj6l/workspace"
        let standardized = URL(fileURLWithPath: location.directory).standardizedFileURL.path
        let normalized = standardized.hasPrefix("/private/var/") ? String(standardized.dropFirst("/private".count)) : standardized
        guard location.project.id == "global", normalized == expected else {
            throw Pass5LiveFailure("Refusing a server outside the approved disposable workspace")
        }

        let saved = OpenCodeSavedServer(config: config)
        let key = "recentServerConfigs"
        let store = OpenCodeServerPasswordStore()
        var entries: [Any] = []
        if UserDefaults.standard.object(forKey: key) != nil, UserDefaults.standard.data(forKey: key) == nil {
            throw Pass5LiveFailure("Refusing to replace an unrecognized saved-server storage format")
        }
        if let data = UserDefaults.standard.data(forKey: key) {
            entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
            let servers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)
            guard !servers.contains(where: { $0.recentServerID == saved.recentServerID }) else {
                throw XCTSkip("The exact 14097 test identity is already saved; refusing to replace it")
            }
        }
        guard store.loadPassword(for: saved.recentServerID) == nil else {
            throw XCTSkip("The exact 14097 test identity already has Keychain credentials; refusing to replace them")
        }
        // Register before the first persistence write. Cleanup filters only this exact
        // identity and retains concurrent additions instead of restoring an old snapshot.
        addTeardownBlock { @MainActor in
            if let data = UserDefaults.standard.data(forKey: key) {
                let current = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
                let retained = try current.filter { entry in
                    let data = try JSONSerialization.data(withJSONObject: entry)
                    let server = try JSONDecoder().decode(OpenCodeSavedServer.self, from: data)
                    guard server.recentServerID == saved.recentServerID else { return true }
                    guard server == saved else { throw Pass5LiveFailure("Test saved identity changed; refusing to remove another owner's entry") }
                    return false
                }
                UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: retained), forKey: key)
            }
            store.deletePassword(for: saved.recentServerID)
        }
        entries.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)))
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: entries), forKey: key)
        store.savePassword(password, for: saved.recentServerID)
        guard store.loadPassword(for: saved.recentServerID) == password else {
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
                .init(name: "search", value: title), .init(name: "project", value: "global")
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
                guard canonical.id == id, canonical.title == title, canonical.directory == directory, canonical.projectID == "global" else {
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
        XCTAssertEqual(canonical.projectID, "global")
        return created
    }

    private func assertNoProviderTurn(_ client: OpenCodeAPIClient, sessionID: String) async throws {
        let pending = try await object(client, "/api/session/\(sessionID)/pending")
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
