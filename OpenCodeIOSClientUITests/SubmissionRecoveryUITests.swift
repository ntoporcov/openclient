import XCTest

@MainActor
final class SubmissionRecoveryUITests: XCTestCase {
    func testSeededRecoveryCardAndAttachmentDetailsInRootAndWindow() {
        checkSeededRecovery(profile: "v2")
    }

    func testSeededLegacyRecoveryCardAndAttachmentDetailsInRootAndWindow() {
        checkSeededRecovery(profile: "legacy")
    }

    func testSubmittingRootAndWindowBothProfiles() {
        checkSeededRecovery(profile: "legacy", submitting: true)
        checkSeededRecovery(profile: "v2", submitting: true)
    }

    func testPendingSubmissionShowsBubbleAndThinkingInBothProfilesAndWindows() {
        checkSeededRecovery(profile: "legacy", submitting: true, pendingOnly: true)
        checkSeededRecovery(profile: "v2", submitting: true, pendingOnly: true)
    }

    func testAdmissionHidesStatusAndRemovesItsLayoutSpace() {
        continueAfterFailure = false
        for profile in ["legacy", "v2"] {
            for window in [false, true] {
                for fast in [false, true] {
                    let app = XCUIApplication()
                    app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
                    app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
                    app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
                    app.launchEnvironment["OPENCLIENT_RECOVERY_ADMISSION_CONTROLS"] = "1"
                    app.launchEnvironment["OPENCLIENT_RECOVERY_FAST_ADMISSION"] = fast ? "1" : "0"
                    app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
                    app.launch()
                    let prompt = app.staticTexts["@build preserve this unconfirmed submission."]
                    XCTAssertTrue(prompt.waitForExistence(timeout: 15))
                    let status = app.buttons["chat.recovery.show.recovery-local-input"]
                    let later = app.staticTexts["A later confirmed message."]
                    if !fast {
                        XCTAssertTrue(status.waitForExistence(timeout: 5))
                        let before = later.frame.minY
                        app.buttons["screenshot.recovery.admit"].tap()
                        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
                        XCTAssertLessThan(later.frame.minY, before - 15, "Admission must remove row height, not only hide its content")
                    } else {
                        Thread.sleep(forTimeInterval: 2)
                        XCTAssertFalse(status.exists, "A fast admission never reveals a late status row")
                    }
                    XCTAssertTrue(prompt.exists)
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name = "optimistic-send-admitted-\(profile)-\(window)-fast-\(fast)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                    app.terminate()
                }
            }
        }
    }

    private func checkSeededRecovery(profile: String, submitting: Bool = false, pendingOnly: Bool = false) {
        continueAfterFailure = false
        for window in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "submission-recovery"
            app.launchEnvironment["OPENCLIENT_RECOVERY_WINDOW"] = window ? "1" : "0"
            app.launchEnvironment["OPENCLIENT_RECOVERY_PROFILE"] = profile
            app.launchEnvironment["OPENCLIENT_RECOVERY_SUBMITTING"] = submitting ? "1" : "0"
            app.launchEnvironment["OPENCLIENT_RECOVERY_PENDING_ONLY"] = pendingOnly ? "1" : "0"
            app.launchEnvironment["OPENCODE_UI_TEST_AUTO_CONNECT"] = "0"
            app.launchEnvironment["OPENCODE_UI_TEST_MODE"] = "0"
            app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
            app.launch()
            XCTAssertTrue(app.staticTexts["screenshot.scene.submission-recovery"].waitForExistence(timeout: 15))
            if pendingOnly {
                XCTAssertTrue(app.staticTexts["@build preserve this unconfirmed submission."].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts["Thinking"].exists)
                let immediate = XCTAttachment(screenshot: app.screenshot())
                immediate.name = "optimistic-send-immediate-thinking-\(profile)-\(window)"
                immediate.lifetime = .keepAlways
                add(immediate)
            }
            let card = app.otherElements["chat.recovery.recovery-local-input"]
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            if submitting {
                let beginning = XCTAttachment(screenshot: app.screenshot())
                beginning.name = "optimistic-send-\(profile)-\(window)-beginning"
                beginning.lifetime = .keepAlways
                add(beginning)
            }
            XCTAssertTrue(app.staticTexts[submitting ? "Sending" : "Submission unconfirmed"].exists)
            XCTAssertTrue(app.buttons["chat.recovery.show.recovery-local-input"].isEnabled)
            let transcript = app.descendants(matching: .any)["chat.scroll"].firstMatch
            let earlyHierarchy = XCTAttachment(string: app.debugDescription)
            earlyHierarchy.lifetime = .keepAlways
            add(earlyHierarchy)
            let earlyScreenshot = XCTAttachment(screenshot: app.screenshot())
            earlyScreenshot.lifetime = .keepAlways
            add(earlyScreenshot)
            XCTAssertTrue(transcript.staticTexts["@build preserve this unconfirmed submission."].exists)
            XCTAssertFalse(app.otherElements["chat.submissionRecovery"].exists)
            if !pendingOnly { XCTAssertLessThan(card.frame.maxY, transcript.staticTexts["A later confirmed message."].frame.minY) }
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "optimistic-send-\(profile)-\(window)-\(submitting)-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let overview = XCTAttachment(screenshot: app.screenshot())
            overview.name = "\(profile) " + (window ? "Seeded window recovery card" : "Seeded root recovery card")
            overview.lifetime = .keepAlways
            add(overview)
            if submitting {
                Thread.sleep(forTimeInterval: 2.1)
                XCTAssertTrue(app.staticTexts["Sending"].exists, "The display timer must not claim admission")
                let held = XCTAttachment(screenshot: app.screenshot())
                held.name = "optimistic-send-\(profile)-\(window)-held"
                held.lifetime = .keepAlways
                add(held)
            }
            app.buttons["Show status"].tap()
            XCTAssertTrue(app.navigationBars["Submission details"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["@build preserve this unconfirmed submission."].exists)
            XCTAssertTrue(app.staticTexts["recovery-note.txt"].exists)
            XCTAssertTrue(app.staticTexts["recovery-local-input"].exists)
            XCTAssertTrue(app.buttons["Copy"].exists)
            XCTAssertEqual(app.buttons["chat.recovery.check.recovery-local-input"].isEnabled, !submitting)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "\(profile) " + (window ? "Seeded window recovery details" : "Seeded root recovery details")
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["Done"].firstMatch.tap()
            XCTAssertTrue(card.waitForExistence(timeout: 3))
            app.terminate()
        }
        // Presentation coverage only: no POST, receipt loss, server restart, or provider execution is simulated here.
    }
}
