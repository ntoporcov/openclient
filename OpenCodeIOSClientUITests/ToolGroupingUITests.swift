import XCTest

@MainActor
final class ToolGroupingUITests: XCTestCase {
    func testGroupingAndVisibilityKeepContextMarkers() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_TOOL_GROUPING_FIXTURE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.tools.group."))
        XCTAssertTrue(app.buttons["grouping.grouping"].waitForExistence(timeout: 15))
        XCTAssertEqual(groups.count, 2)
        groups.firstMatch.tap()
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Grouped-Tools-And-Context"
        capture.lifetime = .keepAlways
        add(capture)
        app.buttons["grouping.reasoning"].tap()
        XCTAssertEqual(groups.count, 1)
        app.buttons["grouping.grouping"].tap()
        XCTAssertEqual(groups.count, 0)
        app.buttons["grouping.tools"].tap()
        XCTAssertTrue(app.buttons["chat.context.model-switched"].exists)
        XCTAssertTrue(app.buttons["chat.context.system"].exists)
        app.buttons["grouping.grouping"].tap()
        XCTAssertEqual(groups.count, 0, "Grouping must not reveal hidden tools")
        app.buttons["chat.context.system"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 3))
        app.buttons["Done"].tap()
        app.buttons["grouping.tools"].tap()
        XCTAssertEqual(groups.count, 1)
        app.terminate()
    }
}
