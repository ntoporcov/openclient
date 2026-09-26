import Foundation
import XCTest
@testable import OpenClient

@MainActor
final class V2LiveFeatureTests: XCTestCase {
    func testPTYLifecycleSocketInputResizeAndCursorReplayAgainstIsolatedBackend() async throws {
        let (client, directory) = try await isolatedContext()
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let title = "V2 Live PTY \(token)"
        let renamedTitle = "\(title) resized"
        let ownedTitles = [title, renamedTitle]

        // Register before POST, including the case where the response is lost after creation.
        addTeardownBlock {
            let terminals = try await client.listV2PTYs(directory: directory)
            for terminal in terminals where ownedTitles.contains(terminal.title) {
                try Self.requireOwned(terminal, titles: ownedTitles, directory: directory)
                try await client.deleteV2PTY(id: terminal.id, directory: directory)
            }
        }

        let events = V2LiveEventRecorder()
        let eventURL = try XCTUnwrap(client.v2EventURL())
        let stream = Task {
            await OpenCodeEventStream.consume(client: client, url: eventURL, onStatus: {
                await events.status($0)
            }, onEvent: {
                await events.receive($0)
            })
        }
        addTeardownBlock { stream.cancel() }
        try await wait("v2 SSE handshake") { await events.isOpen }

        let created = try await client.createV2PTY(title: title, directory: directory)
        try Self.requireOwned(created, titles: [title], directory: directory)
        XCTAssertEqual(created.status, "running")
        XCTAssertGreaterThan(created.pid, 0)
        let listed = try await client.listV2PTYs(directory: directory)
        XCTAssertEqual(listed.filter { $0.id == created.id }.count, 1)
        let fetched = try await client.getV2PTY(id: created.id, directory: directory)
        XCTAssertEqual(fetched, created)
        try await wait("owned pty.created SSE event") {
            await events.contains("pty.created", id: created.id, directory: directory)
        }

        let connection = OpenCodePTYConnection()
        let output = V2LiveSocketRecorder()
        let request = try client.v2PTYConnectRequest(id: created.id, directory: directory, cursor: 0)
        let socket = Task {
            try await connection.run(request: request, initialCursor: 0) { await output.receive($0) }
        }
        addTeardownBlock {
            socket.cancel()
            await connection.disconnect()
        }
        try await wait("real PTY WebSocket handshake and cursor metadata") { await output.isReady }
        let firstMarker = "V2_FIRST_\(token)"
        // The contiguous marker never appears in the input, so shell echo cannot pass the test.
        try await connection.send(Array("printf '\\n%s%s\\n' 'V2_FIRST_' '\(token)'\r".utf8))
        try await wait("executed shell marker") { await output.contains(firstMarker) }

        let beforeResize = try await client.getV2PTY(id: created.id, directory: directory)
        try Self.requireOwned(beforeResize, titles: ownedTitles, directory: directory)
        let updated = try await client.updateV2PTY(
            id: created.id, title: renamedTitle, rows: 37, columns: 101, directory: directory
        )
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.title, renamedTitle)
        let refetched = try await client.getV2PTY(id: created.id, directory: directory)
        XCTAssertEqual(refetched.title, renamedTitle)
        try await wait("owned pty.updated SSE event") {
            await events.contains("pty.updated", id: created.id, directory: directory)
        }
        let sizeMarker = "V2_SIZE_\(token):37 101"
        try await connection.send(Array("printf '\\n%s%s:%s\\n' 'V2_SIZE_' '\(token)' \"$(stty size)\"\r".utf8))
        try await wait("stty confirms actual PTY resize") { await output.contains(sizeMarker) }

        let cursor = await output.cursor
        XCTAssertGreaterThan(cursor, 0)
        let replayMarker = "V2_REPLAY_\(token)"
        try await connection.send(Array("printf '\\n%s%s\\n' 'V2_REPLAY_' '\(token)'\r".utf8))
        try await wait("output after saved cursor") { await output.contains(replayMarker) }
        socket.cancel()
        await connection.disconnect()

        let replay = V2LiveSocketRecorder()
        let replayRequest = try client.v2PTYConnectRequest(id: created.id, directory: directory, cursor: cursor)
        let reopened = Task {
            try await connection.run(request: replayRequest, initialCursor: cursor) { await replay.receive($0) }
        }
        addTeardownBlock {
            reopened.cancel()
            await connection.disconnect()
        }
        try await wait("reopened socket replays bytes after saved cursor") {
            let ready = await replay.isReady
            let containsMarker = await replay.contains(replayMarker)
            return ready && containsMarker
        }
        let replayedFirstMarker = await replay.contains(firstMarker)
        XCTAssertFalse(replayedFirstMarker, "A nonzero cursor must not replay the entire transcript")
        let resumedMarker = "V2_RESUMED_\(token)"
        try await connection.send(Array("printf '\\n%s%s\\n' 'V2_RESUMED_' '\(token)'\r".utf8))
        try await wait("live input after socket reopen") { await replay.contains(resumedMarker) }
        let resumedCursor = await replay.cursor
        XCTAssertGreaterThan(resumedCursor, cursor)

        reopened.cancel()
        await connection.disconnect()
        let beforeDelete = try await client.getV2PTY(id: created.id, directory: directory)
        try Self.requireOwned(beforeDelete, titles: ownedTitles, directory: directory)
        try await client.deleteV2PTY(id: created.id, directory: directory)
        let remaining = try await client.listV2PTYs(directory: directory)
        XCTAssertFalse(remaining.contains { $0.id == created.id })
        try await wait("owned pty.deleted SSE event") {
            await events.contains("pty.deleted", id: created.id, directory: directory)
        }
    }

    func testProviderIntegrationAndPluginLiveReadsAndDirectDecoding() async throws {
        let (client, directory) = try await isolatedContext()
        let providers = try await client.listV2Providers(directory: directory)
        let integrations = try await client.v2Integrations(directory: directory)
        let plugins = try await client.v2Plugins(directory: directory)
        let configuration = try await client.listV2ConfigurationEntries(directory: directory)

        // Independent decoding of actual wire envelopes catches normalization/DTO asymmetry.
        @MainActor
        func read<Value: Decodable & Sendable>(_ path: String, as type: Value.Type) async throws -> Value {
            let request = try client.makeRequest(path: path, method: "GET", queryItems: client.v2LocationQueryItems(directory: directory))
            let (data, response) = try await client.session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            guard http.statusCode == 200 else { throw V2LiveFailure("Read-only discovery returned HTTP \(http.statusCode)") }
            return try JSONDecoder().decode(V2LiveResponse<Value>.self, from: data).data
        }
        @MainActor
        func readBare<Value: Decodable & Sendable>(_ path: String, as type: Value.Type) async throws -> Value {
            let request = try client.makeRequest(path: path, method: "GET", queryItems: client.v2LocationQueryItems(directory: directory))
            let (data, response) = try await client.session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            guard http.statusCode == 200 else { throw V2LiveFailure("Read-only discovery returned HTTP \(http.statusCode)") }
            return try JSONDecoder().decode(Value.self, from: data)
        }
        let rawProviders = try await read("/api/provider", as: [[String: OpenCodeJSONValue]].self)
        let availableIDs = rawProviders.filter {
            if let activation = $0["activation"]?.literalStringValue { return activation != "disabled" }
            return $0["disabled"] != .bool(true)
        }.compactMap { $0["id"]?.literalStringValue }
        XCTAssertEqual(Set(providers.map(\.id)), Set(availableIDs))
        let decodedIntegrations = try await read("/api/integration", as: [OpenCodeV2Integration].self)
        let decodedPlugins = try await read("/api/plugin", as: [OpenCodeV2Plugin].self)
        let decodedConfiguration = try await readBare("/api/config", as: [OpenCodeJSONValue].self)
        XCTAssertEqual(integrations, decodedIntegrations)
        XCTAssertEqual(plugins, decodedPlugins)
        XCTAssertEqual(configuration, decodedConfiguration)
        XCTAssertEqual(Set(integrations.map(\.id)).count, integrations.count)
        // Empty or env-only discovery is valid. Never install credentials or start OAuth here.
    }

    func testEmptyAndEnvironmentOnlyDiscoveryDTOsWithoutLiveCredentials() throws {
        let decoder = JSONDecoder()
        XCTAssertTrue(try decoder.decode([OpenCodeV2Integration].self, from: Data("[]".utf8)).isEmpty)
        let integration = try decoder.decode(OpenCodeV2Integration.self, from: Data(#"{"id":"env-only","name":"Environment Provider","methods":[{"type":"env","names":["EXAMPLE_KEY"]}],"connections":[{"type":"env","name":"EXAMPLE_KEY"}]}"#.utf8))
        XCTAssertEqual(integration.methods, [.env(names: ["EXAMPLE_KEY"])])
        XCTAssertEqual(integration.connections, [.env(name: "EXAMPLE_KEY")])
        XCTAssertFalse(integration.methods[0].isSupported)
        XCTAssertThrowsError(try integration.methods[0].answer(values: [:]))
        let plugin = try decoder.decode(OpenCodeV2Plugin.self, from: Data(#"{"id":"runtime-only","future":true}"#.utf8))
        XCTAssertEqual(plugin.specifier, "runtime-only")
        XCTAssertNil(plugin.state, "Runtime discovery must not invent a successful activation state")
        for status in ["pending", "complete", "failed", "expired"] {
            let dto = try decoder.decode(OpenCodeV2OAuthStatus.self, from: Data("{\"status\":\"\(status)\",\"time\":{\"created\":1000,\"expires\":2000}}".utf8))
            XCTAssertEqual(dto.status.rawValue, status)
            XCTAssertNil(dto.message)
            XCTAssertEqual(dto.time.expiration, Date(timeIntervalSince1970: 2))
        }
    }

    private func isolatedContext() async throws -> (OpenCodeAPIClient, String) {
        let fixture = try OpenCodeV2LiveFixture.load()
        let baseURL = OpenCodeV2LiveFixture.baseURL
        guard let url = URL(string: baseURL), url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw V2LiveFailure("Only the isolated http://127.0.0.1:14097 server is permitted")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: baseURL, username: fixture.username,
                                                      password: fixture.password, apiPreference: .v2), session: session)
        let location = try await client.getV2Location()
        let directory = URL(fileURLWithPath: location.directory).resolvingSymlinksInPath().standardizedFileURL
        let projectDirectory = URL(fileURLWithPath: location.project.directory).resolvingSymlinksInPath().standardizedFileURL
        guard directory == fixture.workspace, projectDirectory == fixture.workspace, fixture.owns(directory) else {
            throw V2LiveFailure("Refusing a server outside the manifest-owned v2 fixture")
        }
        return (client, location.directory)
    }

    nonisolated private static func requireOwned(_ pty: OpenCodePTY, titles: [String], directory: String) throws {
        guard titles.contains(pty.title), pty.cwd == directory,
              pty.id.range(of: #"^pty_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw V2LiveFailure("Refusing to mutate a PTY without exact test ownership and directory")
        }
    }

    private func wait(_ phase: String, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        throw V2LiveFailure("Timed out waiting for \(phase)")
    }
}

private struct V2LiveResponse<Value: Decodable>: Decodable { let data: Value }
private struct V2LiveFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private actor V2LiveSocketRecorder {
    private var connected = false
    private var hasCursor = false
    private var text = ""
    private(set) var cursor = 0
    var isReady: Bool { connected && hasCursor }

    func receive(_ event: OpenCodePTYSocketEvent) {
        switch event {
        case .connected: connected = true
        case .closed: connected = false
        case .cursor(let value): cursor = value; hasCursor = true
        case .output(let value, let next): text += value; cursor = next
        }
    }

    func contains(_ marker: String) -> Bool { text.contains(marker) }
}

private actor V2LiveEventRecorder {
    private(set) var isOpen = false
    private var events: [OpenCodeV2ManagedEvent] = []

    func status(_ status: String) { if status == "stream open event" { isOpen = true } }

    func receive(_ event: OpenCodeServerEvent) {
        if let decoded = OpenCodeEventManager.decodeV2Event(from: event.data), decoded.type.hasPrefix("pty.") {
            events.append(decoded)
        }
    }

    func contains(_ type: String, id: String, directory: String) -> Bool {
        events.contains {
            let data = $0.data.objectValue
            let eventID = data?["id"]?.literalStringValue ?? data?["info"]?.objectValue?["id"]?.literalStringValue
            return $0.type == type && $0.location?.directory == directory && eventID == id
        }
    }
}
