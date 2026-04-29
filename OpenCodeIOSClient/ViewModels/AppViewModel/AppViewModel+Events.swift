import Foundation

extension AppViewModel {
    private static let streamDeltaCoalescingInterval: Duration = .milliseconds(50)

    var isCapturingStreamingDiagnostics: Bool {
        isShowingDebugProbe || isRunningDebugProbe
    }

    func setComposerStreamingFocus(_ isFocused: Bool) {
        guard isComposerStreamingFocused != isFocused else { return }
        isComposerStreamingFocused = isFocused

        if !isFocused {
            flushBufferedTranscript(reason: "composer blur")
        }
    }

    func flushBufferedTranscript(reason: String) {
        flushPendingTranscriptEvents(reason: reason)
    }

    func startDebugProbe() async {
        guard let selectedSession else { return }

        stopDebugProbeStreams()
        debugProbeLog = []
        isRunningDebugProbe = true
        lastFallbackMessageCount = messages.count
        lastFallbackAssistantLength = currentAssistantTextLength()
        appendDebugLog("probe started for \(selectedSession.id)")
        stopEventStream()
        startEventStream()
        appendDebugLog("probe using shared app event stream")
        appendDebugLog("probe prompt: \(debugProbePrompt)")
        await sendMessage(debugProbePrompt, in: selectedSession, userVisible: true)
    }

    func copyDebugProbeLog() -> String {
        debugProbeLog.joined(separator: "\n")
    }

    func presentDebugProbe() {
        isShowingDebugProbe = true
    }

    func startEventStream() {
        stopEventStream()
        let client = self.client
        lastStreamEventAt = .now
        debugLastEventSummary = "stream starting"
        appendDebugLog("stream start global")
        eventManager.start(
            client: client,
            onStatus: { [weak self] status in
                await MainActor.run {
                    self?.debugLastEventSummary = status
                    self?.appendDebugLog(status)
                }
            },
            onRawLine: nil,
            onDroppedEvent: { [weak self] message in
                await MainActor.run {
                    self?.appendDebugLog(message)
                }
            },
            onEvent: { [weak self] managed in
                await MainActor.run {
                    guard let self else { return }
                    if self.shouldLogEventDetails(for: managed.envelope.type) {
                        self.appendDebugLog("event \(managed.envelope.type): \(managed.directory)")
                    }
                    self.handleManagedEvent(managed)
                }
            }
        )
    }

    func stopEventStream() {
        flushPendingTranscriptEvents(reason: "stream stop")
        reloadTask?.cancel()
        reloadTask = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        eventManager.stop()
        eventStreamRestartTask?.cancel()
        eventStreamRestartTask = nil
        debugLastEventSummary = "stream stopped"
        appendDebugLog("stream stopped")
    }

    func startDebugProbeStreams() {
        let client = self.client
        guard let urls = try? client.eventURLs(directory: streamDirectory) else { return }

        for url in urls {
            let label = probeLabel(for: url)
            let task = Task.detached(priority: .background) { [weak self] in
                await OpenCodeEventStream.consume(
                    client: client,
                    url: url,
                    onStatus: { status in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) \(status)")
                        }
                    },
                    onRawLine: { line in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) raw \(Self.debugRawLine(line))")
                        }
                    },
                    onEvent: { event in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) event \(event.type): \(String(event.data.prefix(180)))")
                        }
                    }
                )
            }
            debugProbeStreamTasks.append(task)
        }
    }

    func stopDebugProbeStreams() {
        debugProbeStreamTasks.forEach { $0.cancel() }
        debugProbeStreamTasks.removeAll()
    }

    func handleManagedEvent(_ managed: OpenCodeManagedEvent) {
        guard isConnected else { return }

        if shouldLogEventDetails(for: managed.envelope.type) {
            appendDebugLog(eventScopeSummary(for: managed))
            appendDebugLog(eventIdentitySummary(for: managed.envelope))
        }

        if OpenCodeStateReducer.applyGlobalEvent(event: managed.typed, projects: &projects, currentProject: &currentProject) {
            switch managed.typed {
            case .serverConnected, .globalDisposed:
                Task { [weak self] in
                    try? await self?.refreshProjects()
                    try? await self?.reloadSessions()
                }
            default:
                break
            }
            return
        }

        guard shouldApplyDirectoryEvent(from: managed) else {
            appendDebugLog("drop \(managed.envelope.type): scope mismatch \(managed.directory) selected=\(debugDirectoryLabel(effectiveSelectedDirectory)) stream=\(debugDirectoryLabel(streamDirectory)) session=\(debugSessionLabel(selectedSession))")
            return
        }

        if eventAffectsActiveSession(managed) {
            lastStreamEventAt = .now
        }

        if isLiveActivityMessageEvent(managed.envelope.type) || managed.envelope.type == "session.idle" {
            markChatBreadcrumb(
                "event \(managed.envelope.type)",
                sessionID: managedEventSessionID(for: managed),
                messageID: managed.envelope.properties.messageID ?? managed.envelope.properties.part?.messageID ?? managed.envelope.properties.info?.id,
                partID: managed.envelope.properties.partID ?? managed.envelope.properties.part?.id
            )
        }

        if enqueueSelectedTranscriptEventIfNeeded(managed) {
            return
        }

        if shouldFlushPendingTranscriptEvents(before: managed) {
            flushPendingTranscriptEvents(reason: "before \(managed.envelope.type)")
        }

        if case let .sessionError(sessionID, message) = managed.typed {
            if let sessionID {
                directoryState.sessionStatuses[sessionID] = "idle"
            }
            if sessionID == nil || sessionID == selectedSession?.id {
                errorMessage = message ?? "Session error"
            }
            debugLastEventSummary = message.map { "session error: \($0)" } ?? "session error"
            appendDebugLog(debugLastEventSummary)
            stopFallbackRefresh()
            return
        }

        let payload = managed.envelope
        let selectedSession = directoryState.selectedSession
        let eventSessionID = managedEventSessionID(for: managed)

        updateCachedMessagesForLiveActivityIfNeeded(payload: payload, sessionID: eventSessionID, selectedSessionID: selectedSession?.id)

        var nextDirectoryState = directoryState
        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: managed.typed,
            state: &nextDirectoryState
        )

        if nextDirectoryState != directoryState {
            directoryState = nextDirectoryState
        }

        switch result {
        case let .message(reason):
            if let selectedSession, shouldRefreshSessionPreview(for: payload.type) {
                refreshSessionPreview(for: selectedSession.id, messages: directoryState.messages)
            }
            scheduleLiveActivityPreviewRefreshIfNeeded(for: managedEventSessionID(for: managed))
            if let selectedSession,
               payload.type == "message.updated",
               payload.properties.info?.role == "user",
               payload.properties.info?.sessionID == selectedSession.id {
                syncComposerSelections(for: selectedSession)
            }
            debugLastEventSummary = debugSummary(for: payload)
            appendDebugLog(debugSummary(for: payload))
            appendDebugLog("apply \(payload.type): \(reason) count \(messages.count)")

            if let selectedSession,
               payload.type == "message.updated",
               payload.properties.info?.role == "assistant" {
                startLiveRefresh(for: selectedSession, reason: "assistant")
            }

            if let selectedSession,
               payload.type == "message.part.updated",
               let partType = payload.properties.part?.type,
               ["step-start", "tool", "reasoning", "text"].contains(partType) {
                startLiveRefresh(for: selectedSession, reason: partType)
            }

            if payload.type == "message.part.updated",
               payload.properties.part?.type == "step-finish" {
                appendDebugLog("step finish")
                stopFallbackRefresh()
            }

            triggerStreamPartHapticIfNeeded(for: managed)
        case .sessionChanged:
            appendDebugLog("session changed")
        case .todoChanged:
            appendDebugLog("todo changed")
        case .permissionChanged:
            appendDebugLog("permission changed")
        case .questionChanged:
            appendDebugLog("question changed")
        case .statusChanged:
            appendDebugLog("status changed")
        case .idle:
            appendDebugLog("session idle")
            markChatBreadcrumb("session idle", sessionID: eventSessionID)
            stopFallbackRefresh()
            if let selectedSession {
                scheduleReload(for: selectedSession)
            }
        case let .ignored(reason):
            if isLiveActivityMessageEvent(payload.type),
               activeLiveActivitySessionIDs.contains(eventSessionID ?? "") {
                appendDebugLog("live activity refresh on ignored \(payload.type) session=\(eventSessionID ?? "nil")")
                scheduleLiveActivityPreviewRefreshIfNeeded(for: eventSessionID)
            }
            appendDebugLog("drop \(payload.type): \(reason)")
        }

        switch managed.typed {
        case let .sessionDeleted(session):
            removeSessionPreview(for: session.id)
            if activeLiveActivitySessionIDs.contains(session.id) {
                Task { [weak self] in
                    await self?.stopLiveActivity(for: session.id, immediate: true)
                }
            }
        case let .vcsBranchUpdated(branch):
            directoryState.vcsInfo = OpenCodeVCSInfo(branch: branch, defaultBranch: directoryState.vcsInfo?.defaultBranch)
            refreshVCSFromEvent()
        case let .fileWatcherUpdated(file):
            guard !file.hasPrefix(".git/") else { break }
            refreshVCSFromEvent()
        default:
            break
        }

        if let selectedSession,
           payload.type == "session.diff",
           payload.properties.sessionID == selectedSession.id {
            Task { [weak self] in
                await self?.loadTodos(for: selectedSession)
            }
        }

        refreshLiveActivityIfNeeded(for: eventSessionID)
        if shouldPublishWidgetSnapshots(after: result) {
            publishWidgetSnapshots()
        }
    }

    private func shouldRefreshSessionPreview(for eventType: String) -> Bool {
        eventType != "message.part.delta"
    }

    private func shouldPublishWidgetSnapshots(after result: SessionEventResult) -> Bool {
        switch result {
        case .sessionChanged, .todoChanged, .permissionChanged, .questionChanged, .statusChanged, .idle:
            return true
        case .message, .ignored:
            return false
        }
    }

    private func shouldLogEventDetails(for eventType: String) -> Bool {
        guard isCapturingStreamingDiagnostics else { return false }
        return eventType != "message.part.delta"
    }

    private func enqueueSelectedTranscriptEventIfNeeded(_ managed: OpenCodeManagedEvent) -> Bool {
        guard shouldBufferTranscriptEvent(managed) else {
            return false
        }

        pendingTranscriptEvents.append(
            OpenCodePendingTranscriptEvent(
                typedEvent: managed.typed,
                eventType: managed.envelope.type,
                sessionID: managedEventSessionID(for: managed),
                messageID: managed.envelope.properties.messageID ?? managed.envelope.properties.part?.messageID ?? managed.envelope.properties.info?.id,
                partID: managed.envelope.properties.partID ?? managed.envelope.properties.part?.id,
                deltaCharacterCount: transcriptDeltaCharacterCount(for: managed),
                enqueuedAt: Date()
            )
        )
        triggerStreamPartHapticIfNeeded(for: managed)
        scheduleStreamDeltaFlush()
        return true
    }

    private func shouldBufferTranscriptEvent(_ managed: OpenCodeManagedEvent) -> Bool {
        guard let selectedSessionID = selectedSession?.id else { return false }

        switch managed.typed {
        case let .messagePartDelta(sessionID, _, _, _, _):
            return sessionID == selectedSessionID
        default:
            return false
        }
    }

    private func shouldFlushPendingTranscriptEvents(before managed: OpenCodeManagedEvent) -> Bool {
        !pendingTranscriptEvents.isEmpty
    }

    private func transcriptDeltaCharacterCount(for managed: OpenCodeManagedEvent) -> Int {
        guard case let .messagePartDelta(_, _, _, _, delta) = managed.typed else { return 0 }
        return delta.count
    }

    private func scheduleStreamDeltaFlush(rescheduling: Bool = false) {
        if rescheduling {
            streamDeltaFlushTask?.cancel()
            streamDeltaFlushTask = nil
        }

        guard streamDeltaFlushTask == nil else { return }

        streamDeltaFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.streamDeltaCoalescingInterval)
            guard !Task.isCancelled else { return }
            self?.flushPendingTranscriptEvents(reason: "timer")
        }
    }

    private func flushPendingTranscriptEvents(reason: String) {
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil

        guard !pendingTranscriptEvents.isEmpty else { return }

        let now = Date()
        let events = pendingTranscriptEvents
        pendingTranscriptEvents = []

        var nextDirectoryState = directoryState
        var appliedCount = 0

        for event in events {
            let result = OpenCodeStateReducer.applyDirectoryEvent(
                event: event.typedEvent,
                state: &nextDirectoryState
            )
            if case .message = result {
                appliedCount += 1
            }
        }

        if nextDirectoryState != directoryState {
            directoryState = nextDirectoryState
        }

        for sessionID in Set(events.compactMap(\.sessionID)) {
            refreshLiveActivityIfNeeded(for: sessionID)
        }

        logStreamDeltaFlush(reason: reason, events: events, appliedCount: appliedCount, flushedAt: now)
    }

    private func logStreamDeltaFlush(reason: String, events: [OpenCodePendingTranscriptEvent], appliedCount: Int, flushedAt now: Date) {
        guard isCapturingStreamingDiagnostics else {
            streamDeltaLastFlushAt = now
            return
        }

        let oldest = events.map(\.enqueuedAt).min() ?? now
        let waitMS = Int(now.timeIntervalSince(oldest) * 1000)
        let cadence = streamDeltaLastFlushAt
            .map { "\(Int(now.timeIntervalSince($0) * 1000))ms" } ?? "first"
        let chars = events.reduce(0) { $0 + $1.deltaCharacterCount }
        let types = Set(events.map(\.eventType)).sorted().joined(separator: ",")
        let target = "50ms"
        streamDeltaLastFlushAt = now

        appendDebugLog(
            "transcript flush reason=\(reason) count=\(events.count) applied=\(appliedCount) chars=\(chars) wait=\(waitMS)ms cadence=\(cadence) target=\(target) focused=\(isComposerStreamingFocused) types=\(types)"
        )
    }

    private func isLiveActivityMessageEvent(_ type: String) -> Bool {
        switch type {
        case "message.updated", "message.part.updated", "message.part.delta", "message.removed", "message.part.removed":
            return true
        default:
            return false
        }
    }

    private func updateCachedMessagesForLiveActivityIfNeeded(payload: OpenCodeEventEnvelope, sessionID: String?, selectedSessionID: String?) {
        guard let sessionID,
              sessionID != selectedSessionID,
              activeLiveActivitySessionIDs.contains(sessionID),
              isLiveActivityMessageEvent(payload.type) else {
            return
        }

        var cachedMessages = cachedMessagesBySessionID[sessionID] ?? []

        switch payload.type {
        case "message.updated", "message.part.updated", "message.part.delta":
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: sessionID, messages: cachedMessages)
            guard update.applied else { return }
            cachedMessages = update.messages
        case "message.removed":
            guard let messageID = payload.properties.messageID else { return }
            cachedMessages.removeAll { $0.info.id == messageID }
        case "message.part.removed":
            guard let messageID = payload.properties.messageID,
                  let partID = payload.properties.partID,
                  let index = cachedMessages.firstIndex(where: { $0.info.id == messageID }) else {
                return
            }
            cachedMessages[index] = cachedMessages[index].removingPart(partID: partID)
        default:
            return
        }

        cachedMessagesBySessionID[sessionID] = cachedMessages
        refreshSessionPreview(for: sessionID, messages: cachedMessages)
    }

    private func shouldApplyDirectoryEvent(from managed: OpenCodeManagedEvent) -> Bool {
        let eventDirectory = managed.directory
        let eventSessionID = managedEventSessionID(for: managed)

        if let selectedSessionID = selectedSession?.id,
           eventSessionID == selectedSessionID {
            return true
        }

        let acceptedDirectories = [selectedSession?.directory, effectiveSelectedDirectory]
            .compactMap { directory -> String? in
                guard let directory, !directory.isEmpty else { return nil }
                return directory
            }

        guard !acceptedDirectories.isEmpty else {
            return eventDirectory == "global"
        }

        if acceptedDirectories.contains(eventDirectory) {
            return true
        }

        guard eventDirectory == "global" else { return false }

        return eventSessionID != nil
    }

    private func managedEventSessionID(for managed: OpenCodeManagedEvent) -> String? {
        switch managed.typed {
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            return session.id
        case let .sessionStatus(sessionID, _), let .sessionIdle(sessionID), let .sessionDiff(sessionID), let .todoUpdated(sessionID, _), let .messageRemoved(sessionID, _), let .messagePartDelta(sessionID, _, _, _, _), let .permissionReplied(sessionID, _, _), let .questionReplied(sessionID, _), let .questionRejected(sessionID, _):
            return sessionID
        case let .sessionError(sessionID, _):
            return sessionID
        case let .messageUpdated(info):
            return info.sessionID
        case let .messagePartUpdated(part):
            return part.sessionID
        case let .permissionAsked(permission):
            return permission.sessionID
        case let .questionAsked(question):
            return question.sessionID
        default:
            return nil
        }
    }

    private func triggerStreamPartHapticIfNeeded(for managed: OpenCodeManagedEvent) {
        guard shouldEmitStreamPartHaptic(for: managed) else { return }

        let now = Date()
        guard now >= nextStreamPartHapticAllowedAt else { return }

        OpenCodeHaptics.impact(.crisp)
        nextStreamPartHapticAllowedAt = now.addingTimeInterval(nextStreamPartHapticInterval())
    }

    private func shouldEmitStreamPartHaptic(for managed: OpenCodeManagedEvent) -> Bool {
        guard let selectedSession else { return false }
        guard activeChatSessionID == selectedSession.id else { return false }

        switch managed.typed {
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            guard sessionID == selectedSession.id,
                  field == "text",
                  !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            return isVisibleAssistantTextPart(messageID: messageID, partID: partID, sessionID: sessionID)
        default:
            return false
        }
    }

    private func isVisibleAssistantTextPart(messageID: String, partID: String, sessionID: String) -> Bool {
        guard let message = directoryState.messages.first(where: {
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

    private func nextStreamPartHapticInterval() -> TimeInterval {
        if Double.random(in: 0 ... 1) < 0.18 {
            return Double.random(in: 0.12 ... 0.18)
        }

        return Double.random(in: 0.045 ... 0.085)
    }

    private func eventScopeSummary(for managed: OpenCodeManagedEvent) -> String {
        let selectedSessionID = selectedSession?.id ?? "nil"
        let payloadSessionID = managed.envelope.properties.sessionID ?? "nil"
        let payloadInfoSessionID = managed.envelope.properties.info?.sessionID ?? "nil"
        let partSessionID = managed.envelope.properties.part?.sessionID ?? "nil"
        return "scope event=\(managed.envelope.type) dir=\(managed.directory) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) streamDir=\(debugDirectoryLabel(streamDirectory)) selectedSession=\(selectedSessionID) payloadSession=\(payloadSessionID) infoSession=\(payloadInfoSessionID) partSession=\(partSessionID)"
    }

    func debugDirectoryLabel(_ directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return "nil" }
        return directory
    }

    func debugSessionLabel(_ session: OpenCodeSession?) -> String {
        guard let session else { return "nil" }
        return "\(session.id)@\(debugDirectoryLabel(session.directory))"
    }

    private func eventAffectsActiveSession(_ managed: OpenCodeManagedEvent) -> Bool {
        guard let selectedSessionID = selectedSession?.id else {
            return true
        }

        switch managed.typed {
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            return session.id == selectedSessionID
        case let .sessionStatus(sessionID, _), let .sessionIdle(sessionID), let .sessionDiff(sessionID), let .todoUpdated(sessionID, _), let .messageRemoved(sessionID, _), let .messagePartDelta(sessionID, _, _, _, _), let .permissionReplied(sessionID, _, _), let .questionReplied(sessionID, _), let .questionRejected(sessionID, _):
            return sessionID == selectedSessionID
        case let .sessionError(sessionID, _):
            return sessionID == nil || sessionID == selectedSessionID
        case let .messageUpdated(info):
            return info.sessionID == selectedSessionID
        case let .messagePartUpdated(part):
            return part.sessionID == selectedSessionID
        case let .permissionAsked(permission):
            return permission.sessionID == selectedSessionID
        case let .questionAsked(question):
            return question.sessionID == selectedSessionID
        case let .messagePartRemoved(messageID, _):
            return messages.contains { $0.info.id == messageID }
        case .vcsBranchUpdated, .fileWatcherUpdated:
            return hasGitProject
        default:
            return false
        }
    }

    func scheduleReload(for session: OpenCodeSession) {
        reloadTask?.cancel()

        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.isConnected else { return }
            self.markChatBreadcrumb("reload start", sessionID: session.id)
            do {
                try await self.loadMessages(for: session)
                try await self.reloadSessions()
                await self.loadTodos(for: session)
                self.markChatBreadcrumb("reload finish", sessionID: session.id)
            } catch {
                self.markChatBreadcrumb("reload error", sessionID: session.id)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func startLiveRefresh(for session: OpenCodeSession, reason: String) {
        liveRefreshGeneration += 1
        let generation = liveRefreshGeneration
        lastFallbackMessageCount = messages.count
        lastFallbackAssistantLength = currentAssistantTextLength()
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, self.isConnected, self.selectedSession?.id == session.id else { return }
                guard self.liveRefreshGeneration == generation else { return }
                guard Date.now.timeIntervalSince(self.lastStreamEventAt) >= 1.0 else { continue }

                do {
                    self.markChatBreadcrumb("fallback refresh start \(reason)", sessionID: session.id)
                    try await self.loadMessages(for: session)
                    await self.loadTodos(for: session)
                    self.debugLastEventSummary = self.fallbackRefreshSummary(reason: reason)
                    self.appendDebugLog(self.debugLastEventSummary)
                    self.markChatBreadcrumb("fallback refresh finish \(reason)", sessionID: session.id)
                } catch {
                    self.appendDebugLog("fallback error: \(error.localizedDescription)")
                    self.markChatBreadcrumb("fallback refresh error \(reason)", sessionID: session.id)
                    self.errorMessage = error.localizedDescription
                    return
                }
            }
        }
    }

    func stopFallbackRefresh() {
        liveRefreshGeneration += 1
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        isRunningDebugProbe = false
        stopDebugProbeStreams()
    }

    func debugSummary(for payload: OpenCodeEventEnvelope) -> String {
        switch payload.type {
        case "message.part.delta":
            let delta = payload.properties.delta ?? ""
            return "delta: \(delta)"
        case "message.part.updated":
            return "part: \(payload.properties.part?.type ?? "unknown")"
        case "message.updated":
            return "message: \(payload.properties.info?.role ?? "unknown")"
        default:
            return payload.type
        }
    }

    func fallbackRefreshSummary(reason: String) -> String {
        let assistantText = messages
            .last(where: { ($0.info.role ?? "").lowercased() == "assistant" })?
            .parts
            .compactMap(\.text)
            .joined(separator: " ") ?? ""

        let compact = assistantText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

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

    func currentAssistantTextLength() -> Int {
        messages
            .last(where: { ($0.info.role ?? "").lowercased() == "assistant" })?
            .parts
            .compactMap(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .count ?? 0
    }

    func appendDebugLog(_ message: String) {
        guard isCapturingStreamingDiagnostics else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stamped = "[\(formatter.string(from: Date()))] \(message)"
        debugProbeLog.append(stamped)
        if debugProbeLog.count > 400 {
            debugProbeLog.removeFirst(debugProbeLog.count - 400)
        }
#if DEBUG
        print("[OpenCodeDebug] \(stamped)")
#endif
    }

    func markChatBreadcrumb(
        _ event: String,
        sessionID: String? = nil,
        messageID: String? = nil,
        partID: String? = nil
    ) {
        guard isCapturingStreamingDiagnostics else { return }

        let breadcrumb = OpenCodeChatBreadcrumb(
            event: event,
            sessionID: sessionID,
            selectedSessionID: selectedSession?.id,
            directory: effectiveSelectedDirectory ?? streamDirectory,
            messageID: messageID,
            partID: partID,
            messageCount: messages.count,
            assistantTextLength: currentAssistantTextLength()
        )
        chatBreadcrumbs.append(breadcrumb)
        if chatBreadcrumbs.count > 80 {
            chatBreadcrumbs.removeFirst(chatBreadcrumbs.count - 80)
        }
        saveChatBreadcrumbs(chatBreadcrumbs)
    }

    func copyChatBreadcrumbs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return chatBreadcrumbs.map { breadcrumb in
            [
                "[\(formatter.string(from: breadcrumb.createdAt))]",
                breadcrumb.event,
                "session=\(breadcrumb.sessionID ?? "nil")",
                "selected=\(breadcrumb.selectedSessionID ?? "nil")",
                "dir=\(breadcrumb.directory ?? "nil")",
                "message=\(breadcrumb.messageID ?? "nil")",
                "part=\(breadcrumb.partID ?? "nil")",
                "count=\(breadcrumb.messageCount)",
                "alen=\(breadcrumb.assistantTextLength)"
            ].joined(separator: " ")
        }.joined(separator: "\n")
    }

    func loadChatBreadcrumbs() -> [OpenCodeChatBreadcrumb] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.chatBreadcrumbs) else { return [] }
        return (try? JSONDecoder().decode([OpenCodeChatBreadcrumb].self, from: data)) ?? []
    }

    func saveChatBreadcrumbs(_ breadcrumbs: [OpenCodeChatBreadcrumb]) {
        guard let data = try? JSONEncoder().encode(breadcrumbs) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.chatBreadcrumbs)
    }

    func eventIdentitySummary(for payload: OpenCodeEventEnvelope) -> String {
        let infoID = payload.properties.info?.id ?? "nil"
        let infoRole = payload.properties.info?.role ?? "nil"
        let messageID = payload.properties.messageID ?? payload.properties.part?.messageID ?? "nil"
        let partID = payload.properties.partID ?? payload.properties.part?.id ?? "nil"
        let partType = payload.properties.part?.type ?? "nil"
        let sessionID = payload.properties.sessionID ?? payload.properties.info?.sessionID ?? payload.properties.part?.sessionID ?? "nil"
        return "event ids type=\(payload.type) session=\(sessionID) info=\(infoID):\(infoRole) message=\(messageID) part=\(partID):\(partType)"
    }

    func probeLabel(for url: URL) -> String {
        if url.path.contains("/global/") {
            return "global"
        }
        return "scoped"
    }

    static func debugRawLine(_ line: String) -> String {
        if line.isEmpty {
            return "<blank>"
        }
        return String(line.prefix(180))
    }
}
