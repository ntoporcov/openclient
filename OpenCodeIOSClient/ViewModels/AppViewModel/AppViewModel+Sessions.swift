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

private enum OpenCodeActionResult {
    case success
    case failure
}

extension AppViewModel {
    struct ChatSessionHeaderSnapshot {
        let session: OpenCodeSession
        let isChildSession: Bool
        let parentSession: OpenCodeSession?
        let parentTitle: String
        let childTitle: String

        var navigationTitle: String {
            isChildSession ? childTitle : (session.title ?? "Session")
        }
    }

    func prepareSessionSelection(_ session: OpenCodeSession) {
        let cachedMessages = cachedMessagesBySessionID[session.id] ?? []
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .sessions
            selectedSession = session
            chatStore.beginSelectingSession(cachedMessages: cachedMessages)
            sessionInteractionStore.reset()
            selectedVCSFile = nil
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
        let previousSelectedSession = selectedSession
        let reload = try await sessionCoordinator.reloadDirectory(client: client, directory: effectiveSelectedDirectory)
        let bootstrap = reload.bootstrap
        withAnimation(opencodeSelectionAnimation) {
            isLoadingSessions = false
            allSessions = bootstrap.sessions
        }
        withAnimation(opencodeSelectionAnimation) {
            directoryCommands = bootstrap.commands
            objectWillChange.send()
            sessionInteractionStore.replacePermissions(bootstrap.permissions)
            sessionInteractionStore.replaceQuestions(bootstrap.questions)
        }
        let selection = sessionCoordinator.selectionAfterDirectoryReload(
            previousSelectedSession: previousSelectedSession,
            currentSelectedSessionID: selectedSession?.id,
            sessions: allSessions,
            currentStreamDirectory: streamDirectory,
            isProjectWorkspacesEnabled: isProjectWorkspacesEnabled,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            workspaceDirectories: workspaceDirectories(),
            fallbackSession: { [weak self] sessionID in self?.session(matching: sessionID) }
        )

        if selection.selectedSession != nil {
            withAnimation(opencodeSelectionAnimation) {
                selectedSession = selection.selectedSession
            }
            streamDirectory = selection.streamDirectory
        } else {
            withAnimation(opencodeSelectionAnimation) {
                selectedSession = nil
                if selection.shouldClearActiveChat {
                    chatStore.clearActiveTranscript()
                    sessionInteractionStore.replaceTodos([])
                }
            }
            streamDirectory = selection.streamDirectory
        }

        if selection.preservedWorkspaceSelection, let previousSelectedSession {
            appendDebugLog("preserve workspace selection after root reload session=\(debugSessionLabel(previousSelectedSession))")
        }
        if streamDirectory == nil {
            streamDirectory = allSessions.first?.directory
        }

        sessionStatuses = reload.statuses

        if hasGitProject {
            await reloadGitViewData(force: true)
        }

        publishWidgetSnapshots()
        await loadWorkspaceSessionsIfNeeded()
    }

    func refreshSessionList() async {
        do {
            try await reloadSessions()
            errorMessage = nil
        } catch {
            isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    func loadWorkspaceSessionsIfNeeded() async {
        guard isProjectWorkspacesEnabled else { return }
        await loadWorkspaceSessions()
    }

    func loadWorkspaceSessions() async {
        let directories = workspaceDirectories()
        guard !directories.isEmpty else { return }

        for directory in directories {
            await loadWorkspaceSessions(directory: directory, client: client)
        }
    }

    func loadMoreWorkspaceSessions(directory: String) async {
        sessionListStore.increaseWorkspaceSessionLimit(for: directory, by: 5)
        await loadWorkspaceSessions(directory: directory, client: client, force: true)
    }

    private func loadWorkspaceSessions(directory: String, client: OpenCodeAPIClient, force: Bool = false) async {
        let state = sessionListStore.workspaceSessionState(for: directory)
        if state.isLoading { return }
        if !force, !state.sessions.isEmpty, state.rootSessions.count >= state.limit { return }

        guard let loadingState = sessionListStore.markWorkspaceSessionsLoading(for: directory) else { return }

        do {
            let result = try await sessionCoordinator.loadWorkspaceSessions(client: client, directory: directory, limit: state.limit)

            withAnimation(opencodeSelectionAnimation) {
                sessionListStore.finishWorkspaceSessionsLoading(result.sessions, estimatedTotal: result.estimatedTotal, limit: state.limit, directory: directory)
            }
        } catch {
            sessionListStore.failWorkspaceSessionsLoading(previousState: loadingState, directory: directory)
        }
    }

    func reloadSessionStatuses() async throws {
        sessionStatuses = try await client.listSessionStatuses(directory: effectiveSelectedDirectory)
    }

    func createSession() async {
        guard canCreateSessionOrPresentPaywall() else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let targetDirectory = try await resolveNewSessionDirectory()
            let createSubmission = sessionCoordinator.prepareCreateSession(title: draftTitle, directory: targetDirectory)
            let session = try await sessionCoordinator.submitCreate(client: client, submission: createSubmission)
            draftTitle = ""
            newWorkspaceName = ""
            newSessionWorkspaceSelection = .main
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateSessionSheet = false
            }
            upsertVisibleSession(session)
            try await reloadSessions()
            upsertVisibleSession(session)
            withAnimation(opencodeSelectionAnimation) {
                selectedSession = session
                chatStore.beginSelectingSession(cachedMessages: cachedMessagesBySessionID[session.id] ?? [])
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replaceTodos([])
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

    func runAction(_ action: OpenCodeAction) async {
        guard hasProUnlock else {
            presentPaywall(reason: .actions)
            return
        }

        guard !isUsingAppleIntelligence else {
            errorMessage = "Actions require an OpenCode server connection."
            return
        }

        guard !isActionRunning(action) else { return }

        guard actionCommand(for: action) != nil else {
            errorMessage = "The /\(action.commandName) command is not available in this project."
            return
        }

        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var actionSession: OpenCodeSession?
        var didRunCommand = false
        var didCompleteSuccessfully = false

        do {
            let session = try await client.createSession(
                title: hiddenActionSessionTitle(commandName: action.commandName, runID: runID),
                directory: effectiveSelectedDirectory
            )
            actionSession = session
            seedComposerSelectionsForNewSession(session)
            upsertVisibleSession(session)
            setPendingActionRun(
                PendingOpenCodeActionRun(
                    sessionID: session.id,
                    actionID: action.id,
                    commandName: action.commandName,
                    runID: runID,
                    phase: .runningCommand
                )
            )

            let requestDirectory = sendDirectory(for: session)
            let modelReference = effectiveModelReference(for: session)
            let agentName = effectiveAgentName(for: session)
            let variant = selectedVariant(for: session)
            sessionStatuses[session.id] = "busy"

            appendDebugLog("action run command=/\(action.commandName) session=\(debugSessionLabel(session)) run=\(runID)")
            try await client.sendCommand(
                sessionID: session.id,
                command: action.commandName,
                arguments: "",
                directory: requestDirectory,
                model: modelReference,
                agent: agentName,
                variant: variant
            )
            didRunCommand = true

            updatePendingActionRunPhase(sessionID: session.id, phase: .checkingResult)
            sessionStatuses[session.id] = "busy"

            let response = try await client.sendMessage(
                sessionID: session.id,
                text: actionResultPrompt(commandName: action.commandName, runID: runID),
                directory: requestDirectory,
                model: modelReference,
                agent: agentName,
                variant: variant
            )
            sessionStatuses[session.id] = "idle"

            let result = actionResult(from: [response], runID: runID)
            clearPendingActionRun(sessionID: session.id)

            switch result {
            case .success?:
                didCompleteSuccessfully = true
                appendDebugLog("action success command=/\(action.commandName) session=\(debugSessionLabel(session))")
                try await archiveActionSession(session, directory: requestDirectory)
                removeActionSessionFromLocalState(sessionID: session.id)
            case .failure?, nil:
                let resultLabel = result.map { _ in "failure" } ?? "missing"
                appendDebugLog("action failure command=/\(action.commandName) session=\(debugSessionLabel(session)) result=\(resultLabel)")
                try await revealActionSession(session, commandName: action.commandName)
            }

            errorMessage = nil
        } catch {
            if let session = actionSession {
                clearPendingActionRun(sessionID: session.id)
                if didCompleteSuccessfully {
                    removeActionSessionFromLocalState(sessionID: session.id)
                } else if didRunCommand {
                    try? await revealActionSession(session, commandName: action.commandName)
                } else {
                    try? await client.deleteSession(sessionID: session.id, directory: session.directory, workspaceID: session.workspaceID)
                    removeActionSessionFromLocalState(sessionID: session.id)
                }
            }
            appendDebugLog("action error command=/\(action.commandName) error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    private func setPendingActionRun(_ run: PendingOpenCodeActionRun) {
        withAnimation(opencodeSelectionAnimation) {
            sessionListStore.setPendingActionRun(run)
        }
    }

    private func updatePendingActionRunPhase(sessionID: String, phase: OpenCodeActionRunPhase) {
        withAnimation(opencodeSelectionAnimation) {
            sessionListStore.updatePendingActionRun(for: sessionID) { run in
                run.phase = phase
                return true
            }
        }
    }

    private func clearPendingActionRun(sessionID: String) {
        withAnimation(opencodeSelectionAnimation) {
            sessionListStore.updatePendingActionRun(for: sessionID) { _ in false }
        }
    }

    private func revealActionSession(_ session: OpenCodeSession, commandName: String) async throws {
        let updatedSession = try await client.updateSessionTitle(
            sessionID: session.id,
            title: actionDebugSessionTitle(commandName: commandName)
        )
        upsertVisibleSession(updatedSession)
        try? await reloadSessions()
    }

    private func archiveActionSession(_ session: OpenCodeSession, directory: String?) async throws {
        do {
            _ = try await client.archiveSession(
                sessionID: session.id,
                directory: directory ?? session.directory,
                workspaceID: session.workspaceID
            )
            appendDebugLog("action archived session=\(debugSessionLabel(session))")
        } catch {
            appendDebugLog("action archive failed session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            try await client.deleteSession(
                sessionID: session.id,
                directory: directory ?? session.directory,
                workspaceID: session.workspaceID
            )
            appendDebugLog("action deleted fallback session=\(debugSessionLabel(session))")
        }
    }

    private func removeActionSessionFromLocalState(sessionID: String) {
        withAnimation(opencodeSelectionAnimation) {
            allSessions.removeAll { $0.id == sessionID }
            sessionStatuses[sessionID] = nil
            chatStore.clearCachedMessages(forSessionID: sessionID)
            sessionListStore.removeSessionFromWorkspaceStates(sessionID: sessionID)
        }
        removeSessionPreview(for: sessionID)
        clearPersistedMessageDraft(forSessionID: sessionID)
    }

    private func actionResultPrompt(commandName: String, runID: String) -> String {
        """
        Evaluate the just-completed /\(commandName) action in this session.

        Reply with exactly one line and no other text:
        OPENCLIENT_ACTION_RESULT:\(runID):SUCCESS
        or
        OPENCLIENT_ACTION_RESULT:\(runID):FAILURE

        Use SUCCESS only if the action completed successfully and no user debugging is needed.
        Use FAILURE if anything failed, is ambiguous, or requires user attention.
        """
    }

    private func actionResult(from messages: [OpenCodeMessageEnvelope], runID: String) -> OpenCodeActionResult? {
        let text = messages
            .flatMap(\.parts)
            .compactMap(\.text)
            .joined(separator: "\n")
            .uppercased()
        let markerPrefix = "OPENCLIENT_ACTION_RESULT:\(runID.uppercased()):"

        if text.contains(markerPrefix + "FAILURE") {
            return .failure
        }
        if text.contains(markerPrefix + "SUCCESS") {
            return .success
        }
        return nil
    }

    private func resolveNewSessionDirectory() async throws -> String? {
        guard isProjectWorkspacesEnabled,
              hasGitProject,
              let project = currentProject,
              project.id != "global" else {
            return effectiveSelectedDirectory
        }

        switch newSessionWorkspaceSelection {
        case .main:
            return project.worktree
        case let .directory(directory):
            return directory
        case .createNew:
            let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = try await client.createWorktree(
                directory: project.worktree,
                name: name.isEmpty ? nil : name
            )
            appendSandboxDirectory(created.directory, to: project)
            sessionListStore.ensureWorkspaceStateExists(
                for: created.directory,
                defaultState: OpenCodeWorkspaceSessionState(isLoading: true)
            )
            return created.directory
        }
    }

    func selectSession(_ session: OpenCodeSession) async {
        if isUsingAppleIntelligence {
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                selectedSession = session
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
            chatStore.finishLoadingSelectedSession()
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
        let rawText = draftMessage
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = draftAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }

        if attachments.isEmpty, shouldOpenForkSheet(forSlashInput: text) {
            objectWillChange.send()
            composerStore.resetActiveDraft()
            presentForkSessionSheet()
            return
        }

        if let (command, arguments) = slashCommandInput(from: text) {
            if isForkClientCommand(command) {
                objectWillChange.send()
                composerStore.resetActiveDraft()
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

        await sendMessage(rawText, agentMentions: draftAgentMentions, attachments: attachments, sessionID: selectedSessionID, userVisible: true, meterPrompt: meterPrompt)
    }

    func sendCommand(_ command: OpenCodeCommand, sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        await sendCommand(command, arguments: "", attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        await sendCommand(command, arguments: arguments, attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        guard let session = session(matching: sessionID) else { return }
        await sendCommand(command, arguments: arguments, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], in selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        if isCompactClientCommand(command) {
            await compactSession(selectedSession, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
            return
        }

        guard sessionStatuses[selectedSession.id] != "busy" else {
            appendDebugLog("command blocked busy session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            return
        }

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("command blocked paywall session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            return
        }

        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        let commandPreparation = sessionCoordinator.prepareCommandSubmission(
            command: command,
            arguments: arguments,
            attachments: attachments,
            session: selectedSession,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id,
            model: modelReference,
            agent: agentName,
            variant: variant
        )
        let commandSubmission = commandPreparation.submission

        if userVisible {
            objectWillChange.send()
            composerStore.draftMessage = ""
            composerStore.draftAgentMentions = []
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerStore.resetToken = UUID()
        }

        appendDebugLog("command send: \(commandPreparation.draftCommand)")
        appendDebugLog(
            "command scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) requestDir=\(debugDirectoryLabel(commandSubmission.directory))"
        )

        isLoading = true
        let previousStatus = sessionStatuses[selectedSession.id]
        let statusTransition = sessionCoordinator.commandStatusTransition(
            for: commandPreparation,
            previousStatus: previousStatus
        )
        sessionStatuses[statusTransition.sessionID] = statusTransition.nextStatus
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await sessionCoordinator.submitCommand(client: client, submission: commandSubmission)
            appendDebugLog("command accepted session=\(debugSessionLabel(selectedSession)) command=\(command.name)")
            startLiveRefresh(for: selectedSession, reason: "command")
            errorMessage = nil
        } catch {
            if userVisible {
                refundReservedUserPromptIfNeeded()
            }
            if userVisible, restoreDraftOnFailure {
                let rollback = sessionCoordinator.commandRollback(
                    for: commandPreparation,
                    previousStatus: statusTransition.previousStatus
                )
                objectWillChange.send()
                composerStore.draftMessage = rollback.draftText
                composerStore.draftAgentMentions = []
                addDraftAttachments(rollback.attachments)
                persistCurrentMessageDraft(forSessionID: rollback.sessionID)
                composerStore.resetToken = UUID()
            }
            sessionStatuses[statusTransition.sessionID] = statusTransition.previousStatus
            appendDebugLog("command error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func stopCurrentSession() async {
        if isUsingAppleIntelligence {
            appleIntelligenceResponseTask?.cancel()
            if let selectedSession {
                sessionStatuses[selectedSession.id] = "idle"
            }
            persistAppleIntelligenceMessages()
            return
        }

        guard let selectedSession else { return }
        let abortSubmission = sessionCoordinator.prepareAbortSession(
            session: selectedSession,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id
        )

        do {
            appendDebugLog(
                "abort request session=\(debugSessionLabel(selectedSession)) directory=\(debugDirectoryLabel(abortSubmission.directory)) workspace=\(abortSubmission.workspaceID ?? "nil")"
            )
            try await sessionCoordinator.submitAbort(
                client: client,
                submission: abortSubmission
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

    func sendMessage(_ text: String, agentMentions: [OpenCodeAgentMention] = [], attachments: [OpenCodeComposerAttachment] = [], sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async {
        if isUsingAppleIntelligence {
            guard let session = session(matching: sessionID) else { return }
            await sendAppleIntelligenceMessage(text, attachments: attachments, in: session, userVisible: userVisible)
            return
        }

        guard let session = session(matching: sessionID) else { return }
        await sendMessage(text, agentMentions: agentMentions, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt)
    }

    @discardableResult
    func insertOptimisticUserMessage(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
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
            agentMentions: agentMentions,
            attachments: attachments,
            messageID: resolvedMessageID,
            sessionID: selectedSession.id,
            partID: resolvedPartID,
            agent: effectiveAgentName(for: selectedSession),
            model: optimisticModel
        )

        if animated {
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                chatStore.insertOptimisticUserMessage(localUserMessage)
            }
        } else {
            chatStore.insertOptimisticUserMessage(localUserMessage)
        }
        markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        return (resolvedMessageID, resolvedPartID)
    }

    func sendMessage(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
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

        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        guard let promptPreparation = sessionCoordinator.preparePromptSubmission(
            text: text,
            agentMentions: agentMentions,
            attachments: attachments,
            session: selectedSession,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id,
            messageID: messageID,
            partID: partID,
            model: modelReference,
            agent: agentName,
            variant: variant
        ) else { return }

        let submission = promptPreparation.submission

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("send blocked paywall session=\(debugSessionLabel(selectedSession))")
            return
        }

        let start = sessionCoordinator.promptStart(for: promptPreparation)
        let resolvedMessageID = start.messageID
        let resolvedPartID = start.partID

        let localUserMessage = sessionCoordinator.optimisticUserMessage(for: promptPreparation)
        if userVisible, appendOptimisticMessage {
            objectWillChange.send()
            composerStore.draftMessage = ""
            composerStore.draftAgentMentions = []
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerStore.resetToken = UUID()
            chatStore.insertOptimisticUserMessage(localUserMessage)
            markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        }
        markChatBreadcrumb("send start", sessionID: start.sessionID, messageID: start.messageID, partID: start.partID)
        appendDebugLog("send: \(start.text)")
        appendDebugLog(
            "send scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil") requestDir=\(debugDirectoryLabel(start.requestDirectory)) msgID=\(start.messageID) partID=\(start.partID)"
        )

        isLoading = true
        let previousStatus = sessionStatuses[selectedSession.id]
        let statusTransition = sessionCoordinator.promptStatusTransition(
            for: promptPreparation,
            previousStatus: previousStatus
        )
        sessionStatuses[statusTransition.sessionID] = statusTransition.nextStatus
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await sessionCoordinator.submitPrompt(
                client: client,
                submission: submission
            )
            let success = sessionCoordinator.promptSuccess(for: promptPreparation)
            appendDebugLog("prompt_async accepted session=\(debugSessionLabel(selectedSession)) msgID=\(success.messageID) partID=\(success.partID)")
            markChatBreadcrumb("prompt_async accepted", sessionID: success.sessionID, messageID: success.messageID, partID: success.partID)
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
                let rollback = sessionCoordinator.promptRollback(
                    for: promptPreparation,
                    optimisticMessage: localUserMessage,
                    previousStatus: statusTransition.previousStatus
                )
                chatStore.rollbackOptimisticUserMessage(messageID: rollback.optimisticMessageID)
                markChatBreadcrumb("send rollback", sessionID: rollback.sessionID, messageID: rollback.messageID, partID: rollback.partID)
                objectWillChange.send()
                composerStore.draftMessage = rollback.draftText
                composerStore.draftAgentMentions = rollback.agentMentions
                addDraftAttachments(rollback.attachments)
                persistCurrentMessageDraft(forSessionID: rollback.sessionID)
                composerStore.resetToken = UUID()
            }
            sessionStatuses[statusTransition.sessionID] = statusTransition.previousStatus
            appendDebugLog("send error: \(error.localizedDescription)")
            markChatBreadcrumb("send error", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
            errorMessage = error.localizedDescription
        }
    }

    func removeOptimisticUserMessage(messageID: String, sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        chatStore.removeOptimisticUserMessage(messageID: messageID)
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
        let currentMessages = messages
        var result: [OpenCodeForkableMessage] = []

        for message in currentMessages {
            guard (message.info.role ?? "").lowercased() == "user" else { continue }
            guard let text = sessionCoordinator.forkPromptDraft(from: message).text.nilIfEmpty else { continue }

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

    func compactSession(sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        guard let session = session(matching: sessionID) else { return }
        await compactSession(session, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    func compactSession(_ selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async {
        guard selectedSession.parentID == nil else {
            appendDebugLog("compact blocked child session=\(debugSessionLabel(selectedSession))")
            errorMessage = "Compact is only available in root sessions."
            return
        }

        guard sessionStatuses[selectedSession.id] != "busy" else {
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

        let compactPreparation = sessionCoordinator.prepareCompactSession(
            session: selectedSession,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id,
            model: modelReference
        )

        if userVisible {
            objectWillChange.send()
            composerStore.draftMessage = ""
            composerStore.draftAgentMentions = []
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerStore.resetToken = UUID()
        }

        appendDebugLog(
            "compact request session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) requestDir=\(debugDirectoryLabel(compactPreparation.directory)) model=\(modelReference.providerID)/\(modelReference.modelID)"
        )

        isLoading = true
        let previousStatus = sessionStatuses[selectedSession.id]
        let statusTransition = sessionCoordinator.compactStatusTransition(
            for: compactPreparation,
            previousStatus: previousStatus
        )
        sessionStatuses[statusTransition.sessionID] = statusTransition.nextStatus
        defer { isLoading = false }

        await maybeAutoStartLiveActivity(for: selectedSession)

        do {
            try await sessionCoordinator.submitCompact(
                client: client,
                preparation: compactPreparation
            )
            appendDebugLog("compact accepted session=\(debugSessionLabel(selectedSession))")
            startLiveRefresh(for: selectedSession, reason: "compact")
            refreshLiveActivityIfNeeded(for: selectedSession.id)
            errorMessage = nil
        } catch {
            if userVisible, restoreDraftOnFailure {
                refundReservedUserPromptIfNeeded()
                let rollback = sessionCoordinator.compactRollback(
                    for: compactPreparation,
                    previousStatus: statusTransition.previousStatus
                )
                objectWillChange.send()
                composerStore.draftMessage = rollback.draftText
                composerStore.draftAgentMentions = []
                persistCurrentMessageDraft(forSessionID: rollback.sessionID)
                composerStore.resetToken = UUID()
            }
            sessionStatuses[statusTransition.sessionID] = statusTransition.previousStatus
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
        let sourceMessage = messages.first { $0.id == messageID }
        let forkPreparation = sessionCoordinator.prepareForkSession(
            session: selectedSession,
            messageID: messageID,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id,
            sourceMessage: sourceMessage
        )
        let forkSubmission = forkPreparation.submission

        pendingForkSessionID = forkSubmission.sessionID
        pendingForkMessageID = forkSubmission.messageID
        isLoading = true
        defer {
            pendingForkSessionID = nil
            pendingForkMessageID = nil
            isLoading = false
        }

        do {
            appendDebugLog("fork request session=\(debugSessionLabel(selectedSession)) message=\(forkSubmission.messageID) directory=\(debugDirectoryLabel(forkSubmission.directory))")
            let forked = try await sessionCoordinator.submitFork(
                client: client,
                submission: forkSubmission
            )
            appendDebugLog("fork accepted session=\(debugSessionLabel(forked)) parent=\(selectedSession.id) message=\(forkSubmission.messageID)")

            withAnimation(opencodeSelectionAnimation) {
                isShowingForkSessionSheet = false
            }
            upsertVisibleSession(forked)
            try? await reloadSessions()
            upsertVisibleSession(forked)
            await selectSession(forked)

            if let restoredPrompt = forkPreparation.restoredPrompt {
                objectWillChange.send()
                composerStore.resetActiveDraft(text: restoredPrompt.text, attachments: restoredPrompt.attachments)
                persistCurrentMessageDraft(forSessionID: forked.id)
            }

            errorMessage = nil
        } catch {
            appendDebugLog("fork error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func loadMessages(
        for session: OpenCodeSession,
        prefetchToolDetails: Bool = true,
        refreshTodos: Bool = true
    ) async throws {
        let loadedMessages = try await client.listMessages(sessionID: session.id, directory: session.directory)
        refreshSessionPreview(for: session.id, messages: loadedMessages)
        let isActiveSession = selectedSession?.id == session.id
        chatStore.applyCanonicalMessages(loadedMessages, forSessionID: session.id, isActiveSession: isActiveSession)
        guard isActiveSession else { return }
        appendDebugLog(serverMessageSummary(loadedMessages, sessionID: session.id, reason: "loadMessages"))
        syncComposerSelections(for: session)
        if prefetchToolDetails {
            prefetchToolMessageDetails(for: session, messages: messages)
        }
        refreshLiveActivityIfNeeded(for: session.id)
        if refreshTodos {
            await loadTodos(for: session)
        }
    }

    func refreshChatData(for sessionID: String) async {
        guard !isUsingAppleIntelligence else { return }
        guard let session = session(matching: sessionID) else { return }

        appendDebugLog("manual chat refresh session=\(debugSessionLabel(session))")

        do {
            async let sessions: Void = reloadSessions()
            async let statuses: Void = reloadSessionStatuses()
            async let loadedMessages: Void = loadMessages(for: session)
            async let permissions: Void = loadAllPermissions(for: session)
            async let questions: Void = loadAllQuestions(for: session)
            _ = try await (sessions, statuses, loadedMessages, permissions, questions)

            let refreshedSession = self.session(matching: sessionID) ?? session
            await refreshToolMessageDetails(for: refreshedSession, messages: cachedMessagesBySessionID[sessionID] ?? messages)
            errorMessage = nil
        } catch {
            appendDebugLog("manual chat refresh error session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    func scheduleForegroundChatCatchUp(reason: String) {
        guard !isUsingAppleIntelligence else { return }
        guard selectedSession != nil || activeChatSessionID != nil else { return }

        let now = Date.now
        guard now.timeIntervalSince(lastForegroundChatCatchUpScheduledAt) >= 2 else { return }
        lastForegroundChatCatchUpScheduledAt = now

        let initialSessionID = activeChatSessionID ?? selectedSession?.id
        foregroundChatCatchUpTask?.cancel()
        foregroundChatCatchUpTask = Task { [weak self] in
            for (index, delay) in [Duration.milliseconds(250), .milliseconds(1_500), .seconds(4)].enumerated() {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.runForegroundChatCatchUp(
                    initialSessionID: initialSessionID,
                    reason: reason,
                    attempt: index + 1
                )
            }
        }
    }

    private func runForegroundChatCatchUp(initialSessionID: String?, reason: String, attempt: Int) async {
        guard !isUsingAppleIntelligence else { return }
        guard isConnected else {
            appendDebugLog("foreground catch-up waiting for connection attempt=\(attempt) reason=\(reason)")
            return
        }

        guard let sessionID = activeChatSessionID ?? selectedSession?.id ?? initialSessionID,
              let session = session(matching: sessionID) else {
            appendDebugLog("foreground catch-up skipped missing session attempt=\(attempt) reason=\(reason)")
            return
        }

        appendDebugLog("foreground catch-up start attempt=\(attempt) session=\(debugSessionLabel(session)) reason=\(reason)")

        do {
            async let statuses: Void = reloadSessionStatuses()
            async let loadedMessages: Void = loadMessages(
                for: session,
                prefetchToolDetails: attempt == 1,
                refreshTodos: attempt == 1
            )
            _ = try await (statuses, loadedMessages)
            appendDebugLog("foreground catch-up finish attempt=\(attempt) session=\(debugSessionLabel(session))")
            errorMessage = nil
        } catch {
            appendDebugLog("foreground catch-up error attempt=\(attempt) session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
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
            let latestTodoMessageID = messages
                .reversed()
                .first { envelope in
                    envelope.parts.contains(where: { $0.tool == "todowrite" })
                }?
                .info.id

            return (todos, latestTodoMessageID.flatMap { toolMessageDetails[$0] })
        }

        let refreshedTodos = try await client.getTodos(sessionID: selectedSession.id)
        objectWillChange.send()
        sessionInteractionStore.replaceTodos(refreshedTodos)

        let latestTodoMessageID = messages
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
                objectWillChange.send()
                sessionInteractionStore.replaceTodos(todos)
            }
            refreshLiveActivityIfNeeded(for: session.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replaceTodos([])
            }
            refreshLiveActivityIfNeeded(for: session.id)
        }
    }

    func loadAllPermissions(directory: String? = nil, workspaceID: String? = nil) async {
        do {
            let permissions = try await client.listPermissions(directory: directory, workspaceID: workspaceID)
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replacePermissions(permissions)
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replacePermissions([])
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
                objectWillChange.send()
                sessionInteractionStore.replaceQuestions(questions)
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replaceQuestions([])
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        }
    }

    func loadAllQuestions(for session: OpenCodeSession) async {
        await loadAllQuestions(directory: sendDirectory(for: session), workspaceID: session.workspaceID)
    }

    var selectedSessionPermissions: [OpenCodePermission] {
        guard let selectedSession else { return [] }
        return sessionInteractionStore.permissions(forSessionID: selectedSession.id)
    }

    func permissions(for sessionID: String) -> [OpenCodePermission] {
        sessionInteractionStore.permissions(forSessionID: sessionID)
    }

    var selectedSessionQuestions: [OpenCodeQuestionRequest] {
        guard let selectedSession else { return [] }
        return sessionInteractionStore.questions(forSessionID: selectedSession.id)
    }

    func questions(for sessionID: String) -> [OpenCodeQuestionRequest] {
        sessionInteractionStore.questions(forSessionID: sessionID)
    }

    func hasPermissionRequest(for session: OpenCodeSession) -> Bool {
        sessionInteractionStore.hasPermissionRequest(forSessionID: session.id)
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
                objectWillChange.send()
                sessionInteractionStore.removePermission(id: permission.id)
            }
            refreshLiveActivityIfNeeded(for: permission.sessionID)
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        withAnimation(opencodeSelectionAnimation) {
            objectWillChange.send()
            sessionInteractionStore.removePermission(id: permission.id)
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
                objectWillChange.send()
                sessionInteractionStore.removeQuestion(id: request.id)
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
                objectWillChange.send()
                sessionInteractionStore.removeQuestion(id: request.id)
            }
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSession(_ session: OpenCodeSession) async {
        do {
            let deleteSubmission = sessionCoordinator.prepareDeleteSession(
                session: session,
                selectedDirectory: effectiveSelectedDirectory,
                currentProjectID: currentProject?.id
            )
            try await sessionCoordinator.submitDelete(client: client, submission: deleteSubmission)
            withAnimation(opencodeSelectionAnimation) {
                removePinnedSessionIDFromAllScopes(session.id)
            }
            removeSessionPreview(for: session.id)
            if selectedSession?.id == session.id {
                persistCurrentMessageDraft(forSessionID: session.id)
                withAnimation(opencodeSelectionAnimation) {
                    selectedSession = nil
                    messages = []
                }
            }
            clearPersistedMessageDraft(forSessionID: session.id)
            try await reloadSessions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSession(_ session: OpenCodeSession, title: String) async {
        do {
            guard let renameSubmission = sessionCoordinator.prepareRenameSession(
                session: session,
                title: title,
                selectedDirectory: effectiveSelectedDirectory,
                currentProjectID: currentProject?.id
            ) else { return }
            let updatedSession = try await sessionCoordinator.submitRename(client: client, submission: renameSubmission)
            upsertVisibleSession(updatedSession)
            if selectedSession?.id == updatedSession.id {
                withAnimation(opencodeSelectionAnimation) {
                    selectedSession = updatedSession
                }
            }
            publishWidgetSnapshots()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func presentCreateSessionSheet() {
        draftTitle = ""
        newWorkspaceName = ""
        newSessionWorkspaceSelection = .main
        withAnimation(opencodeSelectionAnimation) {
            isShowingCreateSessionSheet = true
        }
    }

    func upsertVisibleSession(_ session: OpenCodeSession) {
        withAnimation(opencodeSelectionAnimation) {
            sessionListStore.upsertVisibleSession(session, visibleSessions: &allSessions)
        }
    }

    func session(matching sessionID: String) -> OpenCodeSession? {
        sessionListStore.session(matching: sessionID, visibleSessions: allSessions, selectedSession: selectedSession)
    }

    func parentSession(for session: OpenCodeSession) -> OpenCodeSession? {
        guard let parentID = session.parentID else { return nil }
        return self.session(matching: parentID)
    }

    func childSessions(for sessionID: String) -> [OpenCodeSession] {
        sessionListStore.childSessions(for: sessionID, visibleSessions: allSessions)
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

    func chatSessionHeaderSnapshot(for session: OpenCodeSession) -> ChatSessionHeaderSnapshot {
        let parent = parentSession(for: session)
        return ChatSessionHeaderSnapshot(
            session: session,
            isChildSession: session.parentID != nil,
            parentSession: parent,
            parentTitle: parent?.title ?? "Session",
            childTitle: childSessionTitle(for: session)
        )
    }

    private func mergeSessions(_ sessions: [OpenCodeSession]) {
        sessionListStore.mergeSessions(sessions, into: &allSessions)
    }

    func sendDirectory(for session: OpenCodeSession) -> String? {
        appendDebugLog(
            "sendDirectory session=\(debugSessionLabel(session)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil")"
        )
        return sessionCoordinator.promptDirectory(
            for: session,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id
        )
    }

    func prefetchToolMessageDetails(for session: OpenCodeSession, messages: [OpenCodeMessageEnvelope]) {
        let toolMessageIDs = chatStore.recentToolMessageIDs(in: messages, limit: 12)

        for messageID in toolMessageIDs where chatStore.reserveToolMessageDetailFetchIfNeeded(messageID: messageID) {
            Task { [weak self] in
                guard let self else { return }
                defer {
                    Task { @MainActor [weak self] in
                        self?.chatStore.finishToolMessageDetailFetch(messageID: messageID)
                    }
                }
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
        let toolMessageIDs = chatStore.recentToolMessageIDs(in: messages, limit: 20)

        for messageID in toolMessageIDs {
            do {
                toolMessageDetails[messageID] = try await client.getMessage(sessionID: session.id, messageID: messageID)
            } catch {
                appendDebugLog("tool detail refresh failed session=\(debugSessionLabel(session)) message=\(messageID) error=\(error.localizedDescription)")
            }
        }
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
        let priorMessages = messages.filter { $0.id != userMessageID }

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
            objectWillChange.send()
            composerStore.draftMessage = ""
            composerStore.draftAgentMentions = []
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: session.id)
            composerStore.resetToken = UUID()
            withAnimation(opencodeSelectionAnimation) {
                chatStore.appendLocalAppleIntelligenceExchange(
                    userMessage: localUserMessage,
                    assistantMessage: localAssistantMessage,
                    appendUserMessage: appendOptimisticMessage
                )
            }
        }

        persistAppleIntelligenceMessages()
        sessionStatuses[session.id] = "busy"
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
                sessionStatuses[session.id] = "idle"
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
                sessionStatuses[session.id] = "idle"
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
                    self.sessionStatuses[session.id] = "idle"
                    self.isLoading = false
                    self.persistAppleIntelligenceMessages()
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.sessionStatuses[session.id] = "idle"
                    self.isLoading = false
                    self.persistAppleIntelligenceMessages()
                }
            } catch {
                await MainActor.run {
                    self.sessionStatuses[session.id] = "idle"
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
        chatStore.updateLocalAppleIntelligenceAssistantMessage(
            messageID: messageID,
            partID: partID,
            sessionID: sessionID,
            text: text
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
