import XCTest

@MainActor
final class DesktopPointerUITests: XCTestCase {
    func testTopControlGapPassesClicksToDesktopButButtonsDoNot() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_DESKTOP_POINTER_TEST"] = "1"
        app.launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        let canvas = app.descendants(matching: .any).matching(identifier: "remote-desktop.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let close = app.buttons["Close"]
        let gap = canvas.coordinate(withNormalizedOffset: CGVector(
            dx: 0.5, dy: (close.frame.midY - canvas.frame.minY) / canvas.frame.height))
        gap.tap()
        XCTAssertEqual(app.staticTexts["desktop.pointer.events"].label, "1|1|0|0")
        close.tap()
        XCTAssertEqual(app.staticTexts["desktop.pointer.close-count"].label, "1")
        XCTAssertEqual(app.staticTexts["desktop.pointer.events"].label, "1|1|0|0")
    }

    func testDoubleTapAndHoldDragSendDistinctMouseSequences() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_DESKTOP_POINTER_TEST"] = "1"
        app.launch()
        defer { app.terminate() }
        let canvas = app.descendants(matching: .any).matching(identifier: "remote-desktop.canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let events = app.staticTexts["desktop.pointer.events"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertEqual(events.label, "2|2|0|0", "A double tap must send exactly two full clicks")
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.6, thenDragTo: end)
        let parts = events.label.split(separator: "|").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], 3)
        XCTAssertEqual(parts[1], 3, "Lifting the finger must release the remote mouse")
        XCTAssertGreaterThan(parts[2], 0)
        XCTAssertEqual(parts[3], 0, "Dragging must not open a context menu")
        end.press(forDuration: 0.6)
        let afterHold = events.label.split(separator: "|").compactMap { Int($0) }
        XCTAssertEqual(afterHold, [3, 3, parts[2], 1], "A stationary hold must send only a right-click")
    }
}
