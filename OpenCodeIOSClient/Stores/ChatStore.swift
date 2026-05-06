import Combine
import Foundation

@MainActor
final class ChatStore: ObservableObject {
    struct TranscriptDeltaKey: Hashable {
        let sessionID: String
        let messageID: String
        let partID: String
        let field: String
    }

    @Published var messages: [OpenCodeMessageEnvelope]
    @Published var cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]]
    @Published var toolMessageDetails: [String: OpenCodeMessageEnvelope]
    @Published var isLoadingSelectedSession: Bool
    var liveRefreshTask: Task<Void, Never>?
    var liveRefreshGeneration: Int
    var lastFallbackMessageCount: Int
    var lastFallbackAssistantLength: Int
    var inFlightToolMessageDetailIDs: Set<String>
    var nextStreamPartHapticAllowedAt: Date
    var pendingTranscriptEvents: [OpenCodePendingTranscriptEvent]
    var streamDeltaFlushTask: Task<Void, Never>?
    var streamDeltaLastFlushAt: Date?

    init(
        messages: [OpenCodeMessageEnvelope] = [],
        cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]] = [:],
        toolMessageDetails: [String: OpenCodeMessageEnvelope] = [:],
        isLoadingSelectedSession: Bool = false,
        liveRefreshTask: Task<Void, Never>? = nil,
        liveRefreshGeneration: Int = 0,
        lastFallbackMessageCount: Int = 0,
        lastFallbackAssistantLength: Int = 0,
        inFlightToolMessageDetailIDs: Set<String> = [],
        nextStreamPartHapticAllowedAt: Date = .distantPast,
        pendingTranscriptEvents: [OpenCodePendingTranscriptEvent] = [],
        streamDeltaFlushTask: Task<Void, Never>? = nil,
        streamDeltaLastFlushAt: Date? = nil
    ) {
        self.messages = messages
        self.cachedMessagesBySessionID = cachedMessagesBySessionID
        self.toolMessageDetails = toolMessageDetails
        self.isLoadingSelectedSession = isLoadingSelectedSession
        self.liveRefreshTask = liveRefreshTask
        self.liveRefreshGeneration = liveRefreshGeneration
        self.lastFallbackMessageCount = lastFallbackMessageCount
        self.lastFallbackAssistantLength = lastFallbackAssistantLength
        self.inFlightToolMessageDetailIDs = inFlightToolMessageDetailIDs
        self.nextStreamPartHapticAllowedAt = nextStreamPartHapticAllowedAt
        self.pendingTranscriptEvents = pendingTranscriptEvents
        self.streamDeltaFlushTask = streamDeltaFlushTask
        self.streamDeltaLastFlushAt = streamDeltaLastFlushAt
    }

    func resetActiveSession() {
        messages = []
        isLoadingSelectedSession = false
        liveRefreshGeneration += 1
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        lastFallbackMessageCount = 0
        lastFallbackAssistantLength = 0
        pendingTranscriptEvents = []
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil
        streamDeltaLastFlushAt = nil
    }

    func beginSelectingSession(cachedMessages: [OpenCodeMessageEnvelope]) {
        isLoadingSelectedSession = true
        messages = cachedMessages
    }

    func clearActiveTranscript() {
        messages = []
        isLoadingSelectedSession = false
    }

    func finishLoadingSelectedSession() {
        isLoadingSelectedSession = false
    }

    func appendMessage(_ message: OpenCodeMessageEnvelope) {
        messages.append(message)
    }

    func insertOptimisticUserMessage(_ message: OpenCodeMessageEnvelope) {
        messages.append(message)
    }

    func rollbackOptimisticUserMessage(messageID: String) {
        removeMessage(id: messageID)
    }

    func appendLocalAppleIntelligenceExchange(
        userMessage: OpenCodeMessageEnvelope,
        assistantMessage: OpenCodeMessageEnvelope,
        appendUserMessage: Bool
    ) {
        if appendUserMessage {
            messages.append(userMessage)
        }
        messages.append(assistantMessage)
    }

    func updateLocalAppleIntelligenceAssistantMessage(messageID: String, partID: String, sessionID: String, text: String) {
        let part = OpenCodePart(
            id: partID,
            messageID: messageID,
            sessionID: sessionID,
            type: "text",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: text
        )

        upsertPart(
            part,
            fallbackMessage: OpenCodeMessageEnvelope(
                info: OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: "Apple Intelligence", model: nil),
                parts: [part]
            )
        )
    }

    func removeOptimisticUserMessage(messageID: String) {
        messages.removeAll { $0.id == messageID && ($0.info.role ?? "").lowercased() == "user" }
    }

    func removeMessage(id messageID: String) {
        messages.removeAll { $0.id == messageID }
    }

    func upsertPart(_ part: OpenCodePart, fallbackMessage: @autoclosure () -> OpenCodeMessageEnvelope) {
        if let index = messages.firstIndex(where: { $0.id == part.messageID }) {
            messages[index] = messages[index].upsertingPart(part)
            return
        }

        messages.append(fallbackMessage())
    }

    func replaceActiveMessagesWithMergedCanonical(_ loadedMessages: [OpenCodeMessageEnvelope]) {
        messages = Self.mergeMessagesPreservingStreamProgress(existing: messages, loaded: loadedMessages)
    }

    func applyCanonicalMessages(_ loadedMessages: [OpenCodeMessageEnvelope], forSessionID sessionID: String, isActiveSession: Bool) {
        cacheMessages(loadedMessages, forSessionID: sessionID)
        guard isActiveSession else { return }
        replaceActiveMessagesWithMergedCanonical(loadedMessages)
        finishLoadingSelectedSession()
    }

    func cacheMessages(_ messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) {
        cachedMessagesBySessionID[sessionID] = messages
    }

    func clearCachedMessages(forSessionID sessionID: String) {
        cachedMessagesBySessionID[sessionID] = nil
    }

    func updateCachedMessagesForLiveActivity(payload: OpenCodeEventEnvelope, sessionID: String) -> [OpenCodeMessageEnvelope]? {
        var cachedMessages = cachedMessagesBySessionID[sessionID] ?? []

        switch payload.type {
        case "message.updated", "message.part.updated", "message.part.delta":
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: sessionID, messages: cachedMessages)
            guard update.applied else { return nil }
            cachedMessages = update.messages
        case "message.removed":
            guard let messageID = payload.properties.messageID else { return nil }
            cachedMessages.removeAll { $0.info.id == messageID }
        case "message.part.removed":
            guard let messageID = payload.properties.messageID,
                  let partID = payload.properties.partID,
                  let index = cachedMessages.firstIndex(where: { $0.info.id == messageID }) else {
                return nil
            }
            cachedMessages[index] = cachedMessages[index].removingPart(partID: partID)
        default:
            return nil
        }

        cachedMessagesBySessionID[sessionID] = cachedMessages
        return cachedMessages
    }

    func recentToolMessageIDs(in messages: [OpenCodeMessageEnvelope], limit: Int) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []

        for message in messages.reversed() {
            guard ids.count < limit else { break }
            guard message.parts.contains(where: { $0.type == "tool" }) else { continue }
            guard seen.insert(message.info.id).inserted else { continue }
            ids.append(message.info.id)
        }

        return ids
    }

    func reserveToolMessageDetailFetchIfNeeded(messageID: String) -> Bool {
        guard toolMessageDetails[messageID] == nil, !inFlightToolMessageDetailIDs.contains(messageID) else {
            return false
        }
        inFlightToolMessageDetailIDs.insert(messageID)
        return true
    }

    func finishToolMessageDetailFetch(messageID: String) {
        inFlightToolMessageDetailIDs.remove(messageID)
    }

    var hasPendingTranscriptEvents: Bool {
        !pendingTranscriptEvents.isEmpty
    }

    var pendingTranscriptCharacterCount: Int {
        pendingTranscriptEvents.reduce(0) { $0 + $1.deltaCharacterCount }
    }

    var currentAssistantTextLength: Int {
        Self.assistantTextLength(in: messages)
    }

    func streamDeltaCoalescingInterval(
        short: Duration,
        medium: Duration,
        long: Duration,
        veryLong: Duration
    ) -> Duration {
        Self.streamDeltaCoalescingInterval(
            currentAssistantTextLength: currentAssistantTextLength,
            pendingTranscriptCharacterCount: pendingTranscriptCharacterCount,
            short: short,
            medium: medium,
            long: long,
            veryLong: veryLong
        )
    }

    func beginFallbackRefreshTracking() {
        lastFallbackMessageCount = messages.count
        lastFallbackAssistantLength = currentAssistantTextLength
    }

    func fallbackRefreshSummary(reason: String) -> String {
        let compact = Self.compactAssistantText(in: messages)
        let messageDelta = messages.count - lastFallbackMessageCount
        let assistantLength = compact.count
        let lengthDelta = assistantLength - lastFallbackAssistantLength
        lastFallbackMessageCount = messages.count
        lastFallbackAssistantLength = assistantLength

        if compact.isEmpty {
            return "fallback \(reason) m=\(messages.count) dm=\(messageDelta) len=0 dlen=\(lengthDelta) a=empty"
        }

        return "fallback \(reason) m=\(messages.count) dm=\(messageDelta) len=\(assistantLength) dlen=\(lengthDelta) a=\(String(compact.prefix(24)))"
    }

    func enqueuePendingTranscriptEvent(_ event: OpenCodePendingTranscriptEvent) {
        pendingTranscriptEvents.append(event)
    }

    func drainPendingTranscriptEvents() -> (events: [OpenCodePendingTranscriptEvent], coalescedEvents: [OpenCodePendingTranscriptEvent])? {
        guard !pendingTranscriptEvents.isEmpty else { return nil }
        let events = pendingTranscriptEvents
        pendingTranscriptEvents = []
        return (events, Self.coalescedTranscriptEvents(events))
    }

    nonisolated static func shouldBufferTranscriptEvent(
        _ event: OpenCodeTypedEvent,
        selectedSessionID: String?,
        activeChatSessionID: String?
    ) -> Bool {
        guard let selectedSessionID else { return false }
        guard activeChatSessionID == selectedSessionID else { return false }

        switch event {
        case let .messagePartDelta(sessionID, _, _, _, _):
            return sessionID == selectedSessionID
        default:
            return false
        }
    }

    nonisolated static func shouldEmitStreamPartHaptic(
        for event: OpenCodeTypedEvent,
        selectedSessionID: String?,
        activeChatSessionID: String?,
        messages: [OpenCodeMessageEnvelope]
    ) -> Bool {
        guard let selectedSessionID else { return false }
        guard activeChatSessionID == selectedSessionID else { return false }

        switch event {
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            guard sessionID == selectedSessionID,
                  field == "text",
                  !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return isVisibleAssistantTextPart(
                messageID: messageID,
                partID: partID,
                sessionID: sessionID,
                messages: messages
            )
        default:
            return false
        }
    }

    nonisolated static func isVisibleAssistantTextPart(
        messageID: String,
        partID: String,
        sessionID: String,
        messages: [OpenCodeMessageEnvelope]
    ) -> Bool {
        guard let message = messages.first(where: {
            $0.id == messageID &&
                $0.info.sessionID == sessionID &&
                ($0.info.role ?? "").lowercased() == "assistant" &&
                !$0.info.isCompactionSummary
        }) else {
            return false
        }

        return message.parts.contains { part in
            part.id == partID && part.type == "text"
        }
    }

    nonisolated static func assistantTextLength(in messages: [OpenCodeMessageEnvelope]) -> Int {
        compactAssistantText(in: messages).count
    }

    nonisolated static func compactAssistantText(in messages: [OpenCodeMessageEnvelope]) -> String {
        let assistantText = messages
            .last(where: { ($0.info.role ?? "").lowercased() == "assistant" })?
            .parts
            .compactMap(\.text)
            .joined(separator: " ") ?? ""

        return assistantText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func streamDeltaCoalescingInterval(
        currentAssistantTextLength: Int,
        pendingTranscriptCharacterCount: Int,
        short: Duration,
        medium: Duration,
        long: Duration,
        veryLong: Duration
    ) -> Duration {
        let projectedLength = currentAssistantTextLength + pendingTranscriptCharacterCount

        if projectedLength >= 12_000 {
            return veryLong
        }
        if projectedLength >= 6_000 {
            return long
        }
        if projectedLength >= 2_500 {
            return medium
        }
        return short
    }

    nonisolated static func coalescedTranscriptEvents(_ events: [OpenCodePendingTranscriptEvent]) -> [OpenCodePendingTranscriptEvent] {
        var result: [OpenCodePendingTranscriptEvent] = []
        var order: [TranscriptDeltaKey] = []
        var accumulated: [TranscriptDeltaKey: (event: OpenCodePendingTranscriptEvent, delta: String, characterCount: Int, enqueuedAt: Date)] = [:]

        func flushAccumulated() {
            for key in order {
                guard let item = accumulated[key] else { continue }
                result.append(
                    OpenCodePendingTranscriptEvent(
                        typedEvent: .messagePartDelta(
                            sessionID: key.sessionID,
                            messageID: key.messageID,
                            partID: key.partID,
                            field: key.field,
                            delta: item.delta
                        ),
                        eventType: item.event.eventType,
                        sessionID: key.sessionID,
                        messageID: key.messageID,
                        partID: key.partID,
                        deltaCharacterCount: item.characterCount,
                        enqueuedAt: item.enqueuedAt
                    )
                )
            }
            order.removeAll(keepingCapacity: true)
            accumulated.removeAll(keepingCapacity: true)
        }

        for event in events {
            guard case let .messagePartDelta(sessionID, messageID, partID, field, delta) = event.typedEvent else {
                flushAccumulated()
                result.append(event)
                continue
            }

            let key = TranscriptDeltaKey(sessionID: sessionID, messageID: messageID, partID: partID, field: field)
            if var item = accumulated[key] {
                item.delta += delta
                item.characterCount += event.deltaCharacterCount
                item.enqueuedAt = min(item.enqueuedAt, event.enqueuedAt)
                accumulated[key] = item
            } else {
                order.append(key)
                accumulated[key] = (event, delta, event.deltaCharacterCount, event.enqueuedAt)
            }
        }

        flushAccumulated()
        return result
    }

    static func mergeMessagesPreservingStreamProgress(
        existing: [OpenCodeMessageEnvelope],
        loaded: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        return loaded.map { message in
            guard let existingMessage = existingByID[message.id] else {
                return message
            }

            return existingMessage.mergedWithCanonical(message)
        }
    }
}
