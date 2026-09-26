import XCTest
@testable import OpenClient

@MainActor
final class OpenCodeShortcutTests: XCTestCase {
    private let recentServerConfigsKey = "recentServerConfigs"
    private var previousRecentServerConfigs: Data?
    private var passwordIDsToClean: Set<String> = []
    private var previousPendingOperations: Data?
    private var previousMirror: Data?

    override func setUp() async throws {
        previousRecentServerConfigs = UserDefaults.standard.data(forKey: recentServerConfigsKey)
        previousMirror = UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: recentServerConfigsKey)
        UserDefaults.standard.removeObject(forKey: recentServerConfigsKey)
        ShortcutMockURLProtocol.requestHandler = nil
        passwordIDsToClean = []
        previousPendingOperations = UserDefaults.standard.data(forKey: "shortcutPendingOperations")
        UserDefaults.standard.removeObject(forKey: "shortcutPendingOperations")
    }

    override func tearDown() async throws {
        if let previousRecentServerConfigs {
            UserDefaults.standard.set(previousRecentServerConfigs, forKey: recentServerConfigsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recentServerConfigsKey)
        }
        for serverID in passwordIDsToClean {
            OpenCodeServerPasswordStore().deletePassword(for: serverID)
        }
        ShortcutMockURLProtocol.requestHandler = nil
        UserDefaults.standard.set(previousPendingOperations, forKey: "shortcutPendingOperations")
        OpenClientSharePayloadStore.mirrorRecentServersData(previousMirror)
    }

    func testShortcutEntityIDRoundTripsConnectionIDsWithSeparators() throws {
        let connectionID = "http://127.0.0.1:4096|opencode"
        let id = OpenCodeShortcutEntityID.make(kind: "session", components: [connectionID, "proj|one", "ses/one"])

        XCTAssertEqual(
            OpenCodeShortcutEntityID.components(from: id, kind: "session"),
            [connectionID, "proj|one", "ses/one"]
        )
        XCTAssertNil(OpenCodeShortcutEntityID.components(from: id, kind: "project"))
    }

    func testShortcutModelsFetchFiltersDeprecatedAndMapsReasoning() async throws {
        let connection = try saveShortcutConnection()
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())

        ShortcutMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if ["/api/health", "/api/info"].contains(request.url?.path) {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            if request.url?.path == "/global/health" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"healthy":true,"version":"legacy"}"#))
            }
            if request.url?.path == "/agent" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data("[]"))
            }
            XCTAssertEqual(request.url?.path, "/provider")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            let data = Self.data("""
            {
              "all": [
                {
                  "id": "openai",
                  "name": "OpenAI",
                  "models": {
                    "gpt-5": {
                      "id": "gpt-5",
                      "providerID": "openai",
                      "name": "GPT-5",
                      "capabilities": { "reasoning": true },
                      "variants": { "balanced": true, "deep": true }
                    },
                    "old": {
                      "id": "old",
                      "providerID": "openai",
                      "name": "Old",
                      "capabilities": { "reasoning": false },
                      "status": "deprecated"
                    }
                  }
                },
                {
                  "id": "anthropic",
                  "name": "Anthropic",
                  "models": {
                    "claude": {
                      "id": "claude",
                      "providerID": "anthropic",
                      "name": "Claude",
                      "capabilities": { "reasoning": true },
                      "variants": { "think": true }
                    }
                  }
                }
              ],
              "connected": ["openai"],
              "default": {}
            }
            """)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let models = try await service.models(connection: connection)

        XCTAssertEqual(models.map(\.modelID), ["gpt-5"])
        XCTAssertEqual(models.first?.reasoningVariants, ["balanced", "deep"])
    }

    func testCreateSessionAndSendMessageUsesProjectModelAndReasoning() async throws {
        for preference in [OpenCodeAPIPreference.legacy, .v2] {
            try await assertCreateSessionAndSendMessage(apiPreference: preference)
        }
    }

    func testAutomaticLegacyFallbackProbesOnceBeforeCreateAndSend() async throws {
        for (status, body) in [
            (404, ""),
            (405, ""),
            (200, "<!doctype html><html></html>"),
            (200, #"{"healthy":true}"#)
        ] {
            try await assertCreateSessionAndSendMessage(apiPreference: .automatic, probeStatus: status, probeBody: body)
        }
    }

    private func assertCreateSessionAndSendMessage(
        apiPreference: OpenCodeAPIPreference,
        probeStatus: Int = 404,
        probeBody: String = ""
    ) async throws {
        let connection = try saveShortcutConnection(apiPreference: apiPreference)
        let project = shortcutProject(connection: connection)
        let model = OpenCodeShortcutModelEntity(
            id: OpenCodeShortcutEntityID.make(kind: "model", components: [connection.id, "openai", "gpt-5"]),
            connectionID: connection.id,
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5",
            modelName: "GPT-5",
            reasoningVariants: ["balanced"]
        )
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
        var requests: [URLRequest] = []

        ShortcutMockURLProtocol.requestHandler = { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/health"):
                XCTAssertNil(request.url?.query)
                return (HTTPURLResponse(url: request.url!, statusCode: probeStatus, httpVersion: nil, headerFields: nil)!, Self.data(probeBody))
            case ("GET", "/api/info"):
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            case ("GET", "/global/health"):
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"healthy":true,"version":"legacy"}"#))
            case ("GET", "/session/ses_1"):
                XCTAssertEqual(request.url?.query, "directory=/tmp/project")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(Self.legacySession))
            case ("POST", "/session"):
                XCTAssertEqual(request.url?.query, "directory=/tmp/project")
                let body = try XCTUnwrap(request.httpBodyData)
                XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["title": "Shortcut"])
                let data = Self.data("""
                {
                  "id": "ses_1",
                  "title": "Shortcut",
                  "workspaceID": null,
                  "directory": "/tmp/project",
                  "projectID": "proj_1",
                  "parentID": null
                }
                """)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            case ("POST", "/session/ses_1/prompt_async"):
                XCTAssertEqual(request.url?.query, "directory=/tmp/project")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
                let body = try XCTUnwrap(request.httpBodyData)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(json["variant"] as? String, "balanced")
                XCTAssertEqual((json["model"] as? [String: String])?["providerID"], "openai")
                XCTAssertEqual((json["model"] as? [String: String])?["modelID"], "gpt-5")
                let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
                XCTAssertEqual(parts.first?["text"] as? String, "Hello from shortcuts")
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            default:
                XCTFail("Unexpected request: \(request.httpMethod ?? "nil") \(request.url?.absoluteString ?? "nil")")
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }

        let session = try await service.createSessionAndSendMessage(
            connection: connection,
            project: project,
            title: " Shortcut ",
            message: " Hello from shortcuts ",
            model: model,
            reasoning: "balanced"
        )

        XCTAssertEqual(session.sessionID, "ses_1")
        XCTAssertEqual(session.providerID, "openai")
        XCTAssertEqual(session.modelID, "gpt-5")
        XCTAssertEqual(session.reasoningVariant, "balanced")
        let probesInfo = probeStatus == 404 || probeStatus == 405 || probeBody.hasPrefix("<!doctype html")
        let expectedPaths = ["/api/health"] + (probesInfo ? ["/api/info"] : [])
            + ["/global/health", "/session", "/session/ses_1", "/session/ses_1/prompt_async"]
        XCTAssertEqual(requests.map { $0.url?.path }, expectedPaths)
    }

    func testV2DiscoveryAndCreationUseCoreFactoryWithoutLegacyRequests() async throws {
        for preference in OpenCodeAPIPreference.allCases {
            let connection = try saveShortcutConnection(apiPreference: preference)
            let project = shortcutProject(connection: connection)
            let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
            var paths: [String] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                let body: String
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/health"):
                    body = Self.v2Health
                case ("GET", "/api/location"):
                    body = #"{"directory":"/tmp/project","project":{"id":"proj_1","directory":"/tmp/project","canonical":"/tmp/project"}}"#
                case ("GET", "/api/project"):
                    body = #"[{"id":"proj_1","canonical":"/tmp/project","sandboxes":[]}]"#
                case ("GET", "/api/session"):
                    XCTAssertTrue(request.url?.query?.contains("directory=/tmp/project") == true)
                    body = "{\"data\":[\(Self.v2Session)]}"
                case ("GET", "/api/session/ses_1"):
                    body = "{\"data\":\(Self.v2Session)}"
                case ("GET", "/api/agent"):
                    body = #"{"data":[]}"#
                case ("GET", "/api/provider"):
                    body = #"{"data":[{"id":"openai","name":"OpenAI","disabled":false}]}"#
                case ("GET", "/api/model"):
                    body = "{\"data\":[\(Self.v2Model)]}"
                case ("GET", "/api/model/default"):
                    body = "{\"data\":\(Self.v2Model)}"
                case ("POST", "/api/session"):
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    XCTAssertEqual((json["location"] as? [String: String])?["directory"], "/tmp/project")
                    XCTAssertEqual((json["model"] as? [String: String])?["id"], "gpt-5")
                    XCTAssertEqual((json["model"] as? [String: String])?["variant"], "balanced")
                    body = "{\"data\":\(Self.v2Session)}"
                case ("POST", "/api/session/ses_1/prompt"):
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    XCTAssertNil(json["model"])
                    XCTAssertNil(json["variant"])
                    let id = try XCTUnwrap(json["id"] as? String)
                    body = "{\"data\":{\"id\":\"\(id)\",\"sessionID\":\"ses_1\",\"time\":{\"created\":1},\"type\":\"user\",\"payload\":{},\"delivery\":\"queue\"}}"
                default:
                    XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                    throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            let projects = try await service.projects(connection: connection)
            XCTAssertEqual(projects.map(\.projectID), ["proj_1"])
            let sessions = try await service.sessions(connection: connection, project: project)
            XCTAssertEqual(sessions.map(\.sessionID), ["ses_1"])
            let models = try await service.models(connection: connection)
            XCTAssertEqual(models.map(\.modelID), ["gpt-5"])
            XCTAssertEqual(models.first?.reasoningVariants, ["balanced"])
            let created = try await service.createSession(connection: connection, project: project, title: nil, model: models.first, reasoning: "balanced")
            XCTAssertEqual(created.sessionID, "ses_1")
            _ = try await service.createSessionAndSendMessage(connection: connection, project: project, title: nil, message: "Hello", model: models.first, reasoning: "balanced")
            XCTAssertEqual(paths.filter { $0 == "/api/health" }.count, 5)
            XCTAssertEqual(paths.filter { $0 == "/api/session/ses_1/prompt" }.count, 1)
            XCTAssertFalse(paths.contains { $0.contains("event") || $0.contains("wait") })
        }
    }

    func testAutomaticHTTPFailuresDoNotFallbackOrReserveUsage() async throws {
        let connection = try saveShortcutConnection(apiPreference: .automatic)
        OpenCodeServerPasswordStore().savePassword("wrong", for: connection.id)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unexpectedUsageGate())
        for status in [401, 403, 500] {
            var paths: [String] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/health")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6d3Jvbmc=")
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Self.data("failure"))
            }
            do {
                _ = try await service.createSessionAndSendMessage(
                    connection: connection, project: shortcutProject(connection: connection),
                    title: nil, message: "Hello", model: nil, reasoning: nil
                )
                XCTFail("Expected HTTP failure")
            } catch let OpenCodeAPIError.httpError(code, body) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(body, "failure")
            }
            XCTAssertEqual(paths, ["/api/health"])
            XCTAssertEqual(OpenCodeServerPasswordStore().loadPassword(for: connection.id), "wrong")
            XCTAssertEqual(try service.resolveConnection(connection).config.apiPreference, .automatic)
        }
    }

    func testAutomaticMalformedHealthDoesNotFallback() async throws {
        let connection = try saveShortcutConnection(apiPreference: .automatic)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unexpectedUsageGate())
        for body in ["not JSON", "{}", #"{"healthy":true,"version":"next"}"#,
                     #"{"healthy":false,"version":"next","pid":1}"#] {
            var paths: [String] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                XCTAssertEqual(request.httpMethod, "GET")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            do {
                _ = try await service.createSessionAndSendMessage(
                    connection: connection, project: shortcutProject(connection: connection),
                    title: nil, message: "Hello", model: nil, reasoning: nil
                )
                XCTFail("Expected malformed health failure")
            } catch is DecodingError {
            } catch OpenCodeAPIError.invalidResponse {
            }
            XCTAssertEqual(paths, ["/api/health"])
        }
    }

    func testAutomaticNetworkFailureDoesNotFallback() async throws {
        let connection = try saveShortcutConnection(apiPreference: .automatic)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unexpectedUsageGate())
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            XCTAssertEqual(request.httpMethod, "GET")
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await service.createSessionAndSendMessage(
                connection: connection, project: shortcutProject(connection: connection),
                title: nil, message: "Hello", model: nil, reasoning: nil
            )
            XCTFail("Expected network failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
        XCTAssertEqual(paths, ["/api/health"])
    }

    func testTLSFailureNeverFallsThroughOrChangesCredentials() async throws {
        let connection = try saveShortcutConnection(apiPreference: .automatic)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unexpectedUsageGate())
        _ = try service.resolveConnection(connection)
        let original = UserDefaults.standard.data(forKey: recentServerConfigsKey)
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            throw URLError(.serverCertificateUntrusted)
        }
        do {
            _ = try await service.projects(connection: connection)
            XCTFail("Expected TLS failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .serverCertificateUntrusted)
        }
        XCTAssertEqual(paths, ["/api/health"])
        XCTAssertEqual(UserDefaults.standard.data(forKey: recentServerConfigsKey), original)
        XCTAssertEqual(OpenCodeServerPasswordStore().loadPassword(for: connection.id), "pw")
    }

    func testPreviouslySavedV2UnavailableProbesLegacyButFailsWhenNeitherIsHealthy() async throws {
        let connection = try saveShortcutConnection(apiPreference: .v2)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unexpectedUsageGate())
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await service.createSession(connection: connection, project: shortcutProject(connection: connection), title: nil, model: nil, reasoning: nil)
            XCTFail("Neither protocol is available")
        } catch OpenCodeAPIError.httpError(let code, _) {
            XCTAssertEqual(code, 404)
        }
        XCTAssertEqual(paths, ["/api/health", "/api/info", "/global/health"])
    }

    func testIntentionallyEmptyPasswordPreservesBasicAuthForDiscoveryAndSendButMissingCredentialFails() async throws {
        for preference in OpenCodeAPIPreference.allCases {
            let connection = try saveShortcutConnection(apiPreference: preference)
            let project = shortcutProject(connection: connection)
            OpenCodeServerPasswordStore().savePassword("", for: connection.id)
            let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
            let resolved = try service.resolveConnection(connection)
            XCTAssertEqual(resolved.config.username, "opencode")
            XCTAssertEqual(resolved.config.password, "")
            let savedMetadata = UserDefaults.standard.data(forKey: recentServerConfigsKey)
            var paths: [String] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                // An empty saved password permits requests; it does not disable configured Basic auth.
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6")
                let body: String
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/health"): body = Self.v2Health
                case ("GET", "/api/session"): body = "{\"data\":[\(Self.v2Session)]}"
                case ("GET", "/session"): body = #"[{"id":"ses_1","directory":"/tmp/project","projectID":"proj_1"}]"#
                case ("GET", "/api/session/ses_1"): body = "{\"data\":\(Self.v2Session)}"
                case ("GET", "/session/ses_1"): body = Self.legacySession
                case ("POST", "/api/session/ses_1/prompt"):
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    let id = try XCTUnwrap(json["id"] as? String)
                    body = "{\"data\":{\"id\":\"\(id)\",\"sessionID\":\"ses_1\",\"time\":{\"created\":1},\"type\":\"user\",\"payload\":{},\"delivery\":\"queue\"}}"
                case ("POST", "/session/ses_1/prompt_async"): body = ""
                default:
                    XCTFail("Unexpected empty-password request")
                    throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            let sessions = try await service.sessions(connection: connection, project: project)
            _ = try await service.sendMessage(connection: connection, project: project, session: XCTUnwrap(sessions.first), message: "Hello", model: nil, reasoning: nil)
            XCTAssertEqual(paths.filter { $0 == "/api/health" }.count, 2)
            XCTAssertEqual(OpenCodeServerPasswordStore().loadPassword(for: connection.id), "")
            OpenCodeServerPasswordStore().deletePassword(for: connection.id)
            let requestCount = paths.count
            do {
                _ = try await service.sessions(connection: connection, project: project)
                XCTFail("Missing protected credential must not retry anonymously")
            } catch OpenCodeShortcutError.missingCredentials {
            }
            XCTAssertEqual(paths.count, requestCount)
            XCTAssertEqual(UserDefaults.standard.data(forKey: recentServerConfigsKey), savedMetadata)
        }
    }

    func testExistingSessionSelectionRoutesPerProfileAndAwaitsV2ModelPOST() async throws {
        for preference in [OpenCodeAPIPreference.legacy, .v2] {
            let connection = try saveShortcutConnection(apiPreference: preference)
            let project = shortcutProject(connection: connection)
            let selected = shortcutSession(connection: connection, project: project).applying(model: shortcutModel(connection: connection), reasoning: "balanced")
            let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
            var paths: [String] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                let path = try XCTUnwrap(request.url?.path)
                paths.append(path)
                var body = ""
                switch path {
                case "/api/health":
                    if preference == .legacy {
                        return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                    }
                    body = Self.v2Health
                case "/api/info":
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                case "/global/health": body = #"{"healthy":true,"version":"legacy"}"#
                case "/api/session/ses_1": body = "{\"data\":\(Self.v2Session)}"
                case "/session/ses_1": body = Self.legacySession
                case "/api/session/ses_1/model":
                    XCTAssertEqual(request.httpMethod, "POST")
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    XCTAssertEqual(json["model"] as? [String: String], ["providerID": "openai", "id": "gpt-5", "variant": "deep"])
                case "/api/session/ses_1/prompt":
                    XCTAssertEqual(paths, ["/api/health", "/api/session/ses_1", "/api/session/ses_1/model", "/api/session/ses_1", "/api/session/ses_1/prompt"])
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    XCTAssertNil(json["model"])
                    let id = try XCTUnwrap(json["id"] as? String)
                    body = "{\"data\":{\"id\":\"\(id)\",\"sessionID\":\"ses_1\",\"time\":{\"created\":1},\"type\":\"user\",\"payload\":{},\"delivery\":\"queue\"}}"
                case "/session/ses_1/prompt_async":
                    XCTAssertEqual(paths.count, 5)
                    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: Any])
                    XCTAssertEqual(json["model"] as? [String: String], ["providerID": "openai", "modelID": "gpt-5"])
                    XCTAssertEqual(json["variant"] as? String, "deep")
                default:
                    XCTFail("Unexpected selection request: \(path)")
                    throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            let output = try await service.sendMessage(connection: connection, project: project, session: selected, message: "Hello", model: nil, reasoning: "deep")
            XCTAssertEqual(output.reasoningVariant, "deep")
        }
    }

    func testV2SelectionFailureDoesNotPOSTPromptAndRefundsReservation() async throws {
        let connection = try saveShortcutConnection(apiPreference: .v2)
        let project = shortcutProject(connection: connection)
        var meter = OpenClientUsageMeter.empty
        let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: gate)
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            let health = request.url?.path == "/api/health"
            if request.url?.path == "/api/session/ses_1" {
                XCTAssertEqual(request.httpMethod, "GET")
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data("{\"data\":\(Self.v2Session)}"))
            }
            if !health { XCTAssertEqual(request.url?.path, "/api/session/ses_1/model") }
            return (HTTPURLResponse(url: request.url!, statusCode: health ? 200 : 401, httpVersion: nil, headerFields: nil)!, Self.data(health ? Self.v2Health : "unauthorized"))
        }
        do {
            _ = try await service.sendMessage(connection: connection, project: project, session: shortcutSession(connection: connection, project: project), message: "Hello", model: shortcutModel(connection: connection), reasoning: "balanced")
            XCTFail("Selection failure must stop the send")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(paths, ["/api/health", "/api/session/ses_1", "/api/session/ses_1/model"])
        XCTAssertEqual(meter.dailyPromptCount, 0)
        XCTAssertEqual(OpenCodeServerPasswordStore().loadPassword(for: connection.id), "pw")
    }

    func testHTTPPromptFailuresOnlyRefundDefinitiveRejections() async throws {
        for preference in [OpenCodeAPIPreference.legacy, .v2] {
            for status in [503, 408, 409, 422] {
                UserDefaults.standard.removeObject(forKey: "shortcutPendingOperations")
                let connection = try saveShortcutConnection(apiPreference: preference)
                let project = shortcutProject(connection: connection)
                var meter = OpenClientUsageMeter.empty
                let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
                let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: gate)
                var posts = 0
                ShortcutMockURLProtocol.requestHandler = { request in
                    if request.url?.path == "/api/health" {
                        if preference == .legacy {
                            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                        }
                        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(Self.v2Health))
                    }
                    if request.url?.path == "/api/info" {
                        return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                    }
                    if request.url?.path == "/global/health" {
                        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"healthy":true,"version":"legacy"}"#))
                    }
                    if request.httpMethod == "GET" {
                        XCTAssertEqual(request.url?.path, preference == .legacy ? "/session/ses_1" : "/api/session/ses_1")
                        let body = preference == .legacy ? Self.legacySession : "{\"data\":\(Self.v2Session)}"
                        return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
                    }
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.url?.path, preference == .legacy ? "/session/ses_1/prompt_async" : "/api/session/ses_1/prompt")
                    posts += 1
                    return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Self.data("failure"))
                }
                do {
                    _ = try await service.sendMessage(connection: connection, project: project, session: shortcutSession(connection: connection, project: project), message: "Hello", model: nil, reasoning: nil)
                    XCTFail("HTTP failure cannot acknowledge admission")
                } catch OpenCodeShortcutError.rejected {
                    XCTAssertEqual(status, 422)
                } catch OpenCodeShortcutError.uncertainAdmission {
                    XCTAssertNotEqual(status, 422)
                }
                XCTAssertEqual(posts, 1)
                XCTAssertEqual(meter.dailyPromptCount, status == 422 ? 0 : 1)
            }
        }
    }

    func testInjectedCoreUsesFreshCapturedConfigurationWithoutClientOrEvents() async throws {
        let connection = try saveShortcutConnection()
        let core = ShortcutCore()
        var service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
        var snapshots: [OpenCodeServerConfig] = []
        var lifetimes: [BackendConnection] = []
        service.makeBackend = { config, _ in
            snapshots.append(config)
            let backend = core.connection()
            XCTAssertNil(backend.openCodeCompatibility)
            lifetimes.append(backend)
            return backend
        }
        ShortcutMockURLProtocol.requestHandler = { _ in
            XCTFail("Injected core must not resolve an OpenCode client")
            throw URLError(.unsupportedURL)
        }
        let projects = try await service.projects(connection: connection)
        let project = try XCTUnwrap(projects.first)
        let sessions = try await service.sessions(connection: connection, project: project)
        _ = try await service.models(connection: connection)
        OpenCodeServerPasswordStore().savePassword("latest", for: connection.id)
        core.beforeSubmit = {
            OpenCodeServerPasswordStore().savePassword("next-operation", for: connection.id)
        }
        _ = try await service.sendMessage(connection: connection, project: project, session: XCTUnwrap(sessions.first), message: "Hello", model: nil, reasoning: nil)
        XCTAssertEqual(snapshots.map(\.password), ["pw", "pw", "pw", "latest"])
        XCTAssertEqual(core.submissions.last?.scope, .init(projectID: "proj_1", directory: "/tmp/project"))
        XCTAssertTrue(lifetimes.allSatisfy(\.isClosed))
        XCTAssertEqual(Set(lifetimes.map(\.id)).count, 4)
        XCTAssertEqual(core.eventStarts, 0)
    }

    func testSessionEntityResolutionCapturesOneConnectionForAllIDs() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let core = ShortcutCore()
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        var configurations = 0
        service.makeBackend = { _, _ in
            configurations += 1
            return core.connection()
        }
        let values = try await service.sessions(matching: [selected.id, selected.id])
        XCTAssertEqual(values.map(\.id), [selected.id])
        XCTAssertEqual(configurations, 1)
        XCTAssertEqual(core.projectReads, 1)
    }

    func testGlobalCreationPreservesLegacyScopeAndResolvesV2ServerDefault() async throws {
        let connection = try saveShortcutConnection()
        let project = OpenCodeShortcutProjectEntity(id: "global", connectionID: connection.id, projectID: "global", title: "Global", directory: nil)
        for sessionSelection in [false, true] {
            let core = ShortcutCore()
            var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
            service.makeBackend = { _, _ in core.connection(selection: sessionSelection) }
            let output = try await service.createSession(connection: connection, project: project, title: "  Name  ", model: shortcutModel(connection: connection), reasoning: "deep")
            XCTAssertEqual(output.projectID, "global")
            XCTAssertEqual(core.creations.first?.title, "Name")
            XCTAssertEqual(core.creations.first?.scope.projectID, "global")
            XCTAssertEqual(core.creations.first?.scope.directory, sessionSelection ? "/server/default" : nil)
            XCTAssertEqual(core.creations.first?.model, .init(providerID: "openai", modelID: "gpt-5"))
            XCTAssertEqual(core.creations.first?.variant, "deep")
            XCTAssertEqual(core.projectReads, sessionSelection ? 1 : 0)
        }
    }

    func testSessionDiscoveryAndPersistedResolutionFollowOpaqueCursorsBeyond100() async throws {
        let connection = try saveShortcutConnection(apiPreference: .v2)
        let project = shortcutProject(connection: connection)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
        for matching in [false, true] {
            var cursors: [String?] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                let body: String
                switch request.url?.path {
                case "/api/health": body = Self.v2Health
                case "/api/location":
                    body = #"{"directory":"/tmp/project","project":{"id":"proj_1","directory":"/tmp/project","canonical":"/tmp/project"}}"#
                case "/api/project":
                    body = #"[{"id":"proj_1","canonical":"/tmp/project","sandboxes":[]}]"#
                case "/api/session":
                    let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
                    XCTAssertTrue(query.contains(.init(name: "limit", value: cursors.count == 1 ? "1" : "100")))
                    let cursor = query.first { $0.name == "cursor" }?.value
                    cursors.append(cursor)
                    if cursor == nil {
                        let records = (0..<100).map { Self.v2Session.replacingOccurrences(of: "ses_1", with: "ses_page_\($0)") }
                        body = "{\"data\":[\(records.joined(separator: ","))],\"cursor\":{\"next\":\"opaque-next\"}}"
                    } else {
                        XCTAssertEqual(cursor, "opaque-next")
                        body = "{\"data\":[\(Self.v2Session)],\"cursor\":{\"next\":null}}"
                    }
                default:
                    XCTFail("Unexpected discovery request")
                    throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            let values: [OpenCodeShortcutSessionEntity]
            if matching {
                values = try await service.sessions(matching: [shortcutSession(connection: connection, project: project).id])
            } else {
                values = try await service.sessions(connection: connection, project: project)
            }
            XCTAssertEqual(values.count, matching ? 1 : 101)
            XCTAssertEqual(values.last?.sessionID, "ses_1")
            XCTAssertEqual(cursors, [nil, "opaque-next", "opaque-next"], "Probe must preserve the actual continuation read")
        }
    }

    func testDiscoveryStopsCursorCyclesDeduplicatesAndFiltersNonRootAndWrongProject() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection() }
        var cursors: [String?] = []
        core.sessionsHandler = { scope, cursor, limit, roots in
            XCTAssertEqual(scope, .init(projectID: "proj_1", directory: "/tmp/project"))
            XCTAssertEqual(limit, 100)
            XCTAssertTrue(roots)
            cursors.append(cursor)
            let child = OpenCodeSession(id: "child", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: "ses_1")
            let wrongProject = OpenCodeSession(id: "wrong", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "other", parentID: nil)
            return .init(sessions: [core.existing, child, wrongProject], nextCursor: cursor == "a" ? "b" : "a")
        }
        let values = try await service.sessions(connection: connection, project: project)
        XCTAssertEqual(values.map(\.sessionID), ["ses_1"])
        XCTAssertEqual(cursors, [nil, "a", "b"])
    }

    func testStaleCanonicalTargetsNeverChangeModelOrSubmitAndRefundUsage() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let targets = [
            OpenCodeSession(id: "other", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: nil),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "other", parentID: nil),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: "/moved", projectID: "proj_1", parentID: nil),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: "moved", directory: "/tmp/project", projectID: "proj_1", parentID: nil),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: "parent"),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: nil, projectID: "proj_1", parentID: nil),
            OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)
        ]
        for selection in [false, true] {
            for target in targets {
                let core = ShortcutCore()
                core.existing = target
                var meter = OpenClientUsageMeter.empty
                var service = OpenCodeShortcutService(usageGate: .init(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 }))
                service.makeBackend = { _, _ in core.connection(selection: selection) }
                do {
                    _ = try await service.sendMessage(connection: connection, project: project, session: selected,
                        message: "Hello", model: shortcutModel(connection: connection), reasoning: nil)
                    XCTFail("A stale destination must not redirect")
                } catch OpenCodeShortcutError.mismatchedSession {}
                XCTAssertTrue(core.modelSelections.isEmpty)
                XCTAssertTrue(core.submissions.isEmpty)
                XCTAssertEqual(core.calls, ["session"])
                XCTAssertEqual(meter.dailyPromptCount, 0)
                XCTAssertTrue(try service.pendingOperations.records(serverNamespace: ShortcutPendingOperationStore.requestHash([connection.id, "backend", "shortcut-core"]), sessionID: selected.sessionID).isEmpty)
            }
        }
    }

    func testTargetMovingDuringModelSelectionIsRecheckedBeforePrompt() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.beforeSetModel = { _, _ in
            core.existing = .init(id: "ses_1", title: nil, workspaceID: "moved", directory: "/tmp/project", projectID: "proj_1", parentID: nil)
        }
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection(selection: true) }
        do {
            _ = try await service.sendMessage(connection: connection, project: project, session: shortcutSession(connection: connection, project: project),
                message: "Hello", model: shortcutModel(connection: connection), reasoning: nil)
            XCTFail("The model setter must not allow a moved destination to receive the prompt")
        } catch OpenCodeShortcutError.mismatchedSession {}
        XCTAssertEqual(core.calls, ["session", "model", "session"])
        XCTAssertTrue(core.submissions.isEmpty)
    }

    func testGlobalDiscoveryAndSendKeepNilScopeWithLegacyDefaultDirectory() async throws {
        let connection = try saveShortcutConnection(username: "", password: "")
        let project = OpenCodeShortcutProjectEntity(id: "global", connectionID: connection.id, projectID: "global", title: "Global", directory: nil)
        let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic Og==")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertFalse(query.contains { $0.name == "directory" })
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            let record = #"{"id":"ses_1","projectID":"global","directory":"/server/default"}"#
            let body: String
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/health"):
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Self.data("{}"))
            case ("GET", "/api/info"):
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Self.data("{}"))
            case ("GET", "/global/health"): body = #"{"healthy":true,"version":"legacy-test"}"#
            case ("GET", "/session"): body = "[\(record)]"
            case ("GET", "/session/ses_1"): body = record
            case ("POST", "/session/ses_1/prompt_async"): body = ""
            default: throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
        }
        let sessions = try await service.sessions(connection: connection, project: project)
        let selected = try XCTUnwrap(sessions.first)
        XCTAssertEqual(selected.directory, "/server/default")
        _ = try await service.sendMessage(connection: connection, project: project, session: selected, message: "Hello", model: nil, reasoning: nil)
        XCTAssertEqual(paths, ["/api/health", "/api/info", "/global/health", "/session", "/api/health", "/api/info", "/global/health", "/session/ses_1", "/session/ses_1/prompt_async"])
    }

    func testCanonicalWorkspaceIsPreservedWithoutRedirectingToProjectWorktree() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.existing = .init(id: "ses_1", title: nil, workspaceID: "workspace", directory: "/tmp/worktree", projectID: "proj_1", parentID: nil)
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection(selection: true) }
        let selected = OpenCodeShortcutSessionEntity(id: "selected", connectionID: connection.id, projectID: project.projectID,
            sessionID: "ses_1", title: "Session", directory: "/tmp/worktree", workspaceID: "workspace", providerID: nil, modelID: nil, reasoningVariant: nil)
        core.sessionHandler = { id, scope in
            XCTAssertEqual(id, "ses_1")
            XCTAssertEqual(scope, .init(projectID: "proj_1", directory: "/tmp/worktree", workspaceID: "workspace"))
            return core.existing
        }
        _ = try await service.sendMessage(connection: connection, project: project, session: selected, message: "Hello", model: nil, reasoning: nil)
        XCTAssertEqual(core.submissions.first?.scope, .init(projectID: "proj_1", directory: "/tmp/worktree", workspaceID: "workspace"))
    }

    func testDeletedSessionReadFailsBeforeSelectionOrPrompt() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.sessionHandler = { _, _ in throw OpenCodeAPIError.httpError(404, "missing") }
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection(selection: true) }
        do {
            _ = try await service.sendMessage(connection: connection, project: project, session: shortcutSession(connection: connection, project: project),
                message: "Hello", model: shortcutModel(connection: connection), reasoning: nil)
            XCTFail("A deleted destination must fail")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 404)
        }
        XCTAssertTrue(core.modelSelections.isEmpty)
        XCTAssertTrue(core.submissions.isEmpty)
    }

    func testCreateAndSendRejectsCanonicalWrongProjectBeforePrompt() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.existing = .init(id: "ses_1", title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "other", parentID: nil)
        var meter = OpenClientUsageMeter.empty
        var service = OpenCodeShortcutService(usageGate: .init(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 }))
        service.makeBackend = { _, _ in core.connection() }
        do {
            _ = try await service.createSessionAndSendMessage(connection: connection, project: project, title: nil, message: "Hello", model: nil, reasoning: nil)
            XCTFail("Creation must not relabel another project's destination")
        } catch OpenCodeShortcutError.mismatchedSession {}
        XCTAssertEqual(core.creations.count, 1)
        XCTAssertEqual(core.calls, ["session"])
        XCTAssertTrue(core.submissions.isEmpty)
        XCTAssertEqual(meter.dailyPromptCount, 0)
        XCTAssertEqual(meter.createdSessionCount, 1)
        XCTAssertEqual(core.deletes, 0)
    }

    func testReasoningOnlyUsesLatestSessionModelBeforeV2Submission() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.existing.model = .init(providerID: "latest", modelID: "server-model", variant: nil)
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection(selection: true) }
        _ = try await service.sendMessage(connection: connection, project: project, session: shortcutSession(connection: connection, project: project), message: "Hello", model: nil, reasoning: "deep")
        XCTAssertEqual(core.modelSelections.first?.model, .init(providerID: "latest", modelID: "server-model"))
        XCTAssertEqual(core.modelSelections.first?.variant, "deep")
        XCTAssertEqual(core.calls, ["session", "model", "session", "submit"])
    }

    func testMissingNonGlobalDirectoryNeverCreatesInUnrelatedServerDefault() async throws {
        let connection = try saveShortcutConnection()
        let core = ShortcutCore()
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection(selection: true) }
        let project = OpenCodeShortcutProjectEntity(id: "missing", connectionID: connection.id, projectID: "missing", title: "Missing", directory: nil)
        do {
            _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
            XCTFail("Unknown project must not use the global default directory")
        } catch BackendError.invalidScope {}
        XCTAssertTrue(core.creations.isEmpty)
    }

    func testUncertainAndThrownAdmissionsPersistIdentityBlockRerunAndDoNotRefund() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        for result in [ShortcutCore.SubmissionResult.uncertain, .thrown, .wrongIdentity] {
            let core = ShortcutCore()
            core.result = result
            var meter = OpenClientUsageMeter.empty
            let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
            var service = OpenCodeShortcutService(usageGate: gate)
            service.makeBackend = { _, _ in core.connection() }
            do {
                _ = try await service.sendMessage(connection: connection, project: project, session: selected, message: "private prompt", model: nil, reasoning: nil)
                XCTFail("Uncertain admission is not success")
            } catch OpenCodeShortcutError.uncertainAdmission {}
            XCTAssertEqual(meter.dailyPromptCount, 1)
            let submission = try XCTUnwrap(core.submissions.first)
            let persisted = try XCTUnwrap(UserDefaults.standard.data(forKey: "shortcutPendingOperations"))
            let json = try XCTUnwrap(String(data: persisted, encoding: .utf8))
            XCTAssertFalse(json.contains("private prompt"))
            XCTAssertFalse(json.contains("password"))
            XCTAssertFalse(json.contains(connection.baseURL))
            XCTAssertTrue(json.contains(submission.messageID))
            var rerun = OpenCodeShortcutService(usageGate: gate)
            rerun.makeBackend = { _, _ in core.connection() }
            core.messages = [.local(role: "user", text: "unrelated", messageID: "other", sessionID: selected.sessionID),
                             .local(role: "user", text: "wrong scope", messageID: submission.messageID, sessionID: "other-session")]
            do {
                _ = try await rerun.sendMessage(connection: connection, project: project, session: selected, message: "private prompt", model: nil, reasoning: nil)
                XCTFail("Absence of exact canonical identity is unknown")
            } catch OpenCodeShortcutError.uncertainAdmission {}
            XCTAssertEqual(core.submissions.count, 1)
            XCTAssertEqual(meter.dailyPromptCount, 1)
            core.messages = [.local(role: "user", text: "", messageID: submission.messageID, sessionID: selected.sessionID)]
            _ = try await rerun.sendMessage(connection: connection, project: project, session: selected, message: "private prompt", model: nil, reasoning: nil)
            XCTAssertEqual(core.submissions.count, 1)
            core.result = .accepted
            _ = try await rerun.sendMessage(connection: connection, project: project, session: selected, message: "private prompt", model: nil, reasoning: nil)
            XCTAssertEqual(core.submissions.count, 2, "Successful intents must not be permanently deduplicated")
            XCTAssertNotEqual(core.submissions.last?.messageID, submission.messageID)
            XCTAssertEqual(meter.dailyPromptCount, 2)
        }
    }

    func testCreateAndSendUncertaintyReconcilesPendingIdentityWithoutRecreateOrDelete() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.result = .uncertain
        var meter = OpenClientUsageMeter.empty
        let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
        var service = OpenCodeShortcutService(usageGate: gate)
        service.makeBackend = { _, _ in core.connection(selection: true) }
        do {
            _ = try await service.createSessionAndSendMessage(connection: connection, project: project, title: "Private title", message: "Private prompt", model: nil, reasoning: nil)
            XCTFail("Expected uncertain admission")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertEqual(meter.createdSessionCount, 1)
        XCTAssertEqual(meter.dailyPromptCount, 1)
        let submitted = try XCTUnwrap(core.submissions.first)
        core.pendingIDs = [submitted.messageID]
        let output = try await service.createSessionAndSendMessage(connection: connection, project: project, title: "Private title", message: "Private prompt", model: nil, reasoning: nil)
        XCTAssertEqual(output.sessionID, submitted.sessionID)
        XCTAssertEqual(core.creations.count, 1)
        XCTAssertEqual(core.submissions.count, 1)
        XCTAssertEqual(core.transcriptReads, 0)
        XCTAssertEqual(meter.dailyPromptCount, 1)
        XCTAssertEqual(core.deletes, 0)
    }

    func testUncertainCreationCannotAutomaticallyCreateAnotherSession() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.creationError = URLError(.networkConnectionLost)
        var service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        service.makeBackend = { _, _ in core.connection() }
        for _ in 0..<2 {
            do {
                _ = try await service.createSessionAndSendMessage(connection: connection, project: project, title: nil, message: "Hello", model: nil, reasoning: nil)
                XCTFail("Expected unknown creation")
            } catch OpenCodeShortcutError.uncertainCreation {}
        }
        XCTAssertEqual(core.creations.count, 1)
        XCTAssertTrue(core.submissions.isEmpty)
        XCTAssertEqual(core.deletes, 0)
    }

    func testUncertainCreationIdentityUsesNegotiatedProfileNotSavedPreference() async throws {
        for initialProfile in [OpenCodeAPIProfile.legacy, .v2] {
            UserDefaults.standard.removeObject(forKey: "shortcutPendingOperations")
            var profile = initialProfile
            let connection = try saveShortcutConnection(apiPreference: profile == .legacy ? .legacy : .v2)
            let project = shortcutProject(connection: connection)
            let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
            var posts: [OpenCodeAPIProfile] = []
            ShortcutMockURLProtocol.requestHandler = { request in
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/health"):
                    let status = profile == .legacy ? 404 : 200
                    return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Self.data(profile == .legacy ? "" : Self.v2Health))
                case ("GET", "/api/info"):
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                case ("GET", "/global/health"):
                    XCTAssertEqual(profile, .legacy)
                    return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"healthy":true,"version":"legacy"}"#))
                case ("POST", "/session"), ("POST", "/api/session"):
                    XCTAssertEqual(request.url?.path, profile == .legacy ? "/session" : "/api/session")
                    posts.append(profile)
                    throw URLError(.networkConnectionLost)
                default:
                    XCTFail("Uncertain creation without an ID must not query another profile")
                    throw URLError(.unsupportedURL)
                }
            }
            for preference in [initialProfile == .legacy ? OpenCodeAPIPreference.legacy : .v2, .automatic] {
                _ = try saveShortcutConnection(apiPreference: preference)
                do {
                    _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
                    XCTFail("Creation is uncertain")
                } catch OpenCodeShortcutError.uncertainCreation {}
            }
            XCTAssertEqual(posts, [initialProfile], "Automatic resolving to the same profile must recover the same operation")
            let first = try JSONDecoder().decode([String: ShortcutPendingOperationStore.Record].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "shortcutPendingOperations")))
            profile = initialProfile == .legacy ? .v2 : .legacy
            do {
                _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
                XCTFail("The other profile's creation is independently uncertain")
            } catch OpenCodeShortcutError.uncertainCreation {}
            let records = try JSONDecoder().decode([String: ShortcutPendingOperationStore.Record].self,
                from: XCTUnwrap(UserDefaults.standard.data(forKey: "shortcutPendingOperations")))
            XCTAssertEqual(posts, [initialProfile, profile])
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(Set(records.values.map(\.serverNamespace)).count, 2)
            for (hash, record) in first { XCTAssertEqual(records[hash], record) }
        }
    }

    func testShippedProfilelessCreationRecordsRecoverOnlyThroughLegacy() async throws {
        for sessionID: String? in [nil, "ses_1"] {
            UserDefaults.standard.removeObject(forKey: "shortcutPendingOperations")
            let connection = try saveShortcutConnection(apiPreference: .v2)
            let project = shortcutProject(connection: connection)
            let store = ShortcutPendingOperationStore()
            // Exact shipped hash components, intentionally with no profile field or migration.
            let hash = try ShortcutPendingOperationStore.requestHash(["create", connection.id, project.projectID, project.directory,
                nil, nil, nil, nil, nil, nil, nil, nil])
            let old = ShortcutPendingOperationStore.Record(requestHash: hash,
                serverNamespace: try ShortcutPendingOperationStore.requestHash([connection.id]), sessionID: sessionID, directory: project.directory)
            UserDefaults.standard.set(try JSONEncoder().encode([hash: old]), forKey: "shortcutPendingOperations")
            let service = OpenCodeShortcutService(session: makeMockSession(), usageGate: unlockedUsageGate())
            var paths: [String] = []
            var useLegacy = false
            ShortcutMockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                let body: String
                switch (request.httpMethod, request.url?.path) {
                case ("GET", "/api/health"):
                    if useLegacy {
                        return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                    }
                    body = Self.v2Health
                case ("GET", "/api/info"):
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                case ("GET", "/global/health"): body = #"{"healthy":true,"version":"legacy"}"#
                case ("POST", "/api/session"): body = "{\"data\":\(Self.v2Session)}"
                case ("GET", "/session/ses_1"): body = Self.legacySession
                default:
                    XCTFail("A legacy pending record must never be queried through v2 or recreated through legacy")
                    throw URLError(.unsupportedURL)
                }
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(body))
            }
            _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
            XCTAssertEqual(paths, ["/api/health", "/api/session"])
            XCTAssertEqual(try store.record(for: hash), old)
            _ = try saveShortcutConnection(apiPreference: .legacy)
            useLegacy = true
            if sessionID == nil {
                do {
                    _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
                    XCTFail("Unknown legacy creation must still fail closed")
                } catch OpenCodeShortcutError.uncertainCreation {}
                XCTAssertEqual(paths, ["/api/health", "/api/session", "/api/health", "/api/info", "/global/health"])
                XCTAssertEqual(try store.record(for: hash), old)
            } else {
                _ = try await service.createSession(connection: connection, project: project, title: nil, model: nil, reasoning: nil)
                XCTAssertEqual(paths, ["/api/health", "/api/session", "/api/health", "/api/info", "/global/health", "/session/ses_1"])
                XCTAssertNil(try store.record(for: hash))
            }
        }
    }

    func testCapturedProfilesHaveIndependentSessionLocksAndLateReceipts() async throws {
        let connection = try saveShortcutConnection(apiPreference: .automatic)
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let legacy = ShortcutCore()
        let v2 = ShortcutCore()
        let posted = ShortcutTestLatch()
        let receipt = ShortcutTestLatch()
        legacy.submissionHandler = { request in
            posted.open()
            await receipt.wait()
            return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        }
        v2.result = .uncertain
        var legacyService = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        legacyService.makeBackend = { _, _ in legacy.connection(profile: .legacy) }
        var v2Service = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        v2Service.makeBackend = { _, _ in v2.connection(selection: true, profile: .v2) }
        let first = Task {
            try await legacyService.sendMessage(connection: connection, project: project, session: selected, message: "same", model: nil, reasoning: nil)
        }
        defer { receipt.open() }
        await posted.wait()
        do {
            _ = try await v2Service.sendMessage(connection: connection, project: project, session: selected, message: "same", model: nil, reasoning: nil)
            XCTFail("V2 keeps its own uncertain admission")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        let namespace = try ShortcutPendingOperationStore.requestHash([connection.id, "profile", "v2"])
        let pending = try XCTUnwrap(v2Service.pendingOperations.records(serverNamespace: namespace, sessionID: selected.sessionID).first)
        receipt.open()
        _ = try await first.value
        XCTAssertEqual(try v2Service.pendingOperations.record(for: pending.requestHash), pending)
        XCTAssertEqual(legacy.submissions.count, 1)
        XCTAssertEqual(v2.submissions.count, 1)
        XCTAssertEqual(legacy.transcriptReads, 0)
        XCTAssertEqual(v2.transcriptReads, 0)
    }

    func testStoreRejectsCrossProfileReceiptEvenWithReusedOperationUUIDAndHash() async throws {
        let store = ShortcutPendingOperationStore()
        let legacy = ShortcutPendingOperationStore.Record(requestHash: "hash", serverNamespace: "legacy", sessionID: "same", messageID: "same")
        let wrongProfile = ShortcutPendingOperationStore.Record(requestHash: legacy.requestHash, serverNamespace: "v2",
            operationID: legacy.operationID, sessionID: legacy.sessionID, messageID: legacy.messageID)
        try await store.acquireSession(legacy)
        defer { store.finishInvocation(legacy); store.finishInvocation(wrongProfile) }
        XCTAssertTrue(try store.claim(legacy))
        XCTAssertFalse(try store.isCurrent(wrongProfile))
        XCTAssertFalse(store.isActive(wrongProfile))
        XCTAssertFalse(store.ownsSession(wrongProfile))
        XCTAssertFalse(try store.save(wrongProfile))
        XCTAssertFalse(try store.remove(wrongProfile))
        XCTAssertFalse(try store.confirm(wrongProfile))
        store.finishInvocation(wrongProfile)
        XCTAssertTrue(store.isActive(legacy))
        XCTAssertTrue(store.ownsSession(legacy))
        XCTAssertEqual(try store.record(for: legacy.requestHash), legacy)
        XCTAssertTrue(try store.confirm(legacy))
        XCTAssertTrue(store.isConfirmed(legacy))
        XCTAssertFalse(store.isConfirmed(wrongProfile))
    }

    func testDefinitiveRejectionRefundsPromptWithoutDeletingCreatedSession() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let core = ShortcutCore()
        core.result = .rejected
        var meter = OpenClientUsageMeter.empty
        let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
        var service = OpenCodeShortcutService(usageGate: gate)
        service.makeBackend = { _, _ in core.connection() }
        do {
            _ = try await service.createSessionAndSendMessage(connection: connection, project: project, title: nil, message: "Hello", model: nil, reasoning: nil)
            XCTFail("Rejected admission must not succeed")
        } catch OpenCodeShortcutError.rejected {}
        XCTAssertEqual(meter.dailyPromptCount, 0)
        XCTAssertEqual(meter.createdSessionCount, 1)
        XCTAssertEqual(core.deletes, 0)
    }

    func testV2PendingReaderUsesVerifiedEndpointAndNeverMutates() async throws {
        let client = OpenCodeAPIClient(config: .init(baseURL: "http://shortcut.test", username: "", password: ""), session: makeMockSession())
        let reader = OpenCodeV2SessionSelectionService(client: client, version: "0.0.0-next-17155")
        ShortcutMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/pending")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"data":[{"id":"msg_exact"}]}"#))
        }
        let ids = try await reader.pendingInputIDs(sessionID: "ses_1", scope: .init())
        XCTAssertEqual(ids, ["msg_exact"])
    }

    func testV2AgentSelectionWrapperUsesSessionRoute() async throws {
        let client = OpenCodeAPIClient(config: .init(baseURL: "http://shortcut.test", username: "", password: ""), session: makeMockSession())
        let selection = OpenCodeV2SessionSelectionService(client: client, version: "0.0.0-next-17155")
        ShortcutMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/agent")
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBodyData)) as? [String: String]
            XCTAssertEqual(json, ["agent": "plan"])
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await selection.setAgent(sessionID: "ses_1", agent: "plan", scope: .init(directory: "/tmp/project"))
    }

    func testPendingStoreFailsClosedOnCorruptionAndHashesUnambiguousRequestComponents() throws {
        let store = ShortcutPendingOperationStore()
        XCTAssertNotEqual(try ShortcutPendingOperationStore.requestHash(["a|b", "c"]),
                          try ShortcutPendingOperationStore.requestHash(["a", "b|c"]))
        UserDefaults.standard.set(Self.data("invalid"), forKey: store.key)
        XCTAssertThrowsError(try store.record(for: "hash"))
        XCTAssertThrowsError(try store.claim(.init(requestHash: "hash", serverNamespace: "server")))
    }

    func testPendingStoreOnlyCurrentOwnerCanSaveRemoveOrConfirm() async throws {
        let store = ShortcutPendingOperationStore()
        var old = ShortcutPendingOperationStore.Record(requestHash: "same-hash", serverNamespace: "server", sessionID: "session", messageID: "m1")
        let newer = ShortcutPendingOperationStore.Record(requestHash: old.requestHash, serverNamespace: "server", sessionID: "session", messageID: "m2")
        defer { store.finishInvocation(old); store.finishInvocation(newer) }
        try await store.acquireSession(old)
        XCTAssertTrue(try store.claim(old))
        XCTAssertFalse(try store.claim(newer))
        XCTAssertTrue(try store.confirm(old))
        try await store.acquireSession(newer)
        XCTAssertTrue(try store.claim(newer))
        old.directory = "/stale"
        XCTAssertFalse(try store.isCurrent(old))
        XCTAssertFalse(try store.save(old))
        XCTAssertFalse(try store.remove(old))
        XCTAssertFalse(try store.confirm(old))
        store.finishInvocation(old)
        XCTAssertTrue(store.ownsSession(newer), "Stale completion must not unlock a newer operation")
        XCTAssertEqual(try store.record(for: old.requestHash), newer)
        XCTAssertTrue(try store.remove(newer))
        store.finishInvocation(newer)
        XCTAssertFalse(try store.save(old), "A stale save cannot resurrect a settled operation either")
        let next = ShortcutPendingOperationStore.Record(requestHash: old.requestHash, serverNamespace: "server", sessionID: "session", messageID: "m3")
        defer { store.finishInvocation(next) }
        XCTAssertTrue(try store.claim(next), "Completed sequential intents are not permanently deduplicated")
    }

    func testPersistedRecordsWithoutOwnershipOrNamespaceFailClosed() throws {
        let store = ShortcutPendingOperationStore()
        let oldData = Self.data(#"{"old":{"requestHash":"old","sessionID":"ses_1","messageID":"m1"}}"#)
        UserDefaults.standard.set(oldData, forKey: store.key)
        XCTAssertThrowsError(try store.records(serverNamespace: "any", sessionID: "ses_1"))
        XCTAssertThrowsError(try store.claim(.init(requestHash: "new-hash", serverNamespace: "any", sessionID: "ses_1")))
        XCTAssertEqual(UserDefaults.standard.data(forKey: store.key), oldData)
    }

    func testIdenticalOverlappingIntentBeforePersistenceDoesNotBecomeAnotherSequentialSend() async throws {
        let store = ShortcutPendingOperationStore()
        let first = ShortcutPendingOperationStore.Record(requestHash: "same", serverNamespace: "server", sessionID: "session")
        let overlapping = ShortcutPendingOperationStore.Record(requestHash: first.requestHash, serverNamespace: first.serverNamespace, sessionID: first.sessionID)
        try await store.acquireSession(first)
        defer { store.finishInvocation(first); store.finishInvocation(overlapping) }
        do {
            try await store.acquireSession(overlapping)
            XCTFail("An identical in-flight invocation must not queue another automatic POST")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertTrue(store.ownsSession(first))
        store.finishInvocation(first)
        try await store.acquireSession(overlapping)
        XCTAssertTrue(store.ownsSession(overlapping), "After completion the same input is a valid new invocation")
    }

    func testCancellingQueuedSessionOperationDoesNotReleaseAnotherOwner() async throws {
        let store = ShortcutPendingOperationStore()
        let owner = ShortcutPendingOperationStore.Record(requestHash: "owner", serverNamespace: "server", sessionID: "session")
        let queued = ShortcutPendingOperationStore.Record(requestHash: "queued", serverNamespace: "server", sessionID: "session")
        let entered = ShortcutTestLatch()
        try await store.acquireSession(owner)
        defer { store.finishInvocation(owner); store.finishInvocation(queued) }
        let task = Task {
            entered.open()
            try await store.acquireSession(queued)
        }
        await entered.wait()
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled queued work must not acquire or mutate the session")
        } catch is CancellationError {}
        XCTAssertTrue(store.ownsSession(owner))
        XCTAssertFalse(store.ownsSession(queued))
        store.finishInvocation(owner)
        try await store.acquireSession(queued)
        XCTAssertTrue(store.ownsSession(queued))
    }

    func testSessionGateAndPendingLookupAreNamespacedBySavedServer() async throws {
        let store = ShortcutPendingOperationStore()
        let first = ShortcutPendingOperationStore.Record(requestHash: "first", serverNamespace: "saved-server-a", sessionID: "same-session-id")
        let second = ShortcutPendingOperationStore.Record(requestHash: "second", serverNamespace: "saved-server-b", sessionID: "same-session-id")
        defer { store.finishInvocation(first); store.finishInvocation(second) }
        try await store.acquireSession(first)
        XCTAssertTrue(try store.claim(first))
        try await store.acquireSession(second)
        XCTAssertTrue(try store.claim(second))
        XCTAssertTrue(store.ownsSession(first))
        XCTAssertTrue(store.ownsSession(second))
        XCTAssertEqual(try store.records(serverNamespace: first.serverNamespace, sessionID: "same-session-id"), [first])
        XCTAssertEqual(try store.records(serverNamespace: second.serverNamespace, sessionID: "same-session-id"), [second])
    }

    func testDelayedReceiptCannotEraseNewerUncertainOperationAfterCanonicalReconciliation() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let namespace = try ShortcutPendingOperationStore.requestHash([connection.id, "backend", "shortcut-core"])
        let core = ShortcutCore()
        let posted = ShortcutTestLatch()
        let receipt = ShortcutTestLatch()
        var meter = OpenClientUsageMeter.empty
        let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
        core.submissionHandler = { request in
            if core.submissions.count == 1 {
                posted.open()
                await receipt.wait()
                return .accepted(sessionID: request.sessionID, messageID: request.messageID)
            }
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
        var serviceA = OpenCodeShortcutService(usageGate: gate)
        serviceA.makeBackend = { _, _ in core.connection(selection: true) }
        var serviceB = OpenCodeShortcutService(usageGate: gate)
        serviceB.makeBackend = { _, _ in core.connection(selection: true) }
        var serviceC = OpenCodeShortcutService(usageGate: gate)
        serviceC.makeBackend = { _, _ in core.connection(selection: true) }
        let first = Task {
            try await serviceA.sendMessage(connection: connection, project: project, session: selected, message: "same input", model: nil, reasoning: nil)
        }
        defer { receipt.open() }
        await posted.wait()
        let old = try XCTUnwrap(serviceB.pendingOperations.records(serverNamespace: namespace, sessionID: selected.sessionID).first)
        core.messages = [.local(role: "user", text: "", messageID: try XCTUnwrap(old.messageID), sessionID: selected.sessionID)]
        do {
            _ = try await serviceB.sendMessage(connection: connection, project: project, session: selected, message: "same input", model: nil, reasoning: nil)
            XCTFail("The still-active invocation owns the success result, not its concurrent reconciler")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertNil(try serviceB.pendingOperations.record(for: old.requestHash))
        XCTAssertTrue(serviceB.pendingOperations.isConfirmed(old))
        core.messages = []
        do {
            _ = try await serviceC.sendMessage(connection: connection, project: project, session: selected, message: "same input", model: nil, reasoning: nil)
            XCTFail("C must retain its uncertain admission")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        let newer = try XCTUnwrap(serviceC.pendingOperations.record(for: old.requestHash))
        XCTAssertNotEqual(newer.operationID, old.operationID)
        XCTAssertNotEqual(newer.messageID, old.messageID)
        receipt.open()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.sessionID, selected.sessionID)
        XCTAssertEqual(try serviceC.pendingOperations.record(for: old.requestHash), newer)
        do {
            _ = try await serviceB.sendMessage(connection: connection, project: project, session: selected, message: "same input", model: nil, reasoning: nil)
            XCTFail("A late receipt must not allow m3")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertEqual(core.submissions.count, 2)
        XCTAssertEqual(meter.dailyPromptCount, 2)
    }

    func testSessionSelectionAndPromptSerializeAcrossIndependentShortcutServices() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let otherSession = shortcutSession(connection: connection, project: project, sessionID: "ses_other")
        let core = ShortcutCore()
        core.sessionHandler = { id, _ in
            OpenCodeSession(id: id, title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: nil)
        }
        let selectedA = ShortcutTestLatch()
        let releaseA = ShortcutTestLatch()
        let configuredB = ShortcutTestLatch()
        var lifetimes: [UUID] = []
        var capturedPasswords: [String] = []
        core.beforeSetModel = { sessionID, model in
            if sessionID == selected.sessionID, model.modelID == "model-a" {
                selectedA.open()
                await releaseA.wait()
            }
        }
        var serviceA = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        serviceA.makeBackend = { _, _ in
            let backend = core.connection(selection: true)
            lifetimes.append(backend.id)
            return backend
        }
        var serviceB = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        serviceB.makeBackend = { config, _ in
            capturedPasswords.append(config.password)
            let backend = core.connection(selection: true)
            lifetimes.append(backend.id)
            configuredB.open()
            return backend
        }
        let first = Task {
            try await serviceA.sendMessage(connection: connection, project: project, session: selected, message: "A", model: shortcutModel(connection: connection, modelID: "model-a"), reasoning: nil)
        }
        defer { releaseA.open() }
        await selectedA.wait()
        let second = Task {
            try await serviceB.sendMessage(connection: connection, project: project, session: selected, message: "B", model: shortcutModel(connection: connection, modelID: "model-b"), reasoning: nil)
        }
        await configuredB.wait()
        OpenCodeServerPasswordStore().savePassword("changed-while-waiting", for: connection.id)
        _ = try await serviceA.sendMessage(connection: connection, project: project, session: otherSession, message: "Other", model: nil, reasoning: nil)
        XCTAssertEqual(core.modelSelections.count, 1, "Another session can finish, but B cannot change A's model while A is suspended")
        releaseA.open()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(core.submissions.filter { $0.sessionID == selected.sessionID }.map(\.text), ["A", "B"])
        XCTAssertEqual(core.modelsAtSubmission.filter { $0.sessionID == selected.sessionID }.map(\.modelID), ["model-a", "model-b"])
        XCTAssertEqual(capturedPasswords, ["pw"], "Queued work must not re-resolve mutable credentials")
        XCTAssertEqual(Set(lifetimes).count, 3, "Session serialization must not depend on a backend connection UUID")
    }

    func testUncertainInputBlocksDifferentHashSelectionAndSendButNotOtherSessions() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let core = ShortcutCore()
        core.result = .uncertain
        var meter = OpenClientUsageMeter.empty
        let gate = OpenCodeShortcutUsageGate(isProUnlocked: { false }, loadMeter: { meter }, saveMeter: { meter = $0 })
        var firstService = OpenCodeShortcutService(usageGate: gate)
        firstService.makeBackend = { _, _ in core.connection(selection: true) }
        do {
            _ = try await firstService.sendMessage(connection: connection, project: project, session: selected, message: "first", model: shortcutModel(connection: connection, modelID: "model-a"), reasoning: nil)
            XCTFail("Expected uncertain first input")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        let first = try XCTUnwrap(core.submissions.first)
        core.result = .accepted
        var nextService = OpenCodeShortcutService(usageGate: gate)
        nextService.makeBackend = { _, _ in core.connection(selection: true) }
        do {
            _ = try await nextService.sendMessage(connection: connection, project: project, session: selected, message: "different content", model: shortcutModel(connection: connection, modelID: "model-b"), reasoning: "deep")
            XCTFail("A different request hash cannot bypass session uncertainty")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertEqual(core.modelSelections.count, 1)
        XCTAssertEqual(core.submissions.count, 1)
        XCTAssertEqual(meter.dailyPromptCount, 1)
        core.sessionHandler = { id, _ in
            OpenCodeSession(id: id, title: nil, workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: nil)
        }
        _ = try await nextService.sendMessage(connection: connection, project: project,
            session: shortcutSession(connection: connection, project: project, sessionID: "other"), message: "Other", model: nil, reasoning: nil)
        core.messages = [.local(role: "user", text: "", messageID: first.messageID, sessionID: first.sessionID)]
        do {
            _ = try await nextService.sendMessage(connection: connection, project: project, session: selected, message: "different content", model: shortcutModel(connection: connection, modelID: "model-b"), reasoning: "deep")
            XCTFail("Recovering a different input is read-only, not an automatic POST")
        } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertEqual(core.modelSelections.count, 1)
        XCTAssertEqual(core.submissions.count, 2)
        XCTAssertEqual(meter.dailyPromptCount, 2)
        _ = try await nextService.sendMessage(connection: connection, project: project, session: selected, message: "different content", model: shortcutModel(connection: connection, modelID: "model-b"), reasoning: "deep")
        XCTAssertEqual(core.modelSelections.count, 2)
        XCTAssertEqual(core.submissions.count, 3)
        XCTAssertEqual(meter.dailyPromptCount, 3)
    }

    func testQueuedDifferentInputRechecksUncertaintyBeforeChangingModel() async throws {
        let connection = try saveShortcutConnection()
        let project = shortcutProject(connection: connection)
        let selected = shortcutSession(connection: connection, project: project)
        let core = ShortcutCore()
        let posted = ShortcutTestLatch()
        let receipt = ShortcutTestLatch()
        let configuredB = ShortcutTestLatch()
        core.submissionHandler = { request in
            posted.open()
            await receipt.wait()
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
        var serviceA = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        serviceA.makeBackend = { _, _ in core.connection(selection: true) }
        var serviceB = OpenCodeShortcutService(usageGate: unlockedUsageGate())
        serviceB.makeBackend = { _, _ in
            configuredB.open()
            return core.connection(selection: true)
        }
        let first = Task {
            try await serviceA.sendMessage(connection: connection, project: project, session: selected, message: "A", model: shortcutModel(connection: connection, modelID: "model-a"), reasoning: nil)
        }
        defer { receipt.open() }
        await posted.wait()
        let second = Task {
            try await serviceB.sendMessage(connection: connection, project: project, session: selected, message: "B", model: shortcutModel(connection: connection, modelID: "model-b"), reasoning: nil)
        }
        await configuredB.wait()
        receipt.open()
        do { _ = try await first.value; XCTFail("A is uncertain") } catch OpenCodeShortcutError.uncertainAdmission {}
        do { _ = try await second.value; XCTFail("B must not auto-post after A becomes uncertain") } catch OpenCodeShortcutError.uncertainAdmission {}
        XCTAssertEqual(core.modelSelections.map { $0.model.modelID }, ["model-a"])
        XCTAssertEqual(core.submissions.map(\.text), ["A"])
    }

    func testResolveConnectionMigratesPublicPreferenceAndPreservesKeychainIdentityWithoutRequests() throws {
        let service = OpenCodeShortcutService(session: makeMockSession())
        ShortcutMockURLProtocol.requestHandler = { request in
            XCTFail("Synchronous connection resolution must not issue requests")
            throw URLError(.badServerResponse)
        }
        for preference in OpenCodeAPIPreference.allCases {
            let connection = try saveShortcutConnection(apiPreference: preference)
            let resolved = try service.resolveConnection(connection)
            XCTAssertEqual(connection.id, "http://shortcut.test|opencode")
            XCTAssertEqual(resolved.config.recentServerID, connection.id)
            XCTAssertEqual(resolved.config.password, "pw")
            XCTAssertEqual(resolved.config.apiPreference, .automatic)
            let data = try XCTUnwrap(UserDefaults.standard.data(forKey: recentServerConfigsKey))
            XCTAssertEqual(try JSONDecoder().decode([OpenCodeSavedServer].self, from: data).first?.apiPreference, .automatic)
            XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: recentServerConfigsKey), data)
        }
    }

    func testHeadlessShortcutMigratesLegacyPlaintextBeforeCredentialHydration() throws {
        let connection = try saveShortcutConnection(apiPreference: .legacy)
        OpenCodeServerPasswordStore().deletePassword(for: connection.id)
        let savedData = try XCTUnwrap(UserDefaults.standard.data(forKey: recentServerConfigsKey))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [[String: Any]])
        entries[0]["password"] = "legacy-only-copy"
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: entries), forKey: recentServerConfigsKey)
        let service = OpenCodeShortcutService(session: makeMockSession())
        ShortcutMockURLProtocol.requestHandler = { _ in
            XCTFail("Credential migration and discovery must not issue network requests")
            throw URLError(.badServerResponse)
        }

        XCTAssertEqual(service.connections().first?.id, connection.id)
        let resolved = try service.resolveConnection(connection)

        XCTAssertEqual(resolved.config.apiPreference, .automatic)
        XCTAssertEqual(resolved.config.recentServerID, connection.id)
        XCTAssertEqual(resolved.config.password, "legacy-only-copy")
        XCTAssertEqual(OpenCodeServerPasswordStore().loadPassword(for: connection.id), "legacy-only-copy")
        let sanitized = try XCTUnwrap(UserDefaults.standard.data(forKey: recentServerConfigsKey))
        let sanitizedEntries = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]])
        XCTAssertNil(sanitizedEntries.first?["password"])
        XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: recentServerConfigsKey), sanitized)
    }

    func testSavedConnectionWithoutPreferenceAutomaticallyProbesBeforeLegacyDiscovery() async throws {
        let connection = try saveShortcutConnection()
        let savedData = try XCTUnwrap(UserDefaults.standard.data(forKey: recentServerConfigsKey))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [[String: Any]])
        entries[0].removeValue(forKey: "apiPreference")
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: entries), forKey: recentServerConfigsKey)
        let service = OpenCodeShortcutService(session: makeMockSession())
        let resolved = try service.resolveConnection(connection)
        XCTAssertEqual(resolved.config.apiPreference, .automatic)
        XCTAssertEqual(resolved.config.password, "pw")
        var paths: [String] = []
        ShortcutMockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            if ["/api/health", "/api/info"].contains(request.url?.path) {
                return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            if request.url?.path == "/global/health" {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data(#"{"healthy":true,"version":"legacy"}"#))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.data("[]"))
        }
        let projects = try await service.projects(connection: connection)
        XCTAssertTrue(projects.isEmpty)
        XCTAssertEqual(Array(paths.prefix(3)), ["/api/health", "/api/info", "/global/health"])
        XCTAssertEqual(Set(paths), ["/api/health", "/api/info", "/global/health", "/project", "/project/current"])
    }

    private func shortcutProject(connection: OpenCodeShortcutConnectionEntity) -> OpenCodeShortcutProjectEntity {
        OpenCodeShortcutProjectEntity(
            id: OpenCodeShortcutEntityID.make(kind: "project", components: [connection.id, "proj_1"]),
            connectionID: connection.id,
            projectID: "proj_1",
            title: "Project",
            directory: "/tmp/project"
        )
    }

    private func shortcutSession(connection: OpenCodeShortcutConnectionEntity, project: OpenCodeShortcutProjectEntity, sessionID: String = "ses_1") -> OpenCodeShortcutSessionEntity {
        .init(id: OpenCodeShortcutEntityID.make(kind: "session", components: [connection.id, project.projectID, sessionID]),
              connectionID: connection.id, projectID: project.projectID, sessionID: sessionID, title: "Session",
              directory: project.directory, workspaceID: nil, providerID: nil, modelID: nil, reasoningVariant: nil)
    }

    private func shortcutModel(connection: OpenCodeShortcutConnectionEntity, modelID: String = "gpt-5") -> OpenCodeShortcutModelEntity {
        .init(id: "model", connectionID: connection.id, providerID: "openai", providerName: "OpenAI",
              modelID: modelID, modelName: "GPT-5", reasoningVariants: ["balanced", "deep"])
    }

    private func saveShortcutConnection(apiPreference: OpenCodeAPIPreference = .legacy, username: String = "opencode", password: String = "pw") throws -> OpenCodeShortcutConnectionEntity {
        let saved = OpenCodeSavedServer(
            name: "Test",
            iconName: "server.rack",
            baseURL: "http://shortcut.test",
            username: username,
            apiPreference: apiPreference
        )
        let data = try JSONEncoder().encode([saved])
        UserDefaults.standard.set(data, forKey: recentServerConfigsKey)
        OpenCodeServerPasswordStore().savePassword(password, for: saved.recentServerID)
        passwordIDsToClean.insert(saved.recentServerID)
        return OpenCodeShortcutConnectionEntity(id: saved.recentServerID, displayName: "Test",
                                                baseURL: saved.baseURL, username: saved.username)
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShortcutMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func unlockedUsageGate() -> OpenCodeShortcutUsageGate {
        OpenCodeShortcutUsageGate(isProUnlocked: { true })
    }

    private func unexpectedUsageGate() -> OpenCodeShortcutUsageGate {
        OpenCodeShortcutUsageGate(isProUnlocked: {
            XCTFail("Negotiation must reject this operation before checking or reserving usage")
            return true
        })
    }

    nonisolated private static let v2Health = #"{"healthy":true,"version":"0.0.0-next-17155","pid":24062}"#
    nonisolated private static let legacySession = #"{"id":"ses_1","directory":"/tmp/project","projectID":"proj_1"}"#
    nonisolated private static let v2Session = #"{"id":"ses_1","projectID":"proj_1","location":{"directory":"/tmp/project"},"model":{"providerID":"openai","id":"gpt-5","variant":"balanced"},"time":{"created":1,"updated":2}}"#
    nonisolated private static let v2Model = #"{"id":"gpt-5","providerID":"openai","name":"GPT-5","capabilities":{"tools":true,"input":["text"],"output":["text","reasoning"]},"variants":[{"id":"balanced"}],"limit":{"context":1000,"output":100},"status":"active","enabled":true,"cost":[]}"#

    nonisolated private static func data(_ string: String) -> Data {
        string.data(using: .utf8)!
    }
}

@MainActor
private final class ShortcutCore: BackendProjectsService, BackendSessionsService, BackendModelsService, BackendChatService,
                                  BackendSessionSelectionService, BackendPendingInputReading, BackendEventSource {
    enum SubmissionResult { case accepted, rejected, uncertain, thrown, wrongIdentity }
    var result = SubmissionResult.accepted
    var creationError: Error?
    var existing = OpenCodeSession(id: "ses_1", title: "Session", workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: nil)
    var creations: [BackendSessionCreation] = []
    var submissions: [BackendSubmission] = []
    var modelSelections: [(model: OpenCodeModelReference, variant: String?)] = []
    var messages: [OpenCodeMessageEnvelope] = []
    var pendingIDs: Set<String> = []
    var calls: [String] = []
    var projectReads = 0
    var transcriptReads = 0
    var eventStarts = 0
    var deletes = 0
    var beforeSubmit: (() -> Void)?
    var submissionHandler: (@MainActor (BackendSubmission) async throws -> BackendAdmission)?
    var beforeSetModel: (@MainActor (String, OpenCodeModelReference) async throws -> Void)?
    var selectedModels: [String: OpenCodeModelReference] = [:]
    var modelsAtSubmission: [(sessionID: String, modelID: String?)] = []
    var sessionHandler: (@MainActor (String, BackendScope) throws -> OpenCodeSession)?
    var sessionsHandler: (@MainActor (BackendScope, String?, Int, Bool) throws -> BackendSessionPage)?

    func connection(selection: Bool = false, profile: OpenCodeAPIProfile? = nil) -> BackendConnection {
        let projects: any BackendProjectsService
        if let profile {
            projects = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: .init(baseURL: "http://shortcut.test", username: "", password: "")), profile: profile)
        } else {
            projects = self
        }
        return .init(descriptor: .init(id: "shortcut-core", name: "Core", version: "test"), projects: projects, sessions: self,
              chat: self, models: self, events: self, sessionSelection: selection ? self : nil)
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        projectReads += 1
        return .init(projects: [.init(id: "proj_1", worktree: "/tmp/project", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)], defaultDirectory: "/server/default")
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        if let sessionsHandler { return try sessionsHandler(scope, cursor, limit, roots) }
        return .init(sessions: [existing])
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        calls.append("session")
        if let sessionHandler { return try sessionHandler(id, scope) }
        return existing
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        creations.append(request)
        if let creationError { throw creationError }
        return existing
    }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw BackendError.invalidScope }
    func deleteSession(id: String, scope: BackendScope) async throws { deletes += 1 }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { .init() }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        transcriptReads += 1
        return .init(messages: messages)
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        calls.append("submit")
        submissions.append(request)
        modelsAtSubmission.append((request.sessionID, selectedModels[request.sessionID]?.modelID))
        beforeSubmit?()
        if let submissionHandler { return try await submissionHandler(request) }
        switch result {
        case .accepted: return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        case .rejected: return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        case .uncertain: return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        case .thrown: throw URLError(.networkConnectionLost)
        case .wrongIdentity: return .accepted(sessionID: request.sessionID, messageID: "different")
        }
    }
    func interrupt(sessionID: String, scope: BackendScope) async throws { XCTFail("Shortcuts do not wait for or interrupt turns") }
    func setModel(sessionID: String, model: OpenCodeModelReference, variant: String?, scope: BackendScope) async throws {
        calls.append("model")
        modelSelections.append((model, variant))
        selectedModels[sessionID] = model
        try await beforeSetModel?(sessionID, model)
    }
    func setAgent(sessionID: String, agent: String, scope: BackendScope) async throws { XCTFail("No agent override was requested") }
    func pendingInputIDs(sessionID: String, scope: BackendScope) async throws -> Set<String> { pendingIDs }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { eventStarts += 1 }
    func stop() {}
}

@MainActor
private final class ShortcutTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }
}

private final class ShortcutMockURLProtocol: URLProtocol {
    @MainActor static var requestHandler: (@MainActor (URLRequest) async throws -> (HTTPURLResponse, Data))?
    private struct Delivery: @unchecked Sendable { let loader: ShortcutMockURLProtocol }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.requestHandler)
                let (response, data) = try await handler(request)
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: data)
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
