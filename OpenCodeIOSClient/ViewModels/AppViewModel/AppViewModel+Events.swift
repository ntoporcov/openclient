import Foundation

extension AppViewModel {
    private static let shortStreamDeltaCoalescingInterval: Duration = .milliseconds(50)
    private static let mediumStreamDeltaCoalescingInterval: Duration = .milliseconds(90)
    private static let longStreamDeltaCoalescingInterval: Duration = .milliseconds(140)
    private static let veryLongStreamDeltaCoalescingInterval: Duration = .milliseconds(220)

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
        guard eventSyncCoordinator.shouldProcessEvent(isConnected: isConnected) else { return }

        if shouldLogEventDetails(for: managed.envelope.type) {
            appendDebugLog(eventScopeSummary(for: managed))
            appendDebugLog(eventIdentitySummary(for: managed.envelope))
        }

        if let globalAction = eventSyncCoordinator.applyGlobalEvent(
            managed,
            projects: &projects,
            currentProject: &currentProject
        ) {
            switch globalAction {
            case .refreshProjectsAndSessions:
                Task { [weak self] in
                    try? await self?.refreshProjects()
                    try? await self?.reloadSessions()
                }
            }
            return
        }

        if shouldSkipInactiveLiveMessageEvent(managed) {
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
                sessionStatuses[sessionID] = "idle"
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
        let currentSelectedSession = selectedSession
        let eventSessionID = managedEventSessionID(for: managed)

        updateCachedMessagesForLiveActivityIfNeeded(payload: payload, sessionID: eventSessionID, selectedSessionID: currentSelectedSession?.id)

        let application = eventSyncCoordinator.applyDirectoryEvent(managed, to: directoryEventState())
        applyDirectoryEventState(application.state)
        let result = application.result

        switch result {
        case let .message(reason):
            if let currentSelectedSession, shouldRefreshSessionPreview(for: currentSelectedSession.id, eventType: payload.type) {
                refreshSessionPreview(for: currentSelectedSession.id, messages: messages)
            }
            scheduleLiveActivityPreviewRefreshIfNeeded(for: managedEventSessionID(for: managed))
            if let currentSelectedSession,
               payload.type == "message.updated",
               payload.properties.info?.role == "user",
               payload.properties.info?.sessionID == currentSelectedSession.id {
                syncComposerSelections(for: currentSelectedSession)
            }
            debugLastEventSummary = debugSummary(for: payload)
            appendDebugLog(debugSummary(for: payload))
            appendDebugLog("apply \(payload.type): \(reason) count \(messages.count)")

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
            if let currentSelectedSession {
                refreshSessionPreview(for: currentSelectedSession.id, messages: messages)
            }
            if let currentSelectedSession {
                scheduleReload(for: currentSelectedSession)
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
            removePinnedSessionIDFromAllScopes(session.id)
            removeSessionPreview(for: session.id)
            if activeLiveActivitySessionIDs.contains(session.id) {
                Task { [weak self] in
                    await self?.stopLiveActivity(for: session.id, immediate: true)
                }
            }
        case let .vcsBranchUpdated(branch):
            projectFilesStore.applyBranchUpdate(branch)
            refreshVCSFromEvent()
        case let .fileWatcherUpdated(file):
            guard !file.hasPrefix(".git/") else { break }
            refreshVCSFromEvent()
        default:
            break
        }

        if let currentSelectedSession,
           payload.type == "session.diff",
           payload.properties.sessionID == currentSelectedSession.id {
            Task { [weak self] in
                await self?.loadTodos(for: currentSelectedSession)
            }
        }

        refreshLiveActivityIfNeeded(
            for: eventSessionID,
            immediate: Self.shouldRefreshLiveActivityImmediately(after: result, event: managed.typed)
        )
        if shouldPublishWidgetSnapshots(after: result) {
            publishWidgetSnapshots()
        }
    }

    nonisolated static func shouldRefreshLiveActivityImmediately(after result: SessionEventResult, event: OpenCodeTypedEvent) -> Bool {
        switch result {
        case .permissionChanged, .questionChanged:
            return true
        default:
            break
        }

        switch event {
        case .permissionAsked, .permissionReplied, .questionAsked, .questionReplied, .questionRejected:
            return true
        default:
            return false
        }
    }

    private func shouldRefreshSessionPreview(for sessionID: String, eventType: String) -> Bool {
        guard eventType != "message.part.delta" else { return false }
        return sessionStatuses[sessionID] != "busy"
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

        chatStore.enqueuePendingTranscriptEvent(
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
        ChatStore.shouldBufferTranscriptEvent(
            managed.typed,
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID
        )
    }

    private func shouldFlushPendingTranscriptEvents(before managed: OpenCodeManagedEvent) -> Bool {
        chatStore.hasPendingTranscriptEvents
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
            let interval = self?.streamDeltaCoalescingInterval() ?? Self.shortStreamDeltaCoalescingInterval
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flushPendingTranscriptEvents(reason: "timer")
        }
    }

    private func streamDeltaCoalescingInterval() -> Duration {
        chatStore.streamDeltaCoalescingInterval(
            short: Self.shortStreamDeltaCoalescingInterval,
            medium: Self.mediumStreamDeltaCoalescingInterval,
            long: Self.longStreamDeltaCoalescingInterval,
            veryLong: Self.veryLongStreamDeltaCoalescingInterval
        )
    }

    private func flushPendingTranscriptEvents(reason: String) {
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil

        let now = Date()
        guard let pending = chatStore.drainPendingTranscriptEvents() else { return }
        let events = pending.events
        let reducerEvents = pending.coalescedEvents
        let application = eventSyncCoordinator.applyDirectoryEvents(reducerEvents.map(\.typedEvent), to: directoryEventState())
        applyDirectoryEventState(application.state)

        for sessionID in Set(events.compactMap(\.sessionID)) {
            refreshLiveActivityIfNeeded(for: sessionID)
        }

        logStreamDeltaFlush(reason: reason, events: events, appliedCount: application.messageApplyCount, coalescedCount: reducerEvents.count, flushedAt: now)
    }

    private func directoryEventState() -> EventSyncCoordinator.DirectoryEventState {
        EventSyncCoordinator.DirectoryEventState(
            sessions: allSessions,
            selectedSession: selectedSession,
            sessionStatuses: sessionStatuses,
            messages: messages,
            todos: todos,
            permissions: permissions,
            questions: questions
        )
    }

    private func applyDirectoryEventState(_ state: EventSyncCoordinator.DirectoryEventState) {
        if state.sessions != allSessions {
            allSessions = state.sessions
        }
        if state.selectedSession != selectedSession {
            selectedSession = state.selectedSession
        }
        if state.sessionStatuses != sessionStatuses {
            sessionStatuses = state.sessionStatuses
        }
        if state.messages != messages {
            messages = state.messages
        }
        if state.todos != todos {
            objectWillChange.send()
            sessionInteractionStore.replaceTodos(state.todos)
        }
        if state.permissions != permissions {
            objectWillChange.send()
            sessionInteractionStore.replacePermissions(state.permissions)
        }
        if state.questions != questions {
            objectWillChange.send()
            sessionInteractionStore.replaceQuestions(state.questions)
        }
    }

    private func logStreamDeltaFlush(reason: String, events: [OpenCodePendingTranscriptEvent], appliedCount: Int, coalescedCount: Int, flushedAt now: Date) {
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
            "transcript flush reason=\(reason) count=\(events.count) coalesced=\(coalescedCount) applied=\(appliedCount) chars=\(chars) wait=\(waitMS)ms cadence=\(cadence) target=\(target) focused=\(isComposerStreamingFocused) types=\(types)"
        )
    }

    nonisolated static func shouldProcessLiveMessageEvent(
        eventType: String,
        eventSessionID: String?,
        activeChatSessionID: String?,
        activeLiveActivitySessionIDs: Set<String>,
        affectsSelectedTranscript: Bool
    ) -> Bool {
        guard isLiveActivityMessageEventType(eventType) else { return true }

        if let eventSessionID, activeLiveActivitySessionIDs.contains(eventSessionID) {
            return true
        }

        if let eventSessionID, eventSessionID == activeChatSessionID {
            return true
        }

        // Some removal events only carry message ids. Keep those when they match the selected transcript.
        if eventSessionID == nil, affectsSelectedTranscript {
            return true
        }

        return false
    }

    private func shouldSkipInactiveLiveMessageEvent(_ managed: OpenCodeManagedEvent) -> Bool {
        let eventSessionID = managedEventSessionID(for: managed)
        let affectsSelectedTranscript = eventSessionID == nil ? eventAffectsActiveSession(managed) : false
        return !eventSyncCoordinator.shouldProcessLiveMessageEvent(
            eventType: managed.envelope.type,
            eventSessionID: eventSessionID,
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID,
            activeLiveActivitySessionIDs: activeLiveActivitySessionIDs,
            affectsSelectedTranscript: affectsSelectedTranscript
        )
    }

    private func isLiveActivityMessageEvent(_ type: String) -> Bool {
        EventSyncCoordinator.isLiveActivityMessageEventType(type)
    }

    nonisolated private static func isLiveActivityMessageEventType(_ type: String) -> Bool {
        EventSyncCoordinator.isLiveActivityMessageEventType(type)
    }

    private func updateCachedMessagesForLiveActivityIfNeeded(payload: OpenCodeEventEnvelope, sessionID: String?, selectedSessionID: String?) {
        guard let sessionID,
              sessionID != selectedSessionID,
              activeLiveActivitySessionIDs.contains(sessionID),
              isLiveActivityMessageEvent(payload.type) else {
            return
        }

        guard let cachedMessages = chatStore.updateCachedMessagesForLiveActivity(payload: payload, sessionID: sessionID) else { return }
        if sessionStatuses[sessionID] != "busy" {
            refreshSessionPreview(for: sessionID, messages: cachedMessages)
        }
    }

    private func shouldApplyDirectoryEvent(from managed: OpenCodeManagedEvent) -> Bool {
        let eventDirectory = managed.directory
        let eventSessionID = managedEventSessionID(for: managed)

        return eventSyncCoordinator.shouldApplyDirectoryEvent(
            eventDirectory: eventDirectory,
            eventSessionID: eventSessionID,
            selectedSessionID: selectedSession?.id,
            selectedSessionDirectory: selectedSession?.directory,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            activeLiveActivitySessionIDs: activeLiveActivitySessionIDs
        )
    }

    private func managedEventSessionID(for managed: OpenCodeManagedEvent) -> String? {
        eventSyncCoordinator.sessionID(for: managed.typed)
    }

    private func triggerStreamPartHapticIfNeeded(for managed: OpenCodeManagedEvent) {
        guard shouldEmitStreamPartHaptic(for: managed) else { return }

        let now = Date()
        guard now >= nextStreamPartHapticAllowedAt else { return }

        OpenCodeHaptics.impact(.crisp)
        nextStreamPartHapticAllowedAt = now.addingTimeInterval(nextStreamPartHapticInterval())
    }

    private func shouldEmitStreamPartHaptic(for managed: OpenCodeManagedEvent) -> Bool {
        ChatStore.shouldEmitStreamPartHaptic(
            for: managed.typed,
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID,
            messages: messages
        )
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
        eventSyncCoordinator.eventAffectsSelectedSession(
            managed.typed,
            selectedSessionID: selectedSession?.id,
            selectedMessages: messages,
            hasGitProject: hasGitProject
        )
    }

    func scheduleReload(for session: OpenCodeSession) {
        reloadTask?.cancel()

        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.isConnected else { return }
            self.markChatBreadcrumb("idle reconcile start", sessionID: session.id)
            do {
                try await self.loadMessages(for: session)
                self.markChatBreadcrumb("idle reconcile finish", sessionID: session.id)
            } catch {
                self.markChatBreadcrumb("idle reconcile error", sessionID: session.id)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func startLiveRefresh(for session: OpenCodeSession, reason: String) {
        liveRefreshGeneration += 1
        let generation = liveRefreshGeneration
        chatStore.beginFallbackRefreshTracking()
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { [weak self] in
            let delays: [Duration] = [
                .milliseconds(1_500), .seconds(3), .seconds(5),
            ]

            for delay in delays {
                try? await Task.sleep(for: delay)
                guard let self, self.isConnected, self.selectedSession?.id == session.id else { return }
                guard self.liveRefreshGeneration == generation else { return }
                guard Date.now.timeIntervalSince(self.lastStreamEventAt) >= 1.25 else { continue }

                do {
                    self.markChatBreadcrumb("fallback refresh start \(reason)", sessionID: session.id)
                    try await self.loadMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
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
        chatStore.fallbackRefreshSummary(reason: reason)
    }

    func currentAssistantTextLength() -> Int {
        chatStore.currentAssistantTextLength
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
