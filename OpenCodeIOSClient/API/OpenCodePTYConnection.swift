import Foundation

final class OpenCodePTYSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    enum Event: Sendable {
        case opened
        case closed(Int)
    }

    let events: AsyncThrowingStream<Event, Error>
    private let continuation: AsyncThrowingStream<Event, Error>.Continuation

    override init() {
        let stream = AsyncThrowingStream<Event, Error>.makeStream()
        events = stream.stream
        continuation = stream.continuation
        super.init()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        continuation.yield(.opened)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        continuation.yield(.closed(closeCode.rawValue))
        continuation.finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let socket = task as? URLSessionWebSocketTask, socket.closeCode != .invalid {
            continuation.yield(.closed(socket.closeCode.rawValue))
            continuation.finish()
        } else {
            continuation.finish(throwing: error)
        }
    }
}

enum OpenCodePTYConnectionError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        String(localized: "The terminal is not connected.")
    }
}

actor OpenCodePTYConnection {
    private struct CursorMetadata: Decodable {
        let cursor: Int
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var isConnected = false

    func run(
        request: URLRequest,
        initialCursor: Int,
        onEvent: @escaping @Sendable (OpenCodePTYSocketEvent) async -> Void
    ) async throws {
        disconnect()

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        let delegate = OpenCodePTYSocketDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1_024 * 1_024
        self.session = session
        self.socket = socket
        defer {
            if self.socket === socket {
                self.socket = nil
                self.session = nil
                isConnected = false
            }
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        try await withTaskCancellationHandler {
            var lifecycle = delegate.events.makeAsyncIterator()
            socket.resume()
            guard case .opened? = try await lifecycle.next() else {
                throw URLError(.cannotConnectToHost)
            }
            guard !Task.isCancelled, self.socket === socket else { throw CancellationError() }
            isConnected = true
            await onEvent(.connected)
            var cursor = initialCursor
            do {
                while !Task.isCancelled, self.socket === socket {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, self.socket === socket else { throw CancellationError() }
                    if let event = Self.decodeMessage(message, cursor: &cursor) {
                        await onEvent(event)
                    }
                }
                throw CancellationError()
            } catch {
                guard !Task.isCancelled, self.socket === socket else { throw CancellationError() }
                isConnected = false
                // receive() throws on both normal closure and failure. The delegate supplies
                // the actual close code, rather than inferring closure from the NSError.
                if case let .closed(code)? = try? await lifecycle.next() {
                    await onEvent(.closed(code: code))
                    if code == URLSessionWebSocketTask.CloseCode.normalClosure.rawValue { return }
                }
                throw error
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        guard let socket, isConnected else { throw OpenCodePTYConnectionError.notConnected }
        let text = String(decoding: bytes, as: UTF8.self)
        try await socket.send(.string(text))
    }

    func disconnect() {
        isConnected = false
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
    }

    nonisolated static func decodeCursorMetadata(_ data: Data) -> Int? {
        guard data.first == 0,
              let cursor = try? JSONDecoder().decode(CursorMetadata.self, from: Data(data.dropFirst())).cursor,
              (0 ... 9_007_199_254_740_991).contains(cursor) else { return nil }
        return cursor
    }

    nonisolated static func decodeMessage(
        _ message: URLSessionWebSocketTask.Message, cursor: inout Int
    ) -> OpenCodePTYSocketEvent? {
        switch message {
        case let .string(text):
            cursor += text.utf16.count
            return .output(text, cursor: cursor)
        case let .data(data):
            guard let next = decodeCursorMetadata(data) else { return nil }
            cursor = next
            return .cursor(next)
        @unknown default:
            return nil
        }
    }
}
