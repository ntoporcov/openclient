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

struct OpenCodeV2ManagedEvent: Decodable, Sendable {
    struct Location: Codable, Hashable, Sendable {
        let directory: String
        let workspaceID: String?
    }

    let id: String?
    let created: Double?
    let type: String
    let location: Location?
    let data: OpenCodeJSONValue

    var sessionID: String? {
        data.objectValue?["sessionID"]?.literalStringValue
            ?? data.objectValue?["form"]?.objectValue?["sessionID"]?.literalStringValue
    }

    var routingLocation: Location? {
        if type == "session.created" || type == "session.moved",
           let value = data.objectValue?["location"],
           let encoded = try? JSONEncoder().encode(value),
           let location = try? JSONDecoder().decode(Location.self, from: encoded) {
            return location
        }
        return location
    }

    var globalFormEvent: BackendSessionFormsEvent? {
        guard sessionID == "global", let data = data.objectValue else { return nil }
        switch type {
        case "form.created":
            guard let value = data["form"], let encoded = try? JSONEncoder().encode(value),
                  let form = try? JSONDecoder().decode(OpenCodeV2Form.self, from: encoded) else { return nil }
            return .created(form.backendForm)
        case "form.replied":
            guard let id = data["id"]?.literalStringValue, let raw = data["answer"]?.objectValue,
                  let answer = try? raw.mapValues({ try BackendFormValue(jsonValue: $0) }) else { return nil }
            return .answered(.init(sessionID: "global", formID: id), answer)
        case "form.cancelled":
            guard let id = data["id"]?.literalStringValue else { return nil }
            return .cancelled(.init(sessionID: "global", formID: id))
        default: return nil
        }
    }

    // The publisher counts text and reasoning independently, not by content-array index.
    static func partID(messageID: String, type: String, ordinal: Int) -> String {
        "\(messageID):v2:\(type):\(ordinal)"
    }

    var isExecutionStarted: Bool { type == "session.execution.started" }

    var inputID: String? {
        switch type {
        case "session.input.admitted", "session.input.promoted", "session.input.cancelled":
            return data.objectValue?["inputID"]?.literalStringValue
        case "session.inbox.enqueued", "session.inbox.delivery.changed", "session.inbox.delivered", "session.inbox.cancelled":
            return data.objectValue?["inboxID"]?.literalStringValue
        default: return nil
        }
    }

    var admittedInput: OpenCodeV2AdmittedInput? {
        let value: OpenCodeJSONValue?
        switch type {
        case "session.input.admitted":
            value = data.objectValue?["input"]
        case "session.inbox.enqueued":
            guard let item = data.objectValue?["item"]?.objectValue,
                  let kind = item["type"], let payload = item["payload"] else { return nil }
            value = .object(["type": kind, "data": payload])
        default: return nil
        }
        guard let value, let encoded = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(OpenCodeV2AdmittedInput.self, from: encoded)
    }

    var affectsTranscript: Bool {
        type.hasPrefix("session.step.") || type.hasPrefix("session.text.")
            || type.hasPrefix("session.reasoning.") || type.hasPrefix("session.tool.")
            || type.hasPrefix("session.shell.") || type.hasPrefix("session.compaction.")
            || ["session.message.content.updated", "session.revert.committed", "session.inbox.delivered",
                "session.input.promoted", "session.input.cancelled", "session.inbox.cancelled",
                "session.synthetic", "session.instructions.updated", "session.skill.activated",
                "session.agent.selected", "session.model.selected", "session.moved"].contains(type)
    }

    var isExecutionTerminal: Bool {
        type == "session.execution.succeeded"
            || type == "session.execution.failed"
            || type == "session.execution.interrupted"
            || type == "session.idle"
    }
}

actor OpenCodeManagedEventBatcher {
    private static let maxEventsPerFlush = 24

    private struct QueuedEvent: Sendable {
        let directory: String
        let event: OpenCodeManagedEvent
    }

    private let onEvent: @Sendable (OpenCodeManagedEvent) async -> Void
    private var queue: [QueuedEvent] = []
    private var coalescedIndexes: [String: Int] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var isStopped = false

    init(onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void) {
        self.onEvent = onEvent
    }

    func enqueue(_ event: OpenCodeManagedEvent) {
        guard !isStopped else { return }
        let directory = event.directory
        if let key = coalescingKey(directory: directory, event: event),
           let index = coalescedIndexes[key] {
            queue[index] = QueuedEvent(directory: directory, event: event)
            scheduleFlush()
            return
        }

        if let key = coalescingKey(directory: directory, event: event) {
            coalescedIndexes[key] = queue.count
        }
        queue.append(QueuedEvent(directory: directory, event: event))
        scheduleFlush()
    }

    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        flushTask?.cancel()
        flushTask = nil

        while !queue.isEmpty {
            let count = min(queue.count, Self.maxEventsPerFlush)
            let events = Array(queue.prefix(count))
            queue.removeFirst(count)
            rebuildCoalescedIndexes()

            for item in events {
                guard !isStopped else { return }
                await onEvent(item.event)
            }
        }
    }

    func stop() {
        isStopped = true
        flushTask?.cancel()
        flushTask = nil
        queue.removeAll()
        coalescedIndexes.removeAll()
    }

    private func scheduleFlush() {
        guard !isFlushing else { return }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            await self?.flushScheduledEvents()
        }
    }

    private func flushScheduledEvents() async {
        guard !Task.isCancelled else { return }
        // The timer is now delivering, not pending. flush() must not cancel its own callbacks.
        flushTask = nil
        await flush()
    }

    private func coalescingKey(directory: String, event: OpenCodeManagedEvent) -> String? {
        switch event.envelope.type {
        case "session.status":
            guard let sessionID = event.envelope.properties.sessionID else { return nil }
            return "session.status:\(directory):\(sessionID)"
        case "lsp.updated":
            return "lsp.updated:\(directory)"
        default:
            return nil
        }
    }

    private func rebuildCoalescedIndexes() {
        coalescedIndexes = [:]
        for (index, item) in queue.enumerated() {
            guard let key = coalescingKey(directory: item.directory, event: item.event) else { continue }
            coalescedIndexes[key] = index
        }
    }
}

private actor OpenCodeStreamHeartbeat {
    private var lastEventAt = ContinuousClock.now

    func markEvent() {
        lastEventAt = ContinuousClock.now
    }

    func isTimedOut(timeout: TimeInterval) -> Bool {
        lastEventAt.duration(to: .now) >= .seconds(timeout)
    }
}

@MainActor
final class OpenCodeEventManager {
    typealias V2StreamConsumer = @Sendable (
        OpenCodeAPIClient, URL,
        @escaping @Sendable (String) async -> Void,
        @escaping @Sendable () async -> Void,
        @escaping @Sendable (OpenCodeServerEvent) async -> Void
    ) async -> Void
    private static let heartbeatTimeoutSeconds: TimeInterval = 15
    private static let v2HeartbeatTimeoutSeconds: TimeInterval = 45
    private var task: Task<Void, Never>?
    private(set) var generation: UInt = 0
    private var managedEventObserver: (@Sendable (OpenCodeManagedEvent) async -> Void)?

    func setManagedEventObserver(
        _ observer: (@Sendable (OpenCodeManagedEvent) async -> Void)?
    ) {
        managedEventObserver = observer
    }

    nonisolated static func decodeManagedEvent(from rawData: String) -> OpenCodeManagedEventDecodeResult {
        guard let data = rawData.data(using: .utf8) else {
            return .dropped("drop event: non-utf8 payload")
        }

        guard let global = try? JSONDecoder().decode(OpenCodeGlobalEventEnvelope.self, from: data) else {
            if let recovered = recoverPartUpdatedEvent(from: rawData) {
                return .event(recovered)
            }
            return .dropped("drop event: invalid global envelope \(String(rawData.prefix(160)))")
        }

        guard let envelope = global.event else {
            return .dropped("drop event: missing inner envelope dir=\(global.directory ?? "global")")
        }

        guard let typed = OpenCodeTypedEvent(envelope: envelope) else {
            if envelope.type == "message.part.updated",
               let recovered = recoverPartUpdatedEvent(from: rawData) {
                return .event(recovered)
            }
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

    nonisolated static func decodeV2Event(from rawData: String) -> OpenCodeV2ManagedEvent? {
        guard let data = rawData.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OpenCodeV2ManagedEvent.self, from: data)
    }

    func start(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onDroppedEvent: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void
    ) {
        stop()
        let managedEventObserver = self.managedEventObserver
        let generation = self.generation
        task = Task.detached { [weak self] in
            await Self.runStreamLoop(
                client: client,
                onStatus: onStatus,
                onRawLine: onRawLine,
                onDroppedEvent: onDroppedEvent,
                onEvent: { [weak self] managed in
                    guard await self?.generation == generation else { return }
                    await onEvent(managed)
                    guard await self?.generation == generation else { return }
                    await managedEventObserver?(managed)
                }
            )
        }
    }

    func startV2(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onDroppedEvent: (@Sendable (String) async -> Void)? = nil,
        consume: @escaping V2StreamConsumer = { client, url, status, activity, event in
            await OpenCodeEventStream.consume(client: client, url: url, onStatus: status, onActivity: activity, onEvent: event)
        },
        onEvent: @escaping @Sendable (OpenCodeV2ManagedEvent) async -> Void
    ) {
        stop()
        let generation = self.generation
        task = Task.detached { [weak self] in
            await Self.runV2StreamLoop(
                client: client,
                onStatus: { [weak self] status in
                    guard !Task.isCancelled, await self?.generation == generation else { return }
                    await onStatus(status)
                },
                onDroppedEvent: { [weak self] message in
                    guard !Task.isCancelled, await self?.generation == generation else { return }
                    await onDroppedEvent?(message)
                },
                consume: consume,
                onEvent: { [weak self] event in
                    guard !Task.isCancelled, await self?.generation == generation else { return }
                    await onEvent(event)
                }
            )
        }
    }

    nonisolated private static func recoverPartUpdatedEvent(from rawData: String) -> OpenCodeManagedEvent? {
        guard let data = rawData.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let eventObject = root["payload"] as? [String: Any] ?? root
        guard eventObject["type"] as? String == "message.part.updated",
              let properties = eventObject["properties"] as? [String: Any],
              let part = recoverPartUpdatedPart(from: properties) else {
            return nil
        }

        let sessionID = stringValue(for: "sessionID", in: properties) ?? part.sessionID
        let messageID = stringValue(for: "messageID", in: properties) ?? part.messageID
        let partID = stringValue(for: "partID", in: properties) ?? part.id
        let eventProperties = OpenCodeEventProperties(
            sessionID: sessionID,
            part: part,
            text: stringValue(for: "text", in: properties),
            mime: stringValue(for: "mime", in: properties),
            filename: stringValue(for: "filename", in: properties),
            url: stringValue(for: "url", in: properties),
            reason: stringValue(for: "reason", in: properties),
            messageID: messageID,
            partID: partID,
            permissionType: stringValue(for: "type", in: properties),
            callID: stringValue(for: "callID", in: properties)
        )
        let envelope = OpenCodeEventEnvelope(type: "message.part.updated", properties: eventProperties)

        return OpenCodeManagedEvent(
            directory: root["directory"] as? String ?? "global",
            envelope: envelope,
            typed: .messagePartUpdated(part)
        )
    }

    nonisolated private static func recoverPartUpdatedPart(from properties: [String: Any]) -> OpenCodePart? {
        let nested = properties["part"] as? [String: Any]
        func value(_ key: String) -> Any? {
            nested?[key] ?? properties[key]
        }

        let toolName: String? = {
            if let value = value("tool") as? String { return value }
            if let object = value("tool") as? [String: Any] { return stringValue(for: "name", in: object) }
            return nil
        }()
        let type = stringValue(for: "type", in: nested ?? [:])
            ?? stringValue(for: "type", in: properties)
            ?? (toolName != nil ? "tool" : (stringValue(for: "text", in: nested ?? properties) != nil ? "text" : nil))
        guard let type else { return nil }

        let messageID = stringValue(for: "messageID", in: nested ?? [:]) ?? stringValue(for: "messageID", in: properties)
        let partID = stringValue(for: "id", in: nested ?? [:]) ?? stringValue(for: "partID", in: properties) ?? stringValue(for: "id", in: properties)
        let sessionID = stringValue(for: "sessionID", in: nested ?? [:]) ?? stringValue(for: "sessionID", in: properties)

        return OpenCodePart(
            id: partID,
            messageID: messageID,
            sessionID: sessionID,
            type: type,
            mime: stringValue(for: "mime", in: nested ?? [:]) ?? stringValue(for: "mime", in: properties),
            filename: stringValue(for: "filename", in: nested ?? [:]) ?? stringValue(for: "filename", in: properties),
            name: stringValue(for: "name", in: nested ?? [:]) ?? stringValue(for: "name", in: properties),
            url: stringValue(for: "url", in: nested ?? [:]) ?? stringValue(for: "url", in: properties),
            source: nil,
            reason: stringValue(for: "reason", in: nested ?? [:]) ?? stringValue(for: "reason", in: properties),
            tool: toolName,
            callID: stringValue(for: "callID", in: nested ?? [:]) ?? stringValue(for: "callID", in: properties),
            state: nil,
            text: stringValue(for: "text", in: nested ?? [:]) ?? stringValue(for: "text", in: properties)
        )
        .applyingEventFallbacks(sessionID: sessionID, messageID: messageID, partID: partID)
    }

    nonisolated private static func stringValue(for key: String, in dictionary: [String: Any]) -> String? {
        dictionary[key] as? String
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func stopAndWait() async {
        let previous = task
        stop()
        await previous?.value
    }

    deinit {
        task?.cancel()
    }

    nonisolated static func withHeartbeat(
        timeout: TimeInterval,
        onTimeout: @escaping @Sendable () async -> Void,
        consume: @escaping @Sendable (_ onActivity: @escaping @Sendable () async -> Void) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let heartbeat = OpenCodeStreamHeartbeat()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                guard !Task.isCancelled else { return }
                await consume { await heartbeat.markEvent() }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    guard !Task.isCancelled else { return }
                    if await heartbeat.isTimedOut(timeout: timeout) {
                        await onTimeout()
                        return
                    }
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    nonisolated private static func runStreamLoop(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onRawLine: (@Sendable (String) async -> Void)? = nil,
        onDroppedEvent: (@Sendable (String) async -> Void)? = nil,
        onEvent: @escaping @Sendable (OpenCodeManagedEvent) async -> Void
    ) async {
        var reconnectAttempt = 0
        let batcher = OpenCodeManagedEventBatcher(onEvent: onEvent)

        while !Task.isCancelled {
            guard let url = client.globalEventURL() else {
                await onStatus("stream invalid url")
                return
            }

            let startedAt = Date.now
            await withHeartbeat(timeout: Self.heartbeatTimeoutSeconds, onTimeout: {
                await onStatus("stream heartbeat timeout")
            }) { onActivity in
                await OpenCodeEventStream.consume(
                    client: client,
                    url: url,
                    onStatus: onStatus,
                    onActivity: onActivity,
                    onRawLine: onRawLine,
                    onEvent: { event in
                        switch Self.decodeManagedEvent(from: event.data) {
                        case let .event(managed):
                            await batcher.enqueue(managed)
                        case let .dropped(message):
                            await onDroppedEvent?(message)
                        }
                    }
                )
            }

            if Task.isCancelled {
                await batcher.stop()
                return
            }
            await batcher.flush()

            if Date.now.timeIntervalSince(startedAt) > 10 {
                reconnectAttempt = 0
            }

            let delaySeconds = min(8.0, 0.25 * pow(2.0, Double(reconnectAttempt))) + Double.random(in: 0 ... 0.2)
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            await onStatus("stream reconnecting")
            try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1_000)))
        }
        await batcher.stop()
    }

    nonisolated private static func runV2StreamLoop(
        client: OpenCodeAPIClient,
        onStatus: @escaping @Sendable (String) async -> Void,
        onDroppedEvent: (@Sendable (String) async -> Void)?,
        consume: @escaping V2StreamConsumer,
        onEvent: @escaping @Sendable (OpenCodeV2ManagedEvent) async -> Void
    ) async {
        var reconnectAttempt = 0

        while !Task.isCancelled {
            guard let url = client.v2EventURL() else {
                await onStatus("stream invalid v2 url")
                return
            }

            let startedAt = Date.now
            await withHeartbeat(timeout: Self.v2HeartbeatTimeoutSeconds, onTimeout: {
                await onStatus("stream v2 heartbeat timeout")
            }) { onActivity in
                await consume(
                    client, url, onStatus, onActivity,
                    { event in
                        guard let managed = Self.decodeV2Event(from: event.data) else {
                            await onDroppedEvent?("drop v2 event: \(String(event.data.prefix(160)))")
                            return
                        }
                        await onEvent(managed)
                    }
                )
            }
            if Task.isCancelled { return }
            if Date.now.timeIntervalSince(startedAt) > 10 { reconnectAttempt = 0 }

            let delaySeconds = min(8.0, 0.25 * pow(2.0, Double(reconnectAttempt))) + Double.random(in: 0 ... 0.2)
            reconnectAttempt = min(reconnectAttempt + 1, 6)
            await onStatus("stream v2 reconnecting")
            try? await Task.sleep(for: .milliseconds(Int(delaySeconds * 1_000)))
        }
    }
}
