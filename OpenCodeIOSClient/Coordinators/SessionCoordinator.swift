import Foundation

@MainActor
final class SessionCoordinator {
    struct DirectoryReloadResult {
        let bootstrap: OpenCodeDirectoryBootstrap
        let statuses: [String: String]
    }

    struct PromptSubmission {
        let sessionID: String
        let text: String
        let attachments: [OpenCodeComposerAttachment]
        let directory: String?
        let messageID: String
        let partID: String
        let model: OpenCodeModelReference?
        let agent: String?
        let variant: String?
    }

    struct PromptPreparation {
        let submission: PromptSubmission
        let optimisticModel: OpenCodeMessageModelReference?
    }

    struct PromptRollback {
        let sessionID: String
        let optimisticMessageID: String
        let messageID: String
        let partID: String
        let draftText: String
        let attachments: [OpenCodeComposerAttachment]
        let previousStatus: String?
    }

    struct PromptSuccess {
        let sessionID: String
        let messageID: String
        let partID: String
        let requestDirectory: String?
    }

    struct PromptStart {
        let sessionID: String
        let messageID: String
        let partID: String
        let text: String
        let requestDirectory: String?
    }

    struct PromptStatusTransition {
        let sessionID: String
        let previousStatus: String?
        let nextStatus: String
    }

    struct CommandSubmission {
        let sessionID: String
        let commandName: String
        let arguments: String
        let attachments: [OpenCodeComposerAttachment]
        let directory: String?
        let model: OpenCodeModelReference?
        let agent: String?
        let variant: String?
    }

    struct CommandPreparation {
        let submission: CommandSubmission
        let draftCommand: String
    }

    struct CommandRollback {
        let sessionID: String
        let draftText: String
        let attachments: [OpenCodeComposerAttachment]
        let previousStatus: String?
    }

    struct CompactPreparation {
        let sessionID: String
        let directory: String?
        let model: OpenCodeModelReference
        let draftCommand: String
    }

    struct ForkSubmission {
        let sessionID: String
        let messageID: String
        let directory: String?
        let workspaceID: String?
    }

    struct ForkPromptDraft {
        let text: String
        let attachments: [OpenCodeComposerAttachment]
    }

    struct ForkPreparation {
        let submission: ForkSubmission
        let restoredPrompt: ForkPromptDraft?
    }

    struct AbortSubmission {
        let sessionID: String
        let directory: String?
        let workspaceID: String?
    }

    struct DeleteSubmission {
        let sessionID: String
        let directory: String?
        let workspaceID: String?
    }

    struct RenameSubmission {
        let sessionID: String
        let title: String
        let directory: String?
        let workspaceID: String?
    }

    struct CreateSubmission {
        let title: String?
        let directory: String?
    }

    struct WorkspaceSessionsResult {
        let sessions: [OpenCodeSession]
        let estimatedTotal: Int
    }

    struct DirectoryReloadSelection {
        let selectedSession: OpenCodeSession?
        let streamDirectory: String?
        let shouldClearActiveChat: Bool
        let preservedWorkspaceSelection: Bool
    }

    func reloadDirectory(client: OpenCodeAPIClient, directory: String?) async throws -> DirectoryReloadResult {
        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(client: client, directory: directory)
        let statuses = try await client.listSessionStatuses(directory: directory)
        return DirectoryReloadResult(bootstrap: bootstrap, statuses: statuses)
    }

    func selectionAfterDirectoryReload(
        previousSelectedSession: OpenCodeSession?,
        currentSelectedSessionID: String?,
        sessions: [OpenCodeSession],
        currentStreamDirectory: String?,
        isProjectWorkspacesEnabled: Bool,
        effectiveSelectedDirectory: String?,
        workspaceDirectories: [String],
        fallbackSession: (String) -> OpenCodeSession?
    ) -> DirectoryReloadSelection {
        if let currentSelectedSessionID,
           let refreshed = sessions.first(where: { $0.id == currentSelectedSessionID }) {
            return DirectoryReloadSelection(
                selectedSession: refreshed,
                streamDirectory: refreshed.directory,
                shouldClearActiveChat: false,
                preservedWorkspaceSelection: false
            )
        }

        if let previousSelectedSession,
           shouldPreserveWorkspaceSelectionDuringRootReload(
            previousSelectedSession,
            isProjectWorkspacesEnabled: isProjectWorkspacesEnabled,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            workspaceDirectories: workspaceDirectories
           ) {
            let selectedSession = fallbackSession(previousSelectedSession.id) ?? previousSelectedSession
            return DirectoryReloadSelection(
                selectedSession: selectedSession,
                streamDirectory: selectedSession.directory ?? previousSelectedSession.directory,
                shouldClearActiveChat: false,
                preservedWorkspaceSelection: true
            )
        }

        return DirectoryReloadSelection(
            selectedSession: nil,
            streamDirectory: currentStreamDirectory ?? sessions.first?.directory,
            shouldClearActiveChat: true,
            preservedWorkspaceSelection: false
        )
    }

    func loadWorkspaceSessions(client: OpenCodeAPIClient, directory: String, limit: Int) async throws -> WorkspaceSessionsResult {
        let requestLimit = max(limit, 5)
        let loaded = try await client.listSessions(directory: directory, roots: true, limit: requestLimit)
            .filter(\.isRootSession)
        let estimatedTotal = loaded.count < requestLimit ? loaded.count : loaded.count + 1
        return WorkspaceSessionsResult(sessions: loaded, estimatedTotal: estimatedTotal)
    }

    private func shouldPreserveWorkspaceSelectionDuringRootReload(
        _ session: OpenCodeSession,
        isProjectWorkspacesEnabled: Bool,
        effectiveSelectedDirectory: String?,
        workspaceDirectories: [String]
    ) -> Bool {
        guard isProjectWorkspacesEnabled,
              let sessionDirectory = session.directory,
              !sessionDirectory.isEmpty,
              let effectiveSelectedDirectory,
              !effectiveSelectedDirectory.isEmpty else {
            return false
        }

        return workspaceKey(sessionDirectory) != workspaceKey(effectiveSelectedDirectory)
            && workspaceDirectories.contains { workspaceKey($0) == workspaceKey(sessionDirectory) }
    }

    private func workspaceKey(_ directory: String) -> String {
        let normalized = directory.replacingOccurrences(of: "\\", with: "/")
        if normalized.allSatisfy({ $0 == "/" }) { return "/" }
        return normalized.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
    }

    func createSession(client: OpenCodeAPIClient, title: String, directory: String?) async throws -> OpenCodeSession {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await client.createSession(title: trimmedTitle.isEmpty ? nil : trimmedTitle, directory: directory)
    }

    func prepareCreateSession(title: String, directory: String?) -> CreateSubmission {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateSubmission(
            title: trimmedTitle.isEmpty ? nil : trimmedTitle,
            directory: directory
        )
    }

    func submitCreate(client: OpenCodeAPIClient, submission: CreateSubmission) async throws -> OpenCodeSession {
        try await client.createSession(title: submission.title, directory: submission.directory)
    }

    func deleteSession(client: OpenCodeAPIClient, sessionID: String) async throws {
        try await client.deleteSession(sessionID: sessionID)
    }

    func prepareDeleteSession(
        session: OpenCodeSession,
        selectedDirectory: String?,
        currentProjectID: String?
    ) -> DeleteSubmission {
        DeleteSubmission(
            sessionID: session.id,
            directory: promptDirectory(
                for: session,
                selectedDirectory: selectedDirectory,
                currentProjectID: currentProjectID
            ),
            workspaceID: session.workspaceID
        )
    }

    func submitDelete(client: OpenCodeAPIClient, submission: DeleteSubmission) async throws {
        try await client.deleteSession(
            sessionID: submission.sessionID,
            directory: submission.directory,
            workspaceID: submission.workspaceID
        )
    }

    func renameSession(client: OpenCodeAPIClient, sessionID: String, title: String) async throws -> OpenCodeSession? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        return try await client.updateSessionTitle(sessionID: sessionID, title: trimmedTitle)
    }

    func prepareRenameSession(
        session: OpenCodeSession,
        title: String,
        selectedDirectory: String?,
        currentProjectID: String?
    ) -> RenameSubmission? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        return RenameSubmission(
            sessionID: session.id,
            title: trimmedTitle,
            directory: promptDirectory(
                for: session,
                selectedDirectory: selectedDirectory,
                currentProjectID: currentProjectID
            ),
            workspaceID: session.workspaceID
        )
    }

    func submitRename(client: OpenCodeAPIClient, submission: RenameSubmission) async throws -> OpenCodeSession {
        try await client.updateSessionTitle(
            sessionID: submission.sessionID,
            title: submission.title,
            directory: submission.directory,
            workspaceID: submission.workspaceID
        )
    }

    func forkSession(
        client: OpenCodeAPIClient,
        sessionID: String,
        messageID: String,
        directory: String?,
        workspaceID: String?
    ) async throws -> OpenCodeSession {
        try await client.forkSession(
            sessionID: sessionID,
            messageID: messageID,
            directory: directory,
            workspaceID: workspaceID
        )
    }

    func prepareForkSession(
        session: OpenCodeSession,
        messageID: String,
        selectedDirectory: String?,
        currentProjectID: String?,
        sourceMessage: OpenCodeMessageEnvelope?
    ) -> ForkPreparation {
        ForkPreparation(
            submission: ForkSubmission(
                sessionID: session.id,
                messageID: messageID,
                directory: promptDirectory(
                    for: session,
                    selectedDirectory: selectedDirectory,
                    currentProjectID: currentProjectID
                ),
                workspaceID: session.workspaceID
            ),
            restoredPrompt: sourceMessage.map(forkPromptDraft(from:))
        )
    }

    func submitFork(client: OpenCodeAPIClient, submission: ForkSubmission) async throws -> OpenCodeSession {
        try await forkSession(
            client: client,
            sessionID: submission.sessionID,
            messageID: submission.messageID,
            directory: submission.directory,
            workspaceID: submission.workspaceID
        )
    }

    func compactSession(
        client: OpenCodeAPIClient,
        sessionID: String,
        directory: String?,
        model: OpenCodeModelReference
    ) async throws {
        try await client.summarizeSession(
            sessionID: sessionID,
            directory: directory,
            model: model,
            auto: false
        )
    }

    func prepareCompactSession(
        session: OpenCodeSession,
        selectedDirectory: String?,
        currentProjectID: String?,
        model: OpenCodeModelReference
    ) -> CompactPreparation {
        CompactPreparation(
            sessionID: session.id,
            directory: promptDirectory(
                for: session,
                selectedDirectory: selectedDirectory,
                currentProjectID: currentProjectID
            ),
            model: model,
            draftCommand: "/compact"
        )
    }

    func compactStatusTransition(for preparation: CompactPreparation, previousStatus: String?) -> PromptStatusTransition {
        PromptStatusTransition(
            sessionID: preparation.sessionID,
            previousStatus: previousStatus,
            nextStatus: "busy"
        )
    }

    func compactRollback(for preparation: CompactPreparation, previousStatus: String?) -> CommandRollback {
        CommandRollback(
            sessionID: preparation.sessionID,
            draftText: preparation.draftCommand,
            attachments: [],
            previousStatus: previousStatus
        )
    }

    func submitCompact(client: OpenCodeAPIClient, preparation: CompactPreparation) async throws {
        try await compactSession(
            client: client,
            sessionID: preparation.sessionID,
            directory: preparation.directory,
            model: preparation.model
        )
    }

    func abortSession(
        client: OpenCodeAPIClient,
        sessionID: String,
        directory: String?,
        workspaceID: String?
    ) async throws {
        try await client.abortSession(sessionID: sessionID, directory: directory, workspaceID: workspaceID)
    }

    func prepareAbortSession(
        session: OpenCodeSession,
        selectedDirectory: String?,
        currentProjectID: String?
    ) -> AbortSubmission {
        AbortSubmission(
            sessionID: session.id,
            directory: promptDirectory(
                for: session,
                selectedDirectory: selectedDirectory,
                currentProjectID: currentProjectID
            ),
            workspaceID: session.workspaceID
        )
    }

    func submitAbort(client: OpenCodeAPIClient, submission: AbortSubmission) async throws {
        try await abortSession(
            client: client,
            sessionID: submission.sessionID,
            directory: submission.directory,
            workspaceID: submission.workspaceID
        )
    }

    func preparePromptSubmission(
        text: String,
        attachments: [OpenCodeComposerAttachment],
        session: OpenCodeSession,
        selectedDirectory: String?,
        currentProjectID: String?,
        messageID: String? = nil,
        partID: String? = nil,
        model: OpenCodeModelReference?,
        agent: String?,
        variant: String?
    ) -> PromptPreparation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }

        let resolvedMessageID = messageID ?? OpenCodeIdentifier.message()
        let resolvedPartID = partID ?? OpenCodeIdentifier.part()
        let requestDirectory = promptDirectory(
            for: session,
            selectedDirectory: selectedDirectory,
            currentProjectID: currentProjectID
        )
        let optimisticModel = model.map {
            OpenCodeMessageModelReference(providerID: $0.providerID, modelID: $0.modelID, variant: variant)
        }

        return PromptPreparation(
            submission: PromptSubmission(
                sessionID: session.id,
                text: trimmed,
                attachments: attachments,
                directory: requestDirectory,
                messageID: resolvedMessageID,
                partID: resolvedPartID,
                model: model,
                agent: agent,
                variant: variant
            ),
            optimisticModel: optimisticModel
        )
    }

    func promptDirectory(for session: OpenCodeSession, selectedDirectory: String?, currentProjectID: String?) -> String? {
        // Keep existing sessions bound to the directory they were created in.
        if let sessionDirectory = session.directory,
           !sessionDirectory.isEmpty {
            return sessionDirectory
        }

        if let directory = selectedDirectory, !directory.isEmpty {
            return directory
        }

        if currentProjectID == "global" {
            return nil
        }

        return session.directory
    }

    func forkPromptDraft(from message: OpenCodeMessageEnvelope) -> ForkPromptDraft {
        let text = message.parts
            .filter { $0.type == "text" }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
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
        return ForkPromptDraft(text: text, attachments: attachments)
    }

    func optimisticUserMessage(for preparation: PromptPreparation) -> OpenCodeMessageEnvelope {
        let submission = preparation.submission
        return OpenCodeMessageEnvelope.local(
            role: "user",
            text: submission.text,
            attachments: submission.attachments,
            messageID: submission.messageID,
            sessionID: submission.sessionID,
            partID: submission.partID,
            agent: submission.agent,
            model: preparation.optimisticModel
        )
    }

    func promptStart(for preparation: PromptPreparation) -> PromptStart {
        let submission = preparation.submission
        return PromptStart(
            sessionID: submission.sessionID,
            messageID: submission.messageID,
            partID: submission.partID,
            text: submission.text,
            requestDirectory: submission.directory
        )
    }

    func promptStatusTransition(for preparation: PromptPreparation, previousStatus: String?) -> PromptStatusTransition {
        PromptStatusTransition(
            sessionID: preparation.submission.sessionID,
            previousStatus: previousStatus,
            nextStatus: "busy"
        )
    }

    func prepareCommandSubmission(
        command: OpenCodeCommand,
        arguments: String,
        attachments: [OpenCodeComposerAttachment],
        session: OpenCodeSession,
        selectedDirectory: String?,
        currentProjectID: String?,
        model: OpenCodeModelReference?,
        agent: String?,
        variant: String?
    ) -> CommandPreparation {
        let trimmedArguments = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftCommand = trimmedArguments.isEmpty ? "/\(command.name)" : "/\(command.name) \(trimmedArguments)"
        let requestDirectory = promptDirectory(
            for: session,
            selectedDirectory: selectedDirectory,
            currentProjectID: currentProjectID
        )

        return CommandPreparation(
            submission: CommandSubmission(
                sessionID: session.id,
                commandName: command.name,
                arguments: trimmedArguments,
                attachments: attachments,
                directory: requestDirectory,
                model: model,
                agent: agent,
                variant: variant
            ),
            draftCommand: draftCommand
        )
    }

    func commandStatusTransition(for preparation: CommandPreparation, previousStatus: String?) -> PromptStatusTransition {
        PromptStatusTransition(
            sessionID: preparation.submission.sessionID,
            previousStatus: previousStatus,
            nextStatus: "busy"
        )
    }

    func commandRollback(for preparation: CommandPreparation, previousStatus: String?) -> CommandRollback {
        CommandRollback(
            sessionID: preparation.submission.sessionID,
            draftText: preparation.draftCommand,
            attachments: preparation.submission.attachments,
            previousStatus: previousStatus
        )
    }

    func submitCommand(client: OpenCodeAPIClient, submission: CommandSubmission) async throws {
        try await client.sendCommand(
            sessionID: submission.sessionID,
            command: submission.commandName,
            arguments: submission.arguments,
            attachments: submission.attachments,
            directory: submission.directory,
            model: submission.model,
            agent: submission.agent,
            variant: submission.variant
        )
    }

    func promptRollback(
        for preparation: PromptPreparation,
        optimisticMessage: OpenCodeMessageEnvelope,
        previousStatus: String?
    ) -> PromptRollback {
        let submission = preparation.submission
        return PromptRollback(
            sessionID: submission.sessionID,
            optimisticMessageID: optimisticMessage.id,
            messageID: submission.messageID,
            partID: submission.partID,
            draftText: submission.text,
            attachments: submission.attachments,
            previousStatus: previousStatus
        )
    }

    func promptSuccess(for preparation: PromptPreparation) -> PromptSuccess {
        let submission = preparation.submission
        return PromptSuccess(
            sessionID: submission.sessionID,
            messageID: submission.messageID,
            partID: submission.partID,
            requestDirectory: submission.directory
        )
    }

    func submitPrompt(client: OpenCodeAPIClient, submission: PromptSubmission) async throws {
        try await client.sendMessageAsync(
            sessionID: submission.sessionID,
            text: submission.text,
            attachments: submission.attachments,
            directory: submission.directory,
            messageID: submission.messageID,
            partID: submission.partID,
            model: submission.model,
            agent: submission.agent,
            variant: submission.variant
        )
    }
}
