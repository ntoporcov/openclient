import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

extension AppViewModel {
    private static let liveActivityGracePeriod: TimeInterval = 180

    func toggleLiveActivity(for session: OpenCodeSession) async {
        if activeLiveActivitySessionIDs.contains(session.id) {
            await stopLiveActivity(for: session.id, immediate: true)
        } else {
            await startLiveActivity(for: session)
        }
    }

    func startLiveActivity(for session: OpenCodeSession, userVisibleErrors: Bool = true) async {
        #if canImport(ActivityKit) && os(iOS)
        do {
            let state = liveActivityState(for: session)
            let sessionID = session.id
            let sessionTitle = liveActivitySessionTitle(for: session)
            let configSnapshot = config
            let sessionDirectory = session.directory
            let workspaceID = session.workspaceID

            try await Task.detached(priority: .userInitiated) {
                if let existing = Activity<OpenCodeChatActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) {
                    await existing.update(ActivityContent(state: state, staleDate: nil))
                    return
                }

                _ = try Activity.request(
                    attributes: OpenCodeChatActivityAttributes(
                        sessionID: sessionID,
                        sessionTitle: sessionTitle,
                        credentialID: configSnapshot.recentServerID,
                        serverBaseURL: configSnapshot.baseURL,
                        serverUsername: configSnapshot.username,
                        directory: sessionDirectory,
                        workspaceID: workspaceID
                    ),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
            }.value
            activeLiveActivitySessionIDs.insert(session.id)
            if userVisibleErrors {
                errorMessage = nil
            }
        } catch {
            if userVisibleErrors {
                errorMessage = error.localizedDescription
            }
        }
        #endif
    }

    func maybeAutoStartLiveActivity(for session: OpenCodeSession) async {
        guard !isUsingAppleIntelligence, isLiveActivityAutoStartEnabled else { return }
        guard !activeLiveActivitySessionIDs.contains(session.id) else { return }
        await startLiveActivity(for: session, userVisibleErrors: false)
    }

    func scheduleLiveActivityPreviewRefreshIfNeeded(for sessionID: String?) {
        guard let sessionID,
              activeLiveActivitySessionIDs.contains(sessionID),
              selectedSession?.id != sessionID,
              let session = session(matching: sessionID) ?? sessions.first(where: { $0.id == sessionID }) else {
            return
        }

        liveActivityPreviewRefreshTasksBySessionID[sessionID]?.cancel()
        liveActivityPreviewRefreshTasksBySessionID[sessionID] = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            do {
                let messages = try await self.client.listMessages(sessionID: session.id, directory: session.directory)
                self.cachedMessagesBySessionID[session.id] = messages
                self.refreshSessionPreview(for: session.id, messages: messages)
                self.refreshLiveActivityIfNeeded(for: session.id)
            } catch {
                return
            }

            self.liveActivityPreviewRefreshTasksBySessionID[sessionID] = nil
        }
    }

    func stopLiveActivity(for session: OpenCodeSession, immediate: Bool = false) async {
        await stopLiveActivity(for: session.id, immediate: immediate)
    }

    func stopLiveActivity(for sessionID: String, immediate: Bool = false) async {
        #if canImport(ActivityKit) && os(iOS)
        let session = session(matching: sessionID) ?? sessions.first(where: { $0.id == sessionID }) ?? (selectedSession?.id == sessionID ? selectedSession : nil)
        let finalState = session.map { liveActivityState(for: $0) }
        let gracePeriod = immediate ? nil : Self.liveActivityGracePeriod
        await Task.detached(priority: .userInitiated) {
            guard let activity = Activity<OpenCodeChatActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) else { return }
            let dismissalPolicy: ActivityUIDismissalPolicy = {
                guard let gracePeriod else { return .immediate }
                return .after(Date().addingTimeInterval(gracePeriod))
            }()
            await activity.end(ActivityContent(state: finalState ?? activity.content.state, staleDate: nil), dismissalPolicy: dismissalPolicy)
        }.value
        activeLiveActivitySessionIDs.remove(sessionID)
        #endif
    }

    func refreshLiveActivityIfNeeded(for sessionID: String? = nil, endIfIdle: Bool = false) {
        #if canImport(ActivityKit) && os(iOS)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let targetSessionIDs: [String]
            if let sessionID {
                guard self.activeLiveActivitySessionIDs.contains(sessionID) else { return }
                targetSessionIDs = [sessionID]
            } else {
                targetSessionIDs = Array(self.activeLiveActivitySessionIDs)
            }

            for targetSessionID in targetSessionIDs {
                guard let session = self.session(matching: targetSessionID) ?? self.sessions.first(where: { $0.id == targetSessionID }) ?? (self.selectedSession?.id == targetSessionID ? self.selectedSession : nil) else {
                    continue
                }

                let state = self.liveActivityState(for: session)
                if endIfIdle && self.directoryState.sessionStatuses[targetSessionID] == "idle" {
                    await Task.detached(priority: .utility) {
                        guard let activity = Activity<OpenCodeChatActivityAttributes>.activities.first(where: { $0.attributes.sessionID == targetSessionID }) else { return }
                        await activity.end(
                            ActivityContent(state: state, staleDate: nil),
                            dismissalPolicy: .after(Date().addingTimeInterval(Self.liveActivityGracePeriod))
                        )
                    }.value
                    self.activeLiveActivitySessionIDs.remove(targetSessionID)
                    continue
                }

                await Task.detached(priority: .utility) {
                    guard let activity = Activity<OpenCodeChatActivityAttributes>.activities.first(where: { $0.attributes.sessionID == targetSessionID }) else { return }
                    await activity.update(ActivityContent(state: state, staleDate: nil))
                }.value
            }
        }
        #endif
    }

    func handleLiveActivityURL(_ url: URL) async {
        guard url.scheme == OpenCodeChatActivityDeepLink.scheme,
              url.host == OpenCodeChatActivityDeepLink.host else {
            return
        }

        if !isConnected {
            guard hasSavedServer else { return }
            await connect()
            guard isConnected else { return }
        }

        let pathComponents = url.pathComponents
        guard pathComponents.count >= 3, pathComponents[1] == "session" else { return }

        let sessionID = pathComponents[2]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let action = queryItems.first(where: { $0.name == "action" })?.value
        let directory = queryItems.first(where: { $0.name == "directory" })?.value

        if !isUsingAppleIntelligence, effectiveSelectedDirectory != directory {
            await selectDirectory(directory)
        }

        await openSession(sessionID: sessionID)

        switch action {
        case "permission":
            guard let requestID = queryItems.first(where: { $0.name == "requestID" })?.value,
                  let reply = queryItems.first(where: { $0.name == "reply" })?.value,
                  let permission = permissions(for: sessionID).first(where: { $0.id == requestID }) else {
                return
            }
            await respondToPermission(permission, response: reply)
            refreshLiveActivityIfNeeded(for: sessionID)
        case "question":
            guard let requestID = queryItems.first(where: { $0.name == "requestID" })?.value,
                  let answer = queryItems.first(where: { $0.name == "answer" })?.value,
                  let question = questions(for: sessionID).first(where: { $0.id == requestID }) else {
                return
            }
            await respondToQuestion(question, answers: [[answer]])
            refreshLiveActivityIfNeeded(for: sessionID)
        default:
            return
        }
    }

    func isLiveActivityActive(for session: OpenCodeSession) -> Bool {
        activeLiveActivitySessionIDs.contains(session.id)
    }

    private func liveActivityState(for session: OpenCodeSession) -> OpenCodeChatActivityAttributes.ContentState {
        let pendingPermission = permissions(for: session.id).first
        let pendingQuestion = questions(for: session.id).first
        let latestSnippet = liveActivityLatestSnippet(for: session)
        let status = liveActivityStatusText(for: session, hasPendingInteraction: pendingPermission != nil || pendingQuestion != nil)

        if let pendingPermission {
            return OpenCodeChatActivityAttributes.ContentState(
                status: status,
                latestSnippet: latestSnippet,
                updatedAt: .now,
                pendingInteractionKind: "permission",
                interactionID: pendingPermission.id,
                interactionTitle: pendingPermission.title,
                interactionSummary: pendingPermission.summary,
                questionOptionLabels: [],
                canReplyToQuestionInline: false
            )
        }

        if let pendingQuestion,
           let firstQuestion = pendingQuestion.questions.first {
            let optionLabels = Array(firstQuestion.options.map(\.label).prefix(3))
            let canReplyInline = pendingQuestion.questions.count == 1 &&
                firstQuestion.multiple == false &&
                optionLabels.isEmpty == false &&
                optionLabels.count == firstQuestion.options.count

            return OpenCodeChatActivityAttributes.ContentState(
                status: status,
                latestSnippet: latestSnippet,
                updatedAt: .now,
                pendingInteractionKind: "question",
                interactionID: pendingQuestion.id,
                interactionTitle: firstQuestion.header,
                interactionSummary: firstQuestion.question,
                questionOptionLabels: optionLabels,
                canReplyToQuestionInline: canReplyInline
            )
        }

        return OpenCodeChatActivityAttributes.ContentState(
            status: status,
            latestSnippet: latestSnippet,
            updatedAt: .now,
            pendingInteractionKind: nil,
            interactionID: nil,
            interactionTitle: nil,
            interactionSummary: nil,
            questionOptionLabels: [],
            canReplyToQuestionInline: false
        )
    }

    private func liveActivitySessionTitle(for session: OpenCodeSession) -> String {
        let title = childSessionTitle(for: session)
        return title.isEmpty ? "Session" : title
    }

    private func liveActivityStatusText(for session: OpenCodeSession, hasPendingInteraction: Bool) -> String {
        if hasPendingInteraction {
            return "Action"
        }

        switch directoryState.sessionStatuses[session.id] {
        case "busy":
            return "Live"
        case "idle":
            return "Ready"
        default:
            return "Live"
        }
    }

    private func liveActivityLatestSnippet(for session: OpenCodeSession) -> String {
        if selectedSession?.id == session.id {
            if let assistant = latestMeaningfulSnippet(in: messages, role: "assistant") {
                return assistant
            }
            if let user = latestMeaningfulSnippet(in: messages, role: "user") {
                return user
            }
        }

        if let cachedMessages = cachedMessagesBySessionID[session.id] {
            if let assistant = latestMeaningfulSnippet(in: cachedMessages, role: "assistant") {
                return assistant
            }
            if let user = latestMeaningfulSnippet(in: cachedMessages, role: "user") {
                return user
            }
        }

        return sessionPreviews[session.id]?.text ?? "No messages yet"
    }

    private func latestMeaningfulSnippet(in messages: [OpenCodeMessageEnvelope], role: String) -> String? {
        messages
            .reversed()
            .first(where: { ($0.info.role ?? "").lowercased() == role })?
            .parts
            .compactMap { part in
                part.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .pipe { opencodePreviewText($0, limit: 140) }
    }
}

private extension String {
    func pipe<T>(_ transform: (String) -> T) -> T {
        transform(self)
    }
}
