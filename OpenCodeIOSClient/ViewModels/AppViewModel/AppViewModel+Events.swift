import Foundation

extension AppViewModel {
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
        startDebugProbeStreams()
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
                    self?.appendDebugLog("event \(managed.envelope.type): \(managed.directory)")
                    self?.handleManagedEvent(managed)
                }
            }
        )
    }

    func stopEventStream() {
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

        appendDebugLog(eventScopeSummary(for: managed))
        appendDebugLog(eventIdentitySummary(for: managed.envelope))

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
            if let selectedSession {
                refreshSessionPreview(for: selectedSession.id, messages: directoryState.messages)
            }
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
            stopFallbackRefresh()
            if let selectedSession {
                scheduleReload(for: selectedSession)
            }
        case let .ignored(reason):
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

        refreshLiveActivityIfNeeded(for: managedEventSessionID(for: managed))
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
            ($0.info.role ?? "").lowercased() == "assistant"
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
            do {
                try await self.loadMessages(for: session)
                try await self.reloadSessions()
                await self.loadTodos(for: session)
            } catch {
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
                    try await self.loadMessages(for: session)
                    await self.loadTodos(for: session)
                    self.debugLastEventSummary = self.fallbackRefreshSummary(reason: reason)
                    self.appendDebugLog(self.debugLastEventSummary)
                } catch {
                    self.appendDebugLog("fallback error: \(error.localizedDescription)")
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
