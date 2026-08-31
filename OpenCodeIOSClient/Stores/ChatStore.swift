import Combine
import Foundation

@MainActor
final class ChatStore: ObservableObject {
    private static let pendingTranscriptDeltaChunkLimit = 4_096
    let imageLoadingStore = OpenClientImageLoadingStore()
    let videoPlaybackStore = OpenClientVideoPlaybackStore()

    struct TranscriptDeltaKey: Hashable {
        let sessionID: String
        let messageID: String
        let partID: String
        let field: String
    }

    struct MessageHistoryState: Equatable {
        var nextCursor: String?
        var isComplete: Bool
        var isLoading: Bool
    }

    @Published var messages: [OpenCodeMessageEnvelope]
    @Published var cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]]
    @Published var toolMessageDetails: [String: OpenCodeMessageEnvelope]
    @Published var isLoadingSelectedSession: Bool
    @Published private(set) var preparedSessionID: String?
    @Published var activeChatSessionID: String?
    @Published private(set) var messageHistoryBySessionID: [String: MessageHistoryState]
    var inFlightToolMessageDetailIDs: Set<String>
    var nextStreamPartHapticAllowedAt: Date
    var pendingTranscriptEvents: [OpenCodePendingTranscriptEvent]
    private var pendingTranscriptCharacterTotal: Int
    private var pendingTranscriptOldestDate: Date?
    var streamDeltaFlushTask: Task<Void, Never>?
    var streamDeltaFlushGeneration: Int
    var streamDeltaLastFlushAt: Date?
    var streamDeltaScheduledIntervalMS: Int?
    var streamDeltaScheduledActiveTextLength: Int
    var streamDeltaScheduledPendingCharacterCount: Int

    init(
        messages: [OpenCodeMessageEnvelope] = [],
        cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]] = [:],
        toolMessageDetails: [String: OpenCodeMessageEnvelope] = [:],
        isLoadingSelectedSession: Bool = false,
        preparedSessionID: String? = nil,
        activeChatSessionID: String? = nil,
        messageHistoryBySessionID: [String: MessageHistoryState] = [:],
        inFlightToolMessageDetailIDs: Set<String> = [],
        nextStreamPartHapticAllowedAt: Date = .distantPast,
        pendingTranscriptEvents: [OpenCodePendingTranscriptEvent] = [],
        streamDeltaFlushTask: Task<Void, Never>? = nil,
        streamDeltaFlushGeneration: Int = 0,
        streamDeltaLastFlushAt: Date? = nil,
        streamDeltaScheduledIntervalMS: Int? = nil,
        streamDeltaScheduledActiveTextLength: Int = 0,
        streamDeltaScheduledPendingCharacterCount: Int = 0
    ) {
        self.messages = messages
        self.cachedMessagesBySessionID = cachedMessagesBySessionID
        self.toolMessageDetails = toolMessageDetails
        self.isLoadingSelectedSession = isLoadingSelectedSession
        self.preparedSessionID = preparedSessionID
        self.activeChatSessionID = activeChatSessionID
        self.messageHistoryBySessionID = messageHistoryBySessionID
        self.inFlightToolMessageDetailIDs = inFlightToolMessageDetailIDs
        self.nextStreamPartHapticAllowedAt = nextStreamPartHapticAllowedAt
        self.pendingTranscriptEvents = pendingTranscriptEvents
        self.pendingTranscriptCharacterTotal = pendingTranscriptEvents.reduce(0) { $0 + $1.deltaCharacterCount }
        self.pendingTranscriptOldestDate = pendingTranscriptEvents.map(\.enqueuedAt).min()
        self.streamDeltaFlushTask = streamDeltaFlushTask
        self.streamDeltaFlushGeneration = streamDeltaFlushGeneration
        self.streamDeltaLastFlushAt = streamDeltaLastFlushAt
        self.streamDeltaScheduledIntervalMS = streamDeltaScheduledIntervalMS
        self.streamDeltaScheduledActiveTextLength = streamDeltaScheduledActiveTextLength
        self.streamDeltaScheduledPendingCharacterCount = streamDeltaScheduledPendingCharacterCount
    }

    func resetActiveSession() {
        messages = []
        isLoadingSelectedSession = false
        preparedSessionID = nil
        clearPendingTranscriptEvents()
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil
        streamDeltaFlushGeneration &+= 1
        streamDeltaLastFlushAt = nil
        streamDeltaScheduledIntervalMS = nil
        streamDeltaScheduledActiveTextLength = 0
        streamDeltaScheduledPendingCharacterCount = 0
    }

    func beginSelectingSession(sessionID: String, cachedMessages: [OpenCodeMessageEnvelope]) {
        if preparedSessionID != sessionID {
            clearPendingTranscriptEvents()
            streamDeltaFlushTask?.cancel()
            streamDeltaFlushTask = nil
            streamDeltaFlushGeneration &+= 1
        }
        if !isLoadingSelectedSession {
            isLoadingSelectedSession = true
        }
        if messages != cachedMessages {
            messages = cachedMessages
        }
        if preparedSessionID != sessionID {
            preparedSessionID = sessionID
        }
    }

    func clearActiveTranscript() {
        messages = []
        isLoadingSelectedSession = false
        preparedSessionID = nil
    }

    func finishLoadingSelectedSession() {
        if isLoadingSelectedSession {
            isLoadingSelectedSession = false
        }
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

    func replaceActiveMessagesWithCanonical(_ loadedMessages: [OpenCodeMessageEnvelope]) {
        let canonicalMessages = Self.deduplicatedMessages(loadedMessages)
        if messages != canonicalMessages {
            messages = canonicalMessages
        }
    }

    func applyCanonicalMessages(_ loadedMessages: [OpenCodeMessageEnvelope], forSessionID sessionID: String, isActiveSession: Bool) {
        let deduplicatedMessages = Self.deduplicatedMessages(loadedMessages)
        let canonicalMessages = isActiveSession
            ? mergingCanonicalMessages(deduplicatedMessages, withExistingMessages: messages)
            : deduplicatedMessages

        cacheMessages(canonicalMessages, forSessionID: sessionID)
        guard isActiveSession else { return }
        replaceActiveMessagesWithCanonical(canonicalMessages)
        finishLoadingSelectedSession()
    }

    func applyMessageHistoryPage(nextCursor: String?, forSessionID sessionID: String) {
        messageHistoryBySessionID[sessionID] = MessageHistoryState(
            nextCursor: nextCursor,
            isComplete: nextCursor == nil,
            isLoading: false
        )
    }

    func beginLoadingOlderMessages(forSessionID sessionID: String) -> String? {
        guard var state = messageHistoryBySessionID[sessionID],
              !state.isComplete,
              !state.isLoading,
              let cursor = state.nextCursor else { return nil }
        state.isLoading = true
        messageHistoryBySessionID[sessionID] = state
        return cursor
    }

    func failLoadingOlderMessages(forSessionID sessionID: String) {
        guard var state = messageHistoryBySessionID[sessionID], state.isLoading else { return }
        state.isLoading = false
        messageHistoryBySessionID[sessionID] = state
    }

    func hasOlderMessages(forSessionID sessionID: String) -> Bool {
        guard let state = messageHistoryBySessionID[sessionID] else { return false }
        return !state.isComplete && state.nextCursor != nil
    }

    func isLoadingOlderMessages(forSessionID sessionID: String) -> Bool {
        messageHistoryBySessionID[sessionID]?.isLoading ?? false
    }

    private func mergingCanonicalMessages(
        _ canonicalMessages: [OpenCodeMessageEnvelope],
        withExistingMessages existingMessages: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        var existingByID: [String: OpenCodeMessageEnvelope] = [:]
        for message in existingMessages {
            existingByID[message.id] = message
        }

        return canonicalMessages.map { canonical in
            guard let existing = existingByID[canonical.id] else { return canonical }
            var existingPartsByID: [String: OpenCodePart] = [:]
            for part in existing.parts {
                if let partID = part.id {
                    existingPartsByID[partID] = part
                }
            }

            var merged = canonical
            merged.parts = canonical.parts.map { canonicalPart in
                guard let partID = canonicalPart.id,
                      let existingPart = existingPartsByID[partID],
                      let existingText = existingPart.text,
                      !existingText.isEmpty else {
                    return canonicalPart
                }

                guard let canonicalText = canonicalPart.text,
                      !canonicalText.isEmpty else {
                    var part = canonicalPart
                    part.text = existingText
                    return part
                }

                guard existingText.hasPrefix(canonicalText) else {
                    return canonicalPart
                }

                var part = canonicalPart
                part.text = existingText
                return part
            }
            return merged
        }
    }

    func cacheMessages(_ messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) {
        let canonicalMessages = Self.deduplicatedMessages(messages)
        if cachedMessagesBySessionID[sessionID] != canonicalMessages {
            cachedMessagesBySessionID[sessionID] = canonicalMessages
        }
    }

    nonisolated static func mergingCanonicalMessagePage(
        _ page: [OpenCodeMessageEnvelope],
        into existingMessages: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        var merged = deduplicatedMessages(existingMessages)
        var indexByID = Dictionary(uniqueKeysWithValues: merged.indices.map { (merged[$0].id, $0) })
        for message in deduplicatedMessages(page) {
            if let index = indexByID[message.id] {
                merged[index] = message
            } else {
                indexByID[message.id] = merged.count
                merged.append(message)
            }
        }
        return merged.sorted {
            OpenCodeMessage.isOrderedBefore($0.info, $1.info)
        }
    }

    nonisolated private static func deduplicatedMessages(_ messages: [OpenCodeMessageEnvelope]) -> [OpenCodeMessageEnvelope] {
        var result: [OpenCodeMessageEnvelope] = []
        var messageIndexByID: [String: Int] = [:]
        for var message in messages {
            var parts: [OpenCodePart] = []
            var partIndexByID: [String: Int] = [:]
            for part in message.parts {
                guard let partID = part.id else {
                    parts.append(part)
                    continue
                }
                if let index = partIndexByID[partID] {
                    parts[index] = part
                } else {
                    partIndexByID[partID] = parts.count
                    parts.append(part)
                }
            }
            message.parts = parts

            if let index = messageIndexByID[message.id] {
                result[index] = message
            } else {
                messageIndexByID[message.id] = result.count
                result.append(message)
            }
        }
        return result.sorted {
            OpenCodeMessage.isOrderedBefore($0.info, $1.info)
        }
    }

    func clearCachedMessages(forSessionID sessionID: String) {
        cachedMessagesBySessionID[sessionID] = nil
        messageHistoryBySessionID[sessionID] = nil
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

    var pendingTranscriptEventCount: Int {
        pendingTranscriptEvents.count
    }

    var pendingTranscriptCharacterCount: Int {
        pendingTranscriptCharacterTotal
    }

    var pendingTranscriptOldestEnqueuedAt: Date? {
        pendingTranscriptOldestDate
    }

    var currentAssistantTextLength: Int {
        Self.assistantTextLength(in: messages)
    }

    func streamDeltaCoalescingInterval(
        syncState: OpenCodeDirectorySyncState,
        short: Duration,
        medium: Duration,
        long: Duration,
        veryLong: Duration
    ) -> Duration {
        Self.streamDeltaCoalescingInterval(
            currentAssistantTextLength: Self.activePendingTranscriptTextLength(pendingTranscriptEvents, in: syncState),
            pendingTranscriptCharacterCount: pendingTranscriptCharacterCount,
            short: short,
            medium: medium,
            long: long,
            veryLong: veryLong
        )
    }

    func streamDeltaCoalescingInputLengths(syncState: OpenCodeDirectorySyncState) -> (activeTextLength: Int, pendingCharacterCount: Int) {
        (
            Self.activePendingTranscriptTextLength(pendingTranscriptEvents, in: syncState),
            pendingTranscriptCharacterCount
        )
    }

    func enqueuePendingTranscriptEvent(_ event: OpenCodePendingTranscriptEvent) {
        if let index = pendingTranscriptEvents.indices.last,
           case let .messagePartDelta(previousSessionID, previousMessageID, previousPartID, previousField, previousDelta) = pendingTranscriptEvents[index].typedEvent,
           case let .messagePartDelta(sessionID, messageID, partID, field, delta) = event.typedEvent,
           previousSessionID == sessionID,
           previousMessageID == messageID,
           previousPartID == partID,
           previousField == field,
           pendingTranscriptEvents[index].deltaCharacterCount + event.deltaCharacterCount <= Self.pendingTranscriptDeltaChunkLimit {
            let previous = pendingTranscriptEvents[index]
            pendingTranscriptEvents[index] = OpenCodePendingTranscriptEvent(
                typedEvent: .messagePartDelta(
                    sessionID: sessionID,
                    messageID: messageID,
                    partID: partID,
                    field: field,
                    delta: previousDelta + delta
                ),
                eventType: event.eventType,
                sessionID: event.sessionID,
                messageID: event.messageID,
                partID: event.partID,
                deltaCharacterCount: previous.deltaCharacterCount + event.deltaCharacterCount,
                enqueuedAt: previous.enqueuedAt
            )
            pendingTranscriptCharacterTotal += event.deltaCharacterCount
            return
        }

        pendingTranscriptEvents.append(event)
        pendingTranscriptCharacterTotal += event.deltaCharacterCount
        if pendingTranscriptOldestDate == nil || event.enqueuedAt < pendingTranscriptOldestDate! {
            pendingTranscriptOldestDate = event.enqueuedAt
        }
    }

    @discardableResult
    func enqueuePendingTranscriptEventIfAvailable(
        _ event: OpenCodePendingTranscriptEvent,
        in syncState: OpenCodeDirectorySyncState
    ) -> Bool {
        guard Self.canDrainPendingTranscriptEvent(event, in: syncState) else { return false }
        enqueuePendingTranscriptEvent(event)
        return true
    }

    func replacePendingTranscriptEvents(_ events: [OpenCodePendingTranscriptEvent]) {
        pendingTranscriptEvents = events
        pendingTranscriptCharacterTotal = events.reduce(0) { $0 + $1.deltaCharacterCount }
        pendingTranscriptOldestDate = events.map(\.enqueuedAt).min()
    }

    func clearPendingTranscriptEvents() {
        pendingTranscriptEvents = []
        pendingTranscriptCharacterTotal = 0
        pendingTranscriptOldestDate = nil
    }

    func drainPendingTranscriptEvents() -> (events: [OpenCodePendingTranscriptEvent], coalescedEvents: [OpenCodePendingTranscriptEvent])? {
        guard !pendingTranscriptEvents.isEmpty else { return nil }
        let events = pendingTranscriptEvents
        clearPendingTranscriptEvents()
        return (events, Self.coalescedTranscriptEvents(events))
    }

    func drainAvailablePendingTranscriptEvents(
        in syncState: OpenCodeDirectorySyncState
    ) -> (events: [OpenCodePendingTranscriptEvent], coalescedEvents: [OpenCodePendingTranscriptEvent])? {
        guard !pendingTranscriptEvents.isEmpty else { return nil }

        var drainCount = 0
        for event in pendingTranscriptEvents {
            guard Self.canDrainPendingTranscriptEvent(event, in: syncState) else {
                break
            }
            drainCount += 1
        }

        guard drainCount > 0 else { return nil }
        let drained = Array(pendingTranscriptEvents.prefix(drainCount))
        pendingTranscriptEvents.removeFirst(drainCount)
        pendingTranscriptCharacterTotal -= drained.reduce(0) { $0 + $1.deltaCharacterCount }
        pendingTranscriptOldestDate = pendingTranscriptEvents.map(\.enqueuedAt).min()
        guard !drained.isEmpty else { return nil }
        return (drained, Self.coalescedTranscriptEvents(drained))
    }

    nonisolated static func canDrainPendingTranscriptEvent(
        _ event: OpenCodePendingTranscriptEvent,
        in syncState: OpenCodeDirectorySyncState
    ) -> Bool {
        guard case let .messagePartDelta(_, messageID, partID, _, _) = event.typedEvent else {
            return true
        }

        return syncState.partsByMessageID[messageID]?.contains(where: { $0.id == partID }) == true
    }

    nonisolated static func shouldBufferTranscriptEvent(
        _ event: OpenCodeTypedEvent,
        selectedSessionID: String?,
        activeChatSessionID _: String?
    ) -> Bool {
        guard let selectedSessionID else { return false }

        switch event {
        case let .messagePartDelta(sessionID, _, _, field, _):
            return sessionID == selectedSessionID && field == "text"
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

    nonisolated static func activePendingTranscriptTextLength(
        _ events: [OpenCodePendingTranscriptEvent],
        in syncState: OpenCodeDirectorySyncState
    ) -> Int {
        guard let target = events.reversed().first(where: { $0.messageID != nil && $0.partID != nil }),
              let messageID = target.messageID,
              let partID = target.partID else {
            return 0
        }

        return syncState.partsByMessageID[messageID]?
            .first(where: { $0.id == partID })?
            .text?
            .count ?? 0
    }

    nonisolated static func compactAssistantText(in messages: [OpenCodeMessageEnvelope]) -> String {
        let assistantText = messages
            .last(where: { ($0.info.role ?? "").lowercased() == "assistant" && $0.info.time?.completed == nil })?
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
        var accumulated: (key: TranscriptDeltaKey, event: OpenCodePendingTranscriptEvent, delta: String, characterCount: Int, enqueuedAt: Date)?

        func flushAccumulated() {
            guard let item = accumulated else { return }
            result.append(
                OpenCodePendingTranscriptEvent(
                    typedEvent: .messagePartDelta(
                        sessionID: item.key.sessionID,
                        messageID: item.key.messageID,
                        partID: item.key.partID,
                        field: item.key.field,
                        delta: item.delta
                    ),
                    eventType: item.event.eventType,
                    sessionID: item.key.sessionID,
                    messageID: item.key.messageID,
                    partID: item.key.partID,
                    deltaCharacterCount: item.characterCount,
                    enqueuedAt: item.enqueuedAt
                )
            )
            accumulated = nil
        }

        for event in events {
            guard case let .messagePartDelta(sessionID, messageID, partID, field, delta) = event.typedEvent else {
                flushAccumulated()
                result.append(event)
                continue
            }

            let key = TranscriptDeltaKey(sessionID: sessionID, messageID: messageID, partID: partID, field: field)
            if var item = accumulated, item.key == key {
                item.delta += delta
                item.characterCount += event.deltaCharacterCount
                item.enqueuedAt = min(item.enqueuedAt, event.enqueuedAt)
                accumulated = item
            } else {
                flushAccumulated()
                accumulated = (key, event, delta, event.deltaCharacterCount, event.enqueuedAt)
            }
        }

        flushAccumulated()
        return result
    }
}
