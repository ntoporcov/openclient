import Foundation

/// DSH 0.2.0-rc.2's Connection RPC and Typert mux contracts. Cookies and launch
/// tokens stay in this connection's ephemeral URLSession, never in app defaults.
struct DSHConfiguration: Sendable {
    let baseURL: URL
    let launchToken: String?
    var username: String? = nil
    var password: String? = nil

    init(url: URL) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme), components.host != nil,
              components.user == nil, components.password == nil,
              components.path.isEmpty || components.path == "/" else { throw URLError(.badURL) }
        launchToken = components.queryItems?.first(where: { $0.name == "token" })?.value
        components.query = nil
        components.fragment = nil
        components.path = "/"
        guard let baseURL = components.url else { throw URLError(.badURL) }
        self.baseURL = baseURL
    }
}

struct DSHRemoteError: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

// JSON is shared infrastructure; DSH payloads never decode as OpenCode events.
typealias DSHJSON = OpenCodeJSONValue

extension OpenCodeJSONValue {
    subscript(dsh key: String) -> Self { objectValue?[key] ?? .null }
    var dshString: String? { literalStringValue }
    var dshArray: [Self] { arrayValue ?? [] }
    var dshBool: Bool { self == .bool(true) }

    func dshDecode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}

@MainActor
final class DSHTransport {
    private struct Subscription {
        let endpoint: String
        let args: [String: DSHJSON]
        let continuation: AsyncThrowingStream<DSHJSON, Error>.Continuation
        var openingTimeout: Task<Void, Never>?
    }

    let configuration: DSHConfiguration
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var subscriptions: [String: Subscription] = [:]
    private var closed = false
    var onReconnect: (@MainActor () -> Void)?

    init(configuration: DSHConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 20
        settings.urlCache = nil
        self.session = session ?? URLSession(configuration: settings, delegate: DSHLoginRedirectPolicy(origin: configuration.baseURL), delegateQueue: nil)
    }

    func connect() async throws {
        if let username = configuration.username, let password = configuration.password {
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("auth/login"))
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.passwordForm(username: username, password: password)
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.path == "/" else { throw URLError(.userAuthenticationRequired) }
        }
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        if let token = configuration.launchToken {
            components.queryItems = [.init(name: "token", value: token)]
        }
        let (_, response) = try await session.data(from: components.url!)
        try Self.check(response)
        try Task.checkCancellation()
        guard !closed else { throw BackendError.disconnected }
        makeSocket()
        reader = Task { [weak self] in await self?.readFrames() }
    }

    static func passwordForm(username: String, password: String) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let fields = [("username", username), ("password", password), ("next", "/")]
        return Data(fields.map { key, value in "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }

    func call(_ endpoint: String, args: [String: DSHJSON] = [:]) async throws -> DSHJSON {
        guard !closed else { throw BackendError.disconnected }
        let rpcID = UUID().uuidString
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/" + endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DSHJSON.object([
            "type": .string("client-request"), "rpcId": .string(rpcID), "method": .string(endpoint),
            "payload": .object(["args": .object(args)])
        ]))
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        let envelope = try JSONDecoder().decode(DSHJSON.self, from: data)
        guard envelope[dsh: "type"].dshString == "server-response",
              envelope[dsh: "rpcId"].dshString == rpcID else { throw URLError(.cannotParseResponse) }
        let result = envelope[dsh: "result"]
        guard result[dsh: "ok"].dshBool else { throw Self.remoteError(result[dsh: "error"]) }
        return result[dsh: "value"]
    }

    func delegateInteraction(clientID: String, eventID: String) async throws {
        // An unhandled waterfall must call next(), not leave a Host listener waiting.
        // Delegation is not an approval; the next configured answerer owns the decision.
        _ = try await call("$events/result", args: [
            "clientId": .string(clientID), "eventId": .string(eventID),
            "outcome": .object(["kind": .string("next")])
        ])
    }

    func open(_ endpoint: String, args: [String: DSHJSON] = [:]) async throws -> AsyncThrowingStream<DSHJSON, Error> {
        guard !closed, socket != nil else { throw BackendError.disconnected }
        let id = UUID().uuidString
        let pair = AsyncThrowingStream<DSHJSON, Error>.makeStream()
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in await self?.cancel(id) }
        }
        subscriptions[id] = Subscription(endpoint: endpoint, args: args, continuation: pair.continuation)
        armTimeout(id)
        do { try await sendOpen(id) }
        catch {
            finish(id, error: error)
            throw error
        }
        return pair.stream
    }

    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        for id in Array(subscriptions.keys) { finish(id, error: CancellationError()) }
        session.invalidateAndCancel()
    }

    private func makeSocket() {
        var url = URLComponents(url: configuration.baseURL.appendingPathComponent("api/remote.mux"), resolvingAgainstBaseURL: false)!
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: url.url!)
        // Explicitly carry the authority-bound HTTP cookie to the WS handshake.
        let cookies = session.configuration.httpCookieStorage?.cookies(for: configuration.baseURL) ?? []
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        socket = task
        task.resume()
    }

    private func readFrames() async {
        var failures = 0
        while !closed, !Task.isCancelled {
            do {
                guard let socket else { throw URLError(.networkConnectionLost) }
                let message = try await socket.receive()
                try Task.checkCancellation()
                let data: Data
                switch message {
                case let .data(bytes): data = bytes
                case let .string(text): data = Data(text.utf8)
                @unknown default: throw URLError(.cannotParseResponse)
                }
                let frame = try JSONDecoder().decode(DSHJSON.self, from: data)
                guard let id = frame[dsh: "streamId"].dshString,
                      let type = frame[dsh: "type"].dshString else { throw URLError(.cannotParseResponse) }
                guard let subscription = subscriptions[id] else { continue }
                switch type {
                case "item":
                    failures = 0
                    subscription.openingTimeout?.cancel()
                    subscriptions[id]?.openingTimeout = nil
                    subscription.continuation.yield(frame[dsh: "value"])
                case "error": finish(id, error: Self.remoteError(frame[dsh: "error"]))
                case "end": finish(id, error: URLError(.networkConnectionLost))
                default: throw URLError(.cannotParseResponse)
                }
            } catch {
                guard !closed, !Task.isCancelled else { return }
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                failures += 1
                onReconnect?()
                do {
                    try await Task.sleep(for: .milliseconds(min(10_000, 500 * (1 << min(failures - 1, 5)))))
                    try Task.checkCancellation()
                    guard !closed else { return }
                    makeSocket()
                    for id in Array(subscriptions.keys) {
                        armTimeout(id)
                        try await sendOpen(id)
                    }
                } catch {
                    guard !closed, !Task.isCancelled else { return }
                    // The receive loop owns retries; business stream errors above are terminal.
                }
            }
        }
    }

    private func sendOpen(_ id: String) async throws {
        guard let subscription = subscriptions[id] else { return }
        try await send(.object([
            "type": .string("open"), "streamId": .string(id), "endpoint": .string(subscription.endpoint),
            "payload": .object(["args": .object(subscription.args)])
        ]))
    }

    private func send(_ value: DSHJSON) async throws {
        guard let socket, !closed else { throw BackendError.disconnected }
        let data = try JSONEncoder().encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func armTimeout(_ id: String) {
        subscriptions[id]?.openingTimeout?.cancel()
        subscriptions[id]?.openingTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            self?.finish(id, error: URLError(.timedOut))
        }
    }

    private func finish(_ id: String, error: Error) {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.openingTimeout?.cancel()
        subscription.continuation.finish(throwing: error)
    }

    private func cancel(_ id: String) async {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.openingTimeout?.cancel()
        try? await send(.object(["type": .string("cancel"), "streamId": .string(id)]))
    }

    private static func remoteError(_ value: DSHJSON) -> Error {
        guard let code = value[dsh: "code"].dshString, let message = value[dsh: "message"].dshString else {
            return URLError(.cannotParseResponse)
        }
        return DSHRemoteError(code: code, message: message)
    }

    private static func check(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401 || response.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
    }
}
