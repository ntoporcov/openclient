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
            onEvent: { [weak self] managed in
                await MainActor.run {
                    self?.lastStreamEventAt = .now
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

        let payload = managed.envelope
        let selectedSession = directoryState.selectedSession

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: managed.typed,
            state: &directoryState
        )

        switch result {
        case let .message(reason):
            reconcileOptimisticUserMessages()
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
        case .sessionChanged:
            appendDebugLog("session changed")
        case .todoChanged:
            appendDebugLog("todo changed")
        case .permissionChanged:
            appendDebugLog("permission changed")
            Task { [weak self] in
                await self?.loadAllPermissions()
            }
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

        if let selectedSession,
           payload.type == "session.diff",
           payload.properties.sessionID == selectedSession.id {
            Task { [weak self] in
                await self?.loadTodos(for: selectedSession)
            }
        }

        if payload.type == "question.asked" {
            Task { [weak self] in
                await self?.loadAllQuestions()
            }
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
