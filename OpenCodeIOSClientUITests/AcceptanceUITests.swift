import XCTest
import CryptoKit

@MainActor
final class AcceptanceUITests: XCTestCase {
    private var app = XCUIApplication()
    private var fixture: AcceptanceFixture!
    private var sessionID: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNativeComposerStreamingStopPhotoAndLifecycleAgainstScriptedRuntime() async throws {
        fixture = try AcceptanceFixture.load()
        try await fixture.verify()
        for key in app.launchEnvironment.keys where key.hasPrefix("OPENCODE_UI_TEST_") || key.hasPrefix("OPENCLIENT_SCREENSHOT") {
            app.launchEnvironment.removeValue(forKey: key)
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "System password save prompt") { prompt in
            guard prompt.label == "Save Password?" || prompt.staticTexts["Save Password?"].exists,
                  prompt.buttons["Not Now"].exists else { return false }
            prompt.buttons["Not Now"].tap()
            return true
        }
        addTeardownBlock { @MainActor [self] in
            app.terminate()
            // Failure cleanup only. Stop assertions below never use this API path.
            if let sessionID { _ = try? await fixture.request("/api/session/\(sessionID)/interrupt", body: [:]) }
        }
        app.launch()
        try await connectNormally()
        let title = "Acceptance \(UUID().uuidString.prefix(8))"
        let global = app.staticTexts["Global"].firstMatch
        let create = app.buttons["sessions.create"]
        for _ in 0..<2 {
            try await wait("Global project") { global.isHittable }
            global.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            if create.waitForExistence(timeout: 3) { break }
        }
        try await wait("Native new-session action") { create.isHittable }
        create.tap()
        let rename = app.buttons["projects.newChat.navigationTitleButton"]
        try await wait("Native new-chat rename action") { rename.isHittable }
        rename.tap()
        let titleField = app.textFields["projects.newChat.titleField"]
        try await wait("Native session title") { titleField.isHittable }
        titleField.tap()
        titleField.typeText(title + "\n")
        try await wait("New chat composer", timeout: 30) { app.textViews["chat.input"].exists }
        // The real new-chat composer creates the session on its first Send.
        let first = marker("reasoning")
        try await send(first)
        _ = try await fixture.waitEvent(first, kind: "held", stage: 1)
        let sessions = try await fixture.request("/api/session", query: [.init(name: "project", value: "global"), .init(name: "search", value: title)])
        let rows = try XCTUnwrap(sessions["data"] as? [[String: Any]]).filter { $0["title"] as? String == title }
        XCTAssertEqual(rows.count, 1)
        sessionID = try XCTUnwrap(rows.first?["id"] as? String)

        // Five real composer sends fit the unmodified free plan on a fresh device.
        let firstText = try await held(first, assistantCount: 1, stage: 1)
        _ = try await fixture.request("/control/advance", body: ["marker": first], provider: true)
        let secondText = try await held(first, assistantCount: 1, stage: 2)
        XCTAssertNotEqual(firstText, secondText)
        XCTAssertTrue(secondText.hasPrefix(firstText))
        _ = try await finish(first, assistantCount: 1)
        let reasoning = try await canonical().filter { $0["type"] as? String == "assistant" }.first
        let reasoningParts = (reasoning?["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "reasoning" }
        XCTAssertEqual(reasoningParts.compactMap { $0["text"] as? String }, [outputPrefix(first) + ": reasoning, not answer text."])

        let interrupted = marker("interrupt")
        try await send(interrupted)
        let partial = try await held(interrupted, assistantCount: 2, stage: 1)
        let stop = app.buttons.matching(NSPredicate(format: "identifier == 'chat.stream.stop' OR identifier == 'chat.stop'")).firstMatch
        try await wait("Actual native stop button") { stop.exists && stop.isHittable }
        capture("acceptance-before-native-stop")
        stop.tap()
        _ = try await fixture.waitEvent(interrupted, kind: "disconnected")
        _ = try await fixture.request("/api/session/\(sessionID!)/wait", body: [:])
        let aborted = try await canonical().filter { $0["type"] as? String == "assistant" }
        XCTAssertEqual(aborted.count, 2)
        XCTAssertEqual(answer(aborted[1]), partial)
        XCTAssertEqual((aborted[1]["error"] as? [String: Any])?["type"] as? String, "aborted")
        try await evidence(interrupted, phase: "native-stop-provider-disconnected", text: partial, finished: false)
        capture("acceptance-native-stop-complete")

        let followUp = marker("stream")
        try await send(followUp)
        _ = try await held(followUp, assistantCount: 3, stage: 1)
        _ = try await finish(followUp, assistantCount: 3)

        app.buttons["chat.composer.menu"].tap()
        let photos = app.buttons["chat.composer.photos"]
        try await wait("Native Photos action") { photos.isHittable }
        photos.tap()
        let photoPermission = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        if photoPermission.waitForExistence(timeout: 5) { photoPermission.tap() }
        try await wait("System Photos picker") { app.buttons["Cancel"].exists || app.navigationBars["Photos"].exists }
        capture("acceptance-native-photos-picker")
        let photo = app.scrollViews["photosView_content_scroll_view"].images.matching(identifier: "PXGGridLayout-Info").firstMatch
        try await wait("Seeded OS photo visible in picker") {
            photo.exists && photo.frame.width >= 44 && photo.frame.height >= 44
                && photo.frame.minY >= app.navigationBars["Photos"].frame.maxY
                && app.scrollViews["photosView_content_scroll_view"].frame.insetBy(dx: -1, dy: -1).contains(photo.frame)
        }
        capture("acceptance-seeded-photo-visible")
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let done = app.navigationBars["Photos"].buttons["Done"]
        try await wait("Selected photo can be added") { done.isEnabled && done.isHittable }
        done.tap()
        try await wait("Photo imported into the removable composer card", timeout: 30) {
            app.textViews["chat.input"].isHittable && !app.navigationBars["Photos"].exists
                && app.scrollViews.containing(.button, identifier: "xmark").firstMatch.exists
                && !app.staticTexts["Preparing attachments"].exists
        }
        capture("acceptance-native-photo-attached")
        let attachment = marker("attachment")
        try await send(attachment)
        _ = try await held(attachment, assistantCount: 4, stage: 1)
        let context = try await canonical()
        let user = try XCTUnwrap(context.last { $0["type"] as? String == "user" })
        let files = try XCTUnwrap(user["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(files[0]["data"] as? String)))
        let mime = try XCTUnwrap(files[0]["mime"] as? String)
        XCTAssertTrue(mime.hasPrefix("image/"))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let request = try await fixture.waitEvent(attachment, kind: "request")
        let media = try XCTUnwrap(request["media"] as? [[String: Any]])
        XCTAssertEqual(media.count, 1)
        XCTAssertEqual(media[0]["mime"] as? String, mime)
        XCTAssertEqual(media[0]["bytes"] as? Int, bytes.count)
        XCTAssertEqual(media[0]["sha256"] as? String, digest)
        _ = try await finish(attachment, assistantCount: 4)

        let background = marker("stream")
        try await send(background)
        _ = try await held(background, assistantCount: 5, stage: 1)
        XCUIDevice.shared.press(.home)
        try await wait("App actually backgrounded") { app.state == .runningBackground || app.state == .runningBackgroundSuspended }
        _ = try await fixture.request("/control/advance", body: ["marker": background], provider: true)
        _ = try await fixture.waitEvent(background, kind: "held", stage: 2)
        _ = try await fixture.request("/control/finish", body: ["marker": background], provider: true)
        _ = try await fixture.waitEvent(background, kind: "finished")
        _ = try await fixture.request("/api/session/\(sessionID!)/wait", body: [:])
        let completed = try await canonical()
        let finalAnswer = answer(try XCTUnwrap(completed.last { $0["type"] as? String == "assistant" }))
        XCTAssertEqual(finalAnswer, expectedText(background, stage: 3))
        app.activate()
        try await wait("Foreground catches up without pull-to-refresh", timeout: 30) { self.answerElement(finalAnswer).exists }
        capture("acceptance-background-catchup-no-pull")
        try await evidence(background, phase: "background-completed-foreground-catchup", text: finalAnswer, finished: true)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launch()
        try await reconnectSavedServer()
        let search = app.textFields["projects.searchChats"]
        try await wait("Cold relaunch home search") { search.isHittable }
        search.tap()
        search.typeText(title)
        let result = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", title, "session.row.\(sessionID!)")).firstMatch
        try await wait("Persisted server canonical session") { result.isHittable }
        result.tap()
        try await wait("Cold canonical transcript", timeout: 30) { self.answerElement(finalAnswer).exists && app.textViews["chat.input"].exists }
        capture("acceptance-cold-relaunch-saved-server-and-transcript")
        let finalContext = try await canonical()
        XCTAssertEqual(NSArray(array: finalContext), NSArray(array: completed), "Cold navigation must not generate or duplicate messages")
        XCTAssertEqual(finalContext.filter { $0["type"] as? String == "user" }.count, 5)
        XCTAssertEqual(finalContext.filter { $0["type"] as? String == "assistant" }.count, 5)
        XCTAssertEqual(Set(finalContext.compactMap { $0["id"] as? String }).count, finalContext.count)
    }

    private func marker(_ scenario: String) -> String { "[[acceptance:\(scenario):\(UUID().uuidString)]]" }

    private func outputPrefix(_ marker: String) -> String {
        let fields = marker.dropFirst(2).dropLast(2).split(separator: ":")
        return "Acceptance \(fields[1])/\(fields[2])"
    }

    private func expectedText(_ marker: String, stage: Int) -> String {
        let prefix = outputPrefix(marker)
        return ["\(prefix): first. ", "\(prefix): progress. ", "\(prefix): complete."].prefix(stage).joined()
    }

    private func connectNormally() async throws {
        let url = app.textFields["connection.baseURL"]
        try await wait("Fresh normal automatic connection editor", timeout: 30) { app.collectionViews["connection.form"].exists && url.exists }
        try await replace(app.textFields["connection.name"], with: "Acceptance \(fixture.runID.prefix(8))")
        try await replace(url, with: fixture.baseURL)
        try await replace(app.textFields["connection.username"], with: fixture.username)
        let password = app.secureTextFields["connection.password"]
        try await focus(password)
        password.typeText(fixture.password)
        let ack = app.switches["connection.insecureAck"]
        try await reveal("connection.insecureAck", type: .switch)
        capture("acceptance-insecure-ack-before-native-toggle")
        for _ in 0..<2 {
            if ack.exists && ack.value as? String == "1" { break }
            try await reveal("connection.insecureAck", type: .switch)
            ack.switches.firstMatch.tap()
            let deadline = Date().addingTimeInterval(2)
            repeat {
                if ack.value as? String == "1" { break }
                try await Task.sleep(for: .milliseconds(100))
            } while Date() < deadline
        }
        try await wait("Insecure HTTP acknowledged") { ack.value as? String == "1" }
        let connect = app.buttons["connection.connect"]
        try await reveal("connection.connect")
        try await wait("Acknowledged native connection enabled") { connect.isEnabled && connect.isHittable }
        connect.tap()
        try await wait("Real v2 connection complete", timeout: 35) { app.staticTexts["Global"].firstMatch.isHittable && !app.buttons["connection.connect"].exists }
        try await wait("Automatic v2 detection notice") { app.buttons["connection.v2-notice.dismiss"].isHittable }
        capture("acceptance-automatic-v2-notice")
        app.buttons["connection.v2-notice.dismiss"].tap()
        capture("acceptance-normal-connected")
    }

    private func reconnectSavedServer() async throws {
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Acceptance \(fixture.runID.prefix(8))")).firstMatch
        try await wait("Saved server after unmodified cold launch", timeout: 30) { saved.exists && saved.isHittable }
        XCTAssertFalse(app.textFields["connection.password"].exists)
        saved.tap()
        try await wait("Saved credentials reconnect", timeout: 35) { app.textFields["projects.searchChats"].isHittable }
        try await wait("New saved-server connection lifetime notice") { app.buttons["connection.v2-notice.dismiss"].isHittable }
        app.buttons["connection.v2-notice.dismiss"].tap()
    }

    private func replace(_ element: XCUIElement, with text: String) async throws {
        if element.value as? String == text { return }
        try await focus(element)
        let previous = element.value as? String ?? ""
        if !previous.isEmpty && previous != element.placeholderValue {
            app.typeKey("a", modifierFlags: .command)
        }
        element.typeText(text)
        try await wait("Native field value matches input") { element.value as? String == text }
    }

    private func focus(_ element: XCUIElement) async throws {
        for _ in 0..<2 {
            let cell = try await reveal(element.identifier, type: element.elementType)
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
            let deadline = Date().addingTimeInterval(3)
            repeat {
                if app.keyboards.firstMatch.exists && element.debugDescription.contains("Keyboard Focused") { return }
                try await Task.sleep(for: .milliseconds(150))
            } while Date() < deadline
        }
        throw NSError(domain: "AcceptanceUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native field did not acquire keyboard focus: \(element.identifier)"])
    }

    @discardableResult
    private func reveal(_ identifier: String, type: XCUIElement.ElementType = .button) async throws -> XCUIElement {
        let collections = app.collectionViews.allElementsBoundByIndex
        let anchor = "sessions.create.title"
        let index = try XCTUnwrap(collections.indices.last { index in
            (identifier.hasPrefix("connection.") && collections[index].identifier == "connection.form")
                || collections[index].descendants(matching: type).matching(identifier: identifier).firstMatch.exists
                || collections[index].descendants(matching: .any).matching(identifier: anchor).firstMatch.exists
        }, "No native form contains the requested control")
        let form = app.collectionViews.element(boundBy: index)
        let cell = form.cells.containing(type, identifier: identifier).firstMatch
        for _ in 0..<10 {
            let frame = form.frame
            let navigationBottom = app.navigationBars.allElementsBoundByIndex.filter {
                abs($0.frame.midX - frame.midX) < 2 && abs($0.frame.width - frame.width) < 2 && $0.frame.intersects(frame)
            }.map { $0.frame.maxY }.max() ?? frame.minY
            let top = max(frame.minY, navigationBottom) + 8
            let bottom = min(form.frame.maxY, app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : form.frame.maxY) - 12
            if cell.exists && cell.frame.minY >= top && cell.frame.maxY <= bottom {
                let cellFrame = cell.frame
                try await Task.sleep(for: .milliseconds(200))
                if cell.frame == cellFrame { return cell }
                continue
            }
            guard bottom - top > 100 else { break }
            let down = cell.exists && cell.frame.minY < top
            let start = form.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.width * 0.5, dy: (down ? top + 35 : bottom - 35) - form.frame.minY))
            let end = form.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: form.frame.width * 0.5, dy: (down ? bottom - 35 : top + 35) - form.frame.minY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        throw NSError(domain: "AcceptanceUI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native form control not fully visible: \(identifier)"])
    }

    private func send(_ marker: String) async throws {
        let input = app.textViews["chat.input"]
        try await wait("Composer ready for next real send") { input.exists && input.isHittable }
        input.tap()
        input.typeText(marker)
        let send = app.buttons["chat.send"]
        try await wait("Native send enabled") { send.isEnabled && send.isHittable }
        send.tap()
    }

    private func canonical() async throws -> [[String: Any]] {
        let response = try await fixture.request("/api/session/\(sessionID!)/context")
        return try XCTUnwrap(response["data"] as? [[String: Any]])
    }

    private func answer(_ message: [String: Any]) -> String {
        (message["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
    }

    private func answerElement(_ text: String) -> XCUIElement {
        let transcript = app.collectionViews["chat.scroll"]
        let expected = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectable = transcript.textViews.matching(NSPredicate(format: "value == %@", expected)).firstMatch
        return selectable.exists ? selectable : transcript.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch
    }

    @discardableResult
    private func held(_ marker: String, assistantCount: Int, stage: Int) async throws -> String {
        _ = try await fixture.waitEvent(marker, kind: "held", stage: stage)
        let active = try await fixture.request("/api/session/active")
        let status = (active["data"] as? [String: [String: Any]])?[sessionID!]
        XCTAssertEqual(status?["type"] as? String, "running")
        let text = expectedText(marker, stage: stage)
        try await wait("Visible assistant chunk at provider hold \(stage)", timeout: 20) { self.answerElement(text).exists && self.answerElement(text).isHittable }
        try await evidence(marker, phase: "visible-held-stage-\(stage)", text: text, finished: false)
        capture("acceptance-\(assistantCount)-held-stage-\(stage)")
        return text
    }

    @discardableResult
    private func finish(_ marker: String, assistantCount: Int) async throws -> String {
        _ = try await fixture.request("/control/finish", body: ["marker": marker], provider: true)
        _ = try await fixture.waitEvent(marker, kind: "finished")
        _ = try await fixture.request("/api/session/\(sessionID!)/wait", body: [:])
        let assistants = try await canonical().filter { $0["type"] as? String == "assistant" }
        XCTAssertEqual(assistants.count, assistantCount)
        let latest = try XCTUnwrap(assistants.last)
        let text = answer(latest)
        XCTAssertEqual(text, expectedText(marker, stage: 3))
        XCTAssertEqual(latest["finish"] as? String, "stop")
        XCTAssertNil(latest["error"])
        try await wait("Completed assistant visible") { self.answerElement(text).exists }
        try await evidence(marker, phase: "canonical-complete", text: text, finished: true)
        capture("acceptance-\(assistantCount)-canonical-complete")
        return text
    }

    private func evidence(_ marker: String, phase: String, text: String, finished: Bool) async throws {
        let status = try await fixture.request("/control/status", provider: true)
        let events = try XCTUnwrap(status["events"] as? [[String: Any]]).filter { $0["marker"] as? String == marker }
        XCTAssertEqual(events.filter { $0["kind"] as? String == "request" }.count, 1)
        XCTAssertEqual(events.contains { $0["kind"] as? String == "finished" }, finished)
        XCTAssertFalse(events.contains { ["rejected", "hold_timeout"].contains($0["kind"] as? String ?? "") })
        let attachment = XCTAttachment(string: String(decoding: try JSONSerialization.data(withJSONObject: ["phase": phase, "session_id": sessionID!, "text": text, "provider_events": events], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        attachment.name = "acceptance-\(phase)-runtime-provider-proof"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func wait(_ description: String, timeout: TimeInterval = 15, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let savePassword = app.alerts["Save Password?"].exists ? app.alerts["Save Password?"] : app.sheets["Save Password?"]
            if savePassword.exists && savePassword.buttons["Not Now"].isHittable {
                savePassword.buttons["Not Now"].tap()
            }
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        // Never snapshot a credential editor into diagnostic text.
        if !app.secureTextFields["connection.password"].exists { capture("acceptance-failure-\(description)") }
        throw NSError(domain: "AcceptanceUI", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func capture(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let redacted = app.debugDescription.replacingOccurrences(of: fixture.password, with: "<redacted>")
            .replacingOccurrences(of: fixture.controlToken, with: "<redacted>")
        let hierarchy = XCTAttachment(string: redacted)
        hierarchy.name = "\(name)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}

private final class AcceptanceFixture: NSObject, URLSessionTaskDelegate {
    let runID: String
    let root: URL
    let workspace: URL
    let baseURL: String
    let providerURL: String
    let username: String
    let password: String
    let controlToken: String
    let serverPID: Int
    let supervisorPID: Int

    init(_ value: [String: Any], root: URL) throws {
        self.root = root
        runID = try XCTUnwrap(value["run_id"] as? String)
        workspace = URL(fileURLWithPath: try XCTUnwrap(value["workspace"] as? String)).resolvingSymlinksInPath()
        baseURL = try XCTUnwrap(value["base_url"] as? String)
        providerURL = try XCTUnwrap(value["provider_url"] as? String)
        username = try XCTUnwrap(value["username"] as? String)
        password = try XCTUnwrap(value["password"] as? String)
        controlToken = try XCTUnwrap(value["control_token"] as? String)
        serverPID = try XCTUnwrap(value["server_pid"] as? Int)
        supervisorPID = try XCTUnwrap(value["supervisor_pid"] as? Int)
        super.init()
        guard baseURL == "http://127.0.0.1:14097", providerURL == "http://127.0.0.1:14098",
              value["version"] as? String == "0.0.0-next-17155", value["model"] as? String == "scripted/test-model",
              URL(fileURLWithPath: value["root"] as? String ?? "").resolvingSymlinksInPath() == root,
              workspace == root.appendingPathComponent("workspace"), username == "opencode",
              try String(contentsOf: root.appendingPathComponent(".acceptance-root"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == runID else {
            throw NSError(domain: "AcceptanceUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Acceptance identity rejected"])
        }
    }

    static func load() throws -> AcceptanceFixture {
        guard let path = ProcessInfo.processInfo.environment["OPENCLIENT_ACCEPTANCE_MANIFEST_PATH"] else { throw XCTSkip("Acceptance runner manifest required") }
        let url = URL(fileURLWithPath: path)
        let root = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let parent = URL(fileURLWithPath: "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode").resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == parent, root.lastPathComponent.hasPrefix("acceptance-next17155-"), url.lastPathComponent == "manifest.json" else {
            throw NSError(domain: "AcceptanceUI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unapproved acceptance manifest location"])
        }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0
        guard mode & 0o077 == 0 else { throw NSError(domain: "AcceptanceUI", code: 2) }
        return try AcceptanceFixture(XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]), root: root)
    }

    func verify() async throws {
        let health = try await request("/api/health")
        let location = try await request("/api/location")
        let status = try await request("/control/status", provider: true)
        guard health["version"] as? String == "0.0.0-next-17155", health["pid"] as? Int == serverPID,
              status["run_id"] as? String == runID, status["pid"] as? Int == supervisorPID,
              URL(fileURLWithPath: location["directory"] as? String ?? "").resolvingSymlinksInPath() == workspace,
              (location["project"] as? [String: Any])?["id"] as? String == "global" else { throw NSError(domain: "AcceptanceUI", code: 2) }
    }

    func request(_ path: String, body: [String: Any]? = nil, query: [URLQueryItem] = [], provider: Bool = false) async throws -> [String: Any] {
        guard path.hasPrefix(provider ? "/control/" : "/api/"), !path.contains("..") else { throw NSError(domain: "AcceptanceUI", code: 2) }
        var components = URLComponents(string: (provider ? providerURL : baseURL) + path)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue(provider ? "Bearer \(controlToken)" : "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "AcceptanceUI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Acceptance HTTP request failed: \(path)"])
        }
        if data.isEmpty { return [:] }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func waitEvent(_ marker: String, kind: String, stage: Int? = nil) async throws -> [String: Any] {
        var after = 0
        for _ in 0..<3 {
            let response = try await request("/control/wait", body: ["marker": marker, "kind": kind, "after": after, "timeout": 20], provider: true)
            let events = response["events"] as? [[String: Any]] ?? []
            if let event = events.first(where: { stage == nil || $0["stage"] as? Int == stage }) { return event }
            after = events.last?["seq"] as? Int ?? after
        }
        throw NSError(domain: "AcceptanceUI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Provider event missing: \(kind)"])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
