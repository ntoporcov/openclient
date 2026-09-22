import XCTest
@preconcurrency import Network
import ActivityKit
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
    func testBrowserAccessorySessionLayoutAndControls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "sessions"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["screenshot.scene.sessions"].waitForExistence(timeout: 15))
        let open = app.buttons["browser.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        let list = app.collectionViews.containing(.button, identifier: "session.row.session-screenshot-release").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let tabBar = app.tabBars.firstMatch
        let isPad = app.frame.width > 700
        let baselineTabFrame = tabBar.exists ? tabBar.frame : .zero
        let baselineListFrame = list.frame
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'"))
        let baselineIDs = rows.allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(baselineIDs.isEmpty)
        let showsTalk = app.buttons["sessions.newTalk"].exists

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        capture("Browser-sessions-initially-closed")
        for iteration in 0..<2 {
            open.tap()
            XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 5), app.debugDescription)
            let collapse = app.buttons["browser.collapse"].firstMatch
            XCTAssertTrue(collapse.isHittable)
            capture("Browser-sessions-expanded-\(iteration)")
            collapse.tap()
            XCTAssertTrue(app.textFields["browser.address"].waitForNonExistence(timeout: 5))
            let accessory = app.buttons["browser.projectAccessory"]
            if isPad {
                XCTAssertFalse(accessory.exists, "Regular iPad must use inspector controls, not a bottom accessory")
                open.tap()
                XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 5))
                app.buttons["browser.close"].firstMatch.tap()
            } else {
                XCTAssertTrue(accessory.waitForExistence(timeout: 5))
                XCTAssertEqual(accessory.label, "Expand browser")
                XCTAssertTrue(app.buttons["browser.close.accessory"].isHittable)
                capture("Browser-sessions-collapsed-\(iteration)")
                accessory.tap()
                XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 5))
                collapse.tap()
                XCTAssertTrue(app.buttons["browser.close.accessory"].waitForExistence(timeout: 5))
                app.buttons["browser.close.accessory"].tap()
                XCTAssertTrue(accessory.waitForNonExistence(timeout: 5))
                XCTAssertEqual(tabBar.frame.minY, baselineTabFrame.minY, accuracy: 1)
            }
            XCTAssertTrue(app.textFields["browser.address"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(rows.allElementsBoundByIndex.map(\.identifier), baselineIDs)
            XCTAssertEqual(list.frame, baselineListFrame)
            XCTAssertTrue(app.buttons["sessions.create"].isHittable)
            XCTAssertEqual(app.buttons["sessions.newTalk"].exists, showsTalk)
            if showsTalk { XCTAssertTrue(app.buttons["sessions.newTalk"].isHittable) }
            capture("Browser-sessions-after-close-\(iteration)")
        }
    }

    @MainActor
    func testLatestAnnouncementLocalizedLayoutAndDismissal() throws {
        let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("OpenCodeIOSClient/Localizable.xcstrings")
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for (language, accessibilitySize) in [("en", false), ("it", false), ("pt-BR", false), ("pt-BR", true)] {
            let profile = "announcement-\(language)-\(accessibilitySize ? "AXXXL" : "default")"
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "connection"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language,
                                   "-UIPreferredContentSizeCategoryName",
                                   accessibilitySize ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
            app.launch()
            XCTAssertTrue(app.staticTexts["screenshot.scene.connection"].waitForExistence(timeout: 15))
            let entry = app.buttons["help.latest-updates"]
            for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
            XCTAssertTrue(entry.isHittable)
            entry.tap()
            let done = app.buttons["new-features.continue"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            let scroll = app.scrollViews.firstMatch
            let keys = [
                "More control, at a glance",
                "Choose your composer",
                "Usage, without leaving OpenClient",
                "Home Screen widgets",
            ]
            XCTAssertFalse(app.descendants(matching: .any)["new-features.notifications-section"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["new-features.notification-setup"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["new-features.notification-guide"].exists)
            let initial = XCTAttachment(screenshot: app.screenshot())
            initial.name = "\(profile)-hero"
            initial.lifetime = .keepAlways
            add(initial)
            for (index, key) in keys.enumerated() {
                let localizations = try XCTUnwrap(strings[key]?["localizations"] as? [String: [String: Any]])
                let unit = try XCTUnwrap(localizations[language]?["stringUnit"] as? [String: String])
                let text = try XCTUnwrap(unit["value"])
                let card = index == 0
                    ? app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
                    : app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
                for _ in 0..<12 where !card.isHittable { scroll.swipeUp() }
                XCTAssertTrue(card.isHittable, "Expected reachable \(key) for \(profile)")
                for _ in 0..<12 where card.frame.maxY > done.frame.minY - 12 {
                    scroll.swipeUp()
                }
                XCTAssertLessThanOrEqual(card.frame.maxY, done.frame.minY, "Card detail must scroll clear of the footer")
                if index == 0 {
                    XCTAssertEqual(card.label, text)
                    if accessibilitySize {
                        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
                        let lineHeight = UIFont.preferredFont(forTextStyle: .title1, compatibleWith: traits).lineHeight
                        XCTAssertGreaterThan(card.frame.height, lineHeight * 1.5, "The full Portuguese title must wrap rather than truncate to one line")
                    }
                }
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "\(profile)-card-\(index)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "\(profile)-hierarchy-\(index)"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            XCTAssertTrue(done.isHittable)
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 5))
            XCTAssertTrue(entry.isHittable)
            app.terminate()
        }
    }

    @MainActor
    func testLatestAnnouncementComposerAndOpenAISetupStayInsideSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "connection"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.connection"].waitForExistence(timeout: 15))
        let entry = app.buttons["help.latest-updates"]
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()

        let composerPicker = app.segmentedControls["new-features.composer-style"]
        let isRunningOniPad = UIDevice.current.userInterfaceIdiom == .pad
            || environment["SIMULATOR_DEVICE_NAME"]?.localizedCaseInsensitiveContains("iPad") == true
        if !isRunningOniPad {
            XCTAssertTrue(composerPicker.waitForExistence(timeout: 5))
            let initialStyle = composerPicker.buttons.allElementsBoundByIndex.first(where: \.isSelected)?.label
            composerPicker.buttons["Assistant"].tap()
            let preview = app.descendants(matching: .any)["chat.appearance.composer-preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertTrue(preview.label.contains("Assistant composer preview"))
            attachScreenshot(named: "announcement-assistant-preview")
            composerPicker.buttons["Messenger"].tap()
            XCTAssertTrue(preview.label.contains("Messenger composer preview"))
            attachScreenshot(named: "announcement-messenger-preview")
            if let initialStyle { composerPicker.buttons[initialStyle].tap() }
        } else {
            XCTAssertFalse(composerPicker.exists)
            XCTAssertFalse(app.descendants(matching: .any)["new-features.composer-section"].exists)
        }

        let widgetGallery = app.descendants(matching: .any)["new-features.usage-widget-gallery"]
        let done = app.buttons["new-features.continue"]
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(widgetGallery.waitForExistence(timeout: 5))
        // XCTest can report content behind the pinned footer as hittable.
        for _ in 0..<10 where !widgetGallery.isHittable || widgetGallery.frame.maxY > done.frame.minY - 12 {
            scroll.swipeUp()
        }
        XCTAssertLessThan(widgetGallery.frame.maxY, done.frame.minY)
        XCTAssertTrue(app.descendants(matching: .any)["new-features.usage-widget-bars"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["new-features.usage-widget-rings"].exists)
        attachScreenshot(named: "announcement-usage-widget-previews")

        let setup = app.buttons["new-features.openai-usage-setup"]
        for _ in 0..<10 where !setup.isHittable || setup.frame.maxY > done.frame.minY - 12 {
            scroll.swipeUp()
        }
        XCTAssertTrue(setup.isHittable)
        XCTAssertLessThan(setup.frame.maxY, done.frame.minY)
        setup.tap()

        XCTAssertTrue(app.navigationBars["OpenAI"].waitForExistence(timeout: 5))
        attachScreenshot(named: "announcement-openai-setup")
        XCTAssertTrue(app.buttons["new-features.continue"].exists == false)
        app.navigationBars["OpenAI"].buttons.firstMatch.tap()
         XCTAssertTrue(app.buttons["new-features.continue"].waitForExistence(timeout: 5))
     }

    @MainActor
    func testLatestAnnouncementWidgetPreviewsBrazilianPortugueseAXXXLLayout() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "connection"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchArguments = ["-AppleLanguages", "(pt-BR)", "-AppleLocale", "pt-BR",
                               "-UIPreferredContentSizeCategoryName",
                               "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()

        XCTAssertTrue(app.staticTexts["screenshot.scene.connection"].waitForExistence(timeout: 15))
        let entry = app.buttons["help.latest-updates"]
        for _ in 0..<6 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.isHittable)
        entry.tap()

        let scroll = app.scrollViews.firstMatch
        let done = app.buttons["new-features.continue"]
        let gallery = app.descendants(matching: .any)["new-features.usage-widget-gallery"]
        let bars = app.descendants(matching: .any)["new-features.usage-widget-bars"]
        let rings = app.descendants(matching: .any)["new-features.usage-widget-rings"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 5))
        XCTAssertTrue(bars.waitForExistence(timeout: 5))
        XCTAssertTrue(rings.waitForExistence(timeout: 5))
        let initialBarsFrame = bars.frame
        let initialRingsFrame = rings.frame

        func reachPreview(_ preview: XCUIElement, named name: String) {
            for _ in 0..<16 {
                let previewFrame = preview.frame
                let scrollFrame = scroll.frame
                let footerTop = done.frame.minY - 12
                let horizontallyInsideScroll = previewFrame.minX >= scrollFrame.minX
                    && previewFrame.maxX <= scrollFrame.maxX
                if preview.isHittable && previewFrame.maxY <= footerTop && horizontallyInsideScroll {
                    break
                }

                if previewFrame.minY < scrollFrame.minY {
                    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38))
                    let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.52))
                    start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
                } else {
                    scroll.swipeUp(velocity: .slow)
                }
            }

            XCTAssertTrue(preview.isHittable, "Expected reachable \(name) preview")
            XCTAssertLessThanOrEqual(preview.frame.maxY, done.frame.minY - 12,
                                     "Expected \(name) preview above the pinned Continue button")
            XCTAssertGreaterThanOrEqual(preview.frame.minX, scroll.frame.minX,
                                        "Expected \(name) preview inside the scroll view horizontally")
            XCTAssertLessThanOrEqual(preview.frame.maxX, scroll.frame.maxX,
                                     "Expected \(name) preview inside the scroll view horizontally")
            attachScreenshot(named: "announcement-pt-BR-AXXXL-\(name)")
        }

        reachPreview(bars, named: "bars")
        reachPreview(rings, named: "rings")
        if initialBarsFrame != .zero && initialRingsFrame != .zero {
            XCTAssertLessThanOrEqual(initialBarsFrame.maxY, initialRingsFrame.minY,
                                     "Expected usage bars to appear above usage rings")
        }
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
    func testPromoIPadRoomScreenshot() throws {
        guard (environment["SIMULATOR_DEVICE_NAME"] ?? "").localizedCaseInsensitiveContains("iPad") else {
            throw XCTSkip("The three-column promo scene requires iPad")
        }

        setSnapshotLandscapeOutput(true)
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = XCUIApplication()
        setupSnapshot(app)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "ipad-room"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(
            app.staticTexts["screenshot.scene.ipad-room"].waitForExistence(timeout: 10),
            "Expected iPad room screenshot scene to load"
        )
        snapshot("25-ipad-room")
        app.terminate()
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
    func testNewSessionModelPickerNavigatesProviderTree() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "new-session"
        app.launch()

        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10))
        let modelTrigger = app.descendants(matching: .any)["projects.newChat.model"]
        XCTAssertTrue(modelTrigger.waitForExistence(timeout: 10))
        modelTrigger.tap()

        let anthropicMenu = app.collectionViews.buttons["Anthropic"]
        if anthropicMenu.waitForExistence(timeout: 2) {
            XCTAssertFalse(app.collectionViews.buttons["Model"].exists)
            anthropicMenu.tap()

            let option = app.buttons["Claude Sonnet 4.5"]
            XCTAssertTrue(option.waitForExistence(timeout: 10))
            option.tap()
            XCTAssertTrue(waitForAccessibilityValue(of: modelTrigger, equalTo: "Claude Sonnet 4.5"))
            return
        }

        XCTAssertFalse(app.buttons["projects.newChat.model.default"].exists)
        let search = app.searchFields["Search models"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Sonnet")

        let option = app.buttons["Claude Sonnet 4.5"]
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["projects.newChat.model.provider.anthropic"].exists)
        XCTAssertTrue(app.navigationBars["New Session"].exists)
        option.tap()

        XCTAssertTrue(modelTrigger.exists)
        XCTAssertTrue(waitForAccessibilityValue(of: modelTrigger, equalTo: "Claude Sonnet 4.5"))

        modelTrigger.tap()
        let anthropic = app.buttons["projects.newChat.model.provider.anthropic"]
        XCTAssertTrue(anthropic.waitForExistence(timeout: 10))
        anthropic.tap()

        let providerSearch = app.searchFields["Search models"]
        XCTAssertTrue(providerSearch.waitForExistence(timeout: 10))
        providerSearch.tap()
        providerSearch.typeText("GPT-5.4")
        XCTAssertTrue(app.staticTexts["No Models"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testNewSessionControlsRemainAboveKeyboard() {
        for locked in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "new-session"
            if locked {
                app.launchEnvironment["OPENCLIENT_UI_TEST_NEW_SESSION_LOCKED"] = "1"
            }
            app.launch()

            XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10))
            let input = app.textViews["chat.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10), "Expected enabled new-session composer")
            input.tap()

            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "Expected the real composer to show the software keyboard")
            let keyboardTop = keyboard.frame.minY
            let controlIDs = locked
                ? ["projects.newChat.project", "projects.newChat.worktree", "projects.newChat.agent", "projects.newChat.model", "projects.newChat.reasoning"]
                : ["projects.newChat.project.screenshot-project", "projects.newChat.worktree", "projects.newChat.agent", "projects.newChat.model", "projects.newChat.reasoning"]

            for identifier in controlIDs {
                let control = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(control.waitForExistence(timeout: 5), "Expected \(identifier) without scrolling")
                XCTAssertLessThanOrEqual(control.frame.maxY, keyboardTop, "Expected \(identifier) above the keyboard without scrolling")
            }

            if !locked {
                let leadingCard = app.buttons["projects.newChat.project.screenshot-project"]
                let selectorPanelLeadingEdge = (app.frame.width - 320) / 2
                XCTAssertEqual(leadingCard.frame.minX, selectorPanelLeadingEdge, accuracy: 1.5, "Initial project row must align with the selector panel")
            }

            attachScreenshot(named: "new-session-\(locked ? "locked-" : "")keyboard-controls")
            app.terminate()
        }
    }

    @MainActor
    func testNewSessionProjectCardsFillSheetViewport() {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "new-session"
        app.launchEnvironment["OPENCLIENT_UI_TEST_NEW_SESSION_PROJECT_POLISH"] = "1"
        app.launchEnvironment["OPENCLIENT_UI_TEST_DARK_MODE"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["New Session"].waitForExistence(timeout: 10))
        let input = app.textViews["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))

        let leadingCard = app.buttons["projects.newChat.project.screenshot-project"]
        XCTAssertTrue(leadingCard.waitForExistence(timeout: 5))
        XCTAssertEqual(leadingCard.frame.minX, (app.frame.width - 320) / 2, accuracy: 1.5)

        let longNameCard = app.buttons["projects.newChat.project.screenshot-long-project"]
        XCTAssertTrue(longNameCard.waitForExistence(timeout: 5), "The expanded lazy viewport must realize the trailing project")
        XCTAssertLessThanOrEqual(longNameCard.staticTexts.firstMatch.frame.height, 22, "Compact project names must stay on one line")

        let projectPicker = app.scrollViews["projects.newChat.project"]
        XCTAssertTrue(projectPicker.waitForExistence(timeout: 5))
        XCTAssertLessThan(longNameCard.frame.minX, projectPicker.frame.maxX, "The next project should peek into the sheet")
        XCTAssertGreaterThan(longNameCard.frame.maxX, projectPicker.frame.maxX, "The next project should remain partially offscreen")

        let docsCard = app.buttons["projects.newChat.project.screenshot-docs"]
        XCTAssertTrue(docsCard.waitForExistence(timeout: 5))
        docsCard.tap()
        XCTAssertTrue(docsCard.isSelected)
        attachScreenshot(named: "new-session-project-polish-dark-keyboard")
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
    func testV2GlobalSessionSmokeAgainstIsolatedBackend() async throws {
        continueAfterFailure = false
        guard let urlString = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_BASE_URL"),
              let username = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_USERNAME"),
              let password = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_PASSWORD") else {
            throw XCTSkip("Set OPENCODE_V2_TEST_BASE_URL, OPENCODE_V2_TEST_USERNAME, and OPENCODE_V2_TEST_PASSWORD for the isolated v2 smoke test")
        }
        let url = try XCTUnwrap(URL(string: urlString))
        // Never fall back to the normal local backend or allow a user server as a target.
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "V2UISmoke", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The v2 smoke test only permits http://127.0.0.1:14097 with isolated server storage."
            ])
        }
        let backend = V2SmokeBackend(baseURL: url, username: username, password: password)
        let location = try await backend.request("api/location")
        let project = try XCTUnwrap(location["project"] as? [String: Any])
        XCTAssertEqual(project["id"] as? String, "global", "Start the isolated server in a non-git workspace")
        let directory = try XCTUnwrap(location["directory"] as? String)
        XCTAssertFalse(directory.isEmpty)
        XCTAssertNotEqual(directory, "/", "Global session creation must resolve a concrete workspace")

        let runID = UUID().uuidString
        let title = "V2 UI Smoke \(runID)"
        let importedID = "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let importedTitle = "V2 UI Transcript \(runID)"
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Even an empty screenshot-scene value disables live home hydration/search.
        app.launchEnvironment.removeValue(forKey: "OPENCLIENT_SCREENSHOT_SCENE")
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = url.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"

        // Register before fixture creation, so navigation/assertion failures still clean up.
        // Search only our exact UUID title, never delete the difference between session lists.
        addTeardownBlock { @MainActor in
            app.terminate()
            var failures: [String] = []
            do {
                for session in try await backend.sessions(named: title) {
                    let id = try XCTUnwrap(session["id"] as? String)
                    do {
                        _ = try await backend.request("api/session/\(id)", method: "DELETE", allowsNotFound: true)
                    } catch {
                        failures.append("\(id): \(error.localizedDescription)")
                    }
                }
            } catch {
                failures.append("Created session lookup: \(error.localizedDescription)")
            }
            do {
                _ = try await backend.request("api/session/\(importedID)", method: "DELETE", allowsNotFound: true)
            } catch {
                failures.append("\(importedID): \(error.localizedDescription)")
            }
            XCTAssertTrue(failures.isEmpty, "Exact-session cleanup failed: \(failures.joined(separator: "; "))")
            XCUIDevice.shared.orientation = .portrait
        }

        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let regular = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)

        // Both entry points now use the rich composer. Sending would invoke a model;
        // validate configuration/cancellation, then create only an offline fixture via API.
        for entry in ["projects.newChat", "sessions.create"] {
            if entry == "sessions.create" {
                let global = app.staticTexts.matching(identifier: "Global").firstMatch
                try await waitForV2Smoke(in: app, "Expected Global project after cancelling home New Chat") {
                    global.exists && global.isHittable
                }
                global.tap()
            }
            let create = app.buttons[entry]
            try await waitForV2Smoke(in: app, "Expected enabled \(entry)", timeout: 20) {
                create.exists && create.isHittable && create.isEnabled
            }
            create.tap()
            try await waitForV2Smoke(in: app, "Expected rich New Session project, model, and agent controls") {
                app.navigationBars["New Session"].exists
                    && ["project", "model", "agent"].allSatisfy {
                        let control = app.descendants(matching: .any)["projects.newChat.\($0)"].firstMatch
                        return control.exists && control.isHittable
                    }
            }
            let rename = app.buttons["projects.newChat.navigationTitleButton"]
            try await waitForV2Smoke(in: app, "Expected editable new chat title") { rename.exists && rename.isHittable }
            rename.tap()
            let titleField = app.textFields["projects.newChat.titleField"]
            try await waitForV2Smoke(in: app, "Expected the rich composer title field") { titleField.exists && titleField.isHittable }
            titleField.typeText(title)
            XCTAssertEqual(titleField.value as? String, title)
            let send = app.buttons["chat.send"]
            try await waitForV2Smoke(in: app, "A title alone must leave the composer in its empty Dictate state") {
                app.buttons["chat.dictate"].exists && !send.exists
            }
            attachScreenshot(named: "v2-smoke-\(entry)-rich-new-chat")
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            try await waitForV2Smoke(in: app, "Expected New Chat cancellation") { cancel.exists && cancel.isHittable }
            cancel.tap()
            try await waitForV2Smoke(in: app, "Expected rich New Chat dismissal") { !titleField.exists }
        }
        let cancelledSessions = try await backend.sessions(named: title)
        XCTAssertTrue(cancelledSessions.isEmpty, "Cancelling either New Chat entry point must not create a server session")

        let created = try await backend.request("api/session", method: "POST", body: [
            "title": title, "location": ["directory": directory]
        ])
        let info = try XCTUnwrap(created["data"] as? [String: Any])
        XCTAssertEqual(info["projectID"] as? String, "global")
        XCTAssertEqual((info["location"] as? [String: Any])?["directory"] as? String, directory)

        let composer = app.buttons["chat.composer.menu"]
        let model = app.buttons[regular ? "chat.composer.model" : "chat.toolbar.model"]
        let agent = app.buttons[regular ? "chat.composer.agent" : "chat.toolbar.agent"]

        // Import a separate projected transcript; no prompt/turn endpoint or model invocation.
        let userText = "Imported smoke user \(runID)"
        let assistantText = "Imported smoke assistant \(runID)"
        _ = try await backend.importTranscript(info: info, sessionID: importedID, title: importedTitle,
                                              directory: directory, userText: userText, assistantText: assistantText)
        let persisted = try await backend.sessions(named: importedTitle)
        XCTAssertEqual(persisted.map { $0["id"] as? String }, [importedID], "The imported fixture must be discoverable before UI search")

        // Reconnect to exercise server hydration rather than relying on an import SSE event.
        app.terminate()
        app.launch()
        XCUIDevice.shared.orientation = regular ? .landscapeLeft : .portrait
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let search = app.textFields["projects.searchChats"]
        try await waitForV2Smoke(in: app, "Expected home chat search") { search.exists && search.isHittable }
        search.tap()
        search.typeText(importedTitle)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", importedTitle))
            .matching(NSPredicate(format: "identifier != %@", "session.row.\(importedID)")).firstMatch
        try await waitForV2Smoke(in: app, "Expected home search result for the unique imported title", timeout: 30) {
            row.exists && row.isHittable
        }
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists,
                       "Home search must filter out the unrelated fixture session")
        attachScreenshot(named: "v2-smoke-\(regular ? "regular" : "compact")-home-search")
        row.tap()
        let user = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", userText)).firstMatch
        let assistant = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", assistantText)).firstMatch
        try await waitForV2Smoke(in: app, "Expected imported user/assistant transcript and visible chat", timeout: 20) {
            user.exists && assistant.exists && composer.exists && composer.isHittable
        }
        try await waitForV2Smoke(in: app, "Expected visible model and agent menus in the imported chat", timeout: 30) {
            model.exists && agent.exists && model.isHittable && agent.isHittable
        }
        attachScreenshot(named: "v2-smoke-\(regular ? "regular" : "compact")-imported-transcript")

        app.terminate()
        app.launch()
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let activity = app.buttons["projects.activity"]
        try await waitForV2Smoke(in: app, "Expected Activity even though v2 does not support Live Activities") {
            activity.exists && activity.isHittable && activity.isEnabled
        }
        activity.tap()
        let activityRow = app.buttons["activity.session.\(importedID)"]
        try await waitForV2Smoke(in: app, "Expected Activity fixture title and hydrated assistant snippet", timeout: 30) {
            activityRow.exists && activityRow.isHittable
                && activityRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", importedTitle)).firstMatch.exists
                && activityRow.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", assistantText)).firstMatch.exists
        }
        attachScreenshot(named: "v2-smoke-\(regular ? "regular" : "compact")-activity-fixture")
        activityRow.press(forDuration: 1)
        try await waitForV2Smoke(in: app, "Expected ordinary Activity session actions without Live Activity capability") {
            app.buttons["Rename"].exists && app.buttons["Delete"].exists
        }
        XCTAssertFalse(app.buttons["Start Live"].exists)
        XCTAssertFalse(app.buttons["Stop Live"].exists)
        attachScreenshot(named: "v2-smoke-\(regular ? "regular" : "compact")-activity-actions")
        app.buttons["Rename"].tap()
        let renameAlert = app.alerts["Rename Session"]
        try await waitForV2Smoke(in: app, "Expected cancellable Activity rename") { renameAlert.exists }
        renameAlert.buttons["Cancel"].tap()
        try await waitForV2Smoke(in: app, "Expected Activity row after cancelling rename") { !renameAlert.exists && activityRow.isHittable }
        activityRow.tap()
        try await waitForV2Smoke(in: app, "Activity selection must open the imported transcript without another session-row tap", timeout: 20) {
            user.exists && assistant.exists && composer.exists && composer.isHittable
        }
        attachScreenshot(named: "v2-smoke-\(regular ? "regular" : "compact")-activity-opened-chat")
    }

    @MainActor
    func testV2ConfigurationAndTerminalSmokeAgainstIsolatedBackend() async throws {
        guard let urlString = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_BASE_URL"),
              let username = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_USERNAME"),
              let password = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_PASSWORD") else {
            throw XCTSkip("Set OPENCODE_V2_TEST_BASE_URL/USERNAME/PASSWORD for the isolated v2 feature smoke test")
        }
        let url = try XCTUnwrap(URL(string: urlString))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "V2UISmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Only the isolated server on port 14097 is permitted"])
        }
        let backend = V2SmokeBackend(baseURL: url, username: username, password: password)
        let location = try await backend.request("api/location")
        let directory = try XCTUnwrap(location["directory"] as? String)
        let root = "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass2-VwCj6l"
        let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
        let normalized = standardized.hasPrefix("/private/var/") ? String(standardized.dropFirst(8)) : standardized
        guard (location["project"] as? [String: Any])?["id"] as? String == "global",
              normalized == root || normalized.hasPrefix(root + "/") else {
            throw NSError(domain: "V2UISmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing a server outside the dedicated pass2 temporary root"])
        }
        let query = [URLQueryItem(name: "location[directory]", value: directory)]
        let integrationResponse = try await backend.request("api/integration", query: query)
        let integrations = try XCTUnwrap(integrationResponse["data"] as? [[String: Any]])
        let pluginResponse = try await backend.request("api/plugin", query: query)
        let plugins = try XCTUnwrap(pluginResponse["data"] as? [[String: Any]])
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let title = "V2 UI Terminal \(runID)"
        // Keep output markers on one rendered line in the portrait terminal viewport.
        let token = String(runID.prefix(12))
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment.removeValue(forKey: "OPENCLIENT_SCREENSHOT_SCENE")
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = url.absoluteString
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_TERMINAL_TITLE"] = title

        // Do not diff inventories: cleanup may delete only this run's exact title and cwd.
        addTeardownBlock { @MainActor in
            app.terminate()
            defer { XCUIDevice.shared.orientation = .portrait }
            for pty in try await backend.ptys(named: title, directory: directory) {
                let id = try XCTUnwrap(pty["id"] as? String)
                guard pty["cwd"] as? String == directory,
                      id.range(of: #"^pty_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                    throw NSError(domain: "V2UISmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Refusing PTY cleanup without exact ownership"])
                }
                _ = try await backend.request("api/pty/\(id)", method: "DELETE", query: query, allowsNotFound: true)
            }
        }

        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let regular = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let configurations = app.buttons["projects.configurations"]
        try await waitForV2Smoke(in: app, "Expected Configurations on the automatically detected v2 home screen") {
            configurations.exists && configurations.isHittable
        }
        configurations.tap()
        try await waitForV2Smoke(in: app, "Expected Configurations sheet") { app.navigationBars["Configurations"].exists }
        attachScreenshot(named: "v2-feature-configurations")

        @MainActor
        func reveal(_ element: XCUIElement) async throws {
            for _ in 0..<8 {
                if element.exists && element.isHittable { break }
                var form: XCUIElement?
                try await waitForV2Smoke(in: app, "Expected a configuration form containing identified controls") {
                    // A Form's container can be non-hittable while its rows are interactive.
                    // Match its controls instead of accidentally choosing the iPad sidebar.
                    form = [.collectionView, .scrollView, .table].lazy.flatMap { type in
                        app.descendants(matching: type).allElementsBoundByIndex
                    }.first { container in
                        container.frame.intersects(app.windows.firstMatch.frame)
                            && container.descendants(matching: .any)
                                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "configurations."))
                                .allElementsBoundByIndex.contains { $0.isHittable }
                    }
                    return form != nil
                }
                let scroll = try XCTUnwrap(form)
                scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)))
            }
            try await waitForV2Smoke(in: app, "Expected visible configuration control") {
                element.exists && element.isHittable && element.isEnabled
            }
        }

        @MainActor
        func backFromConfiguration(_ navigationTitle: String) async throws {
            let back = app.navigationBars[navigationTitle].buttons
                .matching(NSPredicate(format: "label != %@", "Done")).firstMatch
            try await waitForV2Smoke(in: app, "Expected configuration back navigation") { back.exists && back.isHittable }
            back.tap()
            try await waitForV2Smoke(in: app, "Expected the parent Configurations screen after Back") {
                let done = app.navigationBars["Configurations"].buttons["Done"]
                return done.exists && done.isHittable
                    && !app.switches["configurations.show-tool-calls"].exists
                    && !app.navigationBars["Add Provider"].exists
                    && !app.navigationBars["Plugins"].exists
            }
        }

        let globalSettings = app.buttons["configurations.global-settings"]
        try await reveal(globalSettings)
        globalSettings.tap()
        let chatAppearance = app.buttons["configurations.chat-appearance"]
        try await reveal(chatAppearance)
        chatAppearance.tap()
        let toggleIDs = ["configurations.show-tool-calls", "configurations.show-reasoning-blocks"]
        var initialValues: [String: String] = [:]
        for id in toggleIDs {
            let toggle = app.switches[id]
            try await reveal(toggle)
            let initial = try XCTUnwrap(toggle.value as? String)
            XCTAssertTrue(["0", "1"].contains(initial))
            initialValues[id] = initial
            let control = toggle.switches.firstMatch
            try await waitForV2Smoke(in: app, "Expected the native switch control") { control.exists && control.isHittable }
            control.tap()
            try await waitForV2Smoke(in: app, "Expected local appearance toggle to change") { toggle.value as? String != initial }
        }
        try await backFromConfiguration("Appearance Settings")
        try await backFromConfiguration("Configurations")
        try await reveal(globalSettings)
        globalSettings.tap()
        try await reveal(chatAppearance)
        chatAppearance.tap()
        for id in toggleIDs {
            let toggle = app.switches[id]
            try await reveal(toggle)
            XCTAssertNotEqual(toggle.value as? String, initialValues[id], "Local preferences survive reopening Global Settings")
            let control = toggle.switches.firstMatch
            try await waitForV2Smoke(in: app, "Expected the native switch control") { control.exists && control.isHittable }
            control.tap()
            try await waitForV2Smoke(in: app, "Expected local preference restoration") { toggle.value as? String == initialValues[id] }
        }
        attachScreenshot(named: "v2-feature-global-settings-restored")
        try await backFromConfiguration("Appearance Settings")
        try await backFromConfiguration("Configurations")
        let providers = app.buttons["configurations.addProvider"]
        try await reveal(providers)
        XCTAssertTrue(providers.label.contains("Add Provider"))
        providers.tap()
        try await waitForV2Smoke(in: app, "Expected v1-parity Add Provider screen") {
            app.descendants(matching: .any)["configurations.v2.providers"].exists
                && app.navigationBars["Add Provider"].exists
        }
        let popularProvider = try XCTUnwrap(integrations.first { $0["id"] as? String == "openai" }, "The isolated catalog must contain known Popular provider OpenAI")
        let providerText = try XCTUnwrap(popularProvider["name"] as? String)
        try await waitForV2Smoke(in: app, "Expected discovered OpenAI in the visible Popular group", timeout: 20) {
            app.staticTexts[providerText].exists && app.staticTexts[providerText].isHittable
                && app.staticTexts["Popular"].exists && !app.buttons["Try Again"].exists
        }
        // Logos are intentionally hidden from accessibility; retain the shared row rendering for visual review.
        attachScreenshot(named: "v2-feature-add-provider-popular-logos")
        let otherProvider = try XCTUnwrap(integrations.first { $0["id"] as? String == "302ai" }, "The isolated catalog must contain Other provider 302.AI")
        let otherName = try XCTUnwrap(otherProvider["name"] as? String)
        let providerSearch = app.searchFields.firstMatch
        let providerList = app.collectionViews["configurations.v2.providers"]
        for _ in 0..<2 where !providerSearch.exists || !providerSearch.isHittable {
            providerList.swipeDown()
        }
        try await waitForV2Smoke(in: app, "Expected provider catalog search") { providerSearch.exists && providerSearch.isHittable }
        providerSearch.tap()
        providerSearch.typeText(otherName)
        try await waitForV2Smoke(in: app, "Expected searched provider in Other, not the initial offscreen catalog row") {
            app.staticTexts[otherName].exists && app.staticTexts[otherName].isHittable
                && app.staticTexts["Other"].exists && !app.staticTexts[providerText].exists
        }
        attachScreenshot(named: "v2-feature-add-provider-other-search")
        if !app.navigationBars["Add Provider"].exists {
            let closeSearch = app.toolbars.buttons["close"]
            try await waitForV2Smoke(in: app, "Expected native search dismissal before navigating back") {
                closeSearch.exists && closeSearch.isHittable
            }
            closeSearch.tap()
        }
        // Do not open authentication methods or mutate stored/environment credentials.
        try await backFromConfiguration("Add Provider")
        let pluginsLink = app.buttons["configurations.plugins"]
        try await reveal(pluginsLink)
        pluginsLink.tap()
        let firstPlugin = plugins.first
        let source = firstPlugin?["source"] as? [String: Any]
        let pluginText = source?["target"] as? String ?? source?["path"] as? String
            ?? firstPlugin?["id"] as? String ?? source?["type"] as? String ?? "No Plugins"
        try await waitForV2Smoke(in: app, "Expected v2 plugin discovery rather than legacy endpoint failure", timeout: 20) {
            app.navigationBars["Plugins"].exists && app.staticTexts[pluginText].exists
                && !app.staticTexts["Plugins Unavailable"].exists
        }
        attachScreenshot(named: "v2-feature-plugins")
        try await backFromConfiguration("Plugins")
        let done = app.navigationBars["Configurations"].buttons["Done"]
        try await waitForV2Smoke(in: app, "Expected Configurations Done action") { done.exists && done.isHittable }
        done.tap()
        let global = app.staticTexts.matching(identifier: "Global").firstMatch
        try await waitForV2Smoke(in: app, "Expected Global project after closing Configurations") { global.exists && global.isHittable }
        global.tap()

        if regular {
            let mode = app.buttons["project.mode.menu"]
            try await waitForV2Smoke(in: app, "Expected iPad project mode menu") { mode.exists && mode.isHittable }
            mode.tap()
        }
        let terminalTab = regular ? app.buttons["project.tab.terminal"] : app.buttons["Terminal"]
        try await waitForV2Smoke(in: app, "Expected Terminal tab for the resolved Global directory") {
            terminalTab.exists && terminalTab.isHittable
        }
        terminalTab.tap()
        let create = app.buttons["terminal.create"]
        try await waitForV2Smoke(in: app, "Expected enabled terminal creation") { create.exists && create.isHittable && create.isEnabled }
        create.tap()
        let row = app.buttons.matching(identifier: "terminal.row").matching(NSPredicate(format: "label == %@", title)).firstMatch
        try await waitForV2Smoke(in: app, "Expected exact newly created terminal row", timeout: 20) { row.exists && row.isHittable }
        row.tap()
        let terminal = app.descendants(matching: .any)["terminal.viewport"]
        try await waitForV2Smoke(in: app, "Expected live attached terminal renderer", timeout: 20) {
            terminal.exists && terminal.label.contains("surface=attached")
                && terminal.label.range(of: #"rx=([1-9][0-9]*)"#, options: .regularExpression) != nil
        }

        @MainActor
        func sendMarker(_ prefix: String) async throws {
            terminal.tap()
            let keyboard = app.keyboards.firstMatch
            try await waitForV2Smoke(in: app, "Expected terminal software keyboard") { keyboard.exists }
            // Splitting the marker prevents input echo from masquerading as command execution.
            terminal.typeText("printf '\\n%s%s\\n' '\(prefix)' '\(token)'")
            let returnKey = keyboard.buttons["return"]
            try await waitForV2Smoke(in: app, "Expected terminal Return key") { returnKey.exists && returnKey.isHittable }
            returnKey.tap()
            try await waitForV2Smoke(in: app, "Expected executed terminal marker", timeout: 20) { terminal.label.contains(prefix + token) }
        }
        try await sendMarker("V2_UI_FIRST_")
        attachScreenshot(named: "v2-feature-\(regular ? "ipad" : "iphone")-terminal-output")
        let dismissKeyboard = app.buttons["terminal.keyboard.dismiss"]
        let dismissalCount = Int(dismissKeyboard.value as? String ?? "") ?? 0
        dismissKeyboard.tap()
        try await waitForV2Smoke(in: app, "Expected keyboard-dismiss action rather than a terminal key") {
            (Int(dismissKeyboard.value as? String ?? "") ?? 0) > dismissalCount
        }
        try await waitForV2Smoke(in: app, "Expected terminal keyboard dismissal") { !app.keyboards.firstMatch.exists }
        attachScreenshot(named: "v2-feature-terminal-keyboard-dismissed")

        // A fresh app process guarantees a new renderer/socket even on a split-view iPad.
        app.terminate()
        app.launch()
        XCUIDevice.shared.orientation = regular ? .landscapeLeft : .portrait
        try await connectV2SmokeAndSelectGlobal(in: app)
        if regular {
            let mode = app.buttons["project.mode.menu"]
            try await waitForV2Smoke(in: app, "Expected project mode menu after reconnect") { mode.exists && mode.isHittable }
            if !mode.label.contains("Terminal") {
                mode.tap()
                let tab = app.buttons["project.tab.terminal"]
                try await waitForV2Smoke(in: app, "Expected iPad Terminal menu item after reconnect") { tab.exists && tab.isHittable }
                tab.tap()
            }
        } else {
            let tab = app.buttons["Terminal"]
            try await waitForV2Smoke(in: app, "Expected Terminal tab after reconnect") { tab.exists && tab.isHittable }
            tab.tap()
        }
        try await waitForV2Smoke(in: app, "Expected the same terminal after reconnect", timeout: 20) { row.exists && row.isHittable }
        row.tap()
        try await waitForV2Smoke(in: app, "Expected renderer replay after reconnect", timeout: 20) {
            terminal.exists && terminal.label.contains("surface=attached") && terminal.label.contains("V2_UI_FIRST_" + token)
        }
        try await sendMarker("V2_UI_RESUMED_")
        let owned = try await backend.ptys(named: title, directory: directory)
        XCTAssertEqual(owned.count, 1, "Reconnecting must reuse the PTY rather than create another shell")
        attachScreenshot(named: "v2-feature-\(regular ? "ipad" : "iphone")-terminal-reconnected")
    }

    @MainActor
    func testV2ColdShareComposerStaysBlockedForUnvalidatedConnectionAgainstIsolatedBackend() async throws {
        try await assertV2UnvalidatedShareComposer(cold: true)
    }

    @MainActor
    func testV2WarmShareComposerStaysBlockedForUnvalidatedConnectionAgainstIsolatedBackend() async throws {
        try await assertV2UnvalidatedShareComposer(cold: false)
    }

    @MainActor
    func testV2WarmValidSharePreservesEditedTextAndImageAndRevalidatesTargetWithoutSendingAgainstIsolatedBackend() async throws {
        guard nonEmptyEnvironmentValue("OPENCODE_PASS5_SHARE_SEED_HOOK") == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCODE_PASS5_SHARE_SEED_HOOK=1 to opt into DEBUG storage-seeded share UI coverage")
        }
        let (backend, app, _) = try await isolatedV2FeatureContext()
        let token = UUID().uuidString
        let id = "pass5-ui-\(token)"
        let text = "Pass5 valid shared draft \(token)"
        let filename = "pass5-image-\(token).png"
        let title = "Pass5 Share Cancel \(token)"
        let base = try XCTUnwrap(app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"])
        let username = try XCTUnwrap(app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"])
        let serverID = "\(base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        // Generate a real, recognizable PNG entirely in the runner, not an invalid
        // base64 stand-in that would exercise only the attachment fallback icon.
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.scale = 1
        imageFormat.opaque = true
        imageFormat.preferredRange = .standard
        let png = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80), format: imageFormat).pngData { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            UIColor.cyan.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            context.fill(CGRect(x: 40, y: 40, width: 40, height: 40))
        }
        let payload: [String: Any] = [
            "id": id, "serverID": serverID, "text": text,
            "attachments": [["filename": filename, "mime": "image/png", "dataURL": "data:image/png;base64,\(png.base64EncodedString())"]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertLessThan(data.count, 1_000_000, "Keep the fixture within the DEBUG seed hook's limit")
        app.launchEnvironment["OPENCODE_UI_TEST_SHARE_PAYLOAD"] = String(decoding: data, as: UTF8.self)
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "OPENCODE_UI_TEST_SHARE_PAYLOAD")
            app.launchEnvironment["OPENCODE_UI_TEST_SHARE_CLEANUP_ID"] = id
            app.launch()
            XCTAssertTrue(app.collectionViews["connection.form"].waitForExistence(timeout: 10), "Expected exact-payload cleanup bootstrap to finish")
            app.terminate()
        }
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        app.launchEnvironment.removeValue(forKey: "OPENCODE_UI_TEST_SHARE_PAYLOAD")
        let connectionForm = try XCTUnwrap(app.collectionViews.allElementsBoundByIndex.first {
            $0.identifier == "connection.form"
        })
        for _ in 0..<6 {
            if app.textFields["connection.baseURL"].exists && app.textFields["connection.username"].exists { break }
            connectionForm.swipeDown()
        }
        try await waitForV2Smoke(in: app, "Expected the actual connection URL and username fields after layout") {
            app.textFields["connection.baseURL"].exists && app.textFields["connection.username"].exists
        }
        let configuredURL = try XCTUnwrap(app.textFields["connection.baseURL"].value as? String)
        let configuredUsername = try XCTUnwrap(app.textFields["connection.username"].value as? String)
        XCTAssertEqual("\(configuredURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(configuredUsername.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())", serverID,
                       "The payload identity must match the actual URL/username fields, not the server's display name")
        // Only the normal connection UI may save the server and its Keychain password.
        try await connectV2SmokeAndSelectGlobal(in: app)
        let before = try await backend.sessions(named: title)
        XCTAssertTrue(before.isEmpty)
        var components = URLComponents()
        components.scheme = "openclient"
        components.host = "share"
        components.queryItems = [.init(name: "id", value: id), .init(name: "server", value: serverID)]
        let validURL = try XCTUnwrap(components.url)
        XCTAssertEqual(app.state, .runningForeground, "This must be a warm delivery into the normally connected app")
        try await deliverV2WarmURL(validURL, in: app)
        let input = app.textViews["chat.input"].firstMatch
        let send = app.buttons["chat.send"].firstMatch
        let retry = app.buttons["Retry"].firstMatch
        try await waitForV2Smoke(in: app, "The saved v2 target must validate before enabling the shared composer", timeout: 20) {
            input.exists && (input.value as? String) == text && send.exists && send.isEnabled
                && !retry.exists && !app.staticTexts["Connecting..."].exists
        }
        XCTAssertFalse(app.collectionViews["connection.form"].exists, "Warm URL delivery must retain the connected app, not relaunch its test bootstrap")
        let rename = app.buttons["projects.newChat.navigationTitleButton"]
        try await waitForV2Smoke(in: app, "Expected editable title on the validated shared draft") { rename.exists && rename.isHittable }
        rename.tap()
        let titleField = app.textFields["projects.newChat.titleField"]
        try await waitForV2Smoke(in: app, "Expected shared draft title field") { titleField.exists && titleField.isHittable }
        titleField.typeText(title)
        XCTAssertEqual(titleField.value as? String, title)
        titleField.typeText("\n")
        try await waitForV2Smoke(in: app, "Expected the validated text composer after title editing") { input.isHittable && send.isEnabled }
        input.tap()
        let typedSuffix = " typed-\(token)"
        input.typeText(typedSuffix)
        let editedText = try XCTUnwrap(input.value as? String)
        XCTAssertTrue(editedText.contains(typedSuffix))
        XCTAssertEqual(editedText.replacingOccurrences(of: typedSuffix, with: ""), text)

        // A conflicting URL invalidates the already accepted draft. Redelivering
        // the original URL must revalidate, not leave stale readiness/error state.
        components.queryItems = [.init(name: "id", value: id), .init(name: "server", value: "pass5-missing-\(token)")]
        try await deliverV2WarmURL(try XCTUnwrap(components.url), in: app)
        let mismatch = app.staticTexts["The shared content and link specify different connections."].firstMatch
        try await waitForV2Smoke(in: app, "A conflicting share target must disable Send without replacing edited text") {
            send.exists && !send.isEnabled && retry.exists && mismatch.exists && (input.value as? String) == editedText
        }
        try await deliverV2WarmURL(validURL, in: app)
        try await waitForV2Smoke(in: app, "Revalidated target must clear the mismatch and retain the edited shared draft") {
            send.isEnabled && !retry.exists && !mismatch.exists && (input.value as? String) == editedText
        }

        // Image cards currently expose no filename identifier. Scope to the single
        // square thumbnail in the horizontal attachment rail, then verify the exact
        // filename/MIME in its real preview rather than counting arbitrary images.
        try await waitForV2Smoke(in: app, "Expected a visible shared image card after revalidation") {
            app.scrollViews.buttons.allElementsBoundByIndex.contains {
                $0.isHittable && abs($0.frame.width - 140) < 2 && abs($0.frame.height - 140) < 2
            }
        }
        let thumbnails = app.scrollViews.buttons.allElementsBoundByIndex.filter {
            $0.isHittable && abs($0.frame.width - 140) < 2 && abs($0.frame.height - 140) < 2
        }
        XCTAssertEqual(thumbnails.count, 1, "Expected the one square shared PNG thumbnail")
        let thumbnail = try XCTUnwrap(thumbnails.first)
        attachScreenshot(named: "v2-pass5-valid-share-edited-text-and-checkerboard")
        thumbnail.tap()
        let preview = app.scrollViews.containing(.staticText, identifier: filename).firstMatch
        try await waitForV2Smoke(in: app, "Expected the preserved PNG's filename and MIME in attachment preview") {
            preview.exists && preview.staticTexts[filename].exists && preview.staticTexts["image/png"].exists
        }
        attachScreenshot(named: "v2-pass5-valid-share-image-preview")
        // The content swipe stayed inside the preview's ScrollView on both devices.
        // Drag from the sheet's top edge, above the PNG, to dismiss the presentation.
        preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
            .press(forDuration: 0.05, thenDragTo: preview.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        try await waitForV2Smoke(in: app, "Dismiss image preview back to the same validated shared draft") {
            !preview.exists && send.isHittable && send.isEnabled && (input.value as? String) == editedText
        }
        attachScreenshot(named: "v2-pass5-valid-share-preview-dismissed-draft-preserved")
        let cancel = app.navigationBars.buttons["Cancel"].firstMatch
        try await waitForV2Smoke(in: app, "Expected cancellation without submitting the validated shared draft") { cancel.exists && cancel.isHittable }
        cancel.tap()
        try await waitForV2Smoke(in: app, "Cancelling must clear the shared composer and its routing error") {
            !input.exists && !send.exists && !retry.exists && !mismatch.exists
        }
        let after = try await backend.sessions(named: title)
        XCTAssertTrue(after.isEmpty, "Previewing, editing, revalidating, and cancelling must not create a server session")
        attachScreenshot(named: "v2-pass5-valid-share-cancelled-no-session-created")
    }

    @MainActor
    private func assertV2UnvalidatedShareComposer(cold: Bool) async throws {
        // The DEBUG startup hook seeds storage only; it cannot authorize the handoff.
        // DEBUG + OPENCODE_UI_TEST_MODE=1 startup saves the JSON environment payload
        // through OpenClientSharePayloadStore before presenting root content. A cleanup
        // launch removes only OPENCODE_UI_TEST_SHARE_CLEANUP_ID via that same store.
        // The hook never changes readiness or routes the URL. Only the intentional
        // cold delivery uses app.open, which launches a fresh process on this SDK.
        guard nonEmptyEnvironmentValue("OPENCODE_PASS5_SHARE_SEED_HOOK") == "1" else {
            throw XCTSkip("Set TEST_RUNNER_OPENCODE_PASS5_SHARE_SEED_HOOK=1 to opt into DEBUG storage-seeded share UI coverage")
        }
        let (_, app, _) = try await isolatedV2FeatureContext()
        let token = UUID().uuidString
        let id = "pass5-ui-\(token)"
        let missingServer = "pass5-missing-\(token)"
        let text = "Pass5 shared draft \(token)"
        let payload: [String: Any] = [
            "id": id, "serverID": missingServer, "text": text, "attachments": []
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        app.launchEnvironment["OPENCODE_UI_TEST_SHARE_PAYLOAD"] = String(decoding: data, as: UTF8.self)
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "OPENCODE_UI_TEST_SHARE_PAYLOAD")
            app.launchEnvironment["OPENCODE_UI_TEST_SHARE_CLEANUP_ID"] = id
            app.launch()
            XCTAssertTrue(app.collectionViews["connection.form"].waitForExistence(timeout: 10), "Expected cleanup bootstrap to finish")
            app.terminate()
        }
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        app.launchEnvironment.removeValue(forKey: "OPENCODE_UI_TEST_SHARE_PAYLOAD")
        if cold {
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
        } else {
            try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
            XCTAssertEqual(app.state, .runningForeground)
        }
        var components = URLComponents()
        components.scheme = "openclient"
        components.host = "share"
        components.queryItems = [.init(name: "id", value: id), .init(name: "server", value: missingServer)]
        let url = try XCTUnwrap(components.url)
        if cold {
            app.open(url)
        } else {
            try await deliverV2WarmURL(url, in: app)
        }
        let input = app.textViews["chat.input"].firstMatch
        let send = app.buttons["chat.send"].firstMatch
        try await waitForV2Smoke(in: app, "Expected retained share draft with blocked composer after connection validation fails", timeout: 20) {
            input.exists && (input.value as? String) == text
                && send.exists && !send.isEnabled
                && app.buttons["Retry"].firstMatch.exists
        }
        if !cold {
            XCTAssertFalse(app.collectionViews["connection.form"].exists, "Warm failure must not silently become a cold-share test")
        }
        // Re-delivering the same unresolved payload must not enable Send or replace it.
        try await deliverV2WarmURL(url, in: app)
        try await waitForV2Smoke(in: app, "Repeated share delivery must remain blocked and retain the draft") {
            (input.value as? String) == text && !send.isEnabled && app.buttons["Retry"].firstMatch.exists
        }
        attachScreenshot(named: "v2-pass5-\(cold ? "cold" : "warm")-share-validation-blocked")
        let cancel = app.navigationBars.buttons["Cancel"].firstMatch
        try await waitForV2Smoke(in: app, "Expected cancellable unvalidated share preview") { cancel.exists && cancel.isHittable }
        cancel.tap()
        try await waitForV2Smoke(in: app, "Cancel must dismiss the shared composer without submitting") { !input.exists }
    }

    @MainActor
    private func deliverV2WarmURL(_ url: URL, in app: XCUIApplication) async throws {
        guard url.scheme == "openclient", ["share", "widget"].contains(url.host ?? ""), app.state == .runningForeground else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Warm URL delivery requires an already running foreground app"])
        }
        @MainActor
        func processID() throws -> String {
            let hierarchy = app.debugDescription
            let range = try XCTUnwrap(hierarchy.range(of: #"pid: [0-9]+"#, options: .regularExpression),
                                      "Expected the app process ID in the XCTest hierarchy")
            return String(hierarchy[range])
        }
        let originalPID = try processID()
        // XCUIApplication.open relaunches the target in pass5-ui-1's execution log,
        // clearing saved-server metadata in its UI-test initializer. Route through
        // XCTest's synchronous system API, not UIKit in the sandboxed runner (UI2
        // never completed that callback). Keep process identity proof on every call.
        XCUIDevice.shared.system.open(url)
        // UI3's first iPhone redelivery displayed an OS confirmation. Without
        // accepting it, unchanged content can falsely pass behind the alert and
        // XCTest's default interruption handler later cancels the URL delivery.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirmation = springboard.alerts.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "OpenCodeIOSClientUITests-Runner", "wants to open", "OpenClient"
        )).firstMatch
        if confirmation.waitForExistence(timeout: 2) {
            let open = confirmation.buttons["Open"]
            try await waitForV2Smoke(in: app, "Expected permission to open only OpenClient from the test runner") { open.exists && open.isHittable }
            open.tap()
            try await waitForV2Smoke(in: app, "Expected the OpenClient URL confirmation to dismiss") { !confirmation.exists }
        }
        try await waitForV2Smoke(in: app, "Expected the running app to receive the warm URL") { app.state == .runningForeground }
        let deliveredPID = try processID()
        let delivery = XCTAttachment(string: "Warm \(url.host ?? "") URL delivery: before=\(originalPID), after=\(deliveredPID)")
        delivery.name = url.host == "widget" ? "v2-pass7-widget-process-identity" : "v2-pass5-warm-share-process-identity"
        delivery.lifetime = .keepAlways
        add(delivery)
        guard deliveredPID == originalPID else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Warm URL delivery unexpectedly replaced the app process"])
        }
    }

    @MainActor
    func testV2TalkChooserCancelsAndExistingChatExposesTalkWithoutRecordingAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let talk = app.buttons["projects.newTalk"]
        try await waitForV2Smoke(in: app, "Expected enabled home New Talk on v2") {
            talk.exists && talk.isHittable && talk.isEnabled
        }
        talk.tap()
        let picker = app.descendants(matching: .any)["talk.projectPicker"].firstMatch
        let stop = app.buttons["Stop Conversation"].firstMatch
        try await waitForV2Smoke(in: app, "Expected cancellable Talk project chooser") {
            picker.exists && app.buttons["talk.project.global"].exists && stop.isHittable
        }
        // Selecting a project starts audio. Only the chooser is exercised here.
        XCTAssertFalse(app.buttons["chat.conversation.stop"].exists)
        attachScreenshot(named: "v2-pass5-talk-chooser-no-recording")
        stop.tap()
        try await waitForV2Smoke(in: app, "Cancelling Talk must restore home") { !picker.exists && talk.isHittable }

        let search = app.textFields["projects.searchChats"]
        search.tap()
        search.typeText(fixture.title)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@",
                                                  fixture.title, "session.row.\(fixture.sessionID)")).firstMatch
        try await waitForV2Smoke(in: app, "Expected owned chat search result", timeout: 30) { row.exists && row.isHittable }
        row.tap()
        let existingTalk = app.buttons["chat.conversation.start"]
        try await waitForV2Smoke(in: app, "Expected existing-chat Talk availability without starting audio", timeout: 20) {
            existingTalk.exists && existingTalk.isHittable && existingTalk.isEnabled
                && app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch.exists
        }
        XCTAssertFalse(app.descendants(matching: .any)["chat.conversation.immersive"].exists)
        attachScreenshot(named: "v2-pass5-existing-chat-talk-availability-only")
    }

    @MainActor
    func testV2ManualBrowserHistoryCollapseAndReopenWithoutForwardingAuthAgainstIsolatedBackend() async throws {
        let (_, app, _) = try await isolatedV2FeatureContext()
        let pages = try V2ManualBrowserHTTPFixture()
        addTeardownBlock { @MainActor in app.terminate(); await pages.stop() }
        let url = try await pages.start()
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app)
        try await openV2ManualBrowser(in: app)
        try await navigateV2ManualBrowser(to: url.appendingPathComponent("one"), title: pages.firstTitle, in: app)
        let link = app.webViews.links["Visit second fixture page"].firstMatch
        try await waitForV2Smoke(in: app, "Expected local HTML link") { link.exists && link.isHittable }
        link.tap()
        try await waitForV2Smoke(in: app, "Expected second document title and address") {
            app.webViews.otherElements[pages.secondTitle].firstMatch.exists
                && (app.textFields["browser.address"].value as? String) == url.appendingPathComponent("two").absoluteString
        }
        // Both device hierarchies identify browser history separately from BackButton.
        let back = app.buttons["chevron.backward"]
        try await waitForV2Smoke(in: app, "Expected enabled browser history Back") { back.exists && back.isHittable && back.isEnabled }
        back.tap()
        try await waitForV2Smoke(in: app, "Back must restore the first page") {
            app.webViews.otherElements[pages.firstTitle].firstMatch.exists
                && (app.textFields["browser.address"].value as? String) == url.appendingPathComponent("one").absoluteString
        }
        try await collapseV2ManualBrowser(in: app)
        try await openV2ManualBrowser(in: app)
        try await waitForV2Smoke(in: app, "Reopening must retain the first page and forward history") {
            app.webViews.otherElements[pages.firstTitle].firstMatch.exists && app.buttons["chevron.forward"].isEnabled
        }
        let paths = await pages.requestedPaths
        XCTAssertTrue(paths.contains("/one"))
        XCTAssertTrue(paths.contains("/two"))
        let leakedHeaders = await pages.credentialHeaderNames
        XCTAssertTrue(leakedHeaders.isEmpty, "The manual browser must not send OpenCode credentials: \(leakedHeaders)")
        attachScreenshot(named: "v2-pass5-manual-browser-history-reopened")
    }

    @MainActor
    func testV2ManualBrowserProjectSwitchAndReconnectIsolateOldPageAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let gitDirectory = (directory as NSString).deletingLastPathComponent + "/git-fixture"
        _ = try normalizedV2FixturePath(gitDirectory)
        let location = try await backend.request("api/location", query: [URLQueryItem(name: "location[directory]", value: gitDirectory)])
        let project = try XCTUnwrap(location["project"] as? [String: Any])
        let projectID = try XCTUnwrap(project["id"] as? String)
        guard projectID != "global", let actualDirectory = project["directory"] as? String,
              try normalizedV2FixturePath(actualDirectory) == normalizedV2FixturePath(gitDirectory) else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected only the approved Git fixture project"])
        }
        let pages = try V2ManualBrowserHTTPFixture()
        addTeardownBlock { @MainActor in app.terminate(); await pages.stop() }
        let url = try await pages.start()
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app)
        try await openV2ManualBrowser(in: app)
        try await navigateV2ManualBrowser(to: url.appendingPathComponent("one"), title: pages.firstTitle, in: app)
        try await collapseV2ManualBrowser(in: app)
        try await revealV2Projects(in: app)
        let git = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", actualDirectory, gitDirectory)).firstMatch
        try await waitForV2Smoke(in: app, "Expected approved Git project row") { git.exists && git.isHittable }
        git.tap()
        try await openV2ManualBrowser(in: app)
        XCTAssertFalse(app.webViews.otherElements[pages.firstTitle].firstMatch.exists, "A new project must not display Global's page")
        XCTAssertFalse((app.textFields["browser.address"].value as? String ?? "").contains(url.absoluteString))
        try await navigateV2ManualBrowser(to: url.appendingPathComponent("two"), title: pages.secondTitle, in: app)
        try await collapseV2ManualBrowser(in: app)
        try await revealV2Projects(in: app)
        let global = app.staticTexts["Global"].firstMatch
        try await waitForV2Smoke(in: app, "Expected Global project row") { global.exists && global.isHittable }
        global.tap()
        try await openV2ManualBrowser(in: app)
        try await waitForV2Smoke(in: app, "Returning to Global must restore only its own page") {
            app.webViews.otherElements[pages.firstTitle].firstMatch.exists && !app.webViews.otherElements[pages.secondTitle].firstMatch.exists
        }
        try await collapseV2ManualBrowser(in: app)
        try await revealV2Projects(in: app)
        let disconnect = app.buttons["projects.disconnect"]
        let sidebar = app.collectionViews.containing(.button, identifier: "projects.disconnect").firstMatch
        for _ in 0..<10 {
            if disconnect.exists && disconnect.isHittable { break }
            if sidebar.exists { sidebar.swipeUp() } else { app.swipeUp() }
        }
        try await waitForV2Smoke(in: app, "Expected Disconnect in the project sidebar") { disconnect.exists && disconnect.isHittable }
        disconnect.tap()
        // UI3 shows Recent Servers after disconnect on both devices. Reuse the
        // exact saved v2 connection instead of waiting for the first-run API editor.
        let savedServer = app.buttons
            .containing(.staticText, identifier: backend.baseURL.absoluteString)
            .containing(.staticText, identifier: backend.username.trimmingCharacters(in: .whitespacesAndNewlines))
            .firstMatch
        try await waitForV2Smoke(in: app, "Expected the exact disposable connection in Recent Servers") {
            app.navigationBars["OpenClient"].exists && savedServer.exists && savedServer.isHittable
        }
        savedServer.tap()
        try await waitForV2Smoke(in: app, "Expected saved v2 reconnect to restore the Global project", timeout: 30) {
            !app.navigationBars["OpenClient"].exists && global.exists && global.isHittable
        }
        global.tap()
        try await openV2ManualBrowser(in: app)
        XCTAssertFalse(app.webViews.otherElements[pages.firstTitle].firstMatch.exists)
        XCTAssertFalse(app.webViews.otherElements[pages.secondTitle].firstMatch.exists)
        XCTAssertFalse((app.textFields["browser.address"].value as? String ?? "").contains(url.absoluteString),
                       "A new connection generation must not reuse the old page even on the same server")
        let leakedHeaders = await pages.credentialHeaderNames
        XCTAssertTrue(leakedHeaders.isEmpty)
        attachScreenshot(named: "v2-pass5-browser-reconnect-cleared")
    }

    @MainActor
    private func openV2ManualBrowser(in app: XCUIApplication) async throws {
        let open = app.buttons["browser.open"]
        try await waitForV2Smoke(in: app, "Expected manual browser entry point on v2") { open.exists && open.isHittable && open.isEnabled }
        open.tap()
        try await waitForV2Smoke(in: app, "Expected native browser address bar") {
            app.textFields["browser.address"].exists && app.textFields["browser.address"].isHittable
        }
    }

    @MainActor
    private func navigateV2ManualBrowser(to url: URL, title: String, in app: XCUIApplication) async throws {
        let address = app.textFields["browser.address"]
        address.tap()
        let previous = address.value as? String ?? ""
        if previous != "Search or enter website name" && !previous.isEmpty {
            address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
        }
        address.typeText(url.absoluteString)
        // Fail before Return if typing went wrong, so the resolver cannot search the public web.
        guard address.value as? String == url.absoluteString else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing to submit a non-fixture browser address"])
        }
        address.typeText("\n")
        // WebKit exposes <title> as the document's Other label. The native header
        // is a separate StaticText, now also checked after the UI3 metadata fix.
        let document = app.webViews.otherElements[title].firstMatch
        try await waitForV2Smoke(in: app, "Expected local document title and rendered body", timeout: 20) {
            document.exists && document.staticTexts["Body for \(title)"].firstMatch.exists
                && (address.value as? String) == url.absoluteString
        }
        try await waitForV2Smoke(in: app, "Expected the native browser header to reflect the loaded document title") {
            app.staticTexts[title].exists
        }
    }

    @MainActor
    private func collapseV2ManualBrowser(in app: XCUIApplication) async throws {
        let collapse = app.buttons["browser.collapse"]
        try await waitForV2Smoke(in: app, "Expected browser collapse action") { collapse.exists && collapse.isHittable }
        collapse.tap()
        try await waitForV2Smoke(in: app, "Collapsed browser must hide its address field") { !app.textFields["browser.address"].exists }
    }

    @MainActor
    private func revealV2Projects(in app: XCUIApplication) async throws {
        for _ in 0..<4 {
            if app.buttons["projects.newTalk"].isHittable { return }
            let navigation = app.navigationBars.buttons.allElementsBoundByIndex.first {
                $0.isHittable && ($0.label == "Projects" || $0.label == "Show Sidebar" || $0.identifier == "Sidebar")
            }
            guard let navigation else { break }
            navigation.tap()
        }
        try await waitForV2Smoke(in: app, "Expected project sidebar for scope switching") { app.buttons["projects.newTalk"].isHittable }
    }

    @MainActor
    func testV2ActiveChatRefreshesOnForegroundWithoutPullThroughSnapshotProxy() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        let proxy = try V2ForegroundSnapshotProxy(baseURL: backend.baseURL, username: backend.username,
                                                  password: backend.password, fixture: fixture)
        addTeardownBlock { @MainActor in
            app.terminate()
            await proxy.stop()
        }
        let proxyURL = try await proxy.start()
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = proxyURL.absoluteString
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        let replacement = "Foreground canonical assistant \(UUID().uuidString)"
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replacement)).firstMatch.exists)
        let initialReads = await proxy.replacementReads
        XCTAssertEqual(initialReads, 0)

        XCUIDevice.shared.press(.home)
        try await waitForV2Smoke(in: app, "Expected the active chat app to enter background") {
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        // next-17155 import rejects existing IDs (409), and messages have no update
        // route. Change only the HTTP fixture, never delete/reimport the active session.
        await proxy.replaceAssistant(with: replacement)
        app.activate()
        try await waitForV2Smoke(in: app, "Foreground activation must reconcile the assistant without pulling or reopening", timeout: 20) {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", replacement)).firstMatch.exists
                && !app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch.exists
                && app.buttons["chat.composer.menu"].exists
        }
        let foregroundReads = await proxy.replacementReads
        XCTAssertGreaterThan(foregroundReads, 0, "The production app must fetch the changed HTTP snapshot")
        let streams = await proxy.eventStreamConnections
        XCTAssertGreaterThan(streams, 0, "The proxy must exercise a connected, event-free SSE transport")
        attachScreenshot(named: "v2-foreground-http-fixture-no-sse")

        app.terminate()
        app.launch()
        try await openV2OwnedChat(fixture, in: app, expectedAssistant: replacement)
        let reopenedReads = await proxy.replacementReads
        XCTAssertGreaterThan(reopenedReads, foregroundReads, "Cold reopen must read the replacement snapshot again")
        let failures = await proxy.failures
        XCTAssertTrue(failures.isEmpty, "HTTP fixture failures: \(failures.joined(separator: "; "))")
        let unchanged = try await backend.request("api/session/\(fixture.sessionID)/message/\(fixture.assistantMessageID)")
        let canonical = try XCTUnwrap(unchanged["data"] as? [String: Any])
        XCTAssertEqual((canonical["content"] as? [[String: Any]])?.first?["text"] as? String, fixture.assistantText,
                       "This is controlled HTTP fixture coverage, not a live canonical server mutation")
        attachScreenshot(named: "v2-foreground-cold-reopen")
    }

    @MainActor
    func testV2WidgetActionsValidateRoutesPreserveDraftAndCancelWithoutExecutionAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let initialSessions = try await isolatedV2SessionIDs(backend)
        let token = UUID().uuidString
        let missingCommand = "pass8-missing-\(token)"
        let catalog = try await backend.request("api/command", query: [.init(name: "location[directory]", value: directory)])
        let commands = try XCTUnwrap(catalog["data"] as? [[String: Any]])
        XCTAssertFalse(commands.contains { $0["name"] as? String == missingCommand })
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app)
        let serverID = "\(backend.baseURL.absoluteString.lowercased())|\(backend.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        var link = URLComponents()
        link.scheme = "openclient"
        link.host = "widget"
        link.path = "/new-session"
        link.queryItems = [.init(name: "profile", value: "legacy"), .init(name: "serverID", value: serverID),
                           .init(name: "projectID", value: "global")]
        try await deliverV2WarmURL(try XCTUnwrap(link.url), in: app)
        try await waitForV2Smoke(in: app, "Wrong-profile widget action must reject before presenting a composer") {
            app.staticTexts["Open the app to reconnect the server used by this widget."].firstMatch.exists
                && !app.textViews["chat.input"].exists && !app.navigationBars["New Session"].exists
        }
        let afterWrongProfile = try await isolatedV2SessionIDs(backend)
        XCTAssertEqual(afterWrongProfile, initialSessions)
        attachScreenshot(named: "v2-pass8-widget-action-wrong-profile")

        // Valid command URLs execute immediately. Only deliver a command proven
        // absent from this isolated catalog; never invoke a real command here.
        link.path = "/action"
        link.queryItems?[0] = .init(name: "profile", value: "v2")
        link.queryItems?.append(.init(name: "command", value: missingCommand))
        try await deliverV2WarmURL(try XCTUnwrap(link.url), in: app)
        try await waitForV2Smoke(in: app, "Missing widget command must reject before session creation or prompt admission") {
            app.staticTexts["Command is no longer available. Open the app to sync widget settings."].firstMatch.exists
                && !app.textViews["chat.input"].exists
        }
        let afterMissingCommand = try await isolatedV2SessionIDs(backend)
        XCTAssertEqual(afterMissingCommand, initialSessions)
        attachScreenshot(named: "v2-pass8-widget-command-catalog-rejection")

        link.path = "/new-session"
        link.queryItems?.removeAll { $0.name == "command" }
        let newSessionURL = try XCTUnwrap(link.url)
        try await deliverV2WarmURL(newSessionURL, in: app)
        let input = app.textViews["chat.input"].firstMatch
        let project = app.staticTexts["projects.newChat.project"].firstMatch
        let missingCommandError = app.staticTexts["Command is no longer available. Open the app to sync widget settings."].firstMatch
        try await waitForV2Smoke(in: app, "Validated widget new-session route must expose its locked Global project") {
            app.navigationBars["New Session"].exists && input.exists && input.isHittable && input.isEnabled
                && project.exists && project.label == "Global" && !missingCommandError.exists
        }
        XCTAssertFalse(app.buttons["projects.newChat.project"].exists, "Widget project selection is locked, not an editable picker")
        let title = "Pass8 Widget Draft \(token)"
        let rename = app.buttons["projects.newChat.navigationTitleButton"]
        try await waitForV2Smoke(in: app, "Expected widget draft title editing") { rename.exists && rename.isHittable }
        rename.tap()
        let titleField = app.textFields["projects.newChat.titleField"]
        try await waitForV2Smoke(in: app, "Expected title field, not the message input, to receive the title") { titleField.exists && titleField.isHittable }
        titleField.typeText(title)
        XCTAssertEqual(titleField.value as? String, title)
        titleField.typeText("\n")
        let draft = "Edited widget draft \(token)"
        try await waitForV2Smoke(in: app, "Expected the ready widget message input") { input.exists && input.isHittable && input.isEnabled }
        input.tap()
        input.typeText(draft)
        let send = app.buttons["chat.send"]
        try await waitForV2Smoke(in: app, "Edited widget draft must enable Send without sending") {
            (input.value as? String) == draft && send.exists && send.isEnabled
        }
        try await deliverV2WarmURL(newSessionURL, in: app)
        try await waitForV2Smoke(in: app, "Repeated widget route must preserve title, text, locked project, and readiness") {
            (input.value as? String) == draft && send.isEnabled && project.label == "Global"
                && app.navigationBars[title].exists
        }
        let beforeCancel = try await isolatedV2SessionIDs(backend)
        XCTAssertEqual(beforeCancel, initialSessions)
        attachScreenshot(named: "v2-pass8-widget-edited-draft-preserved")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "v2-pass8-widget-composition-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let cancel = app.navigationBars[title].buttons["Cancel"]
        try await waitForV2Smoke(in: app, "Expected cancellation of the unsent widget draft") { cancel.exists && cancel.isHittable }
        cancel.tap()
        try await waitForV2Smoke(in: app, "Widget cancellation must return to the session list") {
            !input.exists && !app.navigationBars[title].exists && app.buttons["sessions.create"].exists
                && !missingCommandError.exists
        }
        let afterCancel = try await isolatedV2SessionIDs(backend)
        XCTAssertEqual(afterCancel, initialSessions, "No widget route in this test may create a session")
        attachScreenshot(named: "v2-pass8-widget-cancelled-no-creation")
    }

    @MainActor
    func testV2LiveActivityStartsAndStopsOrReportsUnsupportedPlatformAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        let row = app.buttons["session.row.\(fixture.sessionID)"]
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground {
                let stop = app.buttons["Stop Live"].firstMatch
                if stop.exists && stop.isHittable {
                    stop.tap()
                } else if row.exists && row.isHittable && row.images["waveform"].exists {
                    row.press(forDuration: 1)
                    if stop.waitForExistence(timeout: 5) && stop.isHittable { stop.tap() }
                }
            }
            app.terminate()
        }
        let before = try await backend.request("api/session/\(fixture.sessionID)/message")
        app.launch()
        let isIPad = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app)
        try await waitForV2Smoke(in: app, "Expected the exact idle imported chat's session row") { row.exists && row.isHittable }
        XCTAssertFalse(row.images["waveform"].exists)
        row.press(forDuration: 1)
        let live = app.buttons["Live"].firstMatch
        try await waitForV2Smoke(in: app, "V2 must offer the native manual Live Activity action") { live.exists && live.isHittable && live.isEnabled }
        attachScreenshot(named: "v2-pass8-live-activity-available")
        live.tap()
        let unsupportedDescriptions = [ActivityAuthorizationError.unsupported.localizedDescription,
                                       ActivityAuthorizationError.unsupportedTarget.localizedDescription]
        let unsupported = app.staticTexts.matching(NSPredicate(format: "label IN %@", unsupportedDescriptions)).firstMatch
        try await waitForV2Smoke(in: app, "Real ActivityKit request must activate or report explicit iPad platform non-support", timeout: 20) {
            row.images["waveform"].exists || (isIPad && unsupported.exists)
        }
        if unsupported.exists {
            XCTAssertTrue(isIPad, "The iPhone run requires a real start/stop, not an unsupported fallback")
            XCTAssertFalse(row.images["waveform"].exists)
            let evidence = XCTAttachment(string: unsupported.label)
            evidence.name = "v2-pass8-live-activity-unsupported-os-result"
            evidence.lifetime = .keepAlways
            add(evidence)
            attachScreenshot(named: "v2-pass8-live-activity-explicitly-unsupported")
            row.press(forDuration: 1)
            try await waitForV2Smoke(in: app, "Unsupported platform must retain Live rather than falsely showing Stop Live") {
                live.exists && !app.buttons["Stop Live"].exists
            }
        } else {
            row.press(forDuration: 1)
            let stop = app.buttons["Stop Live"].firstMatch
            try await waitForV2Smoke(in: app, "Accepted ActivityKit request must flip the action to Stop Live") { stop.exists && stop.isHittable }
            attachScreenshot(named: "v2-pass8-live-activity-active")
            // Dismiss the context menu without invoking Stop, then establish a new
            // connection lifetime for the exact same saved server/profile owner.
            app.navigationBars["Global"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try await waitForV2Smoke(in: app, "Expected active activity after closing only its context menu") {
                !stop.exists && row.isHittable && row.images["waveform"].exists
            }
            try await revealV2Projects(in: app)
            let disconnect = app.buttons["projects.disconnect"]
            let sidebar = app.collectionViews.containing(.button, identifier: "projects.disconnect").firstMatch
            for _ in 0..<10 {
                if disconnect.exists && disconnect.isHittable { break }
                sidebar.swipeUp()
            }
            try await waitForV2Smoke(in: app, "Expected disconnect without ending the owned activity") { disconnect.exists && disconnect.isHittable }
            disconnect.tap()
            let savedServer = app.buttons
                .containing(.staticText, identifier: backend.baseURL.absoluteString)
                .containing(.staticText, identifier: backend.username.trimmingCharacters(in: .whitespacesAndNewlines))
                .firstMatch
            try await waitForV2Smoke(in: app, "Expected the same saved 14097 owner after disconnect") {
                app.navigationBars["OpenClient"].exists && savedServer.exists && savedServer.isHittable
            }
            attachScreenshot(named: "v2-pass8-live-activity-disconnected-retained-owner")
            savedServer.tap()
            let global = app.staticTexts["Global"].firstMatch
            try await waitForV2Smoke(in: app, "Expected successful same-owner reconnect", timeout: 30) {
                !app.navigationBars["OpenClient"].exists && global.exists && global.isHittable
            }
            global.tap()
            try await waitForV2Smoke(in: app, "Bootstrap must reconcile the retained ActivityKit record without another start", timeout: 20) {
                row.exists && row.isHittable && row.images["waveform"].exists
            }
            row.press(forDuration: 1)
            try await waitForV2Smoke(in: app, "Same-owner reconnect must still offer Stop Live, not Live") {
                stop.exists && stop.isHittable && !live.exists
            }
            attachScreenshot(named: "v2-pass8-live-activity-reconnect-retained")
            let retainedHierarchy = XCTAttachment(string: app.debugDescription)
            retainedHierarchy.name = "v2-pass8-live-activity-reconnect-hierarchy"
            retainedHierarchy.lifetime = .keepAlways
            add(retainedHierarchy)
            stop.tap()
            try await waitForV2Smoke(in: app, "Stopping the owned Live Activity must clear its row badge") { !row.images["waveform"].exists && row.isHittable }
            row.press(forDuration: 1)
            try await waitForV2Smoke(in: app, "Stopped activity must restore the Live action") { live.exists && !app.buttons["Stop Live"].exists }
            attachScreenshot(named: "v2-pass8-live-activity-stopped")
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "v2-pass8-live-activity-controls-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let after = try await backend.request("api/session/\(fixture.sessionID)/message")
        XCTAssertTrue(NSDictionary(dictionary: after).isEqual(to: before))
        let pending = try await backend.request("api/session/\(fixture.sessionID)/pending")
        XCTAssertEqual((pending["data"] as? [[String: Any]])?.count, 0, "ActivityKit controls must not submit model input")
    }

    @MainActor
    func testV2GamesChoosersAreAvailableAndCancelWithoutGeneratingAgainstIsolatedBackend() async throws {
        let (backend, app, _) = try await isolatedV2FeatureContext()
        let initialSessions = try await isolatedV2SessionIDs(backend)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)

        @MainActor
        func gamesPreference() async throws -> XCUIElement {
            let settings = app.buttons["projects.configurations"]
            try await waitForV2Smoke(in: app, "Expected connected app settings") { settings.exists && settings.isHittable }
            settings.tap()
            let global = app.buttons["configurations.global-settings"]
            try await waitForV2Smoke(in: app, "Expected Global Settings link") { global.exists && global.isHittable }
            global.tap()
            let toggle = app.switches["configurations.show-fun-and-games"]
            let form = app.collectionViews.firstMatch
            for _ in 0..<10 {
                if toggle.exists && toggle.isHittable && form.frame.contains(toggle.frame) { break }
                form.swipeUp()
            }
            try await waitForV2Smoke(in: app, "Expected the native Fun & Games preference") { toggle.exists && toggle.isHittable }
            return toggle
        }

        @MainActor
        func closeGamesPreference() async throws {
            let back = app.navigationBars["Configurations"].buttons.matching(NSPredicate(format: "label != %@", "Done")).firstMatch
            try await waitForV2Smoke(in: app, "Expected Global Settings back navigation") { back.exists && back.isHittable }
            back.tap()
            let done = app.navigationBars["Configurations"].buttons["Done"]
            try await waitForV2Smoke(in: app, "Expected parent settings dismissal") { done.exists && done.isHittable }
            done.tap()
            try await waitForV2Smoke(in: app, "Expected home after closing settings") { app.buttons["projects.configurations"].isHittable }
        }

        let toggle = try await gamesPreference()
        let initiallyEnabled = isSwitchOn(toggle)
        if !initiallyEnabled {
            let control = toggle.switches.firstMatch
            try await waitForV2Smoke(in: app, "Expected the native games switch thumb") { control.exists && control.isHittable }
            control.tap()
            try await waitForV2Smoke(in: app, "Games preference must enable before leaving settings") { self.isSwitchOn(toggle) }
        }
        try await closeGamesPreference()
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground {
                let cancel = app.navigationBars.buttons["Cancel"].firstMatch
                if cancel.exists && cancel.isHittable { cancel.tap() }
                let preference = try await gamesPreference()
                if self.isSwitchOn(preference) != initiallyEnabled { preference.switches.firstMatch.tap() }
                try await self.waitForV2Smoke(in: app, "Restore the original games preference") { self.isSwitchOn(preference) == initiallyEnabled }
                try await closeGamesPreference()
            }
            app.terminate()
        }
        for game in ["Find the Bug", "Find the Place"] {
            let entry = app.staticTexts[game].firstMatch
            let home = app.collectionViews.containing(.button, identifier: "projects.disconnect").firstMatch
            for _ in 0..<8 {
                if entry.exists && entry.isHittable { break }
                home.swipeUp()
            }
            try await waitForV2Smoke(in: app, "Expected enabled v2 game entry \(game)") { entry.exists && entry.isHittable }
            entry.tap()
            let chooser = app.navigationBars[game]
            let explanation = game == "Find the Bug"
                ? "Choose the language for the buggy snippet. These match the app's syntax highlighting support."
                : "Choose the model that will host the game. OpenClient will start a new chat and send the private game setup automatically."
            try await waitForV2Smoke(in: app, "Expected cancellable \(game) chooser, not generated gameplay") {
                chooser.exists && chooser.buttons["Cancel"].isHittable && app.staticTexts[explanation].exists
            }
            if game == "Find the Bug" { XCTAssertTrue(app.buttons["Swift"].exists) }
            attachScreenshot(named: "v2-pass8-\(game == "Find the Bug" ? "bug-language" : "place-model")-chooser-only")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "v2-pass8-\(game)-chooser-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            // Model selection starts setup automatically. Never tap any model.
            chooser.buttons["Cancel"].tap()
            try await waitForV2Smoke(in: app, "Cancelling \(game) must restore home without a chat") {
                !chooser.exists && !app.collectionViews["chat.scroll"].exists && app.buttons["projects.newChat"].exists
            }
            let remainingSessions = try await isolatedV2SessionIDs(backend)
            XCTAssertEqual(remainingSessions, initialSessions, "Opening/cancelling game choosers must not create a setup session")
        }
    }

    @MainActor
    private func isolatedV2SessionIDs(_ backend: V2SmokeBackend) async throws -> Set<String> {
        let response = try await backend.request("api/session", query: [.init(name: "project", value: "global"), .init(name: "limit", value: "100")])
        let sessions = try XCTUnwrap(response["data"] as? [[String: Any]])
        guard sessions.count < 100 else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot prove unchanged isolated session inventory from a truncated page"])
        }
        return Set(try sessions.map { try XCTUnwrap($0["id"] as? String) })
    }

    @MainActor
    func testV2ColdCachedTranscriptSurvivesBlockedReadsAndReconcilesWithServerAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        let proxy = try V2ForegroundSnapshotProxy(baseURL: backend.baseURL, username: backend.username,
                                                  password: backend.password, fixture: fixture)
        addTeardownBlock { @MainActor in
            app.terminate()
            await proxy.stop()
        }
        let proxyURL = try await proxy.start()
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = proxyURL.absoluteString
        let cachedText = "Pass7 cached HTTP snapshot \(UUID().uuidString)"
        // Seed an intentionally stale HTTP snapshot through the real app's read/cache
        // pipeline. The underlying server keeps its original canonical transcript.
        await proxy.replaceAssistant(with: cachedText)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app, expectedAssistant: cachedText)
        let transcript = app.collectionViews["chat.scroll"]
        let cachedAssistant = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", cachedText)).firstMatch
        let canonicalAssistant = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch
        let user = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.userText)).firstMatch
        try await waitForV2Smoke(in: app, "Expected the stale HTTP snapshot in the actual chat transcript") {
            cachedAssistant.exists && user.exists
        }
        let initialReads = await proxy.replacementReads
        XCTAssertGreaterThan(initialReads, 0)
        attachScreenshot(named: "v2-pass7-cache-initial-http-snapshot")
        XCUIDevice.shared.press(.home)
        try await waitForV2Smoke(in: app, "Expected the cached chat app to enter background") {
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)

        await proxy.setTranscriptReadsBlocked(true)
        await proxy.replaceAssistant(with: nil)
        app.launch()
        // Auto-connect stays disabled. V2 cache ownership requires a real resolved
        // connection, so this is NOT fully offline app navigation: discovery remains
        // live while every transcript read for the owned session returns HTTP 503.
        try await waitForV2Smoke(in: app, "Cold launch must wait at the connection editor, not restore synthetic chat state") {
            app.collectionViews["connection.form"].exists && !app.buttons["chat.composer.menu"].exists
        }
        try await openV2OwnedChat(fixture, in: app, expectedAssistant: cachedText)
        try await waitForV2Smoke(in: app, "Expected persisted messages inside the cold chat, not a session-list preview") {
            cachedAssistant.exists && user.exists
        }
        let blockedReads = await proxy.blockedTranscriptReads
        let canonicalReadsBefore = await proxy.canonicalTranscriptReads
        XCTAssertGreaterThan(blockedReads, 0, "Cold hydration must actually attempt the blocked transcript endpoint")
        XCTAssertEqual(canonicalReadsBefore, 0, "No successful server transcript can explain the cold cached presentation")
        XCTAssertFalse(canonicalAssistant.exists)
        attachScreenshot(named: "v2-pass7-cold-cache-transcript-http-unavailable")
        let cachedHierarchy = XCTAttachment(string: app.debugDescription)
        cachedHierarchy.name = "v2-pass7-cold-cache-hierarchy"
        cachedHierarchy.lifetime = .keepAlways
        add(cachedHierarchy)

        XCUIDevice.shared.press(.home)
        try await waitForV2Smoke(in: app, "Expected background state before restoring canonical reads") {
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }
        await proxy.setTranscriptReadsBlocked(false)
        app.activate()
        try await waitForV2Smoke(in: app, "Canonical server response must replace the persisted stale presentation", timeout: 30) {
            canonicalAssistant.exists && user.exists && !cachedAssistant.exists
                && app.buttons["chat.composer.menu"].exists
                && !app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Owned transcript temporarily unavailable")).firstMatch.exists
        }
        let canonicalReadsAfter = await proxy.canonicalTranscriptReads
        XCTAssertGreaterThan(canonicalReadsAfter, canonicalReadsBefore)
        let canonical = try await backend.request("api/session/\(fixture.sessionID)/message/\(fixture.assistantMessageID)")
        let assistant = try XCTUnwrap(canonical["data"] as? [String: Any])
        XCTAssertEqual((assistant["content"] as? [[String: Any]])?.first?["text"] as? String, fixture.assistantText)
        let failures = await proxy.failures
        XCTAssertTrue(failures.isEmpty, "Read-only cache fixture failures: \(failures)")
        let readEvidence = XCTAttachment(string: "Initial stale HTTP reads=\(initialReads); cold blocked transcript reads=\(blockedReads); canonical reads while blocked=\(canonicalReadsBefore); canonical reads after recovery=\(canonicalReadsAfter). App terminated before the blocked-read phase; discovery remained live; SSE carried comments only.")
        readEvidence.name = "v2-pass7-cache-read-evidence"
        readEvidence.lifetime = .keepAlways
        add(readEvidence)
        attachScreenshot(named: "v2-pass7-cache-reconciled-to-real-server")
    }

    @MainActor
    func testV2WidgetSessionLinkRejectsWrongProfileThenOpensCanonicalOwnedSessionAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        // The session list renders connection/routing errors; Projects home does not.
        // Keep Global selected but no chat open so rejection has observable evidence.
        try await connectV2SmokeAndSelectGlobal(in: app)
        let serverID = "\(backend.baseURL.absoluteString.lowercased())|\(backend.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        // Match OpenCodeWidgetDeepLink.sessionURL: profile + raw server/session/
        // project IDs and the canonical directory. V2 widget entity hashing is not
        // part of the route, and a fixture's display title must never seed navigation.
        var link = URLComponents()
        link.scheme = "openclient"
        link.host = "widget"
        link.path = "/session"
        link.queryItems = [
            .init(name: "profile", value: "legacy"), .init(name: "serverID", value: serverID),
            .init(name: "sessionID", value: fixture.sessionID), .init(name: "projectID", value: "global"),
            .init(name: "directory", value: fixture.directory)
        ]
        let before = try await backend.request("api/session/\(fixture.sessionID)/message")
        let beforeMessages = try XCTUnwrap(before["data"] as? [[String: Any]])
        XCTAssertEqual(beforeMessages.count, 2)
        let beforePending = try await backend.request("api/session/\(fixture.sessionID)/pending")
        XCTAssertEqual((beforePending["data"] as? [[String: Any]])?.count, 0)
        try await deliverV2WarmURL(try XCTUnwrap(link.url), in: app)
        let rejected = app.staticTexts["Open the app to reconnect the server used by this widget."].firstMatch
        try await waitForV2Smoke(in: app, "A legacy-profile widget link must be explicitly rejected on the saved v2 connection") {
            rejected.exists && app.buttons["sessions.create"].exists && !app.buttons["chat.composer.menu"].exists
        }
        XCTAssertFalse(app.collectionViews["chat.scroll"].exists)
        attachScreenshot(named: "v2-pass7-widget-wrong-profile-rejected")
        let rejectedHierarchy = XCTAttachment(string: app.debugDescription)
        rejectedHierarchy.name = "v2-pass7-widget-profile-boundary-hierarchy"
        rejectedHierarchy.lifetime = .keepAlways
        add(rejectedHierarchy)

        link.queryItems?[0] = .init(name: "profile", value: "v2")
        try await deliverV2WarmURL(try XCTUnwrap(link.url), in: app)
        let transcript = app.collectionViews["chat.scroll"]
        try await waitForV2Smoke(in: app, "Matching-profile widget link must read and open the canonical owned transcript", timeout: 30) {
            transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.userText)).firstMatch.exists
                && transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch.exists
                && app.buttons["chat.composer.menu"].exists
        }
        let after = try await backend.request("api/session/\(fixture.sessionID)/message")
        let afterMessages = try XCTUnwrap(after["data"] as? [[String: Any]])
        XCTAssertEqual(afterMessages.compactMap { $0["id"] as? String }, beforeMessages.compactMap { $0["id"] as? String })
        XCTAssertTrue(NSArray(array: afterMessages).isEqual(to: beforeMessages), "Widget session opens must not mutate the transcript")
        let afterPending = try await backend.request("api/session/\(fixture.sessionID)/pending")
        XCTAssertEqual((afterPending["data"] as? [[String: Any]])?.count, 0, "Opening a widget session must not submit a prompt")
        XCTAssertFalse(app.navigationBars["New Session"].exists)
        attachScreenshot(named: "v2-pass7-widget-canonical-session-opened-without-send")
    }

    @MainActor
    func testV2SessionListShowMoreOnlyWhileRealRootPageRemainsAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        // reloadV2Sessions uses 50, independently of the legacy DirectoryStore limit.
        let pageLimit = 50
        let rootQuery: [URLQueryItem] = [.init(name: "project", value: "global"), .init(name: "parentID", value: "null"), .init(name: "order", value: "desc")]
        let baseline = try await backend.request("api/session", query: rootQuery + [.init(name: "limit", value: "100")])
        let baselineRows = try XCTUnwrap(baseline["data"] as? [[String: Any]])
        guard baselineRows.count <= 10 else {
            throw NSError(domain: "V2UISmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected a small disposable root inventory; existing sessions will not be deleted to fit the fixture"])
        }
        let baselineIDs = Set(try baselineRows.map { try XCTUnwrap($0["id"] as? String) })
        let ownedIDs = (0..<52).map { _ in "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))" }
        let run = String(UUID().uuidString.prefix(8))
        addTeardownBlock { @MainActor in
            app.terminate()
            for id in ownedIDs {
                _ = try await backend.request("api/session/\(id)", method: "DELETE", allowsNotFound: true)
            }
            let remaining = try await backend.request("api/session", query: rootQuery + [.init(name: "limit", value: "100")])
            let ids = Set(try XCTUnwrap(remaining["data"] as? [[String: Any]]).compactMap { $0["id"] as? String })
            XCTAssertEqual(ids, baselineIDs, "Cleanup must preserve all pre-existing roots and remove only this test's IDs")
        }

        @MainActor
        func capture(_ name: String) {
            attachScreenshot(named: name)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "\(name)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }

        @MainActor
        func probe(_ name: String, expectedCount: Int, expectedRemainder: Int) async throws -> (Set<String>, Set<String>) {
            let page = try await backend.request("api/session", query: rootQuery + [.init(name: "limit", value: String(pageLimit))])
            let rows = try XCTUnwrap(page["data"] as? [[String: Any]])
            XCTAssertEqual(rows.count, expectedCount)
            let cursor = try XCTUnwrap((page["cursor"] as? [String: Any])?["next"] as? String)
            let lookahead = try await backend.request("api/session", query: [.init(name: "cursor", value: cursor), .init(name: "limit", value: "1")])
            let next = try await backend.request("api/session", query: [.init(name: "cursor", value: cursor), .init(name: "limit", value: String(pageLimit))])
            let probeRows = try XCTUnwrap(lookahead["data"] as? [[String: Any]])
            let nextRows = try XCTUnwrap(next["data"] as? [[String: Any]])
            XCTAssertEqual(probeRows.count, min(1, expectedRemainder))
            XCTAssertEqual(nextRows.count, expectedRemainder)
            XCTAssertEqual(probeRows.first?["id"] as? String, nextRows.first?["id"] as? String)
            let firstIDs = Set(rows.compactMap { $0["id"] as? String })
            let nextIDs = Set(nextRows.compactMap { $0["id"] as? String })
            XCTAssertEqual(firstIDs.count, expectedCount)
            XCTAssertEqual(nextIDs.count, expectedRemainder)
            XCTAssertTrue(firstIDs.isDisjoint(with: nextIDs))
            let evidence = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: ["baseline": baseline, "first": page, "limit1Lookahead": lookahead, "originalCursorNextPage": next], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            evidence.name = "v2-session-list-\(name)-actual-GET"
            evidence.lifetime = .keepAlways
            add(evidence)
            return (firstIDs, nextIDs)
        }

        for index in ownedIDs.indices {
            let created = try await backend.request("api/session", method: "POST", body: [
                "id": ownedIDs[index], "title": "List \(run) \(String(format: "%02d", index + 1))", "location": ["directory": directory]
            ])
            XCTAssertEqual((created["data"] as? [String: Any])?["id"] as? String, ownedIDs[index])
            if index == 1 {
                _ = try await probe("short", expectedCount: baselineIDs.count + 2, expectedRemainder: 0)
                app.launch()
                _ = try await prepareV2SmokeLayout(in: app)
                try await connectV2SmokeAndSelectGlobal(in: app)
                try await waitForV2Smoke(in: app, "Both owned short-list roots must hydrate") {
                    app.navigationBars["Global"].exists && app.collectionViews.count == 1
                        && ownedIDs.prefix(2).allSatisfy { app.collectionViews.firstMatch.buttons["session.row.\($0)"].exists }
                }
                let list = app.collectionViews.firstMatch
                for _ in 0..<3 { list.swipeUp() }
                XCTAssertFalse(list.buttons["Show More"].exists, "A short terminal root page must not offer Show More despite the runtime cursor")
                capture("v2-session-list-short-terminal-no-show-more")
                app.terminate()
            }
            if index + 1 + baselineIDs.count == pageLimit {
                _ = try await probe("exactly-50-terminal", expectedCount: pageLimit, expectedRemainder: 0)
            }
        }
        let (firstIDs, nextIDs) = try await probe("genuine-next-page", expectedCount: pageLimit, expectedRemainder: baselineIDs.count + 2)
        let ownedNext = nextIDs.intersection(ownedIDs)
        XCTAssertFalse(ownedNext.isEmpty, "The next page must include an owned root, not only pre-existing inventory")
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app)
        let newest = "session.row.\(ownedIDs.last!)"
        try await waitForV2Smoke(in: app, "Global navigation must settle before selecting its list") {
            app.navigationBars["Global"].exists && app.buttons["sessions.create"].isHittable
                && app.collectionViews.count == 1 && app.collectionViews.firstMatch.buttons[newest].exists
        }
        let list = app.collectionViews.firstMatch
        // Home may hydrate up to 100 recent roots. A real user refresh establishes
        // the session list's 50-row page without fake routing or cache manipulation.
        capture("v2-session-list-before-native-refresh")
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(
            forDuration: 0.05,
            thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
            withVelocity: .slow,
            thenHoldForDuration: 0.5
        )
        try await waitForV2Smoke(in: app, "Native refresh must retain the newest owned root", timeout: 20) { list.buttons[newest].isHittable }
        capture("v2-session-list-after-native-refresh")
        let more = list.buttons["Show More"]
        var seen = Set<String>()
        @MainActor
        func observeRows() {
            let ids = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'session.row.'")).allElementsBoundByIndex.map { String($0.identifier.dropFirst("session.row.".count)) }
            XCTAssertEqual(ids.count, Set(ids).count, "The rendered list must not contain duplicate session rows")
            seen.formUnion(ids)
        }
        for _ in 0..<20 {
            observeRows()
            if more.exists && more.isHittable && more.frame.maxY < app.buttons["sessions.create"].frame.minY { break }
            list.swipeUp()
        }
        try await waitForV2Smoke(in: app, "A genuine older root page must expose Show More above the bottom toolbar") {
            more.exists && more.isHittable && more.frame.maxY < app.buttons["sessions.create"].frame.minY
        }
        XCTAssertEqual(seen, firstIDs, "The initial UI must contain only the real first page, not sessions inserted by fixture SSE")
        XCTAssertTrue(seen.isDisjoint(with: nextIDs))
        capture("v2-session-list-genuine-show-more")
        more.tap()
        try await waitForV2Smoke(in: app, "Loading the final root page must remove Show More") {
            !more.exists && ownedNext.allSatisfy { list.buttons["session.row.\($0)"].exists }
        }
        list.swipeUp()
        observeRows()
        for id in ownedNext { XCTAssertTrue(list.buttons["session.row.\(id)"].exists) }
        capture("v2-session-list-final-page-no-show-more")
        for _ in 0..<20 {
            observeRows()
            if seen == firstIDs.union(nextIDs) { break }
            list.swipeDown()
        }
        XCTAssertEqual(seen, firstIDs.union(nextIDs), "All roots must remain reachable exactly once across the two pages")
        XCTAssertFalse(more.exists)
        app.terminate()
    }

    @MainActor
    func testV2TerminalShortAndLongAnswerHaveNoHistoryDisclosureAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        for longAnswer in [false, true] {
            let paragraphs = (1...4).map { index in
                "Answer section \(index). " + String(repeating: "This offline answer is fully available without expanding history. ", count: 9)
            }
            let answer = longAnswer ? paragraphs.joined(separator: "\n\n") + "\n\nAnswer complete." : "Short answer complete."
            let fixture = try await ownedV2Chat(backend: backend, directory: directory, assistantText: answer)
            let page = try await backend.request("api/session/\(fixture.sessionID)/message", query: [
                .init(name: "order", value: "desc"), .init(name: "limit", value: "200")
            ])
            XCTAssertEqual((page["data"] as? [[String: Any]])?.count, 2)
            let cursor = try XCTUnwrap((page["cursor"] as? [String: Any])?["next"] as? String)
            let terminal = try await backend.request("api/session/\(fixture.sessionID)/message", query: [
                .init(name: "cursor", value: cursor), .init(name: "limit", value: "1")
            ])
            XCTAssertEqual((terminal["data"] as? [[String: Any]])?.count, 0)
            let evidence = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: ["page": page, "lookahead": terminal], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            evidence.name = "v2-history-\(longAnswer ? "long" : "short")-actual-GET"
            evidence.lifetime = .keepAlways
            add(evidence)
            app.launch()
            _ = try await prepareV2SmokeLayout(in: app)
            try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
            let search = app.textFields["projects.searchChats"]
            try await waitForV2Smoke(in: app, "Expected owned history fixture search") { search.isHittable }
            search.tap()
            search.typeText(fixture.title)
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", fixture.title, "session.row.\(fixture.sessionID)")).firstMatch
            try await waitForV2Smoke(in: app, "Expected owned history fixture result") { row.isHittable }
            row.tap()
            let transcript = app.collectionViews["chat.scroll"]
            let end = transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", longAnswer ? "Answer complete." : answer)).firstMatch
            try await waitForV2Smoke(in: app, "Terminal answer must render without a disclosure tap") { transcript.exists && end.exists }
            attachScreenshot(named: "v2-history-\(longAnswer ? "long" : "short")-answer-tail-without-expansion")
            let markers = longAnswer ? [fixture.userText] + (1...4).map { "Answer section \($0)." } + ["Answer complete."] : [fixture.userText, answer]
            var observed = Set<String>()
            for _ in 0..<12 {
                for marker in markers where transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.exists {
                    observed.insert(marker)
                }
                XCTAssertFalse(app.buttons["chat-older-messages-button"].exists)
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'View older messages' OR label == 'Load earlier messages' OR label == 'Show earlier activity' OR label == 'Show more'")).firstMatch.exists)
                if observed.count == markers.count && transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.userText)).firstMatch.isHittable { break }
                transcript.swipeDown()
            }
            XCTAssertEqual(observed, Set(markers), "Every answer section and the prompt must be reachable by scrolling alone")
            attachScreenshot(named: "v2-history-\(longAnswer ? "long" : "short")-terminal-no-disclosure")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "v2-history-\(longAnswer ? "long" : "short")-terminal-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.terminate()
        }
    }

    @MainActor
    func testV2RealHiddenMessagesRevealAndTerminalPageBoundariesAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        // Probe real full pages without an excessive 200-message UI traversal.
        for count in [200, 202] {
            let fixture = try await ownedV2Chat(backend: backend, directory: directory, messageCount: count)
            let page = try await backend.request("api/session/\(fixture.sessionID)/message", query: [
                .init(name: "order", value: "desc"), .init(name: "limit", value: "200")
            ])
            let rows = try XCTUnwrap(page["data"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 200)
            let cursor = try XCTUnwrap((page["cursor"] as? [String: Any])?["next"] as? String)
            let probe = try await backend.request("api/session/\(fixture.sessionID)/message", query: [
                .init(name: "cursor", value: cursor), .init(name: "limit", value: "1")
            ])
            let older = try await backend.request("api/session/\(fixture.sessionID)/message", query: [
                .init(name: "cursor", value: cursor), .init(name: "limit", value: "200")
            ])
            let probeRows = try XCTUnwrap(probe["data"] as? [[String: Any]])
            let olderRows = try XCTUnwrap(older["data"] as? [[String: Any]])
            XCTAssertEqual(probeRows.count, count == 200 ? 0 : 1)
            XCTAssertEqual(olderRows.count, count - 200)
            XCTAssertEqual(probeRows.first?["id"] as? String, olderRows.first?["id"] as? String, "Lookahead must not consume the original opaque boundary")
            let ids = (rows + olderRows).compactMap { $0["id"] as? String }
            XCTAssertEqual(Set(ids).count, count)
            let evidence = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: ["page": page, "lookahead": probe, "originalCursorPage": older], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            evidence.name = "v2-history-\(count)-actual-GET-boundary"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        let fixture = try await ownedV2Chat(backend: backend, directory: directory, messageCount: 14)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        let transcript = app.collectionViews["chat.scroll"]
        let older = app.buttons["chat-older-messages-button"]
        for _ in 0..<10 {
            if older.exists && older.isHittable { break }
            transcript.swipeDown()
        }
        try await waitForV2Smoke(in: app, "Two real hidden messages must expose the cached-window history control") { older.isHittable }
        XCTAssertEqual(older.label, "View older messages (2)")
        attachScreenshot(named: "v2-history-14-two-real-hidden-messages")
        let before = XCTAttachment(string: app.debugDescription)
        before.name = "v2-history-14-before-reveal-hierarchy"
        before.lifetime = .keepAlways
        add(before)
        older.tap()
        try await waitForV2Smoke(in: app, "History control must disappear when every real message is revealed") { !older.exists }
        let first = transcript.staticTexts["History message 1."]
        let navigationBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? transcript.frame.minY
        for _ in 0..<6 {
            if first.exists && first.isHittable && first.frame.minY >= navigationBottom { break }
            transcript.swipeDown()
        }
        XCTAssertTrue(first.exists && first.isHittable, "The oldest actual message must become visible")
        XCTAssertGreaterThanOrEqual(first.frame.minY, navigationBottom, "The oldest row must be below the navigation bar, not merely accessibility-hittable")
        XCTAssertFalse(app.buttons["Load earlier messages"].exists)
        XCTAssertFalse(app.buttons["Show earlier activity"].exists)
        attachScreenshot(named: "v2-history-14-all-revealed-no-history-control")
        let after = XCTAttachment(string: app.debugDescription)
        after.name = "v2-history-14-after-reveal-hierarchy"
        after.lifetime = .keepAlways
        add(after)
        app.terminate()
    }

    @MainActor
    func testV2OwnedTranscriptSurvivesColdRelaunchAndReopenAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        app.terminate()
        app.launch()
        try await openV2OwnedChat(fixture, in: app)
        attachScreenshot(named: "v2-owned-transcript-cold-reopen")
    }

    @MainActor
    func testV2GlobalFormsSessionlessTypedReplyCloseAndChatCancelAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let ids = (0..<3).map { "frm_pass6_\($0)_\(UUID().uuidString)" }
        let query = [URLQueryItem(name: "location[directory]", value: directory)]
        addTeardownBlock { @MainActor in
            app.terminate()
            for id in ids {
                let result = try await backend.request("api/session/global/form/\(id)/state", query: query, allowsNotFound: true)
                if (result["data"] as? [String: Any])?["status"] as? String == "pending" {
                    _ = try await backend.request("api/session/global/form/\(id)/cancel", method: "POST", query: query)
                }
            }
        }
        _ = try await backend.request("api/session/global/form", method: "POST", body: [
            "id": ids[0], "title": "Project approval", "metadata": ["kind": "mcp-elicitation", "message": "Disposable project request"],
            "fields": [["key": "count", "type": "integer", "title": "Count", "default": 7],
                       ["key": "enabled", "type": "boolean", "title": "Enabled", "required": true]]
        ], query: query)
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let open = app.buttons["globalForms.open"]
        try await waitForV2Smoke(in: app, "Sessionless Home must expose hydrated global requests") { open.exists && open.isHittable }
        open.tap()
        let panel = app.descendants(matching: .any)["chat.sessionForm.\(ids[0])"].firstMatch
        let enabled = app.descendants(matching: .any)["form.field.enabled"].firstMatch
        try await revealV2FormControl(enabled, panel: panel, in: app)
        enabled.buttons.firstMatch.tap()
        app.buttons["No"].firstMatch.tap()
        app.buttons["globalForms.close"].tap()
        let stillPending = try await backend.request("api/session/global/form/\(ids[0])/state", query: query)
        XCTAssertEqual((stillPending["data"] as? [String: Any])?["status"] as? String, "pending")
        open.tap()
        let submit = app.buttons.matching(identifier: "chat.sessionForm.\(ids[0])").matching(NSPredicate(format: "label == %@", "Submit")).firstMatch
        try await waitForV2Smoke(in: app, "Reopened draft can submit") { submit.exists && submit.isHittable && submit.isEnabled }
        _ = try await backend.request("api/session/global/form", method: "POST", body: [
            "id": ids[1], "title": "Next project request", "fields": [["key": "note", "type": "string"]]
        ], query: query)
        attachScreenshot(named: "pass6-global-home-draft")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "pass6-global-home-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        submit.tap()
        let state = try await backend.request("api/session/global/form/\(ids[0])/state", query: query)
        let answer = try XCTUnwrap((state["data"] as? [String: Any])?["answer"] as? [String: Any])
        XCTAssertEqual(answer["enabled"] as? Bool, false)
        XCTAssertEqual(answer["count"] as? Int, 7)
        let cancel = app.buttons.matching(identifier: "chat.sessionForm.\(ids[1])").matching(NSPredicate(format: "label == %@", "Cancel Request")).firstMatch
        try await waitForV2Smoke(in: app, "SSE next pending request replaces the settled form") { cancel.exists && cancel.isHittable }
        cancel.tap()
        try await waitForV2Smoke(in: app, "All project forms settled") { app.staticTexts["globalForms.empty"].exists }
        app.buttons["globalForms.close"].tap()
        XCTAssertFalse(open.exists)

        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        app.terminate(); app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        _ = try await backend.request("api/session/global/form", method: "POST", body: [
            "id": ids[2], "title": "Location input from chat", "fields": [["key": "note", "type": "string"]]
        ], query: query)
        try await waitForV2Smoke(in: app, "Shared SSE must expose a global request from chat") { open.exists && open.isHittable }
        XCTAssertFalse(app.buttons["chat.composer.menu"].isEnabled)
        XCTAssertTrue(app.buttons["chat.dictate"].exists)
        XCTAssertFalse(app.buttons["chat.dictate"].isEnabled, "New recording must be blocked, not the entire composer")
        if app.buttons["chat.stop"].exists { XCTAssertTrue(app.buttons["chat.stop"].isEnabled) }
        attachScreenshot(named: "pass6-global-chat-blocked")
        open.tap()
        let chatCancel = app.buttons.matching(identifier: "chat.sessionForm.\(ids[2])").matching(NSPredicate(format: "label == %@", "Cancel Request")).firstMatch
        try await waitForV2Smoke(in: app, "Global cancellation is reachable in chat") { chatCancel.exists && chatCancel.isHittable }
        chatCancel.tap()
        try await waitForV2Smoke(in: app, "Cancelled global request disappears") { app.staticTexts["globalForms.empty"].exists }
        app.buttons["globalForms.close"].tap()
        try await waitForV2Smoke(in: app, "Chat composer is restored without session reassignment") { app.buttons["chat.composer.menu"].isEnabled }
        let cancelled = try await backend.request("api/session/global/form/\(ids[2])/state", query: query)
        XCTAssertEqual((cancelled["data"] as? [String: Any])?["status"] as? String, "cancelled")
        attachScreenshot(named: "pass6-global-chat-restored")
    }

    @MainActor
    func testV2NativeFormAppearsInOpenChatSubmitsTypedAnswerAndCancelsAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        // Teardown blocks run in reverse order: stop active form/event traffic
        // before the fixture's registered session deletions run.
        addTeardownBlock { @MainActor in app.terminate() }
        app.launch()
        _ = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        let formID = "frm_\(UUID().uuidString)"
        let fields: [[String: Any]] = [
            ["key": "optional", "type": "string", "title": "Optional note"],
            ["key": "count", "type": "integer", "title": "Default count", "default": 7],
            ["key": "enabled", "type": "boolean", "title": "Enable follow-up", "required": true],
            ["key": "conditional", "type": "string", "title": "Conditional detail", "default": "visible",
             "when": [["key": "enabled", "op": "eq", "value": false]]],
            ["key": "hidden", "type": "string", "title": "Hidden detail", "default": "must not leak",
             "when": [["key": "enabled", "op": "eq", "value": true]]],
            ["key": "choices", "type": "multiselect", "title": "Selections", "custom": true,
             "options": [["value": "a", "label": "Fixture option A"]]],
            ["key": "ack", "type": "external", "title": "Offline acknowledgement",
             "url": "http://127.0.0.1:14097/never-open"]
        ]
        // Create on the exact open chat only after hydration. No relaunch or pull may reveal it.
        let created = try await backend.request("api/session/\(fixture.sessionID)/form", method: "POST", body: [
            "id": formID, "title": "Owned UI form \(formID)", "fields": fields
        ])
        let form = try XCTUnwrap(created["data"] as? [String: Any])
        XCTAssertEqual(form["id"] as? String, formID)
        XCTAssertEqual(form["sessionID"] as? String, fixture.sessionID)
        let panel = app.descendants(matching: .any)["chat.sessionForm.\(formID)"].firstMatch
        try await waitForV2Smoke(in: app, "Expected the live native form in the already open owned chat", timeout: 20) { panel.exists }
        let optional = app.descendants(matching: .any)["form.field.optional"].firstMatch
        let count = app.descendants(matching: .any)["form.field.count"].firstMatch
        try await revealV2FormControl(optional, panel: panel, in: app)
        // Do not enter optional data: an omitted answer must stay absent, not become an empty string.
        try await revealV2FormControl(count, panel: panel, in: app)
        let displayedCount = try XCTUnwrap(count.textFields.firstMatch.value as? String)
        XCTAssertEqual(Double(displayedCount), 7)
        let enabled = app.descendants(matching: .any)["form.field.enabled"].firstMatch
        try await revealV2FormControl(enabled, panel: panel, in: app)
        XCTAssertFalse(app.descendants(matching: .any)["form.field.conditional"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["form.field.hidden"].firstMatch.exists)
        let picker = enabled.buttons.firstMatch
        try await waitForV2Smoke(in: app, "Expected the boolean Not Set/Yes/No picker") { picker.exists && picker.isHittable }
        picker.tap()
        let no = app.buttons["No"].firstMatch
        try await waitForV2Smoke(in: app, "Expected explicit boolean false selection") { no.exists && no.isHittable }
        no.tap()
        let conditional = app.descendants(matching: .any)["form.field.conditional"].firstMatch
        try await waitForV2Smoke(in: app, "Boolean false must activate its conditional field") { conditional.exists }
        XCTAssertFalse(app.descendants(matching: .any)["form.field.hidden"].firstMatch.exists)
        let choices = app.descendants(matching: .any)["form.field.choices"].firstMatch
        let option = choices.buttons["Fixture option A"]
        try await revealV2FormControl(option, panel: panel, in: app)
        option.tap()
        try await waitForV2Smoke(in: app, "Expected the catalog multiselect option to be selected") { option.isSelected }
        attachScreenshot(named: "v2-native-form-catalog-option-selected")
        let custom = choices.textFields["Type your answer"]
        try await revealV2FormControl(custom, panel: panel, in: app)
        custom.tap()
        custom.typeText("custom-fixture")
        let add = choices.buttons["Add"]
        try await revealV2FormControl(add, panel: panel, in: app)
        add.tap()
        try await waitForV2Smoke(in: app, "Custom selection must retain the selected catalog option") {
            option.isSelected && choices.staticTexts["custom-fixture"].exists
        }
        let ack = app.descendants(matching: .any)["form.field.ack"].firstMatch
        let acknowledgement = ack.switches.firstMatch
        try await revealV2FormControl(acknowledgement, panel: panel, in: app)
        XCTAssertFalse(isSwitchOn(acknowledgement))
        let acknowledgementControl = acknowledgement.switches.firstMatch
        try await revealV2FormControl(acknowledgementControl, panel: panel, in: app)
        acknowledgementControl.tap()
        try await waitForV2Smoke(in: app, "Expected explicit external acknowledgement") { self.isSwitchOn(acknowledgement) }
        // Never tap Open Browser: acknowledging an offline fixture needs no external network.
        let submit = app.buttons.matching(identifier: "chat.sessionForm.\(formID)").matching(NSPredicate(format: "label == %@", "Submit")).firstMatch
        try await waitForV2Smoke(in: app, "Expected enabled native form submission") { submit.exists && submit.isHittable && submit.isEnabled }
        attachScreenshot(named: "v2-native-form-ready-to-submit")
        submit.tap()
        try await waitForV2Smoke(in: app, "Successful submit must dismiss only the settled form") { !panel.exists }
        let answered = try await backend.formState(sessionID: fixture.sessionID, formID: formID)
        XCTAssertEqual(answered, .answered([
            "count": .number(7), "enabled": .boolean(false), "conditional": .string("visible"),
            "choices": .strings(["a", "custom-fixture"]), "ack": .boolean(true)
        ]))

        let cancelID = "frm_\(UUID().uuidString)"
        _ = try await backend.request("api/session/\(fixture.sessionID)/form", method: "POST", body: [
            "id": cancelID, "title": "Owned cancellation \(cancelID)", "fields": [["key": "note", "type": "string"]]
        ])
        let cancel = app.buttons.matching(identifier: "chat.sessionForm.\(cancelID)").matching(NSPredicate(format: "label == %@", "Cancel Request")).firstMatch
        try await waitForV2Smoke(in: app, "Expected the next live form cancellation action", timeout: 20) { cancel.exists && cancel.isHittable }
        cancel.tap()
        try await waitForV2Smoke(in: app, "Cancellation must restore the chat composer") {
            !cancel.exists && app.buttons["chat.composer.menu"].exists
        }
        let cancelled = try await backend.formState(sessionID: fixture.sessionID, formID: cancelID)
        XCTAssertEqual(cancelled, .cancelled)
        let pending = try await backend.request("api/session/\(fixture.sessionID)/form")
        XCTAssertEqual((pending["data"] as? [[String: Any]])?.count, 0)
        attachScreenshot(named: "v2-native-form-cancelled")
    }

    @MainActor
    func testV2WorkspaceDestinationCancellationAndOwnedSessionNavigationAgainstIsolatedBackend() async throws {
        guard nonEmptyEnvironmentValue("OPENCODE_V2_TEST_WORKTREE_UI") == "1" else {
            throw XCTSkip("Set OPENCODE_V2_TEST_WORKTREE_UI=1 to opt into disposable Git fixture UI coverage")
        }
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let root = URL(fileURLWithPath: directory).resolvingSymlinksInPath().deletingLastPathComponent()
        let source = URL(fileURLWithPath: nonEmptyEnvironmentValue("OPENCODE_V2_TEST_GIT_ROOT") ?? root.appendingPathComponent("git-fixture").path)
            .resolvingSymlinksInPath().standardizedFileURL
        let parent = URL(fileURLWithPath: nonEmptyEnvironmentValue("OPENCODE_V2_TEST_WORKTREE_DESTINATION_PARENT") ?? root.appendingPathComponent("copies").path)
            .resolvingSymlinksInPath().standardizedFileURL
        guard source.path == root.appendingPathComponent("git-fixture").path,
              parent.path == root.appendingPathComponent("copies").path else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Only the approved git-fixture and sibling copies parent are permitted"])
        }
        // Keep the server's spelling for requests; simulator Foundation can drop
        // /private, which otherwise registers a second alias in the project catalog.
        let hostSource = (directory as NSString).deletingLastPathComponent + "/git-fixture"
        XCTAssertEqual(try normalizedV2FixturePath(hostSource), try normalizedV2FixturePath(source.path))
        let location = try await backend.request("api/location", query: [URLQueryItem(name: "location[directory]", value: hostSource)])
        let project = try XCTUnwrap(location["project"] as? [String: Any])
        let projectID = try XCTUnwrap(project["id"] as? String)
        XCTAssertNotEqual(projectID, "global")
        let sourceDirectory = try XCTUnwrap(project["directory"] as? String)
        let canonical = try XCTUnwrap(project["canonical"] as? String)
        XCTAssertEqual(try normalizedV2FixturePath(sourceDirectory), try normalizedV2FixturePath(source.path))
        XCTAssertEqual(try normalizedV2FixturePath(canonical), try normalizedV2FixturePath(source.path))
        let serverParent = (sourceDirectory as NSString).deletingLastPathComponent + "/copies"
        XCTAssertEqual(try normalizedV2FixturePath(serverParent), try normalizedV2FixturePath(parent.path))
        let query = [URLQueryItem(name: "location[directory]", value: sourceDirectory)]
        let name = "backend-ui-\(UUID().uuidString.lowercased())"
        let ownedDirectory = serverParent + "/" + name
        let copyPath = "experimental/project/\(projectID)/copy"
        let inventoryPath = "api/project/\(projectID)/directories"
        addTeardownBlock { @MainActor in
            let inventory = try await backend.request(inventoryPath, query: query)
            let normalizedOwned = try self.normalizedV2FixturePath(ownedDirectory)
            for worktree in try XCTUnwrap(inventory["data"] as? [[String: Any]]) {
                guard let actual = worktree["directory"] as? String,
                      actual == normalizedOwned || actual == "/private" + normalizedOwned else { continue }
                guard worktree["strategy"] as? String == "git_worktree", ownedDirectory.hasPrefix(serverParent + "/backend-ui-") else {
                    throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing unowned worktree cleanup"])
                }
                _ = try await backend.request(copyPath, method: "DELETE", body: ["directory": actual, "force": true], query: query)
            }
        }
        let created = try await backend.request(copyPath, method: "POST", body: [
            "strategy": "git_worktree", "directory": serverParent, "name": name
        ], query: query)
        XCTAssertEqual(created["directory"] as? String, ownedDirectory)
        let fixture = try await ownedV2Chat(backend: backend, directory: ownedDirectory)
        app.launch()
        let regular = try await prepareV2SmokeLayout(in: app)
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let projectRow = app.staticTexts.matching(NSPredicate(format: "label == %@ OR label == %@", sourceDirectory, source.path)).firstMatch
        try await waitForV2Smoke(in: app, "Expected the registered disposable fixture project", timeout: 30) { projectRow.exists && projectRow.isHittable }
        projectRow.tap()
        let settings = app.buttons["project.settings"]
        try await waitForV2Smoke(in: app, "Expected disposable project settings") { settings.exists && settings.isHittable }
        settings.tap()
        let toggle = app.switches["Show Workspaces"].firstMatch
        let settingsForm = app.collectionViews.containing(.switch, identifier: "Show Workspaces").firstMatch
        for _ in 0..<10 {
            if toggle.exists && toggle.isHittable { break }
            let form = settingsForm.exists ? settingsForm : app.collectionViews.firstMatch
            form.swipeUp()
        }
        try await waitForV2Smoke(in: app, "Expected the workspaces preference for the Git fixture") { toggle.exists && toggle.isHittable }
        let toggleControl = toggle.switches.firstMatch
        try await waitForV2Smoke(in: app, "Expected the enabled native Show Workspaces switch") {
            toggleControl.exists && toggleControl.isHittable && toggleControl.isEnabled
        }
        if !isSwitchOn(toggle) { toggleControl.tap() }
        try await waitForV2Smoke(in: app, "Show Workspaces must be enabled before closing settings") { self.isSwitchOn(toggle) }
        attachScreenshot(named: "v2-workspace-settings-enabled")
        app.navigationBars["Project Settings"].buttons["Done"].tap()
        // The compact TabView does not expose the child navigation toolbar. Its
        // existing section menu offers the same native New Workspace action.
        let workspaceMenu = app.buttons[regular ? "workspace.toolbar" : "workspace.actions.\(sourceDirectory)"]
        try await waitForV2Smoke(in: app, "Expected workspace-scoped sessions and creation menu", timeout: 20) {
            workspaceMenu.exists && workspaceMenu.isHittable
        }
        workspaceMenu.tap()
        let newWorkspace = app.buttons["New Workspace"].firstMatch
        try await waitForV2Smoke(in: app, "Expected native New Workspace action") { newWorkspace.exists && newWorkspace.isHittable }
        newWorkspace.tap()
        let destination = app.textFields["workspace.destinationParent"]
        try await waitForV2Smoke(in: app, "Expected destination parent field in New Workspace") { destination.exists && destination.isHittable }
        let initial = destination.value as? String ?? ""
        destination.tap()
        if !initial.isEmpty && initial != "Destination Parent Directory" {
            destination.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: initial.count))
        }
        destination.typeText(parent.path)
        XCTAssertEqual(destination.value as? String, parent.path)
        attachScreenshot(named: "v2-workspace-destination")
        let createButton = app.buttons["Create Workspace"].firstMatch
        try await waitForV2Smoke(in: app, "Expected valid destination to enable creation") { createButton.exists && createButton.isEnabled }
        let beforeCancel = try await backend.request(inventoryPath, query: query)
        app.navigationBars["New Workspace"].buttons["Cancel"].tap()
        try await waitForV2Smoke(in: app, "Cancelling must dismiss without creating a checkout") { !destination.exists }
        let afterCancel = try await backend.request(inventoryPath, query: query)
        let beforePaths = try XCTUnwrap(beforeCancel["data"] as? [[String: Any]]).compactMap { $0["directory"] as? String }
        let afterPaths = try XCTUnwrap(afterCancel["data"] as? [[String: Any]]).compactMap { $0["directory"] as? String }
        XCTAssertEqual(Set(afterPaths), Set(beforePaths))

        let row = app.buttons["session.row.\(fixture.sessionID)"]
        for _ in 0..<10 {
            if row.exists && row.isHittable { break }
            let list = app.collectionViews.containing(.button, identifier: "workspace.actions.\(ownedDirectory)").firstMatch
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        try await waitForV2Smoke(in: app, "Expected the session inside the exact owned worktree section", timeout: 20) { row.exists && row.isHittable }
        row.tap()
        let assistant = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch
        let composer = app.buttons["chat.composer.menu"]
        try await waitForV2Smoke(in: app, "Workspace session selection must open its transcript", timeout: 20) {
            assistant.exists && composer.exists && composer.isHittable
                && assistant.frame.minX >= app.frame.minX && assistant.frame.maxX <= app.frame.maxX
        }
        attachScreenshot(named: "v2-workspace-owned-session")
    }

    @MainActor
    private func normalizedV2FixturePath(_ path: String) throws -> String {
        let approved = "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass2-VwCj6l/"
        // Lexical normalization only: never resolve arbitrary host symlinks for ownership.
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalized = standardized.hasPrefix("/private" + approved) ? String(standardized.dropFirst("/private".count)) : standardized
        guard path.hasPrefix("/"), normalized.hasPrefix(approved) else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is outside the exact approved fixture"])
        }
        return normalized
    }

    @MainActor
    private func revealV2FormControl(_ control: XCUIElement, panel: XCUIElement, in app: XCUIApplication) async throws {
        // SwiftUI propagates the panel ID to sibling title/scroll/actions rather
        // than exposing one enclosing accessibility container.
        let scroll = app.scrollViews.matching(identifier: panel.identifier).firstMatch
        try await waitForV2Smoke(in: app, "Expected the bounded native form scroll view") { scroll.exists }
        @MainActor
        func isFullyVisible() -> Bool {
            guard control.exists && control.isHittable else { return false }
            let viewport = scroll.frame
            let target = control.frame
            // Require the complete vertical target, allowing only subpoint rounding.
            // The last switch is flush with the content bottom, and its native thumb
            // extends horizontally beyond the SwiftUI row, so an inset CGRect fails.
            return target.height > 0 && target.minY >= viewport.minY - 0.5 && target.maxY <= viewport.maxY + 0.5
        }
        for _ in 0..<12 {
            // A center-only check accepted the iPad option 0.25pt above the clipped
            // bottom edge. Keep the whole target clear of the scroll/footer boundary.
            if isFullyVisible() { return }
            let above = control.exists && control.frame.minY < scroll.frame.minY - 0.5
            // Settle before lifting so inertial scrolling cannot overshoot the
            // small viewport and alternate past the target in both directions.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.3 : 0.75))
                .press(forDuration: 0.05,
                       thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.75 : 0.3)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        try await waitForV2Smoke(in: app, "Expected fully visible native form control \(control.label)", until: isFullyVisible)
    }

    @MainActor
    func testV2WindowComposerIsolationAgainstIsolatedBackend() async throws {
        let (backend, app, directory) = try await isolatedV2FeatureContext()
        let fixture = try await ownedV2Chat(backend: backend, directory: directory)
        addTeardownBlock { @MainActor in
            if app.state == .runningForeground,
               app.descendants(matching: .any)["chat.dedicatedWindow"].firstMatch.exists {
                app.typeKey("w", modifierFlags: .command)
            }
            app.terminate()
        }
        app.launch()
        let regular = try await prepareV2SmokeLayout(in: app)
        try await openV2OwnedChat(fixture, in: app)
        let composer = app.textViews["chat.input"].firstMatch
        try await waitForV2Smoke(in: app, "Expected editable root composer") { composer.exists && composer.isHittable }
        composer.tap()
        composer.typeText("Root-only draft")
        let windowButton = app.buttons["chat.toolbar.openWindow"]
        if !regular {
            XCTAssertFalse(windowButton.exists, "iPhone must not offer unsupported multiwindow")
            XCTAssertEqual(composer.value as? String, "Root-only draft")
            attachScreenshot(named: "pass8-window-iphone-no-multiwindow")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "pass8-window-iphone-capability-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            return
        }
        try await waitForV2Smoke(in: app, "Expected native open-window action") { windowButton.exists && windowButton.isHittable }
        windowButton.tap()
        let dedicated = app.descendants(matching: .any)["chat.dedicatedWindow"].firstMatch
        try await waitForV2Smoke(in: app, "Expected validated dedicated chat", timeout: 30) {
            dedicated.exists && !app.descendants(matching: .any)["chat.dedicatedWindow.unavailable"].exists
        }
        let isolatedComposer = dedicated.textViews["chat.input"].firstMatch
        try await waitForV2Smoke(in: app, "Expected independent editable composer") {
            isolatedComposer.exists && isolatedComposer.isHittable
        }
        XCTAssertNotEqual(isolatedComposer.value as? String, "Root-only draft")
        isolatedComposer.tap()
        isolatedComposer.typeText("Window-only draft")
        XCTAssertEqual(isolatedComposer.value as? String, "Window-only draft")
        XCTAssertTrue(dedicated.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.assistantText)).firstMatch.exists)
        attachScreenshot(named: "pass8-window-independent-draft")
        let childHierarchy = XCTAttachment(string: app.debugDescription)
        childHierarchy.name = "pass8-window-child-context-hierarchy"
        childHierarchy.lifetime = .keepAlways
        add(childHierarchy)
        // Close the native child scene, not the app/process, and prove that its
        // independent edits did not replace the still-open main window's draft.
        app.typeKey("w", modifierFlags: .command)
        try await waitForV2Smoke(in: app, "Closing the child window must reveal the original main-window draft", timeout: 20) {
            !dedicated.exists && windowButton.exists && windowButton.isHittable
                && composer.exists && (composer.value as? String) == "Root-only draft"
        }
        attachScreenshot(named: "pass8-window-main-draft-preserved-after-child-close")
        let rootHierarchy = XCTAttachment(string: app.debugDescription)
        rootHierarchy.name = "pass8-window-main-context-hierarchy"
        rootHierarchy.lifetime = .keepAlways
        add(rootHierarchy)
        // This test never sends a prompt or invokes a model provider.
    }

    @MainActor
    private func isolatedV2FeatureContext() async throws -> (V2SmokeBackend, XCUIApplication, String) {
        guard let base = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_BASE_URL"),
              let username = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_USERNAME"),
              let password = nonEmptyEnvironmentValue("OPENCODE_V2_TEST_PASSWORD") else {
            throw XCTSkip("Set OPENCODE_V2_TEST_BASE_URL/USERNAME/PASSWORD for isolated feature UI tests")
        }
        let url = try XCTUnwrap(URL(string: base))
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Only the isolated server on port 14097 is permitted"])
        }
        let backend = V2SmokeBackend(baseURL: url, username: username, password: password)
        let health = try await backend.request("api/health")
        XCTAssertEqual(health["version"] as? String, "0.0.0-next-17155")
        let location = try await backend.request("api/location")
        let directory = try XCTUnwrap(location["directory"] as? String)
        let workspace = URL(fileURLWithPath: directory).resolvingSymlinksInPath().standardizedFileURL
        let root = workspace.deletingLastPathComponent()
        let approved = URL(fileURLWithPath: "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode")
            .resolvingSymlinksInPath().standardizedFileURL
        guard (location["project"] as? [String: Any])?["id"] as? String == "global",
              workspace.lastPathComponent == "workspace", root.lastPathComponent == "pass2-VwCj6l",
              root.deletingLastPathComponent() == approved else {
            throw NSError(domain: "V2UIFeature", code: 1, userInfo: [NSLocalizedDescriptionKey: "Refusing a server outside the approved disposable pass2 fixture"])
        }
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // launchEnvironment initially contains Xcode's configured app environment.
        // Never inherit another test's auto-send bootstrap or storage/visual fixture.
        // The pass5 share tests add their own UUID-scoped seed after this setup returns.
        for key in ["OPENCLIENT_SCREENSHOT_SCENE", "OPENCODE_UI_TEST_SESSION_TITLE", "OPENCODE_UI_TEST_PROMPT",
                    "OPENCODE_UI_TEST_DIRECTORY", "OPENCODE_UI_TEST_VIDEO_RESOURCE_ID",
                    "OPENCODE_UI_TEST_SHARE_PAYLOAD", "OPENCODE_UI_TEST_SHARE_CLEANUP_ID"] {
            app.launchEnvironment.removeValue(forKey: key)
        }
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_BASE_URL"] = base
        app.launchEnvironment["OPENCODE_UI_TEST_USERNAME"] = username
        app.launchEnvironment["OPENCODE_UI_TEST_PASSWORD"] = password
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        addTeardownBlock { @MainActor in
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        return (backend, app, directory)
    }

    @MainActor
    private func ownedV2Chat(backend: V2SmokeBackend, directory: String, messageCount: Int = 2, assistantText: String? = nil) async throws -> V2OwnedChatFixture {
        let seedID = "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let id = "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let title = "V2 Owned Chat \(UUID().uuidString)"
        // Pre-register both exact IDs, including creation/import response-loss cases.
        addTeardownBlock { @MainActor in
            for ownedID in [seedID, id] {
                _ = try await backend.request("api/session/\(ownedID)", method: "DELETE", allowsNotFound: true)
            }
        }
        let created = try await backend.request("api/session", method: "POST", body: [
            "id": seedID, "title": "Seed \(title)", "location": ["directory": directory]
        ])
        let info = try XCTUnwrap(created["data"] as? [String: Any])
        XCTAssertEqual(info["id"] as? String, seedID)
        return try await backend.importTranscript(info: info, sessionID: id, title: title, directory: directory,
                                                  userText: "Owned user \(id)", assistantText: assistantText ?? "Owned assistant \(id)", messageCount: messageCount)
    }

    @MainActor
    private func openV2OwnedChat(_ fixture: V2OwnedChatFixture, in app: XCUIApplication, expectedAssistant: String? = nil) async throws {
        try await connectV2SmokeAndSelectGlobal(in: app, selectGlobal: false)
        let search = app.textFields["projects.searchChats"]
        try await waitForV2Smoke(in: app, "Expected owned-chat home search") { search.exists && search.isHittable }
        search.tap()
        search.typeText(fixture.title)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", fixture.title))
            .matching(NSPredicate(format: "identifier != %@", "session.row.\(fixture.sessionID)")).firstMatch
        try await waitForV2Smoke(in: app, "Expected the exact owned transcript search result", timeout: 30) { row.exists && row.isHittable }
        row.tap()
        try await waitForV2Smoke(in: app, "Expected the owned user and canonical assistant in open chat", timeout: 20) {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", fixture.userText)).firstMatch.exists
                && app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expectedAssistant ?? fixture.assistantText)).firstMatch.exists
                && app.buttons["chat.composer.menu"].exists
        }
    }

    @MainActor
    private func prepareV2SmokeLayout(in app: XCUIApplication) async throws -> Bool {
        // A prior multiwindow test can leave an unavailable child scene restored
        // in front. Only close that observed scene; never dismiss a valid chat or
        // substitute a synthetic route for the real main-window connection form.
        for _ in 0..<3 {
            let unavailable = app.staticTexts["chat.dedicatedWindow.unavailable"].firstMatch
            guard !app.collectionViews["connection.form"].exists,
                  unavailable.exists && unavailable.isHittable else { break }
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "v2-restored-unavailable-window-before-native-close"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.typeKey("w", modifierFlags: .command)
        }
        let window = app.windows.firstMatch
        try await waitForV2Smoke(in: app, "Expected the connection form in a measurable app window") {
            window.exists && window.frame.width > 0 && window.frame.height > 0
                && app.collectionViews["connection.form"].exists
        }
        let iPad = (environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "").hasPrefix("iPad")
            || (environment["SIMULATOR_DEVICE_NAME"] ?? "").localizedCaseInsensitiveContains("iPad")
            || min(window.frame.width, window.frame.height) > 700
        XCUIDevice.shared.orientation = iPad ? .landscapeLeft : .portrait
        if iPad {
            let deadline = Date().addingTimeInterval(2)
            while window.frame.width < window.frame.height && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if window.frame.width < window.frame.height {
                // Retry rotation once without changing rotation-lock or app preferences.
                XCUIDevice.shared.press(.home)
                XCUIDevice.shared.orientation = .landscapeLeft
                app.activate()
            }
        }
        try await waitForV2Smoke(in: app, "Expected compact iPhone or regular-width iPad app window") {
            let frame = window.frame
            return iPad ? frame.width > 700 : frame.width > 0 && frame.width < 700 && frame.height > frame.width
        }
        let frame = window.frame
        let observedOrientation = frame.width > frame.height ? "landscape" : "portrait"
        let layout = XCTAttachment(string: "Requested: \(iPad ? "landscapeLeft" : "portrait"); reported device orientation: \(XCUIDevice.shared.orientation.rawValue); observed app window: \(frame); observed orientation: \(observedOrientation). Regular-width iPad portrait is supported; a landscape request is not proof of rotation.")
        layout.name = "v2-observed-window-layout"
        layout.lifetime = .keepAlways
        add(layout)
        attachScreenshot(named: "v2-layout-\(iPad ? "ipad" : "iphone")-\(observedOrientation)")
        return frame.width > 700
    }

    @MainActor
    private func connectV2SmokeAndSelectGlobal(in app: XCUIApplication, selectGlobal: Bool = true) async throws {
        let form = app.collectionViews["connection.form"]
        try await waitForV2Smoke(in: app, "Expected automatic connection form") { form.exists }

        @MainActor
        func reveal(_ button: XCUIElement, named name: String) async throws {
            for _ in 0 ..< 6 {
                if button.exists && button.isHittable { break }
                form.swipeUp()
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try await waitForV2Smoke(in: app, "Expected visible \(name) in the connection form", timeout: 2) {
                button.exists && button.isHittable && button.isEnabled
            }
        }

        let connect = app.buttons["connection.connect"]
        try await reveal(connect, named: "Connect button")
        connect.tap()
        try await waitForV2Smoke(in: app, "Expected connection sheet to dismiss after connecting", timeout: 30) {
            !app.navigationBars["OpenClient"].exists
        }
        let global = app.staticTexts.matching(identifier: "Global").firstMatch
        let dismissNotice = app.buttons["connection.v2-notice.dismiss"]
        try await waitForV2Smoke(in: app, "Automatic detection must present the v2 notice after bootstrap", timeout: 15) { dismissNotice.isHittable }
        dismissNotice.tap()
        try await waitForV2Smoke(in: app, "Expected visible Global project after automatic v2 detection", timeout: 30) {
            global.exists && global.isHittable
        }
        if selectGlobal { global.tap() }
    }

    @MainActor
    private func waitForV2Smoke(
        in app: XCUIApplication,
        _ message: String,
        timeout: TimeInterval = 10,
        until condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline

        attachScreenshot(named: "v2-smoke-failure-\(message)")
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "V2 Smoke Failure: \(message)"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // XCTest records the thrown error, and throwing prevents cascading UI actions.
        throw NSError(domain: "V2UISmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
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

@MainActor
private struct V2SmokeBackend {
    let baseURL: URL
    let username: String
    let password: String

    func importTranscript(info: [String: Any], sessionID: String, title: String, directory: String,
                          userText: String, assistantText: String, messageCount: Int = 2) async throws -> V2OwnedChatFixture {
        var info = info
        info["id"] = sessionID
        info["title"] = title
        let now = Date().timeIntervalSince1970 * 1_000
        info["time"] = ["created": now, "updated": now]
        let assistantID = "msg_\(UUID().uuidString)"
        let leading: [[String: Any]] = (0..<max(0, messageCount - 2)).map { index in
            ["id": "msg_\(UUID().uuidString)", "type": "user", "time": ["created": now - Double(messageCount - index)], "text": "History message \(index + 1)."]
        }
        let messages: [[String: Any]] = leading + [
            ["id": "msg_\(UUID().uuidString)", "type": "user", "time": ["created": now], "text": userText],
            ["id": assistantID, "type": "assistant", "time": ["created": now + 1, "completed": now + 2],
             "agent": info["agent"] as? String ?? "build",
             "model": info["model"] as? [String: Any] ?? ["providerID": "smoke", "id": "offline-fixture"],
             "content": [["type": "text", "text": assistantText]], "finish": "stop"]
        ]
        let imported = try await request("api/session/import", method: "POST", body: [
            "info": info, "messages": messages, "location": ["directory": directory]
        ])
        XCTAssertEqual((imported["data"] as? [String: Any])?["id"] as? String, sessionID)
        return .init(sessionID: sessionID, title: title, directory: directory, userText: userText,
                     assistantText: assistantText, assistantMessageID: assistantID)
    }

    func formState(sessionID: String, formID: String) async throws -> V2UIFormState {
        let response = try await request("api/session/\(sessionID)/form/\(formID)/state")
        return try JSONDecoder().decode(V2UIFormState.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(response["data"])))
    }

    func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        query: [URLQueryItem] = [],
        allowsNotFound: Bool = false
    ) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if allowsNotFound, status == 404 { return [:] }
        guard (200 ..< 300).contains(status) else {
            throw NSError(domain: "V2UISmoke", code: status, userInfo: [
                NSLocalizedDescriptionKey: "\(method) \(path) returned HTTP \(status)"
            ])
        }
        if data.isEmpty { return [:] }
        let json = try JSONSerialization.jsonObject(with: data)
        // next-17155 project directory inventory is a bare array, not a data envelope.
        if path.hasSuffix("/directories"), let directories = json as? [[String: Any]] { return ["data": directories] }
        return try XCTUnwrap(json as? [String: Any])
    }

    func sessions(named title: String) async throws -> [[String: Any]] {
        let response = try await request("api/session", query: [
            URLQueryItem(name: "search", value: title),
            URLQueryItem(name: "project", value: "global")
        ])
        return try XCTUnwrap(response["data"] as? [[String: Any]])
            .filter { $0["title"] as? String == title }
    }

    func ptys(named title: String, directory: String) async throws -> [[String: Any]] {
        let response = try await request("api/pty", query: [URLQueryItem(name: "location[directory]", value: directory)])
        return try XCTUnwrap(response["data"] as? [[String: Any]]).filter { $0["title"] as? String == title }
    }
}

/// Static web origin only: no URLSession, upstream, authentication challenge, script,
/// or external subresource. Never reuse the authenticated OpenCode proxy for web pages.
private actor V2ManualBrowserHTTPFixture {
    nonisolated let firstTitle = "Pass5 First \(UUID().uuidString)"
    nonisolated let secondTitle = "Pass5 Second \(UUID().uuidString)"
    private let listener: NWListener
    private let queue = DispatchQueue(label: "OpenClientUITests.manual-browser-http")
    private var connections: [UUID: NWConnection] = [:]
    private var ready = false
    private var stopped = false
    private var failure: String?
    private(set) var requestedPaths: Set<String> = []
    private(set) var credentialHeaderNames: Set<String> = []

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.setReady() }
            case .failed(let error):
                let message = error.localizedDescription
                Task { await self?.setFailure(message) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { await self?.accept(connection) } }
        listener.start(queue: queue)
        let deadline = Date().addingTimeInterval(5)
        while !ready && failure == nil && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard ready, let port = listener.port else {
            throw NSError(domain: "V2BrowserFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: failure ?? "Loopback listener did not become ready"])
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    private func setReady() { ready = true }
    private func setFailure(_ message: String) { failure = message }

    func stop() {
        stopped = true
        listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)
        receive(id, buffered: Data())
    }

    private func close(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }

    private func receive(_ id: UUID, buffered: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            let failed = error != nil
            Task { await self?.received(id, buffered: buffered, data: data, complete: complete, failed: failed) }
        }
    }

    private func received(_ id: UUID, buffered: Data, data: Data?, complete: Bool, failed: Bool) {
        guard !failed, let data, !data.isEmpty else { close(id); return }
        let bytes = buffered + data
        guard bytes.count <= 65_536 else { close(id); return }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if complete { close(id) } else { receive(id, buffered: bytes) }
            return
        }
        let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        for line in lines.dropFirst() {
            let name = String(line.prefix { $0 != ":" }).lowercased()
            if ["authorization", "proxy-authorization", "cookie", "x-opencode-directory"].contains(name) {
                credentialHeaderNames.insert(name)
            }
        }
        let request = (lines.first ?? "").split(separator: " ")
        guard request.count == 3, request[0] == "GET" else { respond(id, status: 405, body: ""); return }
        let path = String(request[1])
        requestedPaths.insert(path)
        guard path == "/one" || path == "/two" else { respond(id, status: 404, body: ""); return }
        let title = path == "/one" ? firstTitle : secondTitle
        respond(id, status: 200, body: """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title></head><body><p>Body for \(title)</p>
        <a href="/two">Visit second fixture page</a></body></html>
        """)
    }

    private func respond(_ id: UUID, status: Int, body: String) {
        let data = Data(body.utf8)
        let headers = "HTTP/1.1 \(status) Fixture\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n"
        connections[id]?.send(content: Data(headers.utf8) + data, completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }
}

private struct V2OwnedChatFixture: Sendable {
    let sessionID: String
    let title: String
    let directory: String
    let userText: String
    let assistantText: String
    let assistantMessageID: String
}

/// Read-only HTTP fixture in the test runner, not an app hook. Forward real v2
/// discovery/read envelopes, but replace one owned assistant and withhold all SSE
/// events. Its actor/Network queue remain responsive during synchronous XCUI calls.
private actor V2ForegroundSnapshotProxy {
    private let baseURL: URL
    private let authorization: String
    private let fixture: V2OwnedChatFixture
    private let listener: NWListener
    private let session: URLSession
    private let queue = DispatchQueue(label: "OpenClientUITests.foreground-http")
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ready = false
    private var stopped = false
    private var replacement: String?
    private var transcriptReadsBlocked = false
    private(set) var replacementReads = 0
    private(set) var blockedTranscriptReads = 0
    private(set) var canonicalTranscriptReads = 0
    private(set) var eventStreamConnections = 0
    private(set) var failures: [String] = []

    init(baseURL: URL, username: String, password: String, fixture: V2OwnedChatFixture) throws {
        guard baseURL.scheme == "http", baseURL.host == "127.0.0.1", baseURL.port == 14097 else {
            throw NSError(domain: "V2ForegroundProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Proxy upstream must be the isolated server on 14097"])
        }
        self.baseURL = baseURL
        self.fixture = fixture
        authorization = "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: V2ForegroundProxyRedirectGuard(), delegateQueue: nil)
    }

    func start() async throws -> URL {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.becameReady() }
            case .failed(let error):
                let message = error.localizedDescription
                Task { await self?.recordFailure(message) }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)
        let deadline = Date().addingTimeInterval(5)
        while !ready && failures.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard ready, let port = listener.port else {
            throw NSError(domain: "V2ForegroundProxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Loopback HTTP fixture failed to start: \(failures)"])
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func replaceAssistant(with text: String?) { replacement = text }
    func setTranscriptReadsBlocked(_ blocked: Bool) { transcriptReadsBlocked = blocked }
    private func becameReady() { ready = true }
    private func recordFailure(_ message: String) { failures.append(message) }

    func stop() {
        stopped = true
        listener.cancel()
        for task in tasks.values { task.cancel() }
        for connection in connections.values { connection.cancel() }
        tasks.removeAll()
        connections.removeAll()
        session.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: Task { await self?.close(id) }
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHeader(id, buffered: Data())
    }

    private func close(_ id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.cancel()
    }

    private func receiveHeader(_ id: UUID, buffered: Data) {
        connections[id]?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            let failed = error != nil
            Task { await self?.receivedHeader(id, buffered: buffered, data: data, complete: complete, failed: failed) }
        }
    }

    private func receivedHeader(_ id: UUID, buffered: Data, data: Data?, complete: Bool, failed: Bool) {
        guard !failed, let data, !data.isEmpty else { close(id); return }
        let bytes = buffered + data
        guard bytes.count <= 65_536 else { respond(id, status: 431, data: Data()); return }
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if complete { close(id) } else { receiveHeader(id, buffered: bytes) }
            return
        }
        let lines = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count == 3, requestLine[0] == "GET" else {
            recordFailure("Rejected non-GET request; this fixture must never forward mutations")
            respond(id, status: 405, data: Data())
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["authorization"] == authorization else { respond(id, status: 401, data: Data()); return }
        guard headers["transfer-encoding"] == nil, (headers["content-length"] ?? "0") == "0" else {
            respond(id, status: 400, data: Data())
            return
        }
        let target = String(requestLine[1])
        guard target.hasPrefix("/"), !target.hasPrefix("//"), let parts = URLComponents(string: target),
              parts.host == nil, parts.fragment == nil else { respond(id, status: 400, data: Data()); return }
        let transcriptPath = "/api/session/\(fixture.sessionID)/message"
        if transcriptReadsBlocked, parts.path == transcriptPath || parts.path.hasPrefix(transcriptPath + "/") {
            blockedTranscriptReads += 1
            respond(id, status: 503, data: Data(#"{"error":"Owned transcript temporarily unavailable"}"#.utf8))
            return
        }
        if parts.path == "/api/event" {
            eventStreamConnections += 1
            // A valid live SSE connection with comments only. No event or replay can
            // cause the transcript to change, including on reconnect after foreground.
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n: no events\n\n"
            connections[id]?.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
            tasks[id] = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                    await self?.heartbeat(id)
                }
            }
            return
        }
        var upstream = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        upstream.percentEncodedPath = parts.percentEncodedPath
        upstream.percentEncodedQuery = parts.percentEncodedQuery
        guard let url = upstream.url else { respond(id, status: 400, data: Data()); return }
        // Capture the snapshot version at request admission. A delayed old request
        // must not turn into new data merely because the test advanced the fixture.
        let text = replacement
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            await self.forward(id, url: url, replacement: text)
        }
    }

    private func heartbeat(_ id: UUID) {
        connections[id]?.send(content: Data(": no events\n\n".utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { Task { await self?.close(id) } }
        })
    }

    private func forward(_ id: UUID, url: URL, replacement: String?) async {
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            var data = received
            let messagesPath = "/api/session/\(fixture.sessionID)/message"
            if http.statusCode == 200, replacement == nil, url.path == messagesPath {
                canonicalTranscriptReads += 1
            }
            if http.statusCode == 200, let replacement,
               url.path == messagesPath || url.path == messagesPath + "/" + fixture.assistantMessageID {
                guard var envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.cannotParseResponse)
                }
                var messages: [[String: Any]]
                if let page = envelope["data"] as? [[String: Any]] { messages = page }
                else if let message = envelope["data"] as? [String: Any] { messages = [message] }
                else { throw URLError(.cannotParseResponse) }
                guard let index = messages.firstIndex(where: { $0["id"] as? String == fixture.assistantMessageID }),
                      messages[index]["type"] as? String == "assistant" else { throw URLError(.cannotParseResponse) }
                messages[index]["content"] = [["type": "text", "text": replacement]]
                if url.path == messagesPath { envelope["data"] = messages } else { envelope["data"] = messages[index] }
                data = try JSONSerialization.data(withJSONObject: envelope)
                replacementReads += 1
            }
            respond(id, status: http.statusCode, data: data, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")
        } catch {
            if !Task.isCancelled { recordFailure("GET \(url.path): \(error.localizedDescription)") }
            respond(id, status: 502, data: Data())
        }
    }

    private func respond(_ id: UUID, status: Int, data: Data, contentType: String = "application/json") {
        let header = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connections[id]?.send(content: Data(header.utf8) + data, completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }
}

private final class V2ForegroundProxyRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// The UI test target cannot import app internals. Decode the real response strictly
// to distinguish boolean false from 0 or "false", and numbers from numeric strings.
private enum V2UIFormValue: Decodable, Equatable {
    case string(String), number(Double), boolean(Bool), strings([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { self = .strings(try container.decode([String].self)) }
    }
}

private enum V2UIFormState: Decodable, Equatable {
    case pending, answered([String: V2UIFormValue]), cancelled
    private enum CodingKeys: CodingKey { case status, answer }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "pending": self = .pending
        case "answered": self = .answered(try container.decode([String: V2UIFormValue].self, forKey: .answer))
        case "cancelled": self = .cancelled
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unknown form settlement state")
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
