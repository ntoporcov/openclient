import XCTest

@MainActor
final class DesktopLoadingGameUITests: XCTestCase {
    func testLandscapeGameRecordsHitsAndRestoresBestAfterRelaunch() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_DESKTOP_GAME_TEST_SUITE"] = "DesktopGameUITest.\(UUID().uuidString)"
        app.launch()
        defer { app.terminate() }
        let start = app.buttons["remote-desktop.game.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let target = app.buttons["remote-desktop.game.target"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        target.tap()
        let best = app.staticTexts["remote-desktop.game.best"]
        XCTAssertTrue(best.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["remote-desktop.game.last"].exists)
        let saved = best.label
        app.terminate()
        app.launch()
        XCTAssertTrue(best.waitForExistence(timeout: 15))
        XCTAssertEqual(best.label, saved)
        XCTAssertTrue(start.exists)
        XCTAssertFalse(target.exists)
    }
}
