import XCTest

/// Read-only live verification. Before running, launch the installed app with
/// OPENCLIENT_DSH_URL via simctl's process environment on each destination.
/// Attaching to that process keeps the credential out of XCTest launch logs.
@MainActor
final class DSHPrototypeUITests: XCTestCase {
#if DSH_CLIENT
    func testConnectionEditorCardsAndSeparateAuthenticationFields() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        app.launch()
        let disconnect = app.buttons["projects.disconnect"]
        let url = app.textFields["dsh.serverURL"]
        let add = app.buttons["dsh.addConnection"]
        try wait(app, "Connection editor or connected app is ready") { url.exists || disconnect.isHittable || add.exists }
        if !url.exists && !add.exists { disconnect.tap() }
        if add.waitForExistence(timeout: 2) {
            XCTAssertFalse(url.exists, "Saved connections must not show the editor")
            capture(app, "dsh-saved-connections")
            add.tap()
        }
        try wait(app, "Connection editor is visible") { url.exists }
        let form = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        capture(app, "dsh-add-connection")
        let desktopIcon = app.buttons["connection.icon.desktopcomputer"]
        desktopIcon.tap()
        XCTAssertTrue(desktopIcon.isSelected)
        XCTAssertFalse(app.buttons["connection.icon.server.rack"].isSelected)
        capture(app, "dsh-icon-desktop-selected")
        let tokenCard = app.buttons["dsh.loginMethod.token"]
        if !tokenCard.isHittable { app.swipeUp() }
        tokenCard.tap()
        XCTAssertTrue(tokenCard.isSelected)
        if !app.secureTextFields["dsh.token"].exists { form.swipeUp() }
        XCTAssertTrue(app.secureTextFields["dsh.token"].exists)
        XCTAssertFalse(app.textFields["dsh.username"].exists)
        capture(app, "dsh-connection-token-cards")
        let passwordCard = app.buttons["dsh.loginMethod.password"]
        app.scrollViews["dsh.loginMethod"].swipeLeft()
        passwordCard.tap()
        XCTAssertTrue(passwordCard.isSelected)
        if !app.secureTextFields["dsh.password"].exists { form.swipeUp() }
        XCTAssertTrue(app.textFields["dsh.username"].exists)
        XCTAssertTrue(app.secureTextFields["dsh.password"].exists)
        XCTAssertFalse(app.secureTextFields["dsh.token"].exists)
        capture(app, "dsh-connection-password-cards")
        form.swipeDown()
        let name = app.textFields["dsh.name"]
        name.tap()
        name.typeText("Test Mac")
        url.tap()
        url.typeText("https://example.invalid/?token=ui-test-token")
        name.tap()
        XCTAssertEqual(url.value as? String, "https://example.invalid/")
    }

    /// Read-only profile inventory verification. Never applies an MCP setting.
    func testManagedMCPFromChatHeaderReadOnly() throws {
        continueAfterFailure = false
        let app = try launchForManagedMCP()
        let header = app.buttons["chat.header"]
        if !header.isHittable {
            let activity = app.buttons["projects.activity"]
            XCTAssertTrue(activity.isHittable)
            capture(app, "dsh-mcp-chat-before-activity")
            activity.tap()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.session."))
            let preferred = rows.matching(NSPredicate(format: "label CONTAINS %@", "OpenClient native DSH smoke test")).firstMatch
            try wait(app, "An existing session is available for read-only MCP inspection") { rows.firstMatch.isHittable }
            capture(app, "dsh-mcp-chat-activity")
            let row = preferred.isHittable ? preferred : rows.firstMatch
            row.tap()
            try wait(app, "Existing chat header is available") { header.isHittable }
            capture(app, "dsh-mcp-chat-open")
        }
        capture(app, "dsh-mcp-chat-before-header")
        header.tap()
        let mcp = app.tabBars.buttons["MCP"].firstMatch
        try wait(app, "Chat header exposes the MCP tab") { mcp.isHittable }
        capture(app, "dsh-mcp-chat-header")
        mcp.tap()
        try verifyManagedMCPInventory(app, surface: "chat", inspectCancellation: true)
    }

    func testManagedMCPFromProjectReadOnly() throws {
        continueAfterFailure = false
        let app = try launchForManagedMCP()
        let workspace = app.staticTexts["default-workspace"].firstMatch
        try wait(app, "Existing default workspace is available") { workspace.isHittable }
        capture(app, "dsh-mcp-project-before-workspace")
        workspace.tap()
        let mcp = app.tabBars.buttons["MCP"].firstMatch
        try wait(app, "Project exposes its MCP tab") { mcp.isHittable }
        capture(app, "dsh-mcp-project-tabs")
        mcp.tap()
        try verifyManagedMCPInventory(app, surface: "project", inspectCancellation: false)
    }

    private func launchForManagedMCP() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        app.launch()
        capture(app, "dsh-mcp-initial")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["projects.activity"].isHittable || app.buttons["chat.header"].isHittable
                || app.staticTexts["default-workspace"].firstMatch.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 30) == .completed else {
            capture(app, "dsh-mcp-connection-not-ready")
            if app.textFields["dsh.serverURL"].exists || app.buttons["dsh.addConnection"].exists
                || app.buttons["dsh.connect"].exists || app.secureTextFields["dsh.password"].exists {
                throw XCTSkip("No saved authenticated DSH connection; credentials were not inspected or changed.")
            }
            throw NSError(domain: "DSHMCPUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Saved connection did not become ready"])
        }
        capture(app, "dsh-mcp-ready")
        return app
    }

    private func verifyManagedMCPInventory(_ app: XCUIApplication, surface: String, inspectCancellation: Bool) throws {
        let scope = app.descendants(matching: .any).matching(identifier: "mcp.managed.scope").firstMatch
        let empty = app.descendants(matching: .any).matching(identifier: "mcp.managed.empty").firstMatch
        let unavailable = app.descendants(matching: .any).matching(identifier: "mcp.managed.unavailable").firstMatch
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.managed.row."))
        // Project navigation owns its existing refresh toolbar; the chat panel
        // hosts the managed view's toolbar directly (verified in device hierarchy).
        let refresh = app.buttons[surface == "project" ? "mcp.refresh" : "mcp.managed.refresh"].firstMatch
        try wait(app, "Canonical MCP inventory loads, rather than only a pre-load unavailable placeholder") {
            scope.exists && (empty.exists || rows.firstMatch.exists) && !unavailable.exists && refresh.isEnabled
        }
        capture(app, "dsh-mcp-\(surface)-canonical")
        XCTAssertTrue(scope.label.contains("all projects, chats, and users"), "Management scope must clearly include every project/chat/user")
        XCTAssertTrue(scope.label.contains("DSH server profile"))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcp.managed.list").firstMatch.exists)
        XCTAssertTrue(refresh.isHittable)
        refresh.tap()
        try wait(app, "Read-only refresh returns canonical MCP inventory") {
            (empty.exists || rows.firstMatch.exists) && !unavailable.exists && refresh.isEnabled
        }
        capture(app, "dsh-mcp-\(surface)-refreshed")
        if inspectCancellation {
            let switches = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.managed.toggle."))
            if let toggle = switches.allElementsBoundByIndex.first(where: { $0.isEnabled && $0.isHittable }) {
                let prior = toggle.value as? String
                capture(app, "dsh-mcp-before-confirmation")
                toggle.tap() // Opens confirmation only; the binding does not apply configuration.
                let cancel = app.buttons["mcp.managed.confirm.cancel"].firstMatch
                try wait(app, "Profile-wide change requires explicit confirmation") { cancel.isHittable }
                capture(app, "dsh-mcp-confirmation-not-applied")
                cancel.tap()
                try wait(app, "Cancellation dismisses the pending change") { !cancel.exists }
                XCTAssertEqual(toggle.value as? String, prior, "Cancel must retain the canonical setting")
                capture(app, "dsh-mcp-confirmation-cancelled")
            } else {
                let evidence = XCTAttachment(string: empty.exists
                    ? "Canonical inventory reports no profile MCP declarations; no live mutable toggle was tested."
                    : "Canonical inventory loaded, but no visible enabled mutable toggle was available; no configuration was changed.")
                evidence.name = "dsh-mcp-no-live-toggle"
                evidence.lifetime = .keepAlways
                add(evidence)
            }
        }
    }

    /// Uses only the user's normal saved connection and existing sessions.
    /// No credential reads, sign-out, session creation, prompts, or tool approvals.
    func testContextSheetDisplaysCanonicalMetadata() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = [:]
        app.launch()
        capture(app, "dsh-context-device-initial")

        let toolbarContext = app.buttons["chat.toolbar.context"]
        let contextUsage = app.buttons["chat.contextUsage"]
        let activity = app.buttons["projects.activity"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            toolbarContext.isHittable || contextUsage.isHittable || activity.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 30) == .completed else {
            capture(app, "dsh-context-device-unavailable")
            if app.textFields["dsh.serverURL"].exists || app.buttons["dsh.addConnection"].exists
                || app.buttons["dsh.connect"].exists || app.secureTextFields["dsh.password"].exists {
                throw XCTSkip("No saved authenticated DSH connection became ready; authentication was not altered.")
            }
            XCTFail("Saved connection did not expose Activity or an existing chat within 30 seconds")
            return
        }
        capture(app, "dsh-context-device-ready")

        if !toolbarContext.isHittable && !contextUsage.isHittable {
            activity.tap()
            let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.session."))
            let preferred = rows.matching(NSPredicate(format: "label CONTAINS %@", "OpenClient native DSH smoke test")).firstMatch
            guard rows.firstMatch.waitForExistence(timeout: 30) else {
                capture(app, "dsh-context-device-no-sessions")
                throw XCTSkip("Authenticated Activity contains no existing session to inspect; no session was created.")
            }
            capture(app, "dsh-context-device-activity")
            let row = preferred.exists && preferred.isHittable ? preferred : rows.firstMatch
            XCTAssertTrue(row.isHittable, "An existing activity row must be hittable without guessing coordinates")
            row.tap()
            try wait(app, "Existing chat exposes its context ring") {
                toolbarContext.isHittable || contextUsage.isHittable
            }
            capture(app, "dsh-context-device-chat")
        }

        let contextButton = toolbarContext.isHittable ? toolbarContext : contextUsage
        XCTAssertTrue(contextButton.isHittable)
        contextButton.tap()
        let summary = app.descendants(matching: .any).matching(identifier: "chat.metadata.contextSummary").firstMatch
        try wait(app, "Canonical server context summary is displayed") { summary.exists }
        capture(app, "dsh-context-device-summary")

        let used = app.descendants(matching: .any).matching(identifier: "chat.metadata.context.used").firstMatch
        let capacity = app.descendants(matching: .any).matching(identifier: "chat.metadata.context.capacity").firstMatch
        for attempt in 0..<2 where !used.exists || !capacity.exists {
            app.swipeUp()
            capture(app, "dsh-context-device-context-scroll-\(attempt)")
        }
        XCTAssertTrue(used.exists, "Canonical used-token metadata row is present")
        XCTAssertTrue(capacity.exists, "Canonical context-capacity metadata row is present")
        capture(app, "dsh-context-device-canonical-rows")

        // Bounded, read-only exploration of the remaining recorded metadata.
        for attempt in 0..<2 {
            app.swipeUp()
            capture(app, "dsh-context-device-metadata-scroll-\(attempt)")
        }
    }

    func testActivityShowsDSHSessions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        guard app.state != .notRunning else { throw XCTSkip("Prelaunch the DSH app with its test login") }
        app.activate()
        let activity = app.buttons["projects.activity"]
        try wait(app, "DSH exposes Activity") { activity.exists && activity.isHittable }
        activity.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "activity.session.", "OpenClient native DSH smoke test")).firstMatch
        try wait(app, "DSH sessions populate Activity") { row.exists }
        capture(app, "dsh-activity")
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
    }

    func testSavedLoginSurvivesRelaunchAndSignOutRemovesIt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        guard app.state != .notRunning else { throw XCTSkip("Prelaunch the DSH app with its test login") }
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        let workspace = app.staticTexts["default-workspace"].firstMatch
        try wait(app, "Saved login reconnects without a launch environment variable") { workspace.exists }
        let disconnect = app.buttons["projects.disconnect"]
        try wait(app, "Disconnect is available") { disconnect.exists && disconnect.isHittable }
        disconnect.tap()
        let saved = app.staticTexts["dsh.savedServer"]
        try wait(app, "Saved server is shown without its token") { saved.exists }
        XCTAssertFalse(saved.label.contains("token="))
        app.buttons["dsh.signOut"].tap()
        app.terminate()
        app.launch()
        let field = app.textFields["dsh.serverURL"]
        try wait(app, "Signed out after relaunch") { field.exists }
        XCTAssertFalse(app.staticTexts["dsh.savedServer"].exists)
        field.tap()
        field.typeText("https://invalid.example/")
        XCTAssertFalse(app.buttons["dsh.connect"].isEnabled, "Missing token cannot connect")
        capture(app, "dsh-signed-out-validation")
    }
#endif

    func testExistingSmokeHistoryInSharedNativeUI() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        guard app.state == .runningForeground || app.state == .runningBackground else {
            throw XCTSkip("Prelaunch the DSH prototype on this destination before running this read-only test")
        }
        app.activate()
        capture(app, "dsh-initial")

        let workspace = app.staticTexts["default-workspace"].firstMatch
        try wait(app, "DSH workspace is visible") { workspace.exists && workspace.isHittable }
        capture(app, "dsh-workspace")
        workspace.tap()

        let session = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "session.row.", "OpenClient native DSH smoke test"
        )).firstMatch
        try wait(app, "Existing smoke session is visible") { session.exists && session.isHittable }
        capture(app, "dsh-session-list")
        session.tap()

        let transcript = app.collectionViews["chat.scroll"]
        let request = transcript.staticTexts["Reply with exactly OK. Do not use tools."].firstMatch
        let answer = transcript.textViews.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND (value == %@ OR label == %@)",
            "chat.responseText.", "OK", "OK"
        )).firstMatch
        try wait(app, "Canonical user request and assistant OK are rendered") {
            transcript.exists && request.exists && answer.exists
        }
        XCTAssertTrue(request.isHittable, "User request must be visible")
        XCTAssertTrue(answer.isHittable, "Assistant response must be visible")
        capture(app, "dsh-existing-smoke-history")
    }

    private func wait(_ app: XCUIApplication, _ message: String, until condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in condition() }, object: nil
        )
        guard XCTWaiter.wait(for: [expectation], timeout: 30) == .completed else {
            capture(app, "dsh-failure")
            throw NSError(domain: "DSHPrototypeUI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
