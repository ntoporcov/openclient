import XCTest
import UIKit

@MainActor
final class TranscriptContinuityUITests: XCTestCase {
    func testThinkingPillPlaygroundCanSpinAndDismiss() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
        app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
        app.launchEnvironment["OPENCLIENT_MATERIALIZATION_GATES"] = "1"
        app.launchEnvironment["OPENCLIENT_THINKING_TOOLS"] = "1"
        app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = "v2"
        app.launchEnvironment["OPENCLIENT_UI_TEST_DARK_MODE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let input = app.textViews["chat.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("Glass playground")
        app.buttons["chat.send"].firstMatch.tap()
        let pill = app.buttons["chat.thinking.neutral"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 8), app.debugDescription)
        pill.tap()
        let surface = app.descendants(matching: .any)["glass-pill.playground.surface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["glass-pill.playground.overlay"].firstMatch.exists)
        XCTAssertFalse(app.sheets.firstMatch.exists, "The toy floats over chat rather than presenting a sheet")
        let renderer = app.descendants(matching: .any)["glass-pill.playground.ready"].firstMatch
        XCTAssertTrue(renderer.waitForExistence(timeout: 10))
        capture(app, name: "glass-playground-open", settleRendering: true)
        let frontImage = try pillPixels(app, surface: surface)
        let initialRotation = try XCTUnwrap(surface.value as? String)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4))
            .press(forDuration: 0.05,
                   thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)))
        XCTAssertTrue(surface.exists, "Dragging rotates the toy rather than dismissing its presentation")
        XCTAssertNotEqual(surface.value as? String, initialRotation)
        let releasedRotation = surface.value as? String
        let coasting = NSPredicate { _, _ in (surface.value as? String) != releasedRotation }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: coasting, object: nil)], timeout: 2), .completed,
                       "A flick continues rotating after the finger lifts")
        capture(app, name: "glass-playground-rotated")
        let rotatedImage = try pillPixels(app, surface: surface)
        let rotationDifference = pixelDifference(frontImage, rotatedImage)
        XCTAssertGreaterThan(rotationDifference, 3, "Dragging must change the rendered pill, not only its accessibility value")
        let returnedToFront = NSPredicate { _, _ in (surface.value as? String) == initialRotation }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returnedToFront, object: nil)], timeout: 6), .completed,
                       "The toy returns to face the user after a few idle seconds")
        capture(app, name: "glass-playground-idle-return", settleRendering: true)
        XCTAssertLessThan(pixelDifference(frontImage, try pillPixels(app, surface: surface)), rotationDifference * 0.7)
        XCTAssertFalse(app.buttons["glass-pill.playground.reset"].exists)
        XCTAssertFalse(app.staticTexts["Drag to spin the pill."].exists)
        let close = app.buttons["glass-pill.playground.close"]
        XCTAssertGreaterThan(close.frame.minY, surface.frame.maxY, "Close sits below the toy")
        close.tap()
        XCTAssertTrue(surface.waitForNonExistence(timeout: 5))
        XCTAssertTrue(pill.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["continuity.diagnostics"].label.contains("posts=1"),
                      "Opening the toy must not cancel or duplicate the in-flight send")
        app.buttons["continuity.tool"].tap()
        XCTAssertTrue(app.staticTexts["Shell"].firstMatch.waitForExistence(timeout: 5))
    }

    func testThinkingPillRemainsResponsiveThroughToolVisibilityChanges() throws {
        continueAfterFailure = false
        for profile in ["legacy", "v2"] {
            let app = XCUIApplication()
            defer { app.terminate() }
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
            app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
            app.launchEnvironment["OPENCLIENT_MATERIALIZATION_GATES"] = "1"
            app.launchEnvironment["OPENCLIENT_THINKING_TOOLS"] = "1"
            app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()

            let input = app.textViews["chat.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap()
            input.typeText("3D pill integration")
            app.buttons["chat.send"].firstMatch.tap()
            let neutral = app.descendants(matching: .any)["chat.thinking.neutral"].firstMatch
            let colored = app.descendants(matching: .any)["chat.thinking.tool"].firstMatch
            XCTAssertTrue(neutral.waitForExistence(timeout: 8))
            let posted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS 'posts=1'"),
                                                   object: app.staticTexts["continuity.diagnostics"])
            XCTAssertEqual(XCTWaiter.wait(for: [posted], timeout: 8), .completed)
            capture(app, name: "glass-pill-\(profile)-thinking")

            app.buttons["continuity.tool"].tap()
            XCTAssertTrue(neutral.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Shell"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["continuity.tools"].tap()
            XCTAssertTrue(colored.waitForExistence(timeout: 5))
            capture(app, name: "glass-pill-\(profile)-working")
            app.buttons["continuity.addReasoning"].tap()
            XCTAssertTrue(colored.exists)
            app.buttons["continuity.addText"].tap()
            XCTAssertTrue(colored.exists)
            capture(app, name: "glass-pill-\(profile)-text-alignment")
            app.buttons["continuity.tools"].tap()
            XCTAssertTrue(colored.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Shell"].firstMatch.exists)
        }
    }

    func testHistoryLoadsAutomaticallyWhenScrollingUp() throws {
        try verifyAutomaticHistoryScrolling(velocity: .slow, label: "slow")
    }

    func testHistoryLoadsAutomaticallyDuringFastScrolling() throws {
        try verifyAutomaticHistoryScrolling(velocity: .fast, label: "fast")
    }

    private func verifyAutomaticHistoryScrolling(velocity: XCUIGestureVelocity, label: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        // Reuse the deterministic 40-message keyboard fixture without opening its keyboard.
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
        app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
        app.launchEnvironment["OPENCLIENT_KEYBOARD_CONTINUITY"] = "1"
        // Omit the recovery placeholder so the opening starts with only the latest
        // user round. The viewport must fill itself rather than waiting for a pull.
        app.launchEnvironment["OPENCLIENT_THINKING_EARLY_RESPONSE"] = "user"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let transcript = app.collectionViews["chat.scroll"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 15))
        let latest = transcript.staticTexts["Keyboard history row 39"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 10))
        XCTAssertTrue(transcript.staticTexts["Keyboard history row 38"].waitForExistence(timeout: 5),
            "The short latest round must automatically expand to fill the viewport")
        let oldest = transcript.staticTexts["Keyboard history row 0"].firstMatch
        XCTAssertFalse(oldest.exists, "Opening must leave older history outside the mounted window")
        XCTAssertFalse(app.buttons["chat-older-messages-button"].exists)
        capture(app, name: "automatic-history-\(label)-initial-tail")
        let navigationBottom = app.navigationBars.allElementsBoundByIndex.map { $0.frame.maxY }.max() ?? transcript.frame.minY
        for _ in 0..<30 {
            if oldest.exists && oldest.isHittable && oldest.frame.minY >= navigationBottom { break }
            transcript.swipeDown(velocity: velocity)
        }
        XCTAssertTrue(oldest.exists && oldest.isHittable, "Scrolling alone must reveal the oldest message")
        XCTAssertGreaterThanOrEqual(oldest.frame.minY, navigationBottom, "The oldest message must be readable below the navigation bar")
        XCTAssertFalse(app.buttons["chat-older-messages-button"].exists)
        capture(app, name: "automatic-history-\(label)-oldest-message")
    }

    func testNativeKeyboardDismissalHasNoDeferredReservation() throws {
        continueAfterFailure = false
        for interactive in [false, true] {
            let app = XCUIApplication()
            defer { app.terminate() }
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
            app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
            app.launchEnvironment["OPENCLIENT_KEYBOARD_CONTINUITY"] = "1"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let input = app.textViews["chat.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap()
            input.typeText("Keyboard draft")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            let trace = app.staticTexts["continuity.keyboard.frames"]
            func frames() -> [[String: Double]] {
                guard let value = trace.value as? String,
                      let frames = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [[String: Double]] else { return [] }
                return frames
            }
            let shown = NSPredicate { _, _ in (frames().last?["requestedKeyboard"] ?? 0) > 200 }
            capture(app, name: "keyboard-\(interactive)-focused")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 15), .completed,
                "Expected software keyboard: \(frames().last ?? [:])")
            app.buttons["continuity.keyboard.record"].tap()
            capture(app, name: "keyboard-\(interactive)-before")
            if interactive {
                let scroll = app.collectionViews["chat.scroll"].firstMatch
                XCTAssertTrue(scroll.exists)
                let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: scroll.frame.midX, dy: input.frame.minY - 100))
                let end = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: scroll.frame.midX, dy: app.frame.maxY - 30))
                start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
            } else {
                app.buttons["continuity.keyboard.hide"].tap()
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            capture(app, name: "keyboard-\(interactive)-hidden")
            let hidden = NSPredicate { _, _ in
                let last = frames().last ?? [:]
                return last["hidden"] == 1 && last["requestedKeyboard"] == 0
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hidden, object: nil)], timeout: 5), .completed)
            let samples = frames()
            let attachment = XCTAttachment(string: trace.value as? String ?? "missing")
            attachment.name = "keyboard-\(interactive)-display-frames"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertTrue(samples.contains { $0["hidden"] == 0 }, "Capture the visible keyboard before dismissal")
            if interactive { XCTAssertTrue(samples.contains { $0["scrolling"] == 1 }, "Exercise a native scrolling gesture") }
            let afterHide = samples.filter { $0["hidden"] == 1 && $0["requestedKeyboard"] == 0 }
            XCTAssertFalse(afterHide.isEmpty)
            for frame in afterHide {
                XCTAssertEqual(frame["inset"]!, frame["expectedInset"]!, accuracy: 1,
                    "No stale keyboard reservation in ANY frame after keyboardDidHide: \(frame)")
            }
            capture(app, name: "keyboard-\(interactive)-after")
        }
    }

    func testEarlyCanonicalHandoffWaitsForEntryAndFastAnswerNeverFlashesThinking() throws {
        continueAfterFailure = false
        for profile in ["legacy", "v2"] {
            for window in [false, true] {
                for response in ["user", "answer", "reduced"] {
                    let app = XCUIApplication()
                    defer { app.terminate() }
                    app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
                    app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
                    app.launchEnvironment["OPENCLIENT_MATERIALIZATION_GATES"] = "1"
                    app.launchEnvironment["OPENCLIENT_THINKING_EARLY_RESPONSE"] = response
                    app.launchEnvironment["OPENCLIENT_THINKING_REDUCE_MOTION"] = response == "reduced" ? "1" : "0"
                    app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
                    app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
                    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    app.launch()
                    let input = app.textViews["chat.input"].firstMatch
                    XCTAssertTrue(input.waitForExistence(timeout: 15))
                    input.tap()
                    input.typeText("Continuity outgoing")
                    app.buttons["chat.send"].firstMatch.tap()
                    let diagnostics = app.staticTexts["continuity.diagnostics"]
                    func snapshot() -> [String: Any] {
                        guard let string = diagnostics.value as? String,
                              let value = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return [:] }
                        return value
                    }
                    let finished = NSPredicate { _, _ in
                        let data = snapshot()
                        guard let id = data["outgoingID"] as? String else { return false }
                        return (data["entryCompletedAt"] as? [String: Double])?[id] != nil
                            && data["admitted"] as? Bool == true
                    }
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: finished, object: nil)], timeout: 8), .completed)
                    let value = snapshot()
                    let id = try XCTUnwrap(value["outgoingID"] as? String)
                    let completed = try XCTUnwrap((value["entryCompletedAt"] as? [String: Double])?[id])
                    let canonicalAt = try XCTUnwrap(value["earlyCanonicalAt"] as? Double)
                    XCTAssertGreaterThan(canonicalAt, 0)
                    if response == "reduced" {
                        let started = try XCTUnwrap((value["entryStartedAt"] as? [String: Double])?[id])
                        XCTAssertLessThan(completed - started, 0.1, "Reduce Motion does not wait for the animation clock")
                    } else {
                        XCTAssertLessThan(canonicalAt, completed, "Canonical content must arrive while the bubble is still entering")
                    }
                    XCTAssertEqual(value["removals"] as? Int, 0)
                    XCTAssertEqual(value["thinkingDuringOutgoingMotion"] as? Bool, false)
                    XCTAssertTrue(diagnostics.label.contains("starts=1"))
                    XCTAssertTrue(diagnostics.label.contains("posts=1"))
                    let neutral = app.descendants(matching: .any)["chat.thinking.neutral"].firstMatch
                    if response == "answer" {
                        XCTAssertFalse(neutral.exists)
                        XCTAssertTrue((value["thinkingFrameTimes"] as? [Double] ?? []).isEmpty)
                    } else {
                        XCTAssertTrue(neutral.waitForExistence(timeout: 5))
                        let firstThinking = try XCTUnwrap((snapshot()["thinkingFrameTimes"] as? [Double])?.first)
                        XCTAssertGreaterThanOrEqual(firstThinking, completed)
                    }
                    let frames = try XCTUnwrap(value["outgoingFrameRows"] as? [[[String: String]]])
                    let cells = frames.compactMap { $0.first { $0["id"] == id }?["cell"] }.filter { !$0.isEmpty }
                    if response == "reduced" { XCTAssertTrue(frames.isEmpty, "No fake animation frames with Reduce Motion") }
                    else { XCTAssertEqual(Set(cells).count, 1, "Canonical replacement keeps the entering cell") }
                    capture(app, name: "entry-sequence-\(profile)-window-\(window)-early-\(response)")
                    app.terminate()
                }
            }
        }
    }

    func testThinkingBeforeToolThenVisibilityToggleKeepsCanonicalRows() throws {
        continueAfterFailure = false
        for profile in ["legacy", "v2"] {
            for window in [false, true] {
                for reasoning in [false, true] {
                    let app = XCUIApplication()
                    defer { app.terminate() }
                    app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
                    app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
                    app.launchEnvironment["OPENCLIENT_MATERIALIZATION_GATES"] = "1"
                    app.launchEnvironment["OPENCLIENT_THINKING_TOOLS"] = "1"
                    app.launchEnvironment["OPENCLIENT_THINKING_REASONING"] = reasoning ? "1" : "0"
                    app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
                    app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
                    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    app.launch()
                    let input = app.textViews["chat.input"].firstMatch
                    XCTAssertTrue(input.waitForExistence(timeout: 15))
                    XCTAssertFalse(app.descendants(matching: .any)["chat.thinking.neutral"].firstMatch.exists)
                    input.tap()
                    input.typeText("Continuity outgoing")
                    app.buttons["chat.send"].firstMatch.tap()
                    let neutral = app.descendants(matching: .any)["chat.thinking.neutral"].firstMatch
                    let colored = app.descendants(matching: .any)["chat.thinking.tool"].firstMatch
                    XCTAssertTrue(neutral.waitForExistence(timeout: 8))
                    let diagnostics = app.staticTexts["continuity.diagnostics"]
                    func snapshot() -> [String: Any] {
                        guard let string = diagnostics.value as? String,
                            let value = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return [:] }
                        return value
                    }
                    let animated = NSPredicate { _, _ in
                        let frames = snapshot()["thinkingProgress"] as? [Double] ?? []
                        return frames.contains { $0 > 0 && $0 < 1 } && frames.last == 1
                    }
                    let animationResult = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: animated, object: nil)], timeout: 5)
                    capture(app, name: "thinking-entry-\(profile)-window-\(window)")
                    XCTAssertEqual(animationResult, .completed, "\(snapshot()["thinkingProgress"] ?? "missing") \(snapshot()["thinkingEvents"] ?? "missing")")
                    let initialRows = try XCTUnwrap(snapshot()["rows"] as? [[String: String]])
                    let outgoingID = try XCTUnwrap(snapshot()["outgoingID"] as? String)
                    let completed = try XCTUnwrap((snapshot()["entryCompletedAt"] as? [String: Double])?[outgoingID])
                    let firstThinking = try XCTUnwrap((snapshot()["thinkingFrameTimes"] as? [Double])?.first)
                    XCTAssertGreaterThanOrEqual(firstThinking, completed, "Thinking follows the actual bubble completion callback")
                    let posted = try XCTUnwrap(snapshot()["postedAt"] as? Double)
                    XCTAssertGreaterThan(posted, 0)
                    XCTAssertLessThan(posted, completed, "The animation must not stall the server request")
                    XCTAssertEqual(snapshot()["thinkingDuringOutgoingMotion"] as? Bool, false)
                    XCTAssertTrue(diagnostics.label.contains("posts=1"), "The request runs independently while its response is held")
                    let risingRows = try XCTUnwrap(snapshot()["outgoingFrameRows"] as? [[[String: String]]])
                    let tailHeights = risingRows.compactMap { $0.first { $0["id"] == "chat-thinking-row" }?["height"] }.compactMap(Double.init)
                    XCTAssertFalse(tailHeights.isEmpty)
                    XCTAssertTrue(tailHeights.allSatisfy { abs($0 - 64) < 1 }, "Invisible entry reserve avoids a second tail-height shift")
                    let cell = try XCTUnwrap(initialRows.first { $0["id"] == outgoingID }?["cell"])
                    XCTAssertFalse(cell.isEmpty)
                    let name = "thinking-\(profile)-window-\(window)-reasoning-\(reasoning)"
                    capture(app, name: name + "-before-tool")
                    app.buttons["continuity.tool"].tap()
                    XCTAssertTrue(neutral.waitForNonExistence(timeout: 5))
                    XCTAssertFalse(colored.exists)
                    XCTAssertTrue(app.staticTexts["Shell"].firstMatch.waitForExistence(timeout: 5))
                    capture(app, name: name + "-visible-card")
                    let canonical = snapshot()["canonicalIDs"] as? [String]
                    let canonicalParts = snapshot()["canonicalParts"] as? [String]
                    app.buttons["continuity.tools"].tap()
                    XCTAssertTrue(colored.waitForExistence(timeout: 5))
                    XCTAssertFalse(neutral.exists)
                    capture(app, name: name + "-hidden-card-summary")
                    XCTAssertEqual(snapshot()["canonicalParts"] as? [String], canonicalParts)
                    let frameCount = (snapshot()["thinkingProgress"] as? [Double] ?? []).count
                    app.buttons["continuity.addReasoning"].tap()
                    XCTAssertTrue(colored.exists)
                    app.buttons["continuity.reasoning"].tap()
                    XCTAssertTrue(colored.exists)
                    app.buttons["continuity.addText"].tap()
                    XCTAssertTrue(colored.exists)
                    let mixedParts = snapshot()["canonicalParts"] as? [String]
                    let frames = snapshot()["thinkingProgress"] as? [Double] ?? []
                    XCTAssertFalse(frames.dropFirst(frameCount).contains { $0 < 1 }, "Part changes must not replay entry")
                    capture(app, name: name + "-mixed-content-summary")
                    app.buttons["continuity.tools"].tap()
                    XCTAssertTrue(colored.waitForNonExistence(timeout: 5))
                    XCTAssertFalse(neutral.exists)
                    XCTAssertEqual(snapshot()["canonicalIDs"] as? [String], canonical)
                    XCTAssertEqual(snapshot()["canonicalParts"] as? [String], mixedParts)
                    let rows = try XCTUnwrap(snapshot()["rows"] as? [[String: String]])
                    XCTAssertEqual(rows.first { $0["id"] == outgoingID }?["cell"], cell)
                    XCTAssertEqual(snapshot()["removals"] as? Int, 0)
                    app.terminate()
                }
            }
        }
    }

    func testSeparatelyGatedReceiptHeaderEmptyAndUsableContentKeepsActualCell() throws {
        continueAfterFailure = false
        let configurations = ["legacy", "v2"].flatMap { profile in
            [false, true].flatMap { window in [false, true].map { (profile, window, $0, false, false) } }
        } + [("legacy", false, false, true, false), ("legacy", true, false, true, false),
             ("v2", true, false, false, true), ("v2", true, true, false, true)]
        for (profile, window, headerFirst, attachment, splitOwner) in configurations {
            let app = XCUIApplication()
            defer { app.terminate() }
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
            app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
            app.launchEnvironment["OPENCLIENT_MATERIALIZATION_GATES"] = "1"
            app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
            app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
            app.launchEnvironment["OPENCLIENT_HEADER_FIRST"] = headerFirst ? "1" : "0"
            app.launchEnvironment["OPENCLIENT_MATERIALIZATION_ATTACHMENT"] = attachment ? "1" : "0"
            app.launchEnvironment["OPENCLIENT_MATERIALIZATION_SPLIT_OWNER"] = splitOwner ? "1" : "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            let input = app.textViews["chat.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 15))
            input.tap()
            input.typeText("Continuity outgoing")
            app.buttons["chat.send"].firstMatch.tap()
            let diagnostics = app.staticTexts["continuity.diagnostics"]
            let posted = NSPredicate { _, _ in diagnostics.label.contains("posts=1") && diagnostics.label.contains("starts=1") }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: posted, object: nil)], timeout: 10), .completed)
            func snapshot() -> [String: Any] {
                guard let string = diagnostics.value as? String,
                      let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] else { return [:] }
                return object
            }
            let baseline = snapshot()
            let id = try XCTUnwrap(baseline["outgoingID"] as? String)
            let initialRows = try XCTUnwrap(baseline["rows"] as? [[String: String]])
            var initial = try XCTUnwrap(initialRows.first { $0["id"] == id })
            XCTAssertFalse(initial["cell", default: ""].isEmpty)
            var initialThinking = try XCTUnwrap(initialRows.first { $0["id"] == "chat-thinking-row" })
            let lastGate = attachment ? 5 : 4
            for gate in 1...lastGate {
                app.buttons["continuity.advance"].tap()
                let reached = NSPredicate { _, _ in
                    let value = snapshot()
                    return value["gate"] as? Int == gate && value["admitted"] as? Bool == true
                }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: reached, object: nil)], timeout: 8), .completed)
                let value = snapshot()
                let name = "materialization-\(profile)-window-\(window)-headerFirst-\(headerFirst)-file-\(attachment)-split-\(splitOwner)-gate-\(gate)"
                capture(app, name: name)
                let rows = try XCTUnwrap(value["rows"] as? [[String: String]])
                let outgoing = try XCTUnwrap(rows.first { $0["id"] == id }, name)
                XCTAssertEqual(rows.filter { $0["id"] == id }.count, 1, name)
                XCTAssertEqual(outgoing["cell"], initial["cell"], name)
                XCTAssertEqual(value["removals"] as? Int, 0, name)
                XCTAssertEqual(value["bridge"] as? Bool, gate < lastGate, name)
                if splitOwner {
                    XCTAssertEqual(value["rootOwner"] as? String, "/continuity", name)
                    XCTAssertEqual(value["windowOwner"] as? String, "global", name)
                    XCTAssertEqual(value["windowText"] as? String, value["rootText"] as? String, name)
                    if gate == lastGate { XCTAssertEqual(value["windowText"] as? String, "Continuity outgoing", name) }
                }
                let thinking = try XCTUnwrap(rows.first { $0["id"] == "chat-thinking-row" }, name)
                // Admission may remove the delayed sending decoration; subsequent content gates must not move rows.
                if gate == 1 { initial = outgoing; initialThinking = thinking }
                for (actual, expected) in [(outgoing, initial), (thinking, initialThinking)] {
                    XCTAssertEqual(Double(actual["height"]!)!, Double(expected["height"]!)!, accuracy: 1, name)
                    XCTAssertEqual(Double(actual["y"]!)!, Double(expected["y"]!)!, accuracy: 1, name)
                }
                XCTAssertEqual(rows.first { $0["id"] == "history" }?["cell"], initialRows.first { $0["id"] == "history" }?["cell"], name)
                XCTAssertTrue(diagnostics.label.contains("posts=1"), name)
                XCTAssertTrue(diagnostics.label.contains("starts=1"), name)
            }
            app.terminate()
        }
    }

    func testActualSendEntryAndCanonicalHandoffBothProfilesAndPresentations() {
        continueAfterFailure = false
        for profile in ["legacy", "v2"] {
            for window in [false, true] {
                let app = XCUIApplication()
                defer { app.terminate() }
                app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
                app.launchEnvironment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] = "1"
                app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
                app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
                app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                app.launch()
                let input = app.textViews["chat.input"].firstMatch
                XCTAssertTrue(input.waitForExistence(timeout: 15))
                let diagnostics = app.staticTexts["continuity.diagnostics"]
                XCTAssertTrue(diagnostics.label.contains("starts=0"), diagnostics.label)
                input.tap()
                input.typeText("Continuity outgoing")
                let send = app.buttons["chat.send"].firstMatch
                XCTAssertTrue(send.isEnabled)
                send.tap()
                let moving = NSPredicate { _, _ in diagnostics.label.contains("moving=true") }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moving, object: nil)], timeout: 8), .completed, diagnostics.label)
                XCTAssertTrue(diagnostics.label.contains("starts=1"), diagnostics.label)
                XCTAssertTrue(diagnostics.label.contains("historical=0"), diagnostics.label)
                let posted = NSPredicate { _, _ in diagnostics.label.contains("posts=1") }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: posted, object: nil)], timeout: 8), .completed, diagnostics.label)
                let streaming = NSPredicate { _, _ in diagnostics.label.contains("streaming=true") }
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: streaming, object: nil)], timeout: 8), .completed, diagnostics.label)
                XCTAssertFalse(app.textViews["chat.responseText.answer"].exists, "The unfinished answer uses streaming chunks, not the completed document")
                capture(app, name: "continuity-\(profile)-window-\(window)-held")
                app.buttons["continuity.finish"].tap()
                XCTAssertTrue(app.textViews["chat.responseText.answer"].waitForExistence(timeout: 8))
                XCTAssertTrue(diagnostics.label.contains("starts=1"), diagnostics.label)
                XCTAssertTrue(diagnostics.label.contains("posts=1"), diagnostics.label)
                capture(app, name: "continuity-\(profile)-window-\(window)-completed")
                app.terminate()
            }
        }
    }

    private func pillPixels(_ app: XCUIApplication, surface: XCUIElement) throws -> [UInt8] {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        let scale = CGFloat(image.width) / app.frame.width
        let rect = surface.frame.applying(CGAffineTransform(scaleX: scale, y: scale))
        let crop = try XCTUnwrap(image.cropping(to: rect))
        var pixels = [UInt8](repeating: 0, count: 64 * 64)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 64, height: 64,
                                                  bitsPerComponent: 8, bytesPerRow: 64,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        return pixels
    }

    private func pixelDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        zip(lhs, rhs).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(lhs.count)
    }

    private func capture(_ app: XCUIApplication, name: String, settleRendering: Bool = false) {
        // Accessibility settles before the simulator's GPU-backed layer has
        // composited its next frame. Allow that frame to reach the screenshot.
        if settleRendering { Thread.sleep(forTimeInterval: 5) }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let diagnostics = app.staticTexts["continuity.diagnostics"]
        let trace = XCTAttachment(string: diagnostics.label + "\n" + (diagnostics.value as? String ?? ""))
        trace.name = name + "-animation-trace"
        trace.lifetime = .keepAlways
        add(trace)
    }
}
