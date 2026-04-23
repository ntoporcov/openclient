import XCTest
@testable import OpenCodeIOSClient

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
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
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
            XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), #"{"reply":"once"}"#)
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
            XCTAssertEqual(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8), #"{"answers":[["Build"],["Ship"]]}"#)
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
