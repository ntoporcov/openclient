import XCTest
import UIKit
import WebKit
@testable import OpenClient

final class OpenClientBridgeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OpenClientImageMockURLProtocol.requestHandler = nil
        OpenClientNotificationMockURLProtocol.requestHandler = nil
    }

    override func tearDown() {
        OpenClientImageMockURLProtocol.requestHandler = nil
        OpenClientNotificationMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testDecodesToolRequest() throws {
        let data = Data(
            """
            {
              "protocol": 1,
              "type": "request",
              "id": "request-1",
              "method": "list_tools",
              "params": { "sessionID": "session-1" }
            }
            """.utf8
        )

        let message = try JSONDecoder().decode(OpenClientBridgeServerMessage.self, from: data)
        XCTAssertEqual(
            message,
            .request(
                OpenClientBridgeRequest(
                    id: "request-1",
                    method: .listTools,
                    params: .object(["sessionID": .string("session-1")])
                )
            )
        )
    }

    func testDiscoveryBuildsEntirePortRangeFromServerHost() {
        let config = OpenCodeServerConfig(baseURL: "http://100.64.0.10:4097")
        let endpoints = OpenClientBridgeEndpointDiscovery.candidateEndpoints(config: config)

        XCTAssertEqual(endpoints.count, 21)
        XCTAssertEqual(endpoints.first?.healthURL.absoluteString, "http://100.64.0.10:4070/openclient/v1/health")
        XCTAssertEqual(endpoints.last?.webSocketURL.absoluteString, "ws://100.64.0.10:4090/openclient/v1/ws")
        XCTAssertEqual(endpoints.first?.openCodePort, 4097)
    }

    func testDiscoveryRejectsHealthyBridgeForDifferentOpenCodePort() {
        let candidate = OpenClientBridgeEndpointDiscovery.candidateEndpoints(
            config: OpenCodeServerConfig(baseURL: "http://100.64.0.10:4097")
        )[0]
        let health = OpenClientBridgeHealth(
            service: "openclient-plugin", protocol: 1, port: candidate.port, openCodePort: 4096
        )

        XCTAssertFalse(OpenClientBridgeEndpointDiscovery.matches(candidate: candidate, health: health))
        XCTAssertTrue(OpenClientBridgeEndpointDiscovery.matches(
            candidate: candidate,
            health: OpenClientBridgeHealth(service: "openclient-plugin", protocol: 1,
                                           port: candidate.port, openCodePort: 4097)
        ))
    }

    func testBridgeHealthDecodesOldAndNotificationAdvertisementsWithoutBreakingBridge() throws {
        let old = try JSONDecoder().decode(
            OpenClientBridgeHealth.self,
            from: Data(#"{"service":"openclient-plugin","protocol":1,"port":4070,"openCodePort":4096}"#.utf8)
        )
        XCTAssertNil(old.notifications)
        XCTAssertEqual(OpenClientBridgeNotificationsCapability(advertisement: old.notifications), .missing)

        let ready = try JSONDecoder().decode(
            OpenClientBridgeHealth.self,
            from: Data(#"{"service":"openclient-plugin","protocol":1,"port":4070,"openCodePort":4096,"notifications":{"version":1,"state":"ready","publicOrigin":"https://notify.example.com","pairing":{"version":1,"cliPath":"/cache/node_modules/@openclient-ios/opencode-plugin/dist/notifications/src/cli.mjs","dataDir":"/state/notify"}}}"#.utf8)
        )
        XCTAssertEqual(
            OpenClientBridgeNotificationsCapability(advertisement: ready.notifications),
            .ready(publicOrigin: "https://notify.example.com")
        )
        XCTAssertTrue(try XCTUnwrap(ready.notifications?.pairing).isTrustedShape)

        let unknownState = try JSONDecoder().decode(
            OpenClientBridgeHealth.self,
            from: Data(#"{"service":"openclient-plugin","protocol":1,"port":4070,"openCodePort":4096,"notifications":{"version":1,"state":"future"}}"#.utf8)
        )
        XCTAssertEqual(OpenClientBridgeNotificationsCapability(advertisement: unknownState.notifications), .unavailable)

        let malformedCapability = try JSONDecoder().decode(
            OpenClientBridgeHealth.self,
            from: Data(#"{"service":"openclient-plugin","protocol":1,"port":4070,"openCodePort":4096,"notifications":"invalid"}"#.utf8)
        )
        XCTAssertNil(malformedCapability.notifications)
    }

    func testNotificationPairingLauncherRejectsArbitraryCommandsAndQuotesPaths() {
        let trusted = OpenClientNotificationPairingLauncher(
            version: 1,
            cliPath: "/tmp/plugin's files/dist/notifications/src/cli.mjs",
            dataDir: "/tmp/notify data's"
        )
        XCTAssertTrue(trusted.isTrustedShape)
        XCTAssertEqual(
            OpenClientNotificationPairingRunner.command(for: trusted),
            "'/tmp/plugin'\\''s files/dist/notifications/src/cli.mjs' pair --data-dir '/tmp/notify data'\\''s'\r"
        )
        XCTAssertFalse(OpenClientNotificationPairingLauncher(version: 1, cliPath: "/bin/sh", dataDir: "/tmp").isTrustedShape)
        XCTAssertFalse(OpenClientNotificationPairingLauncher(version: 1, cliPath: "/tmp/dist/notifications/src/cli.mjs", dataDir: "relative").isTrustedShape)
    }

    @MainActor
    func testNotificationPairingRunnerCleansUpAfterPairingCodeWithoutWaitingForSocketTask() async throws {
        var deleted = false
        OpenClientNotificationMockURLProtocol.requestHandler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/pty"):
                return Self.notificationResponse(request: request, body: #"{"id":"pty-1","title":"OC Notify Setup","command":"","args":[],"cwd":"/tmp","status":"running","pid":1}"#)
            case ("DELETE", "/pty/pty-1"):
                deleted = true
                return Self.notificationResponse(request: request, status: 204, body: "")
            default:
                XCTFail("Unexpected pairing request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.notificationResponse(request: request, status: 500, body: "")
            }
        }
        let configuration = Self.notificationSessionConfiguration()
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://server.example:4096"),
            session: URLSession(configuration: configuration)
        )
        let launcher = OpenClientNotificationPairingLauncher(
            version: 1,
            cliPath: "/tmp/node_modules/@openclient-ios/opencode-plugin/dist/notifications/src/cli.mjs",
            dataDir: "/tmp/notify"
        )
        let runner = OpenClientNotificationPairingRunner(
            clientProvider: { client },
            directoryProvider: { "/tmp" },
            connectionRunner: { _, _, _, onEvent in
                await onEvent(.output("Pairing code (valid 10 minutes, one use): 0123456789", cursor: 1))
                try await Task.sleep(for: .seconds(60))
            },
            timeout: .seconds(2)
        )

        let code = try await runner.createPairingCode(launcher: launcher)

        XCTAssertEqual(code, "0123456789")
        XCTAssertTrue(deleted)
    }

    @MainActor
    func testNotificationPairingRunnerTimeoutCancelsSocketTaskAndCleansUp() async throws {
        var deleted = false
        OpenClientNotificationMockURLProtocol.requestHandler = { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/pty"):
                return Self.notificationResponse(request: request, body: #"{"id":"pty-1","title":"OC Notify Setup","command":"","args":[],"cwd":"/tmp","status":"running","pid":1}"#)
            case ("DELETE", "/pty/pty-1"):
                deleted = true
                return Self.notificationResponse(request: request, status: 204, body: "")
            default:
                XCTFail("Unexpected pairing request: \(request.httpMethod ?? "nil") \(request.url?.path ?? "nil")")
                return Self.notificationResponse(request: request, status: 500, body: "")
            }
        }
        let configuration = Self.notificationSessionConfiguration()
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://server.example:4096"),
            session: URLSession(configuration: configuration)
        )
        let launcher = OpenClientNotificationPairingLauncher(
            version: 1,
            cliPath: "/tmp/node_modules/@openclient-ios/opencode-plugin/dist/notifications/src/cli.mjs",
            dataDir: "/tmp/notify"
        )
        let runner = OpenClientNotificationPairingRunner(
            clientProvider: { client },
            directoryProvider: { "/tmp" },
            connectionRunner: { _, _, _, _ in
                try await Task.sleep(for: .seconds(60))
            },
            timeout: .milliseconds(50)
        )
        let clock = ContinuousClock()
        let started = clock.now

        do {
            _ = try await runner.createPairingCode(launcher: launcher)
            XCTFail("Expected pairing timeout")
        } catch let error as OpenClientNotificationSetupError {
            XCTAssertEqual(error, .pairingTimedOut)
        }

        XCTAssertLessThan(clock.now - started, .seconds(1))
        XCTAssertTrue(deleted)
    }

    @MainActor
    func testNotificationSetupPairsThroughNativeRunnerAndHandsBothCodesToPWA() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Pairing.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let pairing = RecordingNotificationPairingRunner()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: PassiveOpenClientBridgeConnection(),
            notificationSetupClient: RecordingNotificationSetupRequester(),
            notificationPairingRunner: pairing,
            notificationContextProvider: { try? Self.notificationContext() }
        )
        store.apply(.connected(Self.notificationEndpoint()))

        await coordinator.setupNotifications()

        guard case .ready(let setup) = store.notificationSetupPhase else {
            return XCTFail("Expected paired setup")
        }
        XCTAssertEqual(setup.url.absoluteString, "https://notify.example.com/#setup=ABCDEF1234&pair=0123456789")
        XCTAssertEqual(pairing.launcher?.dataDir, "/state/notify")
    }

    func testNotificationAdvertisementsFailClosedWithoutDisablingBridge() throws {
        let invalidOrigins = [
            "http://notify.example.com",
            "https://user:password@notify.example.com",
            "https://notify.example.com/path",
            "https://notify.example.com?query=1",
            "https://notify.example.com/#fragment",
        ]
        for origin in invalidOrigins {
            let advertisement = OpenClientBridgeNotificationsAdvertisement(
                version: 1,
                state: .ready,
                publicOrigin: origin
            )
            XCTAssertEqual(OpenClientBridgeNotificationsCapability(advertisement: advertisement), .unavailable)
        }
        XCTAssertEqual(
            OpenClientBridgeNotificationsCapability(
                advertisement: .init(version: 2, state: .ready, publicOrigin: "https://notify.example.com")
            ),
            .unsupportedVersion
        )
    }

    func testDiscoveryPreservesNotificationMetadataOnEndpoint() {
        let candidate = Self.bridgeEndpoint()
        let endpoint = OpenClientBridgeEndpointDiscovery.endpoint(
            candidate: candidate,
            health: OpenClientBridgeHealth(
                service: "openclient-plugin",
                protocol: 1,
                port: 4070,
                openCodePort: 4096,
                notifications: .init(
                    version: 1,
                    state: .ready,
                    publicOrigin: "https://notify.example.com",
                    pairing: .init(
                        version: 1,
                        cliPath: "/cache/node_modules/@openclient-ios/opencode-plugin/dist/notifications/src/cli.mjs",
                        dataDir: "/state/notify"
                    )
                )
            )
        )
        XCTAssertEqual(endpoint.notifications, .ready(publicOrigin: "https://notify.example.com"))
        XCTAssertEqual(endpoint.notificationPairingLauncher?.dataDir, "/state/notify")
    }

    func testNotificationSetupClientSendsOnlyAllowlistedConnectionFields() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))
        OpenClientNotificationMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://100.64.0.10:4070/openclient/v1/notifications/setup")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let body = try Self.notificationRequestBody(request)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object, [
                "baseURL": "http://server.example:4096/",
                "username": "",
                "profile": "legacy",
            ])
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("password"))
            return Self.notificationResponse(
                request: request,
                body: #"{"url":"https://notify.example.com/#setup=ABCDEF1234","code":"ABCDEF1234","expiresAt":"\#(expiry)"}"#
            )
        }
        let config = OpenCodeServerConfig(
            baseURL: "  http://server.example:4096/  ",
            username: "   ",
            password: "secret"
        )
        let context = try OpenClientNotificationSetupContext(
            connectionID: "connection-1",
            config: config,
            profile: .legacy,
            savedServerID: config.recentServerID
        )
        let setup = try await OpenClientNotificationSetupClient(
            sessionConfiguration: Self.notificationSessionConfiguration(),
            now: { now }
        ).createSetup(endpoint: Self.notificationEndpoint(), context: context)
        XCTAssertEqual(setup.code, "ABCDEF1234")
    }

    func testNotificationSetupContextRejectsCredentialAndURLComponentSmuggling() {
        let invalidBaseURLs = [
            "http://user:password@server.example:4096",
            "http://server.example:4096?directory=/tmp",
            "http://server.example:4096/#fragment",
        ]
        for baseURL in invalidBaseURLs {
            let config = OpenCodeServerConfig(baseURL: baseURL, username: "opencode")
            XCTAssertThrowsError(
                try OpenClientNotificationSetupContext(
                    connectionID: "connection-1",
                    config: config,
                    profile: .legacy,
                    savedServerID: config.recentServerID
                )
            ) { error in
                XCTAssertEqual(error as? OpenClientNotificationSetupError, .invalidConnection)
            }
        }
    }

    func testNotificationSetupContextEnforcesSavedIdentityLengthAndControlBounds() {
        let validConfig = OpenCodeServerConfig(baseURL: "http://server.example:4096/", username: "")
        XCTAssertNoThrow(
            try OpenClientNotificationSetupContext(
                connectionID: "connection-1",
                config: validConfig,
                profile: .legacy,
                savedServerID: validConfig.recentServerID
            )
        )

        let invalidConfigs = [
            OpenCodeServerConfig(baseURL: "http://server.example:4096/\u{0007}", username: "opencode"),
            OpenCodeServerConfig(baseURL: "http://server.example/" + String(repeating: "a", count: 2_049), username: "opencode"),
            OpenCodeServerConfig(baseURL: "http://server.example:4096", username: String(repeating: "u", count: 129)),
            OpenCodeServerConfig(baseURL: "http://server.example:4096", username: "open\u{0007}code"),
        ]
        for config in invalidConfigs {
            XCTAssertThrowsError(
                try OpenClientNotificationSetupContext(
                    connectionID: "connection-1",
                    config: config,
                    profile: .legacy,
                    savedServerID: config.recentServerID
                )
            )
        }
        XCTAssertThrowsError(
            try OpenClientNotificationSetupContext(
                connectionID: "connection-1",
                config: validConfig,
                profile: .legacy,
                savedServerID: "another-server"
            )
        )
    }

    func testNotificationSetupClientRejectsMalformedHealthEndpointBeforeRequest() async throws {
        OpenClientNotificationMockURLProtocol.requestHandler = { request in
            XCTFail("Malformed endpoint must fail before transport: \(request)")
            throw OpenClientNotificationSetupError.invalidResponse
        }
        let malformedURLs = [
            "ftp://100.64.0.10:4070/openclient/v1/health",
            "http://user:password@100.64.0.10:4070/openclient/v1/health",
            "http://100.64.0.10:4070/untrusted/path",
            "http://100.64.0.10:4070/openclient/v1/health?next=evil",
        ]
        for value in malformedURLs {
            let endpoint = OpenClientBridgeEndpoint(
                healthURL: try XCTUnwrap(URL(string: value)),
                webSocketURL: try XCTUnwrap(URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")),
                port: 4070,
                openCodePort: 4096,
                notifications: .ready(publicOrigin: "https://notify.example.com")
            )
            do {
                _ = try await OpenClientNotificationSetupClient(
                    sessionConfiguration: Self.notificationSessionConfiguration()
                ).createSetup(endpoint: endpoint, context: Self.notificationContext())
                XCTFail("Expected malformed endpoint to fail")
            } catch {
                XCTAssertEqual(error as? OpenClientNotificationSetupError, .invalidResponse)
            }
        }
    }

    func testNotificationSetupClientRejectsWrongOriginCodeExpiryAndRedirect() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validExpiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))
        let invalidResponses: [(Int, String, OpenClientNotificationSetupError)] = [
            (200, #"{"url":"https://evil.example/#setup=ABCDEF1234","code":"ABCDEF1234","expiresAt":"\#(validExpiry)"}"#, .invalidResponse),
            (200, #"{"url":"https://notify.example.com/#setup=abcdef1234","code":"abcdef1234","expiresAt":"\#(validExpiry)"}"#, .invalidResponse),
            (200, #"{"url":"https://notify.example.com/#setup=ABCDEF1234","code":"ABCDEF1234","expiresAt":"2000-01-01T00:00:00Z"}"#, .invalidExpiry),
            (200, "not-json", .invalidResponse),
            (302, "{}", .invalidResponse),
        ]
        let context = try Self.notificationContext()
        for (status, body, expected) in invalidResponses {
            OpenClientNotificationMockURLProtocol.requestHandler = { request in
                Self.notificationResponse(request: request, status: status, body: body)
            }
            do {
                _ = try await OpenClientNotificationSetupClient(
                    sessionConfiguration: Self.notificationSessionConfiguration(),
                    now: { now }
                ).createSetup(endpoint: Self.notificationEndpoint(), context: context)
                XCTFail("Expected setup response to be rejected")
            } catch {
                XCTAssertEqual(error as? OpenClientNotificationSetupError, expected)
            }
        }
    }

    @MainActor
    func testNotificationSetupDoesNotRequestUntilTappedOrWhileDisconnected() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let requester = RecordingNotificationSetupRequester()
        let context = try Self.notificationContext()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: FlakyOpenClientBridgeConnection(),
            notificationSetupClient: requester,
            notificationContextProvider: { context }
        )
        var requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 0)
        await coordinator.setupNotifications()
        requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 0)

        store.apply(.connected(Self.bridgeEndpoint()))
        await coordinator.setupNotifications()
        requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 0)
        store.apply(.connected(Self.notificationEndpoint()))
        requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 0)
        await coordinator.setupNotifications()
        requestCount = await requester.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testNotificationSetupIgnoresResultWhenConnectionChangesDuringRequest() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let requester = SuspendedNotificationSetupRequester()
        var context = try Self.notificationContext(connectionID: "connection-1")
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: FlakyOpenClientBridgeConnection(),
            notificationSetupClient: requester,
            notificationContextProvider: { context }
        )
        store.apply(.connected(Self.notificationEndpoint()))
        let task = Task { await coordinator.setupNotifications() }
        while !(await requester.hasRequest) { await Task.yield() }
        context = try Self.notificationContext(connectionID: "connection-2")
        await requester.finish()
        await task.value
        XCTAssertEqual(store.notificationSetupPhase, .idle)
    }

    @MainActor
    func testNotificationSetupIgnoresResponseFromEarlierBridgeLifecycle() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Lifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let requester = SuspendedNotificationSetupRequester()
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true, apiProfile: .legacy)
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://server.example:4096") },
            client: PassiveOpenClientBridgeConnection(),
            notificationSetupClient: requester,
            notificationContextProvider: { try? Self.notificationContext() }
        )
        await Task.yield()
        store.apply(.connected(Self.notificationEndpoint()))
        let task = Task { await coordinator.setupNotifications() }
        while !(await requester.hasRequest) { await Task.yield() }

        coordinator.forceConnect()
        await requester.finish()
        await task.value

        XCTAssertEqual(store.notificationSetupPhase, .idle)
    }

    @MainActor
    func testNotificationSetupPreventsDuplicateRequestAndAllowsRetryAfterFailure() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Retry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let suspended = SuspendedNotificationSetupRequester()
        let context = try Self.notificationContext()
        let firstCoordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: PassiveOpenClientBridgeConnection(),
            notificationSetupClient: suspended,
            notificationContextProvider: { context }
        )
        store.apply(.connected(Self.notificationEndpoint()))
        let firstTask = Task { await firstCoordinator.setupNotifications() }
        while !(await suspended.hasRequest) { await Task.yield() }
        await firstCoordinator.setupNotifications()
        let duplicateRequestCount = await suspended.requestCount
        XCTAssertEqual(duplicateRequestCount, 1)
        await suspended.finish()
        await firstTask.value

        let retrying = RetryingNotificationSetupRequester()
        let retryStore = OpenClientBridgeStore(defaults: defaults)
        let retryCoordinator = OpenClientBridgeCoordinator(
            store: retryStore,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: PassiveOpenClientBridgeConnection(),
            notificationSetupClient: retrying,
            notificationContextProvider: { context }
        )
        retryStore.apply(.connected(Self.notificationEndpoint()))
        await retryCoordinator.setupNotifications()
        guard case .failed = retryStore.notificationSetupPhase else {
            return XCTFail("Expected first retry request to fail")
        }
        await retryCoordinator.setupNotifications()
        guard case .ready = retryStore.notificationSetupPhase else {
            return XCTFail("Expected retry to generate a new setup code")
        }
        let retryRequestCount = await retrying.requestCount
        XCTAssertEqual(retryRequestCount, 2)
    }

    @MainActor
    func testNotificationOpenRevalidatesCurrentSetupAndReportsBrowserFailure() async throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Open.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let requester = RecordingNotificationSetupRequester()
        var context = try Self.notificationContext()
        var now = Date()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: ConnectionStore(),
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig() },
            client: PassiveOpenClientBridgeConnection(),
            notificationSetupClient: requester,
            notificationPairingRunner: RecordingNotificationPairingRunner(),
            notificationContextProvider: { context },
            now: { now }
        )
        store.apply(.connected(Self.notificationEndpoint()))
        await coordinator.setupNotifications()
        let oldOpenRequest = try XCTUnwrap(coordinator.notificationOpenRequest())
        XCTAssertEqual(oldOpenRequest.clipboardPayload, "ocnotify:v1:ABCDEF1234:0123456789")
        await coordinator.setupNotifications()
        let currentOpenRequest = try XCTUnwrap(coordinator.notificationOpenRequest())
        XCTAssertNotEqual(oldOpenRequest.requestID, currentOpenRequest.requestID)
        coordinator.notificationBrowserOpenFailed(request: oldOpenRequest)
        XCTAssertNil(store.notificationBrowserErrorMessage)

        coordinator.notificationBrowserOpenFailed(request: currentOpenRequest)
        XCTAssertEqual(
            store.notificationBrowserErrorMessage,
            OpenClientNotificationSetupError.browserOpenFailed.localizedDescription
        )
        guard case .ready = store.notificationSetupPhase else {
            return XCTFail("Browser rejection should keep the current code available for retry")
        }

        await coordinator.setupNotifications()
        XCTAssertNil(store.notificationBrowserErrorMessage)
        context = try Self.notificationContext(connectionID: "connection-2")
        XCTAssertNil(coordinator.notificationOpenRequest())
        XCTAssertEqual(
            store.notificationSetupPhase,
            .failed(OpenClientNotificationSetupError.staleSetup.localizedDescription)
        )

        await coordinator.setupNotifications()
        now = Date().addingTimeInterval(1_000)
        XCTAssertNil(coordinator.notificationOpenRequest())
        XCTAssertEqual(
            store.notificationSetupPhase,
            .failed(OpenClientNotificationSetupError.staleSetup.localizedDescription)
        )
    }

    @MainActor
    func testOldPluginNotificationGuideIsLocalizedAndDoesNotOfferSetup() throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Guide.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        store.apply(.connected(Self.bridgeEndpoint()))
        let facade = OpenClientBridgeFacade(store: store, forceConnect: {})
        XCTAssertFalse(facade.snapshot.canSetUpNotifications)
        XCTAssertEqual(
            String(localized: facade.snapshot.notificationGuidance),
            "Update the OpenClient plugin on the OpenCode host to set up OC Notify from this app."
        )
    }

    @MainActor
    func testDisconnectedNotificationGuidePrioritizesConnection() throws {
        let suiteName = "OpenClientBridgeTests.Notifications.Disconnected.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let facade = OpenClientBridgeFacade(store: store, forceConnect: {})

        XCTAssertFalse(facade.snapshot.isConnected)
        XCTAssertEqual(
            String(localized: facade.snapshot.notificationGuidance),
            "Connect the OpenClient plugin first to configure OC Notify."
        )
    }

    func testDeviceRegistryPublishesAndExecutesStatusTool() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let tools = await registry.listTools()
        XCTAssertEqual(
            tools.map(\.id),
            [
                "openclient_device_status",
                "openclient_visual_chart",
                "openclient_visual_html",
                "openclient_visual_map",
            ]
        )

        let result = try await registry.execute(
            toolID: "openclient_device_status",
            arguments: [:],
            context: OpenClientRemoteToolContext(
                jsonValue: .object([
                    "sessionID": .string("session-1"),
                    "messageID": .string("message-1"),
                    "agent": .string("build"),
                    "directory": .string("/tmp/project"),
                    "worktree": .string("/tmp/project"),
                ])
            )
        )
        XCTAssertEqual(result.title, "OpenClient device status")
        XCTAssertTrue(result.output.contains("session-1"))
    }

    func testVisualMapToolValidatesAndReturnsRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualMapContract.toolID,
            arguments: Self.mapArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "San Francisco")
        XCTAssertEqual(result.output, "Displayed San Francisco with 1 marker.")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualMapContract.rendererID))
        XCTAssertEqual(result.metadata?["schemaVersion"], .number(1))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualMapPayload.self, from: payloadData)
        XCTAssertEqual(payload.center, OpenClientVisualMapCoordinate(latitude: 37.7749, longitude: -122.4194))
        XCTAssertEqual(payload.markers.map(\.id), ["ferry-building"])
        XCTAssertEqual(payload.span, .defaultValue)
    }

    func testVisualMapToolRejectsInvalidCoordinates() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.mapArguments
        arguments["center"] = .object([
            "latitude": .number(91),
            "longitude": .number(-122.4194),
        ])

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualMapContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected invalid coordinates to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.center")
            )
        }
    }

    func testVisualMapToolRejectsUnknownArguments() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.mapArguments
        arguments["unexpected"] = .bool(true)

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualMapContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected unknown arguments to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments")
            )
        }
    }

    func testVisualMapActivityRestoresPersistedToolPayload() throws {
        let data = Data(
            """
            {
              "id": "part-map",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-map",
              "state": {
                "status": "completed",
                "title": "San Francisco on iPhone",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_map",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Unnormalized input",
                    "center": { "latitude": 0, "longitude": 0 }
                  }
                },
                "output": "Displayed San Francisco with 1 marker.",
                "metadata": {
                  "toolID": "openclient_visual_map",
                  "renderer": "openclient.map.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "San Francisco",
                    "center": { "latitude": 37.7749, "longitude": -122.4194 },
                    "span": { "latitudeDelta": 0.08, "longitudeDelta": 0.08 },
                    "markers": [
                      {
                        "id": "ferry-building",
                        "title": "Ferry Building",
                        "coordinate": { "latitude": 37.7955, "longitude": -122.3937 }
                      }
                    ]
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualMapActivity(part: part))

        XCTAssertEqual(part.state?.input?.clientID, "client-1")
        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualMapContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualMapContract.rendererID)
        XCTAssertEqual(activity.payload.title, "San Francisco")
        XCTAssertEqual(activity.payload.markers.first?.title, "Ferry Building")
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualChartToolValidatesTimeSeriesAndReturnsRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualChartContract.toolID,
            arguments: Self.chartArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "Weekly Active Users")
        XCTAssertEqual(result.output, "Displayed a line chart with 3 data points.")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualChartContract.rendererID))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualChartPayload.self, from: payloadData)
        XCTAssertEqual(payload.chartType, .line)
        XCTAssertEqual(payload.xAxis.type, .time)
        XCTAssertEqual(payload.pointCount, 3)
    }

    func testVisualChartToolRejectsInvalidTimeValue() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.chartArguments
        guard case .array(var series)? = arguments["series"],
              case .object(var firstSeries) = series[0],
              case .array(var points)? = firstSeries["points"],
              case .object(var firstPoint) = points[0] else {
            return XCTFail("Invalid chart test fixture")
        }
        firstPoint["x"] = .string("next Tuesday")
        points[0] = .object(firstPoint)
        firstSeries["points"] = .array(points)
        series[0] = .object(firstSeries)
        arguments["series"] = .array(series)

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualChartContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected invalid time value to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.series.points.x")
            )
        }
    }

    func testVisualChartToolRejectsNegativePieValue() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let arguments: [String: OpenClientJSONValue] = [
            "schemaVersion": .number(1),
            "chartType": .string("pie"),
            "xAxis": .object(["type": .string("category")]),
            "series": .array([
                .object([
                    "id": .string("share"),
                    "name": .string("Share"),
                    "points": .array([
                        .object([
                            "id": .string("ios"),
                            "x": .string("iOS"),
                            "y": .number(-1),
                        ]),
                    ]),
                ]),
            ]),
        ]

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualChartContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected negative pie value to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.series.points.y")
            )
        }
    }

    func testVisualChartActivityRestoresPersistedPayload() throws {
        let data = Data(
            """
            {
              "id": "part-chart",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-chart",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_chart",
                  "arguments": {
                    "schemaVersion": 1,
                    "chartType": "bar",
                    "xAxis": { "type": "category" },
                    "series": [{
                      "id": "draft",
                      "name": "Draft",
                      "points": [{ "id": "draft-a", "x": "A", "y": 1 }]
                    }]
                  }
                },
                "output": "Displayed a donut chart with 2 data points.",
                "metadata": {
                  "toolID": "openclient_visual_chart",
                  "renderer": "openclient.chart.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "chartType": "donut",
                    "title": "Platform Share",
                    "xAxis": { "type": "category" },
                    "yAxis": {},
                    "series": [{
                      "id": "share",
                      "name": "Share",
                      "points": [
                        { "id": "ios", "x": "iOS", "y": 72 },
                        { "id": "macos", "x": "macOS", "y": 28 }
                      ]
                    }]
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualChartActivity(part: part))

        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualChartContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualChartContract.rendererID)
        XCTAssertEqual(activity.payload.title, "Platform Share")
        XCTAssertEqual(activity.payload.chartType, .donut)
        XCTAssertEqual(activity.payload.pointCount, 2)
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualHTMLToolReturnsSandboxedRendererMetadata() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let result = try await registry.execute(
            toolID: OpenClientVisualHTMLContract.toolID,
            arguments: Self.htmlArguments,
            context: try Self.context()
        )

        XCTAssertEqual(result.title, "Bridge Architecture")
        XCTAssertEqual(result.output, "Displayed the static HTML visual \"Bridge Architecture\".")
        XCTAssertEqual(result.metadata?["renderer"], .string(OpenClientVisualHTMLContract.rendererID))

        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualHTMLPayload.self, from: payloadData)
        XCTAssertEqual(payload.height, 280)
        XCTAssertTrue(payload.html.contains("<svg"))
        XCTAssertEqual(payload.documentID.count, 64)
    }

    func testVisualHTMLToolAllowsLongPages() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.htmlArguments
        arguments["height"] = .number(4_800)

        let result = try await registry.execute(
            toolID: OpenClientVisualHTMLContract.toolID,
            arguments: arguments,
            context: try Self.context()
        )
        let payloadValue = try XCTUnwrap(result.metadata?["payload"])
        let payloadData = try JSONEncoder().encode(payloadValue)
        let payload = try JSONDecoder().decode(OpenClientVisualHTMLPayload.self, from: payloadData)

        XCTAssertEqual(payload.height, 4_800)
    }

    func testVisualHTMLToolRejectsExecutableAndEmbeddedContent() async throws {
        let registry = OpenClientDeviceToolRegistry()
        let unsafeFragments = [
            "<script>alert('no')</script>",
            "<img src='https://example.com/tracker.png'>",
            "<div onclick='alert(1)'>Tap me</div>",
            "<style>@import 'https://example.com/style.css';</style>",
            "<iframe srcdoc='<p>nested</p>'></iframe>",
            "<img/src='https://example.com/tracker.png'>",
            "<svg/onload='alert(1)'></svg>",
            "<svg><image xlink:href='data:image/png;base64,AAAA'></image></svg>",
            "<style>@keyframes pulse { to { opacity: 0 } } .x { animation: pulse 1s infinite; }</style>",
            "<svg><filter id='blur'><feGaussianBlur stdDeviation='50'/></filter></svg>",
            "<div style='background: red'>inline style</div>",
            #"<style>@\6b eyframes pulse { to { opacity: 0 } }</style>"#,
        ]

        for fragment in unsafeFragments {
            var arguments = Self.htmlArguments
            arguments["html"] = .string(fragment)
            do {
                _ = try await registry.execute(
                    toolID: OpenClientVisualHTMLContract.toolID,
                    arguments: arguments,
                    context: try Self.context()
                )
                XCTFail("Expected unsafe HTML to be rejected: \(fragment)")
            } catch {
                XCTAssertEqual(
                    error as? OpenClientBridgeProtocolError,
                    .invalidField("arguments.html")
                )
            }
        }
    }

    func testVisualHTMLToolRejectsExcessiveElementCount() async throws {
        let registry = OpenClientDeviceToolRegistry()
        var arguments = Self.htmlArguments
        arguments["html"] = .string(String(repeating: "<span>node</span>", count: 201))

        do {
            _ = try await registry.execute(
                toolID: OpenClientVisualHTMLContract.toolID,
                arguments: arguments,
                context: try Self.context()
            )
            XCTFail("Expected excessive HTML complexity to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("arguments.html")
            )
        }
    }

    func testVisualHTMLActivityRestoresPersistedPayload() throws {
        let data = Data(
            """
            {
              "id": "part-html",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-html",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_html",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Draft",
                    "accessibilityLabel": "Draft visual",
                    "html": "<p>Draft</p>",
                    "height": 160
                  }
                },
                "output": "Displayed the static HTML visual.",
                "metadata": {
                  "toolID": "openclient_visual_html",
                  "renderer": "openclient.html.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Canonical Visual",
                    "accessibilityLabel": "Three connected architecture nodes.",
                    "html": "<div class='nodes'>App → Bridge → OpenCode</div>",
                    "height": 240
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualHTMLActivity(part: part))

        XCTAssertEqual(activity.payload.title, "Canonical Visual")
        XCTAssertEqual(activity.payload.height, 240)
        XCTAssertEqual(activity.payload.accessibilityLabel, "Three connected architecture nodes.")
        XCTAssertFalse(activity.isRunning)
    }

    func testVisualVideoActivityRestoresDormantResourcePayload() throws {
        let cover = Self.visualPreview(width: 2, height: 1)
        let data = Data(
            """
            {
              "id": "part-video",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-video",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_video",
                  "arguments": {
                    "schemaVersion": 1,
                    "title": "Launch",
                    "filePath": "/Volumes/Media/launch.mp4"
                  }
                },
                "output": "Prepared the video for lazy playback.",
                "metadata": {
                  "toolID": "openclient_visual_video",
                  "renderer": "openclient.video.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Launch",
                    "resourceID": "abcdefghijklmnopqrstuvwxyzABCDEF",
                    "startPath": "/openclient/v1/video/resources/abcdefghijklmnopqrstuvwxyzABCDEF/stream",
                    "stopPath": "/openclient/v1/video/resources/abcdefghijklmnopqrstuvwxyzABCDEF/stream",
                     "expiresAt": "2026-07-27T18:00:00.000Z",
                     "width": 1920,
                     "height": 1080,
                     "rotation": 0,
                     "duration": 12.5,
                     "cover": {
                       "mimeType": "image/jpeg",
                       "dataURL": "\(cover.dataURL)",
                       "width": 2,
                       "height": 1
                     },
                     "file": {
                      "name": "launch.mp4",
                      "sizeBytes": 42000000,
                      "modifiedAt": "2026-07-27T12:00:00.000Z",
                      "mimeType": "video/mp4"
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualVideoContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualVideoContract.rendererID)
        let payloadValue = try XCTUnwrap(part.state?.metadata?.payload)
        let payloadData = try JSONEncoder().encode(payloadValue)
        let decodedPayload = try JSONDecoder().decode(OpenClientVisualVideoPayload.self, from: payloadData)
        _ = try decodedPayload.validated()
        let activity = try XCTUnwrap(OpenClientVisualVideoActivity(part: part))

        XCTAssertEqual(activity.payload.displayTitle, "Launch")
        XCTAssertEqual(activity.payload.file.name, "launch.mp4")
        XCTAssertEqual(activity.payload.file.sizeBytes, 42_000_000)
        XCTAssertFalse(activity.payload.startPath.contains("Volumes"))
        XCTAssertEqual(activity.payload.width, 1920)
        XCTAssertEqual(activity.payload.cover, cover)
        XCTAssertEqual(activity.payload.cover?.data, cover.data)
        XCTAssertEqual(activity.id.sessionID, "session-1")
        XCTAssertEqual(activity.id.messageID, "message-1")
        XCTAssertEqual(activity.id.partID, "part-video")
    }

    func testVisualVideoPayloadUsesRotatedSourceDimensions() throws {
        var payload = Self.videoPayload()
        payload.width = 1080
        payload.height = 1920
        payload.rotation = 90
        payload.duration = 12.5

        let validated = try payload.validated()

        XCTAssertEqual(validated.width, 1080)
        XCTAssertEqual(validated.height, 1920)
        XCTAssertEqual(validated.rotation, 90)
        XCTAssertEqual(validated.duration, 12.5)
        XCTAssertEqual(validated.displayAspectRatio, 1920.0 / 1080.0, accuracy: 0.001)
    }

    @MainActor
    func testVideoPlaybackStoreRetainsControllerForLogicalPart() {
        let payload = Self.videoPayload()
        let activity = OpenClientVisualVideoActivity(payload: payload)
        let store = OpenClientVideoPlaybackStore()

        XCTAssertTrue(store.controller(for: activity) === store.controller(for: activity))
    }

    func testVisualVideoPayloadRejectsResourcePathSubstitution() throws {
        let payload = Self.videoPayload(
            startPath: "/openclient/v1/video/resources/another-resource/stream"
        )

        XCTAssertThrowsError(try payload.validated()) { error in
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("payload.startPath")
            )
        }
    }

    @MainActor
    func testVideoStreamCoordinatorUsesConnectedBridgeEndpoint() async throws {
        let suiteName = "OpenClientBridgeTests.Video.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let transport = RecordingVideoStreamTransport()
        let coordinator = OpenClientVideoStreamCoordinator(
            bridgeStore: store,
            transport: transport
        )
        let payload = Self.videoPayload()

        do {
            _ = try await coordinator.start(payload: payload)
            XCTFail("Expected disconnected playback to fail")
        } catch {
            XCTAssertEqual(error as? OpenClientVideoStreamError, .unavailable)
        }

        let endpoint = OpenClientBridgeEndpoint(
            healthURL: try XCTUnwrap(URL(string: "http://100.64.0.10:4070/openclient/v1/health")),
            webSocketURL: try XCTUnwrap(URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")),
            port: 4070,
            openCodePort: 4096
        )
        store.apply(.connected(endpoint))

        let stream = try await coordinator.start(payload: payload)
        XCTAssertEqual(stream.playlistURL.absoluteString, "http://100.64.0.10:4070/openclient/v1/video/streams/abcdefghijklmnopqrstuvwxyzABCDEF/playlist.m3u8")
        let startedEndpoint = await transport.startedEndpoint
        XCTAssertEqual(startedEndpoint, endpoint)

        await coordinator.stop(stream: stream)
        let stoppedEndpoint = await transport.stoppedEndpoint
        XCTAssertEqual(stoppedEndpoint, endpoint)
    }

    func testVisualImageActivityRestoresPersistedResourcePayload() throws {
        let preview = Self.visualPreview(width: 2, height: 1)
        let data = Data(
            """
            {
              "id": "part-image",
              "messageID": "message-1",
              "sessionID": "session-1",
              "type": "tool",
              "tool": "openclient_execute_tool",
              "callID": "call-image",
              "state": {
                "status": "completed",
                "input": {
                  "client_id": "client-1",
                  "tool_id": "openclient_visual_image",
                  "arguments": {
                    "schemaVersion": 1,
                    "filePath": "/private/host/path/aurora.png"
                  }
                },
                "output": "Prepared the image for lazy viewing.",
                "metadata": {
                  "toolID": "openclient_visual_image",
                  "renderer": "openclient.image.v1",
                  "schemaVersion": 1,
                  "payload": {
                    "schemaVersion": 1,
                    "title": "Aurora",
                    "accessibilityLabel": "Green lights over a mountain.",
                    "resourceID": "abcdefghijklmnopqrstuvwxyzABCDEF",
                    "contentPath": "/openclient/v1/image/resources/abcdefghijklmnopqrstuvwxyzABCDEF/content",
                    "expiresAt": "2026-08-27T18:00:00.000Z",
                    "width": 1200,
                    "height": 800,
                    "file": {
                      "name": "aurora.png",
                      "sizeBytes": 2048,
                      "modifiedAt": "2026-07-27T12:00:00.000Z",
                      "mimeType": "image/png"
                    },
                    "preview": {
                      "mimeType": "image/jpeg",
                      "dataURL": "\(preview.dataURL)",
                      "width": 2,
                      "height": 1
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)
        let activity = try XCTUnwrap(OpenClientVisualImageActivity(part: part))

        XCTAssertEqual(part.state?.input?.toolID, OpenClientVisualImageContract.toolID)
        XCTAssertEqual(part.state?.metadata?.renderer, OpenClientVisualImageContract.rendererID)
        XCTAssertEqual(activity.payload.displayTitle, "Aurora")
        XCTAssertEqual(activity.payload.accessibilityLabel, "Green lights over a mountain.")
        XCTAssertEqual(activity.payload.preview, preview)
        XCTAssertEqual(activity.payload.preview.data, preview.data)
        XCTAssertEqual(activity.id.sessionID, "session-1")
        XCTAssertEqual(activity.id.messageID, "message-1")
        XCTAssertEqual(activity.id.partID, "part-image")
    }

    func testVisualImagePayloadRejectsResourcePathSubstitution() throws {
        let payload = Self.imagePayload(
            contentPath: "/openclient/v1/image/resources/another-resource/content"
        )

        XCTAssertThrowsError(try payload.validated()) { error in
            XCTAssertEqual(
                error as? OpenClientBridgeProtocolError,
                .invalidField("payload.contentPath")
            )
        }
    }

    func testVisualImagePayloadRejectsInvalidMetadataConstraints() {
        let cases: [(OpenClientVisualImagePayload, OpenClientBridgeProtocolError)] = [
            (
                Self.imagePayload(declaredSize: OpenClientVisualImageContract.maximumFileBytes + 1),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(fileName: "aurora.png", mimeType: "image/jpeg"),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(modifiedAt: "not-a-date"),
                .invalidField("payload.file")
            ),
            (
                Self.imagePayload(title: "   "),
                .invalidField("payload.title")
            ),
            (
                Self.imagePayload(accessibilityLabel: String(repeating: "a", count: 501)),
                .invalidField("payload.accessibilityLabel")
            ),
            (
                Self.imagePayload(width: 0),
                .invalidField("payload.dimensions")
            ),
        ]

        for (payload, expectedError) in cases {
            XCTAssertThrowsError(try payload.validated()) { error in
                XCTAssertEqual(error as? OpenClientBridgeProtocolError, expectedError)
            }
        }
    }

    func testVisualPreviewRejectsInvalidOversizeAndMismatchedJPEGData() throws {
        XCTAssertThrowsError(
            try OpenClientVisualPreview(
                mimeType: "image/jpeg",
                dataURL: "data:image/jpeg;base64,not canonical base64",
                width: 1,
                height: 1
            )
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDataURL)
        }

        var oversized = Data(repeating: 0, count: OpenClientVisualPreview.maximumDecodedBytes + 1)
        oversized[oversized.startIndex] = 0xff
        oversized[oversized.startIndex + 1] = 0xd8
        oversized[oversized.endIndex - 2] = 0xff
        oversized[oversized.endIndex - 1] = 0xd9
        XCTAssertThrowsError(
            try OpenClientVisualPreview(
                mimeType: "image/jpeg",
                dataURL: OpenClientVisualPreview.dataURLPrefix + oversized.base64EncodedString(),
                width: 1,
                height: 1
            )
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .exceedsSizeLimit)
        }

        let twoByOneJPEG = Self.jpegData(width: 2, height: 1)
        XCTAssertThrowsError(
            try OpenClientVisualPreview(jpegData: twoByOneJPEG, width: 1, height: 1)
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDimensions)
        }
        XCTAssertThrowsError(
            try OpenClientVisualPreview(jpegData: twoByOneJPEG, width: 97, height: 1)
        ) { error in
            XCTAssertEqual(error as? OpenClientVisualPreviewError, .invalidDimensions)
        }
    }

    @MainActor
    func testImageContentCoordinatorUsesConnectedBridgeEndpoint() async throws {
        let suiteName = "OpenClientBridgeTests.Image.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let transport = RecordingImageContentTransport()
        let coordinator = OpenClientImageContentCoordinator(
            bridgeStore: store,
            transport: transport
        )
        let payload = Self.imagePayload()

        do {
            _ = try await coordinator.load(payload: payload)
            XCTFail("Expected disconnected image loading to fail")
        } catch {
            XCTAssertEqual(error as? OpenClientImageContentError, .unavailable)
        }

        let endpoint = Self.bridgeEndpoint()
        store.apply(.connected(endpoint))
        let image = try await coordinator.load(payload: payload)

        XCTAssertEqual(image.width, payload.width)
        XCTAssertEqual(image.height, payload.height)
        let loadedEndpoint = await transport.loadedEndpoint
        XCTAssertEqual(loadedEndpoint, endpoint)
    }

    func testImageContentClientLoadsExactConnectedResourceResponse() async throws {
        let bytes = Self.jpegData(width: 4, height: 3)
        let payload = Self.imagePayload(imageData: bytes, width: 4, height: 3)
        OpenClientImageMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, payload.contentPath)
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.url?.fragment)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "image/jpeg",
                        "Content-Length": "\(bytes.count)",
                    ]
                )!,
                bytes
            )
        }

        let client = OpenClientImageContentClient(sessionConfiguration: Self.imageSessionConfiguration())
        let image = try await client.load(payload: payload, endpoint: Self.bridgeEndpoint())

        XCTAssertEqual(image.data, bytes)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 3)
    }

    func testImageContentClientRejectsInvalidResponses() async throws {
        let bytes = Self.jpegData(width: 2, height: 1)
        let payload = Self.imagePayload(imageData: bytes, width: 2, height: 1)
        let endpoint = Self.bridgeEndpoint()

        try await assertImageLoadError(.statusCode(404), payload: payload, endpoint: endpoint) { request in
            Self.imageResponse(request: request, status: 404, contentType: "image/jpeg", contentLength: bytes.count, data: bytes)
        }
        try await assertImageLoadError(
            .invalidContentType(expected: "image/jpeg", actual: "image/png"),
            payload: payload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/png", contentLength: bytes.count, data: bytes)
        }
        try await assertImageLoadError(
            .invalidContentLength(expected: Int64(bytes.count), actual: Int64(bytes.count + 1)),
            payload: payload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: bytes.count + 1, data: bytes)
        }

        let mismatchedPayload = Self.imagePayload(imageData: bytes, width: 3, height: 2)
        try await assertImageLoadError(
            .dimensionMismatch(expectedWidth: 3, expectedHeight: 2, actualWidth: 2, actualHeight: 1),
            payload: mismatchedPayload,
            endpoint: endpoint
        ) { request in
            Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: bytes.count, data: bytes)
        }

        let maximumPayload = Self.imagePayload(
            imageData: bytes,
            width: 2,
            height: 1,
            declaredSize: OpenClientVisualImageContract.maximumFileBytes
        )
        try await assertImageLoadError(.responseTooLarge, payload: maximumPayload, endpoint: endpoint) { request in
            let oversized = Data(count: Int(OpenClientVisualImageContract.maximumFileBytes) + 1)
            return Self.imageResponse(request: request, contentType: "image/jpeg", contentLength: nil, data: oversized)
        }
    }

    @MainActor
    func testImageLoadingStoreRetainsControllerForLogicalPart() throws {
        let firstActivity = try XCTUnwrap(OpenClientVisualImageActivity(
            part: Self.imagePart(payload: Self.imagePayload(), partID: "part-image")
        ))
        let replacementPayload = Self.imagePayload(resourceID: "0123456789abcdefghijklmnopqrstuv")
        let replacementActivity = try XCTUnwrap(OpenClientVisualImageActivity(
            part: Self.imagePart(payload: replacementPayload, partID: "part-image")
        ))
        let store = OpenClientImageLoadingStore()

        XCTAssertEqual(firstActivity.id, replacementActivity.id)
        XCTAssertTrue(
            store.controller(for: firstActivity) === store.controller(for: replacementActivity)
        )
    }

    @MainActor
    func testWhatsNewImageDemoStartsWithBundledImageLoaded() {
        let activity = OpenClientVisualMediaDemo.imageActivity
        let image = OpenClientVisualMediaDemo.loadedImage
        let controller = OpenClientVisualImageLoadingController(
            id: activity.id,
            payload: activity.payload,
            initialImage: image
        )

        XCTAssertEqual(image.width, activity.payload.width)
        XCTAssertEqual(image.height, activity.payload.height)
        XCTAssertEqual(Int64(image.data.count), activity.payload.file.sizeBytes)
        XCTAssertEqual(controller.phase, .loaded(image))
    }

    func testStaticHTMLDocumentInstallsCSPBeforeVisualFragment() throws {
        let fragment = "<svg aria-label='Safe visual'></svg>"
        let preview = OpenClientStaticHTMLDocument.wrap(fragment: fragment, mode: .preview)
        let detail = OpenClientStaticHTMLDocument.wrap(fragment: fragment, mode: .detail)
        let cspRange = try XCTUnwrap(preview.range(of: "Content-Security-Policy"))
        let fragmentRange = try XCTUnwrap(preview.range(of: fragment))

        XCTAssertLessThan(cspRange.lowerBound, fragmentRange.lowerBound)
        XCTAssertTrue(preview.contains("script-src 'none'"))
        XCTAssertTrue(preview.contains("img-src 'none'"))
        XCTAssertTrue(preview.contains("connect-src 'none'"))
        XCTAssertTrue(preview.contains("frame-src 'none'"))
        XCTAssertTrue(preview.contains("form-action 'none'"))
        XCTAssertTrue(preview.contains("user-scalable=no"))
        XCTAssertTrue(preview.contains("overflow: hidden"))
        XCTAssertFalse(preview.contains("user-select: text !important"))
        XCTAssertTrue(detail.contains("user-scalable=yes"))
        XCTAssertTrue(detail.contains("maximum-scale=5"))
        XCTAssertTrue(detail.contains("overflow: auto"))
        XCTAssertTrue(detail.contains("user-select: text !important"))
        XCTAssertTrue(detail.contains("script-src 'none'"))
        XCTAssertTrue(OpenClientStaticHTMLDocument.contentRules.contains("^https://"))
    }

    @MainActor
    func testStaticHTMLWebViewInteractionModes() {
        let previewCoordinator = OpenClientStaticHTMLCoordinator()
        let preview = OpenClientStaticHTMLWebViewFactory.make(
            coordinator: previewCoordinator,
            mode: .preview
        )
        let detailCoordinator = OpenClientStaticHTMLCoordinator()
        let detail = OpenClientStaticHTMLWebViewFactory.make(
            coordinator: detailCoordinator,
            mode: .detail
        )

        XCTAssertFalse(preview.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(detail.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(preview.allowsBackForwardNavigationGestures)
        XCTAssertFalse(detail.allowsBackForwardNavigationGestures)
        XCTAssertFalse(preview.allowsLinkPreview)
        XCTAssertFalse(detail.allowsLinkPreview)
        XCTAssertFalse(preview.scrollView.isScrollEnabled)
        XCTAssertFalse(preview.scrollView.bounces)
        XCTAssertTrue(detail.scrollView.isScrollEnabled)
        XCTAssertTrue(detail.scrollView.bounces)
        XCTAssertTrue(detail.scrollView.alwaysBounceVertical)
    }

    func testVisualHTMLDocumentIDIsDeterministic() throws {
        let payload = try OpenClientVisualHTMLPayload(
            schemaVersion: 1,
            title: "Stable Visual",
            accessibilityLabel: "A stable visual identifier.",
            html: "<p>Stable</p>",
            height: 200
        ).validated()

        XCTAssertEqual(Set((0 ..< 20).map { _ in payload.documentID }).count, 1)
    }

    @MainActor
    func testStaticHTMLDocumentFinishesSecureWebKitLoad() async throws {
        let payload = try OpenClientVisualHTMLPayload(
            schemaVersion: 1,
            title: "WebKit Probe",
            accessibilityLabel: "A secure HTML loading probe.",
            html: "<style>.probe { color: #e6b757; }</style><div class='probe'>Rendered</div>",
            height: 160
        ).validated()
        let coordinator = OpenClientStaticHTMLCoordinator()
        let webView = OpenClientStaticHTMLWebViewFactory.make(coordinator: coordinator, mode: .detail)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.frame = window.bounds
        host.view.addSubview(webView)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var stages: [String] = []
        var result: String?
        coordinator.didUpdateLoadStage = { stages.append($0) }
        coordinator.didFinishLoad = { result = "finished" }
        coordinator.didFailSecureLoad = { error in
            result = "failed: \(error)"
        }

        coordinator.load(payload: payload, into: webView, mode: .detail)
        for _ in 0 ..< 50 where result == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        withExtendedLifetime(coordinator) {}
        XCTAssertEqual(result, "finished", stages.joined(separator: " -> "))
    }

    @MainActor
    func testBridgeFacadePublishesStatusAndRoutesForceConnect() throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        var forceConnectCount = 0
        let facade = OpenClientBridgeFacade(store: store) {
            forceConnectCount += 1
        }

        XCTAssertEqual(facade.snapshot.statusTitle, "Disconnected")
        XCTAssertEqual(facade.snapshot.toolbarSystemImage, "link.circle")
        XCTAssertTrue(facade.snapshot.showsToolbarButton)

        let endpoint = OpenClientBridgeEndpoint(
            healthURL: try XCTUnwrap(URL(string: "http://100.64.0.10:4070/openclient/v1/health")),
            webSocketURL: try XCTUnwrap(URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")),
            port: 4070,
            openCodePort: 4096
        )
        store.apply(.connected(endpoint))

        XCTAssertEqual(facade.snapshot.statusTitle, "Connected")
        XCTAssertEqual(facade.snapshot.toolbarSystemImage, "link.circle.fill")
        XCTAssertTrue(facade.snapshot.showsToolbarButton)
        XCTAssertEqual(facade.snapshot.endpoint, endpoint.webSocketURL)

        facade.forceConnect()
        XCTAssertEqual(forceConnectCount, 1)
    }

    @MainActor
    func testBridgeCoordinatorReconcilesBackendReplacementWithoutPhaseChange() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = FlakyOpenClientBridgeConnection()
        var config = OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096")
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { config },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstConfig = await client.configs.first
        XCTAssertEqual(firstConfig?.sanitizedBaseURL?.port, 4096)

        config = OpenCodeServerConfig(baseURL: "http://100.78.83.51:4097", apiPreference: .v2)
        coordinator.backendContextChanged(connectionID: UUID(), config: config)

        for _ in 0 ..< 50 {
            let configs = await client.configs
            if configs.contains(where: { $0.sanitizedBaseURL?.port == 4097 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let configs = await client.configs
        XCTAssertTrue(configs.contains { $0.sanitizedBaseURL?.host() == "100.78.83.51" })
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorWaitsForBackendConfigAfterStartup() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = FlakyOpenClientBridgeConnection()
        var config: OpenCodeServerConfig?
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { config },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        coordinator.start()
        try await Task.sleep(for: .milliseconds(20))
        let initialConnectCount = await client.connectCount
        XCTAssertEqual(initialConnectCount, 0)

        config = OpenCodeServerConfig(baseURL: "http://100.78.83.51:4097", apiPreference: .v2)
        coordinator.backendContextChanged(connectionID: UUID(), config: config)
        for _ in 0 ..< 50 {
            if await client.connectCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let configs = await client.configs
        XCTAssertEqual(configs.first?.sanitizedBaseURL?.host(), "100.78.83.51")
        XCTAssertEqual(configs.first?.sanitizedBaseURL?.port, 4097)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorDisconnectsWhenBackendBecomesIncompatibleAndIgnoresStaleEvents() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = LifecycleRecordingOpenClientBridgeConnection()
        var config: OpenCodeServerConfig? = OpenCodeServerConfig(baseURL: "http://100.78.83.51:4097", apiPreference: .v2)
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { config },
            client: client
        )

        coordinator.start()
        for _ in 0 ..< 50 {
            if store.phase == .connected(port: 4070) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.phase, .connected(port: 4070))

        config = nil
        coordinator.backendContextChanged(connectionID: UUID(), config: nil)
        for _ in 0 ..< 50 {
            if await client.disconnectCount > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let disconnectCount = await client.disconnectCount
        XCTAssertEqual(disconnectCount, 2)
        XCTAssertEqual(store.phase, .idle)

        await client.emitStaleConnectedEvent()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.phase, .idle)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorRetriesDuringInitialServerBootstrap() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore()
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        let initialConnectCount = await client.connectCount
        XCTAssertEqual(initialConnectCount, 0)
        connectionStore.updateConnectionPhase(.loadingWorkspace)
        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        XCTAssertFalse(connectionStore.isConnected)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorConnectsForResolvedV2ProfileUsingConfiguredServerPort() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore()
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4097", apiPreference: .v2) },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        connectionStore.resolveAPIProfile(.v2)
        connectionStore.updateConnectionPhase(.preparingInterface)
        try await Task.sleep(for: .milliseconds(50))

        let connectCount = await client.connectCount
        let firstConfig = await client.configs.first
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(firstConfig?.sanitizedBaseURL?.port, 4097)
        XCTAssertEqual(store.phase, .connected(port: 4070))

        // Use the actual post-bootstrap transition. Merely resolving the v2
        // profile leaves the coordinator in its permissive loading phase.
        connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(connectionStore.backendMode, .serverV2)
        XCTAssertEqual(connectionStore.connectionPhase, .idle)
        XCTAssertEqual(store.phase, .connected(port: 4070))

        coordinator.forceConnect()
        for _ in 0 ..< 50 {
            if await client.connectCount >= 3, store.phase == .connected(port: 4070) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let forcedConnectCount = await client.connectCount
        XCTAssertEqual(forcedConnectCount, 3)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        XCTAssertNil(store.errorMessage)
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorAutomaticallyRetriesFailedDiscovery() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = FlakyOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        withExtendedLifetime(coordinator) {}
    }

    @MainActor
    func testBridgeCoordinatorAutomaticallyReconnectsAfterTransportDisconnects() async throws {
        let suiteName = "OpenClientBridgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OpenClientBridgeStore(defaults: defaults)
        let connectionStore = ConnectionStore(backendMode: .server, isConnected: true)
        let client = DisconnectingOpenClientBridgeConnection()
        let coordinator = OpenClientBridgeCoordinator(
            store: store,
            connectionStore: connectionStore,
            chatStore: ChatStore(),
            configProvider: { OpenCodeServerConfig(baseURL: "http://100.64.0.10:4096") },
            client: client,
            reconnectDelay: { _ in .milliseconds(10) }
        )

        for _ in 0 ..< 50 {
            if await client.connectCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let connectCount = await client.connectCount
        XCTAssertEqual(connectCount, 2)
        XCTAssertEqual(store.phase, .connected(port: 4070))
        withExtendedLifetime(coordinator) {}
    }

    private static let mapArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "title": .string("San Francisco"),
        "center": .object([
            "latitude": .number(37.7749),
            "longitude": .number(-122.4194),
        ]),
        "markers": .array([
            .object([
                "id": .string("ferry-building"),
                "title": .string("Ferry Building"),
                "subtitle": .string("Historic waterfront marketplace"),
                "coordinate": .object([
                    "latitude": .number(37.7955),
                    "longitude": .number(-122.3937),
                ]),
            ]),
        ]),
    ]

    private static let chartArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "chartType": .string("line"),
        "title": .string("Weekly Active Users"),
        "xAxis": .object([
            "type": .string("time"),
            "title": .string("Week"),
        ]),
        "yAxis": .object([
            "title": .string("Users"),
        ]),
        "series": .array([
            .object([
                "id": .string("users"),
                "name": .string("Users"),
                "points": .array([
                    .object([
                        "id": .string("week-1"),
                        "x": .string("2026-07-06T00:00:00Z"),
                        "y": .number(120),
                    ]),
                    .object([
                        "id": .string("week-2"),
                        "x": .string("2026-07-13T00:00:00Z"),
                        "y": .number(168),
                    ]),
                    .object([
                        "id": .string("week-3"),
                        "x": .string("2026-07-20T00:00:00Z"),
                        "y": .number(214),
                    ]),
                ]),
            ]),
        ]),
    ]

    private static let htmlArguments: [String: OpenClientJSONValue] = [
        "schemaVersion": .number(1),
        "title": .string("Bridge Architecture"),
        "accessibilityLabel": .string("Three connected nodes labeled OpenClient, Bridge, and OpenCode."),
        "height": .number(280),
        "html": .string(
            """
            <style>
            .diagram { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; padding: 20px; }
            .node { padding: 16px; border: 2px solid #ff9f0a; border-radius: 14px; text-align: center; }
            </style>
            <svg viewBox="0 0 600 180" role="img" aria-label="OpenClient bridge architecture">
              <rect x="20" y="50" width="150" height="80" rx="16" fill="#ff9f0a" opacity=".18" />
              <rect x="225" y="50" width="150" height="80" rx="16" fill="#5e5ce6" opacity=".18" />
              <rect x="430" y="50" width="150" height="80" rx="16" fill="#30d158" opacity=".18" />
              <text x="95" y="96" text-anchor="middle">OpenClient</text>
              <text x="300" y="96" text-anchor="middle">Bridge</text>
              <text x="505" y="96" text-anchor="middle">OpenCode</text>
            </svg>
            """
        ),
    ]

    private static func context() throws -> OpenClientRemoteToolContext {
        try OpenClientRemoteToolContext(
            jsonValue: .object([
                "sessionID": .string("session-1"),
                "messageID": .string("message-1"),
                "agent": .string("build"),
                "directory": .string("/tmp/project"),
                "worktree": .string("/tmp/project"),
            ])
        )
    }

    private static func videoPayload(startPath: String? = nil) -> OpenClientVisualVideoPayload {
        let resourceID = "abcdefghijklmnopqrstuvwxyzABCDEF"
        let expectedPath = "/openclient/v1/video/resources/\(resourceID)/stream"
        return OpenClientVisualVideoPayload(
            schemaVersion: 1,
            title: "Launch",
            resourceID: resourceID,
            startPath: startPath ?? expectedPath,
            stopPath: expectedPath,
            expiresAt: "2026-07-27T18:00:00.000Z",
            file: OpenClientVisualVideoFile(
                name: "launch.mp4",
                sizeBytes: 42_000_000,
                modifiedAt: "2026-07-27T12:00:00.000Z",
                mimeType: "video/mp4"
            ),
            width: 1920,
            height: 1080,
            rotation: 0,
            duration: 12.5,
            cover: visualPreview(width: 2, height: 1)
        )
    }

    private static func imagePayload(
        resourceID: String = "abcdefghijklmnopqrstuvwxyzABCDEF",
        contentPath: String? = nil,
        imageData: Data? = nil,
        width: Int = 2,
        height: Int = 1,
        declaredSize: Int64? = nil,
        title: String? = "Aurora",
        accessibilityLabel: String? = "Green lights over a mountain.",
        fileName: String = "aurora.jpg",
        modifiedAt: String = "2026-07-27T12:00:00.000Z",
        mimeType: String = "image/jpeg"
    ) -> OpenClientVisualImagePayload {
        let fixtureWidth = max(1, width)
        let fixtureHeight = max(1, height)
        let data = imageData ?? jpegData(width: fixtureWidth, height: fixtureHeight)
        return OpenClientVisualImagePayload(
            schemaVersion: OpenClientVisualImageContract.schemaVersion,
            title: title,
            accessibilityLabel: accessibilityLabel,
            resourceID: resourceID,
            contentPath: contentPath ?? "/openclient/v1/image/resources/\(resourceID)/content",
            expiresAt: "2026-08-27T18:00:00.000Z",
            width: width,
            height: height,
            file: OpenClientVisualImageFile(
                name: fileName,
                sizeBytes: declaredSize ?? Int64(data.count),
                modifiedAt: modifiedAt,
                mimeType: mimeType
            ),
            preview: visualPreview(width: min(fixtureWidth, 96), height: min(fixtureHeight, 96))
        )
    }

    private static func visualPreview(width: Int, height: Int) -> OpenClientVisualPreview {
        try! OpenClientVisualPreview(
            jpegData: jpegData(width: width, height: height),
            width: width,
            height: height
        )
    }

    private static func imagePart(payload: OpenClientVisualImagePayload, partID: String) throws -> OpenCodePart {
        let payloadData = try JSONEncoder().encode(payload)
        let payloadJSON = try XCTUnwrap(String(data: payloadData, encoding: .utf8))
        return try JSONDecoder().decode(
            OpenCodePart.self,
            from: Data(
                """
                {
                  "id": "\(partID)",
                  "messageID": "message-1",
                  "sessionID": "session-1",
                  "type": "tool",
                  "tool": "openclient_execute_tool",
                  "callID": "call-image",
                  "state": {
                    "status": "completed",
                    "input": { "tool_id": "openclient_visual_image" },
                    "metadata": {
                      "renderer": "openclient.image.v1",
                      "payload": \(payloadJSON)
                    }
                  }
                }
                """.utf8
            )
        )
    }

    private static func jpegData(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        }
    }

    private static func bridgeEndpoint() -> OpenClientBridgeEndpoint {
        OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
    }

    private static func notificationEndpoint() -> OpenClientBridgeEndpoint {
        OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096,
            notifications: .ready(publicOrigin: "https://notify.example.com"),
            notificationPairingLauncher: .init(
                version: 1,
                cliPath: "/cache/node_modules/@openclient-ios/opencode-plugin/dist/notifications/src/cli.mjs",
                dataDir: "/state/notify"
            )
        )
    }

    private static func notificationContext(connectionID: String = "connection-1") throws -> OpenClientNotificationSetupContext {
        try OpenClientNotificationSetupContext(
            connectionID: connectionID,
            config: OpenCodeServerConfig(baseURL: "http://server.example:4096", username: "opencode"),
            profile: .legacy,
            savedServerID: "http://server.example:4096|opencode"
        )
    }

    private static func notificationSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenClientNotificationMockURLProtocol.self]
        return configuration
    }

    private static func notificationRequestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return body }
            if count < 0 { throw stream.streamError ?? OpenClientNotificationSetupError.invalidResponse }
            body.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func notificationResponse(
        request: URLRequest,
        status: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }

    private static func imageSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenClientImageMockURLProtocol.self]
        return configuration
    }

    private static func imageResponse(
        request: URLRequest,
        status: Int = 200,
        contentType: String,
        contentLength: Int?,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        var headers = ["Content-Type": contentType]
        if let contentLength {
            headers["Content-Length"] = "\(contentLength)"
        }
        return (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!,
            data
        )
    }

    private func assertImageLoadError(
        _ expectedError: OpenClientImageContentError,
        payload: OpenClientVisualImagePayload,
        endpoint: OpenClientBridgeEndpoint,
        response: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) async throws {
        OpenClientImageMockURLProtocol.requestHandler = response
        let client = OpenClientImageContentClient(sessionConfiguration: Self.imageSessionConfiguration())
        do {
            _ = try await client.load(payload: payload, endpoint: endpoint)
            XCTFail("Expected image loading to fail with \(expectedError)")
        } catch {
            XCTAssertEqual(error as? OpenClientImageContentError, expectedError)
        }
    }
}

private actor RecordingVideoStreamTransport: OpenClientVideoStreamTransport {
    private(set) var startedEndpoint: OpenClientBridgeEndpoint?
    private(set) var stoppedEndpoint: OpenClientBridgeEndpoint?

    func start(
        payload: OpenClientVisualVideoPayload,
        endpoint: OpenClientBridgeEndpoint
    ) async throws -> OpenClientVideoStream {
        startedEndpoint = endpoint
        return OpenClientVideoStream(
            id: payload.resourceID,
            playlistURL: URL(string: "http://100.64.0.10:4070/openclient/v1/video/streams/\(payload.resourceID)/playlist.m3u8")!,
            stopPath: "/openclient/v1/video/streams/\(payload.resourceID)"
        )
    }

    func stop(
        stream: OpenClientVideoStream,
        endpoint: OpenClientBridgeEndpoint
    ) async throws {
        stoppedEndpoint = endpoint
    }
}

private actor RecordingImageContentTransport: OpenClientImageContentTransport {
    private(set) var loadedEndpoint: OpenClientBridgeEndpoint?

    func load(
        payload: OpenClientVisualImagePayload,
        endpoint: OpenClientBridgeEndpoint
    ) async throws -> OpenClientLoadedImage {
        loadedEndpoint = endpoint
        return OpenClientLoadedImage(
            data: payload.preview.data,
            platformImage: payload.preview.platformImage,
            width: payload.width,
            height: payload.height
        )
    }
}

private final class OpenClientImageMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: OpenClientImageContentError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OpenClientNotificationMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: OpenClientNotificationSetupError.invalidResponse)
            return
        }
        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor RecordingNotificationSetupRequester: OpenClientNotificationSetupRequesting {
    private(set) var requestCount = 0

    func createSetup(
        endpoint: OpenClientBridgeEndpoint,
        context: OpenClientNotificationSetupContext
    ) async throws -> OpenClientNotificationSetup {
        requestCount += 1
        return OpenClientNotificationSetup(
            url: URL(string: "https://notify.example.com/#setup=ABCDEF1234")!,
            code: "ABCDEF1234",
            expiresAt: Date().addingTimeInterval(300)
        )
    }
}

@MainActor
private final class RecordingNotificationPairingRunner: OpenClientNotificationPairingRunning {
    private(set) var launcher: OpenClientNotificationPairingLauncher?

    func createPairingCode(launcher: OpenClientNotificationPairingLauncher) async throws -> String {
        self.launcher = launcher
        return "0123456789"
    }
}

private actor SuspendedNotificationSetupRequester: OpenClientNotificationSetupRequesting {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasRequest = false
    private(set) var requestCount = 0

    func createSetup(
        endpoint: OpenClientBridgeEndpoint,
        context: OpenClientNotificationSetupContext
    ) async throws -> OpenClientNotificationSetup {
        requestCount += 1
        hasRequest = true
        await withCheckedContinuation { continuation = $0 }
        return OpenClientNotificationSetup(
            url: URL(string: "https://notify.example.com/#setup=ABCDEF1234")!,
            code: "ABCDEF1234",
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

private actor RetryingNotificationSetupRequester: OpenClientNotificationSetupRequesting {
    private(set) var requestCount = 0

    func createSetup(
        endpoint: OpenClientBridgeEndpoint,
        context: OpenClientNotificationSetupContext
    ) async throws -> OpenClientNotificationSetup {
        requestCount += 1
        if requestCount == 1 { throw URLError(.cannotConnectToHost) }
        return OpenClientNotificationSetup(
            url: URL(string: "https://notify.example.com/#setup=0123456789")!,
            code: "0123456789",
            expiresAt: Date().addingTimeInterval(300)
        )
    }
}

private actor PassiveOpenClientBridgeConnection: OpenClientBridgeConnecting {
    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {}

    func updateSession(_ sessionID: String?) async {}
    func disconnect() async {}
}

private actor FlakyOpenClientBridgeConnection: OpenClientBridgeConnecting {
    private(set) var connectCount = 0
    private(set) var configs: [OpenCodeServerConfig] = []

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        connectCount += 1
        configs.append(config)
        if connectCount == 1 {
            throw OpenClientBridgeDiscoveryError.notFound
        }
        let endpoint = OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
        eventHandler(.connected(endpoint))
    }

    func updateSession(_ sessionID: String?) async {}

    func disconnect() async {}
}

private actor LifecycleRecordingOpenClientBridgeConnection: OpenClientBridgeConnecting {
    private(set) var disconnectCount = 0
    private var eventHandler: (@Sendable (OpenClientBridgeClientEvent) -> Void)?

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        self.eventHandler = eventHandler
        eventHandler(.connected(Self.endpoint))
    }

    func updateSession(_ sessionID: String?) async {}

    func disconnect() async {
        disconnectCount += 1
    }

    func emitStaleConnectedEvent() {
        eventHandler?(.connected(Self.endpoint))
    }

    private static var endpoint: OpenClientBridgeEndpoint {
        OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.78.83.51:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.78.83.51:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4097
        )
    }
}

private actor DisconnectingOpenClientBridgeConnection: OpenClientBridgeConnecting {
    private(set) var connectCount = 0

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        connectCount += 1
        let endpoint = OpenClientBridgeEndpoint(
            healthURL: URL(string: "http://100.64.0.10:4070/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://100.64.0.10:4070/openclient/v1/ws")!,
            port: 4070,
            openCodePort: 4096
        )
        eventHandler(.connected(endpoint))
        if connectCount == 1 {
            Task {
                try? await Task.sleep(for: .milliseconds(5))
                eventHandler(.disconnected("Connection lost"))
            }
        }
    }

    func updateSession(_ sessionID: String?) async {}

    func disconnect() async {}
}
