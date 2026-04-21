import XCTest

final class OpenCodeIOSClientUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateSessionAndSendMessageAgainstLocalBackend() {
        let app = XCUIApplication()
        let sessionTitle = "UI Test \(UUID().uuidString.prefix(8))"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = "http://127.0.0.1:4096"
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = "opencode"
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = ""
        app.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        app.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: ui test ok"
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let sessionCell = app.staticTexts[sessionTitle]
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10))
        sessionCell.tap()

        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "ui test ok")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
    }
}
