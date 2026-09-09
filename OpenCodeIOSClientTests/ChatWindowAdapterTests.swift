import XCTest
@testable import OpenClient

@MainActor
final class ChatWindowAdapterTests: XCTestCase {
    override func setUp() async throws {
        _ = URLProtocol.registerClass(WindowAdapterURLProtocol.self)
    }

    override func tearDown() async throws {
        WindowAdapterURLProtocol.handler = nil
        URLProtocol.unregisterClass(WindowAdapterURLProtocol.self)
    }

    private func model(_ profile: OpenCodeAPIProfile) -> AppViewModel {
        let model = AppViewModel()
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.config = .init(baseURL: "https://window-adapters.invalid", apiPreference: profile == .v2 ? .v2 : .legacy)
        model.commerceFacade.store.debugEntitlementOverride = .unlocked
        if profile == .v2 { model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true) }
        else { model.connectionStore.applySuccessfulServerConnection(version: "test", healthy: true) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WindowAdapterURLProtocol.self]
        let client = OpenCodeAPIClient(config: model.config, session: URLSession(configuration: configuration))
        model.backendConnection = OpenCodeBackendFactory(client: client, eventManager: model.eventManager)
            .makeConnection(profile: profile, version: "0.0.0-next-17155", healthy: true)
        let root = session("ses_a", directory: "/A")
        model.directoryStoreRegistry.activate("/A").insertV2Session(root)
        model.directoryStore.selectedSession = root
        return model
    }

    private func session(_ id: String, directory: String, workspace: String? = nil, parent: String? = nil) -> OpenCodeSession {
        .init(id: id, title: id, workspaceID: workspace, directory: directory, projectID: nil, parentID: parent)
    }

    private func window(_ model: AppViewModel, session: OpenCodeSession) -> ChatFacade {
        let owner = model.directoryStoreRegistry.store(for: session.directory)
        owner.insertV2Session(session)
        let context = ChatWindowContext(model: model, connection: model.backendConnection!, session: session, owner: owner)
        return ChatFacade(viewModel: model, windowContext: context)
    }

    func testWindowMCPUsesActualOriginDirectoryAndWorkspaceForBothProfiles() async throws {
        for profile: OpenCodeAPIProfile in [.legacy, .v2] {
            let model = model(profile)
            defer { model.disconnect() }
            let chat = window(model, session: session("ses_b", directory: "/B", workspace: "workspace-b"))
            defer { chat.windowContext?.close() }
            model.mcpStore.applyLoadedStatuses(["root": .init(status: "connected", error: nil)])
            let rootSnapshot = model.mcpFacade.snapshot
            let rootOwner = model.directoryStore
            // A mutable saved-server form is not the connection's origin.
            model.config = .init(baseURL: "https://wrong-window-adapters.invalid", apiPreference: .automatic)
            var paths: [String] = []
            WindowAdapterURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.host, "window-adapters.invalid")
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
                let directoryKey = profile == .v2 ? "location[directory]" : "directory"
                let workspaceKey = profile == .v2 ? "location[workspace]" : "workspace"
                XCTAssertEqual(query.first { $0.name == directoryKey }?.value, "/B")
                XCTAssertEqual(query.first { $0.name == workspaceKey }?.value, "workspace-b")
                let path = try XCTUnwrap(request.url?.path)
                paths.append(path)
                if request.httpMethod == "POST" {
                    XCTAssertEqual(path, profile == .v2 ? "/api/mcp/window/connect" : "/mcp/window/connect")
                    return (204, "")
                }
                XCTAssertEqual(path, profile == .v2 ? "/api/mcp" : "/mcp")
                return (200, profile == .v2
                    ? #"{"data":[{"name":"window","status":{"status":"disconnected"}}]}"#
                    : #"{"window":{"status":"disconnected"}}"#)
            }
            await chat.loadMCPStatusIfNeeded()
            await chat.toggleMCPServer(name: "window")
            XCTAssertEqual(paths.count, 3)
            XCTAssertEqual(model.mcpFacade.snapshot, rootSnapshot)
            XCTAssertTrue(model.directoryStore === rootOwner)
            XCTAssertEqual(model.selectedSession?.id, "ses_a")
        }
    }

    func testLateWindowMCPResponseCannotPublishAfterConnectionReplacement() async throws {
        let model = model(.v2)
        defer { model.disconnect() }
        let chat = window(model, session: session("ses_b", directory: "/B"))
        let started = expectation(description: "Window MCP read started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        WindowAdapterURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/mcp")
            started.fulfill()
            for await _ in gate.stream { break }
            return (200, #"{"data":[{"name":"stale","status":{"status":"connected"}}]}"#)
        }
        let read = Task { await chat.loadMCPStatusIfNeeded() }
        await fulfillment(of: [started], timeout: 2)
        model.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: model.config), eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "0.0.0-next-17155", healthy: true)
        gate.continuation.yield(())
        await read.value
        XCTAssertTrue(chat.windowContext!.isClosed)
        XCTAssertTrue(chat.mcpFacade.snapshot.servers.isEmpty)
        XCTAssertTrue(model.mcpFacade.snapshot.servers.isEmpty)
        XCTAssertNil(model.connectionStore.errorMessage)
    }

    func testConfigurationBarrierOrdersEveryFacadeSubmissionPathAcrossWindowsAndRoot() async throws {
        for usesRootFacade in [false, true] {
            for action in ["message", "v2Prompt", "command", "compact"] {
                let model = model(.v2)
                defer { model.disconnect() }
                let target = session("ses_a", directory: "/A")
                let a = window(model, session: target)
                let b = usesRootFacade ? model.chatFacade : window(model, session: target)
                defer { a.windowContext?.close(); b.windowContext?.close() }
                let started = expectation(description: "Model mutation started")
                let prematureSubmission = expectation(description: "No submission before model response")
                prematureSubmission.isInverted = true
                let gate = AsyncStream<Void>.makeStream()
                defer { gate.continuation.finish() }
                var configured = false
                var submissionCount = 0
                let selected = OpenCodeModelReference(providerID: "provider", modelID: "new-model")
                WindowAdapterURLProtocol.handler = { request in
                    let path = try XCTUnwrap(request.url?.path)
                    if path == "/api/session/ses_a/model" {
                        started.fulfill()
                        for await _ in gate.stream { break }
                        configured = true
                        return (204, "")
                    }
                    if ["/api/session/ses_a/prompt", "/api/session/ses_a/command", "/api/session/ses_a/compact"].contains(path) {
                        if !configured { prematureSubmission.fulfill() }
                        XCTAssertTrue(configured, "\(action) bypassed another facade's configuration")
                        XCTAssertEqual(model.modelConfigurationStore.selectedModelReference(for: target.id), selected)
                        submissionCount += 1
                        if path.hasSuffix("/compact") { return (204, "") }
                        let body = try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any]
                        let id = try XCTUnwrap(body?["id"] as? String)
                        return (200, #"{"data":{"id":"\#(id)","sessionID":"ses_a","timeCreated":1,"delivery":"queue"}}"#)
                    }
                    if path.hasSuffix("/wait") { return (204, "") }
                    if path.hasSuffix("/message") { return (200, #"{"data":[],"cursor":{}}"#) }
                    if path.hasSuffix("/permission") || path.hasSuffix("/form") { return (200, #"{"data":[]}"#) }
                    XCTFail("Unexpected adapter request: \(path)")
                    return (500, "{}")
                }
                a.selectModel(selected, for: target)
                let configuration = try XCTUnwrap(a.v2ConfigurationTasks[target.id])
                XCTAssertEqual(b.v2ConfigurationTasks[target.id]?.id, configuration.id)
                await fulfillment(of: [started], timeout: 2)
                let send = Task {
                    switch action {
                    case "v2Prompt":
                        return await b.sendV2TextPrompt("body", in: target, messageID: "msg_submit")
                    case "command":
                        return await b.sendCommand(.init(name: "review", description: nil, agent: nil, model: nil,
                            source: "command", template: "review", subtask: false, hints: []), sessionID: target.id,
                            userVisible: false, meterPrompt: false, messageID: "msg_submit")
                    case "compact":
                        return await b.compactSession(sessionID: target.id, userVisible: false, meterPrompt: false)
                    default:
                        return await b.sendMessage("body", in: target, userVisible: false, messageID: "msg_submit", meterPrompt: false)
                    }
                }
                await fulfillment(of: [prematureSubmission], timeout: 0.1)
                gate.continuation.yield(())
                let accepted = await send.value
                XCTAssertTrue(accepted, "\(action), root=\(usesRootFacade)")
                XCTAssertEqual(submissionCount, 1)
                XCTAssertNil(b.v2ConfigurationTasks[target.id])
            }
        }
    }

    func testClosedWindowConfigurationFailureCannotPublishAnyPresentationError() async throws {
        let model = model(.v2)
        defer { model.disconnect() }
        let target = session("ses_b", directory: "/B")
        let a = window(model, session: target)
        let b = window(model, session: target)
        defer { b.windowContext?.close() }
        model.connectionStore.errorMessage = "root sentinel"
        b.windowContext?.errorMessage = "B sentinel"
        let before = model.modelConfigurationStore.selectedModelReference(for: target.id)
        let started = expectation(description: "Failing configuration started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        WindowAdapterURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_b/model")
            started.fulfill()
            for await _ in gate.stream { break }
            return (500, "configuration failed")
        }
        a.selectModel(.init(providerID: "provider", modelID: "new"), for: target)
        let task = try XCTUnwrap(b.v2ConfigurationTasks[target.id]?.task)
        await fulfillment(of: [started], timeout: 2)
        a.windowContext?.close()
        gate.continuation.yield(())
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.connectionStore.errorMessage, "root sentinel")
        XCTAssertEqual(b.windowContext?.errorMessage, "B sentinel")
        XCTAssertNil(a.windowContext?.errorMessage)
        XCTAssertEqual(model.modelConfigurationStore.selectedModelReference(for: target.id), before)
        XCTAssertNil(b.v2ConfigurationTasks[target.id])
    }

    func testSuccessfulConfigurationRemainsCanonicalAfterOriginWindowCloses() async throws {
        let model = model(.v2)
        defer { model.disconnect() }
        let target = session("ses_b", directory: "/B")
        var a: ChatFacade? = window(model, session: target)
        let b = window(model, session: target)
        defer { b.windowContext?.close() }
        let started = expectation(description: "Configuration started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        WindowAdapterURLProtocol.handler = { _ in
            started.fulfill()
            for await _ in gate.stream { break }
            return (204, "")
        }
        let selected = OpenCodeModelReference(providerID: "provider", modelID: "new")
        a?.selectModel(selected, for: target)
        let task = try XCTUnwrap(b.v2ConfigurationTasks[target.id]?.task)
        await fulfillment(of: [started], timeout: 2)
        a?.windowContext?.close()
        a = nil
        gate.continuation.yield(())
        let accepted = await task.value
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.modelConfigurationStore.selectedModelReference(for: target.id), selected)
        XCTAssertNil(model.connectionStore.errorMessage)
    }

    func testOpenWindowConfigurationErrorStaysLocal() async throws {
        let model = model(.v2)
        defer { model.disconnect() }
        let target = session("ses_b", directory: "/B")
        let a = window(model, session: target)
        let b = window(model, session: target)
        defer { a.windowContext?.close(); b.windowContext?.close() }
        model.connectionStore.errorMessage = "root sentinel"
        WindowAdapterURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_b/model")
            return (500, "configuration failed")
        }
        a.selectModel(.init(providerID: "provider", modelID: "new"), for: target)
        let task = try XCTUnwrap(b.v2ConfigurationTasks[target.id]?.task)
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertNotNil(a.windowContext?.errorMessage)
        XCTAssertNil(b.windowContext?.errorMessage)
        XCTAssertEqual(model.connectionStore.errorMessage, "root sentinel")
    }

    func testConfigurationQueueDoesNotCrossConnectionLifetimes() async throws {
        let model = model(.v2)
        defer { model.disconnect() }
        let target = session("ses_b", directory: "/B")
        let oldWindow = window(model, session: target)
        let started = expectation(description: "Old connection's configuration started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        var calls = 0
        WindowAdapterURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_b/model")
            calls += 1
            if calls == 1 {
                started.fulfill()
                for await _ in gate.stream { break }
                return (500, "old response")
            }
            return (204, "")
        }
        oldWindow.selectModel(.init(providerID: "provider", modelID: "old"), for: target)
        let oldTask = try XCTUnwrap(oldWindow.v2ConfigurationTasks[target.id]?.task)
        await fulfillment(of: [started], timeout: 2)
        model.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: model.config), eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "0.0.0-next-17155", healthy: true)
        let newWindow = window(model, session: target)
        defer { newWindow.windowContext?.close() }
        XCTAssertTrue(oldWindow.windowContext!.isClosed)
        XCTAssertNil(newWindow.v2ConfigurationTasks[target.id])
        let selected = OpenCodeModelReference(providerID: "provider", modelID: "new")
        newWindow.selectModel(selected, for: target)
        let newTask = try XCTUnwrap(newWindow.v2ConfigurationTasks[target.id]?.task)
        let accepted = await newTask.value
        gate.continuation.yield(())
        let oldAccepted = await oldTask.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(oldAccepted)
        XCTAssertEqual(model.modelConfigurationStore.selectedModelReference(for: target.id), selected)
        XCTAssertNil(model.connectionStore.errorMessage)
        XCTAssertNil(newWindow.windowContext?.errorMessage)
    }

    func testUncachedLegacyChildSheetHydratesChildWithoutChangingParentOrRoot() async throws {
        let model = model(.legacy)
        defer { model.disconnect() }
        let parent = window(model, session: session("ses_parent", directory: "/B"))
        defer { parent.windowContext?.close() }
        parent.saveMessageDraft("parent draft", forSessionID: "ses_parent")
        var reads: [String] = []
        WindowAdapterURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            reads.append(path)
            switch path {
            case "/session/ses_child":
                XCTAssertEqual(Self.query(request, "directory"), "/B")
                return (200, #"{"id":"ses_child","directory":"/B","parentID":"ses_parent"}"#)
            case "/session/ses_child/message":
                XCTAssertEqual(Self.query(request, "directory"), "/B")
                return (200, #"[{"info":{"id":"msg_child","sessionID":"ses_child","role":"assistant"},"parts":[{"id":"prt_child","messageID":"msg_child","sessionID":"ses_child","type":"text","text":"child answer"}]}]"#)
            case "/permission", "/question", "/session/ses_child/todo": return (200, "[]")
            default: XCTFail("Parent or root hydration leaked: \(path)"); return (500, "{}")
            }
        }
        XCTAssertNil(model.directoryStoreRegistry.session(matching: "ses_child"))
        let requestedChild = await parent.sessionForPresentation(sessionID: "ses_child")
        let childSession = try XCTUnwrap(requestedChild)
        let child = try XCTUnwrap(parent.childPresentation(for: childSession))
        defer { child.windowContext?.close() }
        await child.hydrateSessionForPresentation(childSession)
        XCTAssertEqual(child.presentationMessages.first?.parts.first?.text, "child answer")
        XCTAssertEqual(child.selectedSession?.id, "ses_child")
        XCTAssertEqual(parent.selectedSession?.id, "ses_parent")
        XCTAssertEqual(parent.composerStore.draftMessage, "parent draft")
        XCTAssertEqual(model.selectedSession?.id, "ses_a")
        XCTAssertTrue(child.directoryStore(forSessionID: "ses_child") === parent.directoryStore(forSessionID: "ses_parent"))
        // The public warm-up path must also honor its requested child rather than silently hydrate the parent.
        await parent.hydrateSessionForPresentation(childSession)
        XCTAssertEqual(reads.filter { $0 == "/session/ses_child/message" }.count, 2)
        parent.windowContext?.close()
        XCTAssertTrue(child.windowContext!.isClosed)
    }

    func testWindowTodoInspectorReadsAndAppliesOnlyItsCanonicalSession() async throws {
        let model = model(.legacy)
        defer { model.disconnect() }
        let chat = window(model, session: session("ses_b", directory: "/B"))
        defer { chat.windowContext?.close() }
        let rootTodos = [OpenCodeTodo(content: "A todo", status: "pending", priority: "high")]
        model.directoryStore.applyTodos(rootTodos, forSessionID: "ses_a")
        model.sessionInteractionStore.todos = rootTodos
        let owner = chat.directoryStore(forSessionID: "ses_b")
        let messageJSON = #"{"info":{"id":"msg_todo_b","sessionID":"ses_b","role":"assistant"},"parts":[{"id":"prt_todo_b","messageID":"msg_todo_b","sessionID":"ses_b","type":"tool","tool":"todowrite"}]}"#
        owner.applyCanonicalMessages([try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: Data(messageJSON.utf8))], forSessionID: "ses_b")
        var paths: [String] = []
        WindowAdapterURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            paths.append(path)
            if path == "/session/ses_b/todo" { return (200, #"[{"content":"B todo","status":"in_progress","priority":"medium"}]"#) }
            XCTAssertEqual(path, "/session/ses_b/message/msg_todo_b")
            return (200, messageJSON)
        }
        let refreshed = try await chat.refreshTodosAndLatestTodoMessage()
        XCTAssertEqual(paths, ["/session/ses_b/todo", "/session/ses_b/message/msg_todo_b"])
        XCTAssertEqual(refreshed.todos.map(\.content), ["B todo"])
        XCTAssertEqual(refreshed.detail?.info.sessionID, "ses_b")
        XCTAssertEqual(chat.todoInspectorSnapshot.todos, refreshed.todos)
        XCTAssertEqual(model.directoryStore.syncState.todosBySessionID["ses_a"], rootTodos)
        XCTAssertEqual(model.sessionInteractionStore.todos, rootTodos)
        XCTAssertEqual(model.selectedSession?.id, "ses_a")
    }

    func testWindowTodoReadCannotApplyAfterClose() async throws {
        let model = model(.legacy)
        defer { model.disconnect() }
        let chat = window(model, session: session("ses_b", directory: "/B"))
        let owner = chat.directoryStore(forSessionID: "ses_b")
        let original = [OpenCodeTodo(content: "original", status: "pending", priority: "low")]
        owner.applyTodos(original, forSessionID: "ses_b")
        let started = expectation(description: "Todo read started")
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        WindowAdapterURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_b/todo")
            started.fulfill()
            for await _ in gate.stream { break }
            return (200, #"[{"content":"stale","status":"completed","priority":"low"}]"#)
        }
        let task = Task { try await chat.refreshTodosAndLatestTodoMessage() }
        await fulfillment(of: [started], timeout: 2)
        chat.windowContext?.close()
        gate.continuation.yield(())
        do { _ = try await task.value; XCTFail("Closed presentation must reject its stale todo read") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(owner.syncState.todosBySessionID["ses_b"], original)
    }

    func testActualAdapterEventSourceRemainsSingleAcrossBorrowedPresentations() async throws {
        for profile: OpenCodeAPIProfile in [.legacy, .v2] {
            let model = model(profile)
            defer { model.disconnect() }
            let opened = expectation(description: "Actual adapter SSE opened")
            var streamRequests = 0
            WindowAdapterURLProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, profile == .v2 ? "/api/event" : "/global/event")
                streamRequests += 1
                if streamRequests == 1 { opened.fulfill() }
                return (200, ": keep-alive\n\n")
            }
            let connection = try model.requireBackendConnection()
            // Retain the root subscription; presentations borrow stores, not this stream.
            let rootStream = connection.eventStream()
            await fulfillment(of: [opened], timeout: 3)
            let a = window(model, session: session("ses_parent", directory: "/B"))
            let b = window(model, session: session("ses_b", directory: "/B"))
            let childSession = session("ses_child", directory: "/B", parent: "ses_parent")
            a.directoryStore(forSessionID: "ses_parent").insertV2Session(childSession)
            let child = try XCTUnwrap(a.childPresentation(for: childSession))
            child.windowContext?.close()
            a.windowContext?.close()
            b.windowContext?.close()
            XCTAssertFalse(connection.isClosed)
            XCTAssertEqual(streamRequests, 1)
            withExtendedLifetime(rootStream) {}
        }
    }

    private static func query(_ request: URLRequest, _ name: String) -> String? {
        request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class WindowAdapterURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: WindowAdapterURLProtocol }
    private let lock = NSLock()
    private var loadingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        ["window-adapters.invalid", "wrong-window-adapters.invalid"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        let task = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                guard !Task.isCancelled else { return }
                let streaming = request.url?.path.hasSuffix("/event") == true
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                if !streaming { delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader) }
            } catch {
                if !Task.isCancelled { delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error) }
            }
        }
        lock.withLock { loadingTask = task }
    }
    override func stopLoading() {
        let task = lock.withLock { let task = loadingTask; loadingTask = nil; return task }
        task?.cancel()
    }
}
