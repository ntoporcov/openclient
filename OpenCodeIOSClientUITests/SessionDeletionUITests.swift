import XCTest

@MainActor
final class SessionDeletionUITests: XCTestCase {
    func testNativeDeletionOfMiddlePinnedAndLastSession() async throws {
        continueAfterFailure = false
        let fixture = try DeletionFixture.loadOwnedManifest()
        try await fixture.verify()
        let initial = try await fixture.request("/api/session")
        guard (initial["data"] as? [[String: Any]])?.isEmpty == true else {
            throw NSError(domain: "DeletionFixture", code: 5, userInfo: [NSLocalizedDescriptionKey: "Last-row reproduction requires a fresh empty fixture"])
        }
        let app = XCUIApplication()
        var owned: [String] = []
        var titles: [String] = []
        for index in 0..<4 {
            let title = "Deletion \(index) \(UUID().uuidString.prefix(8))"
            let response = try await fixture.request("/api/session", method: "POST", body: [
                "title": title,
                "location": ["directory": fixture.workspace.path]
            ])
            owned.append(try XCTUnwrap((response["data"] as? [String: Any])?["id"] as? String))
            titles.append(title)
        }
        addTeardownBlock { @MainActor in
            app.terminate()
            for id in owned { _ = try? await fixture.request("/api/session/\(id)", method: "DELETE") }
        }
        app.launchEnvironment = [
            "OPENCODE_UI_TEST_MODE": "1", "OPENCODE_UI_TEST_AUTO_CONNECT": "0",
            "OPENCODE_UI_TEST_BASE_URL": fixture.baseURL,
            "OPENCODE_UI_TEST_USERNAME": fixture.username,
            "OPENCODE_UI_TEST_PASSWORD": fixture.password,
            "OPENCODE_UI_TEST_DIRECTORY": fixture.workspace.path
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-LogForEachSlowPath", "YES"]
        app.launch()
        let form = app.collectionViews["connection.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 20))
        let connect = app.buttons["connection.connect"]
        for _ in 0..<5 where !connect.isHittable { form.swipeUp() }
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        let global = app.staticTexts["Global"].firstMatch
        let connected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in global.isHittable && !connect.exists }, object: nil)
        await fulfillment(of: [connected], timeout: 40)
        if fixture.isLegacy {
            XCTAssertFalse(app.buttons["connection.v2-notice.dismiss"].exists)
        } else {
            let dismissNotice = app.buttons["connection.v2-notice.dismiss"]
            XCTAssertTrue(dismissNotice.waitForExistence(timeout: 15))
            XCTAssertTrue(dismissNotice.isHittable)
            dismissNotice.tap()
        }
        global.tap()
        func row(_ id: String) -> XCUIElement { app.buttons["session.row.\(id)"] }
        func chatTitle(_ index: Int) -> XCUIElement {
            app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label == %@", titles[index])).firstMatch
        }
        func selectAndRevealList(_ index: Int, phase: String) async throws {
            row(owned[index]).tap()
            guard app.textViews["chat.input"].waitForExistence(timeout: 20), chatTitle(index).waitForExistence(timeout: 5) else {
                throw NSError(domain: "DeletionUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Requested chat was not presented"])
            }
            capture(app, phase + "-selected-chat")
            if !row(owned[index]).isHittable, app.navigationBars.buttons["BackButton"].firstMatch.exists {
                // Compact back navigation changes the column, not the canonical selection.
                app.navigationBars.buttons["BackButton"].firstMatch.tap()
            } else {
                XCTAssertTrue(chatTitle(index).exists, "Split detail must remain on the selected session")
            }
            XCTAssertTrue(row(owned[index]).isHittable)
            capture(app, phase + "-selected-row-before-delete")
        }
        func deleteFromMenu(_ index: Int) async throws {
            row(owned[index]).press(forDuration: 1)
            let action = app.buttons["Delete"].firstMatch
            guard action.waitForExistence(timeout: 5) else {
                throw NSError(domain: "DeletionUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Native Delete action did not appear"])
            }
            action.tap()
            try await waitForRemoval(app, element: row(owned[index]))
            let status = try await fixture.status("/api/session/\(owned[index])")
            XCTAssertEqual(status, 404)
            XCTAssertFalse(chatTitle(index).exists)
            XCTAssertFalse(app.textViews["chat.input"].exists)
            if app.buttons["Show Sidebar"].exists {
                XCTAssertTrue(app.staticTexts["Select a Session"].waitForExistence(timeout: 5))
            }
        }
        XCTAssertTrue(row(owned[1]).waitForExistence(timeout: 20))
        try await selectAndRevealList(1, phase: "middle")
        // Control: deleting another row must leave the selected chat and its peers intact.
        row(owned[3]).swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 3) { delete.tap() }
        try await waitForRemoval(app, element: row(owned[3]))
        let controlStatus = try await fixture.status("/api/session/\(owned[3])")
        XCTAssertEqual(controlStatus, 404)
        for index in 0..<3 { XCTAssertTrue(row(owned[index]).exists) }
        if app.buttons["Show Sidebar"].exists { XCTAssertTrue(chatTitle(1).exists) }
        capture(app, "after-unselected-control-delete")

        try await deleteFromMenu(1)
        for index in [0, 2] {
            XCTAssertTrue(row(owned[index]).isHittable)
            let status = try await fixture.status("/api/session/\(owned[index])")
            XCTAssertEqual(status, 200)
        }
        capture(app, "after-selected-middle-delete-two-survivors")

        row(owned[0]).press(forDuration: 1)
        XCTAssertTrue(app.buttons["Pin"].waitForExistence(timeout: 5))
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5))
        try await selectAndRevealList(0, phase: "pinned")
        try await deleteFromMenu(0)
        XCTAssertTrue(row(owned[2]).isHittable)
        XCTAssertFalse(app.staticTexts["Pinned"].exists)
        capture(app, "after-selected-pinned-delete-one-survivor")

        try await selectAndRevealList(2, phase: "last")
        try await deleteFromMenu(2)
        XCTAssertTrue(app.staticTexts["Create a session to start chatting."].waitForExistence(timeout: 10))
        capture(app, "after-last-session-delete")
        for id in owned {
            let status = try await fixture.status("/api/session/\(id)")
            XCTAssertEqual(status, 404)
        }

        let activityResponse = try await fixture.request("/api/session", method: "POST", body: [
            "title": "Deletion Activity \(UUID().uuidString.prefix(8))",
            "location": ["directory": fixture.workspace.path]
        ])
        let activityID = try XCTUnwrap((activityResponse["data"] as? [String: Any])?["id"] as? String)
        owned.append(activityID)
        if app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        else { app.navigationBars.buttons["BackButton"].firstMatch.tap() }
        XCTAssertTrue(app.buttons["projects.activity"].waitForExistence(timeout: 10))
        app.buttons["projects.activity"].tap()
        let activityRow = app.buttons["activity.session.\(activityID)"]
        XCTAssertTrue(activityRow.waitForExistence(timeout: 20))
        capture(app, "before-last-activity-delete")
        activityRow.press(forDuration: 1)
        let activityDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(activityDelete.waitForExistence(timeout: 5))
        activityDelete.tap()
        try await waitForRemoval(app, element: activityRow)
        let activityStatus = try await fixture.status("/api/session/\(activityID)")
        XCTAssertEqual(activityStatus, 404)
        capture(app, "after-last-activity-delete")
    }

    private func waitForRemoval(_ app: XCUIApplication, element: XCUIElement) async throws {
        for _ in 0..<100 {
            XCTAssertEqual(app.state, .runningForeground, "App exited during native List deletion")
            if !element.exists {
                try await Task.sleep(for: .seconds(1))
                XCTAssertEqual(app.state, .runningForeground)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        capture(app, "deletion-did-not-settle")
        throw NSError(domain: "DeletionUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Deleted row remained visible"])
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        guard !app.secureTextFields["connection.password"].exists else { return }
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

final class DeletionFixture: NSObject, URLSessionTaskDelegate {
    let serverPID: Int
    let root: URL
    let isLegacy: Bool
    var baseURL: String { isLegacy ? "http://127.0.0.1:14096" : "http://127.0.0.1:14097" }
    var username: String { "opencode" }
    let password: String
    var workspace: URL { root.appendingPathComponent("workspace").resolvingSymlinksInPath() }

    init(value: [String: Any], root: URL) throws {
        serverPID = try XCTUnwrap(value["server_pid"] as? Int)
        password = try XCTUnwrap(value["password"] as? String)
        self.root = root
        isLegacy = root.lastPathComponent.hasPrefix("deletion-legacy-")
    }

    static func loadOwnedManifest(legacy: Bool? = nil) throws -> DeletionFixture {
        let environment = ProcessInfo.processInfo.environment
        let selectedPath = legacy.map { environment[$0 ? "OPENCLIENT_DELETION_LEGACY_MANIFEST_PATH" : "OPENCLIENT_ACCEPTANCE_MANIFEST_PATH"] }
            ?? (environment["OPENCLIENT_DELETION_LEGACY_MANIFEST_PATH"] ?? environment["OPENCLIENT_ACCEPTANCE_MANIFEST_PATH"])
        guard let path = selectedPath else {
            throw XCTSkip("Owned acceptance fixture manifest required")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = url.deletingLastPathComponent()
        let parent = URL(fileURLWithPath: "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode").resolvingSymlinksInPath()
        let legacy = root.lastPathComponent.hasPrefix("deletion-legacy-")
        guard root.deletingLastPathComponent() == parent, legacy || root.lastPathComponent.hasPrefix("acceptance-next17155-") else {
            throw NSError(domain: "DeletionFixture", code: 1)
        }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        guard value["base_url"] as? String == (legacy ? "http://127.0.0.1:14096" : "http://127.0.0.1:14097"),
              value["version"] as? String == (legacy ? "1.18.29" : "0.0.0-next-17155"), value["password"] is String,
              try String(contentsOf: root.appendingPathComponent(legacy ? ".deletion-root" : ".acceptance-root"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == value["run_id"] as? String else {
            throw NSError(domain: "DeletionFixture", code: 2)
        }
        return try DeletionFixture(value: value, root: root)
    }

    func verify() async throws {
        if isLegacy {
            let health = try await request("/api/health")
            let location = try await request("/api/location")
            guard health["version"] as? String == "1.18.29",
                  URL(fileURLWithPath: location["directory"] as? String ?? "").resolvingSymlinksInPath() == workspace else {
                throw NSError(domain: "DeletionFixture", code: 3)
            }
            return
        }
        let health = try await request("/api/health")
        let location = try await request("/api/location")
        guard health["pid"] as? Int == serverPID,
              health["version"] as? String == "0.0.0-next-17155",
              URL(fileURLWithPath: location["directory"] as? String ?? "").resolvingSymlinksInPath() == workspace else {
            throw NSError(domain: "DeletionFixture", code: 3)
        }
    }

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let (data, status) = try await send(path, method: method, body: body)
        guard (200..<300).contains(status) else { throw NSError(domain: "DeletionFixtureHTTP", code: status) }
        guard !data.isEmpty else { return [:] }
        let value = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        if isLegacy, path == "/api/session" { return ["data": value] }
        return value as? [String: Any] ?? [:]
    }

    func status(_ path: String) async throws -> Int { try await send(path, method: "GET", body: nil).1 }

    private func send(_ path: String, method: String, body: [String: Any]?) async throws -> (Data, Int) {
        guard path.hasPrefix("/api/"), !path.contains("..") else { throw NSError(domain: "DeletionFixture", code: 4) }
        let actualPath = isLegacy ? (path == "/api/health" ? "/global/health" : path == "/api/location" ? "/path" : String(path.dropFirst(4))) : path
        var request = URLRequest(url: try XCTUnwrap(URL(string: baseURL + actualPath)))
        request.httpMethod = method
        request.setValue("Basic " + Data("\(username):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            var body = body
            if isLegacy, path == "/api/session" { body.removeValue(forKey: "location") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
