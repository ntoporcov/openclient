import Foundation

struct OpenCodeManagedEvent: Sendable {
    let directory: String
    let envelope: OpenCodeEventEnvelope
    let typed: OpenCodeTypedEvent
}

enum OpenCodeManagedEventDecodeResult: Sendable {
    case event(OpenCodeManagedEvent)
    case dropped(String)
}

@MainActor
final class OpenCodeEventManager {
    private var task: Task<Void, Never>?

    nonisolated static func decodeManagedEvent(from rawData: String) -> OpenCodeManagedEventDecodeResult {
        guard let data = rawData.data(using: .utf8) else {
            return .dropped("drop event: non-utf8 payload")
        }

        guard let global = try? JSONDecoder().decode(OpenCodeGlobalEventEnvelope.self, from: data) else {
            return .dropped("drop event: invalid global envelope \(String(rawData.prefix(160)))")
        }

        guard let envelope = global.event else {
            return .dropped("drop event: missing inner envelope dir=\(global.directory ?? "global")")
        }

        guard let typed = OpenCodeTypedEvent(envelope: envelope) else {
            return .dropped("drop event: untyped \(envelope.type) dir=\(global.directory ?? "global")")
        }

        return .event(
            OpenCodeManagedEvent(
                directory: global.directory ?? "global",
                envelope: envelope,
                typed: typed
            )
        )
    }

    func start(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onDroppedEvent: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void
    ) {
        stop()
        task = Task {
            await Self.runStreamLoop(
                client: client,
                onStatus: onStatus,
                onRawLine: onRawLine,
                onDroppedEvent: onDroppedEvent,
                onEvent: onEvent
            )
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    nonisolated private static func runStreamLoop(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onDroppedEvent: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void
    ) async {
        var reconnectAttempt = 0

        while !Task.isCancelled {
            guard let url = client.globalEventURL() else {
                await onStatus("stream invalid url")
                return
            }

            let startedAt = Date.now
            await OpenCodeEventStream.consume(
                client: client,
                url: url,
                onStatus: onStatus,
                onRawLine: onRawLine,
                onEvent: { event in
                    switch Self.decodeManagedEvent(from: event.data) {
                    case let .event(managed):
                        await onEvent(managed)
                    case let .dropped(message):
                        await onDroppedEvent?(message)
                    }
                }
            )

            if Task.isCancelled {
                return
            }

            if Date.now.timeIntervalSince(startedAt) > 10 {
                reconnectAttempt = 0
            }

            let delaySeconds = min(8.0, 0.25 * pow(2.0, Double(reconnectAttempt))) + Double.random(in: 0 ... 0.2)
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            await onStatus("stream reconnecting")
            try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1_000)))
        }
    }
}
