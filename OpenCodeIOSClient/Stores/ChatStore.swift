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

    struct V2TranscriptState: Equatable, Sendable {
        var olderCursor: String? = nil
        var isLoadingOlder = false
        var hasLoadedInitial = false
    }

    struct SubmissionRecovery: Equatable, Sendable, Identifiable {
        enum Phase: Equatable, Sendable { case submitting, uncertain, admitted, cancelled }
        let sessionID: String
        let message: OpenCodeMessageEnvelope
        var phase: Phase
        var pendingStatusUnknown = false
        var attachments: [OpenCodeComposerAttachment] = []
        var agentMentions: [OpenCodeAgentMention] = []
        var submittedAt: Date = .distantPast
        // Presentation anchors include prior local submissions, never admission evidence.
        var precedingMessageIDs: [String] = []
        var id: String { message.id }
        var text: String { message.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n") }

        func canBeReplaced(by canonical: OpenCodeMessageEnvelope, completeInventory: Bool = false) -> Bool {
            guard canonical.id == id, canonical.info.role == "user", canonical.info.sessionID == sessionID else { return false }
            let text = canonical.parts.first { $0.type == "text" && $0.synthetic != true }?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let files = canonical.parts.filter { $0.type == "file" && $0.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count
            guard !text.isEmpty || files > 0 else { return false }
            // A full HTTP inventory can omit a submitted category. Live part events cannot.
            if completeInventory { return true }
            let expectedFiles = max(attachments.count, message.parts.filter { $0.type == "file" }.count)
            return (self.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !text.isEmpty)
                && files >= expectedFiles
        }
    }

    struct PromptAdmission: Equatable, Sendable {
        enum Phase: Equatable, Sendable { case submitting, uncertain, admitted, rejected, cancelled }
        let connectionID: UUID
        let sessionID: String
        let text: String
        let agentMentions: [OpenCodeAgentMention]
        let attachments: [OpenCodeComposerAttachment]
        var phase: Phase
    }

    @Published private(set) var promptAdmissions: [String: PromptAdmission] = [:]

    func promptAdmissionPhase(messageID: String, sessionID: String, connectionID: UUID) -> PromptAdmission.Phase? {
        guard let admission = promptAdmissions[messageID], admission.connectionID == connectionID,
              admission.sessionID == sessionID else { return nil }
        return admission.phase
    }

    func hasPendingPromptAdmission(sessionID: String, connectionID: UUID) -> Bool {
        promptAdmissions.values.contains {
            $0.connectionID == connectionID && $0.sessionID == sessionID && ($0.phase == .submitting || $0.phase == .uncertain)
        }
    }

    func beginPromptAdmission(_ request: BackendSubmission, connectionID: UUID) -> Bool {
        guard !hasPendingPromptAdmission(sessionID: request.sessionID, connectionID: connectionID),
               !submissionRecoveries.values.contains(where: { $0.sessionID == request.sessionID && ($0.phase == .submitting || $0.phase == .uncertain) }),
               canonicalSubmissionSessions[request.messageID] != request.sessionID,
               promptAdmissions[request.messageID]?.connectionID != connectionID else { return false }
        promptAdmissions = promptAdmissions.filter { $0.value.connectionID == connectionID }
        promptAdmissions[request.messageID] = PromptAdmission(connectionID: connectionID, sessionID: request.sessionID,
            text: request.text, agentMentions: request.agentMentions, attachments: request.attachments, phase: .submitting)
        if submissionConnectionID == connectionID, submissionOwner != nil, submissionRecoveries[request.messageID] == nil,
           canonicalSubmissionSessions[request.messageID] != request.sessionID {
            let message = OpenCodeMessageEnvelope.local(role: "user", text: request.text,
                agentMentions: request.agentMentions, attachments: request.attachments,
                messageID: request.messageID, sessionID: request.sessionID)
            let presentation = stagedSubmissionPresentations[request.messageID]
            submissionRecoveries[request.messageID] = SubmissionRecovery(sessionID: request.sessionID, message: message,
                phase: .submitting, attachments: request.attachments, agentMentions: request.agentMentions,
                submittedAt: presentation?.submittedAt ?? .now,
                precedingMessageIDs: presentation?.precedingMessageIDs ??
                    ((cachedMessagesBySessionID[request.sessionID] ?? messages.filter { $0.info.sessionID == request.sessionID }).map(\.id)
                         + recoveryInputs(sessionID: request.sessionID).map(\.id)))
            stagedSubmissionPresentations[request.messageID] = nil
            if let cached = cachedMessagesBySessionID[request.sessionID] {
                cacheMessages(cached, forSessionID: request.sessionID)
            }
            messages = withoutRecoveryMessages(messages, sessionID: request.sessionID)
        }
        return true
    }

    @discardableResult
    func applyPromptAdmission(_ phase: PromptAdmission.Phase, messageID: String, connectionID: UUID) -> PromptAdmission.Phase? {
        guard var admission = promptAdmissions[messageID], admission.connectionID == connectionID else { return nil }
        // Exact canonical evidence wins over a conflicting response or a cancelled request's defer.
        guard admission.phase != .admitted && admission.phase != .rejected && admission.phase != .cancelled else { return admission.phase }
        admission.phase = phase
        promptAdmissions[messageID] = admission
        if submissionConnectionID == connectionID, submissionRecoveries[messageID]?.sessionID == admission.sessionID {
            switch phase {
            case .admitted: confirmSubmissionAdmission(messageID: messageID, sessionID: admission.sessionID)
            case .uncertain: markSubmissionUncertain(messageID: messageID, sessionID: admission.sessionID)
            case .rejected: rollbackV2Prompt(messageID: messageID, sessionID: admission.sessionID)
            case .cancelled: removeSubmissionPresentation(messageID: messageID, sessionID: admission.sessionID)
            case .submitting: break
            }
        }
        return phase
    }

    /// Call only with canonical server input, never with merged transcripts or optimistic cache rows.
    @discardableResult
    func confirmPromptAdmission(from message: OpenCodeMessage, connectionID: UUID) -> Bool {
        guard message.role?.lowercased() == "user", var admission = promptAdmissions[message.id],
              admission.connectionID == connectionID, admission.sessionID == message.sessionID else { return false }
        admission.phase = .admitted
        promptAdmissions[message.id] = admission
        return true
    }

    @Published var messages: [OpenCodeMessageEnvelope]
    @Published var cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]]
    @Published var toolMessageDetails: [String: OpenCodeMessageEnvelope]
    @Published var isLoadingSelectedSession: Bool
    @Published private(set) var preparedSessionID: String?
    @Published var activeChatSessionID: String?
    @Published private(set) var messageHistoryBySessionID: [String: MessageHistoryState]
    @Published private(set) var v2TranscriptStates: [String: V2TranscriptState] = [:]
    @Published private(set) var submissionRecoveries: [String: SubmissionRecovery] = [:]
    @Published private(set) var stagedSubmissionPresentations: [String: SubmissionRecovery] = [:]
    @Published private(set) var canonicalSubmissionSessions: [String: String] = [:]
    private var submissionOwner: String?
    private var submissionConnectionID: UUID?
    private var recoveryByOwner: [String: (inputs: [String: SubmissionRecovery], canonical: [String: String])] = [:]

    // Recovery survives a server reconnect in this process, not an app process restart.
    func selectSubmissionOwner(_ owner: String?, connectionID: UUID? = nil) {
        stagedSubmissionPresentations = [:]
        submissionConnectionID = connectionID
        for (id, input) in submissionRecoveries where input.phase == .submitting {
            markSubmissionUncertain(messageID: id, sessionID: input.sessionID)
        }
        guard owner != submissionOwner else { return }
        if let previous = submissionOwner {
            recoveryByOwner[previous] = (submissionRecoveries, canonicalSubmissionSessions)
        }
        if submissionOwner != nil || !recoveryByOwner.isEmpty {
            resetActiveSession()
            cachedMessagesBySessionID = [:]
            v2TranscriptStates = [:]
            v2AdmittedInputsByID = [:]
            v2StreamRevisionsBySessionID = [:]
            v2EndedPartIDs = [:]
            v2LiveTextPartIDs = [:]
        }
        submissionOwner = owner
        let saved = owner.flatMap { recoveryByOwner.removeValue(forKey: $0) }
        canonicalSubmissionSessions = saved?.canonical ?? [:]
        submissionRecoveries = saved?.inputs ?? [:]
    }

    func recoveryInputs(sessionID: String) -> [SubmissionRecovery] {
        let inputs = stagedSubmissionPresentations.merging(submissionRecoveries) { _, recovery in recovery }
        return inputs.values.filter { $0.sessionID == sessionID }.sorted { ($0.submittedAt, $0.id) < ($1.submittedAt, $1.id) }
    }

    /// Captures UI position before async preparation, without reserving or proving admission.
    func stageSubmissionPresentation(_ message: OpenCodeMessageEnvelope, sessionID: String,
                                     canonical: [OpenCodeMessageEnvelope], attachments: [OpenCodeComposerAttachment],
                                     agentMentions: [OpenCodeAgentMention], submittedAt: Date = .now) {
        guard submissionRecoveries[message.id] == nil, stagedSubmissionPresentations[message.id] == nil,
              canonicalSubmissionSessions[message.id] != sessionID else { return }
        stagedSubmissionPresentations[message.id] = SubmissionRecovery(sessionID: sessionID, message: message,
            phase: .submitting, attachments: attachments, agentMentions: agentMentions,
            submittedAt: submittedAt,
            precedingMessageIDs: canonical.map(\.id) + recoveryInputs(sessionID: sessionID).map(\.id))
    }

    func discardStagedSubmissionPresentation(messageID: String) {
        // A started request must always have a successor before its task drops staging.
        if let staged = stagedSubmissionPresentations[messageID], submissionRecoveries[messageID] == nil,
           let admission = promptAdmissions[messageID], admission.sessionID == staged.sessionID,
           admission.connectionID == submissionConnectionID,
           admission.phase != .rejected, admission.phase != .cancelled {
            var recovery = staged
            recovery.phase = admission.phase == .admitted ? .admitted : admission.phase == .uncertain ? .uncertain : .submitting
            submissionRecoveries[messageID] = recovery
        }
        stagedSubmissionPresentations[messageID] = nil
    }

    /// Call after committing the canonical envelopes to the directory and active presentation sources.
    func retireSubmissionPresentations(in committed: [OpenCodeMessageEnvelope], sessionID: String, completeInventory: Bool = false) {
        for message in committed where canonicalSubmissionSessions[message.id] == sessionID {
            guard let input = submissionRecoveries[message.id] ?? stagedSubmissionPresentations[message.id],
                  input.sessionID == sessionID, input.canBeReplaced(by: message, completeInventory: completeInventory) else { continue }
            stagedSubmissionPresentations[message.id] = nil
            submissionRecoveries[message.id] = nil
        }
    }

    func removeSubmissionPresentation(messageID: String, sessionID: String) {
        if stagedSubmissionPresentations[messageID]?.sessionID == sessionID { stagedSubmissionPresentations[messageID] = nil }
        if submissionRecoveries[messageID]?.sessionID == sessionID { submissionRecoveries[messageID] = nil }
    }

    /// Strip only this owner's local IDs; exact canonical evidence always wins.
    func withoutRecoveryMessages(_ messages: [OpenCodeMessageEnvelope], sessionID: String) -> [OpenCodeMessageEnvelope] {
        messages.filter { message in
            submissionRecoveries[message.id]?.sessionID != sessionID
                || canonicalSubmissionSessions[message.id] == sessionID
        }
    }

    var v2PromptInFlightSessionIDs: Set<String> {
        Set(submissionRecoveries.values.filter { $0.phase == .submitting || $0.phase == .uncertain }.map(\.sessionID))
    }
    private var v2AdmittedInputsByID: [String: OpenCodeMessageEnvelope] = [:]
    private var v2StreamRevisionsBySessionID: [String: Int] = [:]
    private struct V2CanonicalRead {
        let id: UUID
        var pending = true
        var needsRetry: Bool
        var retried: Bool
    }
    private var v2CanonicalReads: [String: V2CanonicalRead] = [:]
    private var v2HydratingSessionID: String?
    private var v2HydrationRevision = 0
    private var v2EndedPartIDs: [String: Set<String>] = [:]
    private var v2LiveTextPartIDs: [String: Set<String>] = [:]
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
        v2CanonicalReads.removeAll()
        v2HydratingSessionID = nil
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

    func beginV2TranscriptHydration(sessionID: String, preservingCanonicalRead: Bool = false) {
        if !preservingCanonicalRead { v2CanonicalReads[sessionID] = nil }
        v2HydratingSessionID = sessionID
        v2HydrationRevision = v2StreamRevision(sessionID: sessionID)
        isLoadingSelectedSession = true
        preparedSessionID = nil
        messages = []
        v2TranscriptStates[sessionID] = V2TranscriptState(olderCursor: nil, hasLoadedInitial: false)
        v2AdmittedInputsByID = v2AdmittedInputsByID.filter { $0.value.info.sessionID != sessionID }
    }

    @discardableResult
    func applyInitialV2Transcript(
        _ loadedMessages: [OpenCodeMessageEnvelope],
        olderCursor: String?,
        sessionID: String,
        expectedStreamRevision: Int? = nil
    ) -> Bool {
        guard v2HydratingSessionID == sessionID,
              v2StreamRevision(sessionID: sessionID) == (expectedStreamRevision ?? v2HydrationRevision) else { return false }
        reconcileV2PromptAdmissions(in: loadedMessages, sessionID: sessionID)
        let canonical = Self.deduplicatedMessages(preservingV2LiveText(loadedMessages, sessionID: sessionID), preservingOrder: true)
        v2HydratingSessionID = nil
        messages = canonical
        cacheMessages(canonical, forSessionID: sessionID)
        v2TranscriptStates[sessionID] = V2TranscriptState(
            olderCursor: loadedMessages.isEmpty ? nil : olderCursor,
            isLoadingOlder: false,
            hasLoadedInitial: true
        )
        preparedSessionID = sessionID
        isLoadingSelectedSession = false
        return true
    }

    func failV2TranscriptHydration(sessionID: String) {
        guard v2HydratingSessionID == sessionID else { return }
        v2HydratingSessionID = nil
        isLoadingSelectedSession = false
        v2TranscriptStates[sessionID] = nil
    }

    func beginLoadingOlderV2Messages(sessionID: String) -> String? {
        guard var state = v2TranscriptStates[sessionID],
              !state.isLoadingOlder,
              let cursor = state.olderCursor else { return nil }
        state.isLoadingOlder = true
        v2TranscriptStates[sessionID] = state
        return cursor
    }

    func applyOlderV2Transcript(
        _ olderMessages: [OpenCodeMessageEnvelope],
        olderCursor: String?,
        requestedCursor: String,
        sessionID: String
    ) {
        guard v2TranscriptStates[sessionID]?.isLoadingOlder == true,
              v2TranscriptStates[sessionID]?.olderCursor == requestedCursor else { return }
        reconcileV2PromptAdmissions(in: olderMessages, sessionID: sessionID)
        let canonicalIDs = Set(olderMessages.map(\.id))
        let existing = withoutRecoveryMessages(cachedMessagesBySessionID[sessionID] ?? [], sessionID: sessionID)
            .filter { !canonicalIDs.contains($0.id) }
        let merged = Self.deduplicatedMessages(olderMessages + existing, preservingOrder: true)
        cacheMessages(merged, forSessionID: sessionID)
        if preparedSessionID == sessionID {
            messages = merged
        }
        v2TranscriptStates[sessionID] = V2TranscriptState(
            olderCursor: olderMessages.isEmpty || olderCursor == requestedCursor ? nil : olderCursor,
            isLoadingOlder: false,
            hasLoadedInitial: true
        )
    }

    func failLoadingOlderV2Messages(sessionID: String) {
        guard var state = v2TranscriptStates[sessionID] else { return }
        state.isLoadingOlder = false
        v2TranscriptStates[sessionID] = state
    }

    func hasOlderV2Messages(sessionID: String) -> Bool {
        v2TranscriptStates[sessionID]?.olderCursor != nil
    }

    func isLoadingOlderV2Messages(sessionID: String) -> Bool {
        v2TranscriptStates[sessionID]?.isLoadingOlder == true
    }

    func beginV2Prompt(_ message: OpenCodeMessageEnvelope, sessionID: String,
                       attachments: [OpenCodeComposerAttachment] = [], agentMentions: [OpenCodeAgentMention] = []) -> Bool {
        guard message.info.sessionID == sessionID, !v2PromptInFlightSessionIDs.contains(sessionID),
               submissionRecoveries[message.id] == nil, canonicalSubmissionSessions[message.id] != sessionID else { return false }
        let presentation = stagedSubmissionPresentations[message.id]
        submissionRecoveries[message.id] = SubmissionRecovery(sessionID: sessionID, message: message, phase: .submitting,
            attachments: attachments, agentMentions: agentMentions, submittedAt: presentation?.submittedAt ?? .now,
            precedingMessageIDs: presentation?.precedingMessageIDs ??
                ((cachedMessagesBySessionID[sessionID] ?? messages.filter { $0.info.sessionID == sessionID }).map(\.id)
                     + recoveryInputs(sessionID: sessionID).map(\.id)))
        stagedSubmissionPresentations[message.id] = nil
        return true
    }

    func rollbackV2Prompt(messageID: String, sessionID: String) {
        guard canonicalSubmissionSessions[messageID] != sessionID else { return }
        var transcript = cachedMessagesBySessionID[sessionID] ?? []
        transcript.removeAll { $0.id == messageID }
        cacheMessages(transcript, forSessionID: sessionID)
        if preparedSessionID == sessionID { messages = transcript }
        if submissionRecoveries[messageID]?.sessionID == sessionID { submissionRecoveries[messageID] = nil }
    }

    func reconcileV2NewestPage(
        _ newestPage: [OpenCodeMessageEnvelope],
        olderCursor: String?,
        optimisticMessage _: OpenCodeMessageEnvelope,
        sessionID: String
    ) {
        applyV2EventProjection(newestPage, olderCursor: olderCursor, sessionID: sessionID)
    }

    func applyV2EventProjection(
        _ newestPage: [OpenCodeMessageEnvelope],
        olderCursor: String?,
        sessionID: String
    ) {
        if v2HydratingSessionID == sessionID {
            applyInitialV2Transcript(newestPage, olderCursor: olderCursor, sessionID: sessionID,
                expectedStreamRevision: v2StreamRevision(sessionID: sessionID))
            return
        }
        reconcileV2PromptAdmissions(in: newestPage, sessionID: sessionID)
        let existing = withoutRecoveryMessages(cachedMessagesBySessionID[sessionID] ?? [], sessionID: sessionID)
        // An overlap at the first canonical row proves continuity. With no anchor,
        // the old prefix may have been reverted while disconnected; reload it by cursor.
        let anchor = newestPage.first.flatMap { first in existing.firstIndex { $0.id == first.id } }
        let prefix = olderCursor == nil ? existing.prefix(0) : existing.prefix(anchor ?? 0)
        var reconciled = preservingV2LiveText(Array(prefix) + newestPage, sessionID: sessionID)

        reconciled = Self.deduplicatedMessages(reconciled, preservingOrder: true)
        cacheMessages(reconciled, forSessionID: sessionID)
        if preparedSessionID == sessionID {
            messages = reconciled
        }
        var state = v2TranscriptStates[sessionID] ?? V2TranscriptState()
        if prefix.isEmpty || !state.hasLoadedInitial || olderCursor == nil { state.olderCursor = newestPage.isEmpty ? nil : olderCursor }
        state.hasLoadedInitial = true
        v2TranscriptStates[sessionID] = state
    }

    private func preservingV2LiveText(_ incoming: [OpenCodeMessageEnvelope], sessionID: String) -> [OpenCodeMessageEnvelope] {
        guard let liveIDs = v2LiveTextPartIDs[sessionID], !liveIDs.isEmpty else { return incoming }
        let previous = Dictionary((cachedMessagesBySessionID[sessionID] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var unfinishedIDs = Set<String>()
        let result = incoming.map { message in
            guard message.info.time?.completed == nil, let live = previous[message.id], live.info.time?.completed == nil else { return message }
            var message = message
            for index in message.parts.indices {
                let part = message.parts[index]
                guard let id = part.id, liveIDs.contains(id), part.time?.end == nil,
                      v2EndedPartIDs[sessionID]?.contains(id) != true,
                      ["text", "reasoning"].contains(part.type),
                      let streamed = live.parts.first(where: { $0.id == id && $0.type == part.type }),
                      streamed.time?.end == nil else { continue }
                unfinishedIDs.insert(id)
                guard part.text == "", let text = streamed.text, !text.isEmpty else { continue }
                // next-17155 persists the text body at part end, after live deltas.
                message.parts[index].text = text
            }
            return message
        }
        v2LiveTextPartIDs[sessionID]?.formIntersection(unfinishedIDs)
        return result
    }

    @discardableResult
    func applyV2StreamEvent(_ event: OpenCodeV2ManagedEvent, sessionID: String) -> Bool {
        guard event.sessionID == sessionID,
              let data = event.data.objectValue else { return false }

        let messageID = data["assistantMessageID"]?.literalStringValue
        let original = cachedMessagesBySessionID[sessionID] ?? []
        var transcript = withoutRecoveryMessages(original, sessionID: sessionID)
        if transcript != original {
            cacheMessages(transcript, forSessionID: sessionID)
            if preparedSessionID == sessionID { messages = transcript }
        }
        if event.affectsTranscript {
            // Even a same-value terminal event invalidates an older HTTP snapshot.
            v2StreamRevisionsBySessionID[sessionID, default: 0] &+= 1
        }

        func ensureAssistantMessage(_ messageID: String) -> Int {
            if let index = transcript.firstIndex(where: { $0.id == messageID }) {
                return index
            }
            transcript.append(
                OpenCodeMessageEnvelope(
                    info: OpenCodeMessage(
                        id: messageID,
                        role: "assistant",
                        sessionID: sessionID,
                        time: OpenCodeMessageTime(created: event.created),
                        agent: nil,
                        model: nil
                    ),
                    parts: []
                )
            )
            return transcript.count - 1
        }

        func partID(type: String, messageID: String, ordinal: Int) -> String {
            OpenCodeV2ManagedEvent.partID(messageID: messageID, type: type, ordinal: ordinal)
        }

        func upsertTextPart(type: String, messageID: String, ordinal: Int, text: String, appends: Bool, time: OpenCodePartTime? = nil) {
            let index = ensureAssistantMessage(messageID)
            let id = partID(type: type, messageID: messageID, ordinal: ordinal)
            let previous = transcript[index].parts.first(where: { $0.id == id })
            let existingText = previous?.text ?? ""
            let part = OpenCodePart(
                id: id,
                messageID: messageID,
                sessionID: sessionID,
                type: type,
                mime: nil,
                filename: nil,
                url: nil,
                reason: type == "reasoning" ? "reasoning" : nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: appends ? existingText + text : text,
                time: time ?? previous?.time
            )
            transcript[index] = transcript[index].upsertingPart(part)
        }

        func upsertToolPart(messageID: String, toolID: String, name: String?, state: OpenCodeToolState) {
            let index = ensureAssistantMessage(messageID)
            let previous = transcript[index].parts.first(where: { $0.id == toolID })
            let part = OpenCodePart(
                id: toolID,
                messageID: messageID,
                sessionID: sessionID,
                type: "tool",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: name ?? previous?.tool,
                callID: toolID,
                state: state,
                text: nil
            )
            transcript[index] = transcript[index].upsertingPart(part)
        }

        func updateAssistant(_ index: Int, starting: Bool = false, completed: Bool = false, streamed: Bool = false, superseded: Bool = false) {
            let data = superseded ? [:] : event.data.objectValue ?? [:]
            let previous = transcript[index].info
            let model = data["model"].flatMap { value in
                try? JSONDecoder().decode(OpenCodeMessageModelReference.self, from: JSONEncoder().encode(value))
            } ?? previous.model
            let error = data["error"]?.objectValue.map {
                OpenCodeSessionErrorPayload(name: $0["type"]?.stringValue, data: OpenCodeSessionErrorData(message: $0["message"]?.stringValue))
            }
            let tokens = data["tokens"].flatMap { value in
                try? JSONDecoder().decode(OpenCodeMessageTokens.self, from: JSONEncoder().encode(value))
            }
            transcript[index].info = OpenCodeMessage(
                id: previous.id, role: "assistant", sessionID: sessionID,
                time: OpenCodeMessageTime(
                    created: previous.time?.created ?? event.created,
                    completed: starting ? nil : completed ? event.created : previous.time?.completed,
                    streamed: starting ? nil : streamed ? event.created : previous.time?.streamed
                ),
                agent: data["agent"]?.stringValue ?? previous.agent, model: model,
                parentID: previous.parentID, mode: previous.mode, summary: previous.summary,
                finish: starting ? nil : data["finish"]?.stringValue ?? (error != nil ? "error" : previous.finish),
                providerID: model?.providerID ?? previous.providerID, modelID: model?.modelID ?? previous.modelID,
                error: starting ? nil : error ?? previous.error,
                cost: data["cost"]?.doubleValue ?? previous.cost, tokens: tokens ?? previous.tokens,
                system: previous.system
            )
        }

        switch event.type {
        case "session.input.admitted", "session.inbox.enqueued":
            guard let inputID = event.inputID, let input = event.admittedInput else { return false }
            confirmSubmissionAdmission(messageID: inputID, sessionID: sessionID)
            let role = input.type == .synthetic ? "assistant" : "user"
            var admitted = OpenCodeMessageEnvelope(
                info: OpenCodeMessage(id: inputID, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil),
                parts: [OpenCodePart(
                    id: partID(type: "text", messageID: inputID, ordinal: 0), messageID: inputID,
                    sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil,
                    reason: nil, tool: nil, callID: nil, state: nil, text: input.data.text,
                    synthetic: input.type == .synthetic ? true : nil
                )]
            )
            for (index, file) in (input.data.files ?? []).enumerated() {
                admitted.parts.append(OpenCodePart(
                    id: "\(inputID):v2:file:\(index)", messageID: inputID, sessionID: sessionID,
                    type: "file", mime: file.mime, filename: file.name,
                    url: "data:\(file.mime);base64,\(file.data)", reason: nil, tool: nil, callID: nil, state: nil, text: nil
                ))
            }
            for (index, agent) in (input.data.agents ?? []).enumerated() {
                admitted.parts.append(OpenCodePart(
                    id: "\(inputID):v2:agent:\(index)", messageID: inputID, sessionID: sessionID,
                    type: "agent", mime: nil, filename: nil, name: agent.name, url: nil,
                    source: agent.mention.map { OpenCodePartSource(value: $0.text, start: Int(exactly: $0.start),
                        end: Int(exactly: $0.end), type: nil, text: nil, path: nil) },
                    reason: nil, tool: nil, callID: nil, state: nil, text: nil
                ))
            }
            v2AdmittedInputsByID[inputID] = admitted
            return false
        case "session.input.cancelled", "session.inbox.cancelled":
            guard let inputID = event.inputID else { return false }
            guard canonicalSubmissionSessions[inputID] != sessionID else { return false }
            v2AdmittedInputsByID[inputID] = nil
            if submissionRecoveries[inputID]?.sessionID == sessionID {
                submissionRecoveries[inputID]?.phase = .cancelled
                submissionRecoveries[inputID]?.pendingStatusUnknown = false
                if promptAdmissions[inputID]?.connectionID == submissionConnectionID,
                   promptAdmissions[inputID]?.sessionID == sessionID {
                    // Cancellation proves the input was admitted, but never promotes its content.
                    promptAdmissions[inputID]?.phase = .admitted
                }
                transcript.removeAll { $0.id == inputID }
            }
        case "session.input.promoted", "session.inbox.delivered":
            guard let inputID = event.inputID else { return false }
            confirmSubmissionAdmission(messageID: inputID, sessionID: sessionID)
            defer { v2AdmittedInputsByID[inputID] = nil }
            guard var admitted = v2AdmittedInputsByID[inputID] else { return false }
            admitted.info = OpenCodeMessage(id: inputID, role: admitted.info.role, sessionID: sessionID,
                time: OpenCodeMessageTime(created: event.created), agent: nil, model: nil)
            reconcileV2PromptAdmissions(in: [admitted], sessionID: sessionID)
            if let index = transcript.firstIndex(where: { $0.id == inputID }) {
                transcript[index] = admitted
            } else {
                transcript.append(admitted)
            }
        case "session.step.started":
            guard let messageID else { return false }
            if let previous = transcript.first(where: { $0.id == messageID }),
               let completed = previous.info.time?.completed,
               let created = event.created, created <= completed { return false }
            if !transcript.contains(where: { $0.id == messageID }),
               let previous = transcript.lastIndex(where: { $0.info.role == "assistant" && $0.info.model != nil }),
               transcript[previous].info.time?.completed == nil {
                updateAssistant(previous, completed: true, superseded: true)
            }
            let index = ensureAssistantMessage(messageID)
            v2EndedPartIDs[sessionID]?.subtract(transcript[index].parts.compactMap(\.id))
            v2LiveTextPartIDs[sessionID]?.subtract(transcript[index].parts.compactMap(\.id))
            updateAssistant(index, starting: true)
        case "session.step.streamed", "session.step.ended", "session.step.failed":
            guard let messageID else { return false }
            let index = ensureAssistantMessage(messageID)
            updateAssistant(index, completed: event.type != "session.step.streamed", streamed: event.type == "session.step.streamed")
        case "session.message.content.updated":
            guard let id = data["messageID"]?.stringValue,
                  let content = data["content"]?.arrayValue else { return false }
            guard content.allSatisfy({ item in
                guard let value = item.objectValue, let type = value["type"]?.literalStringValue else { return false }
                if type == "text" || type == "reasoning" { return value["text"]?.literalStringValue != nil }
                guard type == "tool", value["id"]?.literalStringValue != nil, value["name"]?.literalStringValue != nil,
                      let state = value["state"]?.objectValue, let status = state["status"]?.literalStringValue else { return false }
                if status == "streaming" { return state["input"]?.literalStringValue != nil }
                guard state["input"]?.objectValue != nil else { return false }
                switch status {
                case "running": return state["metadata"]?.objectValue != nil
                case "completed": return state["content"]?.arrayValue?.isEmpty == false
                case "error": return state["error"]?.objectValue != nil
                default: return false
                }
            }) else { return false }
            let index = ensureAssistantMessage(id)
            transcript[index].parts = []
            var ordinals: [String: Int] = [:]
            for item in content {
                guard let value = item.objectValue, let type = value["type"]?.stringValue else { continue }
                if type == "text" || type == "reasoning" {
                    let ordinal = ordinals[type, default: 0]
                    ordinals[type] = ordinal + 1
                    let time = value["time"]?.objectValue
                    upsertTextPart(type: type, messageID: id, ordinal: ordinal, text: value["text"]?.stringValue ?? "", appends: false,
                        time: time?["created"]?.doubleValue.map { OpenCodePartTime(start: $0, end: time?["completed"]?.doubleValue) })
                } else if type == "tool", let toolID = value["id"]?.stringValue,
                          let state = value["state"]?.objectValue {
                    upsertToolPart(messageID: id, toolID: toolID, name: value["name"]?.stringValue,
                        state: OpenCodeToolState(
                            status: state["status"]?.stringValue == "streaming" ? "pending" : state["status"]?.stringValue,
                            title: value["name"]?.stringValue,
                            error: state["error"]?.objectValue?["message"]?.stringValue,
                            input: Self.v2ToolInput(from: state["input"]?.objectValue),
                            output: Self.v2ToolOutput(from: state["content"]?.arrayValue),
                            metadata: Self.v2ToolMetadata(from: state["metadata"]?.objectValue, content: state["content"]?.arrayValue),
                            raw: state["input"]?.literalStringValue
                        ))
                }
            }
        case "session.revert.committed":
            guard let boundary = data["to"]?.stringValue,
                  let index = transcript.firstIndex(where: { $0.id == boundary }) else { return false }
            // Revert includes its boundary. Unknown/local-only IDs are not evidence of membership in that range.
            for message in transcript[index...] {
                v2AdmittedInputsByID[message.id] = nil
                removeSubmissionPresentation(messageID: message.id, sessionID: sessionID)
            }
            transcript.removeSubrange(index...)
        case "session.text.started", "session.reasoning.started":
            guard let messageID, let ordinal = data["ordinal"]?.intValue, ordinal >= 0 else { return false }
            let type = event.type == "session.text.started" ? "text" : "reasoning"
            guard !transcript.contains(where: { $0.id == messageID && $0.parts.contains(where: {
                $0.id == partID(type: type, messageID: messageID, ordinal: ordinal)
            }) }) else { return false }
            upsertTextPart(type: type, messageID: messageID, ordinal: ordinal, text: "", appends: false,
                time: type == "reasoning" ? event.created.map { OpenCodePartTime(start: $0) } : nil)
        case "session.text.delta", "session.reasoning.delta":
            guard let messageID,
                  let ordinal = data["ordinal"]?.intValue,
                  let delta = data["delta"]?.literalStringValue else { return false }
            let type = event.type == "session.text.delta" ? "text" : "reasoning"
            guard ordinal >= 0,
                  v2EndedPartIDs[sessionID]?.contains(partID(type: type, messageID: messageID, ordinal: ordinal)) != true,
                  transcript.contains(where: { $0.id == messageID && $0.info.time?.completed == nil && $0.parts.contains(where: {
                      $0.id == partID(type: type, messageID: messageID, ordinal: ordinal) && $0.time?.end == nil
                  }) }) else { return false }
            upsertTextPart(type: type, messageID: messageID, ordinal: ordinal, text: delta, appends: true)
            v2LiveTextPartIDs[sessionID, default: []].insert(partID(type: type, messageID: messageID, ordinal: ordinal))
        case "session.text.ended", "session.reasoning.ended":
            guard let messageID,
                  let ordinal = data["ordinal"]?.intValue,
                  let text = data["text"]?.literalStringValue else { return false }
            let type = event.type == "session.text.ended" ? "text" : "reasoning"
            guard ordinal >= 0 else { return false }
            let id = partID(type: type, messageID: messageID, ordinal: ordinal)
            let previous = transcript.first(where: { $0.id == messageID })?.parts.first { $0.id == id }
            v2EndedPartIDs[sessionID, default: []].insert(id)
            v2LiveTextPartIDs[sessionID]?.remove(id)
            let time = type == "reasoning" ? (previous?.time?.start ?? event.created).map { OpenCodePartTime(start: $0, end: event.created) } : nil
            upsertTextPart(type: type, messageID: messageID, ordinal: ordinal, text: text, appends: false, time: time)
        case "session.tool.input.started":
            guard let messageID,
                  let toolID = data["id"]?.stringValue,
                  let name = data["name"]?.stringValue else { return false }
            guard !transcript.contains(where: { $0.id == messageID && $0.parts.contains(where: { $0.id == toolID }) }) else { return false }
            upsertToolPart(
                messageID: messageID,
                toolID: toolID,
                name: name,
                state: OpenCodeToolState(status: "pending", title: name, error: nil, input: nil, output: nil, metadata: nil)
            )
        case "session.tool.input.delta", "session.tool.input.ended":
            guard let messageID,
                  let toolID = data["id"]?.literalStringValue,
                  let text = (data[event.type.hasSuffix("delta") ? "delta" : "text"]?.literalStringValue) else { return false }
            let index = ensureAssistantMessage(messageID)
            let previous = transcript[index].parts.first(where: { $0.id == toolID })
            guard previous?.state?.status == "pending" else { return false }
            let inputPartID = "\(messageID):v2:tool-input:\(toolID)"
            if event.type == "session.tool.input.delta" {
                guard v2EndedPartIDs[sessionID]?.contains(inputPartID) != true else { return false }
            } else {
                v2EndedPartIDs[sessionID, default: []].insert(inputPartID)
            }
            let raw = event.type.hasSuffix("delta") ? (previous?.state?.raw ?? "") + text : text
            upsertToolPart(
                messageID: messageID,
                toolID: toolID,
                name: nil,
                state: OpenCodeToolState(
                    status: "pending",
                    title: previous?.state?.title,
                    error: nil,
                    input: previous?.state?.input,
                    output: nil,
                    metadata: previous?.state?.metadata,
                    raw: raw
                )
            )
        case "session.tool.called":
            guard let messageID,
                  let toolID = data["id"]?.stringValue else { return false }
            let index = ensureAssistantMessage(messageID)
            let previous = transcript[index].parts.first(where: { $0.id == toolID })
            guard previous?.state?.status == "pending" else { return false }
            upsertToolPart(
                messageID: messageID,
                toolID: toolID,
                name: nil,
                state: OpenCodeToolState(
                    status: "running",
                    title: previous?.state?.title,
                    error: nil,
                    input: Self.v2ToolInput(from: data["input"]?.objectValue),
                    output: nil,
                    metadata: Self.v2ToolMetadata(from: [:])
                )
            )
        case "session.tool.progress":
            guard let messageID,
                  let toolID = data["id"]?.stringValue else { return false }
            let index = ensureAssistantMessage(messageID)
            let previous = transcript[index].parts.first(where: { $0.id == toolID })
            guard previous?.state?.status == "running" else { return false }
            upsertToolPart(
                messageID: messageID,
                toolID: toolID,
                name: nil,
                state: OpenCodeToolState(
                    status: "running",
                    title: previous?.state?.title,
                    error: nil,
                    input: previous?.state?.input,
                    output: nil,
                    metadata: Self.v2ToolMetadata(from: data["metadata"]?.objectValue)
                )
            )
        case "session.tool.success", "session.tool.failed":
            guard let messageID,
                  let toolID = data["id"]?.stringValue else { return false }
            let index = ensureAssistantMessage(messageID)
            let previous = transcript[index].parts.first(where: { $0.id == toolID })
            let failed = event.type == "session.tool.failed"
            guard previous?.state?.status == "running" || (failed && previous?.state?.status == "pending") else { return false }
            upsertToolPart(
                messageID: messageID,
                toolID: toolID,
                name: nil,
                state: OpenCodeToolState(
                    status: failed ? "error" : "completed",
                    title: previous?.state?.title,
                    error: failed ? data["error"]?.objectValue?["message"]?.stringValue : nil,
                    input: previous?.state?.input ?? Self.v2ToolInput(from: [:]),
                    output: Self.v2ToolOutput(from: data["content"]?.arrayValue),
                    metadata: Self.v2ToolMetadata(from: data["metadata"]?.objectValue, content: data["content"]?.arrayValue)
                )
            )
        default:
            return false
        }

        guard transcript != original else { return false }
        // Keep the server's projection order. Local recovery is never transcript data.
        if v2TranscriptStates[sessionID] == nil { v2TranscriptStates[sessionID] = V2TranscriptState() }
        cacheMessages(transcript, forSessionID: sessionID)
        if preparedSessionID == sessionID {
            messages = transcript
        }
        return true
    }

    func beginV2CanonicalRead(sessionID: String) -> UUID {
        let previous = v2CanonicalReads[sessionID]
        let id = UUID()
        v2CanonicalReads[sessionID] = V2CanonicalRead(id: id,
            needsRetry: previous?.pending == true || previous?.needsRetry == true,
            retried: previous?.retried ?? false)
        return id
    }

    func isCurrentV2CanonicalRead(_ id: UUID, sessionID: String) -> Bool {
        v2CanonicalReads[sessionID]?.id == id
    }

    func v2CanonicalReadID(sessionID: String) -> UUID? {
        v2CanonicalReads[sessionID]?.id
    }

    // Superseding reads inherit recovery responsibility. Late losers never start a retry cascade.
    func finishV2CanonicalRead(_ id: UUID, sessionID: String, applied: Bool, needsRetry: Bool) -> Bool {
        guard var read = v2CanonicalReads[sessionID], read.id == id else { return false }
        read.pending = false
        read.needsRetry = !applied && (read.needsRetry || needsRetry)
        let retry = read.needsRetry && !read.retried
        read.retried = !applied && (read.retried || retry)
        v2CanonicalReads[sessionID] = read
        return retry
    }

    func v2StreamRevision(sessionID: String) -> Int {
        v2StreamRevisionsBySessionID[sessionID, default: 0]
    }

    func isHydratingV2Transcript(sessionID: String) -> Bool {
        v2HydratingSessionID == sessionID
    }

    private static func v2ToolInput(from object: [String: OpenCodeJSONValue]?) -> OpenCodeToolInput? {
        guard let object else { return nil }
        return OpenCodeToolInput(
            command: object["command"]?.stringValue,
            description: object["description"]?.stringValue,
            filePath: object["filePath"]?.stringValue,
            name: object["name"]?.stringValue,
            path: object["path"]?.stringValue,
            query: object["query"]?.stringValue,
            pattern: object["pattern"]?.stringValue,
            subagentType: object["subagent_type"]?.stringValue,
            url: object["url"]?.stringValue,
            clientID: object["client_id"]?.stringValue,
            toolID: object["tool_id"]?.stringValue,
            arguments: object
        )
    }

    private static func v2ToolMetadata(from object: [String: OpenCodeJSONValue]?, content: [OpenCodeJSONValue]? = nil) -> OpenCodeToolMetadata? {
        var object = object ?? [:]
        let files = (content ?? []).filter { $0.objectValue?["type"]?.stringValue == "file" }
        if !files.isEmpty { object["files"] = .array(files) }
        guard let data = try? JSONEncoder().encode(OpenCodeJSONValue.object(object)) else { return nil }
        return try? JSONDecoder().decode(OpenCodeToolMetadata.self, from: data)
    }

    private static func v2ToolOutput(from content: [OpenCodeJSONValue]?) -> String? {
        let values = content?.compactMap { item -> String? in
            guard let object = item.objectValue else { return nil }
            if object["type"]?.stringValue == "text" {
                return object["text"]?.stringValue
            }
            if object["type"]?.stringValue == "file" {
                return object["name"]?.stringValue ?? object["uri"]?.stringValue
            }
            return nil
        } ?? []
        let output = values.joined(separator: "\n")
        return output.isEmpty ? nil : output
    }

    func finishV2PromptWithoutReconciliation(sessionID: String) {
        // Request completion alone is not proof of admission. Callers with a receipt
        // must confirm its exact ID, rather than unlocking a later prompt in this session.
        for (id, admission) in submissionRecoveries where admission.sessionID == sessionID && admission.phase == .submitting {
            markSubmissionUncertain(messageID: id, sessionID: sessionID)
        }
    }

    func markSubmissionUncertain(messageID: String, sessionID: String) {
        guard var admission = submissionRecoveries[messageID], admission.sessionID == sessionID,
              admission.phase == .submitting else { return }
        admission.phase = .uncertain
        submissionRecoveries[messageID] = admission
    }

    @discardableResult
    func confirmSubmissionAdmission(messageID: String, sessionID: String) -> Bool {
        if canonicalSubmissionSessions[messageID] == sessionID { return true }
        guard var admission = submissionRecoveries[messageID], admission.sessionID == sessionID else { return false }
        guard admission.phase != .cancelled else { return true }
        admission.phase = .admitted
        admission.pendingStatusUnknown = false
        submissionRecoveries[messageID] = admission
        return true
    }

    func applyV2InboxAdmissionIDs(_ ids: Set<String>, sessionID: String) {
        // Absence is not rejection: the input may already have left the inbox.
        for id in ids { confirmSubmissionAdmission(messageID: id, sessionID: sessionID) }
    }

    private func reconcileV2PromptAdmissions(in canonical: [OpenCodeMessageEnvelope], sessionID: String) {
        for message in canonical where message.info.sessionID == sessionID {
            _ = confirmCanonicalSubmission(message.info)
        }
    }

    @discardableResult
    func confirmCanonicalSubmission(_ message: OpenCodeMessage) -> Bool {
        guard message.role == "user", let sessionID = message.sessionID else { return false }
        if canonicalSubmissionSessions[message.id] == sessionID { return true }
        let input = submissionRecoveries[message.id] ?? stagedSubmissionPresentations[message.id]
        let admission = promptAdmissions[message.id]
        guard input?.sessionID == sessionID || (admission?.sessionID == sessionID
            && admission?.connectionID == submissionConnectionID && submissionConnectionID != nil) else { return false }
        // An older optimistic payload must not win the streaming-prefix merge over this canonical input.
        messages.removeAll { $0.id == message.id && $0.info.sessionID == sessionID }
        if let cached = cachedMessagesBySessionID[sessionID] {
            cachedMessagesBySessionID[sessionID] = cached.filter { $0.id != message.id }
        }
        // Admission evidence is not evidence that a displayable canonical envelope has been committed.
        canonicalSubmissionSessions[message.id] = sessionID
        if let connectionID = submissionConnectionID { confirmPromptAdmission(from: message, connectionID: connectionID) }
        if var admitted = input, admitted.sessionID == sessionID {
            admitted.phase = .admitted
            admitted.pendingStatusUnknown = false
            submissionRecoveries[message.id] = admitted
            stagedSubmissionPresentations[message.id] = nil
        }
        return true
    }

    func markSubmissionStatusUnknown(messageID: String, sessionID: String) {
        guard submissionRecoveries[messageID]?.sessionID == sessionID,
              submissionRecoveries[messageID]?.phase == .admitted else { return }
        submissionRecoveries[messageID]?.pendingStatusUnknown = true
    }

    func isV2PromptInFlight(sessionID: String) -> Bool {
        v2PromptInFlightSessionIDs.contains(sessionID)
    }

    func clearActiveTranscript() {
        v2HydratingSessionID = nil
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
        let deduplicatedMessages = Self.deduplicatedMessages(withoutRecoveryMessages(loadedMessages, sessionID: sessionID))
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
        let canonicalMessages = Self.deduplicatedMessages(withoutRecoveryMessages(messages, sessionID: sessionID),
            preservingOrder: v2TranscriptStates[sessionID] != nil)
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

    nonisolated private static func deduplicatedMessages(_ messages: [OpenCodeMessageEnvelope], preservingOrder: Bool = false) -> [OpenCodeMessageEnvelope] {
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
        if preservingOrder { return result }
        return result.sorted {
            OpenCodeMessage.isOrderedBefore($0.info, $1.info)
        }
    }

    func clearCachedMessages(forSessionID sessionID: String) {
        promptAdmissions = promptAdmissions.filter { $0.value.sessionID != sessionID }
        cachedMessagesBySessionID[sessionID] = nil
        messageHistoryBySessionID[sessionID] = nil
        v2TranscriptStates[sessionID] = nil
        submissionRecoveries = submissionRecoveries.filter { $0.value.sessionID != sessionID }
        canonicalSubmissionSessions = canonicalSubmissionSessions.filter { $0.value != sessionID }
        v2StreamRevisionsBySessionID[sessionID] = nil
        v2CanonicalReads[sessionID] = nil
        v2EndedPartIDs[sessionID] = nil
        v2LiveTextPartIDs[sessionID] = nil
        v2AdmittedInputsByID = v2AdmittedInputsByID.filter { $0.value.info.sessionID != sessionID }
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
