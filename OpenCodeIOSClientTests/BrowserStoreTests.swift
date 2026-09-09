import Combine
import Network
import XCTest
import UIKit
import WebKit
@testable import OpenClient

@MainActor
final class BrowserStoreTests: XCTestCase {
    func testWelcomeDocumentContainsRotatingBrowserPuns() {
        XCTAssertEqual(BrowserWelcomeDocument.puns.count, 16)
        XCTAssertTrue(BrowserWelcomeDocument.html.contains("font-family: ui-serif"))
        XCTAssertTrue(BrowserWelcomeDocument.html.contains("window.setInterval"))
    }

    func testAddressResolverPreservesExplicitWebURL() {
        XCTAssertEqual(
            BrowserAddressResolver.resolve("https://opencode.ai/docs")?.absoluteString,
            "https://opencode.ai/docs"
        )
    }

    func testAddressResolverAddsHTTPSForDomain() {
        XCTAssertEqual(
            BrowserAddressResolver.resolve("opencode.ai/docs")?.absoluteString,
            "https://opencode.ai/docs"
        )
    }

    func testAddressResolverUsesHTTPForLocalhost() {
        XCTAssertEqual(
            BrowserAddressResolver.resolve("localhost:3000")?.absoluteString,
            "http://localhost:3000"
        )
    }

    func testAddressResolverTurnsWordsIntoSearch() {
        let url = BrowserAddressResolver.resolve("OpenCode browser plugin")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        XCTAssertEqual(components?.host, "www.google.com")
        XCTAssertEqual(components?.path, "/search")
        XCTAssertEqual(components?.queryItems, [URLQueryItem(name: "q", value: "OpenCode browser plugin")])
    }

    func testPresentationTransitionsPreserveFocusIntentWhenExpandingCollapsedBrowser() {
        let store = BrowserStore(projectID: "project-a")

        store.openAddressBar()
        let focusRequest = store.addressFocusRequest
        XCTAssertEqual(store.presentation, .expanded)
        XCTAssertTrue(store.consumeAddressFocusRequest())
        XCTAssertFalse(store.consumeAddressFocusRequest())

        store.collapse()
        XCTAssertEqual(store.presentation, .collapsed)

        store.expand()
        XCTAssertEqual(store.presentation, .expanded)
        XCTAssertEqual(store.addressFocusRequest, focusRequest)
        XCTAssertFalse(store.consumeAddressFocusRequest())

        store.close()
        XCTAssertEqual(store.presentation, .closed)
    }

    func testBrowserSessionsAreIsolatedByProject() {
        let store = BrowserStore(projectID: "project-a")

        store.openAddressBar()
        store.addressText = "https://project-a.example"
        store.collapse()

        store.selectProject("project-b")
        XCTAssertEqual(store.presentation, .closed)
        XCTAssertEqual(store.addressText, "")

        store.openAddressBar()
        store.addressText = "https://project-b.example"
        store.collapse()

        store.selectProject("project-a")
        XCTAssertEqual(store.presentation, .collapsed)
        XCTAssertEqual(store.addressText, "https://project-a.example")

        store.selectProject("project-b")
        XCTAssertEqual(store.presentation, .collapsed)
        XCTAssertEqual(store.addressText, "https://project-b.example")
    }

    func testSwitchingProjectsCollapsesExpandedBrowser() {
        let store = BrowserStore(projectID: "project-a")
        store.openAddressBar()

        store.selectProject("project-b")
        XCTAssertEqual(store.presentation, .closed)

        store.selectProject("project-a")
        XCTAssertEqual(store.presentation, .collapsed)
    }

    func testContextPreservesPageAndHistoryOnlyWithinTheSameConnectionProjectAndDirectory() async throws {
        let server = try BrowserHistoryHTTPServer()
        defer { server.stop() }
        let store = BrowserStore()
        let connectionID = UUID()
        store.selectContext(connectionID: connectionID, projectID: "project-a", directory: "/main")
        store.openAddressBar()
        let original = store.webView
        let firstURL = try await loadHistoryFixture(in: original, server: server)
        XCTAssertTrue(original.canGoBack)
        let historyURLs = original.backForwardList.backList.map(\.url)
        XCTAssertTrue(historyURLs.contains(firstURL))

        store.selectContext(connectionID: connectionID, projectID: "project-a", directory: "/main")
        XCTAssertTrue(store.webView === original)
        XCTAssertEqual(store.presentation, .expanded)

        store.selectContext(connectionID: connectionID, projectID: "project-a", directory: "/worktree")
        XCTAssertEqual(store.activeProjectID, "project-a")
        XCTAssertEqual(store.presentation, .closed)
        XCTAssertEqual(store.addressText, "")
        XCTAssertFalse(store.webView === original)
        XCTAssertFalse(store.webView.canGoBack)
        let worktree = store.webView

        store.selectContext(connectionID: connectionID, projectID: "project-b", directory: "/main")
        XCTAssertFalse(store.webView === original)
        XCTAssertFalse(store.webView === worktree)

        store.selectContext(connectionID: connectionID, projectID: "project-a", directory: "/main")
        XCTAssertTrue(store.webView === original)
        XCTAssertEqual(store.presentation, .collapsed)
        XCTAssertTrue(store.webView.canGoBack)
        XCTAssertEqual(store.webView.backForwardList.backList.map(\.url), historyURLs)
        XCTAssertEqual(store.webView.url?.path, "/second")
        store.clearAllBrowserSessions()
    }

    func testConnectionReplacementDropsAllPagesHistoryInstructionsAndAutomationTokens() async throws {
        let server = try BrowserHistoryHTTPServer()
        defer { server.stop() }
        let store = BrowserStore()
        let firstConnection = UUID()
        store.selectContext(connectionID: firstConnection, projectID: "project-a", directory: "/main")
        let original = store.webView
        _ = try await loadHistoryFixture(in: original, server: server)
        XCTAssertTrue(original.canGoBack)
        XCTAssertFalse(original.backForwardList.backList.isEmpty, "Reset must discard real history, not an empty fixture")
        _ = try store.presentForAutomation(instruction: "Old instruction")
        let oldToken = try store.beginAutomationActivity("Old activity")
        store.selectContext(connectionID: firstConnection, projectID: "project-b", directory: "/other")
        let backgroundPage = store.webView

        store.selectContext(connectionID: UUID(), projectID: "project-a", directory: "/main")

        XCTAssertNil(original.navigationDelegate)
        XCTAssertNil(original.uiDelegate)
        XCTAssertNil(backgroundPage.navigationDelegate)
        XCTAssertNil(backgroundPage.uiDelegate)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.presentation, .closed)
        XCTAssertNil(store.currentURL)
        XCTAssertNil(store.userInstruction)
        XCTAssertNil(store.automationStatus)
        XCTAssertEqual(store.addressText, "")
        XCTAssertFalse(store.webView === original)
        XCTAssertTrue(store.webView.backForwardList.backList.isEmpty)
        XCTAssertFalse(store.webView.canGoForward)

        let currentToken = try store.beginAutomationActivity("Current activity")
        var invalidations = 0
        let observation = store.objectWillChange.sink { invalidations += 1 }
        store.endAutomationActivity(oldToken)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(store.automationStatus, "Current activity")
        store.endAutomationActivity(currentToken)
        XCTAssertNil(store.automationStatus)
        withExtendedLifetime(observation) {}

        store.selectContext(connectionID: firstConnection, projectID: "project-b", directory: "/other")
        XCTAssertFalse(store.webView === backgroundPage, "Replacing a connection clears inactive sessions too")
        store.clearAllBrowserSessions()
    }

    func testPageTitlePublishesAfterLoadingAndWithoutNavigationWithoutOverwritingAddressDraft() async throws {
        let server = try BrowserHistoryHTTPServer()
        let store = BrowserStore(projectID: "project-a")
        defer {
            store.clearAllBrowserSessions()
            server.stop()
        }
        store.openAddressBar()
        let webView = store.webView
        let initialTitlePublished = expectation(description: "HTTP page title reaches the browser header")
        let initialObservation = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .filter { store.displayTitle == "History Fixture second" }
            .prefix(1)
            .sink { _ in initialTitlePublished.fulfill() }

        _ = try await loadHistoryFixture(in: webView, server: server)
        await fulfillment(of: [initialTitlePublished], timeout: 5)
        XCTAssertEqual(store.pageTitle, "History Fixture second")
        withExtendedLifetime(initialObservation) {}

        let pageURL = store.currentURL
        let historyURLs = webView.backForwardList.backList.map(\.url)
        store.addressText = "An unsubmitted address draft"
        let updatedTitlePublished = expectation(description: "Post-load title change reaches the browser header")
        let updatedObservation = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .filter { store.displayTitle == "Title changed after load" }
            .prefix(1)
            .sink { _ in updatedTitlePublished.fulfill() }

        // Use WebKit directly: automationSnapshot would force a metadata refresh and mask the bug.
        _ = try await javaScriptString("document.title = 'Title changed after load'; document.title", in: webView)
        await fulfillment(of: [updatedTitlePublished], timeout: 5)

        XCTAssertEqual(store.pageTitle, "Title changed after load")
        XCTAssertEqual(store.displayTitle, "Title changed after load")
        XCTAssertEqual(store.addressText, "An unsubmitted address draft")
        XCTAssertEqual(store.currentURL, pageURL)
        XCTAssertEqual(webView.backForwardList.backList.map(\.url), historyURLs)
        withExtendedLifetime(updatedObservation) {}
    }

    func testAutomationActivityCompletionIsScopedToItsOriginalWorktree() throws {
        let store = BrowserStore()
        let connectionID = UUID()
        store.selectContext(connectionID: connectionID, projectID: "project", directory: "/main")
        let mainToken = try store.beginAutomationActivity("Main activity")
        store.selectContext(connectionID: connectionID, projectID: "project", directory: "/worktree")
        let worktreeToken = try store.beginAutomationActivity("Worktree activity")

        store.endAutomationActivity(mainToken)
        XCTAssertEqual(store.automationStatus, "Worktree activity")
        store.selectContext(connectionID: connectionID, projectID: "project", directory: "/main")
        XCTAssertNil(store.automationStatus)
        store.selectContext(connectionID: connectionID, projectID: "project", directory: "/worktree")
        XCTAssertEqual(store.automationStatus, "Worktree activity")
        store.endAutomationActivity(worktreeToken)
        store.clearAllBrowserSessions()
    }

    func testWebsiteDataIsNonpersistentSharedWithinConnectionAndIsolatedAfterReconnect() async throws {
        let store = BrowserStore()
        let connectionID = UUID()
        store.selectContext(connectionID: connectionID, projectID: "project-a", directory: "/main")
        let firstDataStore = store.webView.configuration.websiteDataStore
        XCTAssertFalse(firstDataStore.isPersistent)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "fixture.example", .path: "/", .name: "browser-session", .value: "first-connection",
        ]))
        await withCheckedContinuation { continuation in
            firstDataStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }

        store.selectContext(connectionID: connectionID, projectID: "project-b", directory: "/worktree")
        let sharedDataStore = store.webView.configuration.websiteDataStore
        XCTAssertTrue(sharedDataStore === firstDataStore)
        let sharedCookies = await withCheckedContinuation { continuation in
            sharedDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(sharedCookies.contains { $0.name == cookie.name && $0.value == cookie.value })

        store.clearAllBrowserSessions()
        XCTAssertNil(store.activeProjectID)
        XCTAssertFalse(store.isActive)
        store.selectContext(connectionID: UUID(), projectID: "project-a", directory: "/main")
        let reconnectedDataStore = store.webView.configuration.websiteDataStore
        XCTAssertFalse(reconnectedDataStore.isPersistent)
        XCTAssertFalse(reconnectedDataStore === firstDataStore)
        let reconnectedCookies = await withCheckedContinuation { continuation in
            reconnectedDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(reconnectedCookies.isEmpty)
        store.clearAllBrowserSessions()
    }

    func testBrowserToolRegistryPublishesPlaywrightStyleTools() async {
        let browser = BrowserStore(projectID: "project-a")
        let registry = OpenClientDeviceToolRegistry(browserStore: browser)

        let toolIDs = await registry.listTools().map(\.id)

        XCTAssertTrue(toolIDs.contains("openclient_browser_navigate"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_present"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_clear_instruction"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_snapshot"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_click"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_type"))
        XCTAssertTrue(toolIDs.contains("openclient_browser_history"))
    }

    func testBrowserAutomationSnapshotsClicksAndTypesUsingElementRefs() async throws {
        let store = BrowserStore(projectID: "project-a")
        store.openAddressBar()
        let webView = store.webView
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
              <head><title>Automation Fixture</title></head>
              <body>
                <button aria-label="Continue" onclick="document.body.dataset.clicked='yes'">Continue</button>
                <input aria-label="Search" value="draft">
                <p>Visible fixture text</p>
              </body>
            </html>
            """,
            baseURL: URL(string: "https://fixture.example")
        )
        for _ in 0 ..< 50 {
            if webView.url != nil, !webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        store.close()

        let snapshot = try await store.automationSnapshot()
        let button = try XCTUnwrap(snapshot.elements.first { $0.role == "button" && $0.name == "Continue" })
        let input = try XCTUnwrap(snapshot.elements.first { $0.role == "textbox" && $0.name == "Search" })

        XCTAssertEqual(snapshot.page.title, "Automation Fixture")
        XCTAssertTrue(snapshot.visibleText.contains("Visible fixture text"))
        XCTAssertEqual(store.presentation, .closed)

        _ = try await store.automationClick(ref: button.ref)
        XCTAssertEqual(store.presentation, .closed)
        let clicked = try await javaScriptString("document.body.dataset.clicked", in: webView)
        XCTAssertEqual(clicked, "yes")

        _ = try await store.automationType(ref: input.ref, text: "OpenClient", clear: true, submit: false)
        XCTAssertEqual(store.presentation, .closed)
        let value = try await javaScriptString("document.querySelector('input').value", in: webView)
        XCTAssertEqual(value, "OpenClient")
    }

    func testBrowserPresentationToolExpandsWithInstruction() throws {
        let store = BrowserStore(projectID: "project-a")

        _ = try store.presentForAutomation(instruction: "Review the generated checkout details.")

        XCTAssertEqual(store.presentation, .expanded)
        XCTAssertEqual(store.userInstruction, "Review the generated checkout details.")

        _ = try store.clearAutomationInstruction()
        XCTAssertNil(store.userInstruction)
    }

    func testBrowserAutomationActivityTracksCurrentToolStatus() throws {
        let store = BrowserStore(projectID: "project-a")

        let first = try store.beginAutomationActivity("Inspecting page")
        XCTAssertEqual(store.presentation, .collapsed)
        let second = try store.beginAutomationActivity("Entering text")
        XCTAssertEqual(store.automationStatus, "Entering text")

        store.endAutomationActivity(second)
        XCTAssertEqual(store.automationStatus, "Inspecting page")

        store.endAutomationActivity(first)
        XCTAssertNil(store.automationStatus)
    }

    private func loadHistoryFixture(in webView: WKWebView, server: BrowserHistoryHTTPServer) async throws -> URL {
        let listening = expectation(description: "Browser history HTTP listener ready")
        server.start { listening.fulfill() }
        await fulfillment(of: [listening], timeout: 5)
        let baseURL = try XCTUnwrap(server.baseURL, server.startupError ?? "Loopback listener did not become ready")

        // Substitute HTML loads do not establish navigable history. Use native HTTP navigations,
        // not script-created entries that WebKit can skip when traversing history.
        for path in ["first", "second"] {
            let url = baseURL.appendingPathComponent(path)
            let title = "History Fixture \(path)"
            let loaded = expectation(description: "Browser history fixture \(path) loaded")
            let observation = webView.publisher(for: \.isLoading)
                .combineLatest(
                    webView.publisher(for: \.title),
                    webView.publisher(for: \.url),
                    webView.publisher(for: \.canGoBack)
                )
                .filter { isLoading, pageTitle, pageURL, canGoBack in
                    !isLoading && pageTitle == title && pageURL == url && (path == "first" || canGoBack)
                }
                .prefix(1)
                .sink { _ in loaded.fulfill() }
            webView.load(URLRequest(url: url))
            await fulfillment(of: [loaded], timeout: 5)
            withExtendedLifetime(observation) {}
        }
        let firstURL = baseURL.appendingPathComponent("first")
        XCTAssertEqual(webView.backForwardList.backItem?.url, firstURL)
        XCTAssertTrue(server.requestedPaths.isSuperset(of: ["/first", "/second"]))
        return firstURL
    }

    private func javaScriptString(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let value = result as? String {
                    continuation.resume(returning: value)
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }
}

@MainActor
private final class BrowserHistoryHTTPServer {
    private let listener: NWListener
    private var connections: [UUID: NWConnection] = [:]
    private var stopped = false
    private(set) var baseURL: URL?
    private(set) var startupError: String?
    private(set) var requestedPaths: Set<String> = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping @MainActor () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, !self.stopped, self.baseURL == nil, self.startupError == nil else { return }
                switch state {
                case .ready:
                    if let port = self.listener.port {
                        self.baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)")
                    }
                    ready()
                case .failed(let error):
                    self.startupError = error.localizedDescription
                    ready()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.stopped else { connection.cancel(); return }
                let id = UUID()
                self.connections[id] = connection
                connection.start(queue: .main)
                self.receive(id, buffered: Data())
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receive(_ id: UUID, buffered: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection = self.connections[id] else { return }
                guard error == nil, let data, !data.isEmpty else { self.close(id); return }
                let bytes = buffered + data
                guard bytes.count <= 16_384 else { self.close(id); return }
                guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { self.close(id) } else { self.receive(id, buffered: bytes) }
                    return
                }
                let header = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                let request = (header.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                guard request.count == 3, request[0] == "GET" else { self.close(id); return }
                let path = String(request[1])
                self.requestedPaths.insert(path)
                let isPage = path == "/first" || path == "/second"
                let title = "History Fixture \(path.dropFirst())"
                let body = isPage ? "<!doctype html><html><head><title>\(title)</title></head><body>Local fixture</body></html>" : ""
                let payload = Data(body.utf8)
                let status = isPage ? "200 OK" : "404 Not Found"
                let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(headers.utf8) + payload, completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in self?.close(id) }
                })
            }
        }
    }
}
