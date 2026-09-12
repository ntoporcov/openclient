import XCTest

@MainActor
final class ChatHeaderUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testShortTitlePillIsWiderThanEntireModelGroup() {
        for window in [false, true] {
            let app = launch(window: window, shortTitle: true)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "Default")
            capture(app, "Toolbar-Short-Title-Balance-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testLongModelAndReasoningStayVisibleWithoutToolbarOverflow() {
        let appearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = appearance }
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch(window: dark, large: true, longModel: true)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            capture(app, "Toolbar-Long-\(dark ? "Dark" : "Light")")
            assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
            app.terminate()
        }
    }

    private func assertEssentialControls(_ app: XCUIApplication, modelTitle: String, reasoning: String) {
        let isPhone = !app.buttons["chat.composer.model"].exists
        let model = app.buttons[isPhone ? "chat.toolbar.model" : "chat.composer.model"]
        XCTAssertTrue(model.exists)
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue((model.value as? String ?? "").contains(modelTitle))
        if isPhone {
            XCTAssertTrue((model.value as? String ?? "").contains(reasoning))
            XCTAssertLessThanOrEqual(model.frame.width, 192)
            XCTAssertGreaterThanOrEqual(model.frame.height, 44)
            let title = app.staticTexts["chat.toolbar.model.title"]
            let variant = app.staticTexts["chat.toolbar.model.reasoning"]
            XCTAssertTrue(title.exists)
            XCTAssertTrue(variant.exists)
            XCTAssertLessThanOrEqual(title.frame.maxX, model.frame.maxX)
            XCTAssertLessThanOrEqual(variant.frame.maxX, model.frame.maxX)
            let logo = app.descendants(matching: .any).matching(identifier: "chat.toolbar.providerLogo").firstMatch
            XCTAssertTrue(logo.exists)
            XCTAssertGreaterThanOrEqual(logo.frame.minX, max(title.frame.maxX, variant.frame.maxX))
            XCTAssertLessThanOrEqual(logo.frame.maxX, model.frame.maxX)
        } else {
            XCTAssertTrue(app.buttons["chat.composer.reasoning"].isHittable)
        }
        let ring = app.buttons["chat.toolbar.context"]
        XCTAssertTrue(ring.isHittable)
        if isPhone {
            XCTAssertEqual(ring.frame.width, 44, accuracy: 1)
            XCTAssertGreaterThanOrEqual(ring.frame.minX, app.buttons["chat.header"].frame.maxX)
            XCTAssertGreaterThanOrEqual(model.frame.minX, ring.frame.maxX)
            let header = app.buttons["chat.header"]
            let leftWidth = ring.frame.maxX - header.frame.minX
            XCTAssertGreaterThan(leftWidth, model.frame.width)
            XCTAssertLessThanOrEqual(ring.frame.minX - header.frame.maxX, 4.5)
            let geometry = XCTAttachment(string: "header=\(header.frame) leftGroupWidth=\(leftWidth) model=\(model.frame) context=\(ring.frame)")
            geometry.name = "Toolbar-Rendered-Widths"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        let bar = app.navigationBars.firstMatch
        if isPhone {
            XCTAssertEqual(bar.buttons.count, 4, "Back, header, context, and model must remain in the bar without an overflow item")
            XCTAssertLessThanOrEqual(model.frame.maxX, bar.frame.maxX)
        }
        XCTAssertFalse(bar.buttons["More"].exists)
        XCTAssertFalse(bar.buttons["ellipsis"].exists)
        XCTAssertFalse(bar.buttons["More actions"].exists)
        XCTAssertFalse(bar.buttons["Open Streaming Debug Log"].exists)
        XCTAssertGreaterThan(model.frame.width, 44)
        XCTAssertLessThanOrEqual(model.frame.maxX, app.frame.maxX)
    }

    func testModelReasoningAndContextActionsRemainUsableInRootAndWindow() {
        for window in [false, true] {
            let app = launch(window: window)
            XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
            assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "High")
            let usesComposer = app.buttons["chat.composer.model"].exists
            let picker = app.buttons[usesComposer ? "chat.composer.model" : "chat.toolbar.model"]
            picker.tap()
            app.collectionViews.buttons["Model"].firstMatch.tap()
            app.collectionViews.buttons["OpenAI"].firstMatch.tap()
            app.buttons["GPT-6 Astra Extended Context Research Preview"].tap()
            XCTAssertTrue((picker.value as? String ?? "").contains("GPT-6 Astra Extended Context Research Preview"))
            if usesComposer { app.buttons["chat.composer.reasoning"].tap() }
            else { picker.tap(); app.collectionViews.buttons["Reasoning"].firstMatch.tap() }
            app.buttons["Extended Deliberation For Complex Tasks"].tap()
            assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
            if window { XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].value as? String, "astra|high") }
            else { XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].value as? String, "astra-long|extended_deliberation_for_complex_tasks") }
            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 3))
            capture(app, "Toolbar-Context-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testCompactToolbarFits320PointPaneAndRespondsToRotation() {
        let orientation = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = orientation }
        let app = launch(window: true, large: true, longModel: true, narrow: true)
        XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
        assertEssentialControls(app, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
        capture(app, "Toolbar-320")
        app.terminate()
        let expanded = launch(window: false, longModel: true)
        XCTAssertTrue(expanded.buttons["chat.header"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        assertEssentialControls(expanded, modelTitle: "GPT-6 Astra Extended Context Research Preview", reasoning: "Extended Deliberation For Complex Tasks")
        capture(expanded, "Toolbar-Rotated")
        expanded.terminate()
    }

    func testHeaderSelectionAndRenameRootAndWindow() {
        for window in [false, true] {
            let app = launch(window: window)
            let header = app.buttons["chat.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 15))
            XCTAssertGreaterThanOrEqual(header.frame.height, 44)
            capture(app, "Header-Bar-\(window ? "Window" : "Root")")
            header.tap()
            let agent = app.buttons["chat.header.agent.ReviewAgent"]
            XCTAssertTrue(agent.waitForExistence(timeout: 3))
            capture(app, "Header-\(window ? "Window" : "Root")")
            let transcript = app.collectionViews["chat.scroll"]
            let popover = app.otherElements["chat.header.popover"].firstMatch
            if popover.exists, transcript.exists {
                XCTAssertLessThanOrEqual(popover.frame.width, transcript.frame.width + 1)
                XCTAssertGreaterThanOrEqual(popover.frame.width, transcript.frame.width - 64)
            }
            XCTAssertTrue(app.staticTexts["ReviewAgent agent description"].exists)
            agent.tap()
            XCTAssertTrue(header.label.contains("ReviewAgent"))
            header.tap()
            let field = app.textFields["chat.header.rename.title"]
            XCTAssertTrue(field.waitForExistence(timeout: 3))
            let originalTitle = field.value as? String
            field.tap()
            field.typeText("Renamed B")
            let renamedTitle = field.value as? String ?? ""
            XCTAssertTrue(renamedTitle.contains("Renamed B"))
            XCTAssertNotEqual(renamedTitle, originalTitle)
            app.buttons["chat.header.rename.save"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@",
                "chat.header", renamedTitle)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["chat.header.fixture.root"].label, window ? "header-a" : "header-b")
            capture(app, "Header-Renamed-\(window ? "Window" : "Root")")
            app.terminate()
        }
    }

    func testHeaderLongTitleLargeTypeLightDarkAndScrollableAgents() {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        for dark in [false, true] {
            XCUIDevice.shared.appearance = dark ? .dark : .light
            let app = launch(window: true, large: true)
            let header = app.buttons["chat.header"]
            XCTAssertTrue(header.waitForExistence(timeout: 15))
            capture(app, "Header-Large-\(dark ? "Dark" : "Light")")
            header.tap()
            XCTAssertTrue(app.textFields["chat.header.rename.title"].waitForExistence(timeout: 3))
            capture(app, "Header-Popover-Large-\(dark ? "Dark" : "Light")")
            XCTAssertTrue(app.switches["chat.header.liveActivity"].isHittable)
            app.terminate()
        }
    }

    func testHeaderMenuWhileComposerKeyboardIsVisible() {
        let app = launch(window: true)
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Keep this draft")
        assertEssentialControls(app, modelTitle: "GPT-6 Astra", reasoning: "High")
        app.buttons["chat.header"].tap()
        let list = app.collectionViews["chat.header.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let title = app.textFields["chat.header.rename.title"]
        XCTAssertTrue(title.isHittable)
        capture(app, "Header-Keyboard")
        app.terminate()
    }

    private func launch(window: Bool, large: Bool = false, longModel: Bool = false, narrow: Bool = false, shortTitle: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_HEADER_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_HEADER_WINDOW"] = window ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_MANY_AGENTS"] = large ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_LONG_MODEL"] = longModel ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_NARROW"] = narrow ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_SHORT_TITLE"] = shortTitle ? "1" : "0"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
