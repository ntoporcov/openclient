import XCTest

@MainActor
final class SessionCleanupUITests: XCTestCase {
    nonisolated override func record(_ issue: XCTIssue) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanupVisualTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "\(issue.compactDescription)\n\(String(describing: issue.sourceCodeContext.location))"
            .write(to: directory.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
        super.record(issue)
    }

    func testCleanupReviewAndReadOnlyTranscript() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "projects"
        app.launchEnvironment["OPENCLIENT_CLEANUP_FIXTURE"] = "1"
        app.launch()
        defer { app.terminate() }
        let cleanup = app.descendants(matching: .any).matching(identifier: "projects.cleanup").firstMatch
        if app.buttons["Show Sidebar"].waitForExistence(timeout: 2) { app.buttons["Show Sidebar"].tap() }
        if !cleanup.waitForExistence(timeout: 5) { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(cleanup.waitForExistence(timeout: 10))
        if !cleanup.isHittable { app.swipeUp() }
        cleanup.tap()
        XCTAssertTrue(app.staticTexts["By Age"].waitForExistence(timeout: 10))
        capture(app, "cleanup-overview")
        let review = app.descendants(matching: .any).matching(identifier: "cleanup.review").firstMatch
        app.buttons["cleanup.age"].tap()
        XCTAssertTrue(app.staticTexts["Matching chats"].waitForExistence(timeout: 5))
        capture(app, "cleanup-by-age")
        if !review.exists || !review.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["cleanup.project"].waitForExistence(timeout: 5))
        app.buttons["cleanup.project"].tap()
        XCTAssertTrue(app.navigationBars["By Project"].waitForExistence(timeout: 5))
        capture(app, "cleanup-by-project")
        if !review.exists || !review.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        if !review.isHittable { app.swipeUp() }
        review.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cleanup.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 10))
        let firstID = cards.firstMatch.identifier
        capture(app, "cleanup-review")
        // Release partway across the card; the exit animation must finish the
        // dismissal rather than requiring a drag all the way off-screen.
        cards.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: cards.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        capture(app, "cleanup-after-delete-swipe")
        XCTAssertTrue(app.buttons["Delete 1 Chat"].waitForExistence(timeout: 5))
        capture(app, "cleanup-flight-completed")
        app.buttons["Undo Last Swipe"].tap()
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5))
        cards.firstMatch.swipeRight()
        XCTAssertTrue(app.buttons[firstID].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete 1 Chat"].exists)
        app.buttons["Undo Last Swipe"].tap()
        XCTAssertTrue(app.buttons[firstID].waitForExistence(timeout: 5))
        cards.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "cleanup.transcript").firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textViews["chat.input"].exists)
        XCTAssertFalse(app.buttons["chat.send"].exists)
        capture(app, "cleanup-read-only")
        app.buttons["BackButton"].firstMatch.tap()
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5))
        let age = app.buttons["cleanup.age"]
        if !age.exists || !age.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(age.waitForExistence(timeout: 5))
        XCTAssertTrue(review.isHittable)
        if !cleanup.exists || !cleanup.isHittable { showProjects(app) }
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        for _ in 0..<3 {
            let activity = app.buttons["projects.activity"]
            if !activity.isHittable { app.swipeDown() }
            XCTAssertTrue(activity.waitForExistence(timeout: 5))
            activity.tap()
            capture(app, "cleanup-activity-open")
            XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
            if !cleanup.exists || !cleanup.isHittable { showProjects(app) }
            XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
            if !cleanup.isHittable { app.swipeUp() }
            cleanup.tap()
            XCTAssertTrue(age.waitForExistence(timeout: 5))
            age.tap()
            XCTAssertTrue(app.staticTexts["Matching chats"].waitForExistence(timeout: 5))
            if !age.exists || !age.isHittable { app.buttons["BackButton"].firstMatch.tap() }
            XCTAssertTrue(age.waitForExistence(timeout: 5))
            if !cleanup.exists || !cleanup.isHittable { showProjects(app) }
            XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        }
        capture(app, "cleanup-activity-switching-completed")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CleanupVisualTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
        try? app.debugDescription.write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    private func showProjects(_ app: XCUIApplication) {
        if app.buttons["cleanup.done"].exists { app.buttons["cleanup.done"].tap() }
        if app.buttons["projects.cleanup"].exists && app.buttons["projects.cleanup"].isHittable { return }
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else { app.buttons["BackButton"].firstMatch.tap() }
    }
}

/// Exercises the real split shell against the seeded backend, including delayed
/// transcript hydration. Lifecycle history catches transitions hidden by XCTest's
/// normal wait-for-idle behavior.
@MainActor
final class SessionNavigationUITests: XCTestCase {
    nonisolated override func record(_ issue: XCTIssue) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NavigationVisualTests", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? "\(issue.compactDescription)\n\(String(describing: issue.sourceCodeContext.location))"
            .write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        super.record(issue)
    }
    private let firstSession = "session-screenshot-release"
    private let secondSession = "session-screenshot-followup"

    func testChatDraftSurvivesSessionSwitching() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        let input = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH 'navigation.chat.'")).firstMatch
        tap(app, "session.row.\(secondSession)")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let marker = "Preserved draft \(UUID().uuidString)"
        input.typeText(marker)
        let draft = input.value as? String
        XCTAssertTrue(draft?.contains(marker) == true)
        showSessionList(app, sessionID: secondSession)
        tap(app, "session.row.\(firstSession)")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        showSessionList(app, sessionID: firstSession)
        tap(app, "session.row.\(secondSession)")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, draft)
    }

    func testChatOpeningTypingAndActivityNavigationRemainResponsive() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        tap(app, "session.row.\(firstSession)")
        // The navigation fixture's route identifier propagates to the UIKit composer.
        let input = app.textViews.matching(NSPredicate(format: "identifier BEGINSWITH %@", "navigation.chat.")).firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isHittable)
        input.tap()
        let marker = "Navigation regression \(UUID().uuidString)"
        input.typeText(marker)
        XCTAssertTrue((input.value as? String)?.contains(marker) == true)
        showSessionList(app, sessionID: firstSession)
        showProjects(app)
        tap(app, "projects.activity")
        tap(app, "activity.session.\(secondSession)")
        XCTAssertTrue(element(app, "navigation.chat.\(secondSession)").waitForExistence(timeout: 10))
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isHittable)
        showProjects(app)
    }

    func testSessionSwitchingAndBackDoNotBounceOrRemount() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        for id in [firstSession, secondSession, firstSession] {
            showSessionList(app, sessionID: id)
            let start = events(app).count
            element(app, "session.row.\(id)").tap()
            assertChatSettles(app, sessionID: id, since: start)
            showSessionList(app, sessionID: id)
            let afterBack = events(app).count
            assertNoNavigationChanges(app, since: afterBack)
            XCTAssertTrue(element(app, "session.row.\(id)").isHittable)
        }
    }

    func testCleanupMethodsReturnToOptionsWithAnExistingChat() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        let start = events(app).count
        element(app, "session.row.\(firstSession)").tap()
        assertChatSettles(app, sessionID: firstSession, since: start)
        for method in ["age", "project", "review"] {
            showProjects(app)
            tap(app, "projects.cleanup")
            tap(app, "cleanup.\(method)")
            let destination = method == "review" ? "Review Individually" : method == "age" ? "By Age" : "By Project"
            XCTAssertTrue(app.navigationBars[destination].waitForExistence(timeout: 5))
            let options = element(app, "cleanup.age")
            if !options.exists || !options.isHittable { app.buttons["BackButton"].firstMatch.tap() }
            XCTAssertTrue(options.waitForExistence(timeout: 5))
            XCTAssertTrue(options.isHittable)
            let returned = events(app).count
            assertNoNavigationChanges(app, since: returned)
        }
    }

    func testReselectingSameSessionKeepsSingleChatDetail() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        for attempt in 0..<3 {
            showSessionList(app, sessionID: firstSession)
            let start = events(app).count
            element(app, "session.row.\(firstSession)").tap()
            assertChatSettles(app, sessionID: firstSession, since: start, requiresAppearance: attempt == 0)
        }
    }

    func testReadOnlyTranscriptActivityAndProjectSwitchingResetDetailHistory() {
        let app = launch()
        defer { app.terminate() }
        openProject(app)
        let initial = events(app).count
        element(app, "session.row.\(firstSession)").tap()
        assertChatSettles(app, sessionID: firstSession, since: initial)
        for _ in 0..<2 {
            showProjects(app)
            tap(app, "projects.cleanup")
            tap(app, "cleanup.review")
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cleanup.card.'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5))
            card.tap()
            XCTAssertTrue(element(app, "cleanup.transcript").waitForExistence(timeout: 5))
            XCTAssertFalse(app.textViews["chat.input"].exists)
            showProjects(app)
            tap(app, "projects.activity")
            XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5))
            let start = events(app).count
            tap(app, "activity.session.\(secondSession)")
            assertChatSettles(app, sessionID: secondSession, since: start, requiresAppearance: false)
            XCTAssertFalse(element(app, "cleanup.transcript").exists)
            showProjects(app)
            let beforeProject = events(app).count
            openProject(app)
            XCTAssertTrue(element(app, "session.row.\(firstSession)").isHittable)
            XCTAssertFalse(Array(events(app).dropFirst(beforeProject)).contains("column:detail"), "Project selection skipped its session list")
        }
    }

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["OPENCLIENT_SCREENSHOT_SCENE"] = "projects"
        app.launchEnvironment["OPENCLIENT_CLEANUP_FIXTURE"] = "1"
        app.launchEnvironment["OPENCLIENT_NAVIGATION_TRACE"] = "1"
        app.launchEnvironment["OPENCLIENT_PERF_DIAGNOSTICS"] = "1"
        app.launch()
        XCTAssertTrue(element(app, "navigation.trace").waitForExistence(timeout: 10))
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ app: XCUIApplication, _ id: String) {
        let target = element(app, id)
        if id.hasPrefix("activity.session.") {
            let list = element(app, "activity.list")
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            for _ in 0..<3 {
                if target.exists && target.isHittable { break }
                list.swipeUp()
            }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), id)
        XCTAssertTrue(target.isHittable, id)
        target.tap()
    }

    private func showProjects(_ app: XCUIApplication) {
        if app.buttons["cleanup.done"].exists { app.buttons["cleanup.done"].tap() }
        let project = element(app, "projects.project.screenshot-project")
        for _ in 0..<5 {
            if project.exists && project.isHittable { return }
            if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
            else if app.buttons["BackButton"].firstMatch.exists { app.buttons["BackButton"].firstMatch.tap() }
            else { break }
        }
        XCTAssertTrue(project.waitForExistence(timeout: 5))
        XCTAssertTrue(project.isHittable)
    }

    private func openProject(_ app: XCUIApplication) {
        showProjects(app)
        tap(app, "projects.project.screenshot-project")
        XCTAssertTrue(element(app, "session.row.\(firstSession)").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "session.row.\(firstSession)").isHittable)
    }

    private func showSessionList(_ app: XCUIApplication, sessionID: String) {
        let row = element(app, "session.row.\(sessionID)")
        if !row.exists || !row.isHittable { app.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable)
    }

    private func events(_ app: XCUIApplication) -> [String] {
        (element(app, "navigation.trace").value as? String ?? "").split(separator: "|").map(String.init)
    }

    private func assertChatSettles(_ app: XCUIApplication, sessionID: String, since start: Int, requiresAppearance: Bool = true) {
        let appeared = NSPredicate { [self] _, _ in
            element(app, "navigation.chat.\(sessionID)").exists
                && events(app).contains("appear:\(sessionID)")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: appeared, object: nil)], timeout: 10), .completed)
        let stable = events(app).count
        assertNoNavigationChanges(app, since: stable)
        let changes = Array(events(app).dropFirst(start))
        let appearances = changes.filter { $0 == "appear:\(sessionID)" }.count
        XCTAssertLessThanOrEqual(appearances, 1, "Chat remounted: \(changes)")
        if requiresAppearance { XCTAssertEqual(appearances, 1, "Expected the selected chat: \(changes)") }
        XCTAssertFalse(changes.contains("disappear:\(sessionID)"), "Selected chat left the screen: \(changes)")
        // iOS 26 can reparent an offscreen split detail, calling onDisappear/onAppear
        // while preserving its State. Reject unmounts after UIKit confirms visibility,
        // rather than treating those pre-presentation callbacks as lost chat identity.
        if let visible = changes.firstIndex(of: "appear:\(sessionID)") {
            XCTAssertFalse(changes[visible...].contains("unmount:\(sessionID)"), "Visible chat was replaced: \(changes)")
        } else {
            XCTAssertFalse(changes.contains("unmount:\(sessionID)"), "Presented chat was replaced: \(changes)")
        }
        XCTAssertLessThanOrEqual(changes.filter { $0 == "column:detail" }.count, 1, "Repeated detail presentation: \(changes)")
    }

    private func assertNoNavigationChanges(_ app: XCUIApplication, since start: Int) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in events(app).count > start }, object: nil)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.2), .completed, "Navigation changed after settling: \(Array(events(app).dropFirst(start)))")
    }
}
