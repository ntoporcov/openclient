import XCTest

@MainActor
final class ChatControlsAnnouncementUITests: XCTestCase {
    func testInteractiveReleaseChoicesAndPreviews() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_CHAT_CONTROLS_PREVIEW"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let picker = app.segmentedControls["new-features.streaming-delivery"]
        XCTAssertTrue(picker.waitForExistence(timeout: 15))
        picker.buttons["Steer"].tap()
        XCTAssertTrue(app.staticTexts["Steer redirects the assistant during its current turn."].exists)
        XCTAssertFalse(app.buttons["new-features.try-send"].exists)
        XCTAssertTrue(app.staticTexts["Hold Send to choose Queue, Steer, or Side Question for a single message."].exists)
        func reveal(_ element: XCUIElement) {
            for _ in 0..<10 {
                if element.isHittable { return }
                app.swipeUp()
            }
            XCTAssertTrue(element.isHittable, "\(element.identifier)\n\(app.debugDescription)")
        }
        let bubbles = app.segmentedControls["new-features.bubble-style"]
        reveal(bubbles)
        bubbles.buttons.element(boundBy: 1).tap()
        let accent = app.buttons["appearance.accent-color.purple"]
        reveal(accent)
        accent.tap()
        XCTAssertTrue(accent.isSelected)
        let grouping = app.switches["new-features.group-tools"]
        reveal(grouping)
        XCTAssertEqual(grouping.value as? String, "0")
        grouping.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(grouping.value as? String, "1")
        let preview = app.buttons["new-features.group-preview"]
        reveal(preview)
        preview.tap()
        XCTAssertTrue(app.staticTexts["Theme.swift"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Chat-Customization-Announcement"
        capture.lifetime = .keepAlways
        add(capture)
    }
}
