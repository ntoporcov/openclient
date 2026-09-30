import XCTest
import UIKit

@MainActor
final class GalleryScreenshotUITests: XCTestCase {
    func testCaptureGallerySources() {
        continueAfterFailure = false
        let ipad = UIDevice.current.userInterfaceIdiom == .pad
            || (ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "").contains("iPad")
        setSnapshotLandscapeOutput(false)
        XCUIDevice.shared.orientation = .portrait

        func launch(_ scene: String, _ extra: [String: String] = [:]) -> XCUIApplication {
            let app = XCUIApplication()
            setupSnapshot(app)
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-ApplePersistenceIgnoreState", "YES"]
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = scene
            app.launchEnvironment["OPENCLIENT_GALLERY"] = "1"
            app.launchEnvironment["OPENCLIENT_UI_TEST_DARK_MODE"] = "1"
            for (key, value) in extra { app.launchEnvironment[key] = value }
            app.launch()
            XCTAssertTrue(app.staticTexts["screenshot.scene.\(scene)"].waitForExistence(timeout: 15))
            XCUIDevice.shared.orientation = .portrait
            return app
        }
        func capture(_ name: String, app: XCUIApplication) {
            // Let presentation and glass transitions settle before capturing marketing artwork.
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let screenshot = app.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "gallery-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fastlane/screenshots/en_US")
            let device = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"]!.replacingOccurrences(of: " ", with: "-")
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try! screenshot.pngRepresentation.write(to: root.appendingPathComponent("\(device)-gallery-\(name).png"))
        }

        var app = ipad
            ? launch("chat", ["OPENCLIENT_STREAMING_DELIVERY_FIXTURE": "1", "OPENCLIENT_SIDE_QUESTION_DRAFT": "Add a dark mode, too."])
            : launch("projects")
        capture("01-overview", app: app)
        app.terminate()

        app = launch("chat", ["OPENCLIENT_STREAMING_DELIVERY_FIXTURE": "1", "OPENCLIENT_SIDE_QUESTION_DRAFT": "Add a dark mode, too."])
        let send = app.buttons["chat.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        send.press(forDuration: 0.7)
        capture("02-delivery", app: app)
        app.terminate()

        app = launch("chat", ["OPENCLIENT_STREAMING_DELIVERY_FIXTURE": "1", "OPENCLIENT_SIDE_QUESTION_DRAFT": "/btw When should I queue instead of steer?"])
        XCTAssertTrue(app.buttons["chat.send"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["chat.send"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["When should I queue instead of steer?"].firstMatch.waitForExistence(timeout: 10))
        capture("03-side-question", app: app)
        app.terminate()

        app = launch("chat", ["OPENCLIENT_TOOL_GROUPING_FIXTURE": "1"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.tools.group.")).firstMatch.waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.tools.group.")).firstMatch.tap()
        capture("04-grouping", app: app)
        app.terminate()

        app = launch("chat", ["OPENCLIENT_CHAT_CONTROLS_PREVIEW": "1"])
        let accent = app.buttons["appearance.accent-color.purple"]
        for _ in 0..<8 {
            if accent.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(accent.isHittable)
        accent.tap()
        let grouping = app.switches["new-features.group-tools"].firstMatch
        XCTAssertTrue(grouping.waitForExistence(timeout: 5))
        if grouping.value as? String != "1" { grouping.tap() }
        capture("05-customization", app: app)
        app.terminate()

        for (scene, name) in [
            ("sessions", "06-sessions"),
            ("new-session", "07-models"),
            ("permission", "08-permissions"),
            ("question", "09-questions"),
            ("recent-widget", "10-widgets"),
        ] {
            app = launch(scene)
            if scene == "sessions" {
                XCTAssertTrue(app.buttons["sessions.newTalk"].waitForExistence(timeout: 10))
            }
            capture(name, app: app)
            app.terminate()
        }
    }
}
