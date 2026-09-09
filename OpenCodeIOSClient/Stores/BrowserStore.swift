import Combine
import Foundation
import WebKit

enum BrowserPresentation: Equatable {
    case closed
    case collapsed
    case expanded
}

struct BrowserAutomationPageState: Codable, Equatable, Sendable {
    let title: String
    let url: String
    let isLoading: Bool
    let canGoBack: Bool
    let canGoForward: Bool
}

struct BrowserAutomationSnapshot: Codable, Equatable, Sendable {
    struct Element: Codable, Equatable, Sendable {
        let ref: String
        let role: String
        let name: String
        let value: String?
        let disabled: Bool
    }

    let page: BrowserAutomationPageState
    let elements: [Element]
    let visibleText: String
}

fileprivate struct BrowserContext: Hashable, Sendable {
    let connectionID: UUID?
    let projectID: String
    let directory: String?
}

struct BrowserAutomationActivityToken: Hashable, Sendable {
    fileprivate let context: BrowserContext
    let id: UUID

    var projectID: String { context.projectID }
}

enum BrowserAutomationError: LocalizedError, Equatable {
    case noActiveProject
    case noPage
    case invalidAddress
    case navigationTimedOut
    case invalidElementReference
    case unsupportedElement
    case invalidHistoryAction

    var errorDescription: String? {
        switch self {
        case .noActiveProject:
            return String(localized: "Select a project before using the in-app browser.")
        case .noPage:
            return String(localized: "Open a page in the in-app browser first.")
        case .invalidAddress:
            return String(localized: "The browser address is invalid.")
        case .navigationTimedOut:
            return String(localized: "The webpage did not finish loading in time.")
        case .invalidElementReference:
            return String(localized: "The browser element reference is missing or stale. Take a new snapshot.")
        case .unsupportedElement:
            return String(localized: "The referenced element does not support this browser action.")
        case .invalidHistoryAction:
            return String(localized: "The browser history action is unsupported.")
        }
    }
}

struct BrowserAddressResolver {
    static func resolve(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }

        if looksLikeWebAddress(trimmed) {
            let scheme = usesLocalHTTP(trimmed) ? "http" : "https"
            return URL(string: "\(scheme)://\(trimmed)")
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components?.url
    }

    private static func looksLikeWebAddress(_ input: String) -> Bool {
        guard input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        let lowercased = input.lowercased()
        return lowercased.contains(".")
            || lowercased.hasPrefix("localhost")
            || lowercased.hasPrefix("[::1]")
    }

    private static func usesLocalHTTP(_ input: String) -> Bool {
        let lowercased = input.lowercased()
        return lowercased.hasPrefix("localhost")
            || lowercased.hasPrefix("127.")
            || lowercased.hasPrefix("0.0.0.0")
            || lowercased.hasPrefix("[::1]")
    }
}

enum BrowserWelcomeDocument {
    static let puns: [LocalizedStringResource] = [
        "No site yet. We're just browsing our options.",
        "Ready to surf? The web is already making waves.",
        "The internet called. It left a hyperlink.",
        "A blank page is just a site waiting to happen.",
        "Let's address the situation.",
        "Good URLs are worth the wait.",
        "This browser has excellent cache flow.",
        "Go ahead. Make a site decision.",
        "The web is vast. No need to rush the current.",
        "Every great web journey begins with a single tap.",
        "Need direction? Start with an address.",
        "We tried to tell a DNS joke, but it couldn't resolve.",
        "Surf responsibly. Some links can be a little clickbaity.",
        "The browser is open-minded. Every tab gets a chance.",
        "Take a byte out of the internet.",
        "Where we're going, we don't need bookmarks. But they help.",
    ]

    static var html: String {
        let localizedPuns = puns.map { String(localized: $0) }
        let encodedPuns = (try? JSONEncoder().encode(localizedPuns)) ?? Data("[]".utf8)
        let punsJSON = String(decoding: encodedPuns, as: UTF8.self)
        let title = htmlEscaped(String(localized: "Browser"))
        let eyebrow = htmlEscaped(String(localized: "OpenClient Browser"))
        let prompt = htmlEscaped(String(localized: "Type an address above and let the good sites roll."))

        return """
        <!doctype html>
        <html lang="\(htmlEscaped(Locale.current.identifier))">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="color-scheme" content="light dark">
          <title>\(title)</title>
          <style>
            :root {
              color-scheme: light dark;
              --ink: rgba(24, 22, 34, 0.92);
              --muted: rgba(42, 38, 56, 0.60);
              --base: #f2f2f7;
            }

            * { box-sizing: border-box; }

            html, body {
              width: 100%;
              min-height: 100%;
              margin: 0;
              overflow: hidden;
            }

            body {
              display: grid;
              place-items: center;
              padding: clamp(24px, 7vw, 72px);
              color: var(--ink);
              background:
                radial-gradient(circle at 18% 16%, rgba(175, 82, 222, 0.34), transparent 38%),
                radial-gradient(circle at 82% 76%, rgba(50, 173, 230, 0.30), transparent 40%),
                radial-gradient(circle at 72% 10%, rgba(255, 149, 0, 0.20), transparent 30%),
                linear-gradient(135deg, rgba(88, 86, 214, 0.30), rgba(175, 82, 222, 0.18) 38%, rgba(50, 173, 230, 0.14) 70%, var(--base));
              font-family: ui-serif, "New York", "Iowan Old Style", "Palatino Linotype", Georgia, serif;
            }

            body::before,
            body::after {
              content: "";
              position: fixed;
              width: min(56vw, 560px);
              aspect-ratio: 1;
              border-radius: 50%;
              filter: blur(28px);
              opacity: 0.54;
              pointer-events: none;
              animation: drift 14s ease-in-out infinite alternate;
            }

            body::before {
              top: -24%;
              right: -18%;
              background: radial-gradient(circle, rgba(175, 82, 222, 0.45), transparent 68%);
            }

            body::after {
              bottom: -32%;
              left: -16%;
              background: radial-gradient(circle, rgba(50, 173, 230, 0.42), transparent 68%);
              animation-direction: alternate-reverse;
            }

            main {
              position: relative;
              z-index: 1;
              width: min(100%, 780px);
              min-height: min(54vh, 420px);
              display: flex;
              flex-direction: column;
              justify-content: center;
              padding: clamp(28px, 7vw, 68px);
            }

            .eyebrow {
              margin: 0 0 20px;
              color: var(--muted);
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              font-size: 11px;
              font-weight: 700;
              letter-spacing: 0.18em;
              text-transform: uppercase;
            }

            #pun {
              max-width: 18ch;
              min-height: 3.1em;
              margin: 0;
              font-size: clamp(32px, 6.4vw, 72px);
              font-weight: 500;
              line-height: 1.02;
              letter-spacing: -0.035em;
              text-wrap: balance;
              transition: opacity 320ms ease, transform 320ms ease;
            }

            #pun.changing {
              opacity: 0;
              transform: translateY(8px);
            }

            .prompt {
              margin: 28px 0 0;
              color: var(--muted);
              font-family: -apple-system, BlinkMacSystemFont, sans-serif;
              font-size: clamp(13px, 2vw, 17px);
              line-height: 1.45;
            }

            @keyframes drift {
              from { transform: translate3d(-3%, -2%, 0) scale(0.94); }
              to { transform: translate3d(6%, 7%, 0) scale(1.08); }
            }

            @media (prefers-color-scheme: dark) {
              :root {
                --ink: rgba(255, 255, 255, 0.92);
                --muted: rgba(235, 230, 247, 0.62);
                --base: #111016;
              }
            }

            @media (max-height: 520px) {
              body { padding: 18px 28px; }
              main { min-height: 0; padding: 26px 34px; }
              .eyebrow { margin-bottom: 12px; }
              #pun { min-height: 2.2em; font-size: clamp(28px, 5.2vw, 52px); }
              .prompt { margin-top: 16px; }
            }

            @media (prefers-reduced-motion: reduce) {
              body::before, body::after { animation: none; }
              #pun { transition: none; }
            }
          </style>
        </head>
        <body>
          <main>
            <p class="eyebrow">\(eyebrow)</p>
            <h1 id="pun"></h1>
            <p class="prompt">\(prompt)</p>
          </main>
          <script>
            const puns = \(punsJSON);
            const label = document.getElementById('pun');
            let index = Math.floor(Math.random() * puns.length);

            function showPun(animated) {
              if (!puns.length) return;
              if (animated) label.classList.add('changing');
              window.setTimeout(() => {
                label.textContent = puns[index];
                label.classList.remove('changing');
                index = (index + 1) % puns.length;
              }, animated ? 320 : 0);
            }

            showPun(false);
            window.setInterval(() => showPun(true), 6500);
          </script>
        </body>
        </html>
        """
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@MainActor
final class BrowserStore: ObservableObject {
    @Published private(set) var activeProjectID: String?

    private var connectionID: UUID?
    private var directory: String?
    private var sessions: [BrowserContext: BrowserSession] = [:]
    // Deliberate privacy change: cookies are shared within a connection, never across reconnects.
    private var websiteDataStore: WKWebsiteDataStore?
    private var activeSessionObservation: AnyCancellable?

    init(projectID: String? = nil) {
        activeProjectID = projectID
    }

    var presentation: BrowserPresentation {
        activeSession?.presentation ?? .closed
    }

    var addressText: String {
        get { activeSession?.addressText ?? "" }
        set { activeSession(createIfNeeded: true)?.addressText = newValue }
    }

    var pageTitle: String {
        activeSession?.pageTitle ?? String(localized: "Browser")
    }

    var currentURL: URL? {
        activeSession?.currentURL
    }

    var isLoading: Bool {
        activeSession?.isLoading ?? false
    }

    var canGoBack: Bool {
        activeSession?.canGoBack ?? false
    }

    var canGoForward: Bool {
        activeSession?.canGoForward ?? false
    }

    var errorMessage: String? {
        activeSession?.errorMessage
    }

    var addressFocusRequest: Int {
        activeSession?.addressFocusRequest ?? 0
    }

    var webView: WKWebView {
        guard let session = activeSession(createIfNeeded: true) else {
            preconditionFailure("A project must be active before presenting the browser")
        }
        return session.webView
    }

    var isActive: Bool {
        presentation != .closed
    }

    var displayTitle: String {
        activeSession?.displayTitle ?? String(localized: "Browser")
    }

    var displayURL: String {
        activeSession?.displayURL ?? String(localized: "Search or enter a website")
    }

    var faviconURL: URL? {
        activeSession?.faviconURL
    }

    var userInstruction: String? {
        activeSession?.userInstruction
    }

    var automationStatus: String? {
        activeSession?.automationStatus
    }

    func selectProject(_ projectID: String?) {
        selectContext(connectionID: connectionID, projectID: projectID, directory: nil)
    }

    func selectContext(connectionID: UUID?, projectID: String?, directory: String?) {
        if self.connectionID != connectionID {
            clearAllBrowserSessions()
        }
        guard self.connectionID != connectionID || projectID != activeProjectID || self.directory != directory else { return }
        if activeSession?.presentation == .expanded {
            activeSession?.collapse()
        }

        activeSessionObservation = nil
        self.connectionID = connectionID
        self.directory = directory
        activeProjectID = projectID
        bindActiveSession(activeSession)
    }

    func clearAllBrowserSessions() {
        guard connectionID != nil || activeProjectID != nil || !sessions.isEmpty else { return }
        activeSessionObservation = nil
        for session in sessions.values {
            session.invalidate()
        }
        sessions.removeAll()
        websiteDataStore = nil
        connectionID = nil
        directory = nil
        activeProjectID = nil
    }

    func openAddressBar() {
        activeSession(createIfNeeded: true)?.openAddressBar()
    }

    func consumeAddressFocusRequest() -> Bool {
        activeSession?.consumeAddressFocusRequest() ?? false
    }

    func expand() {
        activeSession?.expand()
    }

    func collapse() {
        activeSession?.collapse()
    }

    func close() {
        activeSession?.close()
    }

    func submitAddress() {
        activeSession?.submitAddress()
    }

    func goBack() {
        activeSession?.goBack()
    }

    func goForward() {
        activeSession?.goForward()
    }

    func reloadOrStop() {
        activeSession?.reloadOrStop()
    }

    func dismissUserInstruction() {
        activeSession?.dismissUserInstruction()
    }

    func clearAutomationInstruction() throws -> BrowserAutomationPageState {
        guard let session = activeSession else {
            throw BrowserAutomationError.noPage
        }
        session.dismissUserInstruction()
        return session.currentAutomationPageState()
    }

    func presentForAutomation(instruction: String) throws -> BrowserAutomationPageState {
        guard let session = activeSession(createIfNeeded: true) else {
            throw BrowserAutomationError.noActiveProject
        }
        return session.presentForAutomation(instruction: instruction)
    }

    func beginAutomationActivity(_ status: String) throws -> BrowserAutomationActivityToken {
        guard let context = activeContext,
              let session = activeSession(createIfNeeded: true) else {
            throw BrowserAutomationError.noActiveProject
        }
        let id = session.beginAutomationActivity(status)
        return BrowserAutomationActivityToken(context: context, id: id)
    }

    func endAutomationActivity(_ token: BrowserAutomationActivityToken) {
        sessions[token.context]?.endAutomationActivity(token.id)
    }

    func automationNavigate(to address: String) async throws -> BrowserAutomationPageState {
        guard let session = activeSession(createIfNeeded: true) else {
            throw BrowserAutomationError.noActiveProject
        }
        return try await session.automationNavigate(to: address)
    }

    func automationSnapshot() async throws -> BrowserAutomationSnapshot {
        guard let session = activeSession else {
            throw BrowserAutomationError.noPage
        }
        return try await session.automationSnapshot()
    }

    func automationClick(ref: String) async throws -> BrowserAutomationPageState {
        guard let session = activeSession else {
            throw BrowserAutomationError.noPage
        }
        return try await session.automationClick(ref: ref)
    }

    func automationType(
        ref: String,
        text: String,
        clear: Bool,
        submit: Bool
    ) async throws -> BrowserAutomationPageState {
        guard let session = activeSession else {
            throw BrowserAutomationError.noPage
        }
        return try await session.automationType(ref: ref, text: text, clear: clear, submit: submit)
    }

    func automationHistory(action: String) async throws -> BrowserAutomationPageState {
        guard let session = activeSession else {
            throw BrowserAutomationError.noPage
        }
        return try await session.automationHistory(action: action)
    }

    private var activeContext: BrowserContext? {
        guard let activeProjectID else { return nil }
        return BrowserContext(connectionID: connectionID, projectID: activeProjectID, directory: directory)
    }

    private var activeSession: BrowserSession? {
        guard let activeContext else { return nil }
        return sessions[activeContext]
    }

    private func activeSession(createIfNeeded: Bool) -> BrowserSession? {
        guard let activeContext else { return nil }
        if let session = sessions[activeContext] {
            if activeSessionObservation == nil {
                bindActiveSession(session)
            }
            return session
        }
        guard createIfNeeded else { return nil }

        let dataStore = websiteDataStore ?? WKWebsiteDataStore.nonPersistent()
        websiteDataStore = dataStore
        let session = BrowserSession(websiteDataStore: dataStore)
        sessions[activeContext] = session
        bindActiveSession(session)
        objectWillChange.send()
        return session
    }

    private func bindActiveSession(_ session: BrowserSession?) {
        activeSessionObservation = session?.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

@MainActor
private final class BrowserSession: NSObject, ObservableObject {
    @Published private(set) var presentation: BrowserPresentation = .closed
    @Published var addressText = ""
    @Published private(set) var pageTitle = "Browser"
    @Published private(set) var currentURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var addressFocusRequest = 0
    @Published private(set) var userInstruction: String?
    @Published private(set) var automationStatus: String?
    private var consumedAddressFocusRequest = 0
    private var automationActivities: [(id: UUID, status: String)] = []
    private var isInvalidated = false
    private var titleObservation: AnyCancellable?

    let webView: WKWebView

    init(websiteDataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        // WebKit can publish the title after didFinish, or change it without navigating.
        titleObservation = webView.publisher(for: \.title)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isInvalidated else { return }
                self.synchronizePageTitle()
            }

        #if canImport(UIKit)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #endif

        webView.loadHTMLString(BrowserWelcomeDocument.html, baseURL: nil)
    }

    private var isActive: Bool {
        presentation != .closed
    }

    var displayTitle: String {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "Browser" {
            return trimmed
        }
        return currentURL?.host ?? String(localized: "Browser")
    }

    var displayURL: String {
        currentURL?.absoluteString ?? String(localized: "Search or enter a website")
    }

    var faviconURL: URL? {
        guard let currentURL,
              currentURL.scheme == "http" || currentURL.scheme == "https",
              currentURL.host != nil,
              var components = URLComponents(url: currentURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func openAddressBar() {
        presentation = .expanded
        addressFocusRequest += 1
    }

    func consumeAddressFocusRequest() -> Bool {
        guard addressFocusRequest > consumedAddressFocusRequest else { return false }
        consumedAddressFocusRequest = addressFocusRequest
        return true
    }

    func expand() {
        guard isActive else { return }
        presentation = .expanded
    }

    func collapse() {
        guard isActive else { return }
        presentation = .collapsed
    }

    func close() {
        webView.stopLoading()
        isLoading = false
        presentation = .closed
        userInstruction = nil
    }

    func invalidate() {
        isInvalidated = true
        titleObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        close()
        automationActivities.removeAll()
        automationStatus = nil
    }

    func submitAddress() {
        guard let url = BrowserAddressResolver.resolve(addressText) else { return }
        addressText = url.absoluteString
        errorMessage = nil
        presentation = .expanded
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reloadOrStop() {
        if webView.isLoading {
            webView.stopLoading()
            isLoading = false
        } else if webView.url != nil {
            webView.reload()
        } else {
            submitAddress()
        }
    }

    func dismissUserInstruction() {
        userInstruction = nil
    }

    func presentForAutomation(instruction: String) -> BrowserAutomationPageState {
        userInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        presentation = .expanded
        return automationPageState()
    }

    func beginAutomationActivity(_ status: String) -> UUID {
        let id = UUID()
        if presentation == .closed {
            presentation = .collapsed
        }
        automationActivities.append((id, status))
        automationStatus = status
        return id
    }

    func endAutomationActivity(_ id: UUID) {
        guard automationActivities.contains(where: { $0.id == id }) else { return }
        automationActivities.removeAll { $0.id == id }
        automationStatus = automationActivities.last?.status
    }

    func automationNavigate(to address: String) async throws -> BrowserAutomationPageState {
        guard let url = BrowserAddressResolver.resolve(address) else {
            throw BrowserAutomationError.invalidAddress
        }
        addressText = url.absoluteString
        errorMessage = nil
        webView.load(URLRequest(url: url))
        try await waitForNavigation()
        synchronizeMetadata()
        return automationPageState()
    }

    func automationSnapshot() async throws -> BrowserAutomationSnapshot {
        guard webView.url != nil else { throw BrowserAutomationError.noPage }
        if webView.isLoading {
            try await waitForNavigation()
        }
        let json = try await evaluateJavaScript(Self.snapshotScript)
        guard let data = json.data(using: .utf8) else {
            throw BrowserAutomationError.noPage
        }
        struct DocumentSnapshot: Decodable {
            let elements: [BrowserAutomationSnapshot.Element]
            let visibleText: String
        }
        let document = try JSONDecoder().decode(DocumentSnapshot.self, from: data)
        synchronizeMetadata()
        return BrowserAutomationSnapshot(
            page: automationPageState(),
            elements: document.elements,
            visibleText: document.visibleText
        )
    }

    func automationClick(ref: String) async throws -> BrowserAutomationPageState {
        guard webView.url != nil else { throw BrowserAutomationError.noPage }
        let reference = try Self.javaScriptLiteral(ref)
        let script = """
        (() => {
          const registry = window.__openclientBrowserAutomation;
          const element = registry?.byRef?.get(\(reference));
          if (!element || !element.isConnected) throw new Error('STALE_REF');
          if (element.disabled || element.getAttribute('aria-disabled') === 'true') throw new Error('DISABLED');
          element.scrollIntoView({ block: 'center', inline: 'center' });
          element.focus({ preventScroll: true });
          element.click();
          return JSON.stringify({ ok: true });
        })()
        """
        do {
            _ = try await evaluateJavaScript(script)
        } catch {
            throw BrowserAutomationError.invalidElementReference
        }
        try await settleAfterInteraction()
        return automationPageState()
    }

    func automationType(
        ref: String,
        text: String,
        clear: Bool,
        submit: Bool
    ) async throws -> BrowserAutomationPageState {
        guard webView.url != nil else { throw BrowserAutomationError.noPage }
        let reference = try Self.javaScriptLiteral(ref)
        let text = try Self.javaScriptLiteral(text)
        let script = """
        (() => {
          const registry = window.__openclientBrowserAutomation;
          const element = registry?.byRef?.get(\(reference));
          if (!element || !element.isConnected) throw new Error('STALE_REF');
          if (element.disabled || element.getAttribute('aria-disabled') === 'true') throw new Error('DISABLED');
          const editable = element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement || element.isContentEditable;
          if (!editable) throw new Error('NOT_EDITABLE');
          element.scrollIntoView({ block: 'center', inline: 'center' });
          element.focus({ preventScroll: true });
          if (element.isContentEditable) {
            element.textContent = \(clear ? text : "(element.textContent || '') + \(text)");
          } else {
            const nextValue = \(clear ? text : "element.value + \(text)");
            const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
            if (setter) setter.call(element, nextValue); else element.value = nextValue;
          }
          element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: \(text) }));
          element.dispatchEvent(new Event('change', { bubbles: true }));
          if (\(submit ? "true" : "false")) {
            element.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true }));
            element.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', bubbles: true }));
            element.form?.requestSubmit();
          }
          return JSON.stringify({ ok: true });
        })()
        """
        do {
            _ = try await evaluateJavaScript(script)
        } catch let error as BrowserAutomationError {
            throw error
        } catch {
            let message = error.localizedDescription
            if message.contains("NOT_EDITABLE") {
                throw BrowserAutomationError.unsupportedElement
            }
            throw BrowserAutomationError.invalidElementReference
        }
        try await settleAfterInteraction()
        return automationPageState()
    }

    func automationHistory(action: String) async throws -> BrowserAutomationPageState {
        guard webView.url != nil else { throw BrowserAutomationError.noPage }
        switch action {
        case "back":
            if webView.canGoBack { webView.goBack() }
        case "forward":
            if webView.canGoForward { webView.goForward() }
        case "reload":
            webView.reload()
        default:
            throw BrowserAutomationError.invalidHistoryAction
        }
        try await settleAfterInteraction()
        return automationPageState()
    }

    private func automationPageState() -> BrowserAutomationPageState {
        synchronizeMetadata()
        return BrowserAutomationPageState(
            title: displayTitle,
            url: currentURL?.absoluteString ?? "",
            isLoading: isLoading,
            canGoBack: canGoBack,
            canGoForward: canGoForward
        )
    }

    func currentAutomationPageState() -> BrowserAutomationPageState {
        automationPageState()
    }

    private func waitForNavigation(timeout: Duration = .seconds(15)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while webView.isLoading {
            guard !isInvalidated else { throw CancellationError() }
            guard clock.now < deadline else { throw BrowserAutomationError.navigationTimedOut }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
        }
        guard !isInvalidated else { throw CancellationError() }
        if let errorMessage, !errorMessage.isEmpty {
            throw NSError(domain: "OpenClientBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
    }

    private func settleAfterInteraction() async throws {
        try await Task.sleep(for: .milliseconds(150))
        guard !isInvalidated else { throw CancellationError() }
        if webView.isLoading {
            try await waitForNavigation()
        }
        synchronizeMetadata()
    }

    private func evaluateJavaScript(_ script: String) async throws -> String {
        guard !isInvalidated else { throw CancellationError() }
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result = result as? String {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: BrowserAutomationError.noPage)
                }
            }
        }
        guard !isInvalidated else { throw CancellationError() }
        return result
    }

    private static func javaScriptLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let literal = String(data: data, encoding: .utf8) else {
            throw BrowserAutomationError.invalidElementReference
        }
        return literal
    }

    private static let snapshotScript = """
    (() => {
      const state = window.__openclientBrowserAutomation || {
        nextRef: 1,
        refs: new WeakMap(),
        byRef: new Map()
      };
      window.__openclientBrowserAutomation = state;
      const visible = (element) => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.visibility !== 'hidden' && style.display !== 'none' && rect.width > 0 && rect.height > 0;
      };
      const refFor = (element) => {
        let ref = state.refs.get(element);
        if (!ref) {
          ref = `e${state.nextRef++}`;
          state.refs.set(element, ref);
          state.byRef.set(ref, element);
        }
        return ref;
      };
      const roleFor = (element) => element.getAttribute('role') || ({
        A: 'link', BUTTON: 'button', INPUT: element.type === 'checkbox' ? 'checkbox' : 'textbox',
        TEXTAREA: 'textbox', SELECT: 'combobox', SUMMARY: 'button'
      }[element.tagName] || element.tagName.toLowerCase());
      const nameFor = (element) => {
        const labelledBy = element.getAttribute('aria-labelledby');
        const labelledText = labelledBy ? labelledBy.split(/\\s+/).map((id) => document.getElementById(id)?.innerText || '').join(' ') : '';
        return (element.getAttribute('aria-label') || labelledText || element.getAttribute('alt') ||
          element.getAttribute('placeholder') || element.innerText || element.value || element.getAttribute('title') || '')
          .replace(/\\s+/g, ' ').trim().slice(0, 240);
      };
      const selector = [
        'a[href]', 'button', 'input:not([type="hidden"])', 'textarea', 'select', 'summary',
        '[contenteditable="true"]', '[role="button"]', '[role="link"]', '[role="textbox"]',
        '[role="checkbox"]', '[role="radio"]', '[role="combobox"]', '[role="menuitem"]', '[tabindex]'
      ].join(',');
      const elements = Array.from(document.querySelectorAll(selector)).filter(visible).slice(0, 200).map((element) => ({
        ref: refFor(element),
        role: roleFor(element),
        name: nameFor(element),
        value: ('value' in element && typeof element.value === 'string') ? element.value.slice(0, 500) : null,
        disabled: Boolean(element.disabled || element.getAttribute('aria-disabled') === 'true')
      }));
      const visibleText = (document.body?.innerText || '').replace(/\\n{3,}/g, '\\n\\n').trim().slice(0, 8000);
      return JSON.stringify({ elements, visibleText });
    })()
    """

    private func synchronizePageTitle() {
        let title = webView.url?.scheme == "about"
            ? String(localized: "Browser")
            : webView.title ?? webView.url?.host ?? String(localized: "Browser")
        if pageTitle != title {
            pageTitle = title
        }
    }

    private func synchronizeMetadata() {
        let loadedURL = webView.url
        let isWelcomeDocument = loadedURL?.scheme == "about"
        currentURL = isWelcomeDocument ? nil : loadedURL
        synchronizePageTitle()
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading

        if let currentURL, currentURL.scheme != "about" {
            addressText = currentURL.absoluteString
        }
    }

    private func handleNavigationFailure(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            synchronizeMetadata()
            return
        }

        synchronizeMetadata()
        isLoading = false
        errorMessage = error.localizedDescription
    }
}

extension BrowserSession: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        errorMessage = nil
        isLoading = true
        synchronizeMetadata()
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?) {
        synchronizeMetadata()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        synchronizeMetadata()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        synchronizeMetadata()
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        synchronizeMetadata()
        isLoading = false
        errorMessage = String(localized: "The webpage stopped responding. Reload it to continue.")
    }
}

extension BrowserSession: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}
