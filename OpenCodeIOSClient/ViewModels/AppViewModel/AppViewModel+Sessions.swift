import Foundation
import SwiftUI

extension AppViewModel {
    func reloadSessions() async throws {
        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(client: client, directory: effectiveSelectedDirectory)
        withAnimation(opencodeSelectionAnimation) {
            directoryState.sessions = bootstrap.sessions
        }
        prefetchSessionPreviews(for: directoryState.sessions)
        withAnimation(opencodeSelectionAnimation) {
            directoryState.permissions = bootstrap.permissions
            directoryState.questions = bootstrap.questions
        }
        if let selectedSessionID = directoryState.selectedSession?.id,
           let refreshed = directoryState.sessions.first(where: { $0.id == selectedSessionID }) {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.selectedSession = refreshed
            }
            streamDirectory = refreshed.directory
        } else {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.selectedSession = nil
                directoryState.messages = []
                directoryState.todos = []
            }
            if streamDirectory == nil {
                streamDirectory = directoryState.sessions.first?.directory
            }
        }
        if streamDirectory == nil {
            streamDirectory = directoryState.sessions.first?.directory
        }

        try await reloadSessionStatuses()
    }

    func reloadSessionStatuses() async throws {
        directoryState.sessionStatuses = try await client.listSessionStatuses(directory: effectiveSelectedDirectory)
    }

    func createSession() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let session = try await client.createSession(title: title.isEmpty ? nil : title, directory: effectiveSelectedDirectory)
            draftTitle = ""
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateSessionSheet = false
            }
            upsertVisibleSession(session)
            try await reloadSessions()
            upsertVisibleSession(session)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.selectedSession = session
            }
            streamDirectory = session.directory
            withAnimation(opencodeSelectionAnimation) {
                directoryState.todos = []
            }
            try await loadMessages(for: session)
            seedComposerSelectionsForNewSession(session)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ session: OpenCodeSession) async {
        withAnimation(opencodeSelectionAnimation) {
            directoryState.selectedSession = session
            directoryState.todos = []
        }
        streamDirectory = session.directory
        do {
            async let messages: Void = loadMessages(for: session)
            async let statuses: Void = reloadSessionStatuses()
            _ = try await (messages, statuses)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentMessage() async {
        guard let selectedSessionID = selectedSession?.id else { return }
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        await sendMessage(text, sessionID: selectedSessionID, userVisible: true)
    }

    func stopCurrentSession() async {
        guard let selectedSession else { return }

        do {
            try await client.abortSession(sessionID: selectedSession.id)
        } catch {
            appendDebugLog("abort error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        do {
            async let statuses: Void = reloadSessionStatuses()
            async let messages: Void = loadMessages(for: selectedSession)
            _ = try await (statuses, messages)
        } catch {
            appendDebugLog("post-abort refresh error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func sendMessage(_ text: String, sessionID: String, userVisible: Bool) async {
        guard let session = session(matching: sessionID) else { return }
        await sendMessage(text, in: session, userVisible: userVisible)
    }

    func sendMessage(_ text: String, in selectedSession: OpenCodeSession, userVisible: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard directoryState.sessionStatuses[selectedSession.id] != "busy" else {
            appendDebugLog("send blocked busy session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) streamDir=\(debugDirectoryLabel(streamDirectory))")
            return
        }

        let requestDirectory = sendDirectory(for: selectedSession)
        let messageID = OpenCodeIdentifier.message()
        let partID = OpenCodeIdentifier.part()
        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        let optimisticModel = modelReference.map {
            OpenCodeMessageModelReference(providerID: $0.providerID, modelID: $0.modelID, variant: variant)
        }

        let localUserMessage = OpenCodeMessageEnvelope.local(
            role: "user",
            text: trimmed,
            messageID: messageID,
            partID: partID,
            agent: agentName,
            model: optimisticModel
        )
        if userVisible {
            draftMessage = ""
            composerResetToken = UUID()
            withAnimation(opencodeSelectionAnimation) {
                directoryState.messages.append(localUserMessage)
            }
        }
        appendDebugLog("send: \(trimmed)")
        appendDebugLog(
            "send scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil") requestDir=\(debugDirectoryLabel(requestDirectory)) msgID=\(messageID) partID=\(partID)"
        )

        isLoading = true
        let previousStatus = directoryState.sessionStatuses[selectedSession.id]
        directoryState.sessionStatuses[selectedSession.id] = "busy"
        defer { isLoading = false }

        do {
            try await client.sendMessageAsync(
                sessionID: selectedSession.id,
                text: trimmed,
                directory: requestDirectory,
                messageID: nil,
                partID: nil,
                model: modelReference,
                agent: agentName,
                variant: variant
            )
            appendDebugLog("prompt_async accepted session=\(debugSessionLabel(selectedSession)) msgID=\(messageID) partID=\(partID)")
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 500ms")
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 2s")
            }
            startLiveRefresh(for: selectedSession, reason: "send")
            errorMessage = nil
        } catch {
            if userVisible {
                withAnimation(opencodeSelectionAnimation) {
                    directoryState.messages.removeAll { $0.id == localUserMessage.id }
                }
                draftMessage = trimmed
            }
            directoryState.sessionStatuses[selectedSession.id] = previousStatus
            appendDebugLog("send error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(for session: OpenCodeSession) async throws {
        let loadedMessages = try await client.listMessages(sessionID: session.id)
        guard selectedSession?.id == session.id else { return }
        appendDebugLog(serverMessageSummary(loadedMessages, sessionID: session.id, reason: "loadMessages"))
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

    @MainActor
    func logServerMessageSnapshot(for session: OpenCodeSession, reason: String) async {
        do {
            let loadedMessages = try await client.listMessages(sessionID: session.id)
            appendDebugLog(serverMessageSummary(loadedMessages, sessionID: session.id, reason: reason))
        } catch {
            appendDebugLog("server snapshot failed session=\(debugSessionLabel(session)) reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    func serverMessageSummary(_ messages: [OpenCodeMessageEnvelope], sessionID: String, reason: String) -> String {
        let tail = messages.suffix(4).map { message in
            let parts = message.parts.map { part in
                let text = (part.text ?? "").replacingOccurrences(of: "\n", with: "\\n")
                let snippet = String(text.prefix(40))
                return "\(part.id):\(part.type ?? "nil"):\(snippet)"
            }.joined(separator: "|")
            return "\(message.id):\(message.info.role ?? "nil")[\(parts)]"
        }.joined(separator: "; ")

        return "server snapshot session=\(sessionID) reason=\(reason) count=\(messages.count) tail=\(tail)"
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
            let todos = try await client.getTodos(sessionID: session.id)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.todos = todos
            }
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.todos = []
            }
        }
    }

    func loadAllPermissions() async {
        do {
            let permissions = try await client.listPermissions()
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions = permissions
            }
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions = []
            }
        }
    }

    func loadAllQuestions() async {
        do {
            let questions = try await client.listQuestions()
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions = questions
            }
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions = []
            }
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
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions.removeAll { $0.id == permission.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        withAnimation(opencodeSelectionAnimation) {
            directoryState.permissions.removeAll { $0.id == permission.id }
        }
    }

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]]) async {
        do {
            try await client.replyToQuestion(requestID: request.id, answers: answers)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions.removeAll { $0.id == request.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest) async {
        do {
            try await client.rejectQuestion(requestID: request.id)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions.removeAll { $0.id == request.id }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: OpenCodeSession) async {
        do {
            try await client.deleteSession(sessionID: session.id)
            sessionPreviews[session.id] = nil
            if directoryState.selectedSession?.id == session.id {
                withAnimation(opencodeSelectionAnimation) {
                    directoryState.selectedSession = nil
                    directoryState.messages = []
                }
            }
            try await reloadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentCreateSessionSheet() {
        draftTitle = ""
        withAnimation(opencodeSelectionAnimation) {
            isShowingCreateSessionSheet = true
        }
    }

    func upsertVisibleSession(_ session: OpenCodeSession) {
        withAnimation(opencodeSelectionAnimation) {
            if let index = directoryState.sessions.firstIndex(where: { $0.id == session.id }) {
                directoryState.sessions[index] = session
            } else {
                directoryState.sessions.insert(session, at: 0)
            }
        }
    }

    func session(matching sessionID: String) -> OpenCodeSession? {
        if let selectedSession, selectedSession.id == sessionID {
            return selectedSession
        }

        return directoryState.sessions.first(where: { $0.id == sessionID })
    }

    func sendDirectory(for session: OpenCodeSession) -> String? {
        appendDebugLog(
            "sendDirectory session=\(debugSessionLabel(session)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil")"
        )
        // Keep existing sessions bound to the directory they were created in.
        if let sessionDirectory = session.directory,
           !sessionDirectory.isEmpty {
            return sessionDirectory
        }

        if let directory = effectiveSelectedDirectory, !directory.isEmpty {
            return directory
        }

        if currentProject?.id == "global" {
            return nil
        }

        return session.directory
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
