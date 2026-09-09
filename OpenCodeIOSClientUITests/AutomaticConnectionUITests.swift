import XCTest

@MainActor
final class AutomaticConnectionUITests: XCTestCase {
    func testAutomaticV2NoticeDismissalSurvivesNavigationAndEventsButResetsOnReconnect() async throws {
        let (fixture, app) = try await context(legacy: false)
        let title = "Auto notice \(UUID().uuidString.prefix(8))"
        let created = try await fixture.request("/api/session", method: "POST", body: ["title": title, "location": ["directory": fixture.workspace.path]])
        let id = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        addTeardownBlock { @MainActor in _ = try? await fixture.request("/api/session/\(id)", method: "DELETE") }
        try await connect(app)
        let dismiss = app.buttons["connection.v2-notice.dismiss"]
        let report = app.descendants(matching: .any)["connection.v2-notice.report-bug"].firstMatch
        try await wait(app, "Automatic v2 notice after bootstrap") { dismiss.isHittable && report.isHittable }
        XCTAssertTrue(app.staticTexts["OpenCode v2 detected"].exists)
        capture(app, "automatic-v2-notice-after-bootstrap")

        // Navigate with the banner present: it is not a modal acknowledgment gate.
        try await openGlobal(app)
        XCTAssertTrue(app.buttons["sessions.create"].isHittable)
        XCTAssertTrue(dismiss.isHittable)
        XCTAssertTrue(report.isHittable)
        let notice = app.otherElements["connection.v2-notice"]
        let row = app.buttons["session.row.\(id)"]
        try await wait(app, "First session remains accessible below notice") { row.exists && row.isHittable }
        XCTAssertGreaterThanOrEqual(app.navigationBars["Global"].frame.minY, notice.frame.maxY - 1)
        XCTAssertGreaterThanOrEqual(row.frame.minY, notice.frame.maxY - 1)
        capture(app, "automatic-v2-notice-nonblocking-session-list")
        dismiss.tap()
        try await wait(app, "Notice dismissed") { !dismiss.exists }

        try await wait(app, "Bootstrap loaded the owned session") { row.exists }
        XCTAssertFalse(dismiss.exists)
        _ = try await fixture.request("/api/session/\(id)/rename", method: "POST", body: ["title": title + " renamed"])
        try await wait(app, "Real session-renamed SSE reaches list") { row.label.contains("renamed") }
        XCTAssertFalse(dismiss.exists)
        capture(app, "automatic-v2-dismissal-survives-real-events")
        try await home(app)
        XCTAssertFalse(dismiss.exists)
        try await openGlobal(app)
        XCTAssertFalse(dismiss.exists)
        try await home(app)

        app.buttons["projects.disconnect"].tap()
        let recent = app.collectionViews["connection.recent-servers"]
        try await wait(app, "Saved fixture connection after disconnect") { recent.exists }
        XCTAssertFalse(dismiss.exists)
        let saved = recent.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture.baseURL)).firstMatch
        try await wait(app, "Exact saved fixture is tappable") { saved.isHittable }
        saved.tap()
        try await wait(app, "New connection lifetime re-presents notice", timeout: 40) {
            dismiss.isHittable && report.isHittable && app.textFields["projects.searchChats"].exists
        }
        capture(app, "automatic-v2-notice-new-connection-lifetime")
    }

    func testAutomaticLegacyConnectionHasNoV2Notice() async throws {
        let (fixture, app) = try await context(legacy: true)
        let title = "Auto legacy \(UUID().uuidString.prefix(8))"
        let created = try await fixture.request("/api/session", method: "POST", body: ["title": title])
        let id = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        addTeardownBlock { @MainActor in _ = try? await fixture.request("/api/session/\(id)", method: "DELETE") }
        try await connect(app)
        XCTAssertFalse(app.buttons["connection.v2-notice.dismiss"].exists)
        capture(app, "automatic-legacy-connected-without-v2-notice")
        try await openGlobal(app)
        let row = app.buttons["session.row.\(id)"]
        try await wait(app, "Legacy bootstrap lists the actual owned session") { row.exists && row.isHittable }
        XCTAssertTrue(row.label.contains(title))
        XCTAssertFalse(app.buttons["connection.v2-notice.dismiss"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["connection.v2-notice.report-bug"].exists)
        capture(app, "automatic-legacy-real-session-list-no-notice")
    }

    func testAutomaticV2AuthenticationFailureDoesNotPresentNoticeOrLegacyWorkspace() async throws {
        let (fixture, app) = try await context(legacy: false, invalidPassword: true)
        let before = try await fixture.request("/api/session")
        let form = app.collectionViews["connection.form"]
        let connect = app.buttons["connection.connect"]
        try await revealConnect(app)
        connect.tap()
        let error = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '401'")).firstMatch
        try await wait(app, "Authentication failure remains a 401", timeout: 40) { error.exists }
        XCTAssertTrue(form.exists || app.buttons["connection.recovery.edit-server"].exists)
        XCTAssertFalse(app.buttons["connection.v2-notice.dismiss"].exists)
        XCTAssertFalse(app.buttons["sessions.create"].exists)
        XCTAssertFalse(app.staticTexts["Global"].exists)
        XCTAssertFalse(app.textViews["chat.input"].exists)
        let after = try await fixture.request("/api/session")
        XCTAssertEqual(NSArray(array: before["data"] as? [Any] ?? []), NSArray(array: after["data"] as? [Any] ?? []))
        capture(app, "automatic-v2-401-no-fallback-workspace-or-notice")
    }

    private func context(legacy: Bool, invalidPassword: Bool = false) async throws -> (DeletionFixture, XCUIApplication) {
        continueAfterFailure = false
        let fixture = try DeletionFixture.loadOwnedManifest(legacy: legacy)
        XCTAssertEqual(fixture.isLegacy, legacy)
        try await fixture.verify()
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "0",
            "OPENCODE_UI_TEST_BASE_URL": fixture.baseURL, "OPENCODE_UI_TEST_USERNAME": fixture.username,
            "OPENCODE_UI_TEST_PASSWORD": invalidPassword ? "invalid-\(UUID().uuidString)" : fixture.password,
            "OPENCODE_UI_TEST_SERVER_NAME": "Automatic fixture"
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        try await wait(app, "Stable automatic connection form") { app.collectionViews["connection.form"].exists }
        XCTAssertFalse(app.buttons["connection.apiPreference"].exists, "The public API picker was removed")
        XCTAssertFalse(app.buttons["connection.v2-notice.dismiss"].exists, "No banner before an established v2 connection")
        return (fixture, app)
    }

    private func revealConnect(_ app: XCUIApplication) async throws {
        let form = app.collectionViews["connection.form"]
        let connect = app.buttons["connection.connect"]
        for _ in 0..<6 {
            if connect.exists && connect.isHittable { break }
            form.swipeUp()
        }
        try await wait(app, "Automatic Connect button") { connect.exists && connect.isHittable && connect.isEnabled }
    }

    private func connect(_ app: XCUIApplication) async throws {
        try await revealConnect(app)
        app.buttons["connection.connect"].tap()
        try await wait(app, "Successful automatic bootstrap", timeout: 40) {
            !app.collectionViews["connection.form"].exists && app.staticTexts["Global"].firstMatch.isHittable
        }
    }

    private func openGlobal(_ app: XCUIApplication) async throws {
        let global = app.staticTexts["Global"].firstMatch
        for _ in 0..<2 {
            try await wait(app, "Global project entry") { global.isHittable }
            global.tap()
            if app.buttons["sessions.create"].waitForExistence(timeout: 3) { break }
        }
        try await wait(app, "Session list is usable") { app.buttons["sessions.create"].isHittable }
    }

    private func home(_ app: XCUIApplication) async throws {
        if app.buttons["projects.disconnect"].isHittable { return }
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else { app.navigationBars.buttons["BackButton"].firstMatch.tap() }
        try await wait(app, "Projects navigation") { app.buttons["projects.disconnect"].isHittable }
    }

    private func wait(_ app: XCUIApplication, _ message: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        capture(app, "automatic-connection-failure-\(message)")
        throw NSError(domain: "AutomaticConnectionUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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
