import XCTest
#if canImport(UIKit)
import UIKit
#endif

final class OpenCodeIOSClientUITests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private var baseURL: URL {
        URL(string: environment["SNAPSHOT_OPENCODE_BASE_URL"] ?? environment["OPENCODE_UI_TEST_BASE_URL"] ?? "http://127.0.0.1:4096")!
    }

    private var username: String {
        nonEmptyEnvironmentValue("SNAPSHOT_OPENCODE_USERNAME")
            ?? nonEmptyEnvironmentValue("OPENCODE_UI_TEST_USERNAME")
            ?? "opencode"
    }

    private var password: String {
        nonEmptyEnvironmentValue("SNAPSHOT_OPENCODE_PASSWORD")
            ?? nonEmptyEnvironmentValue("OPENCODE_UI_TEST_PASSWORD")
            ?? ""
    }

    private var projectDirectory: String {
        environment["SNAPSHOT_OPENCODE_DIRECTORY"] ?? environment["OPENCODE_UI_TEST_DIRECTORY"] ?? "/tmp/opencode-ios-client"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func nonEmptyEnvironmentValue(_ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    @MainActor
    func testAppStoreScreenshots() {
        let allScenes: [(scene: String, screenshotName: String)] = [
            ("connection", "01-connection"),
            ("recent-servers", "02-recent-servers"),
            ("projects", "03-projects"),
            ("activity", "04-activity"),
            ("new-session", "05-new-session"),
            ("provider-setup", "06-provider-setup"),
            ("sessions", "07-sessions"),
            ("permission", "09-permission"),
            ("question", "10-question"),
            ("fun-games", "11-fun-games"),
            ("find-place-game", "12-find-place-game"),
            ("find-bug-game", "13-find-bug-game"),
            ("composer-actions", "14-composer-actions"),
            ("paywall", "15-paywall"),
            ("recent-widget", "16-recent-widget"),
            ("pinned-widget", "17-pinned-widget"),
            ("quick-start-widgets", "18-quick-start-widgets"),
            ("live-activity", "19-live-activity"),
            ("session-actions", "20-session-actions"),
            ("session-pinned", "21-session-pinned"),
            ("browser", "22-browser"),
            ("visual-tools", "23-visual-tools"),
            ("terminal-showcase", "24-terminal"),
            ("chat", "08-chat"),
        ]

        let requestedScenes = Set(
            (environment["OPENCLIENT_SCREENSHOT_SCENES"] ?? "")
                .split(separator: ",")
                .map(String.init)
        )
        let scenes = requestedScenes.isEmpty
            ? allScenes
            : allScenes.filter { requestedScenes.contains($0.scene) }

        XCTAssertEqual(Set(scenes.map(\.scene)).count, scenes.count, "Screenshot scene names must be unique")
        XCTAssertEqual(Set(scenes.map(\.screenshotName)).count, scenes.count, "Screenshot output names must be unique")
        XCTAssertEqual(scenes.count, requestedScenes.isEmpty ? allScenes.count : requestedScenes.count, "Every requested screenshot scene must exist")

        let simulatorDeviceName = environment["SIMULATOR_DEVICE_NAME"] ?? ""
        #if canImport(UIKit)
        let capturesLandscape = UIDevice.current.userInterfaceIdiom == .pad || simulatorDeviceName.localizedCaseInsensitiveContains("iPad")
        #else
        let capturesLandscape = simulatorDeviceName.localizedCaseInsensitiveContains("iPad")
        #endif
        setSnapshotLandscapeOutput(capturesLandscape)

        for (scene, screenshotName) in scenes {
            XCUIDevice.shared.orientation = capturesLandscape ? .landscapeLeft : .portrait

            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = scene
            if scene == "terminal-showcase" {
                app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
            }
            app.launch()
            XCUIDevice.shared.orientation = capturesLandscape ? .landscapeLeft : .portrait
            if capturesLandscape {
                sleep(1)
            }

            let sceneMarker = app.staticTexts["screenshot.scene.\(scene)"]
            XCTAssertTrue(sceneMarker.waitForExistence(timeout: 10), "Expected screenshot scene \(scene) to load")

            if scene == "connection" || scene == "recent-servers" {
                XCTAssertTrue(app.navigationBars["OpenClient"].waitForExistence(timeout: 10), "Expected connection sheet to load")
            }

            if scene == "projects" || scene == "provider-setup" {
                XCTAssertTrue(app.buttons["projects.activity"].waitForExistence(timeout: 10), "Expected Activity link to load")
            }

            if scene == "projects" {
                XCTAssertTrue(app.textFields["projects.searchChats"].waitForExistence(timeout: 10), "Expected project chat search bar to load")
                XCTAssertTrue(app.buttons["projects.newChat"].waitForExistence(timeout: 10), "Expected project new chat button to load")
            }

            if scene == "new-session" {
                XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10), "Expected new session sheet to load")
                let projectPicker = app.descendants(matching: .any)["projects.newChat.project"]
                XCTAssertTrue(projectPicker.waitForExistence(timeout: 10), "Expected project picker in new session sheet")
            }

            if scene == "activity", capturesLandscape {
                let historicalSession = app.buttons["activity.session.session-screenshot-review"]
                XCTAssertTrue(
                    revealForScreenshot(historicalSession, in: app),
                    "Expected simplified historical Activity card"
                )
            }

            if scene == "chat", capturesLandscape {
                let dedicatedWindow = app.descendants(matching: .any)["chat.dedicatedWindow"]
                if !dedicatedWindow.exists {
                    let openWindow = app.buttons["chat.toolbar.openWindow"]
                    XCTAssertTrue(openWindow.waitForExistence(timeout: 10), "Expected Open Chat in New Window action")
                    openWindow.tap()
                }
                XCTAssertTrue(
                    dedicatedWindow.waitForExistence(timeout: 10),
                    "Expected dedicated chat window"
                )
                sleep(1)
            }

            if scene == "composer-actions" {
                let composerMenu = app.buttons["chat.composer.menu"]
                XCTAssertTrue(composerMenu.waitForExistence(timeout: 10), "Expected composer menu button to load")
                composerMenu.tap()
                XCTAssertTrue(app.navigationBars["Message Tools"].waitForExistence(timeout: 10), "Expected composer actions sheet to load")
            }

            if scene == "provider-setup" {
                let configurations = app.buttons["projects.configurations"]
                XCTAssertTrue(configurations.waitForExistence(timeout: 10), "Expected configurations button to load")
                configurations.tap()
                XCTAssertTrue(app.navigationBars["Add Provider"].waitForExistence(timeout: 10), "Expected Add Provider screen to load")
            }

            if scene == "browser" {
                XCTAssertTrue(
                    app.staticTexts["screenshot.browser.ready"].waitForExistence(timeout: 15),
                    "Expected offline browser fixture to finish loading"
                )
                XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 10), "Expected browser address bar")
                XCTAssertTrue(app.descendants(matching: .any)["browser.instruction"].waitForExistence(timeout: 10), "Expected browser instruction banner")
            }

            if scene == "visual-tools" {
                XCTAssertTrue(
                    app.staticTexts["screenshot.visual-tools.ready"].waitForExistence(timeout: 15),
                    "Expected visual HTML fixture to finish loading"
                )
                XCTAssertTrue(app.descendants(matching: .any)["chat.tool.visual-chart"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.descendants(matching: .any)["chat.tool.visual-html"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.descendants(matching: .any)["chat.tool.visual-video"].waitForExistence(timeout: 10))
            }

            if scene == "terminal-showcase" {
                let terminal = app.descendants(matching: .any)["terminal.viewport"]
                XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Expected terminal viewport")
                XCTAssertTrue(waitForTerminalPosition(in: 0.95 ... 1.0, element: terminal), "Expected release transcript at the latest output")
                sleep(1)
            }

            snapshot(screenshotName)
            app.terminate()
        }
    }

    @MainActor
    private func revealForScreenshot(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0 ..< 8 {
            if element.exists,
               element.isHittable,
               element.frame.midY < app.frame.height * 0.78 {
                return true
            }
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return element.exists && element.isHittable
    }

    @MainActor
    func testActivityProjectFilterMenu() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["activity.newChat"].waitForExistence(timeout: 5))
        let filter = app.buttons["activity.projectFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-release"].exists)
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-docs"].exists)

        filter.tap()

        XCTAssertTrue(app.buttons["All Projects"].waitForExistence(timeout: 5))
        let openClientProject = app.buttons["openclient"]
        XCTAssertTrue(openClientProject.exists)
        XCTAssertTrue(app.buttons["avatarless-project"].exists)
        XCTAssertTrue(app.buttons["product-playbook"].exists)
        let menuScreenshot = XCTAttachment(screenshot: app.screenshot())
        menuScreenshot.name = "Activity Project Filter"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)
        openClientProject.tap()

        XCTAssertFalse(app.buttons["activity.session.session-screenshot-release"].exists)
        XCTAssertTrue(app.buttons["activity.session.session-screenshot-docs"].exists)
    }

    @MainActor
    func testActivityLiveActivitySwipeAction() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        let row = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()

        XCTAssertTrue(app.buttons["Stop Live"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(app.buttons["Rename"].exists)
    }

    @MainActor
    func testActivitySessionContextMenuShowsSessionActions() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        let row = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1.0)

        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Delete"].exists)
        XCTAssertTrue(app.buttons["Stop Live"].exists)
        app.buttons["Rename"].tap()
        let renameAlert = app.alerts["Rename Session"]
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
        renameAlert.buttons["Cancel"].tap()
    }

    @MainActor
    func testActivitySettingsHideLastUserMessageAndPersistPreference() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "activity"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        let row = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        app.buttons["activity.settings"].tap()
        XCTAssertTrue(app.navigationBars["Activity Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["activity.settings.showLastUserMessage"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if !isSwitchOn(toggle) {
            toggle.tap()
        }
        app.buttons["Done"].tap()
        let userMessage = app.staticTexts["activity.session.session-screenshot-release.latest-user"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5))

        app.buttons["activity.settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.tap()
        app.buttons["Done"].tap()
        let compactPredicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return !element.exists
        }
        expectation(for: compactPredicate, evaluatedWith: userMessage)
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["screenshot.scene.activity"].waitForExistence(timeout: 10))
        let restoredRow = app.buttons["activity.session.session-screenshot-release"]
        XCTAssertTrue(restoredRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["activity.session.session-screenshot-release.latest-user"].exists)

        app.buttons["activity.settings"].tap()
        let restoredToggle = app.switches["activity.settings.showLastUserMessage"]
        XCTAssertTrue(restoredToggle.waitForExistence(timeout: 5))
        XCTAssertFalse(isSwitchOn(restoredToggle))
        restoredToggle.tap()
        app.buttons["Done"].tap()
    }

    @MainActor
    private func isSwitchOn(_ element: XCUIElement) -> Bool {
        guard let value = element.value as? String else { return false }
        return ["1", "on", "true"].contains(value.lowercased())
    }

    @MainActor
    func testNewSessionUIKitPickerRemainsInContext() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "new-session"
        app.launch()

        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10))
        let modelTrigger = app.descendants(matching: .any)["projects.newChat.model"]
        XCTAssertTrue(modelTrigger.waitForExistence(timeout: 10))
        modelTrigger.tap()

        let option = app.buttons["Claude Sonnet 4.5"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["New Session"].exists)
        option.tap()

        XCTAssertTrue(modelTrigger.exists)
        XCTAssertEqual(modelTrigger.value as? String, "Claude Sonnet 4.5")
    }

    @MainActor
    func testChatModelPickerSelectsModelAndReasoning() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].waitForExistence(timeout: 10))
        let modelTrigger = app.buttons["chat.toolbar.model"]
        XCTAssertTrue(modelTrigger.waitForExistence(timeout: 10))

        modelTrigger.tap()
        let modelMenu = app.collectionViews.buttons["Model"]
        XCTAssertTrue(modelMenu.waitForExistence(timeout: 10))
        modelMenu.tap()
        let providerMenu = app.buttons["Anthropic"]
        XCTAssertTrue(providerMenu.waitForExistence(timeout: 10))
        providerMenu.tap()
        let model = app.buttons["Claude Sonnet 4.5"]
        XCTAssertTrue(model.waitForExistence(timeout: 10))
        model.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(of: modelTrigger, equalTo: "Claude Sonnet 4.5, Default"),
            "Expected selecting Claude to update the chat model"
        )

        modelTrigger.tap()
        let reasoningMenu = app.collectionViews.buttons["Reasoning"].firstMatch
        XCTAssertTrue(reasoningMenu.waitForExistence(timeout: 10))
        reasoningMenu.tap()
        let reasoning = app.buttons["Balanced"]
        XCTAssertTrue(reasoning.waitForExistence(timeout: 10))
        reasoning.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(of: modelTrigger, equalTo: "Claude Sonnet 4.5, Balanced"),
            "Expected selecting Balanced to update the reasoning level"
        )
    }

    @MainActor
    func testChatTodoStripMinimizesAndRestores() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].waitForExistence(timeout: 10))
        let expandedTodos = app.descendants(matching: .any)["chat.todos.expanded"]
        XCTAssertTrue(expandedTodos.waitForExistence(timeout: 10))

        expandedTodos.swipeDown()

        let minimizedTodos = app.buttons["chat.todos.minimized"]
        XCTAssertTrue(minimizedTodos.waitForExistence(timeout: 5))
        minimizedTodos.tap()

        XCTAssertTrue(expandedTodos.waitForExistence(timeout: 5))
    }

    @MainActor
    func testTerminalScrollsAndDismissesKeyboard() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "terminal"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_PASTE_TEXT"] = "fixture-paste"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.terminal"].waitForExistence(timeout: 10))
        let terminalRow = app.buttons.matching(identifier: "terminal.row").firstMatch
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 10), "Expected seeded terminal session row")
        terminalRow.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Expected terminal viewport")
        XCTAssertTrue(waitForTerminalPosition(in: 0.95 ... 1.0, element: terminal), "Expected fixture to begin at the bottom")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Expected terminal keyboard to open")

        let pasteButton = app.buttons["terminal.paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 10), "Expected fixed terminal Paste action")
        XCTAssertTrue(waitForEnabled(pasteButton), "Expected terminal Paste action to accept plain text")
        let pasteCount = Int(pasteButton.value as? String ?? "") ?? 0
        pasteButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(of: pasteButton, above: pasteCount),
            "Expected terminal Paste action to receive the clipboard text"
        )
        attachScreenshot(named: "terminal-01-keyboard-bottom")

        let keyboardBottomPosition = terminalPosition(of: terminal)
        dragTerminal(terminal, fromY: 0.32, toY: 0.58)
        let didScrollUpWithKeyboard = waitForTerminalPosition(below: keyboardBottomPosition - 0.005, element: terminal)
        let keyboardScrolledPosition = terminalPosition(of: terminal)
        attachScreenshot(named: "terminal-02-keyboard-scrolled-up")
        XCTAssertTrue(
            didScrollUpWithKeyboard,
            "Expected swipe down to reveal earlier output with keyboard visible; position stayed at \(keyboardScrolledPosition) from \(keyboardBottomPosition)"
        )

        dragTerminal(terminal, fromY: 0.58, toY: 0.32)
        XCTAssertTrue(
            waitForTerminalPosition(above: keyboardScrolledPosition + 0.005, element: terminal),
            "Expected swipe up to move back toward recent terminal output with keyboard visible"
        )
        attachScreenshot(named: "terminal-03-keyboard-scrolled-down")

        let dismissKeyboard = app.buttons["terminal.keyboard.dismiss"]
        XCTAssertTrue(dismissKeyboard.waitForExistence(timeout: 10), "Expected fixed keyboard dismissal control")
        let dismissalCount = Int(dismissKeyboard.value as? String ?? "") ?? 0
        dismissKeyboard.tap()
        let didInvokeDismissal = waitForAccessibilityValue(of: dismissKeyboard, above: dismissalCount)
        attachScreenshot(named: "terminal-04-keyboard-dismiss-tapped")
        XCTAssertTrue(didInvokeDismissal, "Expected keyboard dismissal button action to run")
        XCTAssertTrue(waitForDisappearance(of: keyboard), "Expected keyboard dismissal control to close the keyboard")
        attachScreenshot(named: "terminal-05-keyboard-dismissed")

        let noKeyboardBottomPosition = terminalPosition(of: terminal)
        dragTerminal(terminal, fromY: 0.32, toY: 0.58)
        XCTAssertTrue(waitForDisappearance(of: keyboard), "Expected scrolling to keep the keyboard dismissed")
        let didScrollUpWithoutKeyboard = waitForTerminalPosition(below: noKeyboardBottomPosition - 0.005, element: terminal)
        let keyboardHiddenScrolledPosition = terminalPosition(of: terminal)
        attachScreenshot(named: "terminal-06-no-keyboard-scrolled-up")
        XCTAssertTrue(
            didScrollUpWithoutKeyboard,
            "Expected swipe down to reveal earlier output without keyboard; position stayed at \(keyboardHiddenScrolledPosition) from \(noKeyboardBottomPosition)"
        )

        dragTerminal(terminal, fromY: 0.58, toY: 0.32)
        XCTAssertTrue(waitForDisappearance(of: keyboard), "Expected reverse scrolling to keep the keyboard dismissed")
        XCTAssertTrue(
            waitForTerminalPosition(above: keyboardHiddenScrolledPosition + 0.005, element: terminal),
            "Expected swipe up to move toward recent output without the keyboard"
        )
        attachScreenshot(named: "terminal-07-no-keyboard-scrolled-down")

        terminal.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Expected tapping the terminal to reopen the keyboard")
        dismissKeyboard.tap()
        XCTAssertTrue(waitForDisappearance(of: keyboard), "Expected dismissal control to remain functional after reopening")
        attachScreenshot(named: "terminal-08-keyboard-redismissed")

        let initialFontSize = terminalFontSize(of: terminal)
        terminal.pinch(withScale: 0.7, velocity: -1)
        XCTAssertTrue(
            waitForTerminalFontSize(below: initialFontSize, element: terminal),
            "Expected pinch gesture to decrease terminal font size"
        )
    }

    @MainActor
    func testTerminalCopiesSelectedText() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "terminal"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.terminal"].waitForExistence(timeout: 10))
        let terminalRow = app.buttons.matching(identifier: "terminal.row").firstMatch
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 10), "Expected seeded terminal session row")
        terminalRow.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Expected terminal viewport")

        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(forDuration: 0.75)

        let selectionText = app.textViews["terminal.selection.text"]
        XCTAssertTrue(selectionText.waitForExistence(timeout: 10), "Expected terminal selection sheet")
        let copyButton = app.buttons["terminal.selection.copy"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 10), "Expected terminal Copy action")
        copyButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue(of: copyButton, above: 0),
            "Expected Copy to place the selected terminal text on the pasteboard"
        )

        let doneButton = app.buttons["terminal.selection.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 10), "Expected terminal selection Done action")
        doneButton.tap()
        XCTAssertTrue(waitForDisappearance(of: selectionText), "Expected Done to dismiss terminal selection")
    }

    @MainActor
    func testTerminalAgainstLocalBackend() {
        let app = XCUIApplication()
        let terminalTitle = "UI Terminal \(UUID().uuidString.prefix(8))"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_TERMINAL_TITLE"] = terminalTitle
        app.launch()

        let projectCell = app.staticTexts[projectDirectory]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 30), "Expected local project after auto-connect")
        projectCell.tap()

        let terminalTab = app.buttons["Terminal"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 20), "Expected Terminal project tab")
        terminalTab.tap()

        let terminalRows = app.buttons.matching(identifier: "terminal.row")
        let emptyCreateButton = app.buttons["terminal.create.empty"]
        XCTAssertTrue(
            terminalRows.firstMatch.waitForExistence(timeout: 10) || emptyCreateButton.exists,
            "Expected terminal list hydration to finish"
        )
        let createButton = app.buttons["terminal.create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 10), "Expected new terminal action")
        createButton.tap()
        let terminalRow = app.buttons[terminalTitle]
        let terminalList = app.descendants(matching: .any)["terminal.list"]
        for _ in 0 ..< 12 where !terminalRow.exists {
            terminalList.swipeUp()
        }
        XCTAssertTrue(terminalRow.waitForExistence(timeout: 20), "Expected a new terminal session row")
        terminalRow.tap()

        let terminal = app.descendants(matching: .any)["terminal.viewport"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), "Expected live terminal viewport")
        attachScreenshot(named: "terminal-live-01-prompt")
        XCTAssertTrue(
            waitForTerminalOutput(element: terminal),
            "Expected live PTY output; terminal state: \(terminal.label)"
        )

        terminal.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Expected terminal keyboard")

#if canImport(UIKit)
        UIPasteboard.general.string = "id"
#endif
        let pasteButton = app.buttons["terminal.paste"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 10), "Expected terminal Paste action")
        pasteButton.tap()
        XCTAssertTrue(
            waitForTerminalText("% id", element: terminal, timeout: 10),
            "Expected pasted command to reach the live terminal; terminal state: \(terminal.label)"
        )
        let returnKey = keyboard.buttons["return"]
        XCTAssertTrue(returnKey.waitForExistence(timeout: 10), "Expected software keyboard Return key")
        returnKey.tap()
        XCTAssertTrue(
            waitForTerminalText("uid=", element: terminal, timeout: 15),
            "Expected pasted id command to execute; terminal state: \(terminal.label)"
        )

        XCTAssertTrue(
            typeKeyboardKey("p", expecting: "% p", keyboard: keyboard, terminal: terminal),
            "Expected first command character; terminal state: \(terminal.label)"
        )
        XCTAssertTrue(
            typeKeyboardKey("w", expecting: "% pw", keyboard: keyboard, terminal: terminal),
            "Expected second command character"
        )
        XCTAssertTrue(
            typeKeyboardKey("d", expecting: "% pwd", keyboard: keyboard, terminal: terminal),
            "Expected complete command to echo"
        )
        attachScreenshot(named: "terminal-live-02-keyboard-echo")

        XCTAssertTrue(returnKey.waitForExistence(timeout: 10), "Expected software keyboard Return key")
        returnKey.tap()
        XCTAssertTrue(
            waitForTerminalText(projectDirectory, element: terminal, timeout: 15),
            "Expected Return to execute pwd; terminal state: \(terminal.label)"
        )
        attachScreenshot(named: "terminal-live-03-command-executed")

        let navigationBar = app.navigationBars[terminalTitle]
        XCTAssertTrue(navigationBar.waitForExistence(timeout: 10), "Expected terminal navigation bar")
        let backButton = navigationBar.buttons
            .matching(NSPredicate(format: "identifier != %@", "terminal.close"))
            .firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 10), "Expected terminal list back button")
        backButton.tap()

        let reopenedRow = app.buttons.matching(identifier: "terminal.row")
            .matching(NSPredicate(format: "label == %@", terminalTitle))
            .firstMatch
        XCTAssertTrue(reopenedRow.waitForExistence(timeout: 10), "Expected terminal row after navigating back")
        reopenedRow.tap()

        let reopenedTerminal = app.descendants(matching: .any)["terminal.viewport"]
        XCTAssertTrue(reopenedTerminal.waitForExistence(timeout: 10), "Expected reopened terminal viewport")
        XCTAssertTrue(
            waitForTerminalText(projectDirectory, element: reopenedTerminal, timeout: 15),
            "Expected reopened renderer to reconstruct terminal output; terminal state: \(reopenedTerminal.label)"
        )
        attachScreenshot(named: "terminal-live-04-reopened")

        reopenedTerminal.tap()
        let reopenedKeyboard = app.keyboards.firstMatch
        XCTAssertTrue(reopenedKeyboard.waitForExistence(timeout: 10), "Expected keyboard after reopening terminal")
        XCTAssertTrue(
            typeKeyboardKey("l", expecting: "% l", keyboard: reopenedKeyboard, terminal: reopenedTerminal),
            "Expected live input after reopening; terminal state: \(reopenedTerminal.label)"
        )
        XCTAssertTrue(
            typeKeyboardKey("s", expecting: "% ls", keyboard: reopenedKeyboard, terminal: reopenedTerminal),
            "Expected complete live input after reopening"
        )
        attachScreenshot(named: "terminal-live-05-reopened-keyboard-echo")
    }

    @MainActor
    func testCreateSessionAndSendMessageAgainstLocalBackend() {
        let app = XCUIApplication()
        let sessionTitle = "UI Test \(UUID().uuidString.prefix(8))"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        app.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: ui test ok"
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10))
        sessionCell.tap()

        let reply = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "ui test ok")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 60))
    }

    @MainActor
    func testLargeSessionBackgroundLifecycleAgainstLocalBackend() {
        let app = XCUIApplication()
        let hasExplicitBackend = nonEmptyEnvironmentValue("SNAPSHOT_OPENCODE_PASSWORD") != nil
            || nonEmptyEnvironmentValue("OPENCODE_UI_TEST_PASSWORD") != nil
        if hasExplicitBackend {
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
            app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
            app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
            app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
            app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "1"
        }
        app.launch()

        let projectCell = hasExplicitBackend
            ? app.staticTexts[projectDirectory]
            : app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 30), "Expected local project after auto-connect")
        projectCell.tap()

        let sessionCell = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Local chat cache with SwiftData"))
            .firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 30), "Expected the large cache reference session")
        sessionCell.tap()

        let chatMarker = app.buttons["chat.composer.menu"]
        XCTAssertTrue(chatMarker.waitForExistence(timeout: 30), "Expected the large chat composer")

        for _ in 0 ..< 3 {
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "Expected OpenClient to enter the background")
            app.activate()
            XCTAssertTrue(chatMarker.waitForExistence(timeout: 15), "Expected the large chat after returning to the foreground")
        }
    }

    @MainActor
    func testSecondMessageRendersSecondAssistantReplyAgainstLocalBackend() async throws {
        let app = XCUIApplication()
        let sessionTitle = "UI Followup \(UUID().uuidString.prefix(8))"
        let firstReply = "uireplyone\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondReply = "uireplytwo\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"

        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        app.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: \(firstReply)"
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 10))
        sessionCell.tap()

        XCTAssertTrue(waitForAssistantReply(firstReply, in: app, timeout: 90))

        try await sendPrompt("Reply with exactly: \(secondReply)", in: app)
        XCTAssertTrue(waitForAssistantReply(secondReply, in: app, timeout: 90))
    }

    @MainActor
    func testInlineVideoPlaysAgainstLocalBackend() async throws {
        guard let resourceID = nonEmptyEnvironmentValue("OPENCODE_UI_TEST_VIDEO_RESOURCE_ID") else {
            throw XCTSkip("Set OPENCODE_UI_TEST_VIDEO_RESOURCE_ID to a persisted video resource")
        }
        let app = XCUIApplication()
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launchEnvironment["OPENCODE_UI_TEST_VIDEO_RESOURCE_ID"] = resourceID
        app.launch()

        XCTAssertTrue(app.staticTexts["video.ui-test.ready"].waitForExistence(timeout: 30))

        let videoTitle = app.staticTexts["UI Test Earth Video"]
        XCTAssertTrue(videoTitle.waitForExistence(timeout: 10))
        videoTitle.tap()

        let playingVideo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND value == %@", "chat.tool.visual-video", "playing"))
            .firstMatch
        XCTAssertTrue(
            playingVideo.waitForExistence(timeout: 30),
            "Expected AVPlayer to advance"
        )
        attachScreenshot(named: "inline-video-playing")
    }

    @MainActor
    func testReconnectAndFollowupStillRendersAssistantReply() async throws {
        let sessionTitle = "UI Reconnect \(UUID().uuidString.prefix(8))"
        let firstReply = "uireconnectone\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondReply = "uireconnecttwo\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondPrompt = "Reply with exactly: \(secondReply)"

        let firstLaunch = XCUIApplication()
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_SESSION_TITLE"] = sessionTitle
        firstLaunch.launchEnvironment["OPENCODE_UI_TEST_PROMPT"] = "Reply with exactly: \(firstReply)"
        firstLaunch.launch()

        try await connectAndOpenSession(named: sessionTitle, in: firstLaunch)
        XCTAssertTrue(waitForAssistantReply(firstReply, in: firstLaunch, timeout: 90))
        let sessionID = try await waitForSessionID(named: sessionTitle)
        firstLaunch.terminate()

        let secondLaunch = XCUIApplication()
        secondLaunch.launch()

        try await reconnectIfNeeded(secondLaunch)
        try await openSessionIfVisible(named: sessionTitle, in: secondLaunch)
        try await sendPrompt(secondPrompt, in: secondLaunch)

        let rendered = waitForAssistantReply(secondReply, in: secondLaunch, timeout: 90)
        if !rendered {
            attachDebugLog(from: secondLaunch, named: "Reconnect Followup Debug Log")
            try await attachBackendMessages(for: sessionID, named: "Reconnect Selected Session Messages")
            try await attachPromptSearch(secondPrompt, named: "Reconnect Prompt Search")
        }
        XCTAssertTrue(rendered)
    }

    @MainActor
    func testManualSessionCreationAllowsSecondPromptInSameSession() async throws {
        let app = XCUIApplication()
        let sessionTitle = "UI Manual \(UUID().uuidString.prefix(8))"
        let firstPrompt = "uimanualfirst\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
        let secondPrompt = "uimanualsecond\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"

        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = baseURL.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_DIRECTORY"] = projectDirectory
        app.launch()

        let connectButton = app.buttons["connection.connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 10))
        connectButton.tap()

        let projectCell = app.staticTexts["opencode-ios-client"]
        XCTAssertTrue(projectCell.waitForExistence(timeout: 10))
        projectCell.tap()

        let createSessionButton = app.buttons["sessions.create"]
        XCTAssertTrue(createSessionButton.waitForExistence(timeout: 10))
        createSessionButton.tap()

        let titleField = app.textFields["sessions.create.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10))
        titleField.tap()
        titleField.typeText(sessionTitle)

        let confirmCreateButton = app.buttons["sessions.create.confirm"]
        XCTAssertTrue(confirmCreateButton.waitForExistence(timeout: 10))
        confirmCreateButton.tap()

        let createdSessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", sessionTitle)).firstMatch
        if createdSessionCell.waitForExistence(timeout: 10) {
            createdSessionCell.tap()
        }

        let sessionID = try await waitForSessionID(named: sessionTitle)
        try await sendPrompt(firstPrompt, in: app)
        let firstPersisted = try await waitForPromptPersistence(firstPrompt)
        XCTAssertEqual(
            firstPersisted.sessionID,
            sessionID,
            "First prompt persisted to unexpected session \(firstPersisted.sessionID), expected \(sessionID)"
        )

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 90))

        try await sendPrompt(secondPrompt, in: app)
        let secondPersisted = try await waitForPromptPersistence(secondPrompt)
        XCTAssertEqual(
            secondPersisted.sessionID,
            sessionID,
            "Second prompt persisted to unexpected session \(secondPersisted.sessionID), expected \(sessionID)"
        )
    }

    @MainActor
    private func sendPrompt(_ prompt: String, in app: XCUIApplication) async throws {
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText(prompt)

        let sendButton = app.buttons["chat.send"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        sendButton.tap()
    }

    @MainActor
    private func waitForAssistantReply(_ reply: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", reply)).firstMatch
        return text.waitForExistence(timeout: timeout)
    }

    @MainActor
    private func waitForTerminalPosition(in range: ClosedRange<Double>, element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitForTerminalPosition(element: element, timeout: timeout) { range.contains($0) }
    }

    @MainActor
    private func waitForTerminalPosition(below value: Double, element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitForTerminalPosition(element: element, timeout: timeout) { $0 < value }
    }

    @MainActor
    private func waitForTerminalPosition(above value: Double, element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        waitForTerminalPosition(element: element, timeout: timeout) { $0 > value }
    }

    @MainActor
    private func waitForTerminalPosition(
        element: XCUIElement,
        timeout: TimeInterval,
        matches: (Double) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if matches(terminalPosition(of: element)) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForTerminalText(_ text: String, element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.label.contains(text) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForTerminalOutput(element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.label.range(of: #"rx=([1-9][0-9]*)"#, options: .regularExpression) != nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func typeKeyboardKey(
        _ key: String,
        expecting text: String,
        keyboard: XCUIElement,
        terminal: XCUIElement
    ) -> Bool {
        for _ in 0 ..< 3 {
            keyboard.keys[key].tap()
            if waitForTerminalText(text, element: terminal, timeout: 3) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func dragTerminal(_ terminal: XCUIElement, fromY: CGFloat, toY: CGFloat) {
        let start = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fromY))
        let end = terminal.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: toY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func terminalPosition(of element: XCUIElement) -> Double {
        guard let value = element.value as? String else { return -1 }
        return Double(value) ?? -1
    }

    @MainActor
    private func terminalFontSize(of element: XCUIElement) -> Double {
        guard let match = element.label.range(of: #"font=([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression) else {
            return -1
        }
        return Double(element.label[match].dropFirst("font=".count)) ?? -1
    }

    @MainActor
    private func waitForTerminalFontSize(
        below value: Double,
        element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if terminalFontSize(of: element) >= 0, terminalFontSize(of: element) < value {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.isEnabled {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForAccessibilityValue(of element: XCUIElement, above value: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let current = Int(element.value as? String ?? "") ?? -1
            if current > value {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForAccessibilityValue(
        of element: XCUIElement,
        equalTo expectedValue: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if (element.value as? String) == expectedValue {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func connectAndOpenSession(named title: String, in app: XCUIApplication) async throws {
        let connectButton = app.buttons["connection.connect"]
        if connectButton.waitForExistence(timeout: 10) {
            connectButton.tap()
        } else {
            let reconnectButton = app.buttons["Reconnect"]
            XCTAssertTrue(reconnectButton.waitForExistence(timeout: 10))
            reconnectButton.tap()
        }

        let sessionCell = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", title))
            .firstMatch
        if sessionCell.waitForExistence(timeout: 5), sessionCell.isHittable {
            sessionCell.tap()
            return
        }
        if app.staticTexts["Loading chat..."].exists || app.textFields["chat.input"].exists {
            return
        }

        if !sessionCell.exists {
            let projectCell = app.staticTexts["opencode-ios-client"]
            if projectCell.waitForExistence(timeout: 10), projectCell.isHittable {
                projectCell.tap()
            }
        }
        if sessionCell.waitForExistence(timeout: 20), sessionCell.isHittable {
            sessionCell.tap()
            return
        }
        if !app.staticTexts["Loading chat..."].exists,
           !app.textFields["chat.input"].exists {
            attachScreenshot(named: "session-bootstrap-failure")
            let attachment = XCTAttachment(string: app.debugDescription)
            attachment.name = "Session Bootstrap Accessibility Tree"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTFail("Expected bootstrapped session \(title)")
            return
        }
    }

    @MainActor
    private func reconnectIfNeeded(_ app: XCUIApplication) async throws {
        let reconnectButton = app.buttons["Reconnect"]
        if reconnectButton.waitForExistence(timeout: 10) {
            reconnectButton.tap()
            return
        }

        let connectButton = app.buttons["connection.connect"]
        if connectButton.waitForExistence(timeout: 10) {
            connectButton.tap()
        }
    }

    @MainActor
    private func openSessionIfVisible(named title: String, in app: XCUIApplication) async throws {
        let projectCell = app.staticTexts["opencode-ios-client"]
        if projectCell.waitForExistence(timeout: 10) {
            projectCell.tap()
        }

        let sessionCell = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 20))
        sessionCell.tap()
    }

    @MainActor
    private func attachDebugLog(from app: XCUIApplication, named name: String) {
        let bugButton = app.buttons["chat.debugProbe"]
        guard bugButton.waitForExistence(timeout: 5) else { return }
        bugButton.tap()

        let logView = app.staticTexts["debugProbe.log"]
        guard logView.waitForExistence(timeout: 5) else { return }

        let attachment = XCTAttachment(string: logView.label)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachBackendMessages(for sessionID: String, named name: String) async throws {
        let messages = try await fetchMessages(sessionID: sessionID)
        let body = messages.map { envelope in
            let role = envelope.info.role ?? "?"
            let text = envelope.parts.compactMap(\.text).joined(separator: " | ")
            return "\(role)\t\(text)"
        }.joined(separator: "\n")

        let attachment = XCTAttachment(string: body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachPromptSearch(_ prompt: String, named name: String) async throws {
        let sessions = try await fetchSessions()
        var lines: [String] = []

        for session in sessions {
            let messages = try await fetchMessages(sessionID: session.id)
            let matching = messages.filter { envelope in
                envelope.parts.compactMap(\.text).joined(separator: "\n").contains(prompt)
            }
            guard !matching.isEmpty else { continue }

            lines.append("session=\(session.id) title=\(session.title ?? "")")
            lines.append(contentsOf: matching.map { envelope in
                let role = envelope.info.role ?? "?"
                let text = envelope.parts.compactMap(\.text).joined(separator: " | ")
                return "\(role)\t\(text)"
            })
        }

        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func waitForSessionID(named title: String) async throws -> String {
        let deadline = Date().addingTimeInterval(30)

        while Date() < deadline {
            let sessions = try await fetchSessions()
            if let sessionID = sessions.first(where: { $0.title == title })?.id {
                return sessionID
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        XCTFail("Timed out waiting for session \(title)")
        return ""
    }

    @MainActor
    private func waitForPromptPersistence(_ prompt: String) async throws -> PromptLocation {
        let deadline = Date().addingTimeInterval(45)

        while Date() < deadline {
            let sessions = try await fetchSessions()
            for session in sessions {
                let messages = try await fetchMessages(sessionID: session.id)
                if messages.contains(where: { $0.isUserPrompt(prompt) }) {
                    return PromptLocation(sessionID: session.id)
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        XCTFail("Timed out waiting for prompt persistence: \(prompt)")
        return PromptLocation(sessionID: "")
    }

    @MainActor
    private func fetchSessions() async throws -> [UITestSession] {
        var components = URLComponents(url: baseURL.appendingPathComponent("session"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "directory", value: projectDirectory)]
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url: try XCTUnwrap(components?.url)))
        try assertHTTP(response, data: data)
        return try JSONDecoder().decode([UITestSession].self, from: data)
    }

    @MainActor
    private func fetchMessages(sessionID: String) async throws -> [UITestMessageEnvelope] {
        let url = baseURL.appendingPathComponent("session").appendingPathComponent(sessionID).appendingPathComponent("message")
        let (data, response) = try await URLSession.shared.data(for: makeRequest(url: url))
        try assertHTTP(response, data: data)
        return try JSONDecoder().decode([UITestMessageEnvelope].self, from: data)
    }

    @MainActor
    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        return request
    }

    @MainActor
    private func assertHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            XCTFail("Missing HTTP response")
            return
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            XCTFail("Unexpected status \(http.statusCode): \(body)")
            return
        }
    }
}

private struct UITestSession: Decodable {
    let id: String
    let title: String?
}

private struct UITestMessageEnvelope: Decodable {
    struct Info: Decodable {
        let role: String?
    }

    struct Part: Decodable {
        let text: String?
    }

    let info: Info
    let parts: [Part]

    func isUserPrompt(_ prompt: String) -> Bool {
        guard (info.role ?? "").lowercased() == "user" else { return false }
        let text = parts.compactMap(\.text).joined(separator: "\n")
        return text.contains(prompt)
    }
}

private struct PromptLocation {
    let sessionID: String
}
