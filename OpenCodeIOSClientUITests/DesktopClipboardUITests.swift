import XCTest

@MainActor
final class DesktopClipboardUITests: XCTestCase {
    func testClipboardCaptureRequiresExplicitCopyAndSurvivesClosingViewer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_DESKTOP_CLIPBOARD_TEST"] = "1"
        app.launch()
        defer { app.terminate() }
        let capture = app.buttons["clipboard.fixture.capture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 15))
        let clipboard = app.buttons["remote-desktop.clipboard"]
        XCTAssertFalse(clipboard.exists)
        capture.tap()
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        XCTAssertNotEqual(app.staticTexts["clipboard.fixture.copied"].label, "Captured computer text")
        clipboard.tap()
        let item = app.buttons["remote-desktop.clipboard.item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.label.contains("Captured computer text"))
        item.tap()
        app.buttons["remote-desktop.clipboard.done"].tap()
        XCTAssertEqual(app.staticTexts["clipboard.fixture.copied"].label, "Captured computer text")
        app.buttons["clipboard.fixture.close"].tap()
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        clipboard.tap()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertTrue(item.label.contains("Captured computer text"))
    }
}
