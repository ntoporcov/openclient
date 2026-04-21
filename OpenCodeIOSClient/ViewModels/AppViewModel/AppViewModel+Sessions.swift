import Foundation

extension AppViewModel {
    func reloadSessions() async throws {
        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(client: client, directory: effectiveSelectedDirectory)
        directoryState.sessions = bootstrap.sessions
        prefetchSessionPreviews(for: directoryState.sessions)
        directoryState.permissions = bootstrap.permissions
        directoryState.questions = bootstrap.questions
        if let selectedSessionID = directoryState.selectedSession?.id,
           let refreshed = directoryState.sessions.first(where: { $0.id == selectedSessionID }) {
            directoryState.selectedSession = refreshed
            streamDirectory = refreshed.directory
        } else {
            directoryState.selectedSession = nil
            directoryState.messages = []
            directoryState.todos = []
            if streamDirectory == nil {
                streamDirectory = directoryState.sessions.first?.directory
            }
        }
        if streamDirectory == nil {
            streamDirectory = directoryState.sessions.first?.directory
        }
    }

    func createSession() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = try await client.createSession(title: title.isEmpty ? nil : title, directory: effectiveSelectedDirectory)
            draftTitle = ""
            isShowingCreateSessionSheet = false
            try await reloadSessions()
            directoryState.selectedSession = session
            streamDirectory = session.directory
            directoryState.todos = []
            try await loadMessages(for: session)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ session: OpenCodeSession) async {
        directoryState.selectedSession = session
        streamDirectory = session.directory
        directoryState.todos = []
        do {
            try await loadMessages(for: session)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentMessage() async {
        guard let selectedSession else { return }
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        await sendMessage(text, in: selectedSession, userVisible: true)
    }

    func sendMessage(_ text: String, in selectedSession: OpenCodeSession, userVisible: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let localUserMessage = OpenCodeMessageEnvelope.local(role: "user", text: trimmed)
        if userVisible {
            draftMessage = ""
            composerResetToken = UUID()
            directoryState.messages.append(localUserMessage)
        }
        appendDebugLog("send: \(trimmed)")

        isLoading = true
        defer { isLoading = false }

        do {
            try await client.sendMessageAsync(
                sessionID: selectedSession.id,
                text: trimmed,
                directory: selectedSession.directory,
                model: effectiveModelReference(for: selectedSession),
                agent: effectiveAgentName(for: selectedSession),
                variant: selectedVariant(for: selectedSession)
            )
            startLiveRefresh(for: selectedSession, reason: "send")
            errorMessage = nil
        } catch {
            if userVisible {
                directoryState.messages.removeAll { $0.id == localUserMessage.id }
                draftMessage = trimmed
            }
            appendDebugLog("send error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(for session: OpenCodeSession) async throws {
        let loadedMessages = try await client.listMessages(sessionID: session.id)
        directoryState.messages = mergeMessagesPreservingStreamProgress(existing: directoryState.messages, loaded: loadedMessages)
        reconcileOptimisticUserMessages()
        syncComposerSelections(for: session)
        prefetchToolMessageDetails(for: session, messages: directoryState.messages)
        await loadTodos(for: session)
    }

    func mergeMessagesPreservingStreamProgress(
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

    func reconcileOptimisticUserMessages() {
        var canonicalUserTextCounts: [String: Int] = [:]

        for message in directoryState.messages {
            guard !isOptimisticLocalUserMessage(message), let text = normalizedUserText(for: message) else { continue }
            canonicalUserTextCounts[text, default: 0] += 1
        }

        var remainingCanonicalUserTextCounts = canonicalUserTextCounts

        directoryState.messages.removeAll { message in
            guard isOptimisticLocalUserMessage(message),
                  let text = normalizedUserText(for: message),
                  let count = remainingCanonicalUserTextCounts[text],
                  count > 0 else {
                return false
            }

            remainingCanonicalUserTextCounts[text] = count - 1
            return true
        }
    }

    func isOptimisticLocalUserMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
        (message.info.role ?? "").lowercased() == "user" && message.info.sessionID == nil
    }

    func normalizedUserText(for message: OpenCodeMessageEnvelope) -> String? {
        guard (message.info.role ?? "").lowercased() == "user" else { return nil }

        let text = message.parts
            .compactMap(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? nil : text
    }

    func fetchMessageDetails(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
           let detail = toolMessageDetails[messageID] {
            return detail
        }

        let detail = try await client.getMessage(sessionID: sessionID, messageID: messageID)
        toolMessageDetails[messageID] = detail
        return detail
    }

    func refreshTodosAndLatestTodoMessage() async throws -> (todos: [OpenCodeTodo], detail: OpenCodeMessageEnvelope?) {
        guard let selectedSession else {
            return (todos, nil)
        }

        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            let latestTodoMessageID = directoryState.messages
                .reversed()
                .first { envelope in
                    envelope.parts.contains(where: { $0.tool == "todowrite" })
                }?
                .info.id

            return (directoryState.todos, latestTodoMessageID.flatMap { toolMessageDetails[$0] })
        }

        let refreshedTodos = try await client.getTodos(sessionID: selectedSession.id)
        directoryState.todos = refreshedTodos

        let latestTodoMessageID = directoryState.messages
            .reversed()
            .first { envelope in
                envelope.parts.contains(where: { $0.tool == "todowrite" })
            }?
            .info.id

        guard let latestTodoMessageID else {
            return (refreshedTodos, nil)
        }

        let detail = try await fetchMessageDetails(sessionID: selectedSession.id, messageID: latestTodoMessageID)
        return (refreshedTodos, detail)
    }

    func loadTodos(for session: OpenCodeSession) async {
        do {
            directoryState.todos = try await client.getTodos(sessionID: session.id)
        } catch {
            directoryState.todos = []
        }
    }

    func loadAllPermissions() async {
        do {
            directoryState.permissions = try await client.listPermissions()
        } catch {
            directoryState.permissions = []
        }
    }

    func loadAllQuestions() async {
        do {
            directoryState.questions = try await client.listQuestions()
        } catch {
            directoryState.questions = []
        }
    }

    var selectedSessionPermissions: [OpenCodePermission] {
        guard let selectedSession else { return [] }
        return permissions.filter { $0.sessionID == selectedSession.id }
    }

    var selectedSessionQuestions: [OpenCodeQuestionRequest] {
        guard let selectedSession else { return [] }
        return questions.filter { $0.sessionID == selectedSession.id }
    }

    func hasPermissionRequest(for session: OpenCodeSession) -> Bool {
        permissions.contains { $0.sessionID == session.id }
    }

    func respondToPermission(_ permission: OpenCodePermission, response: String) async {
        do {
            let reply: String
            switch response {
            case "allow":
                reply = "once"
            case "deny":
                reply = "reject"
            default:
                reply = response
            }

            try await client.replyToPermission(requestID: permission.id, reply: reply)
            directoryState.permissions.removeAll { $0.id == permission.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        directoryState.permissions.removeAll { $0.id == permission.id }
    }

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]]) async {
        do {
            try await client.replyToQuestion(requestID: request.id, answers: answers)
            directoryState.questions.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest) async {
        do {
            try await client.rejectQuestion(requestID: request.id)
            directoryState.questions.removeAll { $0.id == request.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: OpenCodeSession) async {
        do {
            try await client.deleteSession(sessionID: session.id)
            sessionPreviews[session.id] = nil
            if directoryState.selectedSession?.id == session.id {
                directoryState.selectedSession = nil
                directoryState.messages = []
            }
            try await reloadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentCreateSessionSheet() {
        draftTitle = ""
        isShowingCreateSessionSheet = true
    }

    func prefetchToolMessageDetails(for session: OpenCodeSession, messages: [OpenCodeMessageEnvelope]) {
        let toolMessageIDs = Set(messages.filter { envelope in
            envelope.parts.contains(where: { $0.type == "tool" })
        }.map(\.info.id))

        for messageID in toolMessageIDs where toolMessageDetails[messageID] == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let detail = try await self.client.getMessage(sessionID: session.id, messageID: messageID)
                    await MainActor.run {
                        self.toolMessageDetails[messageID] = detail
                    }
                } catch {
                    return
                }
            }
        }
    }
}
