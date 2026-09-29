import XCTest

@MainActor
final class StreamingDeliveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSideQuestionMenuWorksIdleAndStreamingWithoutSubmittingDraft() {
        for busy in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
            app.launchEnvironment["OPENCLIENT_STREAMING_DELIVERY_FIXTURE"] = "1"
            app.launchEnvironment["OPENCLIENT_DELIVERY_IDLE"] = busy ? "0" : "1"
            app.launchEnvironment["OPENCLIENT_SIDE_QUESTION_LOADING"] = "1"
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 15))
            send.press(forDuration: 1.2)
            capture(app, busy ? "Fan-Streaming" : "Fan-Idle")
            XCTAssertTrue(app.buttons[busy ? "Queue" : "Submit"].waitForExistence(timeout: 3))
            if busy { XCTAssertTrue(app.buttons["Steer"].exists) }
            let sideQuestion = app.buttons["chat.send.sideQuestion"]
            XCTAssertTrue(sideQuestion.exists)
            sideQuestion.tap()
            XCTAssertTrue(app.staticTexts["chat.sideQuestion.question"].waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["chat.sideQuestion.ask"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["chat.sideQuestion.loading"].waitForExistence(timeout: 3))
            capture(app, busy ? "Side-Question-Streaming-Loading" : "Side-Question-Idle-Loading")
            XCTAssertTrue(app.buttons["chat.sideQuestion.copy"].waitForExistence(timeout: 10))
            capture(app, busy ? "Side-Question-Streaming-Answer" : "Side-Question-Idle-Answer")
            app.buttons["chat.sideQuestion.done"].tap()
            XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.textViews["chat.input"].value as? String, "")
            XCTAssertEqual(app.staticTexts["streaming.fixture.submissions"].value as? String, "0")
            capture(app, busy ? "Side-Question-Streaming" : "Side-Question-Idle")
            if !busy {
                app.textViews["chat.input"].tap()
                app.textViews["chat.input"].typeText("Another message")
                send.press(forDuration: 1.2)
                let submit = app.buttons["chat.send.submit"]
                XCTAssertTrue(submit.waitForExistence(timeout: 3))
                submit.tap()
                XCTAssertEqual(app.staticTexts["streaming.fixture.submissions"].value as? String, "1")
            }
            app.terminate()
        }
    }

    func testSideQuestionSlashAndAccessoryEntryPointsWhileStreaming() {
        for entry in ["command", "typed", "accessory"] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
            app.launchEnvironment["OPENCLIENT_STREAMING_DELIVERY_FIXTURE"] = "1"
            app.launchEnvironment["OPENCLIENT_SIDE_QUESTION_DRAFT"] = entry == "typed" ? "/btw Why did the tests fail?" : (entry == "command" ? "/btw" : "")
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15))
            switch entry {
            case "command":
                let command = app.buttons["chat.command.btw"]
                XCTAssertTrue(command.waitForExistence(timeout: 3))
                command.tap()
            case "typed":
                app.buttons["chat.send"].tap()
            default:
                app.buttons["chat.composer.menu"].tap()
                let action = app.buttons["chat.composer.sideQuestion"]
                XCTAssertTrue(action.waitForExistence(timeout: 3))
                let menu = app.scrollViews.containing(.button, identifier: "chat.composer.sideQuestion").firstMatch
                for _ in 0..<3 where !action.isHittable { menu.swipeUp() }
                action.tap()
            }
            if entry == "typed" {
                XCTAssertTrue(app.staticTexts["chat.sideQuestion.question"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.buttons["chat.sideQuestion.copy"].waitForExistence(timeout: 3))
            } else {
                let input = app.textFields["chat.sideQuestion.input"]
                XCTAssertTrue(input.waitForExistence(timeout: 3))
                input.tap()
                input.typeText("Why did the tests fail?\n")
                XCTAssertTrue(app.staticTexts["chat.sideQuestion.question"].waitForExistence(timeout: 3))
                XCTAssertTrue(app.buttons["chat.sideQuestion.copy"].waitForExistence(timeout: 3))
            }
            XCTAssertFalse(app.buttons["chat.sideQuestion.ask"].exists)
            capture(app, "Side-Question-\(entry)-Dialog")
            app.buttons["chat.sideQuestion.done"].tap()
            XCTAssertEqual(app.staticTexts["streaming.fixture.submissions"].value as? String, "0")
            app.terminate()
        }
    }

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

    func testLongPressFansOutActionsAndTappingDeliverySubmitsImmediately() {
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
            XCTAssertEqual(submissions.value as? String, "0")
            capture(app, "\(style)-Initial-Queue")

            if assistant {
                input.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
                capture(app, "\(style)-Keyboard-Visible")
            }

            // Holding only expands; tapping a satellite sends exactly once.
            send.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["chat.send.steer"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.buttons["chat.send.queue"].exists)
            XCTAssertTrue(app.buttons["chat.send.sideQuestion"].exists)
            XCTAssertEqual(submissions.value as? String, "0", "A long press must never submit")
            capture(app, "\(style)-Submit-Action-Fan")
            app.buttons["chat.send.steer"].tap()
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertEqual(submissions.value as? String, "1")
            XCTAssertEqual(submissions.label, "steer:Keep this streaming draft")
            XCTAssertEqual(send.label, "Queue", "An explicit send does not change the connection default")

            send.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["chat.send.queue"].waitForExistence(timeout: 3))
            app.buttons["chat.send.queue"].tap()
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            let queued = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "2"), object: submissions)
            XCTAssertEqual(XCTWaiter.wait(for: [queued], timeout: 3), .completed)
            XCTAssertEqual(submissions.label, "steer:Keep this streaming draft|queue:Keep this streaming draft")

            let stopFrame = app.buttons["chat.stream.stop"].frame
            send.press(forDuration: 1.2)
            XCTAssertTrue(app.buttons["chat.send.options.dismiss"].waitForExistence(timeout: 3))
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: stopFrame.midX, dy: stopFrame.midY)).tap()
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertEqual(submissions.value as? String, "2", "Scrim dismissal must not send or stop")
            XCTAssertEqual(app.staticTexts["streaming.fixture.stops"].value as? String, "0", "The fan scrim must cover Stop")
            if assistant { XCTAssertTrue(app.keyboards.firstMatch.exists) }
            send.tap()
            XCTAssertEqual(submissions.value as? String, "3", "Normal tap still submits once")
            capture(app, "\(style)-Submitted-Default")
            app.terminate()
        }
    }

    func testHoldAndDragSelectsFanActionOnRelease() {
        for busy in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
            app.launchEnvironment["OPENCLIENT_STREAMING_DELIVERY_FIXTURE"] = "1"
            app.launchEnvironment["OPENCLIENT_DELIVERY_IDLE"] = busy ? "0" : "1"
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 15))
            app.textViews["chat.input"].tap()
            let root = app.coordinate(withNormalizedOffset: .zero)
            let start = root.withOffset(CGVector(dx: send.frame.midX, dy: send.frame.midY))
            let actions = busy ? ["queue", "steer", "sideQuestion"] : ["submit", "sideQuestion"]
            send.press(forDuration: 1)
            XCTAssertTrue(app.buttons["chat.send.sideQuestion"].waitForExistence(timeout: 3))
            let frames = actions.map { app.buttons["chat.send.\($0)"].frame }
            app.buttons["chat.send.options.close"].tap()
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            start.press(forDuration: 1, thenDragTo: root.withOffset(CGVector(dx: 20, dy: 100)))
            XCTAssertTrue(send.waitForExistence(timeout: 3))
            XCTAssertEqual(app.staticTexts["streaming.fixture.submissions"].value as? String, "0")

            var count = 0
            for (action, frame) in zip(actions, frames) {
                start.press(forDuration: 1, thenDragTo: root.withOffset(CGVector(dx: frame.midX, dy: frame.midY)))
                if action == "sideQuestion" {
                    XCTAssertTrue(app.buttons["chat.sideQuestion.copy"].waitForExistence(timeout: 5))
                    app.buttons["chat.sideQuestion.done"].tap()
                } else {
                    count += 1
                }
                XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 3))
                let expected = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", String(count)),
                    object: app.staticTexts["streaming.fixture.submissions"])
                XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 3), .completed)
            }
            XCTAssertEqual(app.staticTexts["streaming.fixture.submissions"].value as? String, String(count))
            XCTAssertEqual(app.staticTexts["streaming.fixture.stops"].value as? String, "0")
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
