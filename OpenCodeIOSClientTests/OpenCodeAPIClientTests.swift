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
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.sendMessageAsync(sessionID: "ses_test", text: "hello")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testEventURLsBuildScopedAndGlobalEndpoints() throws {
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"))
        let urls = try client.eventURLs(directory: "/Users/mininic")
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://127.0.0.1:4096/event?directory=/Users/mininic",
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
