import XCTest

@MainActor
final class StreamingDeliveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testQueueAndSteerStayAtTranscriptTailUntilCanonicalPickup() {
        for mode in ["queue", "steer"] {
            verifyPendingDelivery(mode)
        }
    }

    private func verifyPendingDelivery(_ mode: String) {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_QUEUE_LIFECYCLE_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_QUEUE_LIFECYCLE_DELIVERY"] = mode
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let firstTool = app.staticTexts["queue.fixture.transcript.tool1"]
        XCTAssertTrue(firstTool.waitForExistence(timeout: 15))
        capture(app, "\(mode)-Lifecycle-Before-Submission")
        app.buttons["chat.send"].tap()
        let delivered = app.staticTexts.matching(identifier: "queue.fixture.transcript.queued")
        let advance = app.buttons["queue.fixture.advance"]
        let caption = app.staticTexts[mode == "queue" ? "Queued" : "Waiting to steer"]

        for (index, rowID) in ["tool1", "tool2", "tool3", "final"].enumerated() {
            if index > 0 { advance.tap() }
            XCTAssertTrue(app.staticTexts["queue.fixture.transcript.\(rowID)"].waitForExistence(timeout: 3))
            XCTAssertTrue(delivered.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(delivered.count, 1, "A pending prompt must appear exactly once")
            XCTAssertEqual(delivered.firstMatch.label, "Pending follow-up")
            XCTAssertTrue(caption.waitForExistence(timeout: 3))
            XCTAssertLessThan(app.staticTexts["queue.fixture.transcript.\(rowID)"].frame.maxY, delivered.firstMatch.frame.minY,
                "The pending prompt must follow the growing assistant turn")
            XCTAssertLessThanOrEqual(delivered.firstMatch.frame.maxY, caption.frame.minY)
            XCTAssertLessThan(caption.frame.maxY, app.textViews["chat.input"].frame.minY)
            XCTAssertFalse(app.buttons["chat.queue.queued"].exists)
            capture(app, "\(mode)-Lifecycle-Pending-\(rowID)")
        }

        for stage in ["Canonical-Header", "Canonical-Parts", "Replayed-Delivery"] {
            advance.tap()
            XCTAssertTrue(caption.waitForNonExistence(timeout: 3))
            XCTAssertTrue(delivered.firstMatch.waitForExistence(timeout: 3))
            XCTAssertEqual(delivered.count, 1)
            XCTAssertEqual(delivered.firstMatch.label, "Pending follow-up")
            let rows = ["tool1", "tool2", "tool3", "final", "queued", "answer"].map {
                app.staticTexts["queue.fixture.transcript.\($0)"]
            }
            for (earlier, later) in zip(rows, rows.dropFirst()) {
                XCTAssertTrue(earlier.exists)
                XCTAssertTrue(later.exists)
                XCTAssertLessThan(earlier.frame.maxY, later.frame.minY,
                    "Delivery must appear after the complete active turn and before the next answer")
            }
            capture(app, "\(mode)-Lifecycle-\(stage)")
        }
    }

    func testLongPressSelectsDeliveryWithoutSendingAndTapSends() {
        for assistant in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
            app.launchEnvironment["OPENCLIENT_STREAMING_DELIVERY_FIXTURE"] = "1"
            app.launchEnvironment["OPENCLIENT_STREAMING_ASSISTANT"] = assistant ? "1" : "0"
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let style = assistant ? "Assistant" : "Messenger"
            let send = app.buttons["chat.send"]
            let input = app.textViews["chat.input"]
            let submissions = app.staticTexts["streaming.fixture.submissions"]
            XCTAssertTrue(send.waitForExistence(timeout: 15))
            XCTAssertEqual(send.label, "Queue")
            XCTAssertTrue(send.images["text.line.last.and.arrowtriangle.forward"].exists)
            XCTAssertEqual(submissions.value as? String, "0")
            capture(app, "\(style)-Initial-Queue")

            if assistant {
                input.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
                capture(app, "\(style)-Keyboard-Visible")
            }

            // Both choices must be exposed by a physical long press, not an AX action.
            send.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Steer"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["Queue"].exists)
            capture(app, "\(style)-Long-Press-Menu")
            app.buttons["Steer"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'chat.send' AND label == 'Steer'")).firstMatch.waitForExistence(timeout: 3))
            XCTAssertTrue(send.images["steeringwheel"].exists)
            XCTAssertEqual(input.value as? String, "Keep this streaming draft")
            XCTAssertEqual(submissions.value as? String, "0", "Selecting delivery must not submit")
            capture(app, "\(style)-Selected-Steer")
            send.tap()
            XCTAssertEqual(submissions.value as? String, "1")
            XCTAssertEqual(submissions.label, "steer:Keep this streaming draft")

            send.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["Queue"].waitForExistence(timeout: 3))
            app.buttons["Queue"].tap()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'chat.send' AND label == 'Queue'")).firstMatch.waitForExistence(timeout: 3))
            XCTAssertTrue(send.images["text.line.last.and.arrowtriangle.forward"].exists)
            XCTAssertEqual(submissions.value as? String, "1")
            XCTAssertEqual(input.value as? String, "Keep this streaming draft")
            capture(app, "\(style)-Selected-Queue")
            send.tap()
            XCTAssertEqual(submissions.value as? String, "2")
            XCTAssertEqual(submissions.label, "steer:Keep this streaming draft|queue:Keep this streaming draft")
            capture(app, "\(style)-Submitted")
            app.terminate()
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-Hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
