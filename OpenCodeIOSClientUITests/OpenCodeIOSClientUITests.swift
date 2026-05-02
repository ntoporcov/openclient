import XCTest

final class OpenCodeIOSClientUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private var baseURL: URL {
        URL(string: environment["SNAPSHOT_OPENCODE_BASE_URL"] ?? environment["OPENCODE_UI_TEST_BASE_URL"] ?? "http://127.0.0.1:4096")!
    }

    private var username: String {
        environment["SNAPSHOT_OPENCODE_USERNAME"] ?? environment["OPENCODE_UI_TEST_USERNAME"] ?? "opencode"
    }

    private var password: String {
        environment["SNAPSHOT_OPENCODE_PASSWORD"] ?? environment["OPENCODE_UI_TEST_PASSWORD"] ?? ""
    }

    private var projectDirectory: String {
        environment["SNAPSHOT_OPENCODE_DIRECTORY"] ?? environment["OPENCODE_UI_TEST_DIRECTORY"] ?? "/tmp/opencode-ios-client"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppStoreScreenshots() {
        if isRunningOniPadSimulator {
            XCUIDevice.shared.orientation = .landscapeLeft
        }

        let scenes: [(scene: String, screenshotName: String)] = [
            ("connection", "01-connection"),
            ("recent-servers", "02-recent-servers"),
            ("projects", "03-projects"),
            ("sessions", "04-sessions"),
            ("chat", "05-chat"),
            ("permission", "06-permission"),
            ("question", "07-question"),
            ("fun-games", "08-fun-games"),
            ("find-place-game", "09-find-place-game"),
            ("find-bug-game", "10-find-bug-game"),
            ("composer-actions", "11-composer-actions"),
            ("paywall", "12-paywall"),
            ("recent-widget", "13-recent-widget"),
            ("pinned-widget", "14-pinned-widget"),
            ("live-activity", "15-live-activity"),
            ("session-actions", "16-session-actions"),
            ("session-pinned", "17-session-pinned"),
        ]

        for (scene, screenshotName) in scenes {
            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = scene
            app.launch()

            let sceneMarker = app.staticTexts["screenshot.scene.\(scene)"]
            XCTAssertTrue(sceneMarker.waitForExistence(timeout: 10), "Expected screenshot scene \(scene) to load")

            if scene == "composer-actions" {
                let composerMenu = app.buttons["chat.composer.menu"]
                XCTAssertTrue(composerMenu.waitForExistence(timeout: 10), "Expected composer menu button to load")
                composerMenu.tap()
                XCTAssertTrue(app.navigationBars["Message Tools"].waitForExistence(timeout: 10), "Expected composer actions sheet to load")
            }

            snapshot(screenshotName)
            app.terminate()
        }
    }

    private var isRunningOniPadSimulator: Bool {
        let deviceName = environment["SIMULATOR_DEVICE_NAME"] ?? ""
        return deviceName.localizedCaseInsensitiveContains("iPad")
    }

    @MainActor
    func testCreateSessionAndSendMessageAgainstLocalBackend() {
        let app = XCUIApplication()
        let sessionTitle = "UI Test \(UUID().uuidString.prefix(8))"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        app.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: ui test ok"
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10))
        sessionCell.tap()

        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "ui test ok")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
    }

    @MainActor
    func testSecondMessageRendersSecondAssistantReplyAgainstLocalBackend() async throws {
        let app = XCUIApplication()
        let sessionTitle = "UI Followup \(UUID().uuidString.prefix(8))"
        let firstReply = "uireplyone\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondReply = "uireplytwo\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"

        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        app.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: \(firstReply)"
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10))
        sessionCell.tap()

        XCTAssertTrue(waitForAssistantReply(firstReply, in: app, timeout: 90))

        try await sendPrompt("Reply with exactly: \(secondReply)", in: app)
        XCTAssertTrue(waitForAssistantReply(secondReply, in: app, timeout: 90))
    }

    @MainActor
    func testReconnectAndFollowupStillRendersAssistantReply() async throws {
        let sessionTitle = "UI Reconnect \(UUID().uuidString.prefix(8))"
        let firstReply = "uireconnectone\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondReply = "uireconnecttwo\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondPrompt = "Reply with exactly: \(secondReply)"

        let firstLaunch = XCUIApplication()
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: \(firstReply)"
        firstLaunch.launch()

        try await connectAndOpenSession(named: sessionTitle, in: firstLaunch)
        XCTAssertTrue(waitForAssistantReply(firstReply, in: firstLaunch, timeout: 90))
        let sessionID = try await waitForSessionID(named: sessionTitle)
        firstLaunch.terminate()

        let secondLaunch = XCUIApplication()
        secondLaunch.launch()

        try await reconnectIfNeeded(secondLaunch)
        try await openSessionIfVisible(named: sessionTitle, in: secondLaunch)
        try await sendPrompt(secondPrompt, in: secondLaunch)

        let rendered = waitForAssistantReply(secondReply, in: secondLaunch, timeout: 90)
        if !rendered {
            attachDebugLog(from: secondLaunch, named: "Reconnect Followup Debug Log")
            try await attachBackendMessages(for: sessionID, named: "Reconnect Selected Session Messages")
            try await attachPromptSearch(secondPrompt, named: "Reconnect Prompt Search")
        }
        XCTAssertTrue(rendered)
    }

    @MainActor
    func testManualSessionCreationAllowsSecondPromptInSameSession() async throws {
        let app = XCUIApplication()
        let sessionTitle = "UI Manual \(UUID().uuidString.prefix(8))"
        let firstPrompt = "uimanualfirst\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondPrompt = "uimanualsecond\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"

        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let createSessionButton = app.buttons["sessions.create"]
        XCTAssertTrue(createSessionButton.waitForExistence(timeout: 10))
        createSessionButton.tap()

        let titleField = app.textFields["sessions.create.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText(sessionTitle)

        let confirmCreateButton = app.buttons["sessions.create.confirm"]
        XCTAssertTrue(confirmCreateButton.waitForExistence(timeout: 10))
        confirmCreateButton.tap()

        let createdSessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        if createdSessionCell.waitForExistence(timeout: 10) {
            createdSessionCell.tap()
        }

        let sessionID = try await waitForSessionID(named: sessionTitle)
        try await sendPrompt(firstPrompt, in: app)
        let firstPersisted = try await waitForPromptPersistence(firstPrompt)
        XCTAssertEqual(
            firstPersisted.sessionID,
            sessionID,
            "First prompt persisted to unexpected session \(firstPersisted.sessionID), expected \(sessionID)"
        )

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 90))

        try await sendPrompt(secondPrompt, in: app)
        let secondPersisted = try await waitForPromptPersistence(secondPrompt)
        XCTAssertEqual(
            secondPersisted.sessionID,
            sessionID,
            "Second prompt persisted to unexpected session \(secondPersisted.sessionID), expected \(sessionID)"
        )
    }

    @MainActor
    private func sendPrompt(_ prompt: String, in app: XCUIApplication) async throws {
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(prompt)

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        sendButton.tap()
    }

    @MainActor
    private func waitForAssistantReply(_ reply: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", reply)).firstMatch
        return text.waitForExistence(timeout: timeout)
    }

    @MainActor
    private func connectAndOpenSession(named title: String, in app: XCUIApplication) async throws {
        let connectButton = app.buttons["connection.connect"]
        if connectButton.waitForExistence(timeout: 10) {
            connectButton.tap()
        } else {
            let reconnectButton = app.buttons["Reconnect"]
            XCTAssertTrue(reconnectButton.waitForExistence(timeout: 10))
            reconnectButton.tap()
        }

        let projectCell = app.staticTexts["opencode-ios-client"]
        if projectCell.waitForExistence(timeout: 10) {
            projectCell.tap()
        }

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 20))
        sessionCell.tap()
    }

    @MainActor
    private func reconnectIfNeeded(_ app: XCUIApplication) async throws {
        let reconnectButton = app.buttons["Reconnect"]
        if reconnectButton.waitForExistence(timeout: 10) {
            reconnectButton.tap()
            return
        }

        let connectButton = app.buttons["connection.connect"]
        if connectButton.waitForExistence(timeout: 10) {
            connectButton.tap()
        }
    }

    @MainActor
    private func openSessionIfVisible(named title: String, in app: XCUIApplication) async throws {
        let projectCell = app.staticTexts["opencode-ios-client"]
        if projectCell.waitForExistence(timeout: 10) {
            projectCell.tap()
        }

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 20))
        sessionCell.tap()
    }

    @MainActor
    private func attachDebugLog(from app: XCUIApplication, named name: String) {
        let bugButton = app.buttons["chat.debugProbe"]
        guard bugButton.waitForExistence(timeout: 5) else { return }
        bugButton.tap()

        let logView = app.staticTexts["debugProbe.log"]
        guard logView.waitForExistence(timeout: 5) else { return }

        let attachment = XCTAttachment(string: logView.label)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachBackendMessages(for sessionID: String, named name: String) async throws {
        let messages = try await fetchMessages(sessionID: sessionID)
        let body = messages.map { envelope in
            let role = envelope.info.role ?? "?"
            let text = envelope.parts.compactMap(\.text).joined(separator: " | ")
            return "\(role)\t\(text)"
        }.joined(separator: "\n")

        let attachment = XCTAttachment(string: body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachPromptSearch(_ prompt: String, named name: String) async throws {
        let sessions = try await fetchSessions()
        var lines: [String] = []

        for session in sessions {
            let messages = try await fetchMessages(sessionID: session.id)
            let matching = messages.filter { envelope in
                envelope.parts.compactMap(\.text).joined(separator: "\n").contains(prompt)
            }
            guard !matching.isEmpty else { continue }

            lines.append("session=\(session.id) title=\(session.title ?? "")")
            lines.append(contentsOf: matching.map { envelope in
                let role = envelope.info.role ?? "?"
                let text = envelope.parts.compactMap(\.text).joined(separator: " | ")
                return "\(role)\t\(text)"
            })
        }

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForSessionID(named title: String) async throws -> String {
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let sessions = try await fetchSessions()
            if let sessionID = sessions.first(where: { $0.title == title })?.id {
                return sessionID
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTFail("Timed out waiting for session \(title)")
        return ""
    }

    @MainActor
    private func waitForPromptPersistence(_ prompt: String) async throws -> PromptLocation {
        let deadline = Date().addingTimeInterval(45)

        while Date() < deadline {
            let sessions = try await fetchSessions()
            for session in sessions {
                let messages = try await fetchMessages(sessionID: session.id)
                if messages.contains(where: { $0.isUserPrompt(prompt) }) {
                    return PromptLocation(sessionID: session.id)
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTFail("Timed out waiting for prompt persistence: \(prompt)")
        return PromptLocation(sessionID: "")
    }

    @MainActor
    private func fetchSessions() async throws -> [UITestSession] {
        var components = URLComponents(url: baseURL.appendingPathComponent("session"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "directory", value: projectDirectory)]
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url: try XCTUnwrap(components?.url)))
        try assertHTTP(response, data: data)
        return try JSONDecoder().decode([UITestSession].self, from: data)
    }

    @MainActor
    private func fetchMessages(sessionID: String) async throws -> [UITestMessageEnvelope] {
        let url = baseURL.appendingPathComponent("session").appendingPathComponent(sessionID).appendingPathComponent("message")
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url: url))
        try assertHTTP(response, data: data)
        return try JSONDecoder().decode([UITestMessageEnvelope].self, from: data)
    }

    @MainActor
    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor
    private func assertHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            XCTFail("Missing HTTP response")
            return
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            XCTFail("Unexpected status \(http.statusCode): \(body)")
            return
        }
    }
}

private struct UITestSession: Decodable {
    let id: String
    let title: String?
}

private struct UITestMessageEnvelope: Decodable {
    struct Info: Decodable {
        let role: String?
    }

    struct Part: Decodable {
        let text: String?
    }

    let info: Info
    let parts: [Part]

    func isUserPrompt(_ prompt: String) -> Bool {
        guard (info.role ?? "").lowercased() == "user" else { return false }
        let text = parts.compactMap(\.text).joined(separator: "\n")
        return text.contains(prompt)
    }
}

private struct PromptLocation {
    let sessionID: String
}
