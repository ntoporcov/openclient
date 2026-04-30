import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum AppleIntelligenceIntent: String, CaseIterable, Sendable {
    case chat
    case initialize
    case listDirectory = "list_directory"
    case readFile = "read_file"
    case searchFiles = "search_files"
    case writeFile = "write_file"
    case clarify

    var label: String {
        switch self {
        case .chat:
            return "chat"
        case .initialize:
            return "init"
        case .listDirectory:
            return "list_directory"
        case .readFile:
            return "read_file"
        case .searchFiles:
            return "search_files"
        case .writeFile:
            return "write_file"
        case .clarify:
            return "clarify"
        }
    }
}

extension AppViewModel {
    func prepareSessionSelection(_ session: OpenCodeSession) {
        let cachedMessages = cachedMessagesBySessionID[session.id] ?? []
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .sessions
            directoryState.selectedSession = session
            directoryState.isLoadingSelectedSession = true
            directoryState.messages = cachedMessages
            directoryState.todos = []
            directoryState.permissions = []
            directoryState.questions = []
            directoryState.selectedVCSFile = nil
        }
        restoreMessageDraft(for: session)
        streamDirectory = session.directory
    }

    var defaultAppleIntelligenceUserInstructions: String {
        """
        Default to using no tools.
        If the user is just greeting you, chatting casually, brainstorming, or asking a general question, respond normally without using any tools.
        Only use file tools when the user explicitly asks about the workspace, files, code, project structure, or asks you to inspect, search, read, write, list, browse, summarize, or modify something in the picked folder.
        Do not use tools just because a workspace exists.
        Do not inspect the workspace proactively.
        Do not call `list_directory` unless the user explicitly asks to list, browse, or explore files.
        If the user mentions a specific file or topic and clearly wants workspace information, prefer `read_file` or `search_files` over listing the whole directory.
        Answer from conversation context alone whenever possible.
        """
    }

    var defaultAppleIntelligenceSystemInstructions: String {
        """
        You are OpenCode running as an on-device Apple Intelligence demo inside a native iOS client.
        Answer the user's actual latest message directly.
        Do not restart the conversation with a greeting unless the user is greeting you first.
        Do not ignore the user's question.
        If the user asks a general knowledge or conversational question, answer it normally.
        Only shift into workspace help when the request is actually about the selected workspace.
        Never invent file contents.
        Paths are always relative to the selected workspace root unless you say otherwise.
        Keep answers practical and concise.
        Default to no tool usage.
        Do not use any tools for greetings, small talk, general advice, or brainstorming.
        Do not browse the workspace by default.
        Only use tools after an explicit user request that requires workspace inspection or modification.
        Only call `list_directory` when the user explicitly asks for a file listing or browsing step.
        Prefer `read_file` for named files and `search_files` for topic lookups when the user explicitly wants workspace information.
        """
    }

    func reloadSessions() async throws {
        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(client: client, directory: effectiveSelectedDirectory)
        withAnimation(opencodeSelectionAnimation) {
            directoryState.isLoadingSessions = false
            directoryState.sessions = bootstrap.sessions
            prunePinnedSessionsForCurrentScope()
        }
        withAnimation(opencodeSelectionAnimation) {
            directoryState.commands = bootstrap.commands
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

        if hasGitProject {
            await reloadGitViewData(force: true)
        }

        publishWidgetSnapshots()
    }

    func reloadSessionStatuses() async throws {
        directoryState.sessionStatuses = try await client.listSessionStatuses(directory: effectiveSelectedDirectory)
    }

    func createSession() async {
        guard canCreateSessionOrPresentPaywall() else { return }

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
                directoryState.isLoadingSelectedSession = true
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            withAnimation(opencodeSelectionAnimation) {
                directoryState.todos = []
            }
            try await loadMessages(for: session)
            seedComposerSelectionsForNewSession(session)
            await maybeAutoStartLiveActivity(for: session)
            recordCreatedSessionForMetering()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSession(_ session: OpenCodeSession) async {
        if isUsingAppleIntelligence {
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                directoryState.selectedSession = session
            }
            restoreMessageDraft(for: session)
            return
        }

        let didPrepareSelection = selectedSession?.id == session.id
        if !didPrepareSelection {
            prepareSessionSelection(session)
        }
        do {
            async let messages: Void = loadMessages(for: session)
            async let statuses: Void = reloadSessionStatuses()
            async let permissions: Void = loadAllPermissions(for: session)
            async let questions: Void = loadAllQuestions(for: session)
            _ = try await (messages, statuses, permissions, questions)
            restoreMessageDraftIfComposerIsEmpty(for: session)
            await maybeAutoStartLiveActivity(for: session)
            errorMessage = nil
        } catch {
            directoryState.isLoadingSelectedSession = false
            errorMessage = error.localizedDescription
        }
    }

    func sendCurrentMessage(meterPrompt: Bool = true) async {
        if isUsingAppleIntelligence {
            if meterPrompt, !reserveUserPromptIfAllowed() { return }
            await sendCurrentAppleIntelligenceMessage()
            return
        }

        guard let selectedSessionID = selectedSession?.id else { return }
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        if attachments.isEmpty, shouldOpenForkSheet(forSlashInput: text) {
            draftMessage = ""
            composerResetToken = UUID()
            presentForkSessionSheet()
            return
        }

        if let (command, arguments) = slashCommandInput(from: text) {
            if isForkClientCommand(command) {
                draftMessage = ""
                composerResetToken = UUID()
                presentForkSessionSheet()
                return
            }
            if isCompactClientCommand(command) {
                await compactSession(sessionID: selectedSessionID, userVisible: true, meterPrompt: meterPrompt)
                return
            }
            await sendCommand(command, arguments: arguments, attachments: attachments, sessionID: selectedSessionID, userVisible: true, meterPrompt: meterPrompt)
            return
        }

        await sendMessage(text, attachments: attachments, sessionID: selectedSessionID, userVisible: true, meterPrompt: meterPrompt)
    }

    func sendCommand(_ command: OpenCodeCommand, sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        await sendCommand(command, arguments: "", attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        await sendCommand(command, arguments: arguments, attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        guard let session = session(matching: sessionID) else { return }
        await sendCommand(command, arguments: arguments, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], in selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true) async {
        if isCompactClientCommand(command) {
            await compactSession(selectedSession, userVisible: userVisible, meterPrompt: meterPrompt)
            return
        }

        guard directoryState.sessionStatuses[selectedSession.id] != "busy" else {
            appendDebugLog("command blocked busy session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            return
        }

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("command blocked paywall session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            return
        }

        let requestDirectory = sendDirectory(for: selectedSession)
        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        let trimmedArguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftCommand = trimmedArguments.isEmpty ? "/\(command.name)" : "/\(command.name) \(trimmedArguments)"

        if userVisible {
            draftMessage = ""
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerResetToken = UUID()
        }

        appendDebugLog("command send: \(draftCommand)")
        appendDebugLog(
            "command scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) requestDir=\(debugDirectoryLabel(requestDirectory))"
        )

        isLoading = true
        let previousStatus = directoryState.sessionStatuses[selectedSession.id]
        directoryState.sessionStatuses[selectedSession.id] = "busy"
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await client.sendCommand(
                sessionID: selectedSession.id,
                command: command.name,
                arguments: trimmedArguments,
                attachments: attachments,
                directory: requestDirectory,
                model: modelReference,
                agent: agentName,
                variant: variant
            )
            appendDebugLog("command accepted session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            startLiveRefresh(for: selectedSession, reason: "command")
            errorMessage = nil
        } catch {
            if userVisible {
                refundReservedUserPromptIfNeeded()
            }
            if userVisible {
                draftMessage = draftCommand
                addDraftAttachments(attachments)
                persistCurrentMessageDraft(forSessionID: selectedSession.id)
                composerResetToken = UUID()
            }
            directoryState.sessionStatuses[selectedSession.id] = previousStatus
            appendDebugLog("command error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func stopCurrentSession() async {
        if isUsingAppleIntelligence {
            appleIntelligenceResponseTask?.cancel()
            if let selectedSession {
                directoryState.sessionStatuses[selectedSession.id] = "idle"
            }
            persistAppleIntelligenceMessages()
            return
        }

        guard let selectedSession else { return }
        let requestDirectory = sendDirectory(for: selectedSession)

        do {
            appendDebugLog(
                "abort request session=\(debugSessionLabel(selectedSession)) directory=\(debugDirectoryLabel(requestDirectory)) workspace=\(selectedSession.workspaceID ?? "nil")"
            )
            try await client.abortSession(
                sessionID: selectedSession.id,
                directory: requestDirectory,
                workspaceID: selectedSession.workspaceID
            )
            appendDebugLog("abort accepted session=\(debugSessionLabel(selectedSession))")
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

    func sendMessage(_ text: String, attachments: [OpenCodeComposerAttachment] = [], sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        if isUsingAppleIntelligence {
            guard let session = session(matching: sessionID) else { return }
            await sendAppleIntelligenceMessage(text, attachments: attachments, in: session, userVisible: userVisible)
            return
        }

        guard let session = session(matching: sessionID) else { return }
        await sendMessage(text, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    @discardableResult
    func insertOptimisticUserMessage(
        _ text: String,
        attachments: [OpenCodeComposerAttachment] = [],
        in selectedSession: OpenCodeSession,
        messageID: String? = nil,
        partID: String? = nil,
        animated: Bool = true
    ) -> (messageID: String, partID: String) {
        let resolvedMessageID = messageID ?? OpenCodeIdentifier.message()
        let resolvedPartID = partID ?? OpenCodeIdentifier.part()
        let variant = selectedVariant(for: selectedSession)
        let optimisticModel = effectiveModelReference(for: selectedSession).map {
            OpenCodeMessageModelReference(providerID: $0.providerID, modelID: $0.modelID, variant: variant)
        }

        let localUserMessage = OpenCodeMessageEnvelope.local(
            role: "user",
            text: text,
            attachments: attachments,
            messageID: resolvedMessageID,
            sessionID: selectedSession.id,
            partID: resolvedPartID,
            agent: effectiveAgentName(for: selectedSession),
            model: optimisticModel
        )

        if animated {
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                directoryState.messages.append(localUserMessage)
            }
        } else {
            directoryState.messages.append(localUserMessage)
        }
        markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        return (resolvedMessageID, resolvedPartID)
    }

    func sendMessage(
        _ text: String,
        attachments: [OpenCodeComposerAttachment] = [],
        in selectedSession: OpenCodeSession,
        userVisible: Bool,
        messageID: String? = nil,
        partID: String? = nil,
        appendOptimisticMessage: Bool = true,
        meterPrompt: Bool = true
    ) async {
        if isUsingAppleIntelligence {
            await sendAppleIntelligenceMessage(
                text,
                attachments: attachments,
                in: selectedSession,
                userVisible: userVisible,
                messageID: messageID,
                partID: partID,
                appendOptimisticMessage: appendOptimisticMessage
            )
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("send blocked paywall session=\(debugSessionLabel(selectedSession))")
            return
        }

        let requestDirectory = sendDirectory(for: selectedSession)
        let resolvedMessageID = messageID ?? OpenCodeIdentifier.message()
        let resolvedPartID = partID ?? OpenCodeIdentifier.part()
        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        let optimisticModel = modelReference.map {
            OpenCodeMessageModelReference(providerID: $0.providerID, modelID: $0.modelID, variant: variant)
        }

        let localUserMessage = OpenCodeMessageEnvelope.local(
            role: "user",
            text: trimmed,
            attachments: attachments,
            messageID: resolvedMessageID,
            sessionID: selectedSession.id,
            partID: resolvedPartID,
            agent: agentName,
            model: optimisticModel
        )
        if userVisible, appendOptimisticMessage {
            draftMessage = ""
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerResetToken = UUID()
            directoryState.messages.append(localUserMessage)
            markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        }
        markChatBreadcrumb("send start", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        appendDebugLog("send: \(trimmed)")
        appendDebugLog(
            "send scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil") requestDir=\(debugDirectoryLabel(requestDirectory)) msgID=\(resolvedMessageID) partID=\(resolvedPartID)"
        )

        isLoading = true
        let previousStatus = directoryState.sessionStatuses[selectedSession.id]
        directoryState.sessionStatuses[selectedSession.id] = "busy"
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await client.sendMessageAsync(
                sessionID: selectedSession.id,
                text: trimmed,
                attachments: attachments,
                directory: requestDirectory,
                messageID: resolvedMessageID,
                partID: resolvedPartID,
                model: modelReference,
                agent: agentName,
                variant: variant
            )
            appendDebugLog("prompt_async accepted session=\(debugSessionLabel(selectedSession)) msgID=\(resolvedMessageID) partID=\(resolvedPartID)")
            markChatBreadcrumb("prompt_async accepted", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
            if isCapturingStreamingDiagnostics {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 500ms")
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 2s")
                }
            }
            startLiveRefresh(for: selectedSession, reason: "send")
            refreshLiveActivityIfNeeded(for: selectedSession.id)
            errorMessage = nil
        } catch {
            if userVisible {
                refundReservedUserPromptIfNeeded()
            }
            if userVisible {
                directoryState.messages.removeAll { $0.id == localUserMessage.id }
                markChatBreadcrumb("send rollback", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
                draftMessage = trimmed
                addDraftAttachments(attachments)
                persistCurrentMessageDraft(forSessionID: selectedSession.id)
                composerResetToken = UUID()
            }
            directoryState.sessionStatuses[selectedSession.id] = previousStatus
            appendDebugLog("send error: \(error.localizedDescription)")
            markChatBreadcrumb("send error", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
            errorMessage = error.localizedDescription
        }
    }

    func removeOptimisticUserMessage(messageID: String, sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        directoryState.messages.removeAll { $0.id == messageID && ($0.info.role ?? "").lowercased() == "user" }
        markChatBreadcrumb("optimistic remove", sessionID: sessionID, messageID: messageID)
    }

    func slashCommandInput(from text: String) -> (command: OpenCodeCommand, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }

        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let commandName = parts.first.map(String.init), !commandName.isEmpty,
              let command = commands.first(where: { $0.name == commandName }) else {
            return nil
        }

        let arguments = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (command, arguments)
    }

    var forkableMessages: [OpenCodeForkableMessage] {
        let messages = directoryState.messages
        var result: [OpenCodeForkableMessage] = []

        for message in messages {
            guard (message.info.role ?? "").lowercased() == "user" else { continue }
            guard let text = forkPromptText(from: message).nilIfEmpty else { continue }

            result.append(
                OpenCodeForkableMessage(
                    id: message.id,
                    text: text.replacingOccurrences(of: "\n", with: " "),
                    created: message.info.time?.created
                )
            )
        }

        return result.reversed()
    }

    func presentForkSessionSheet() {
        guard selectedSession != nil, !forkableMessages.isEmpty else { return }
        withAnimation(opencodeSelectionAnimation) {
            isShowingForkSessionSheet = true
        }
    }

    func isForkClientCommand(_ command: OpenCodeCommand) -> Bool {
        command.source == "client" && command.name == "fork"
    }

    func isCompactClientCommand(_ command: OpenCodeCommand) -> Bool {
        command.name == "compact"
    }

    func compactSession(sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        guard let session = session(matching: sessionID) else { return }
        await compactSession(session, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    func compactSession(_ selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true) async {
        guard selectedSession.parentID == nil else {
            appendDebugLog("compact blocked child session=\(debugSessionLabel(selectedSession))")
            errorMessage = "Compact is only available in root sessions."
            return
        }

        guard directoryState.sessionStatuses[selectedSession.id] != "busy" else {
            appendDebugLog("compact blocked busy session=\(debugSessionLabel(selectedSession))")
            return
        }

        guard let modelReference = effectiveModelReference(for: selectedSession) else {
            appendDebugLog("compact blocked missing model session=\(debugSessionLabel(selectedSession))")
            errorMessage = "Select a model before compacting this session."
            return
        }

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("compact blocked paywall session=\(debugSessionLabel(selectedSession))")
            return
        }

        let requestDirectory = sendDirectory(for: selectedSession)

        if userVisible {
            draftMessage = ""
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerResetToken = UUID()
        }

        appendDebugLog(
            "compact request session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) requestDir=\(debugDirectoryLabel(requestDirectory)) model=\(modelReference.providerID)/\(modelReference.modelID)"
        )

        isLoading = true
        let previousStatus = directoryState.sessionStatuses[selectedSession.id]
        directoryState.sessionStatuses[selectedSession.id] = "busy"
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await client.summarizeSession(
                sessionID: selectedSession.id,
                directory: requestDirectory,
                model: modelReference,
                auto: false
            )
            appendDebugLog("compact accepted session=\(debugSessionLabel(selectedSession))")
            startLiveRefresh(for: selectedSession, reason: "compact")
            refreshLiveActivityIfNeeded(for: selectedSession.id)
            errorMessage = nil
        } catch {
            if userVisible {
                refundReservedUserPromptIfNeeded()
                draftMessage = "/compact"
                persistCurrentMessageDraft(forSessionID: selectedSession.id)
                composerResetToken = UUID()
            }
            directoryState.sessionStatuses[selectedSession.id] = previousStatus
            appendDebugLog("compact error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func shouldOpenForkSheet(forSlashInput text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/fork"
    }

    func forkSelectedSession(from messageID: String) async {
        guard let selectedSession else { return }
        await forkSession(selectedSession, from: messageID)
    }

    func forkSession(_ selectedSession: OpenCodeSession, from messageID: String) async {
        let requestDirectory = sendDirectory(for: selectedSession)
        let sourceMessage = directoryState.messages.first { $0.id == messageID }
        let restoredPrompt = sourceMessage.map(promptDraft(from:))

        isLoading = true
        defer { isLoading = false }

        do {
            appendDebugLog("fork request session=\(debugSessionLabel(selectedSession)) message=\(messageID) directory=\(debugDirectoryLabel(requestDirectory))")
            let forked = try await client.forkSession(
                sessionID: selectedSession.id,
                messageID: messageID,
                directory: requestDirectory,
                workspaceID: selectedSession.workspaceID
            )
            appendDebugLog("fork accepted session=\(debugSessionLabel(forked)) parent=\(selectedSession.id) message=\(messageID)")

            withAnimation(opencodeSelectionAnimation) {
                isShowingForkSessionSheet = false
            }
            upsertVisibleSession(forked)
            try? await reloadSessions()
            upsertVisibleSession(forked)
            await selectSession(forked)

            if let restoredPrompt {
                draftMessage = restoredPrompt.text
                draftAttachments = restoredPrompt.attachments
                persistCurrentMessageDraft(forSessionID: forked.id)
                composerResetToken = UUID()
            }

            errorMessage = nil
        } catch {
            appendDebugLog("fork error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func forkPromptText(from message: OpenCodeMessageEnvelope) -> String {
        message.parts
            .filter { $0.type == "text" }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func promptDraft(from message: OpenCodeMessageEnvelope) -> (text: String, attachments: [OpenCodeComposerAttachment]) {
        let text = forkPromptText(from: message)
        let attachments = message.parts.compactMap { part -> OpenCodeComposerAttachment? in
            guard part.type == "file",
                  let filename = part.filename,
                  let mime = part.mime,
                  let url = part.url else {
                return nil
            }

            return OpenCodeComposerAttachment(
                id: part.id ?? OpenCodeIdentifier.part(),
                kind: mime.lowercased().hasPrefix("image/") ? .image : .file,
                filename: filename,
                mime: mime,
                dataURL: url
            )
        }
        return (text, attachments)
    }

    func loadMessages(for session: OpenCodeSession) async throws {
        let loadedMessages = try await client.listMessages(sessionID: session.id, directory: session.directory)
        refreshSessionPreview(for: session.id, messages: loadedMessages)
        cachedMessagesBySessionID[session.id] = loadedMessages
        guard selectedSession?.id == session.id else { return }
        appendDebugLog(serverMessageSummary(loadedMessages, sessionID: session.id, reason: "loadMessages"))
        directoryState.messages = mergeMessagesPreservingStreamProgress(existing: directoryState.messages, loaded: loadedMessages)
        syncComposerSelections(for: session)
        prefetchToolMessageDetails(for: session, messages: directoryState.messages)
        refreshLiveActivityIfNeeded(for: session.id)
        await loadTodos(for: session)
        directoryState.isLoadingSelectedSession = false
    }

    func refreshChatData(for sessionID: String) async {
        guard !isUsingAppleIntelligence else { return }
        guard let session = session(matching: sessionID) else { return }

        appendDebugLog("manual chat refresh session=\(debugSessionLabel(session))")

        do {
            async let sessions: Void = reloadSessions()
            async let statuses: Void = reloadSessionStatuses()
            async let messages: Void = loadMessages(for: session)
            async let permissions: Void = loadAllPermissions(for: session)
            async let questions: Void = loadAllQuestions(for: session)
            _ = try await (sessions, statuses, messages, permissions, questions)

            let refreshedSession = self.session(matching: sessionID) ?? session
            await refreshToolMessageDetails(for: refreshedSession, messages: cachedMessagesBySessionID[sessionID] ?? directoryState.messages)
            errorMessage = nil
        } catch {
            appendDebugLog("manual chat refresh error session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
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
            let loadedMessages = try await client.listMessages(sessionID: session.id, directory: session.directory)
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
                return "\(part.id ?? "nil"):\(part.type):\(snippet)"
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
            refreshLiveActivityIfNeeded(for: session.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.todos = []
            }
            refreshLiveActivityIfNeeded(for: session.id)
        }
    }

    func loadAllPermissions(directory: String? = nil, workspaceID: String? = nil) async {
        do {
            let permissions = try await client.listPermissions(directory: directory, workspaceID: workspaceID)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions = permissions
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions = []
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        }
    }

    func loadAllPermissions(for session: OpenCodeSession) async {
        await loadAllPermissions(directory: sendDirectory(for: session), workspaceID: session.workspaceID)
    }

    func loadAllQuestions(directory: String? = nil, workspaceID: String? = nil) async {
        do {
            let questions = try await client.listQuestions(directory: directory, workspaceID: workspaceID)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions = questions
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions = []
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        }
    }

    func loadAllQuestions(for session: OpenCodeSession) async {
        await loadAllQuestions(directory: sendDirectory(for: session), workspaceID: session.workspaceID)
    }

    var selectedSessionPermissions: [OpenCodePermission] {
        guard let selectedSession else { return [] }
        return permissions.filter { $0.sessionID == selectedSession.id }
    }

    func permissions(for sessionID: String) -> [OpenCodePermission] {
        permissions.filter { $0.sessionID == sessionID }
    }

    var selectedSessionQuestions: [OpenCodeQuestionRequest] {
        guard let selectedSession else { return [] }
        return questions.filter { $0.sessionID == selectedSession.id }
    }

    func questions(for sessionID: String) -> [OpenCodeQuestionRequest] {
        questions.filter { $0.sessionID == sessionID }
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

            let session = session(matching: permission.sessionID)
            let directory = session.flatMap(sendDirectory(for:))
            try await client.replyToPermission(
                requestID: permission.id,
                reply: reply,
                directory: directory,
                workspaceID: session?.workspaceID
            )
            withAnimation(opencodeSelectionAnimation) {
                directoryState.permissions.removeAll { $0.id == permission.id }
            }
            refreshLiveActivityIfNeeded(for: permission.sessionID)
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        withAnimation(opencodeSelectionAnimation) {
            directoryState.permissions.removeAll { $0.id == permission.id }
        }
        refreshLiveActivityIfNeeded(for: permission.sessionID)
        publishWidgetSnapshots()
    }

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]]) async {
        do {
            let session = session(matching: request.sessionID)
            let directory = session.flatMap(sendDirectory(for:))
            try await client.replyToQuestion(
                requestID: request.id,
                answers: answers,
                directory: directory,
                workspaceID: session?.workspaceID
            )
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions.removeAll { $0.id == request.id }
            }
            refreshLiveActivityIfNeeded(for: request.sessionID)
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest) async {
        do {
            let session = session(matching: request.sessionID)
            let directory = session.flatMap(sendDirectory(for:))
            try await client.rejectQuestion(
                requestID: request.id,
                directory: directory,
                workspaceID: session?.workspaceID
            )
            withAnimation(opencodeSelectionAnimation) {
                directoryState.questions.removeAll { $0.id == request.id }
            }
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: OpenCodeSession) async {
        do {
            try await client.deleteSession(sessionID: session.id)
            unpinSession(session)
            removeSessionPreview(for: session.id)
            if directoryState.selectedSession?.id == session.id {
                persistCurrentMessageDraft(forSessionID: session.id)
                withAnimation(opencodeSelectionAnimation) {
                    directoryState.selectedSession = nil
                    directoryState.messages = []
                }
            }
            clearPersistedMessageDraft(forSessionID: session.id)
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

    func parentSession(for session: OpenCodeSession) -> OpenCodeSession? {
        guard let parentID = session.parentID else { return nil }
        return self.session(matching: parentID)
    }

    func childSessions(for sessionID: String) -> [OpenCodeSession] {
        directoryState.sessions.filter { $0.parentID == sessionID }
    }

    func ensureAllSessionsLoaded() async {
        do {
            let sessions = try await client.listSessions(directory: effectiveSelectedDirectory)
            withAnimation(opencodeSelectionAnimation) {
                mergeSessions(sessions)
            }
        } catch {
            return
        }
    }

    func openSession(sessionID: String) async {
        if session(matching: sessionID) == nil {
            await ensureAllSessionsLoaded()
        }

        guard let session = session(matching: sessionID) else { return }
        await selectSession(session)
    }

    func resolveTaskSessionID(from part: OpenCodePart, currentSessionID: String) -> String? {
        if let sessionID = part.state?.metadata?.sessionId, !sessionID.isEmpty {
            return sessionID
        }

        let description = part.state?.input?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentName = taskAgentDisplayName(from: part.state?.input?.subagentType)?.lowercased()

        return childSessions(for: currentSessionID)
            .filter { child in
                guard let title = child.title?.lowercased() else { return description == nil && agentName == nil }
                let descriptionMatches = description.map { title.hasPrefix($0.lowercased()) } ?? true
                let agentMatches = agentName.map { title.contains("@\($0)") || title.contains($0) } ?? true
                return descriptionMatches && agentMatches
            }
            .sorted {
                let lhs = $0.title ?? ""
                let rhs = $1.title ?? ""
                return lhs < rhs
            }
            .first?
            .id
    }

    func taskAgentDisplayName(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        return String(first).uppercased() + trimmed.dropFirst()
    }

    func latestTaskDescription(for session: OpenCodeSession) -> String? {
        guard let parentID = session.parentID else { return nil }

        let parentMessages = toolMessageDetails.values
            .filter { $0.info.sessionID == parentID }
            .sorted { $0.info.id < $1.info.id }

        for message in parentMessages.reversed() {
            for part in message.parts.reversed() where part.tool == "task" {
                if resolveTaskSessionID(from: part, currentSessionID: parentID) == session.id,
                   let description = part.state?.input?.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !description.isEmpty {
                    return description
                }
            }
        }

        return nil
    }

    func childSessionTitle(for session: OpenCodeSession) -> String {
        if let description = latestTaskDescription(for: session), !description.isEmpty {
            return description
        }

        if let title = session.title, !title.isEmpty {
            return title.replacingOccurrences(of: #"\s+\(@[^)]+ subagent\)"#, with: "", options: .regularExpression)
        }

        return "New Session"
    }

    func parentSessionTitle(for session: OpenCodeSession) -> String {
        parentSession(for: session)?.title ?? "Session"
    }

    private func mergeSessions(_ sessions: [OpenCodeSession]) {
        for session in sessions {
            if let index = directoryState.sessions.firstIndex(where: { $0.id == session.id }) {
                directoryState.sessions[index] = directoryState.sessions[index].merged(with: session)
            } else {
                directoryState.sessions.append(session)
            }
        }
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
        let toolMessageIDs = recentToolMessageIDs(in: messages, limit: 12)

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

    func refreshToolMessageDetails(for session: OpenCodeSession, messages: [OpenCodeMessageEnvelope]) async {
        let toolMessageIDs = recentToolMessageIDs(in: messages, limit: 20)

        for messageID in toolMessageIDs {
            do {
                toolMessageDetails[messageID] = try await client.getMessage(sessionID: session.id, messageID: messageID)
            } catch {
                appendDebugLog("tool detail refresh failed session=\(debugSessionLabel(session)) message=\(messageID) error=\(error.localizedDescription)")
            }
        }
    }

    private func recentToolMessageIDs(in messages: [OpenCodeMessageEnvelope], limit: Int) -> [String] {
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

    func sendCurrentAppleIntelligenceMessage() async {
        guard let selectedSession else { return }
        let text = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        await sendAppleIntelligenceMessage(text, attachments: attachments, in: selectedSession, userVisible: true)
    }

    func sendAppleIntelligenceMessage(
        _ text: String,
        attachments: [OpenCodeComposerAttachment] = [],
        in session: OpenCodeSession,
        userVisible: Bool,
        messageID: String? = nil,
        partID: String? = nil,
        appendOptimisticMessage: Bool = true
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard let workspace = activeAppleIntelligenceWorkspace else {
            errorMessage = "No Apple Intelligence workspace is active."
            return
        }

        let userMessageID = messageID ?? OpenCodeIdentifier.message()
        let userPartID = partID ?? OpenCodeIdentifier.part()
        let assistantMessageID = OpenCodeIdentifier.message()
        let assistantPartID = OpenCodeIdentifier.part()
        let priorMessages = directoryState.messages.filter { $0.id != userMessageID }

        let localUserMessage = OpenCodeMessageEnvelope.local(
            role: "user",
            text: trimmed,
            attachments: attachments,
            messageID: userMessageID,
            sessionID: session.id,
            partID: userPartID,
            agent: nil,
            model: nil
        )
        let localAssistantMessage = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: assistantMessageID, role: "assistant", sessionID: session.id, time: nil, agent: "Apple Intelligence", model: nil),
            parts: [
                OpenCodePart(
                    id: assistantPartID,
                    messageID: assistantMessageID,
                    sessionID: session.id,
                    type: "text",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: nil,
                    callID: nil,
                    state: nil,
                    text: ""
                )
            ]
        )

        if userVisible {
            draftMessage = ""
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: session.id)
            composerResetToken = UUID()
            withAnimation(opencodeSelectionAnimation) {
                if appendOptimisticMessage {
                    directoryState.messages.append(localUserMessage)
                }
                directoryState.messages.append(localAssistantMessage)
            }
        }

        persistAppleIntelligenceMessages()
        directoryState.sessionStatuses[session.id] = "busy"
        isLoading = true
        errorMessage = nil
        appleIntelligenceResponseTask?.cancel()

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if !model.isAvailable {
                updateAppleIntelligenceAssistantMessage(
                    messageID: assistantMessageID,
                    partID: assistantPartID,
                    sessionID: session.id,
                    text: appleIntelligenceAvailabilitySummary ?? "Apple Intelligence is unavailable."
                )
                directoryState.sessionStatuses[session.id] = "idle"
                isLoading = false
                persistAppleIntelligenceMessages()
                return
            }

            if !model.supportsLocale(Locale.current) {
                updateAppleIntelligenceAssistantMessage(
                    messageID: assistantMessageID,
                    partID: assistantPartID,
                    sessionID: session.id,
                    text: "Apple Intelligence does not support the current device language or locale for this demo yet."
                )
                directoryState.sessionStatuses[session.id] = "idle"
                isLoading = false
                persistAppleIntelligenceMessages()
                return
            }
        }
#endif

        appleIntelligenceResponseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let rootURL = try self.resolveAppleIntelligenceWorkspaceURL(workspace)
                await MainActor.run {
                    self.appleIntelligenceDebugToolRootPath = rootURL.path(percentEncoded: false)
                }
                let didAccess = rootURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        rootURL.stopAccessingSecurityScopedResource()
                    }
                }

                let initialContext = self.appleIntelligenceInitialContext(for: rootURL)
                let intent = try await self.inferAppleIntelligenceIntent(
                    currentText: trimmed,
                    attachments: attachments,
                    priorMessages: priorMessages,
                    workspace: workspace
                )
                let prompt = self.appleIntelligenceExecutionPrompt(
                    intent: intent,
                    currentText: trimmed,
                    attachments: attachments,
                    priorMessages: priorMessages,
                    workspace: workspace,
                    initialContext: initialContext
                )
#if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *) {
                    for try await snapshot in try self.makeAppleIntelligenceResponseStream(intent: intent, prompt: prompt, rootURL: rootURL) {
                        try Task.checkCancellation()
                        await MainActor.run {
                            self.updateAppleIntelligenceAssistantMessage(
                                messageID: assistantMessageID,
                                partID: assistantPartID,
                                sessionID: session.id,
                                text: snapshot.content
                            )
                        }
                    }
                } else {
                    throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable on this OS version."])
                }
#else
                throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable on this build."])
#endif

                await MainActor.run {
                    self.directoryState.sessionStatuses[session.id] = "idle"
                    self.isLoading = false
                    self.persistAppleIntelligenceMessages()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.directoryState.sessionStatuses[session.id] = "idle"
                    self.isLoading = false
                    self.persistAppleIntelligenceMessages()
                }
            } catch {
                await MainActor.run {
                    self.directoryState.sessionStatuses[session.id] = "idle"
                    self.isLoading = false
                    self.updateAppleIntelligenceAssistantMessage(
                        messageID: assistantMessageID,
                        partID: assistantPartID,
                        sessionID: session.id,
                        text: "Apple Intelligence error: \(error.localizedDescription)"
                    )
                    self.persistAppleIntelligenceMessages()
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func updateAppleIntelligenceAssistantMessage(messageID: String, partID: String, sessionID: String, text: String) {
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

        if let index = directoryState.messages.firstIndex(where: { $0.id == messageID }) {
            directoryState.messages[index] = directoryState.messages[index].upsertingPart(part)
            return
        }

        directoryState.messages.append(
            OpenCodeMessageEnvelope(
                info: OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: "Apple Intelligence", model: nil),
                parts: [part]
            )
        )
    }

    func inferAppleIntelligenceIntent(
        currentText: String,
        attachments: [OpenCodeComposerAttachment],
        priorMessages: [OpenCodeMessageEnvelope],
        workspace: AppleIntelligenceWorkspaceRecord
    ) async throws -> AppleIntelligenceIntent {
        if let heuristicIntent = appleIntelligenceHeuristicIntent(currentText: currentText, attachments: attachments) {
            return heuristicIntent
        }

        if currentText == "/init" || currentText.hasPrefix("/init ") {
            return .initialize
        }

        let history = priorMessages
            .suffix(6)
            .compactMap { message -> String? in
                let role = (message.info.role ?? "assistant").lowercased()
                let text = message.parts.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(role): \(text)"
            }
            .joined(separator: "\n\n")
        let attachmentSummary = appleIntelligenceAttachmentSummary(attachments)
        let classifierPrompt = """
        Classify the user's latest request into exactly one label.

        Valid labels:
        - chat
        - init
        - list_directory
        - read_file
        - search_files
        - write_file
        - clarify

        Rules:
        - chat: normal conversation, greetings, questions that do not require workspace inspection
        - init: explicit /init command
        - list_directory: asking to list, browse, or explore files/folders
        - read_file: asking about a specific file or asking to open/read a file
        - search_files: asking to find something by topic, symbol, or text across files
        - write_file: asking to create, edit, update, or modify files
        - clarify: workspace task is ambiguous and needs a follow-up question

        Return only the label and nothing else.

        Workspace: \(workspace.lastKnownPath)

        Recent conversation:
        \(history.isEmpty ? "None." : history)

        Latest user message:
        \(currentText.isEmpty ? "[No text; inspect attachments only.]" : currentText)

        \(attachmentSummary)
        """

#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let model = SystemLanguageModel.default
            let session = LanguageModelSession(model: model) {
                """
                You classify user intent for an on-device coding assistant.
                Return one exact label from the allowed set and no extra words.
                """
            }
            let response = try await session.respond(to: classifierPrompt)
            let label = response.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch label {
            case AppleIntelligenceIntent.chat.label:
                return .chat
            case AppleIntelligenceIntent.initialize.label:
                return .initialize
            case AppleIntelligenceIntent.listDirectory.label:
                return .listDirectory
            case AppleIntelligenceIntent.readFile.label:
                return .readFile
            case AppleIntelligenceIntent.searchFiles.label:
                return .searchFiles
            case AppleIntelligenceIntent.writeFile.label:
                return .writeFile
            default:
                return .chat
            }
        }
#endif
        return .chat
    }

    func appleIntelligenceHeuristicIntent(currentText: String, attachments: [OpenCodeComposerAttachment]) -> AppleIntelligenceIntent? {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let simplified = normalized
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")

        if !attachments.isEmpty, trimmed.isEmpty {
            return .clarify
        }

        guard !simplified.isEmpty else {
            return .chat
        }

        let chatPhrases = [
            "hi", "hey", "hello", "yo", "hiya", "good morning", "good afternoon", "good evening",
            "whats up", "what is up", "hows it going", "how is it going", "how are you", "sup", "wyd",
            "who are you", "what are you", "thanks", "thank you", "cool", "nice", "ok", "okay",
            "what", "huh", "uhh", "uhmmm", "bro", "man"
        ]
        if chatPhrases.contains(where: { simplified == $0 || simplified.hasPrefix($0 + " ") || simplified.hasSuffix(" " + $0) }) {
            return .chat
        }

        let capabilityQuestions = [
            "can you read files", "can you read file", "can you browse files", "can you inspect files",
            "can you search files", "what can you do", "what can you read"
        ]
        if capabilityQuestions.contains(where: { simplified == $0 || simplified.contains($0) }) {
            return .chat
        }

        let directoryKeywords = [
            "list files", "show files", "browse files", "browse folder", "list directory", "what files",
            "whats in this folder", "show me the folder", "your directory", "this directory", "the directory"
        ]
        if directoryKeywords.contains(where: { simplified.contains($0) }) {
            return .listDirectory
        }

        let searchKeywords = ["find ", "search for", "grep", "where is", "look for", "search the codebase", "search the project"]
        if searchKeywords.contains(where: { simplified.contains($0) }) {
            return .searchFiles
        }

        let writeKeywords = ["edit ", "change ", "update ", "modify ", "write ", "create ", "add ", "replace ", "fix "]
        if writeKeywords.contains(where: { simplified.contains($0) }) {
            return .writeFile
        }

        let readKeywords = ["open ", "read ", "show me ", "explain this file", "whats in ", "what is in "]
        if readKeywords.contains(where: { simplified.contains($0) }) {
            return .readFile
        }

        return nil
    }

    func appleIntelligenceExecutionPrompt(
        intent: AppleIntelligenceIntent,
        currentText: String,
        attachments: [OpenCodeComposerAttachment],
        priorMessages: [OpenCodeMessageEnvelope],
        workspace: AppleIntelligenceWorkspaceRecord,
        initialContext: String
    ) -> String {
        let history = priorMessages
            .suffix(8)
            .compactMap { message -> String? in
                let role = (message.info.role ?? "assistant").lowercased()
                let text = message.parts.compactMap(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return "\(role): \(text)"
            }
            .joined(separator: "\n\n")

        let attachmentSummary = appleIntelligenceAttachmentSummary(attachments)
        let instructionBlock = appleIntelligenceUserInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalInstructionsSection = instructionBlock.isEmpty ? "" : "\nAdditional instructions:\n\(instructionBlock)\n"

        if intent == .initialize {
            return """
            The user selected the workspace at \(workspace.lastKnownPath).

            Recent conversation:
            \(history.isEmpty ? "None." : history)

            The user ran /init.
            Use your tools to inspect the workspace and produce a practical project initialization summary.
            Cover:
            1. What this project appears to be
            2. Important files or entry points
            3. How someone should explore or run it next if that is discoverable
            4. A few useful follow-up things they can ask you to do

            \(initialContext)

            \(attachmentSummary)
            """
        }

        if intent == .chat {
            return """
            The user is having a normal conversation.
            Respond to the user's latest message directly.
            Do not greet again unless the latest message is itself a greeting.
            If the latest message is a follow-up question, answer the follow-up instead of restarting.
            Do not mention workspace files or tools.

            Recent conversation:
            \(history.isEmpty ? "None." : history)

            User message:
            \(currentText.isEmpty ? "[No text; inspect the supplied attachments.]" : currentText)
            \(additionalInstructionsSection)

            \(attachmentSummary)
            """
        }

        let intentGuidance: String = switch intent {
        case .chat:
            "Respond conversationally without using tools."
        case .listDirectory:
            "The user wants to browse files or folders. Use directory listing tools only if needed."
        case .readFile:
            "The user wants details about a specific file. Prefer reading that file directly."
        case .searchFiles:
            "The user wants to find information across the workspace. Search before answering."
        case .writeFile:
            "The user wants to modify workspace files. Inspect only what is needed, then make the requested change."
        case .clarify:
            "The request is ambiguous. Ask one concise clarification question and do not use tools."
        case .initialize:
            ""
        }

        return """
        The user selected the workspace at \(workspace.lastKnownPath).

        Intent:
        \(intent.label)

        Guidance:
        \(intentGuidance)

        Workspace context:
        \(initialContext)

        Recent conversation:
        \(history.isEmpty ? "None." : history)

        User message:
        \(currentText.isEmpty ? "[No text; inspect the supplied attachments.]" : currentText)
        \(additionalInstructionsSection)

        \(attachmentSummary)
        """
    }

    func appleIntelligenceAttachmentSummary(_ attachments: [OpenCodeComposerAttachment]) -> String {
        guard !attachments.isEmpty else { return "Attachments: none." }

        let summaries = attachments.map { attachment in
            let name = attachment.filename
            if attachment.mime.lowercased().hasPrefix("text/"),
               let decoded = decodeAttachmentText(attachment) {
                let excerpt = decoded.prefix(4000)
                return "Attachment \(name) (text):\n\(excerpt)"
            }

            if attachment.isImage {
                return "Attachment \(name): image included by the user."
            }

            return "Attachment \(name): non-text file with MIME type \(attachment.mime)."
        }

        return "Attachments:\n\n\(summaries.joined(separator: "\n\n"))"
    }

    func decodeAttachmentText(_ attachment: OpenCodeComposerAttachment) -> String? {
        guard let commaIndex = attachment.dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(attachment.dataURL[attachment.dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func appleIntelligenceInitialContext(for rootURL: URL) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let summary = entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(30)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? "\(url.lastPathComponent)/" : url.lastPathComponent
            }
            .joined(separator: ", ")

        return summary.isEmpty ? "The workspace root appears empty." : "Top-level workspace entries: \(summary)"
    }

    func resolveAppleIntelligenceWorkspaceURL(_ workspace: AppleIntelligenceWorkspaceRecord) throws -> URL {
        if activeAppleIntelligenceWorkspaceID == workspace.id,
           let activeAppleIntelligenceWorkspaceURL {
            appleIntelligenceDebugResolvedPath = activeAppleIntelligenceWorkspaceURL.path(percentEncoded: false)
            return activeAppleIntelligenceWorkspaceURL
        }

        var isStale = false
        let url = try URL(
            resolvingBookmarkData: workspace.bookmarkData,
            options: appleIntelligenceBookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )

        if isStale,
           let refreshed = try? url.bookmarkData(options: appleIntelligenceBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil),
           var currentAppleIntelligenceWorkspace,
           currentAppleIntelligenceWorkspace.id == workspace.id {
            currentAppleIntelligenceWorkspace.bookmarkData = refreshed
            currentAppleIntelligenceWorkspace.lastKnownPath = url.path(percentEncoded: false)
            self.currentAppleIntelligenceWorkspace = currentAppleIntelligenceWorkspace
        }

        let fileManager = FileManager.default
        let resolvedPath = url.path(percentEncoded: false)
        appleIntelligenceDebugResolvedPath = resolvedPath
        guard fileManager.fileExists(atPath: resolvedPath) else {
            throw NSError(
                domain: "AppleIntelligence",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The saved Apple Intelligence folder is no longer available. Please pick it again."]
            )
        }

        return url
    }

    @available(iOS 26.0, macOS 26.0, *)
    func makeAppleIntelligenceResponseStream(intent: AppleIntelligenceIntent, prompt: String, rootURL: URL) throws -> LanguageModelSession.ResponseStream<String> {
#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw NSError(domain: "AppleIntelligence", code: 1, userInfo: [NSLocalizedDescriptionKey: appleIntelligenceAvailabilitySummary ?? "Apple Intelligence is unavailable."])
        }
        guard model.supportsLocale(Locale.current) else {
            throw NSError(
                domain: "AppleIntelligence",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence does not support the current device language/locale for this model."]
            )
        }

        let toolbox = AppleIntelligenceWorkspaceToolbox(rootURL: rootURL)
        var tools: [any Tool] = []
        switch intent {
        case .chat, .clarify:
            break
        case .initialize:
            tools.append(AppleIntelligenceListDirectoryTool(toolbox: toolbox))
            tools.append(AppleIntelligenceReadFileTool(toolbox: toolbox))
            tools.append(AppleIntelligenceSearchFilesTool(toolbox: toolbox))
        case .listDirectory:
            tools.append(AppleIntelligenceListDirectoryTool(toolbox: toolbox))
        case .readFile:
            tools.append(AppleIntelligenceReadFileTool(toolbox: toolbox))
        case .searchFiles:
            tools.append(AppleIntelligenceSearchFilesTool(toolbox: toolbox))
        case .writeFile:
            tools.append(AppleIntelligenceReadFileTool(toolbox: toolbox))
            tools.append(AppleIntelligenceWriteFileTool(toolbox: toolbox))
        }
        let session = LanguageModelSession(model: model, tools: tools) {
            let instructionBlock = self.appleIntelligenceSystemInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if instructionBlock.isEmpty {
                "You are OpenCode running as an on-device Apple Intelligence demo inside a native iOS client."
            } else {
                """
                \(instructionBlock)
                """
            }
        }
        return session.streamResponse(to: prompt)
#else
        throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is unavailable on this build."])
#endif
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
private struct AppleIntelligenceWorkspaceToolbox: Sendable {
    let rootURL: URL

    private var rootPath: String {
        rootURL.standardizedFileURL.path
    }

    private var allowedRootPaths: Set<String> {
        canonicalPathVariants(for: rootURL)
    }

    func listDirectory(path: String) throws -> String {
        let target = try resolvedURL(for: path, allowDirectory: true)
        let values = try target.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            return "\(normalizedPath(path)) is a file, not a directory."
        }

        let entries = try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        if entries.isEmpty {
            return "Directory \(normalizedPath(path)) is empty."
        }

        return entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(80)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? "- \(relativePath(for: url))/" : "- \(relativePath(for: url))"
            }
            .joined(separator: "\n")
    }

    func readFile(path: String) throws -> String {
        let excerptLimit = 4000
        let target = try resolvedURL(for: path, allowDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            return missingFileFallback(path: path)
        }
        let values = try target.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            return directoryReadFallback(path: path, target: target)
        }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            return missingFileFallback(path: path)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return "File \(normalizedPath(path)) is not UTF-8 text."
        }

        if target.pathExtension.lowercased() == "json",
           let summary = jsonSummary(text: text, path: path, excerptLimit: excerptLimit) {
            return summary
        }

        if text.count <= excerptLimit {
            return text
        }

        return """
        File \(normalizedPath(path)) is large, so this content is truncated to the first \(excerptLimit) characters.

        \(String(text.prefix(excerptLimit)))
        """
    }

    func searchFiles(query: String) throws -> String {
        let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var matches: [String] = []

        while let url = enumerator?.nextObject() as? URL, matches.count < 40 {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if text.localizedCaseInsensitiveContains(query) {
                matches.append(relativePath(for: url))
            }
        }

        return matches.isEmpty ? "No text files contained \"\(query)\"." : matches.map { "- \($0)" }.joined(separator: "\n")
    }

    func writeFile(path: String, content: String) throws -> String {
        let target = try resolvedURL(for: path, allowDirectory: false)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try content.write(to: target, atomically: true, encoding: .utf8)
        return "Wrote \(content.count) characters to \(normalizedPath(path))."
    }

    private func resolvedURL(for path: String, allowDirectory: Bool) throws -> URL {
        let rawPath = path
        let cleaned = normalizedPath(path)
        let target: URL

        if cleaned.isEmpty || cleaned == "." {
            target = rootURL
        } else if let absoluteURL = absoluteWorkspaceURL(from: cleaned) {
            target = absoluteURL
        } else if cleaned == rootURL.lastPathComponent {
            target = rootURL
        } else if cleaned.hasPrefix(rootPath + "/") || cleaned == rootPath {
            target = URL(fileURLWithPath: cleaned)
        } else {
            target = rootURL.appendingPathComponent(cleaned)
        }

        let standardized = target.standardizedFileURL
        let standardizedVariants = canonicalPathVariants(for: standardized)
        let isInsideWorkspace = standardizedVariants.contains { candidate in
            allowedRootPaths.contains { root in
                candidate == root || candidate.hasPrefix(root + "/")
            }
        }

        guard isInsideWorkspace else {
            let debugMessage = "That path escapes the selected workspace. raw=\(rawPath) cleaned=\(cleaned) resolved=\(standardized.path) root=\(rootPath)"
            throw NSError(domain: "AppleIntelligence", code: 3, userInfo: [NSLocalizedDescriptionKey: debugMessage])
        }

        if allowDirectory { return standardized }

        let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey])
        if values?.isDirectory == true {
            throw NSError(domain: "AppleIntelligence", code: 4, userInfo: [NSLocalizedDescriptionKey: "Expected a file path, but received a directory."])
        }
        return standardized
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = cleanedModelPath(path)
        if trimmed == "/" { return "" }
        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)?.path(percentEncoded: false) ?? trimmed
        }
        if trimmed.hasPrefix(rootPath + "/") || trimmed == rootPath {
            return trimmed
        }
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : trimmed
    }

    private func absoluteWorkspaceURL(from value: String) -> URL? {
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            return url
        }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value)
        }

        return nil
    }

    private func cleanedModelPath(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
    }

    private func canonicalPathVariants(for url: URL) -> Set<String> {
        canonicalPathVariants(for: url.standardizedFileURL.path)
            .union(canonicalPathVariants(for: url.resolvingSymlinksInPath().path))
    }

    private func canonicalPathVariants(for path: String) -> Set<String> {
        guard !path.isEmpty else { return [] }
        var variants: Set<String> = [path]

        if path.hasPrefix("/private/") {
            variants.insert(String(path.dropFirst("/private".count)))
        } else if path.hasPrefix("/var/") {
            variants.insert("/private" + path)
        }

        return variants
    }

    private func relativePath(for url: URL) -> String {
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return url.lastPathComponent }
        let suffix = fullPath.dropFirst(rootPath.count)
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : String(suffix)
    }

    private func directoryReadFallback(path: String, target: URL) -> String {
        let entries = (try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        if entries.isEmpty {
            return "\(normalizedPath(path)) is a directory and it is empty. Use list_directory if you want to browse it."
        }

        let preview = entries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(20)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? "- \(relativePath(for: url))/" : "- \(relativePath(for: url))"
            }
            .joined(separator: "\n")

        return "\(normalizedPath(path)) is a directory, not a file. Top entries:\n\(preview)"
    }

    private func missingFileFallback(path: String) -> String {
        let cleaned = normalizedPath(path)
        let rootEntries = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let preview = rootEntries
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(20)
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDirectory ? "- \(relativePath(for: url))/" : "- \(relativePath(for: url))"
            }
            .joined(separator: "\n")

        if preview.isEmpty {
            return "\(cleaned) was not found in the selected workspace. The workspace currently appears empty."
        }

        return "\(cleaned) was not found in the selected workspace. Top-level entries are:\n\(preview)"
    }

    private func jsonSummary(text: String, path: String, excerptLimit: Int) -> String? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        let cleaned = normalizedPath(path)
        if let dictionary = json as? [String: Any] {
            let keys = dictionary.keys.sorted()
            let previewKeys = keys.prefix(20).joined(separator: ", ")
            if text.count <= excerptLimit {
                return """
                JSON file \(cleaned) with top-level keys: \(previewKeys)

                \(text)
                """
            }

            let excerpt = String(text.prefix(excerptLimit))
            return """
            JSON file \(cleaned) is large.
            Top-level keys: \(previewKeys)
            Total top-level key count: \(keys.count)
            Content below is truncated to the first \(excerptLimit) characters.

            \(excerpt)
            """
        }

        if let array = json as? [Any] {
            let excerpt = String(text.prefix(min(text.count, excerptLimit)))
            return """
            JSON file \(cleaned) contains a top-level array with \(array.count) items.
            Content below is truncated to the first \(min(text.count, excerptLimit)) characters.

            \(excerpt)
            """
        }

        return nil
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Arguments for listing a directory inside the selected workspace")
private struct AppleIntelligenceListDirectoryArguments {
    let path: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Arguments for reading a text file inside the selected workspace")
private struct AppleIntelligenceReadFileArguments {
    let path: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Arguments for searching text across files in the selected workspace")
private struct AppleIntelligenceSearchFilesArguments {
    let query: String
}

@available(iOS 26.0, macOS 26.0, *)
@Generable(description: "Arguments for writing a text file inside the selected workspace")
private struct AppleIntelligenceWriteFileArguments {
    let path: String
    let content: String
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleIntelligenceListDirectoryTool: Tool {
    let toolbox: AppleIntelligenceWorkspaceToolbox
    let name = "list_directory"
    let description = "List files and folders at a relative workspace path when the user explicitly asks to browse or list files."

    func call(arguments: AppleIntelligenceListDirectoryArguments) async throws -> String {
        try toolbox.listDirectory(path: arguments.path)
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleIntelligenceReadFileTool: Tool {
    let toolbox: AppleIntelligenceWorkspaceToolbox
    let name = "read_file"
    let description = "Read a UTF-8 text file at a relative workspace path. If the path is a directory, you will get a short directory summary instead of an error."

    func call(arguments: AppleIntelligenceReadFileArguments) async throws -> String {
        try toolbox.readFile(path: arguments.path)
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleIntelligenceSearchFilesTool: Tool {
    let toolbox: AppleIntelligenceWorkspaceToolbox
    let name = "search_files"
    let description = "Search UTF-8 text files in the selected workspace for a query string."

    func call(arguments: AppleIntelligenceSearchFilesArguments) async throws -> String {
        try toolbox.searchFiles(query: arguments.query)
    }
}

@available(iOS 26.0, macOS 26.0, *)
private struct AppleIntelligenceWriteFileTool: Tool {
    let toolbox: AppleIntelligenceWorkspaceToolbox
    let name = "write_file"
    let description = "Write UTF-8 text content to a relative file path in the selected workspace."

    func call(arguments: AppleIntelligenceWriteFileArguments) async throws -> String {
        try toolbox.writeFile(path: arguments.path, content: arguments.content)
    }
}
#endif
