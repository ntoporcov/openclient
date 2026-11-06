import Foundation
import Network
import OSLog

/// RoyalVNCKit accepts TCP only. This single-client loopback adapter preserves
/// the plugin's ticket/origin boundary without exposing a listener on the LAN.
final class OpenClientDesktopTunnel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "openclient.desktop.tunnel")
    private var listener: NWListener?
    private var peer: NWConnection?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var ready: CheckedContinuation<UInt16, Error>?
    private var stopped = false
    private var clipboard = DesktopClipboardChannel()
    private var onClipboardText: (@Sendable (String) -> Void)?
    private let logger = Logger(subsystem: "com.ntoporcov.openclient", category: "DesktopClipboard")

    func start(viewerURL: URL, onClipboardText: (@Sendable (String) -> Void)? = nil) async throws -> UInt16 {
        guard var url = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil else { throw URLError(.badURL) }
        let ticket = URLComponents(string: "?" + (url.percentEncodedFragment ?? ""))?.queryItems?.first { $0.name == "ticket" }?.value
        guard let ticket, ticket.count == 43 else { throw URLError(.badURL) }
        url.fragment = nil
        url.query = nil
        url.path = "/openclient/v1/desktop/socket"
        var origin = url
        origin.path = ""
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.queryItems = [URLQueryItem(name: "ticket", value: ticket)]
        if onClipboardText != nil { url.queryItems?.append(URLQueryItem(name: "clipboard", value: "1")) }
        var request = URLRequest(url: url.url!)
        request.setValue(origin.url!.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        let socketRequest = request
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
                self.ready = continuation
                self.onClipboardText = onClipboardText
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    let session = URLSession(configuration: .ephemeral)
                    self.session = session
                    self.socket = session.webSocketTask(with: socketRequest)
                    listener.stateUpdateHandler = { [weak self, weak listener] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            if let port = listener?.port { self.ready?.resume(returning: port.rawValue); self.ready = nil }
                        case .failed(let error): self.close(error)
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self, weak listener] peer in
                        guard let self else { peer.cancel(); return }
                        guard self.peer == nil, !self.stopped else { peer.cancel(); return }
                        self.peer = peer
                        listener?.cancel()
                        peer.start(queue: self.queue)
                        self.socket?.resume()
                        self.readTCP()
                        self.readWebSocket()
                    }
                    listener.start(queue: self.queue)
                } catch { self.close(error) }
            }
        }
    }

    func stop() { queue.async { self.close(CancellationError()) } }

    /// Called only after the native desktop has authenticated. Older hosts never
    /// advertise this channel, so they never receive an unsupported text command.
    func enableClipboard() {
        queue.async {
            guard !self.stopped else { return }
            self.clipboard.requested = true
            self.subscribeToClipboardIfReady()
        }
    }

    private func subscribeToClipboardIfReady() {
        guard onClipboardText != nil, clipboard.takeSubscription() else { return }
        socket?.send(.string("{\"type\":\"clipboard.subscribe\"}")) { error in
            if error != nil { self.logger.error("Host clipboard subscription failed") }
        }
    }

    private func close(_ error: Error) {
        guard !stopped else { return }
        stopped = true
        onClipboardText = nil
        ready?.resume(throwing: error); ready = nil
        listener?.cancel(); listener = nil
        peer?.cancel(); peer = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        session?.invalidateAndCancel(); session = nil
    }

    private func readTCP() {
        peer?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
            if let error { self.close(error); return }
            guard let data, !data.isEmpty else { self.close(URLError(.networkConnectionLost)); return }
            self.socket?.send(.data(data)) { error in
                self.queue.async {
                    if let error { self.close(error) }
                    else if complete { self.close(URLError(.networkConnectionLost)) }
                    else { self.readTCP() }
                }
            }
        }
    }

    private func readWebSocket() {
        socket?.receive { result in
            self.queue.async {
                switch result {
                case .success(.data(let data)):
                    self.peer?.send(content: data, completion: .contentProcessed { error in
                        if let error { self.close(error) } else { self.readWebSocket() }
                    })
                case .success(.string(let message)):
                    if let event = self.clipboard.receive(message) {
                        switch event {
                        case .capability(let available):
                            self.logger.info("Host clipboard available: \(available)")
                            self.subscribeToClipboardIfReady()
                        case .status(let ready):
                            self.logger.info("Host clipboard observer ready: \(ready)")
                        case .text(let text):
                            self.onClipboardText?(text)
                        }
                    }
                    // Control messages never enter the RFB byte stream.
                    self.readWebSocket()
                case .success: self.close(URLError(.cannotParseResponse))
                case .failure(let error): self.close(error)
                }
            }
        }
    }
}

struct DesktopClipboardChannel {
    enum Event: Equatable {
        case capability(Bool), status(Bool), text(String)
    }
    var requested = false
    private var available = false
    private var subscribed = false

    mutating func takeSubscription() -> Bool {
        guard requested, available, !subscribed else { return false }
        subscribed = true
        return true
    }

    mutating func receive(_ message: String) -> Event? {
        guard message.utf8.count <= 512 * 1024,
              let data = message.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        switch envelope.type {
        case "clipboard.capability":
            guard let value = envelope.available else { return nil }
            available = value
            return .capability(value)
        case "clipboard.status":
            guard subscribed, let value = envelope.ready else { return nil }
            return .status(value)
        case "clipboard.text":
            guard subscribed, let text = envelope.text, !text.isEmpty,
                  text.utf8.count <= 65_536 else { return nil }
            return .text(text)
        default: return nil
        }
    }

    private struct Envelope: Decodable {
        let type: String
        let available: Bool?
        let ready: Bool?
        let text: String?
    }
}
