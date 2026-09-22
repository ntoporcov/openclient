import Combine
import Foundation
import XCTest
@testable import OpenClient

final class TerminalFeatureTests: XCTestCase {
    override func tearDown() {
        TerminalURLProtocol.handler = nil
        super.tearDown()
    }

    func testPTYCreatedEventDecodesFromGlobalStream() throws {
        let raw = #"{"directory":"/tmp/project","payload":{"type":"pty.created","properties":{"info":{"id":"pty_1","title":"Terminal 1","command":"/bin/zsh","args":["-l"],"cwd":"/tmp/project","status":"running","pid":42}}}}"#

        guard case let .event(event) = OpenCodeEventManager.decodeManagedEvent(from: raw),
              case let .ptyCreated(terminal) = event.typed else {
            return XCTFail("Expected a typed pty.created event")
        }

        XCTAssertEqual(event.directory, "/tmp/project")
        XCTAssertEqual(terminal.id, "pty_1")
        XCTAssertEqual(terminal.command, "/bin/zsh")
        XCTAssertEqual(terminal.args, ["-l"])
        XCTAssertEqual(terminal.pid, 42)
    }

    func testPTYExitedEventDecodesExitCode() throws {
        let raw = #"{"directory":"/tmp/project","payload":{"type":"pty.exited","properties":{"id":"pty_1","exitCode":130}}}"#

        guard case let .event(event) = OpenCodeEventManager.decodeManagedEvent(from: raw),
              case let .ptyExited(id, exitCode) = event.typed else {
            return XCTFail("Expected a typed pty.exited event")
        }

        XCTAssertEqual(id, "pty_1")
        XCTAssertEqual(exitCode, 130)
    }

    func testBinaryCursorMetadataDecodes() {
        var data = Data([0])
        data.append(Data(#"{"cursor":12345}"#.utf8))

        XCTAssertEqual(OpenCodePTYConnection.decodeCursorMetadata(data), 12_345)
        XCTAssertNil(OpenCodePTYConnection.decodeCursorMetadata(Data(#"{"cursor":12}"#.utf8)))
        for json in [#"{"cursor":-1}"#, #"{"cursor":1.5}"#, #"{"cursor":9007199254740992}"#, "{}", "invalid"] {
            XCTAssertNil(OpenCodePTYConnection.decodeCursorMetadata(Data([0]) + Data(json.utf8)))
        }
    }

    func testSocketFramesCountUTF16AndAuthoritativeReplayCursor() {
        var cursor = 0
        let text = "a\u{1F680}e\u{0301}"
        XCTAssertEqual(OpenCodePTYConnection.decodeMessage(.string(text), cursor: &cursor), .output(text, cursor: 5))
        let metadata = Data([0]) + Data(#"{"cursor":2000000}"#.utf8)
        XCTAssertEqual(OpenCodePTYConnection.decodeMessage(.data(metadata), cursor: &cursor), .cursor(2_000_000))
        XCTAssertEqual(OpenCodePTYConnection.decodeMessage(.string("\r\n"), cursor: &cursor), .output("\r\n", cursor: 2_000_002))
        XCTAssertNil(OpenCodePTYConnection.decodeMessage(.data(Data("not terminal output".utf8)), cursor: &cursor))
        XCTAssertEqual(cursor, 2_000_002)
    }

    func testSocketDelegateReportsConfirmedOpenAndActualCloseCode() async throws {
        let delegate = OpenCodePTYSocketDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: try XCTUnwrap(URL(string: "wss://example.com/api/pty/pty_1/connect")))
        var events = delegate.events.makeAsyncIterator()
        // No task is resumed: drive Foundation's delegate boundary without a live server.
        delegate.urlSession(session, webSocketTask: socket, didOpenWithProtocol: nil)
        guard case .opened? = try await events.next() else { return XCTFail("Expected confirmed handshake") }
        delegate.urlSession(session, webSocketTask: socket, didCloseWith: .policyViolation, reason: nil)
        guard case let .closed(code)? = try await events.next() else { return XCTFail("Expected close") }
        XCTAssertEqual(code, URLSessionWebSocketTask.CloseCode.policyViolation.rawValue)
        let end = try await events.next()
        XCTAssertNil(end)
    }

    func testHandshakeFailureDoesNotEmitConnected() async throws {
        let delegate = OpenCodePTYSocketDelegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: try XCTUnwrap(URL(string: "wss://example.com/api/pty/pty_1/connect")))
        delegate.urlSession(session, task: socket, didCompleteWithError: URLError(.userAuthenticationRequired))
        var events = delegate.events.makeAsyncIterator()
        do {
            _ = try await events.next()
            XCTFail("Handshake failure must throw without reporting connected")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .userAuthenticationRequired)
        }
    }

    func testV2PTYDecodesOptionalExitCode() throws {
        let running = try JSONDecoder().decode(OpenCodePTY.self, from: Data(Self.ptyJSON.utf8))
        XCTAssertNil(running.exitCode)
        let exited = Self.ptyJSON.replacingOccurrences(of: "\"running\"", with: "\"exited\"")
            .replacingOccurrences(of: "\"pid\":42", with: "\"pid\":42,\"exitCode\":130")
        let info = try JSONDecoder().decode(OpenCodePTY.self, from: Data(exited.utf8))
        XCTAssertEqual(info.status, "exited")
        XCTAssertEqual(info.exitCode, 130)
    }

    func testV2ConnectUsesNativeBasicAuthAndNestedLocationAtServerMount() throws {
        var config = OpenCodeServerConfig(baseURL: "https://example.com/relay", username: "user", password: "password")
        let request = try OpenCodeAPIClient(config: config).v2PTYConnectRequest(
            id: "pty_1", directory: "/tmp/a b", workspaceID: "wrk_1", cursor: -1
        )
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/relay/api/pty/pty_1/connect")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["location[directory]": "/tmp/a b", "location[workspace]": "wrk_1", "cursor": "-1"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNzd29yZA==")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory")?.removingPercentEncoding, "/tmp/a b")
        config.baseURL = "http://example.com"
        let plain = try OpenCodeAPIClient(config: config).v2PTYConnectRequest(id: "pty_1", directory: "/tmp/project", cursor: 0)
        XCTAssertEqual(plain.url?.scheme, "ws")
        XCTAssertEqual(plain.url?.path, "/api/pty/pty_1/connect")
    }

    func testV2CRUDRoutesBodiesAndWrappedResponses() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let (requests, continuation) = AsyncStream<TerminalPendingRequest>.makeStream()
        TerminalURLProtocol.handler = { continuation.yield($0) }
        var iterator = requests.makeAsyncIterator()
        let calls = Task {
            defer { continuation.finish() }
            let list = try await client.listV2PTYs(directory: "/tmp/project", workspaceID: "wrk_1")
            XCTAssertEqual(list.map(\.id), ["pty_1"])
            let created = try await client.createV2PTY(title: "New", directory: "/tmp/project", workspaceID: "wrk_1")
            XCTAssertEqual(created.id, "pty_1")
            _ = try await client.getV2PTY(id: "pty_1", directory: "/tmp/project", workspaceID: "wrk_1")
            _ = try await client.updateV2PTY(id: "pty_1", title: "Renamed", rows: 24, columns: 80, directory: "/tmp/project", workspaceID: "wrk_1")
            try await client.deleteV2PTY(id: "pty_1", directory: "/tmp/project", workspaceID: "wrk_1")
        }
        let expected = [("GET", "/api/pty"), ("POST", "/api/pty"), ("GET", "/api/pty/pty_1"), ("PUT", "/api/pty/pty_1"), ("DELETE", "/api/pty/pty_1")]
        for (index, route) in expected.enumerated() {
            let next = await iterator.next()
            let pending = try XCTUnwrap(next)
            XCTAssertEqual(pending.request.httpMethod, route.0)
            XCTAssertEqual(pending.request.url?.path, route.1)
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(pending.request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["location[directory]": "/tmp/project", "location[workspace]": "wrk_1"])
            XCTAssertNotNil(pending.request.value(forHTTPHeaderField: "Authorization"))
            if route.0 == "POST" {
                let body = try requestBody(pending.request)
                XCTAssertEqual(body["title"] as? String, "New")
                XCTAssertEqual(body.count, 1)
            }
            if route.0 == "PUT" {
                let body = try requestBody(pending.request)
                XCTAssertEqual(body["title"] as? String, "Renamed")
                XCTAssertEqual(body["size"] as? [String: Int], ["rows": 24, "cols": 80])
            }
            pending.respond(index == 4 ? "" : Self.wrapped(index == 0 ? "[\(Self.ptyJSON)]" : Self.ptyJSON), status: index == 4 ? 204 : 200)
        }
        try await calls.value
    }

    func testSoftwareTerminalInputSendsTextAndCarriageReturnBytes() {
        XCTAssertEqual(TerminalFacade.softwareInputBytes(for: "pwd"), Array("pwd".utf8))
        XCTAssertEqual(TerminalFacade.softwareInputBytes(for: "\n"), [0x0D])
        XCTAssertEqual(TerminalFacade.softwareInputBytes(for: "\r"), [0x0D])
        XCTAssertEqual(TerminalFacade.softwareInputBytes(for: "\r\n"), [0x0D])
    }

    func testFreshRendererReplaysBeforeReconnectResumesFromLatestCursor() {
        XCTAssertEqual(
            TerminalFacade.connectionCursor(initialCursor: 0, latestCursor: 912, attempt: 0),
            0
        )
        XCTAssertEqual(
            TerminalFacade.connectionCursor(initialCursor: 0, latestCursor: 912, attempt: 1),
            912
        )
    }

    func testPTYConnectRequestUsesWebSocketAuthAndScope() throws {
        var config = OpenCodeServerConfig()
        config.baseURL = "https://example.com/api"
        config.username = "user"
        config.password = "password"
        let request = try OpenCodeAPIClient(config: config).ptyConnectRequest(
            id: "pty_1",
            directory: "/tmp/project",
            workspaceID: "workspace-1",
            cursor: 27
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/api/pty/pty_1/connect")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "directory" })?.value, "/tmp/project")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "workspace" })?.value, "workspace-1")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, "27")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNzd29yZA==")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
    }

    func testCredentialImportLegacyPTYTransportAllowsStableGlobalScope() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let transport = try OpenCodeCredentialImportLegacyPTYTransport(client: client)
        let (requests, continuation) = AsyncStream<TerminalPendingRequest>.makeStream()
        TerminalURLProtocol.handler = { continuation.yield($0) }
        var iterator = requests.makeAsyncIterator()
        let calls = Task {
            let created = try await transport.create(
                request: OpenCodePTYCreateRequest(title: "Credential import"),
                scope: .init()
            )
            XCTAssertEqual(created.id, "pty_1")
            guard case .deleted = try await transport.delete(id: created.id, scope: .init()) else {
                return XCTFail("Expected the global-scope PTY to be deleted")
            }
        }

        let nextCreate = await iterator.next()
        let create = try XCTUnwrap(nextCreate)
        XCTAssertEqual(create.request.httpMethod, "POST")
        XCTAssertEqual(create.request.url?.path, "/pty")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(create.request.url), resolvingAgainstBaseURL: false)?.query)
        XCTAssertNil(create.request.value(forHTTPHeaderField: "x-opencode-directory"))
        create.respond(Self.ptyJSON)

        let nextDelete = await iterator.next()
        let delete = try XCTUnwrap(nextDelete)
        XCTAssertEqual(delete.request.httpMethod, "DELETE")
        XCTAssertEqual(delete.request.url?.path, "/pty/pty_1")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(delete.request.url), resolvingAgainstBaseURL: false)?.query)
        XCTAssertNil(delete.request.value(forHTTPHeaderField: "x-opencode-directory"))
        delete.respond("true")

        try await calls.value
        continuation.finish()
    }

    func testCredentialImportGlobalPTYConnectRequestUsesServerDefaultDirectory() throws {
        var config = OpenCodeServerConfig()
        config.baseURL = "https://example.com/api"
        config.username = "user"
        config.password = "password"

        let request = try OpenCodeAPIClient(config: config).ptyConnectRequest(
            id: "pty_1",
            directory: nil,
            cursor: 0
        )

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.path, "/api/pty/pty_1/connect")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["cursor": "0"])
        XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
    }

    @MainActor
    func testTerminalStoreKeepsIndependentDirectoryTabs() {
        let store = TerminalStore()
        let first = makePTY(id: "pty_1", title: "Terminal 1", directory: "/tmp/one")
        let second = makePTY(id: "pty_2", title: "Terminal 2", directory: "/tmp/one")
        let other = makePTY(id: "pty_3", title: "Terminal 1", directory: "/tmp/two")

        store.activate(directory: "/tmp/one")
        store.append(first, directory: "/tmp/one")
        store.append(second, directory: "/tmp/one")
        XCTAssertEqual(store.activeTerminal?.id, "pty_2")

        XCTAssertTrue(store.remove(id: "pty_2", directory: "/tmp/one"))
        XCTAssertEqual(store.activeTerminal?.id, "pty_1")

        store.activate(directory: "/tmp/two")
        store.append(other, directory: "/tmp/two")
        XCTAssertEqual(store.activeTerminal?.id, "pty_3")
        XCTAssertEqual(store.workspaces["/tmp/one"]?.terminals.map(\.id), ["pty_1"])
    }

    @MainActor
    func testTerminalStoreReconcilesServerListWithoutSelectingATerminal() {
        let store = TerminalStore()
        let first = makePTY(id: "pty_1", title: "Terminal 1", directory: "/tmp/one")
        let second = makePTY(id: "pty_2", title: "Terminal 2", directory: "/tmp/one")

        store.activate(directory: "/tmp/one")
        store.replaceTerminals([first, second], directory: "/tmp/one")

        XCTAssertEqual(store.activeWorkspace.terminals.map(\.id), ["pty_1", "pty_2"])
        XCTAssertNil(store.activeTerminal)

        store.select(id: second.id, directory: "/tmp/one")
        store.updateCursor(42, id: second.id, directory: "/tmp/one")
        store.replaceTerminals([second], directory: "/tmp/one")

        XCTAssertEqual(store.activeTerminal?.id, "pty_2")
        XCTAssertEqual(store.activeTerminal?.cursor, 42)
    }

    @MainActor
    func testWorkspaceIDsAreIndependentAndInactiveRemovalDoesNotDisconnect() {
        let store = TerminalStore()
        let info = makePTY(id: "pty_1", title: "One", directory: "/tmp/project")
        store.activate(directory: "/tmp/project", workspaceID: "wrk_1")
        store.append(info, directory: "/tmp/project", workspaceID: "wrk_1")
        store.activate(directory: "/tmp/project", workspaceID: "wrk_2")
        store.append(info, directory: "/tmp/project", workspaceID: "wrk_2")
        store.setConnectionState(.connected)
        store.setError(URLError(.badServerResponse))
        XCTAssertEqual(store.connectionState, .connected, "A REST failure must not disable a healthy socket")
        XCTAssertFalse(store.remove(id: info.id, directory: "/tmp/project", workspaceID: "wrk_1"))
        XCTAssertEqual(store.connectionState, .connected)
        XCTAssertEqual(store.activeTerminal?.id, info.id)
        XCTAssertTrue(store.workspace(directory: "/tmp/project", workspaceID: "wrk_1").terminals.isEmpty)
        XCTAssertTrue(store.workspace(directory: "/tmp/project").terminals.isEmpty)
    }

    @MainActor
    func testHydrationFiltersExitedTerminalsAndResetPreservesFontSize() throws {
        let store = TerminalStore(fontSize: 17)
        store.activate(directory: "/tmp/project")
        let info = try JSONDecoder().decode(OpenCodePTY.self, from: Data(Self.ptyJSON.replacingOccurrences(of: "running", with: "exited").utf8))
        store.append(info, directory: "/tmp/project")
        store.replaceTerminals([info], directory: "/tmp/project")
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
        XCTAssertNil(store.activeTerminal)
        store.reset()
        XCTAssertNil(store.activeDirectory)
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertEqual(store.fontSize, 17)
    }

    @MainActor
    func testV2EventsRouteLifecycleAndRejectStaleGenerationAndIncompletePayload() throws {
        let store = TerminalStore()
        let facade = TerminalFacade(store: store, clientProvider: { nil }, directoryProvider: { "/tmp/project" },
                                    apiProfileProvider: { .v2 }, generationProvider: { 7 }, workspaceIDProvider: { "wrk_1" })
        let created = try v2Event("pty.created", data: "{\"info\":\(Self.ptyJSON)}", workspaceID: "wrk_1")
        XCTAssertFalse(facade.consumeV2(created, generation: 6))
        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(facade.consumeV2(created, generation: 7))
        XCTAssertEqual(store.activeWorkspace.terminals.map(\.id), ["pty_1"])
        XCTAssertNil(store.activeTerminal)
        facade.selectTerminal(id: "pty_1")
        let updated = Self.ptyJSON.replacingOccurrences(of: "Terminal 1", with: "Renamed")
        XCTAssertTrue(facade.consumeV2(try v2Event("pty.updated", data: "{\"info\":\(updated)}", workspaceID: "wrk_1")))
        XCTAssertEqual(store.activeTerminal?.title, "Renamed")
        XCTAssertFalse(facade.consumeV2(try v2Event("pty.exited", data: #"{"id":"pty_1"}"#, workspaceID: "wrk_1")))
        XCTAssertTrue(facade.consumeV2(try v2Event("pty.exited", data: #"{"id":"pty_1","exitCode":0}"#, workspaceID: "wrk_1")))
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
        XCTAssertTrue(facade.consumeV2(created))
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty, "A delayed create must not resurrect an exited PTY")
        facade.resetForConnectionChange()
        XCTAssertTrue(facade.consumeV2(created))
        XCTAssertTrue(facade.consumeV2(try v2Event("pty.deleted", data: #"{"id":"pty_1"}"#, workspaceID: "wrk_1")))
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
    }

    @MainActor
    func testLateInventoryCannotOverwriteNewScopeOrFinishItsLoading() async throws {
        for change in ["directory", "workspace", "generation", "profile", "server", "reset", "error"] {
            var client = makeClient()
            let session = client.session
            defer { session.invalidateAndCancel() }
            var directory = "/tmp/project"
            var workspace: String? = nil
            var generation: UInt = 0
            var profile: OpenCodeAPIProfile = .v2
            let store = TerminalStore()
            let facade = TerminalFacade(store: store, clientProvider: { client }, directoryProvider: { directory },
                                        apiProfileProvider: { profile }, generationProvider: { generation }, workspaceIDProvider: { workspace })
            let (requests, continuation) = AsyncStream<TerminalPendingRequest>.makeStream()
            TerminalURLProtocol.handler = { continuation.yield($0) }
            var iterator = requests.makeAsyncIterator()
            let oldLoad = Task { await facade.refreshTerminals() }
            let oldRequest = await iterator.next()
            let old = try XCTUnwrap(oldRequest)
            switch change {
            case "directory": directory = "/tmp/other"
            case "workspace": workspace = "wrk_other"
            case "generation": generation += 1
            case "profile": profile = .legacy
            case "server": client = OpenCodeAPIClient(config: .init(baseURL: "https://other.example.com"), session: session)
            default: facade.resetForConnectionChange()
            }
            let newLoad = Task { await facade.refreshTerminals() }
            let newRequest = await iterator.next()
            let new = try XCTUnwrap(newRequest)
            old.respond(Self.wrapped("[\(Self.ptyJSON)]"), status: change == "error" ? 500 : 200)
            await oldLoad.value
            XCTAssertTrue(store.isLoadingTerminals, change)
            XCTAssertTrue(store.activeWorkspace.terminals.isEmpty, change)
            XCTAssertNil(store.errorMessage, change)
            let info = Self.ptyJSON.replacingOccurrences(of: "pty_1", with: "pty_new")
            new.respond(profile == .v2 ? Self.wrapped("[\(info)]") : "[\(info)]")
            await newLoad.value
            XCTAssertFalse(store.isLoadingTerminals, change)
            XCTAssertEqual(store.activeWorkspace.terminals.map(\.id), ["pty_new"], change)
            facade.resetForConnectionChange()
        }
    }

    @MainActor
    func testReconnectInvalidatesInFlightInventoryAndReconcilesMissedExits() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let store = TerminalStore()
        let facade = TerminalFacade(store: store, clientProvider: { client }, directoryProvider: { "/tmp/project" }, apiProfileProvider: { .v2 })
        let (requests, continuation) = AsyncStream<TerminalPendingRequest>.makeStream()
        TerminalURLProtocol.handler = { continuation.yield($0) }
        var iterator = requests.makeAsyncIterator()
        let load = Task { await facade.refreshTerminals() }
        let firstRequest = await iterator.next()
        let first = try XCTUnwrap(firstRequest)
        await facade.refreshAfterEventReconnect()
        first.respond(Self.wrapped("[\(Self.ptyJSON)]"))
        let secondRequest = await iterator.next()
        let second = try XCTUnwrap(secondRequest)
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
        second.respond(Self.wrapped("[\(Self.ptyJSON.replacingOccurrences(of: "running", with: "exited"))]"))
        await load.value
        XCTAssertFalse(store.isLoadingTerminals)
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
    }

    @MainActor
    func testExitedPTYAfterAbnormalCloseIsRemovedWithoutReplacementOrReconnect() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let store = TerminalStore()
        store.activate(directory: "/tmp/project")
        store.append(makePTY(id: "pty_1", title: "One", directory: "/tmp/project"), directory: "/tmp/project")
        let removed = expectation(description: "Exited PTY removed")
        let observation = store.$workspaces.dropFirst().sink { workspaces in
            if workspaces["/tmp/project"]?.terminals.isEmpty == true { removed.fulfill() }
        }
        let inspected = expectation(description: "PTY inspected once after socket failure")
        inspected.assertForOverFulfill = true
        TerminalURLProtocol.handler = { pending in
            XCTAssertEqual(pending.request.httpMethod, "GET")
            XCTAssertEqual(pending.request.url?.path, "/api/pty/pty_1")
            pending.respond(Self.wrapped(Self.ptyJSON.replacingOccurrences(of: "running", with: "exited")))
            inspected.fulfill()
        }
        let opened = expectation(description: "One socket attempt")
        opened.assertForOverFulfill = true
        let facade = TerminalFacade(
            store: store, clientProvider: { client }, directoryProvider: { "/tmp/project" }, apiProfileProvider: { .v2 },
            connectionRunner: { _, request, cursor, onEvent in
                XCTAssertEqual(request.url?.path, "/api/pty/pty_1/connect")
                XCTAssertEqual(cursor, 0)
                opened.fulfill()
                await onEvent(.connected)
                await onEvent(.closed(code: 4404))
                throw URLError(.networkConnectionLost)
            }
        )
        facade.attachRenderer(rendererID: UUID(), terminalID: "pty_1", output: { _ in }, input: rendererInput())
        await fulfillment(of: [opened, inspected, removed], timeout: 2)
        XCTAssertTrue(store.activeWorkspace.terminals.isEmpty)
        XCTAssertEqual(store.connectionState, .disconnected)
        observation.cancel()
        facade.resetForConnectionChange()
    }

    @MainActor
    func testNormalSocketCloseDoesNotInspectOrReconnectPTY() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        TerminalURLProtocol.handler = { pending in
            XCTFail("Normal socket closure must not issue \(pending.request.httpMethod ?? "") \(pending.request.url?.path ?? "")")
            pending.respond("", status: 500)
        }
        let store = TerminalStore()
        store.activate(directory: "/tmp/project")
        store.append(makePTY(id: "pty_1", title: "One", directory: "/tmp/project"), directory: "/tmp/project")
        let closed = expectation(description: "Normal close delivered")
        closed.assertForOverFulfill = true
        let facade = TerminalFacade(
            store: store, clientProvider: { client }, directoryProvider: { "/tmp/project" }, apiProfileProvider: { .v2 },
            connectionRunner: { _, _, _, onEvent in
                await onEvent(.connected)
                await onEvent(.closed(code: 1000))
                closed.fulfill()
            }
        )
        facade.attachRenderer(rendererID: UUID(), terminalID: "pty_1", output: { _ in }, input: rendererInput())
        await fulfillment(of: [closed], timeout: 2)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertEqual(store.activeTerminal?.id, "pty_1", "The inventory event, not socket closure, owns tab removal")
        facade.resetForConnectionChange()
    }

    @MainActor
    func testInactiveWorkspaceExitKeepsCurrentRendererAttached() throws {
        let store = TerminalStore()
        let info = makePTY(id: "pty_1", title: "One", directory: "/tmp/project")
        store.append(info, directory: "/tmp/project", workspaceID: "wrk_other")
        store.activate(directory: "/tmp/project", workspaceID: "wrk_current")
        store.append(info, directory: "/tmp/project", workspaceID: "wrk_current")
        let facade = TerminalFacade(store: store, clientProvider: { nil }, directoryProvider: { "/tmp/project" },
                                    apiProfileProvider: { .v2 }, workspaceIDProvider: { "wrk_current" })
        var pastes = 0
        facade.attachRenderer(rendererID: UUID(), terminalID: "pty_1", output: { _ in }, input: rendererInput(paste: { _ in pastes += 1 }))
        store.setConnectionState(.connected)
        XCTAssertTrue(facade.consumeV2(try v2Event("pty.exited", data: #"{"id":"pty_1","exitCode":0}"#, workspaceID: "wrk_other")))
        facade.pasteText("still attached")
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(store.connectionState, .connected)
        facade.resetForConnectionChange()
        facade.pasteText("detached")
        XCTAssertEqual(pastes, 1)
    }

    @MainActor
    func testReplacingRendererReplaysAndRejectsOldOutputAndDetach() async throws {
        typealias Handler = @Sendable (OpenCodePTYSocketEvent) async -> Void
        let (handlers, continuation) = AsyncStream<Handler>.makeStream()
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let store = TerminalStore()
        store.activate(directory: "/tmp/project")
        store.append(makePTY(id: "pty_1", title: "One", directory: "/tmp/project"), directory: "/tmp/project")
        let facade = TerminalFacade(
            store: store, clientProvider: { client }, directoryProvider: { "/tmp/project" }, apiProfileProvider: { .v2 },
            connectionRunner: { _, _, cursor, onEvent in
                XCTAssertEqual(cursor, 0, "Each new renderer needs replay, not the previous surface's cursor")
                continuation.yield(onEvent)
            }
        )
        let firstID = UUID()
        let secondID = UUID()
        var firstOutput: [String] = []
        var secondOutput: [String] = []
        var iterator = handlers.makeAsyncIterator()
        facade.attachRenderer(rendererID: firstID, terminalID: "pty_1", output: { firstOutput.append($0) }, input: rendererInput())
        let firstHandler = await iterator.next()
        let first = try XCTUnwrap(firstHandler)
        await first(.output("first", cursor: 5))
        facade.attachRenderer(rendererID: secondID, terminalID: "pty_1", output: { secondOutput.append($0) }, input: rendererInput())
        let secondHandler = await iterator.next()
        let second = try XCTUnwrap(secondHandler)
        await first(.output("stale", cursor: 999))
        facade.detachRenderer(terminalID: "pty_1", rendererID: firstID)
        await second(.output("replayed", cursor: 8))
        XCTAssertEqual(firstOutput, ["first"])
        XCTAssertEqual(secondOutput, ["replayed"])
        XCTAssertEqual(store.activeTerminal?.cursor, 8)
        facade.resetForConnectionChange()
        await second(.output("after reset", cursor: 1000))
        XCTAssertEqual(secondOutput, ["replayed"])
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    @MainActor
    func testResizeBackToPreviousDimensionsStillSendsAfterCanceledPUT() async throws {
        let client = makeClient()
        defer { client.session.invalidateAndCancel() }
        let store = TerminalStore()
        store.activate(directory: "/tmp/project")
        store.append(makePTY(id: "pty_1", title: "One", directory: "/tmp/project"), directory: "/tmp/project")
        store.updateSize(rows: 24, columns: 80, id: "pty_1", directory: "/tmp/project")
        let facade = TerminalFacade(store: store, clientProvider: { client }, directoryProvider: { "/tmp/project" }, apiProfileProvider: { .v2 })
        let (requests, continuation) = AsyncStream<TerminalPendingRequest>.makeStream()
        TerminalURLProtocol.handler = { continuation.yield($0) }
        var iterator = requests.makeAsyncIterator()
        facade.resize(terminalID: "pty_1", rows: 24, columns: 90)
        let firstRequest = await iterator.next()
        let first = try XCTUnwrap(firstRequest)
        XCTAssertEqual(try requestBody(first.request)["size"] as? [String: Int], ["rows": 24, "cols": 90])
        XCTAssertNil(store.activeTerminal?.columns)
        facade.resize(terminalID: "pty_1", rows: 24, columns: 80)
        let secondRequest = await iterator.next()
        let second = try XCTUnwrap(secondRequest)
        XCTAssertEqual(try requestBody(second.request)["size"] as? [String: Int], ["rows": 24, "cols": 80])
        let acknowledged = expectation(description: "Latest resize acknowledged")
        let observation = store.$workspaces.sink { workspaces in
            if workspaces["/tmp/project"]?.terminals.first?.columns == 80 { acknowledged.fulfill() }
        }
        second.respond(Self.wrapped(Self.ptyJSON))
        await fulfillment(of: [acknowledged], timeout: 2)
        XCTAssertEqual(store.activeTerminal?.columns, 80)
        observation.cancel()
        facade.resetForConnectionChange()
    }

    @MainActor
    func testTerminalStorePersistsSharedFontSize() throws {
        let suiteName = "TerminalFeatureTests.fontSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialStore = TerminalStore(defaults: defaults)
        XCTAssertEqual(initialStore.fontSize, 12)

        initialStore.setFontSize(9)
        let restoredStore = TerminalStore(defaults: defaults)

        XCTAssertEqual(restoredStore.fontSize, 9)
    }

    @MainActor
    func testTerminalFacadeRoutesPasteTextToActiveRenderer() {
        let directory = "/tmp/one"
        let terminal = makePTY(id: "pty_1", title: "Terminal 1", directory: directory)
        let store = TerminalStore()
        store.activate(directory: directory)
        store.append(terminal, directory: directory)
        let facade = TerminalFacade(
            store: store,
            clientProvider: { nil },
            directoryProvider: { directory }
        )
        var pastedText: String?
        var focusCount = 0

        facade.attachRenderer(
            rendererID: UUID(),
            terminalID: terminal.id,
            output: { _ in },
            input: TerminalFacade.RendererInput(
                insertText: { _ in },
                pasteText: { pastedText = $0 },
                setControlModifier: { _ in },
                setAltModifier: { _ in },
                sendSpecialKey: { _ in },
                focus: { focusCount += 1 },
                dismissKeyboard: {}
            )
        )

        facade.pasteText("printf 'hello'")

        XCTAssertEqual(pastedText, "printf 'hello'")
        XCTAssertEqual(focusCount, 1)
    }

    private static let ptyJSON = #"{"id":"pty_1","title":"Terminal 1","command":"/bin/zsh","args":["-l"],"cwd":"/tmp/project","status":"running","pid":42}"#

    private static func wrapped(_ data: String) -> String {
        #"{"location":{"directory":"/tmp/project","project":{"id":"project","directory":"/tmp/project","canonical":"/tmp/project"}},"data":\#(data)}"#
    }

    private func makeClient() -> OpenCodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TerminalURLProtocol.self]
        return OpenCodeAPIClient(config: .init(baseURL: "https://example.com", username: "user", password: "password"), session: URLSession(configuration: configuration))
    }

    private func v2Event(_ type: String, data: String, workspaceID: String? = nil) throws -> OpenCodeV2ManagedEvent {
        let workspace = workspaceID.map { ",\"workspaceID\":\"\($0)\"" } ?? ""
        let raw = #"{"id":"evt_1","created":123,"type":"\#(type)","location":{"directory":"/tmp/project"\#(workspace)},"data":\#(data)}"#
        return try JSONDecoder().decode(OpenCodeV2ManagedEvent.self, from: Data(raw.utf8))
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func rendererInput(paste: @escaping (String) -> Void = { _ in }) -> TerminalFacade.RendererInput {
        TerminalFacade.RendererInput(insertText: { _ in }, pasteText: paste, setControlModifier: { _ in },
                                     setAltModifier: { _ in }, sendSpecialKey: { _ in }, focus: {}, dismissKeyboard: {})
    }

    private func makePTY(id: String, title: String, directory: String) -> OpenCodePTY {
        OpenCodePTY(
            id: id,
            title: title,
            command: "/bin/zsh",
            args: ["-l"],
            cwd: directory,
            status: "running",
            pid: 42
        )
    }
}

private struct TerminalPendingRequest: Sendable {
    let request: URLRequest
    let deliver: @Sendable (String, Int) -> Void

    func respond(_ body: String, status: Int = 200) {
        deliver(body, status)
    }
}

private final class TerminalURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (TerminalPendingRequest) -> Void)?

    // Immutable bridge to Foundation callbacks, completed once by the scripted response.
    private struct Delivery: @unchecked Sendable {
        let loader: TerminalURLProtocol

        func respond(_ body: String, status: Int, url: URL) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocol(loader, didLoad: Data(body.utf8))
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Self.handler?(TerminalPendingRequest(request: request, deliver: { body, status in
            delivery.respond(body, status: status, url: request.url!)
        }))
    }
    override func stopLoading() {}
}
