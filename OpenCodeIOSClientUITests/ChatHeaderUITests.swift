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
        let usesToolbarModel = app.buttons["chat.toolbar.model"].exists
        let modelIdentifier = usesToolbarModel ? "chat.toolbar.model" : "chat.composer.model"
        let model = app.buttons[modelIdentifier]
        XCTAssertTrue(model.exists)
        XCTAssertTrue(model.isHittable)
        XCTAssertTrue((model.value as? String ?? "").contains(modelTitle))
        XCTAssertTrue((model.value as? String ?? "").contains(reasoning))
        let title = app.staticTexts["\(modelIdentifier).title"]
        let variant = app.staticTexts["\(modelIdentifier).reasoning"]
        XCTAssertTrue(title.exists)
        XCTAssertTrue(variant.exists)
        XCTAssertLessThanOrEqual(title.frame.maxX, model.frame.maxX)
        XCTAssertLessThanOrEqual(variant.frame.maxX, model.frame.maxX)
        if usesToolbarModel {
            XCTAssertLessThanOrEqual(model.frame.width, 192)
            XCTAssertGreaterThanOrEqual(model.frame.height, 44)
            let logo = app.descendants(matching: .any).matching(identifier: "chat.toolbar.providerLogo").firstMatch
            XCTAssertTrue(logo.exists)
            XCTAssertGreaterThanOrEqual(logo.frame.minX, max(title.frame.maxX, variant.frame.maxX))
            XCTAssertLessThanOrEqual(logo.frame.maxX, model.frame.maxX)
        }
        let ring = app.buttons["chat.toolbar.context"]
        XCTAssertTrue(ring.isHittable)
        if usesToolbarModel {
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
        if usesToolbarModel {
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
            let picker = app.buttons[app.buttons["chat.toolbar.model"].exists ? "chat.toolbar.model" : "chat.composer.model"]
            picker.tap()
            app.collectionViews.buttons["Model"].firstMatch.tap()
            app.collectionViews.buttons["OpenAI"].firstMatch.tap()
            app.buttons["GPT-6 Astra Extended Context Research Preview"].tap()
            XCTAssertTrue((picker.value as? String ?? "").contains("GPT-6 Astra Extended Context Research Preview"))
            picker.tap()
            app.collectionViews.buttons["Reasoning"].firstMatch.tap()
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

    func testHeaderAppearanceComposerStylePreviewPreservesPopoverAndDraft() {
        let app = launch(window: true)
        let input = app.textViews["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Keep this appearance draft")

        app.buttons["chat.header"].tap()
        let appearance = app.buttons["chat.header.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()

        let composerStyle = app.buttons["chat.appearance.composer-style"]
        XCTAssertTrue(composerStyle.waitForExistence(timeout: 3))
        composerStyle.tap()

        let picker = app.segmentedControls["configurations.composer-style"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        let preview = app.descendants(matching: .any)["chat.appearance.composer-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 3))
        XCTAssertEqual(preview.buttons.count, 0)
        XCTAssertEqual(preview.textFields.count, 0)
        XCTAssertEqual(preview.textViews.count, 0)

        picker.buttons["Assistant"].tap()
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)
        XCTAssertTrue(app.navigationBars["Composer Style"].exists, "Changing layout must not dismiss the header popover")
        XCTAssertTrue(preview.label.contains("Assistant"))

        picker.buttons["Messenger"].tap()
        XCTAssertTrue(picker.buttons["Messenger"].isSelected)
        XCTAssertTrue(app.navigationBars["Composer Style"].exists)
        picker.buttons["Assistant"].tap()
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)

        app.navigationBars["Composer Style"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Appearance Settings"].waitForExistence(timeout: 3))
        app.navigationBars["Appearance Settings"].buttons.firstMatch.tap()
        let agent = app.buttons["chat.header.agent.build"]
        XCTAssertTrue(agent.waitForExistence(timeout: 3))
        agent.tap()

        XCTAssertTrue(input.waitForExistence(timeout: 3))
        XCTAssertEqual(input.value as? String, "Keep this appearance draft")
        XCTAssertTrue(app.buttons["chat.composer.model"].waitForExistence(timeout: 3))
        app.buttons["chat.header"].tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        appearance.tap()
        composerStyle.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.buttons["Assistant"].isSelected)
        app.terminate()
    }

    func testAssistantHeaderAndContextStayInNavigationBarWhileKeyboardIsVisible() {
        for fixture in [(name: "Root", window: false, narrow: false), (name: "Window-320", window: true, narrow: true)] {
            let app = launch(window: fixture.window, narrow: fixture.narrow, assistant: true)
            let input = app.textViews["chat.input"]
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            capture(app, "Header-Assistant-Before-Keyboard-\(fixture.name)")
            assertAssistantHeaderLayout(app)

            input.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
                input.tap()
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
            input.typeText("Keep the Assistant composer active")
            capture(app, "Header-Assistant-Keyboard-\(fixture.name)")
            assertAssistantHeaderLayout(app)

            app.buttons["chat.header"].tap()
            let list = app.collectionViews["chat.header.list"]
            XCTAssertTrue(list.waitForExistence(timeout: 3))
            app.buttons["chat.header.agent.build"].tap()
            XCTAssertTrue(list.waitForNonExistence(timeout: 3))

            app.buttons["chat.toolbar.context"].tap()
            XCTAssertTrue(app.navigationBars["Context"].waitForExistence(timeout: 3))
            capture(app, "Header-Assistant-Context-\(fixture.name)")
            app.terminate()
        }
    }

    func testAssistantHeaderUsesLeadingLandscapeAndTrailingPortrait() {
        let app = launch(window: false, assistant: true)
        addTeardownBlock {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        XCTAssertTrue(app.buttons["chat.header"].waitForExistence(timeout: 15))
        capture(app, "Header-Assistant-Portrait")
        assertAssistantHeaderLayout(app)

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLandscape(app))
        capture(app, "Header-Assistant-Landscape")
        assertAssistantHeaderLayout(app, expectsLeading: true)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForPortrait(app))
        capture(app, "Header-Assistant-Portrait-After-Rotation")
        assertAssistantHeaderLayout(app)
    }

    func testAssistantComposerMenuOpensDismissesAndModelMenuRemainsUsable() {
        let app = launch(window: false, assistant: true)
        XCTAssertTrue(app.buttons["chat.composer.menu"].waitForExistence(timeout: 15))

        let composerMenu = app.buttons["chat.composer.menu"]
        composerMenu.tap()
        let tools = app.navigationBars["Message Tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertTrue(composerMenu.exists)
        capture(app, "Assistant-Attachment-Popover")

        let photos = app.buttons["chat.composer.photos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        photos.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()

        let model = app.buttons["chat.composer.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 3))
        let modelHittable = expectation(
            for: NSPredicate(format: "hittable == true"),
            evaluatedWith: model
        )
        wait(for: [modelHittable], timeout: 3)
        model.tap()
        let modelGroup = app.collectionViews.buttons["Model"].firstMatch
        XCTAssertTrue(modelGroup.waitForExistence(timeout: 3))
        modelGroup.tap()
        let provider = app.collectionViews.buttons["OpenAI"].firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 3))
        provider.tap()
        let longModel = app.buttons["GPT-6 Astra Extended Context Research Preview"]
        XCTAssertTrue(longModel.waitForExistence(timeout: 3))
        longModel.tap()
        XCTAssertTrue((model.value as? String ?? "").contains("GPT-6 Astra Extended Context Research Preview"))
        Thread.sleep(forTimeInterval: 0.5)
        capture(app, "Assistant-Glass-Model-Long-Title")
        app.terminate()
    }

    private func assertAssistantHeaderLayout(_ app: XCUIApplication, expectsLeading: Bool = false) {
        let header = app.buttons["chat.header"]
        let context = app.buttons["chat.toolbar.context"]
        let bar = app.navigationBars.firstMatch
        let back = bar.buttons["Sessions"]
        let headerFrame = header.exists ? header.frame : .null
        let contextFrame = context.exists ? context.frame : .null
        let trailingGap = context.exists ? bar.frame.maxX - contextFrame.maxX : .infinity
        let leadingSafeGap = back.exists ? back.frame.minX - bar.frame.minX : .infinity
        let geometry = XCTAttachment(string: "app=\(app.frame) navigationBar=\(bar.frame) back=\(back.exists ? back.frame : .null) headerExists=\(header.exists) headerHittable=\(header.isHittable) header=\(headerFrame) contextExists=\(context.exists) contextHittable=\(context.isHittable) context=\(contextFrame) leadingSafeGap=\(leadingSafeGap) trailingGap=\(trailingGap)")
        geometry.name = "Assistant-Toolbar-Frame-Evidence"
        geometry.lifetime = .keepAlways
        add(geometry)

        XCTAssertTrue(header.isHittable)
        XCTAssertTrue(context.isHittable)
        XCTAssertEqual(context.frame.width, 44, accuracy: 1)
        XCTAssertGreaterThanOrEqual(context.frame.minX, header.frame.maxX)
        XCTAssertLessThanOrEqual(context.frame.minX - header.frame.maxX, 4.5)

        XCTAssertLessThanOrEqual(context.frame.maxX, bar.frame.maxX)
        if expectsLeading {
            XCTAssertTrue(back.exists)
            XCTAssertGreaterThanOrEqual(header.frame.minX, back.frame.maxX - 8,
                "The Assistant title should remain beside the native back control in landscape")
            XCTAssertLessThanOrEqual(header.frame.minX - back.frame.maxX, 24,
                "The Assistant title should not leave a large gap after the native back control")
            XCTAssertLessThan(header.frame.midX, bar.frame.midX,
                "The Assistant group should remain leading in landscape")
        }
        if !expectsLeading && app.frame.width < 600 {
            XCTAssertGreaterThan(context.frame.midX, bar.frame.midX,
                "The Assistant pill should remain trailing in portrait")
            // Liquid Glass extends four points beyond the context button's AX hit frame.
            XCTAssertEqual(trailingGap, 24, accuracy: 1, "The single Assistant pill should reach the 20-point visual margin")
        }
        XCTAssertFalse(bar.buttons["More"].exists)
        XCTAssertFalse(bar.buttons["ellipsis"].exists)
        XCTAssertFalse(bar.buttons["More actions"].exists)
    }

    private func waitForLandscape(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.frame.width > app.frame.height { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func waitForPortrait(_ app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if app.frame.height > app.frame.width { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    private func launch(window: Bool, large: Bool = false, longModel: Bool = false, narrow: Bool = false,
                        shortTitle: Bool = false, assistant: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_HEADER_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_HEADER_WINDOW"] = window ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_MANY_AGENTS"] = large ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_LONG_MODEL"] = longModel ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_NARROW"] = narrow ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_SHORT_TITLE"] = shortTitle ? "1" : "0"
        app.launchEnvironment["OPENCLIENT_HEADER_ASSISTANT"] = assistant ? "1" : "0"
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
