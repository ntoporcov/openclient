import XCTest

@MainActor
final class ResponseCopyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDurationCaptionLocalizedLayoutAndMissingStart() throws {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        for (language, locale, prefix) in [
            ("en", "en_US", "Turn took "),
            ("pt-BR", "pt_BR", "O turno levou "),
            ("it", "it_IT", "Il turno ha richiesto ")
        ] {
            for appearance in ["Light", "Dark"] {
                XCUIDevice.shared.appearance = appearance == "Dark" ? .dark : .light
                let app = XCUIApplication()
                app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
                app.launchEnvironment["OPENCLIENT_UI_TEST_RESPONSE_COPY"] = "1"
                app.launchEnvironment["OPENCLIENT_UI_TEST_RESPONSE_DURATION"] = appearance == "Dark" ? "hours" : "known"
                app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
                app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
                app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
                if appearance == "Dark" {
                    app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
                }
                app.launch()
                XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].waitForExistence(timeout: 15))
                let transcript = app.collectionViews["chat.scroll"]
                let answer = app.textViews["chat.responseText.response-copy-followup"]
                reveal(answer, in: transcript, towardStart: true)
                answer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
                let copy = app.buttons["chat.copyResponse.response-copy-prompt"]
                reveal(copy, in: transcript, towardStart: false)
                let clock = app.staticTexts["chat.responseCompletedAt.response-copy-prompt"]
                let duration = app.staticTexts["chat.responseDuration.response-copy-prompt"]
                let actions = app.buttons["chat.responseActions.response-copy-prompt"]
                XCTAssertTrue(duration.waitForExistence(timeout: 3))
                let seconds = appearance == "Dark" ? 3_723.0 : 83.0
                let expected = Duration.seconds(seconds).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)
                        .locale(Locale(identifier: locale))
                )
                XCTAssertEqual(duration.label, prefix + expected)
                XCTAssertGreaterThanOrEqual(duration.frame.minX, clock.frame.maxX)
                XCTAssertEqual(duration.frame.midY, clock.frame.midY, accuracy: 2)
                XCTAssertLessThanOrEqual(duration.frame.maxX, copy.frame.minX)
                for control in [copy, actions] {
                    XCTAssertTrue(control.isHittable)
                    XCTAssertGreaterThanOrEqual(control.frame.width, 44)
                    XCTAssertGreaterThanOrEqual(control.frame.height, 44)
                    XCTAssertLessThanOrEqual(control.frame.maxX, transcript.frame.maxX)
                }
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "Duration-\(language)-\(appearance)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_UI_TEST_RESPONSE_COPY"] = "1"
        app.launchEnvironment["OPENCLIENT_UI_TEST_RESPONSE_DURATION"] = "missing"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].waitForExistence(timeout: 15))
        let transcript = app.collectionViews["chat.scroll"]
        let answer = app.textViews["chat.responseText.response-copy-followup"]
        reveal(answer, in: transcript, towardStart: true)
        answer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let copy = app.buttons["chat.copyResponse.response-copy-prompt"]
        reveal(copy, in: transcript, towardStart: false)
        XCTAssertTrue(app.staticTexts["chat.responseCompletedAt.response-copy-prompt"].exists)
        XCTAssertFalse(app.staticTexts["chat.responseDuration.response-copy-prompt"].exists)
        XCTAssertTrue(copy.isHittable)
    }

    func testResponseCopyAndSelection() throws {
        let app = XCUIApplication()
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "chat"
        app.launchEnvironment["OPENCLIENT_UI_TEST_RESPONSE_COPY"] = "1"
        app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
        app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].waitForExistence(timeout: 15))

        let transcript = app.collectionViews["chat.scroll"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        let copy = app.buttons["chat.copyResponse.response-copy-prompt"]
        let actions = app.buttons["chat.responseActions.response-copy-prompt"]
        let completedAt = app.staticTexts["chat.responseCompletedAt.response-copy-prompt"]
        let paragraph = app.textViews["chat.responseText.response-copy-answer"]
        let followup = app.textViews["chat.responseText.response-copy-followup"]
        let prompt = transcript.staticTexts["Explain the update."]
        let tool = transcript.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "Capture screenshot scenes", "Captures the App Store screenshot set"
        )).firstMatch

        func assertCaption(visible: Bool, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(copy.exists, visible, file: file, line: line)
            XCTAssertEqual(actions.exists, visible, file: file, line: line)
            XCTAssertEqual(completedAt.exists, visible, file: file, line: line)
            XCTAssertEqual(app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "chat.copyResponse."
            )).count, visible ? 1 : 0, file: file, line: line)
            XCTAssertEqual(app.buttons.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "chat.responseActions."
            )).count, visible ? 1 : 0, file: file, line: line)
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(
                format: "identifier BEGINSWITH %@", "chat.responseCompletedAt."
            )).count, visible ? 1 : 0, file: file, line: line)
        }

        assertCaption(visible: false)
        XCTAssertTrue(tool.waitForExistence(timeout: 3))
        var bottomCell: XCUIElement { transcript.cells.element(boundBy: transcript.cells.count - 1) }
        let hiddenTailHeight = bottomCell.frame.maxY - tool.frame.maxY
        XCTAssertLessThan(hiddenTailHeight, 32, "Hidden captions must not reserve a row of space")
        reveal(paragraph, in: transcript, towardStart: true)
        // One native value must span both server text parts, including the list.
        let answerText = try XCTUnwrap(paragraph.value as? String)
        XCTAssertTrue(answerText.hasPrefix("First paragraph has formatted text."))
        XCTAssertTrue(answerText.contains("A second paragraph belongs to the same answer."))
        XCTAssertTrue(answerText.contains("This paragraph comes from another text part."))
        XCTAssertTrue(answerText.contains("Select across paragraphs"))
        XCTAssertTrue(answerText.contains("Keep the text together"))
        XCTAssertFalse(answerText.contains("**"))
        assertCaption(visible: false)

        // Press a real glyph on the first line, not the blank center of the view.
        let firstLine = paragraph.textViews.matching(NSPredicate(
            format: "label BEGINSWITH %@", "First paragraph has"
        )).firstMatch
        XCTAssertTrue(firstLine.exists)
        firstLine.press(forDuration: 1)
        let nativeCopy = app.menuItems["Copy"]
        XCTAssertTrue(nativeCopy.waitForExistence(timeout: 3))
        assertCaption(visible: false)
        XCTAssertFalse(app.buttons["Debug JSON"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let inlineSelection = XCTAttachment(screenshot: app.screenshot())
        inlineSelection.name = "Inline native selection with turn caption hidden"
        inlineSelection.lifetime = .keepAlways
        add(inlineSelection)
        nativeCopy.tap()
        XCTAssertTrue(nativeCopy.waitForNonExistence(timeout: 3))
        assertCaption(visible: false)

        // Copy can retain UIKit's selected range. Clear it outside assistant text
        // before testing a quick tap in the other, previously unselected answer.
        reveal(prompt, in: transcript, towardStart: true)
        prompt.tap()
        assertCaption(visible: false)
        reveal(followup, in: transcript, towardStart: false)
        // A normal tap in the whitespace beside the line should also reveal actions.
        followup.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 3))
        reveal(copy, in: transcript, towardStart: false)
        assertCaption(visible: true)
        let revealedTailHeight = bottomCell.frame.maxY - tool.frame.maxY
        XCTAssertEqual(revealedTailHeight - hiddenTailHeight, 44, accuracy: 2,
                       "Showing the caption should expand the transcript layout")
        XCTAssertTrue(actions.isHittable)
        XCTAssertGreaterThanOrEqual(copy.frame.width, 44)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44)
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44)
        XCTAssertTrue(completedAt.isHittable)
        XCTAssertTrue(followup.exists)
        XCTAssertTrue(tool.exists, "The completed tool-only row must remain in the turn")
        XCTAssertTrue(tool.isHittable)
        XCTAssertGreaterThan(tool.frame.minY, followup.frame.maxY)
        for element in [copy, actions, completedAt] {
            XCTAssertGreaterThan(element.frame.minY, followup.frame.maxY)
            XCTAssertGreaterThanOrEqual(element.frame.minY, tool.frame.maxY,
                                        "The only caption belongs below the last tool row")
        }
        XCTAssertTrue(completedAt.label.hasPrefix("Completed at "))

        let caption = XCTAttachment(screenshot: app.screenshot())
        caption.name = "Single response turn caption below trailing tool"
        caption.lifetime = .keepAlways
        add(caption)

        reveal(paragraph, in: transcript, towardStart: true)
        paragraph.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 15, dy: 12)).tap()
        reveal(copy, in: transcript, towardStart: false)
        assertCaption(visible: true)

        XCTAssertEqual(copy.label, "Copy")
        copy.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        // XCTest can wait for UI idleness until after the brief checkmark has reset.
        XCTAssertTrue(copy.wait(for: \.label, toEqual: "Copy", timeout: 5))

        actions.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
        let markdown = app.buttons["chat.copyResponseMarkdown"]
        XCTAssertTrue(markdown.waitForExistence(timeout: 3))
        XCTAssertEqual(markdown.label, "Copy as Markdown")
        markdown.tap()
        // Menu dismissal can take longer than the transient two-second copy feedback.
        XCTAssertTrue(copy.wait(for: \.label, toEqual: "Copy", timeout: 5))
        assertCaption(visible: true)

        actions.tap()
        let select = app.buttons["chat.selectResponseText"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForExistence(timeout: 3))

        let selection = app.textViews["chat.responseSelectionText"]
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        XCTAssertTrue(selection.isHittable)
        let selectedText = try XCTUnwrap(selection.value as? String)
        let turnParagraphs = [
            "First paragraph has formatted text.",
            "A second paragraph belongs to the same answer.",
            "This paragraph comes from another text part.",
            "Select across paragraphs",
            "Keep the text together",
            "The final answer completes the turn."
        ]
        var remaining = selectedText[...]
        for text in turnParagraphs {
            let range = try XCTUnwrap(remaining.range(of: text), "Missing or out-of-order turn text: \(text)")
            remaining = remaining[range.upperBound...]
        }
        XCTAssertTrue(selectedText.hasPrefix(turnParagraphs[0]))
        XCTAssertTrue(selectedText.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(turnParagraphs[5]))
        for excluded in ["Explain the update.", "Capture screenshot scenes", "fastlane ios screenshots",
                         "Prepared 6 deterministic scenes", "Captures the App Store screenshot set", "**"] {
            XCTAssertFalse(selectedText.contains(excluded), "Selection must contain only the rendered turn text")
        }

        selection.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 50, dy: 12)).press(forDuration: 1)
        XCTAssertTrue(app.menuItems["Copy"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Full turn text selection"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.menuItems["Copy"].tap()
        app.navigationBars["Select Text"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Select Text"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        reveal(copy, in: transcript, towardStart: false)
        assertCaption(visible: true)
        XCTAssertTrue(followup.exists)
        XCTAssertEqual(followup.value as? String, "The final answer completes the turn.")
        XCTAssertTrue(tool.exists)
        XCTAssertTrue(app.staticTexts["screenshot.scene.chat"].exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // Verify the clipboard through a real paste, rather than timing transient feedback.
        actions.tap()
        markdown.tap()
        let input = app.textViews["chat.input"]
        input.tap()
        input.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        let expectedMarkdown = "First paragraph has **formatted text**.\n\nA second paragraph belongs to the same answer.\n\nThis paragraph comes from another text part.\n\n- Select across paragraphs\n- Keep the text together\n\nThe final answer completes the turn."
        XCTAssertEqual(input.value as? String, expectedMarkdown)
    }

    private func reveal(
        _ element: XCUIElement,
        in transcript: XCUIElement,
        towardStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0..<8 {
            let viewport = transcript.frame.insetBy(dx: 0, dy: 20)
            if element.exists, element.isHittable,
               element.frame.minY >= viewport.minY,
               min(element.frame.maxY, element.frame.minY + 24) <= viewport.maxY {
                return
            }
            let scrollTowardStart = element.exists && !element.frame.isEmpty
                ? element.frame.minY < viewport.minY : towardStart
            transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: scrollTowardStart ? 0.35 : 0.75))
                .press(forDuration: 0.05, thenDragTo: transcript.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.9, dy: scrollTowardStart ? 0.75 : 0.35)
                ))
        }
        XCTFail("Could not expose the first line of \(element.identifier) in chat.scroll", file: file, line: line)
    }
}
