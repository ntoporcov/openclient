import Foundation

struct OpenCodeManagedEvent: Sendable {
    let directory: String
    let envelope: OpenCodeEventEnvelope
    let typed: OpenCodeTypedEvent
}

final class OpenCodeEventManager {
    private var task: Task<Void, Never>?

    func start(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void
    ) {
        stop()
        task = Task.detached(priority: .background) {
            while !Task.isCancelled {
                guard let url = client.globalEventURL() else {
                    await onStatus("stream invalid url")
                    return
                }

                await OpenCodeEventStream.consume(
                    client: client,
                    url: url,
                    onStatus: onStatus,
                    onRawLine: onRawLine,
                    onEvent: { event in
                        guard let data = event.data.data(using: .utf8),
                              let global = try? JSONDecoder().decode(OpenCodeGlobalEventEnvelope.self, from: data),
                              let envelope = global.event,
                              let typed = OpenCodeTypedEvent(envelope: envelope) else {
                            return
                        }

                        await onEvent(
                            OpenCodeManagedEvent(
                                directory: global.directory ?? "global",
                                envelope: envelope,
                                typed: typed
                            )
                        )
                    }
                )

                if Task.isCancelled {
                    return
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
