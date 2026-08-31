import XCTest
@testable import OpenClient

final class OpenCodeAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    func testSendMessageAsyncUsesPromptAsyncEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/prompt_async")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.sendMessageAsync(sessionID: "ses_test", text: "hello", directory: "/tmp/project")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSendMessageAsyncEncodesAgentMentionParts() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0]["type"] as? String, "text")
            XCTAssertEqual(parts[0]["text"] as? String, "ask @explore about this")
            XCTAssertEqual(parts[1]["type"] as? String, "agent")
            XCTAssertEqual(parts[1]["name"] as? String, "explore")
            let source = try XCTUnwrap(parts[1]["source"] as? [String: Any])
            XCTAssertEqual(source["value"] as? String, "@explore")
            XCTAssertEqual(source["start"] as? Int, 4)
            XCTAssertEqual(source["end"] as? Int, 12)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.sendMessageAsync(
            sessionID: "ses_test",
            text: "ask @explore about this",
            agentMentions: [OpenCodeAgentMention(name: "explore", content: "@explore", start: 4, end: 12)]
        )
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDecodesAgentPartSource() throws {
        let data = """
        {
          "info": { "id": "msg_1", "role": "user", "sessionID": "ses_1" },
          "parts": [
            {
              "id": "prt_agent",
              "sessionID": "ses_1",
              "messageID": "msg_1",
              "type": "agent",
              "name": "explore",
              "source": { "value": "@explore", "start": 4, "end": 12 }
            }
          ]
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: data)
        let part = try XCTUnwrap(message.parts.first)
        XCTAssertEqual(part.type, "agent")
        XCTAssertEqual(part.name, "explore")
        XCTAssertEqual(part.source?.value, "@explore")
        XCTAssertEqual(part.source?.start, 4)
        XCTAssertEqual(part.source?.end, 12)
    }

    func testDecodesCommandsWhenMCPSourceReturnsObjectTemplate() throws {
        // opencode returns `template: {}` for MCP-sourced commands; the whole `/command`
        // array must still decode instead of failing with a DecodingError.typeMismatch.
        let data = """
        [
          { "name": "init", "description": "Init", "source": "command", "template": "Create AGENTS.md", "hints": ["$ARGUMENTS"] },
          { "name": "websearch:web_search_help", "description": "Get help with web search", "source": "mcp", "template": {}, "hints": [] }
        ]
        """.data(using: .utf8)!

        let commands = try JSONDecoder().decode([OpenCodeCommand].self, from: data)

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].template, "Create AGENTS.md")
        XCTAssertEqual(commands[1].name, "websearch:web_search_help")
        XCTAssertEqual(commands[1].source, "mcp")
        XCTAssertEqual(commands[1].template, "")
    }

    func testListMessagesRepairsUnpairedUnicodeEscapesInToolOutput() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            expectation.fulfill()

            let data = #"[{"info":{"id":"msg_user","role":"user","sessionID":"ses_test","model":{"providerID":"openai","modelID":"gpt-5.5","variant":"medium"}},"parts":[{"id":"prt_user","messageID":"msg_user","sessionID":"ses_test","type":"text","text":"Use the previous model"}]},{"info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"},"parts":[{"id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_test","type":"tool","tool":"bash","state":{"status":"completed","output":"valid pair \ud83d\ude96 and bad scalar \ude80"}}]}]"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let messages = try await client.listMessages(sessionID: "ses_test")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.info.model?.modelID, "gpt-5.5")
        let output = try XCTUnwrap(messages.last?.parts.first?.state?.output)
        XCTAssertTrue(output.unicodeScalars.contains(UnicodeScalar(0x1F696)!))
        XCTAssertTrue(output.unicodeScalars.contains(UnicodeScalar(0xFFFD)!))
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMessagesUsesLimitAndDirectoryQueryItems() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            expectation.fulfill()
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        _ = try await client.listMessages(sessionID: "ses_test", limit: 20, directory: "/tmp/project")

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMessagePageUsesCursorAndReturnsNextCursorHeader() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "limit", value: "12"),
                URLQueryItem(name: "before", value: "cursor-1"),
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            expectation.fulfill()
            let data = #"[{"info":{"id":"msg_old","role":"user","sessionID":"ses_test"},"parts":[]}]"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Next-Cursor": "cursor-2"]
                )!,
                data
            )
        }

        let page = try await client.listMessagePage(
            sessionID: "ses_test",
            limit: 12,
            before: "cursor-1",
            directory: "/tmp/project"
        )

        XCTAssertEqual(page.messages.map(\.id), ["msg_old"])
        XCTAssertEqual(page.nextCursor, "cursor-2")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testGetSessionUsesExactScopedEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_child")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "workspace-1"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()
            let data = #"{"id":"ses_child","title":"Child","workspaceID":"workspace-1","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let loaded = try await client.getSession(
            sessionID: "ses_child",
            directory: "/tmp/project",
            workspaceID: "workspace-1"
        )

        XCTAssertEqual(loaded.id, "ses_child")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDirectoryBootstrapWarmsChildSessionForPendingPermission() async throws {
        let childRequest = expectation(description: "child session requested")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            let data: Data
            switch request.url?.path {
            case "/session":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "directory", value: "/tmp/project"),
                    URLQueryItem(name: "roots", value: "true"),
                    URLQueryItem(name: "limit", value: "100"),
                ])
                data = #"[{"id":"ses_parent","title":"Parent","directory":"/tmp/project","projectID":"proj_1"}]"#.data(using: .utf8)!
            case "/permission":
                data = #"[{"id":"perm_child","sessionID":"ses_child","permission":"bash","patterns":["xcodebuild test"]}]"#.data(using: .utf8)!
            case "/question", "/command":
                data = Data("[]".utf8)
            case "/session/ses_child":
                childRequest.fulfill()
                data = #"{"id":"ses_child","title":"Child","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#.data(using: .utf8)!
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                data = Data("[]".utf8)
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(
            client: client,
            directory: "/tmp/project",
            sessionLimit: 100
        )

        XCTAssertEqual(bootstrap.sessions.map(\.id), ["ses_parent", "ses_child"])
        XCTAssertEqual(bootstrap.sessions.last?.parentID, "ses_parent")
        XCTAssertEqual(bootstrap.sessionTotal, 1)
        await fulfillment(of: [childRequest], timeout: 1)
    }

    func testUpdateProjectEncodesIconPreferences() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/project/proj_123")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Project")
            let icon = try XCTUnwrap(json["icon"] as? [String: Any])
            XCTAssertEqual(icon["color"] as? String, "purple")
            XCTAssertEqual(icon["override"] as? String, "data:image/png;base64,AAA")
            expectation.fulfill()

            let data = """
            {
              "id": "proj_123",
              "worktree": "/tmp/project",
              "name": "Project",
              "icon": { "color": "purple", "override": "data:image/png;base64,AAA" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let project = try await client.updateProject(
            projectID: "proj_123",
            directory: "/tmp/project",
            name: "Project",
            icon: OpenCodeProject.Icon(override: "data:image/png;base64,AAA", color: "purple")
        )
        XCTAssertEqual(project.icon?.color, "purple")
        XCTAssertEqual(project.icon?.override, "data:image/png;base64,AAA")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testRemoveWorktreeUsesRootDirectoryQueryAndTargetBody() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/experimental/worktree")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")

            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["directory"] as? String, "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let removed = try await client.removeWorktree(rootDirectory: "/tmp/project", worktreeDirectory: "/tmp/project-worktree")
        XCTAssertTrue(removed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResetWorktreeUsesResetEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/experimental/worktree/reset")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["directory"] as? String, "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let reset = try await client.resetWorktree(rootDirectory: "/tmp/project", worktreeDirectory: "/tmp/project-worktree")
        XCTAssertTrue(reset)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDisposeInstanceUsesDirectoryScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/instance/dispose")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project-worktree"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let disposed = try await client.disposeInstance(directory: "/tmp/project-worktree")
        XCTAssertTrue(disposed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testProviderStateUsesProviderEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            let data = #"{"all":[{"id":"openai","name":"OpenAI","source":"api","env":[],"options":{},"models":{"gpt-5":{"id":"gpt-5","providerID":"openai","name":"GPT-5","capabilities":{"reasoning":true},"status":"active","release_date":"2026-01-01"}}}],"connected":["openai"],"default":{"openai":"gpt-5"}}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let state = try await client.providerState(directory: "/tmp/project")

        XCTAssertEqual(state.connected, ["openai"])
        XCTAssertEqual(state.default["openai"], "gpt-5")
        XCTAssertEqual(state.all.first?.models["gpt-5"]?.releaseDate, "2026-01-01")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResolvedConfigLoadsDirectoryPluginsInServerOrder() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/config")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            let data = #"{"plugin":["opencode-example@1.2.3",["file:///tmp/project/.opencode/plugins/local.ts",{"option":true}]]}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let config = try await client.resolvedConfig(directory: "/tmp/project")

        XCTAssertEqual(config.plugins.map(\.specifier), [
            "opencode-example@1.2.3",
            "file:///tmp/project/.opencode/plugins/local.ts",
        ])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResolvedConfigDefaultsMissingPluginListToEmpty() throws {
        let config = try JSONDecoder().decode(OpenCodeResolvedConfig.self, from: Data(#"{"model":"openai/gpt-5"}"#.utf8))

        XCTAssertEqual(config.plugins, [])
    }

    func testSetProviderAPIKeyUsesAuthEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/openai")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, "api")
            XCTAssertEqual(json["key"] as? String, "sk-test")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.setProviderAPIKey(providerID: "openai", key: "sk-test")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testAuthorizeProviderOAuthUsesProviderOAuthEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider/openai/oauth/authorize")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["method"] as? Int, 1)
            XCTAssertEqual((json["inputs"] as? [String: String])?["account"], "pro")
            expectation.fulfill()

            let data = #"{"url":"https://auth.example.com","method":"auto","instructions":"Enter code: ABCD-EFGH"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let authorization = try await client.authorizeProviderOAuth(providerID: "openai", method: 1, inputs: ["account": "pro"], directory: "/tmp/project")
        XCTAssertEqual(authorization?.method, "auto")
        XCTAssertEqual(authorization?.instructions, "Enter code: ABCD-EFGH")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testCompleteProviderOAuthUsesProviderOAuthCallbackEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider/github-copilot/oauth/callback")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["method"] as? Int, 0)
            XCTAssertEqual(json["code"] as? String, "oauth-code")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let completed = try await client.completeProviderOAuth(providerID: "github-copilot", method: 0, code: "oauth-code")
        XCTAssertTrue(completed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testUpdateGlobalConfigEncodesDisabledProviders() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/global/config")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["disabled_providers"] as? [String], ["custom"])
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }

        try await client.updateGlobalConfig(OpenCodeGlobalConfigPatch(provider: nil, disabledProviders: ["custom"]))
        await fulfillment(of: [expectation], timeout: 1)
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
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
        return data.isEmpty ? nil : data
    }

    func testAbortSessionUsesAbortEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/abort")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.abortSession(sessionID: "ses_test", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListSessionStatusesUsesStatusEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/status")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            let data = """
            {
              \"ses_busy\": { \"type\": \"busy\" },
              \"ses_idle\": { \"type\": \"idle\" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let statuses = try await client.listSessionStatuses(directory: "/tmp/project")
        XCTAssertEqual(statuses, ["ses_busy": "busy", "ses_idle": "idle"])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListQuestionsUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let questions = try await client.listQuestions(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(questions, [])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListPermissionsUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/permission")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let permissions = try await client.listPermissions(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(permissions, [])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMCPStatusUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/mcp")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            let data = """
            {
              \"github\": { \"status\": \"connected\" },
              \"broken\": { \"status\": \"failed\", \"error\": \"boom\" },
              \"oauth\": { \"status\": \"needs_client_registration\", \"error\": \"register first\" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let statuses = try await client.listMCPStatus(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(statuses["github"]?.status, "connected")
        XCTAssertEqual(statuses["broken"]?.error, "boom")
        XCTAssertEqual(statuses["oauth"]?.displayStatus, "Needs Registration")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testConnectMCPServerUsesScopedConnectEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path(percentEncoded: true), "/mcp/local%20server/connect")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.connectMCPServer(name: "local server", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDisconnectMCPServerUsesScopedDisconnectEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/mcp/github/disconnect")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.disconnectMCPServer(name: "github", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testReplyToPermissionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/permission/p_123/reply")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"reply":"once"}"#)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.replyToPermission(requestID: "p_123", reply: "once", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testReplyToQuestionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question/q_123/reply")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"answers":[["Build"],["Ship"]]}"#)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.replyToQuestion(requestID: "q_123", answers: [["Build"], ["Ship"]], directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testRejectQuestionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question/q_123/reject")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.rejectQuestion(requestID: "q_123", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testEventURLsBuildScopedAndGlobalEndpoints() throws {
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"))
        let urls = try client.eventURLs(directory: "/tmp/project")
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://127.0.0.1:4096/event?directory=/tmp/project",
            "http://127.0.0.1:4096/global/event",
        ])
    }
}

private func requestBodyString(for request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }

    return String(data: data, encoding: .utf8)
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
