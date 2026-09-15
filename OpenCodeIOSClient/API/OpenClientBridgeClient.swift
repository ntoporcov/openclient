import Foundation

struct OpenClientBridgeRegistration: Equatable, Sendable {
    let clientID: String
    let displayName: String
    let appVersion: String
}

struct OpenClientBridgeEndpoint: Equatable, Sendable {
    let healthURL: URL
    let webSocketURL: URL
    let port: Int
    let openCodePort: Int
    let notifications: OpenClientBridgeNotificationsCapability

    init(
        healthURL: URL,
        webSocketURL: URL,
        port: Int,
        openCodePort: Int,
        notifications: OpenClientBridgeNotificationsCapability = .missing
    ) {
        self.healthURL = healthURL
        self.webSocketURL = webSocketURL
        self.port = port
        self.openCodePort = openCodePort
        self.notifications = notifications
    }
}

enum OpenClientBridgeClientEvent: Equatable, Sendable {
    case searching
    case connecting(OpenClientBridgeEndpoint)
    case connected(OpenClientBridgeEndpoint)
    case disconnected(String?)
}

protocol OpenClientBridgeConnecting: Sendable {
    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws
    func updateSession(_ sessionID: String?) async
    func disconnect() async
}

actor OpenClientBridgeClient: OpenClientBridgeConnecting {
    private let registry: OpenClientDeviceToolRegistry
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var requestTasks: [String: Task<Void, Never>] = [:]
    private var eventHandler: (@Sendable (OpenClientBridgeClientEvent) -> Void)?
    private var endpoint: OpenClientBridgeEndpoint?
    private var activeSessionID: String?
    private var registered = false
    private var generation = UUID()

    init(registry: OpenClientDeviceToolRegistry = OpenClientDeviceToolRegistry()) {
        self.registry = registry
    }

    func connect(
        config: OpenCodeServerConfig,
        registration: OpenClientBridgeRegistration,
        initialSessionID: String?,
        eventHandler: @escaping @Sendable (OpenClientBridgeClientEvent) -> Void
    ) async throws {
        let generation = UUID()
        self.generation = generation
        cleanupConnection()
        self.eventHandler = eventHandler
        activeSessionID = initialSessionID
        eventHandler(.searching)

        let endpoint = try await OpenClientBridgeEndpointDiscovery.discover(config: config)
        try Task.checkCancellation()
        guard generation == self.generation else { throw CancellationError() }
        eventHandler(.connecting(endpoint))
        self.endpoint = endpoint

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: endpoint.webSocketURL)
        self.session = session
        self.socket = socket
        registered = false
        socket.resume()
        try await send(
            OpenClientBridgeRegisterMessage(
                protocolVersion: openClientBridgeProtocolVersion,
                type: "register",
                clientID: registration.clientID,
                displayName: registration.displayName,
                appVersion: registration.appVersion
            )
        )
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    func updateSession(_ sessionID: String?) async {
        activeSessionID = sessionID
        guard registered else { return }
        try? await sendSessionUpdate()
    }

    func disconnect() async {
        generation = UUID()
        cleanupConnection()
        activeSessionID = nil
        eventHandler = nil
    }

    private func cleanupConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for task in requestTasks.values { task.cancel() }
        requestTasks.removeAll()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        endpoint = nil
        registered = false
    }

    private func receiveLoop(generation: UUID) async {
        do {
            while !Task.isCancelled, generation == self.generation, let socket {
                let payload = try await socket.receive()
                let data: Data
                switch payload {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let value):
                    data = value
                @unknown default:
                    throw OpenClientBridgeProtocolError.unsupportedMessage
                }
                let message = try JSONDecoder().decode(OpenClientBridgeServerMessage.self, from: data)
                try await handle(message)
            }
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            connectionFailed(error, generation: generation)
        }
    }

    private func handle(_ message: OpenClientBridgeServerMessage) async throws {
        switch message {
        case .registered:
            registered = true
            startHeartbeat()
            try await sendSessionUpdate()
            if let endpoint { eventHandler?(.connected(endpoint)) }
        case .request(let request):
            let task = Task { [weak self] in
                guard let self else { return }
                await self.process(request)
            }
            requestTasks[request.id] = task
        case .cancel(let id):
            requestTasks.removeValue(forKey: id)?.cancel()
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let generation = generation
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop(generation: generation)
        }
    }

    private func heartbeatLoop(generation: UUID) async {
        while !Task.isCancelled, generation == self.generation {
            do {
                try await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled,
                      generation == self.generation,
                      let socket else { return }
                try await Self.sendPing(on: socket)
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                connectionFailed(error, generation: generation)
                return
            }
        }
    }

    private func connectionFailed(_ error: Error, generation: UUID) {
        guard generation == self.generation else { return }
        cleanupConnection()
        eventHandler?(.disconnected(error.localizedDescription))
    }

    private nonisolated static func sendPing(on socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let completion = OpenClientBridgePingCompletion(continuation: continuation)
            socket.sendPing { error in
                completion.resume(with: error)
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                completion.resume(with: URLError(.timedOut))
            }
        }
    }

    private func process(_ request: OpenClientBridgeRequest) async {
        defer { requestTasks.removeValue(forKey: request.id) }
        do {
            let result: OpenClientJSONValue
            switch request.method {
            case .listTools:
                try Task.checkCancellation()
                let tools = await registry.listTools()
                result = .object(["tools": .array(tools.map(\.jsonValue))])
            case .executeTool:
                guard let params = request.params.objectValue else {
                    throw OpenClientBridgeProtocolError.invalidField("params")
                }
                let toolID = try params.requiredString("toolID")
                let arguments = try params.object("arguments")
                guard let contextValue = params["context"] else {
                    throw OpenClientBridgeProtocolError.invalidField("context")
                }
                let context = try OpenClientRemoteToolContext(jsonValue: contextValue)
                try Task.checkCancellation()
                let toolResult = try await registry.execute(toolID: toolID, arguments: arguments, context: context)
                result = toolResult.jsonValue
            }
            guard !Task.isCancelled else { return }
            try await send(
                OpenClientBridgeResponseMessage(
                    protocolVersion: openClientBridgeProtocolVersion,
                    type: "response",
                    id: request.id,
                    ok: true,
                    result: result,
                    error: nil
                )
            )
        } catch {
            guard !Task.isCancelled else { return }
            try? await send(
                OpenClientBridgeResponseMessage(
                    protocolVersion: openClientBridgeProtocolVersion,
                    type: "response",
                    id: request.id,
                    ok: false,
                    result: nil,
                    error: OpenClientBridgeWireError(code: "execution_failed", message: error.localizedDescription)
                )
            )
        }
    }

    private func sendSessionUpdate() async throws {
        try await send(
            OpenClientBridgeSessionMessage(
                protocolVersion: openClientBridgeProtocolVersion,
                type: "session_updated",
                sessionID: activeSessionID
            )
        )
    }

    private func send<T: Encodable>(_ message: T) async throws {
        guard let socket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONEncoder().encode(message)
        guard let text = String(data: data, encoding: .utf8) else {
            throw OpenClientBridgeProtocolError.unsupportedMessage
        }
        try await socket.send(.string(text))
    }
}

private final class OpenClientBridgePingCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume(with error: Error?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

enum OpenClientBridgeEndpointDiscovery {
    static func discover(config: OpenCodeServerConfig) async throws -> OpenClientBridgeEndpoint {
        let candidates = candidateEndpoints(config: config)
        guard !candidates.isEmpty else { throw OpenClientBridgeDiscoveryError.invalidServerURL }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 2
        sessionConfiguration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.finishTasksAndInvalidate() }

        return try await withThrowingTaskGroup(of: OpenClientBridgeEndpoint?.self) { group in
            for candidate in candidates {
                group.addTask {
                    await probe(candidate: candidate, session: session)
                }
            }
            for try await endpoint in group {
                if let endpoint {
                    group.cancelAll()
                    return endpoint
                }
            }
            throw OpenClientBridgeDiscoveryError.notFound
        }
    }

    static func candidateEndpoints(config: OpenCodeServerConfig) -> [OpenClientBridgeEndpoint] {
        guard let baseURL = config.sanitizedBaseURL,
              let host = baseURL.host(),
              let openCodePort = baseURL.normalizedNetworkPort else { return [] }
        return (4070 ... 4090).compactMap { port in
            var healthComponents = URLComponents()
            healthComponents.scheme = "http"
            healthComponents.host = host
            healthComponents.port = port
            healthComponents.path = "/openclient/v1/health"
            var socketComponents = healthComponents
            socketComponents.scheme = "ws"
            socketComponents.path = "/openclient/v1/ws"
            guard let healthURL = healthComponents.url,
                  let webSocketURL = socketComponents.url else { return nil }
            return OpenClientBridgeEndpoint(
                healthURL: healthURL,
                webSocketURL: webSocketURL,
                port: port,
                openCodePort: openCodePort
            )
        }
    }

    private static func probe(
        candidate: OpenClientBridgeEndpoint,
        session: URLSession
    ) async -> OpenClientBridgeEndpoint? {
        let request = URLRequest(url: candidate.healthURL)
        guard let (data, response) = try? await session.data(for: request),
              let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              let health = try? JSONDecoder().decode(OpenClientBridgeHealth.self, from: data),
              health.service == "openclient-plugin",
              health.protocol == openClientBridgeProtocolVersion,
              health.port == candidate.port,
              health.openCodePort == candidate.openCodePort else { return nil }
        return endpoint(candidate: candidate, health: health)
    }

    static func endpoint(
        candidate: OpenClientBridgeEndpoint,
        health: OpenClientBridgeHealth
    ) -> OpenClientBridgeEndpoint {
        OpenClientBridgeEndpoint(
            healthURL: candidate.healthURL,
            webSocketURL: candidate.webSocketURL,
            port: candidate.port,
            openCodePort: candidate.openCodePort,
            notifications: OpenClientBridgeNotificationsCapability(advertisement: health.notifications)
        )
    }
}

enum OpenClientBridgeDiscoveryError: LocalizedError {
    case invalidServerURL
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "The OpenCode server URL cannot be used for OpenClient bridge discovery.")
        case .notFound:
            return String(localized: "No OpenClient plugin bridge was found on ports 4070 through 4090.")
        }
    }
}

private struct OpenClientBridgeRegisterMessage: Encodable {
    let protocolVersion: Int
    let type: String
    let clientID: String
    let displayName: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case clientID
        case displayName
        case appVersion
    }
}

private struct OpenClientBridgeSessionMessage: Encodable {
    let protocolVersion: Int
    let type: String
    let sessionID: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case sessionID
    }
}

private struct OpenClientBridgeResponseMessage: Encodable {
    let protocolVersion: Int
    let type: String
    let id: String
    let ok: Bool
    let result: OpenClientJSONValue?
    let error: OpenClientBridgeWireError?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case id
        case ok
        case result
        case error
    }
}

private struct OpenClientBridgeWireError: Encodable {
    let code: String
    let message: String
}

private extension URL {
    var normalizedNetworkPort: Int? {
        if let port { return port }
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}

protocol OpenClientNotificationSetupRequesting: Sendable {
    func createSetup(
        endpoint: OpenClientBridgeEndpoint,
        context: OpenClientNotificationSetupContext
    ) async throws -> OpenClientNotificationSetup
}

final class OpenClientNotificationSetupClient: NSObject, OpenClientNotificationSetupRequesting, URLSessionTaskDelegate, @unchecked Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let configuration = sessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        self.now = now
        session = URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func createSetup(
        endpoint: OpenClientBridgeEndpoint,
        context: OpenClientNotificationSetupContext
    ) async throws -> OpenClientNotificationSetup {
        guard case .ready(let publicOrigin) = endpoint.notifications else {
            throw OpenClientNotificationSetupError.unavailable
        }
        guard var components = URLComponents(url: endpoint.healthURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.path == "/openclient/v1/health",
              components.query == nil,
              components.fragment == nil,
              components.url?.absoluteString == endpoint.healthURL.absoluteString else {
            throw OpenClientNotificationSetupError.invalidResponse
        }
        components.path = "/openclient/v1/notifications/setup"
        components.query = nil
        components.fragment = nil
        guard let requestURL = components.url else { throw OpenClientNotificationSetupError.invalidResponse }

        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            OpenClientNotificationSetupRequest(
                baseURL: context.baseURL,
                username: context.username,
                profile: context.profile.rawValue
            )
        )

        let (data, response) = try await session.data(for: request, delegate: self)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url == requestURL else {
            throw OpenClientNotificationSetupError.invalidResponse
        }
        guard let wire = try? JSONDecoder().decode(OpenClientNotificationSetupResponse.self, from: data) else {
            throw OpenClientNotificationSetupError.invalidResponse
        }
        guard wire.code.count == 10,
              wire.code.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) }),
              let url = URL(string: wire.url),
              wire.url == "\(publicOrigin)/#setup=\(wire.code)",
              url.absoluteString == wire.url,
              let expiresAt = Self.parseDate(wire.expiresAt) else {
            throw OpenClientNotificationSetupError.invalidResponse
        }
        let issuedAt = now()
        guard expiresAt > issuedAt,
              expiresAt <= issuedAt.addingTimeInterval(610) else {
            throw OpenClientNotificationSetupError.invalidExpiry
        }
        return OpenClientNotificationSetup(url: url, code: wire.code, expiresAt: expiresAt)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct OpenClientNotificationSetupRequest: Encodable {
    let baseURL: String
    let username: String
    let profile: String
}

private struct OpenClientNotificationSetupResponse: Decodable {
    let url: String
    let code: String
    let expiresAt: String
}
