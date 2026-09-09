import Foundation
import SwiftUI

#if canImport(FoundationModels)
import FoundationModels
#endif

private enum OpenCodeWorktreeOperationError: LocalizedError {
    case missingProject
    case primaryWorkspace
    case failed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingProject:
            return String(localized: "No git project is selected.")
        case .primaryWorkspace:
            return String(localized: "The primary workspace cannot be reset or deleted.")
        case let .failed(message):
            return message
        case .timedOut:
            return String(localized: "OpenCode is still preparing this worktree. Try again in a moment.")
        }
    }
}

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

private enum BackendPromptFailure: Error {
    case rejected, uncertain
}

private let openCodeV2SessionPageLimit = 50

extension AppViewModel {
    func beginSessionNavigation(_ session: OpenCodeSession) -> String? {
        let previousSessionID = selectedSession?.id
        sessionNavigationGeneration &+= 1
        if connectionStore.apiProfile == .v2 {
            if let previousSessionID {
                preserveCurrentMessageDraftForNavigation(forSessionID: previousSessionID)
            }
            if let directory = session.directory,
               DirectoryStoreRegistry.key(for: directory) != directoryStoreRegistry.activeKey {
                selectedDirectory = directory
                directoryStore.insertV2Session(session)
            }
            selectedProjectContentTab = .sessions
            selectedSession = session
            resetLocalCacheChatHydration(sessionID: session.id)
            chatStore.beginV2TranscriptHydration(sessionID: session.id)
            projectFilesStore.selectedVCSFile = nil
            streamDirectory = nil
            restoreMessageDraft(for: session)
            return previousSessionID
        }
        if compatibilityClient(for: .localCache) != nil, let previousSessionID,
           previousSessionID != session.id,
           let previousStore = directoryStoreRegistry.ownerStore(forSessionID: previousSessionID) {
            scheduleLocalChatCacheWrite(
                sessionID: previousSessionID,
                store: previousStore,
                includesTodos: previousStore.syncState.todosBySessionID[previousSessionID] != nil,
                immediate: true
            )
        }
        selectedProjectContentTab = .sessions
        selectedSession = session
        isLoadingSelectedSession = true
        projectFilesStore.selectedVCSFile = nil
        streamDirectory = session.directory
        return previousSessionID
    }

    func prepareSessionSelection(_ session: OpenCodeSession) {
        prepareSessionSelection(
            session,
            preservingDraftForSessionID: selectedSession?.id,
            animatesChanges: true
        )
    }

    func prepareSessionSelection(
        _ session: OpenCodeSession,
        preservingDraftForSessionID previousSessionID: String?,
        animatesChanges: Bool
    ) {
        if let previousSessionID {
            preserveCurrentMessageDraftForNavigation(forSessionID: previousSessionID)
        }
        var selectedMessages: [OpenCodeMessageEnvelope] = []
        let applyChanges = { [self] in
            selectedProjectContentTab = .sessions
            objectWillChange.send()
            let cachedMessages = directoryStore.applySessionSelection(
                session,
                cachedMessages: cachedMessagesBySessionID[session.id] ?? []
            )
            selectedMessages = cachedMessages
            chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: cachedMessages)
            sessionInteractionStore.applySelectedSession(
                sessionID: session.id,
                sessions: directoryStore.sessions,
                syncState: directoryStore.syncState
            )
            projectFilesStore.selectedVCSFile = nil
        }
        if animatesChanges {
            withAnimation(opencodeSelectionAnimation, applyChanges)
        } else {
            applyChanges()
        }
        if !selectedMessages.isEmpty {
            inferFunAndGames(from: selectedMessages, forSessionID: session.id)
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

    func reloadSessions(cursor: String? = nil) async throws {
        if connectionStore.apiProfile == .v2 {
            try await reloadV2Sessions(replacing: true)
            return
        }
        let directory = effectiveSelectedDirectory
        let targetKey = DirectoryStoreRegistry.key(for: directory)
        let targetStore = directoryStoreRegistry.store(for: directory)
        let targetGeneration = directoryStoreRegistry.generation
        defer { targetStore.isLoadingSessions = false }
        let previousSelectedSession = targetStore.selectedSession
        let permissionRevision = targetStore.permissionRevision
        let questionRevision = targetStore.questionRevision
        let connection = try requireBackendConnection()
        let sessionRevision = targetStore.sessions
        let statusRevision = targetStore.statusRevision
        let page = try await connection.sessions.sessions(scope: .init(projectID: currentProject?.id, directory: directory),
            cursor: cursor, limit: targetStore.sessionLimit, roots: true)
        var loadedSessions = cursor == nil ? page.sessions : targetStore.sessions + page.sessions
        var commands: [OpenCodeCommand] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []
        var statuses = targetStore.sessionStatuses
        if let compatibility = try? connection.requireOpenCodeClient(for: .interactions) {
            async let loadedPermissions = compatibility.listPermissions(directory: directory)
            async let loadedQuestions = compatibility.listQuestions(directory: directory)
            async let loadedStatuses = compatibility.listSessionStatuses(directory: directory)
            (permissions, questions, statuses) = try await (loadedPermissions, loadedQuestions, loadedStatuses)
            var knownIDs = Set(loadedSessions.map(\.id))
            var missingIDs = Set(permissions.map(\.sessionID) + questions.map(\.sessionID)).subtracting(knownIDs)
            while !missingIDs.isEmpty {
                var parentIDs = Set<String>()
                for id in missingIDs {
                    if let session = try? await connection.sessions.session(id: id, scope: .init(directory: directory)) {
                        loadedSessions.append(session)
                        knownIDs.insert(session.id)
                        if let parentID = session.parentID { parentIDs.insert(parentID) }
                    }
                }
                missingIDs = parentIDs.subtracting(knownIDs)
            }
        }
        if let compatibility = try? connection.requireOpenCodeClient(for: .commands) {
            commands = try await compatibility.listCommands(directory: directory)
        }
        guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
              directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
        if targetStore.sessions != sessionRevision {
            // Reconcile unchanged rows from the page without undoing live creates/renames/deletes.
            let previousByID = Dictionary(sessionRevision.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let currentByID = Dictionary(targetStore.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            loadedSessions = loadedSessions.filter { currentByID[$0.id] == previousByID[$0.id] }
                + targetStore.sessions.filter { previousByID[$0.id] != $0 }
        }
        let bootstrap = OpenCodeDirectoryBootstrap(sessions: loadedSessions,
            sessionTotal: page.nextCursor != nil || page.sessions.count >= targetStore.sessionLimit ? page.sessions.count + 1 : page.sessions.count,
            sessionLimit: targetStore.sessionLimit, commands: commands, permissions: permissions, questions: questions)
        let scopedSessions = sessionListStore.applyDirectoryReloadSessions(bootstrap.sessions, scopedTo: directory)
        targetStore.applyDirectoryReload(
            bootstrap: bootstrap,
            statuses: targetStore.statusRevision == statusRevision ? statuses : targetStore.sessionStatuses,
            scopedSessions: scopedSessions,
            permissionRevisionAtRequestStart: permissionRevision,
            questionRevisionAtRequestStart: questionRevision
        )
        if page.nextCursor != nil || cursor != nil {
            // This store method only applies page/cursor state; no v2 event semantics are involved.
            targetStore.applyV2SessionPage(.init(sessions: scopedSessions, nextCursor: page.nextCursor),
                replacing: true, requestedCursor: cursor, limit: targetStore.sessionLimit)
        }
        if (try? connection.requireOpenCodeClient(for: .localCache)) != nil {
            persistDirectoryToLocalCache(targetStore, directory: directory)
        }
        guard directoryStoreRegistry.activeStore === targetStore else { return }
        objectWillChange.send()
        let selection = sessionCoordinator.selectionAfterDirectoryReload(
            previousSelectedSession: previousSelectedSession,
            currentSelectedSessionID: selectedSession?.id,
            sessions: allSessions,
            currentStreamDirectory: streamDirectory,
            isProjectWorkspacesEnabled: isProjectWorkspacesEnabled,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            workspaceDirectories: workspaceDirectories(),
            preserveMissingSelectedSession: previousSelectedSession?.id == pendingRecentSessionOpenID,
            fallbackSession: { [weak self] sessionID in self?.session(matching: sessionID) }
        )

        if selection.selectedSession != nil {
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                directoryStore.applySelectedSessionAfterReload(selection.selectedSession)
            }
            streamDirectory = selection.streamDirectory
        } else {
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                directoryStore.applySelectedSessionAfterReload(selection.selectedSession)
                if selection.shouldClearActiveChat {
                    chatStore.clearActiveTranscript()
                    sessionInteractionStore.replaceTodos([])
                }
            }
            streamDirectory = selection.streamDirectory
        }

        if let selectedSessionID = directoryStore.selectedSession?.id {
            sessionInteractionStore.applySelectedSession(
                sessionID: selectedSessionID,
                sessions: directoryStore.sessions,
                syncState: directoryStore.syncState
            )
        }

        if selection.preservedWorkspaceSelection, let previousSelectedSession {
            appendDebugLog("preserve workspace selection after root reload session=\(debugSessionLabel(previousSelectedSession))")
        }
        if streamDirectory == nil {
            streamDirectory = allSessions.first?.directory
        }

        if hasGitProject, selectedProjectContentTab == .git {
            await projectFilesFacade.reloadGitViewData(force: true)
        }

        publishWidgetSnapshots()
        await loadWorkspaceSessionsIfNeeded()
    }

    func reloadV2Sessions(
        replacing: Bool,
        cursor: String? = nil
    ) async throws {
        guard connectionStore.apiProfile == .v2, let projectID = currentProject?.id else { return }
        let connection = try requireBackendConnection()
        let client = try connection.requireOpenCodeClient(for: .interactions)
        let directory = projectID == "global" ? nil : effectiveSelectedDirectory
        let targetKey = DirectoryStoreRegistry.key(for: directory)
        let targetStore = directoryStoreRegistry.store(for: directory)
        let targetGeneration = directoryStoreRegistry.generation
        if replacing, cursor == nil, targetStore.sessions.isEmpty {
            _ = await hydrateDirectoryFromLocalCache(directory)
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
        }
        let sessionRevision = targetStore.v2SessionRevision
        let statusRevision = targetStore.statusRevision
        targetStore.isLoadingSessions = true
        defer { targetStore.isLoadingSessions = false }

        async let activeStatuses = client.listV2SessionStatuses()
        let page = try await connection.sessions.sessions(scope: .init(projectID: projectID, directory: directory),
            cursor: cursor, limit: openCodeV2SessionPageLimit, roots: true)
        let statuses = try await activeStatuses
        guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, config == client.config,
              directoryStoreRegistry.generation == targetGeneration,
              directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
        guard targetStore.v2SessionRevision == sessionRevision else {
            targetStore.applyV2ActiveStatuses(statuses, requestedAtRevision: statusRevision)
            directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
            scheduleV2TimelineReconciliation()
            return
        }

        targetStore.applyV2SessionPage(
            OpenCodeV2SessionPage(sessions: page.sessions, nextCursor: page.nextCursor),
            replacing: replacing,
            requestedCursor: cursor,
            limit: openCodeV2SessionPageLimit
        )
        targetStore.applyV2ActiveStatuses(statuses, requestedAtRevision: statusRevision)
        persistDirectoryToLocalCache(targetStore, directory: directory)
        scheduleWidgetSnapshotPublication()
        if let selectedSessionID = targetStore.selectedSession?.id {
            // A cursor page is not evidence that the selected session was deleted.
            if let refreshed = targetStore.sessions.first(where: { $0.id == selectedSessionID }) {
                targetStore.selectedSession = refreshed
            }
        }
        objectWillChange.send()
    }

    func hydrateV2Transcript(
        for session: OpenCodeSession,
        navigationGeneration: UInt,
        expectedDirectoryKey: String
    ) async -> Bool {
        guard connectionStore.apiProfile == .v2 else { return false }
        guard let connection = try? requireBackendConnection() else { return false }
        let owner = directoryStore
        let generation = directoryStoreRegistry.generation
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let presentationRequest = chatDetailPresentationRequest
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && connectionStore.apiProfile == .v2
                && directoryStoreRegistry.generation == generation
                && directoryStoreRegistry.contains(owner, forKey: expectedDirectoryKey)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision
                && isSessionNavigationCurrent(sessionID: session.id, generation: navigationGeneration, directoryKey: expectedDirectoryKey)
        }
        guard isCurrent() else { return false }
        if chatStore.preparedSessionID != session.id, chatStore.messages.isEmpty {
            _ = await hydrateChatFromLocalCache(session, navigationGeneration: navigationGeneration,
                expectedDirectoryKey: expectedDirectoryKey)
            guard isCurrent() else { return false }
        }
        if chatStore.preparedSessionID == session.id, !chatStore.isHydratingV2Transcript(sessionID: session.id) {
            requestChatDetailPresentation(sessionID: session.id, navigationGeneration: navigationGeneration,
                directoryKey: expectedDirectoryKey, previousRequest: presentationRequest)
            return true
        }
        let requestID = chatStore.beginV2CanonicalRead(sessionID: session.id)
        var applied = false
        var needsRetry = false
        defer {
            finishV2CanonicalRead(requestID, sessionID: session.id, applied: applied,
                needsRetry: needsRetry, isCurrent: isCurrent())
        }
        do {
            for _ in 0 ..< 3 {
                guard isCurrent() else { return false }
                guard chatStore.isCurrentV2CanonicalRead(requestID, sessionID: session.id) else {
                    return chatStore.preparedSessionID == session.id && !chatStore.isHydratingV2Transcript(sessionID: session.id)
                }
                let revision = chatStore.v2StreamRevision(sessionID: session.id)
                let page = try await connection.chat.transcript(sessionID: session.id,
                    scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID), cursor: nil, limit: 200)
                guard isCurrent() else { return false }
                guard chatStore.isCurrentV2CanonicalRead(requestID, sessionID: session.id) else {
                    return chatStore.preparedSessionID == session.id && !chatStore.isHydratingV2Transcript(sessionID: session.id)
                }
                guard chatStore.applyInitialV2Transcript(page.messages, olderCursor: page.olderCursor,
                    sessionID: session.id, expectedStreamRevision: revision) else { continue }
                applied = true
                for message in page.messages { confirmCanonicalPromptAdmission(message.info, connectionID: connection.id) }
                persistLoadedMessagesToLocalCache(page.messages, sessionID: session.id,
                    coverage: .newestPage(hasOlder: page.olderCursor != nil))
                owner.applyV2Messages(chatStore.cachedMessagesBySessionID[session.id] ?? page.messages, forSessionID: session.id)
                finishTranscriptCommit(in: owner, sessionID: session.id, completeInventory: page.messages)
                inferFunAndGames(from: owner.syncState.messageEnvelopes(forSessionID: session.id), forSessionID: session.id)
                liveActivityFacade.reducerDidCommit(sessionIDs: [session.id])
                refreshSessionPreview(for: session.id, messages: owner.syncState.messageEnvelopes(forSessionID: session.id))
                connectionStore.clearTranscriptError(connectionID: connection.id, sessionID: session.id)
                requestChatDetailPresentation(sessionID: session.id, navigationGeneration: navigationGeneration,
                    directoryKey: expectedDirectoryKey, previousRequest: presentationRequest)
                return true
            }
            needsRetry = true
            return false
        } catch {
            guard isCurrent() else { return false }
            guard chatStore.isCurrentV2CanonicalRead(requestID, sessionID: session.id) else {
                return chatStore.preparedSessionID == session.id && !chatStore.isHydratingV2Transcript(sessionID: session.id)
            }
            if chatStore.preparedSessionID == session.id {
                requestChatDetailPresentation(sessionID: session.id, navigationGeneration: navigationGeneration,
                    directoryKey: expectedDirectoryKey, previousRequest: presentationRequest)
                return true
            }
            connectionStore.applyTranscriptError(error, connectionID: connection.id, sessionID: session.id)
            return false
        }
    }

    private func requestChatDetailPresentation(
        sessionID: String, navigationGeneration: UInt, directoryKey: String, previousRequest: Int
    ) {
        guard chatDetailPresentationRequest == previousRequest,
              !hasHydratedLocalChat(sessionID: sessionID),
              chatStore.preparedSessionID == sessionID,
              !chatStore.isHydratingV2Transcript(sessionID: sessionID),
              isSessionNavigationCurrent(sessionID: sessionID, generation: navigationGeneration, directoryKey: directoryKey) else { return }
        if let session = selectedSession { applyV2SessionConfiguration(session) }
        chatDetailPresentationRequest &+= 1
    }

    func hydrateV2Interactions(for session: OpenCodeSession) async {
        guard connectionStore.apiProfile == .v2 else { return }
        guard let connection = try? requireBackendConnection(),
              let client = try? connection.requireOpenCodeClient(for: .interactions) else { return }
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        guard let key = directoryStoreRegistry.key(for: owner) else { return }
        let targetGeneration = directoryStoreRegistry.generation
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let permissionRevision = owner.permissionRevision
        let questionRevision = owner.questionRevision
        let navigationGeneration = sessionNavigationGeneration
        do {
            async let permissions = client.listV2SessionPermissions(sessionID: session.id)
            async let forms = client.listV2SessionForms(sessionID: session.id)
            let (loadedPermissions, loadedForms) = try await (permissions, forms)
            guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, config == client.config,
                  directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.contains(owner, forKey: key),
                  directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision else { return }
            owner.applyV2SessionInteractions(sessionID: session.id, permissions: loadedPermissions, forms: loadedForms,
                permissionRevisionAtRequestStart: permissionRevision, questionRevisionAtRequestStart: questionRevision)
            liveActivityFacade.reducerDidCommit(sessionIDs: [session.id])
            if directoryStore === owner, isSessionNavigationCurrent(sessionID: session.id, generation: navigationGeneration, directoryKey: key) {
                sessionInteractionStore.applySelectedSession(
                    sessionID: session.id,
                    sessions: owner.sessions,
                    syncState: owner.syncState
                )
            }
        } catch {
            appendDebugLog("v2 interaction hydration failed: \(error.localizedDescription)")
        }
    }

    func loadOlderV2Messages(sessionID: String, windowContext: ChatWindowContext? = nil) async -> Bool {
        guard connectionStore.apiProfile == .v2,
               (windowContext?.isCurrent ?? true),
               (windowContext?.session.id ?? selectedSession?.id) == sessionID,
              let cursor = chatStore.beginLoadingOlderV2Messages(sessionID: sessionID) else { return false }
        guard let connection = try? requireBackendConnection() else { return false }
        let owner = windowContext?.owner ?? directoryStore
        guard let key = directoryStoreRegistry.key(for: owner) else { return false }
        let navigationGeneration = sessionNavigationGeneration
        let targetGeneration = directoryStoreRegistry.generation
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        let revision = chatStore.v2StreamRevision(sessionID: sessionID)
        let canonicalReadID = chatStore.v2CanonicalReadID(sessionID: sessionID)
        let messagesBeforeRequest = chatStore.cachedMessagesBySessionID[sessionID]
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && connectionStore.apiProfile == .v2 && directoryStoreRegistry.generation == targetGeneration
                && directoryStoreRegistry.contains(owner, forKey: key)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision
                && (windowContext?.isCurrent ?? isSessionNavigationCurrent(sessionID: sessionID, generation: navigationGeneration, directoryKey: key))
        }
        defer {
            if backendConnection?.id == connection.id, !connection.isClosed, directoryStoreRegistry.generation == targetGeneration,
               (windowContext != nil || sessionNavigationGeneration == navigationGeneration), chatStore.isLoadingOlderV2Messages(sessionID: sessionID) {
                chatStore.failLoadingOlderV2Messages(sessionID: sessionID)
            }
        }
        do {
            let session = owner.sessions.first { $0.id == sessionID }
            let page = try await connection.chat.transcript(sessionID: sessionID,
                scope: .init(projectID: session?.projectID, directory: session?.directory ?? DirectoryStoreRegistry.directory(forKey: key), workspaceID: session?.workspaceID), cursor: cursor, limit: 200)
            guard !Task.isCancelled, isCurrent(),
                     (windowContext != nil || chatStore.preparedSessionID == sessionID) else { return false }
            guard chatStore.v2StreamRevision(sessionID: sessionID) == revision else {
                directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
                scheduleV2TimelineReconciliation()
                return false
            }
            // History must not reintroduce stale records over a newer canonical HTTP snapshot.
            guard chatStore.v2CanonicalReadID(sessionID: sessionID) == canonicalReadID,
                  chatStore.cachedMessagesBySessionID[sessionID] == messagesBeforeRequest else { return false }
            chatStore.applyOlderV2Transcript(
                page.messages,
                olderCursor: page.olderCursor,
                requestedCursor: cursor,
                sessionID: sessionID
            )
            for message in page.messages { confirmCanonicalPromptAdmission(message.info, connectionID: connection.id) }
            if let firstLoadedID = messagesBeforeRequest?.first?.id {
                persistLoadedMessagesToLocalCache(page.messages, sessionID: sessionID,
                    coverage: .olderPage(beforeMessageID: firstLoadedID))
            }
            owner.applyV2Messages(chatStore.cachedMessagesBySessionID[sessionID] ?? [], forSessionID: sessionID)
            finishTranscriptCommit(in: owner, sessionID: sessionID, completeInventory: page.messages)
            inferFunAndGames(from: owner.syncState.messageEnvelopes(forSessionID: sessionID), forSessionID: sessionID)
            liveActivityFacade.reducerDidCommit(sessionIDs: [sessionID])
            refreshSessionPreview(for: sessionID, messages: owner.syncState.messageEnvelopes(forSessionID: sessionID))
            connectionStore.clearTranscriptError(connectionID: connection.id, sessionID: sessionID)
            return true
        } catch {
            guard !Task.isCancelled, isCurrent() else { return false }
            chatStore.failLoadingOlderV2Messages(sessionID: sessionID)
            connectionStore.applyTranscriptError(error, connectionID: connection.id, sessionID: sessionID)
            return false
        }
    }

    func sendV2TextPrompt(
        _ text: String, in session: OpenCodeSession,
        attachments: [OpenCodeComposerAttachment] = [],
        agentMentions: [OpenCodeAgentMention] = [],
        meterPrompt: Bool = true,
        messageID requestedMessageID: String? = nil,
        reservedPromptDay: String? = nil,
        windowContext: ChatWindowContext? = nil
    ) async -> Bool {
        guard !Task.isCancelled, connectionStore.apiProfile == .v2,
              windowContext?.isCurrent ?? true,
              !funAndGamesStore.hasPendingSetup(for: session.id),
              !directoryStoreRegistry.isV2SessionDeleted(session.id) else { return false }
        if let requestedMessageID, let phase = chatFacade.promptAdmissionPhase(messageID: requestedMessageID, sessionID: session.id) {
            return phase == .admitted
        }
        guard !chatFacade.hasPendingPromptAdmission(sessionID: session.id) else { return false }
        if let directory = session.directory,
           !globalFormsFacade.pending(for: .init(directory: directory, workspaceID: session.workspaceID)).isEmpty {
            // This attempt has no admission owner and has not posted. Release only its prepaid day.
            chatFacade.refundReservedPrompt(on: reservedPromptDay)
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        let prompt = agentMentions.isEmpty ? trimmed : text
        guard let connection = try? requireBackendConnection(),
              let client = try? connection.requireOpenCodeClient(for: .interactions) else { return false }
        let generation = directoryStoreRegistry.generation
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        guard let key = directoryStoreRegistry.key(for: owner) else { return false }
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let navigationGeneration = sessionNavigationGeneration
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && connectionStore.apiProfile == .v2 && config == client.config && directoryStoreRegistry.generation == generation
                && (windowContext?.isCurrent ?? true)
                && directoryStoreRegistry.contains(owner, forKey: key)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision
        }
        let isVisible = { [self] in
            windowContext == nil && isCurrent() && isSessionNavigationCurrent(sessionID: session.id, generation: navigationGeneration, directoryKey: key)
        }
        await maybeAutoStartLiveActivity(for: session)
        guard isCurrent(), !funAndGamesStore.hasPendingSetup(for: session.id) else { return false }
        let charged = reservedPromptDay != nil || (meterPrompt && !hasProUnlock)
        guard reservedPromptDay != nil || !meterPrompt || reserveUserPromptIfAllowed() else { return false }
        let chargedDay = reservedPromptDay ?? usageMeter.promptDay
        let refund = { [self] in
            if charged, usageMeter.promptDay == chargedDay,
               chargedDay == OpenClientUsageMeter.dayString(for: Date()) {
                refundReservedUserPromptIfNeeded()
            }
        }

        let messageID = requestedMessageID ?? OpenCodeIdentifier.message()
        let optimistic = OpenCodeMessageEnvelope.local(
            role: "user",
            text: prompt,
            agentMentions: agentMentions,
            attachments: attachments,
            messageID: messageID,
            sessionID: session.id,
            partID: "\(messageID):v2:text:0"
        )
        if requestedMessageID != nil {
            // Generic composer callers may already have inserted this same optimistic ID.
            chatStore.rollbackV2Prompt(messageID: messageID, sessionID: session.id)
            _ = owner.removeMessage(sessionID: session.id, messageID: messageID)
        }
        guard chatStore.beginV2Prompt(optimistic, sessionID: session.id, attachments: attachments, agentMentions: agentMentions) else {
            refund()
            return false
        }
        owner.applyV2Messages(chatStore.withoutRecoveryMessages(owner.syncState.messageEnvelopes(forSessionID: session.id),
            sessionID: session.id), forSessionID: session.id)
        defer {
            if backendConnection?.id == connection.id, !connection.isClosed, connectionStore.apiProfile == .v2,
               config == client.config, directoryStoreRegistry.generation == generation {
                // Only this request can become uncertain; a newer request may already be submitting.
                chatStore.markSubmissionUncertain(messageID: messageID, sessionID: session.id)
            }
        }

        do {
            let admission = try await connection.chat.submit(.init(sessionID: session.id, messageID: messageID, text: prompt,
                scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID),
                attachments: attachments, agentMentions: agentMentions))
            switch admission {
            case let .accepted(sessionID, admittedID) where sessionID == session.id && admittedID == messageID:
                break
            case let .rejected(sessionID, rejectedID) where sessionID == session.id && rejectedID == messageID:
                throw BackendPromptFailure.rejected
            default:
                throw BackendPromptFailure.uncertain
            }
            if isCurrent() { chatStore.confirmSubmissionAdmission(messageID: messageID, sessionID: session.id) }
        } catch BackendPromptFailure.rejected {
            let hasCanonicalInput = chatStore.canonicalSubmissionSessions[messageID] == session.id
            if isCurrent(), chatStore.submissionRecoveries[messageID]?.phase == .admitted
                || chatStore.submissionRecoveries[messageID]?.phase == .cancelled || hasCanonicalInput {
                // An exact-ID admission event is stronger evidence than a conflicting HTTP error.
                return true
            }
            if isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, config == client.config, directoryStoreRegistry.generation == generation {
                // Rename/move/navigation must not strand a definitively rejected optimistic row.
                chatStore.rollbackV2Prompt(messageID: messageID, sessionID: session.id)
                for store in directoryStoreRegistry.stores(containingSessionID: session.id) {
                    _ = store.removeMessage(sessionID: session.id, messageID: messageID)
                }
            }
            refund()
            if isVisible() { errorMessage = String(localized: "OpenCode rejected the prompt.") }
            return false
        } catch {
            // Never retry POST with a fresh ID. A lost receipt can still mean admitted work.
            guard isCurrent(), !Task.isCancelled else { return false }
            chatStore.markSubmissionUncertain(messageID: messageID, sessionID: session.id)
            if !(await resolveV2PromptAdmission(sessionID: session.id, messageID: messageID)) {
                if isCurrent() {
                    directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
                    scheduleV2TimelineReconciliation()
                }
                // Preserve the draft and identity-specific lock, not a permanent session lock.
                return false
            }
        }

        guard isCurrent() else { return true }
        connectionStore.clearPromptError(connectionID: connection.id, sessionID: session.id, messageID: messageID)
        // Admission releases the composer/new-chat sheet; completion is a separate read.
        Task { @MainActor in
            guard isCurrent() else { return }
            do {
                try await client.waitForV2Session(sessionID: session.id)
                guard isCurrent(), !Task.isCancelled else { return }
                await reconcileV2TimelineFromEvent(sessionID: session.id)
            } catch {
                guard isCurrent(), !Task.isCancelled else { return }
                directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
                scheduleV2TimelineReconciliation()
                if isVisible() {
                    connectionStore.applyPromptError(String(localized: "Prompt was admitted, but the timeline could not be reconciled yet."),
                        connectionID: connection.id, sessionID: session.id, messageID: messageID)
                }
            }
        }
        return true
    }

    func resolveV2PromptAdmission(sessionID: String, messageID: String, checkPendingStatus: Bool = false) async -> Bool {
        guard connectionStore.apiProfile == .v2 else { return false }
        if !checkPendingStatus, chatFacade.isPromptAdmitted(messageID: messageID, sessionID: sessionID) { return true }
        guard let connection = try? requireBackendConnection(),
              let client = connection.openCodeCompatibility?.client else { return false }
        let generation = directoryStoreRegistry.generation
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        let endpoint: OpenCodeV2PendingInputEndpoint = serverVersion.hasSuffix("next-17155") ? .pending : .inbox
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && connectionStore.apiProfile == .v2 && config == client.config
                && directoryStoreRegistry.generation == generation
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision
        }
        do {
            let message = try await client.getV2Message(sessionID: sessionID, messageID: messageID)
            guard isCurrent() else { return false }
            if message.id == messageID, message.info.sessionID == sessionID, message.info.role == "user" {
                // Keep recovery until a full page establishes its canonical position.
                chatStore.confirmPromptAdmission(from: message.info, connectionID: connection.id)
                chatStore.confirmSubmissionAdmission(messageID: messageID, sessionID: sessionID)
                connectionStore.clearPromptError(connectionID: connection.id, sessionID: sessionID, messageID: messageID)
                return true
            }
        } catch {
            guard isCurrent() else { return false }
        }
        do {
            let ids = try await client.listV2PendingInputIDs(sessionID: sessionID, endpoint: endpoint)
            guard isCurrent() else { return false }
            chatStore.applyV2InboxAdmissionIDs(ids, sessionID: sessionID)
            if ids.contains(messageID) {
                chatStore.applyPromptAdmission(.admitted, messageID: messageID, connectionID: connection.id)
                connectionStore.clearPromptError(connectionID: connection.id, sessionID: sessionID, messageID: messageID)
                return true
            }
            if checkPendingStatus { chatStore.markSubmissionStatusUnknown(messageID: messageID, sessionID: sessionID) }
        } catch {
            guard isCurrent() else { return false }
            if checkPendingStatus { chatStore.markSubmissionStatusUnknown(messageID: messageID, sessionID: sessionID) }
        }
        // A live event or another canonical read can resolve the ID during either GET.
        return chatFacade.isPromptAdmitted(messageID: messageID, sessionID: sessionID)
    }

    static func isDefinitiveV2PromptRejection(_ statusCode: Int) -> Bool {
        // Timeout/conflict may be generated after admission, including duplicate-ID conflicts.
        (400 ..< 500).contains(statusCode) && statusCode != 408 && statusCode != 409
    }

    func reconcileV2TimelineFromEvent(sessionID: String, presentationIndependent: Bool = false) async {
        guard connectionStore.apiProfile == .v2 else { return }
        guard let connection = try? requireBackendConnection() else { return }
        guard let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID),
              let key = directoryStoreRegistry.key(for: owner) else { return }
        let targetGeneration = directoryStoreRegistry.generation
        let streamRevision = chatStore.v2StreamRevision(sessionID: sessionID)
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        let navigationGeneration = sessionNavigationGeneration
        let wasSelected = selectedSession?.id == sessionID
        let wasHydrating = chatStore.isHydratingV2Transcript(sessionID: sessionID)
            || (wasSelected && chatStore.preparedSessionID != sessionID)
        let presentationRequest = chatDetailPresentationRequest
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && connectionStore.apiProfile == .v2
                && directoryStoreRegistry.generation == targetGeneration
                && directoryStoreRegistry.contains(owner, forKey: key)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision
                && (presentationIndependent || !(wasSelected || selectedSession?.id == sessionID)
                    || isSessionNavigationCurrent(sessionID: sessionID, generation: navigationGeneration, directoryKey: key))
        }

        guard isCurrent() else { return }
        if wasSelected, chatStore.preparedSessionID != sessionID, !chatStore.isHydratingV2Transcript(sessionID: sessionID) {
            let cachedPresentation = hasPresentableCachedV2Chat ? chatStore.messages : []
            chatStore.beginV2TranscriptHydration(sessionID: sessionID, preservingCanonicalRead: true)
            if !cachedPresentation.isEmpty { chatStore.messages = cachedPresentation }
        }
        let requestID = chatStore.beginV2CanonicalRead(sessionID: sessionID)
        var applied = false
        var needsRetry = false
        defer {
            finishV2CanonicalRead(requestID, sessionID: sessionID, applied: applied,
                needsRetry: needsRetry, isCurrent: isCurrent())
        }
        do {
            let unresolvedIDs = chatStore.submissionRecoveries.filter {
                $0.value.sessionID == sessionID && $0.value.phase == .uncertain
            }.keys.sorted()
            for messageID in unresolvedIDs {
                _ = await resolveV2PromptAdmission(sessionID: sessionID, messageID: messageID)
                guard isCurrent(), chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID) else { return }
            }
            let oldestLoadedID = chatStore.cachedMessagesBySessionID[sessionID]?.first?.id
            let canonicalSession = owner.sessions.first { $0.id == sessionID }
            let scope = BackendScope(projectID: canonicalSession?.projectID,
                directory: canonicalSession?.directory ?? DirectoryStoreRegistry.directory(forKey: key),
                workspaceID: canonicalSession?.workspaceID)
            var page = try await connection.chat.transcript(sessionID: sessionID, scope: scope, cursor: nil, limit: 200)
            guard isCurrent(), chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID) else { return }
            var projected = page.messages
            var seenCursors = Set<String>()
            // Bridge missed pages and replace the entire loaded range, including reverted records.
            while let oldestLoadedID, !projected.contains(where: { $0.id == oldestLoadedID }),
                  let cursor = page.olderCursor {
                guard isCurrent() else { return }
                guard seenCursors.insert(cursor).inserted else { throw OpenCodeV2TransportError.invalidTimelineRecord }
                page = try await connection.chat.transcript(sessionID: sessionID, scope: scope, cursor: cursor, limit: 200)
                guard isCurrent(), chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID) else { return }
                projected = page.messages + projected
            }
            guard isCurrent(), chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID) else { return }
            guard chatStore.v2StreamRevision(sessionID: sessionID) == streamRevision else {
                needsRetry = true
                return
            }
            chatStore.applyV2EventProjection(
                projected,
                olderCursor: page.olderCursor,
                sessionID: sessionID
            )
            applied = true
            for message in projected { confirmCanonicalPromptAdmission(message.info, connectionID: connection.id) }
            persistLoadedMessagesToLocalCache(projected, sessionID: sessionID,
                coverage: .newestPage(hasOlder: page.olderCursor != nil))
            connectionStore.clearTranscriptError(connectionID: connection.id, sessionID: sessionID)
            owner.applyV2Messages(chatStore.cachedMessagesBySessionID[sessionID] ?? projected, forSessionID: sessionID)
            finishTranscriptCommit(in: owner, sessionID: sessionID, completeInventory: projected)
            inferFunAndGames(from: owner.syncState.messageEnvelopes(forSessionID: sessionID), forSessionID: sessionID)
            liveActivityFacade.reducerDidCommit(sessionIDs: [sessionID])
            refreshSessionPreview(for: sessionID, messages: owner.syncState.messageEnvelopes(forSessionID: sessionID))
            if let session = owner.sessions.first(where: { $0.id == sessionID })
                ?? (owner.selectedSession?.id == sessionID ? owner.selectedSession : nil) {
                applyV2SessionConfiguration(session)
            }
            if wasSelected, wasHydrating {
                requestChatDetailPresentation(sessionID: sessionID, navigationGeneration: navigationGeneration,
                    directoryKey: key, previousRequest: presentationRequest)
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(), chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID) else { return }
            appendDebugLog("v2 timeline reconciliation failed: \(error.localizedDescription)")
        }
    }

    private func finishV2CanonicalRead(_ requestID: UUID, sessionID: String, applied: Bool, needsRetry: Bool, isCurrent: Bool) {
        let ownsRequest = chatStore.isCurrentV2CanonicalRead(requestID, sessionID: sessionID)
        let retry = chatStore.finishV2CanonicalRead(requestID, sessionID: sessionID, applied: applied, needsRetry: needsRetry)
        guard isCurrent else { return }
        if ownsRequest, !applied {
            chatStore.failV2TranscriptHydration(sessionID: sessionID)
        }
        if retry {
            directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
            scheduleV2TimelineReconciliation()
        }
    }

    func interruptV2Session(sessionID: String) async -> Bool {
        guard connectionStore.apiProfile == .v2 else { return false }
        guard let connection = try? requireBackendConnection() else { return false }
        let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) ?? directoryStore
        let generation = directoryStoreRegistry.generation
        let revision = owner.statusRevision
        let navigationGeneration = sessionNavigationGeneration
        do {
            try await connection.chat.interrupt(sessionID: sessionID,
                scope: .init(directory: directoryStoreRegistry.key(for: owner).flatMap(DirectoryStoreRegistry.directory(forKey:))))
            guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, directoryStoreRegistry.generation == generation,
                  directoryStoreRegistry.key(for: owner) != nil else { return true }
            if owner.statusRevision == revision { owner.applySessionStatus("idle", forSessionID: sessionID) }
            directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
            scheduleV2TimelineReconciliation(immediate: true)
            if selectedSession?.id == sessionID, sessionNavigationGeneration == navigationGeneration { errorMessage = nil }
            return true
        } catch {
            if isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation, selectedSession?.id == sessionID,
               sessionNavigationGeneration == navigationGeneration { errorMessage = error.localizedDescription }
            return false
        }
    }

    func refreshSessionList() async {
        guard !isBrowsingLocalCache else { return }
        let generation = directoryStoreRegistry.generation
        let owner = directoryStore
        do {
            try await reloadSessions()
            guard directoryStoreRegistry.generation == generation, directoryStore === owner else { return }
            errorMessage = nil
        } catch {
            guard directoryStoreRegistry.generation == generation, directoryStore === owner else { return }
            isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    func loadMoreSessions() async {
        guard !isBrowsingLocalCache, directoryStore.hasMoreSessions, !isLoadingSessions else { return }
        if connectionStore.apiProfile == .v2 {
            guard let cursor = directoryStore.nextSessionCursor else { return }
            let generation = directoryStoreRegistry.generation
            let owner = directoryStore
            do {
                try await reloadV2Sessions(replacing: false, cursor: cursor)
                guard directoryStoreRegistry.generation == generation, directoryStore === owner else { return }
                errorMessage = nil
            } catch {
                guard directoryStoreRegistry.generation == generation, directoryStore === owner else { return }
                isLoadingSessions = false
                errorMessage = error.localizedDescription
            }
            return
        }
        let targetStore = directoryStore
        if let cursor = targetStore.nextSessionCursor {
            targetStore.isLoadingSessions = true
            do { try await reloadSessions(cursor: cursor) }
            catch { if directoryStore === targetStore { errorMessage = error.localizedDescription } }
            return
        }
        let previousLimit = targetStore.sessionLimit
        targetStore.sessionLimit += 100
        targetStore.isLoadingSessions = true
        do {
            try await reloadSessions()
            errorMessage = nil
        } catch {
            targetStore.sessionLimit = previousLimit
            targetStore.isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    func loadWorkspaceSessionsIfNeeded() async {
        guard let project = currentProject, isProjectWorkspacesEnabled(for: project) else { return }
        await loadWorkspaceSessions()
    }

    func loadWorkspaceSessions() async {
        guard let connection = backendConnection, connection.worktrees != nil,
              let project = currentProject else { return }
        await refreshCurrentProjectWorktreesIfNeeded()
        guard isCurrentBackendConnection(connection), currentProject?.id == project.id else { return }
        let directories = workspaceDirectories()
        for directory in directories {
            guard isCurrentBackendConnection(connection), currentProject?.id == project.id else { return }
            guard let key = workspacePageKey(directory: directory),
                  sessionListStore.workspacePages[key]?.hasLoaded != true else { continue }
            await loadWorkspaceSessionPage(directory: directory)
        }
    }

    func loadMoreWorkspaceSessions(directory: String) async {
        await loadWorkspaceSessionPage(directory: directory, loadNext: true)
    }

    func refreshWorkspaceSessions(directory: String) async {
        await loadWorkspaceSessionPage(directory: directory, replacing: true)
    }

    @discardableResult
    func createWorkspace(name: String, destinationParent: String? = nil) async -> Bool {
        guard let connection = backendConnection, connection.worktrees != nil else { return false }
        do {
            _ = try await createManagedWorktree(name: name, destinationParent: destinationParent)
            guard isCurrentBackendConnection(connection) else { return false }
            errorMessage = nil
            return true
        } catch {
            guard isCurrentBackendConnection(connection) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func presentNewSession(inWorkspace directory: String) {
        presentNewProjectChatSheet(
            projectID: currentProject?.id,
            workspaceDirectory: directory,
            locksProject: true
        )
    }

    @discardableResult
    func deleteWorktree(directory: String, force: Bool = false) async -> BackendWorktreeRemovalOutcome {
        guard let connection = backendConnection, let service = connection.worktrees,
              let key = workspacePageKey(directory: directory),
              sessionListStore.workspaceOperation(for: directory)?.isBusy != true else { return .failed }
        do {
            let project = try projectForManagedWorktree(directory)
            objectWillChange.send()
            sessionListStore.setWorkspaceOperation(.deleting, for: directory)
            try await service.remove(scope: .init(projectID: project.id, directory: project.worktree), directory: directory, force: force)
            guard isCurrentBackendConnection(connection) else { return .failed }
            let entries = projectStore.worktreeInventories[key.inventory] ?? []
            projectStore.setWorktreeInventory(entries.filter { $0.directory != directory }, for: key.inventory)
            sessionListStore.removeWorkspacePage(key)
            // Removing a checkout does not delete or archive its canonical server sessions.
            if currentProject?.id == project.id {
                removeSandboxDirectory(directory, from: project)
                await clearSelectionIfNeeded(afterRemovingWorkspace: directory, fallbackDirectory: project.worktree)
            }
            errorMessage = nil
            return .removed
        } catch {
            guard isCurrentBackendConnection(connection) else { return .failed }
            objectWillChange.send()
            sessionListStore.setWorkspaceOperation(.failed(error.localizedDescription), for: directory)
            errorMessage = error.localizedDescription
            if case let BackendWorktreeError.forceRequired(message) = error { return .requiresForce(message) }
            return .failed
        }
    }

    func resetWorktree(directory: String) async {
        guard let connection = backendConnection, let service = connection.worktreeReset,
              let key = workspacePageKey(directory: directory),
              sessionListStore.workspaceOperation(for: directory)?.isBusy != true else { return }
        do {
            let project = try projectForManagedWorktree(directory)
            objectWillChange.send()
            sessionListStore.setWorkspaceOperation(.resetting, for: directory)

            let result = try await service.reset(scope: .init(projectID: project.id, directory: project.worktree), directory: directory)
            guard isCurrentBackendConnection(connection) else { return }
            sessionListStore.removeWorkspacePage(key)
            guard currentProject?.id == project.id else { return }

            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                removeLocalSessions(result.archivedSessionIDs, fromWorkspace: directory)
                sessionListStore.setWorkspaceOperation(nil, for: directory)
            }
            await refreshWorkspaceSessions(directory: directory)
            await clearSelectionIfNeeded(afterRemovingWorkspace: directory, fallbackDirectory: project.worktree)
            errorMessage = nil
        } catch {
            guard isCurrentBackendConnection(connection) else { return }
            objectWillChange.send()
            sessionListStore.setWorkspaceOperation(.failed(error.localizedDescription), for: directory)
            errorMessage = error.localizedDescription
        }
    }

    func waitForWorktreeReadyIfNeeded(directory: String?) async throws {
        guard let directory, !directory.isEmpty else { return }
        guard let connection = backendConnection else { throw BackendError.disconnected }
        let deadline = Date().addingTimeInterval(5 * 60)

        while Date() < deadline {
            guard isCurrentBackendConnection(connection) else { throw CancellationError() }
            guard let operation = sessionListStore.workspaceOperation(for: directory) else { return }
            if case let .failed(message) = operation {
                throw OpenCodeWorktreeOperationError.failed(message)
            }
            guard operation.isBusy else { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        throw OpenCodeWorktreeOperationError.timedOut
    }

    private func loadWorkspaceSessionPage(directory: String, replacing: Bool = false, loadNext: Bool = false) async {
        guard let connection = backendConnection, connection.worktrees != nil,
              let project = currentProject, let key = workspacePageKey(directory: directory),
              workspaceDirectories().contains(directory) else { return }
        let previous = sessionListStore.workspacePages[key]
        if loadNext, previous?.state.hasMore != true { return }
        let cursor = loadNext ? previous?.nextCursor : nil
        // Legacy core pages have no cursor; retain their increasing-limit behavior at this boundary.
        let legacyPage = connection.openCodeCompatibility?.profile == .legacy
        let limit = max(5, previous?.state.limit ?? 5) + (loadNext && legacyPage ? 5 : 0)
        guard let requestID = sessionListStore.beginWorkspacePage(key, replacing: replacing) else { return }
        let generation = directoryStoreRegistry.generation
        let owner = directoryStoreRegistry.store(for: directory)
        let navigationGeneration = sessionNavigationGeneration
        let priorSessions = owner.sessions
        let lifecycle = directoryStoreRegistry.v2LifecycleSnapshot
        let isCurrent = { [self] in
            !Task.isCancelled && isCurrentBackendConnection(connection) && directoryStoreRegistry.generation == generation
                && sessionNavigationGeneration == navigationGeneration
                && currentProject?.id == project.id && workspaceDirectories().contains(directory)
        }
        defer { sessionListStore.failWorkspacePage(key, requestID: requestID, projectsToVisible: isCurrent()) }
        do {
            let page = try await connection.sessions.sessions(
                scope: .init(projectID: project.id, directory: directory, workspaceID: key.inventory.workspaceID),
                cursor: cursor, limit: limit, roots: true
            )
            guard isCurrent() else { return }
            let canonical = directoryStoreRegistry.unchangedV2Sessions(page.sessions, since: lifecycle).filter {
                $0.directory == directory && $0.workspaceID == key.inventory.workspaceID
            }
            let cached = cursor == nil ? [] : (previous?.state.sessions ?? [])
            let newer = owner.sessions.filter { session in
                session != priorSessions.first(where: { $0.id == session.id })
                    && session.directory == directory && session.workspaceID == key.inventory.workspaceID
                    && !directoryStoreRegistry.isV2SessionDeleted(session.id)
            }
            var sessions = sessionListStore.workspacePageSessions(cached, applying: canonical + newer)
            sessions.removeAll { directoryStoreRegistry.isV2SessionDeleted($0.id) }
            let nextCursor = page.nextCursor == cursor ? nil : page.nextCursor
            guard sessionListStore.finishWorkspacePage(key, requestID: requestID, sessions: sessions,
                nextCursor: nextCursor, limit: limit, hasMore: nextCursor != nil || (legacyPage && page.sessions.count >= limit)) else { return }
            if legacyPage { _ = owner.upsertSessions(sessions) }
            else { owner.applyV2DiscoveredSessions(sessions) }
        } catch {
            guard isCurrent() else { return }
            sessionListStore.failWorkspacePage(key, requestID: requestID)
            errorMessage = error.localizedDescription
        }
    }

    func reloadSessionStatuses() async throws {
        let connection = try requireBackendConnection()
        guard let client = compatibilityClient(for: .interactions) else { return }
        if connectionStore.apiProfile == .v2 {
            let generation = directoryStoreRegistry.generation
            let stores = directoryStoreRegistry.allStores.map { ($0, $0.statusRevision) }
            let statuses = try await client.listV2SessionStatuses()
            guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, config == client.config,
                  directoryStoreRegistry.generation == generation else { return }
            for (store, revision) in stores where directoryStoreRegistry.key(for: store) != nil {
                store.applyV2ActiveStatuses(statuses, requestedAtRevision: revision)
            }
            return
        }
        let directory = effectiveSelectedDirectory
        let targetKey = DirectoryStoreRegistry.key(for: directory)
        let targetStore = directoryStoreRegistry.store(for: directory)
        let targetGeneration = directoryStoreRegistry.generation
        let revision = targetStore.statusRevision
        let statuses = try await client.listSessionStatuses(directory: directory)
        guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
              targetStore.statusRevision == revision,
              directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
        let changed = targetStore.applySessionStatuses(statuses)
        if changed, directoryStoreRegistry.activeStore === targetStore {
            objectWillChange.send()
        }
    }

    func createSession() async {
        guard canCreateSessionOrPresentPaywall() else { return }

        if connectionStore.apiProfile == .v2 {
            await createV2Session()
            return
        }

        guard let connection = try? requireBackendConnection() else { return }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let key = directoryStoreRegistry.activeKey
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && directoryStoreRegistry.generation == generation
                && sessionNavigationGeneration == navigationGeneration && directoryStoreRegistry.activeKey == key
        }
        isLoading = true
        defer { if backendConnection?.id == connection.id, !connection.isClosed { isLoading = false } }

        do {
            let targetDirectory = try await resolveNewSessionDirectory()
            let createSubmission = sessionCoordinator.prepareCreateSession(title: draftTitle, directory: targetDirectory)
            guard isCurrent() else { return }
            let session = try await connection.sessions.createSession(.init(title: createSubmission.title,
                scope: currentProject.map { projectExecutionScope(for: $0, directory: createSubmission.directory) }
                    ?? .init(directory: createSubmission.directory),
                agent: newSessionDefaults.agentName, model: newSessionDefaultModelReference(), variant: newSessionDefaults.reasoningVariant))
            recordCreatedSessionForMetering()
            guard isCurrent() else { return }
            draftTitle = ""
            newWorkspaceName = ""
            newSessionWorkspaceSelection = .main
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateSessionSheet = false
            }
            upsertVisibleSession(session)
            try await reloadSessions()
            guard isCurrent() else { return }
            upsertVisibleSession(session)
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                let cachedMessages = directoryStore.applySessionSelection(
                    session,
                    cachedMessages: cachedMessagesBySessionID[session.id] ?? []
                )
                chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: cachedMessages)
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                sessionInteractionStore.replaceTodos([])
            }
            try await loadMessages(for: session)
            guard isCurrent() else { return }
            seedComposerSelectionsForNewSession(session)
            errorMessage = nil
        } catch {
            if isCurrent() { errorMessage = error.localizedDescription }
        }
    }

    private func createV2Session() async {
        guard !isLoading, let project = currentProject else { return }
        guard let connection = try? requireBackendConnection() else { return }
        let key = directoryStoreRegistry.activeKey
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let defaults = newSessionDefaults
        let title = draftTitle
        let model = defaults.providerID.flatMap { providerID in
            defaults.modelID.map { OpenCodeModelReference(providerID: providerID, modelID: $0) }
        }
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection)
                && directoryStoreRegistry.generation == generation
                && directoryStoreRegistry.activeKey == key
                && sessionNavigationGeneration == navigationGeneration
                && currentProject?.id == project.id
        }

        isLoading = true
        defer { if backendConnection?.id == connection.id, !connection.isClosed, directoryStoreRegistry.generation == generation { isLoading = false } }
        do {
            let selectedDirectory = try await resolveNewSessionDirectory()
            guard isCurrent() else { return }
            let scope = projectExecutionScope(for: project, directory: selectedDirectory)
            guard let directory = scope.directory, !directory.isEmpty else { throw BackendError.invalidScope }
            let owner = directoryStoreRegistry.store(for: directory)
            let session = try await connection.sessions.createSession(.init(title: title,
                scope: scope,
                agent: defaults.agentName, model: model, variant: defaults.reasoningVariant))
            recordCreatedSessionForMetering()
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                  directoryStoreRegistry.key(for: owner) != nil,
                  !directoryStoreRegistry.isV2SessionDeleted(session.id) else { return }
            owner.insertV2Session(session)
            applyV2SessionConfiguration(session)
            guard isCurrent() else { return }
            draftTitle = ""
            newWorkspaceName = ""
            newSessionWorkspaceSelection = .main
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateSessionSheet = false
            }
            isLoading = false
            seedComposerSelectionsForNewSession(session)
            await selectSession(session)
        } catch {
            if isCurrent() { errorMessage = error.localizedDescription }
        }
    }

    var supportsProjectActionExecution: Bool {
        !isBrowsingLocalCache && !isUsingAppleIntelligence && isConnected
            && backendConnection?.isClosed == false && backendConnection?.commands != nil
    }

    var currentProjectActionScope: ProjectActionScope? {
        guard let connection = backendConnection, let commands = connection.commands else { return nil }
        let scope = currentProject.map { projectExecutionScope(for: $0, directory: effectiveSelectedDirectory) }
            ?? BackendScope(directory: effectiveSelectedDirectory)
        return .init(backendID: connection.descriptor.id, contractID: commands.actionContractID,
            projectID: scope.projectID,
            directory: connection.openCodeCompatibility?.profile == .legacy ? effectiveSelectedDirectory : scope.directory,
            workspaceID: scope.workspaceID)
    }

    func runAction(_ action: OpenCodeAction) async {
        guard supportsProjectActionExecution, let connection = backendConnection,
              let commands = connection.commands, let scope = currentProjectActionScope else {
            errorMessage = String(localized: "The /\(action.commandName) command is not available in this project.")
            return
        }
        guard hasProUnlock else {
            presentPaywall(reason: .actions)
            return
        }

        guard actionCommand(for: action) != nil else {
            errorMessage = String(localized: "The /\(action.commandName) command is not available in this project.")
            return
        }

        let defaults = newSessionDefaults
        let model = defaults.providerID.flatMap { providerID in
            defaults.modelID.map { OpenCodeModelReference(providerID: providerID, modelID: $0) }
        }
        let owner = directoryStoreRegistry.store(for: scope.directory)
        await projectActionCoordinator.run(action: action, scope: scope, connection: connection, commands: commands,
            agent: defaults.agentName, model: model, variant: defaults.reasoningVariant,
            isCurrent: { [weak self] in self?.isCurrentBackendConnection(connection) == true },
            sessionCreated: { [weak self] session in
                guard let self, isCurrentBackendConnection(connection) else { return }
                _ = owner.upsertSessions([session])
            })
    }

    func recoverProjectActionRun(id: String) async {
        guard let connection = backendConnection, let scope = currentProjectActionScope,
              let run = projectActionStore.run(id: id), run.scope == scope, let sessionID = run.sessionID else { return }
        // Recovery is local first and never depends on rename/archive succeeding.
        projectActionStore.reveal(id: id)
        do {
            let session = try await connection.sessions.session(id: sessionID, scope: run.scope.backendScope)
            guard isCurrentBackendConnection(connection), currentProjectActionScope == scope else { return }
            upsertVisibleSession(session)
            isShowingProjectSettingsSheet = false
            await selectSession(session)
        } catch {
            if isCurrentBackendConnection(connection) { errorMessage = error.localizedDescription }
        }
    }

    private func resolveNewSessionDirectory() async throws -> String? {
        guard let project = currentProject, isProjectWorkspacesEnabled(for: project),
              project.vcs == "git",
              project.id != "global" else {
            return effectiveSelectedDirectory
        }

        switch newSessionWorkspaceSelection {
        case .main:
            return project.worktree
        case let .directory(directory):
            return directory
        case .createNew:
            let created = try await createManagedWorktree(name: newWorkspaceName)
            return created.directory
        }
    }

    func createManagedWorktree(name rawName: String?, destinationParent: String? = nil,
                               project requestedProject: OpenCodeProject? = nil) async throws -> BackendWorktreeCreationResult {
        guard let connection = backendConnection, let service = connection.worktrees,
              let selectedProject = requestedProject ?? currentProject else {
            throw OpenCodeWorktreeOperationError.missingProject
        }
        let project = projectStore.preservingSelectedDirectory(selectedProject, connectionID: connection.id)
        guard isProjectWorkspacesEnabled(for: project), project.vcs == "git", let key = worktreeInventoryKey(for: project) else {
            throw OpenCodeWorktreeOperationError.missingProject
        }
        guard projectStore.beginWorktreeCreation(for: key) else { throw BackendWorktreeError.unavailable }
        defer { projectStore.finishWorktreeCreation(for: key) }
        let scope = BackendScope(projectID: project.id, directory: project.worktree)
        if projectStore.worktreeInventories[key] == nil {
            let requestID = projectStore.beginWorktreeInventoryRequest(for: key)
            let entries = try await service.inventory(scope: scope)
            guard isCurrentBackendConnection(connection) else { throw CancellationError() }
            projectStore.applyWorktreeInventory(entries, for: key, requestID: requestID)
        }
        let name = rawName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let parent = destinationParent ?? projectStore.worktreeDestinationParents[key]
        let readinessRevision = projectStore.worktreeReadinessRevision
        let created = try await service.create(.init(scope: scope, name: name, destinationParent: parent))
        guard isCurrentBackendConnection(connection) else { throw CancellationError() }
        if let parent { projectStore.worktreeDestinationParents[key] = parent }
        let entries = projectStore.worktreeInventories[key] ?? []
        projectStore.setWorktreeInventory(entries.filter { $0.directory != created.directory } + [created.worktree], for: key)
        if currentProject?.id == project.id {
            appendSandboxDirectory(created.directory, to: project)
            sessionListStore.ensureWorkspaceStateExists(for: created.directory)
        }
        switch created.readiness {
        case .ready: sessionListStore.setWorkspaceOperation(nil, for: created.directory)
        case .preparing:
            if let event = projectStore.worktreeReadinessEvent(directory: created.directory, connectionID: connection.id, after: readinessRevision) {
                sessionListStore.setWorkspaceOperation(event.error.map(OpenCodeWorkspaceOperation.failed), for: created.directory)
            } else {
                sessionListStore.setWorkspaceOperation(.preparing, for: created.directory)
            }
        }
        return created
    }

    private func projectForManagedWorktree(_ directory: String) throws -> OpenCodeProject {
        guard let connection = backendConnection,
              let project = currentProject.map({ projectStore.preservingSelectedDirectory($0, connectionID: connection.id) }),
              project.id != "global",
              project.vcs == "git" else {
            throw OpenCodeWorktreeOperationError.missingProject
        }

        guard workspaceKey(directory) != workspaceKey(project.worktree) else {
            throw OpenCodeWorktreeOperationError.primaryWorkspace
        }
        guard let key = worktreeInventoryKey(for: project),
              projectStore.worktreeInventories[key]?.contains(where: { $0.directory == directory && $0.isManaged }) == true else {
            throw BackendWorktreeError.unsupportedLocation
        }
        return project
    }

    private func clearSelectionIfNeeded(afterRemovingWorkspace directory: String, fallbackDirectory: String) async {
        let removedKey = workspaceKey(directory)
        let selectedKey = selectedDirectory.map { workspaceKey($0) }
        let sessionKey = selectedSession?.directory.map { workspaceKey($0) }
        let streamKey = streamDirectory.map { workspaceKey($0) }
        guard selectedKey == removedKey || sessionKey == removedKey || streamKey == removedKey else { return }

        prepareDirectorySelection(fallbackDirectory)
        do {
            try await reloadSessions()
            await loadComposerOptions()
        } catch {
            isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    private func removeLocalSessions(_ sessionIDs: [String], fromWorkspace directory: String, leavesEmptyWorkspaceState: Bool = true) {
        guard !sessionIDs.isEmpty else {
            if leavesEmptyWorkspaceState {
                sessionListStore.finishWorkspaceSessionsLoading([], estimatedTotal: 0, limit: sessionListStore.workspaceSessionState(for: directory).limit, directory: directory)
            }
            return
        }

        let ids = Set(sessionIDs)
        allSessions.removeAll { ids.contains($0.id) }
        for sessionID in ids {
            sessionStatuses[sessionID] = nil
            chatStore.clearCachedMessages(forSessionID: sessionID)
            sessionListStore.removeSessionFromWorkspaceStates(sessionID: sessionID)
            removeSessionPreview(for: sessionID)
            clearPersistedMessageDraft(forSessionID: sessionID)
            removeSessionFromLocalCache(sessionID)
        }
        if leavesEmptyWorkspaceState {
            sessionListStore.finishWorkspaceSessionsLoading([], estimatedTotal: 0, limit: sessionListStore.workspaceSessionState(for: directory).limit, directory: directory)
        }
    }

    func selectSession(_ session: OpenCodeSession) async {
        if connectionStore.apiProfile == .v2 {
            if selectedSession?.id != session.id || (!chatStore.isHydratingV2Transcript(sessionID: session.id)
                && chatStore.preparedSessionID != session.id) {
                _ = beginSessionNavigation(session)
            }
            let generation = sessionNavigationGeneration
            let key = directoryStoreRegistry.activeKey
            let registryGeneration = directoryStoreRegistry.generation
            if chatStore.messages.isEmpty {
                _ = await hydrateChatFromLocalCache(session, navigationGeneration: generation, expectedDirectoryKey: key)
                guard directoryStoreRegistry.generation == registryGeneration,
                      isSessionNavigationCurrent(sessionID: session.id, generation: generation, directoryKey: key) else { return }
            }
            do {
                try await reloadSessionStatuses()
                guard directoryStoreRegistry.generation == registryGeneration,
                      isSessionNavigationCurrent(sessionID: session.id, generation: generation, directoryKey: key) else { return }
                if await hydrateV2Transcript(for: session, navigationGeneration: generation, expectedDirectoryKey: key) {
                    await hydrateV2Interactions(for: session)
                }
            } catch {
                guard directoryStoreRegistry.generation == registryGeneration,
                      isSessionNavigationCurrent(sessionID: session.id, generation: generation, directoryKey: key) else { return }
                chatStore.failV2TranscriptHydration(sessionID: session.id)
                errorMessage = error.localizedDescription
            }
            return
        }
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
            sessionNavigationGeneration &+= 1
            prepareSessionSelection(session)
        }
        let navigationGeneration = sessionNavigationGeneration
        let navigationDirectoryKey = directoryStoreRegistry.activeKey
        if compatibilityClient(for: .localCache) != nil, !hasHydratedLocalChat(sessionID: session.id),
           await hydrateChatFromLocalCache(
            session,
            navigationGeneration: navigationGeneration,
            expectedDirectoryKey: navigationDirectoryKey
           ) != nil {
            guard isSessionNavigationCurrent(
                sessionID: session.id,
                generation: navigationGeneration,
                directoryKey: navigationDirectoryKey
            ) else { return }
            prepareSessionSelection(
                session,
                preservingDraftForSessionID: nil,
                animatesChanges: false
            )
        }
        if isBrowsingLocalCache {
            chatStore.finishLoadingSelectedSession()
            restoreMessageDraftIfComposerIsEmpty(for: session)
            return
        }

        guard let connection = try? requireBackendConnection() else { return }
        do {
            let todosAreFresh = areLocalChatTodosFresh(sessionID: session.id)
            async let statuses: Void = reloadSessionStatuses()
            async let permissions: Void = loadAllPermissions(for: session)
            async let questions: Void = loadAllQuestions(for: session)
            async let messages: Void = loadMessages(for: session, refreshTodos: !todosAreFresh)
            _ = try await (messages, statuses, permissions, questions)
            guard isCurrentBackendConnection(connection), isSessionNavigationCurrent(
                sessionID: session.id,
                generation: navigationGeneration,
                directoryKey: navigationDirectoryKey
            ) else { return }
            restoreMessageDraftIfComposerIsEmpty(for: session)
            errorMessage = nil
        } catch {
            guard isCurrentBackendConnection(connection), isSessionNavigationCurrent(
                sessionID: session.id,
                generation: navigationGeneration,
                directoryKey: navigationDirectoryKey
            ) else { return }
            chatStore.finishLoadingSelectedSession()
            errorMessage = error.localizedDescription
        }
    }

    func isSessionNavigationCurrent(sessionID: String, generation: UInt, directoryKey: String) -> Bool {
        sessionNavigationGeneration == generation
            && directoryStoreRegistry.activeKey == directoryKey
            && selectedSession?.id == sessionID
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

    @discardableResult
    func sendCommand(_ command: OpenCodeCommand, sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async -> Bool {
        await sendCommand(command, arguments: "", attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    @discardableResult
    func sendCommand(_ command: OpenCodeCommand, arguments: String, sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async -> Bool {
        await sendCommand(command, arguments: arguments, attachments: draftAttachments, sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    @discardableResult
    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true, messageID: String? = nil, agentMentions: [OpenCodeAgentMention]? = nil, reservedPromptDay: String? = nil) async -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        return await sendCommand(command, arguments: arguments, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure,
            messageID: messageID, agentMentions: agentMentions, reservedPromptDay: reservedPromptDay)
    }

    @discardableResult
    func sendCommand(_ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], in selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true, messageID: String? = nil, agentMentions: [OpenCodeAgentMention]? = nil, reservedPromptDay: String? = nil, windowContext: ChatWindowContext? = nil) async -> Bool {
        guard windowContext?.isCurrent ?? true else { return false }
        guard !funAndGamesStore.hasPendingSetup(for: selectedSession.id) else { return false }
        guard !Task.isCancelled, !isBrowsingLocalCache, !isUsingAppleIntelligence else { return false }
        if isCompactClientCommand(command) {
            return await compactSession(selectedSession, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
        }
        // Client-local commands must never be sent to an optional server service.
        guard command.source != "client" else { return false }
        if let connection = backendConnection, !connection.isClosed, let service = connection.commands {
            return await submitBackendCommand(command, arguments: arguments, attachments: attachments, in: selectedSession,
                connection: connection, service: service, userVisible: userVisible, meterPrompt: meterPrompt,
                requestedMessageID: messageID, agentMentions: agentMentions, reservedPromptDay: reservedPromptDay,
                restoreDraftOnFailure: restoreDraftOnFailure, windowContext: windowContext)
        }
        let allowsLegacyFallback = backendConnection?.openCodeCompatibility?.profile == .legacy
            || (backendConnection == nil && backendFactory == nil && connectionStore.apiProfile != .v2 && config.apiPreference == .legacy)
        guard allowsLegacyFallback, let legacyClient = compatibilityClient(for: .commands),
              let connection = try? requireBackendConnection(),
              let service = connection.commands ?? OpenCodeCommandsService.make(client: legacyClient, profile: .legacy,
                version: connection.descriptor.version, sessions: connection.sessions, chat: connection.chat) else {
            errorMessage = String(localized: "The /\(command.name) command is not available in this project.")
            return false
        }
        return await submitBackendCommand(command, arguments: arguments, attachments: attachments, in: selectedSession,
            connection: connection, service: service, userVisible: userVisible, meterPrompt: meterPrompt,
            requestedMessageID: messageID, agentMentions: agentMentions, reservedPromptDay: reservedPromptDay,
            restoreDraftOnFailure: restoreDraftOnFailure, windowContext: windowContext)
    }

    private func submitBackendCommand(
        _ command: OpenCodeCommand, arguments: String, attachments: [OpenCodeComposerAttachment], in session: OpenCodeSession,
        connection: BackendConnection, service: any BackendCommandsService, userVisible: Bool, meterPrompt: Bool,
        requestedMessageID: String?, agentMentions: [OpenCodeAgentMention]?, reservedPromptDay: String?, restoreDraftOnFailure: Bool,
        windowContext: ChatWindowContext? = nil
    ) async -> Bool {
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let key = directoryStoreRegistry.key(for: owner) ?? directoryStoreRegistry.activeKey
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let isV2 = connectionStore.apiProfile == .v2
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && directoryStoreRegistry.generation == generation
                && (windowContext?.isCurrent ?? true)
                && directoryStoreRegistry.contains(owner, forKey: key)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision
        }
        let isVisible = { [self] in
            windowContext == nil && isCurrent() && isSessionNavigationCurrent(sessionID: session.id, generation: navigationGeneration, directoryKey: key)
        }
        guard isCurrent() else { return false }
        if let id = requestedMessageID {
            if let phase = chatFacade.promptAdmissionPhase(messageID: id, sessionID: session.id) {
                return phase == .admitted
            }
        }
        guard !chatFacade.hasPendingPromptAdmission(sessionID: session.id) else {
            if connection.openCodeCompatibility == nil, isVisible() { errorMessage = String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.") }
            return false
        }
        guard owner.sessionStatuses[session.id] != "busy" else { return false }

        let preparation = sessionCoordinator.prepareCommandSubmission(command: command, arguments: arguments, attachments: attachments,
            session: session, selectedDirectory: windowContext == nil ? effectiveSelectedDirectory : session.directory,
            currentProjectID: windowContext == nil ? currentProject?.id : session.projectID,
            model: effectiveModelReference(for: session), agent: effectiveAgentName(for: session), variant: selectedVariant(for: session))
        let submission = preparation.submission
        let previousDraft = draftMessage
        let previousMentions = draftAgentMentions
        let previousAttachments = draftAttachments
        let previousResetToken = composerStore.resetToken
        let matchesDraft = userVisible && isVisible()
            && previousDraft.trimmingCharacters(in: .whitespacesAndNewlines) == preparation.draftCommand
        let text = matchesDraft ? previousDraft : preparation.draftCommand
        let mentions = OpenCodeAgentMention.reconciled(agentMentions ?? (matchesDraft ? previousMentions : []), in: text)
        let restoreEmptyDraft = { [self] in
            guard restoreDraftOnFailure, userVisible, isVisible(), previousDraft.isEmpty,
                  composerStore.resetToken == previousResetToken, draftMessage == previousDraft,
                  draftAgentMentions == previousMentions, draftAttachments == previousAttachments else { return }
            composerStore.resetActiveDraft(text: text, agentMentions: mentions, attachments: attachments)
            persistCurrentMessageDraft(forSessionID: session.id)
        }
        let messageID = requestedMessageID ?? OpenCodeIdentifier.message()
        let request = BackendCommandSubmission(sessionID: session.id, messageID: messageID, command: command.name,
            arguments: submission.arguments,
            scope: .init(projectID: session.projectID, directory: submission.directory, workspaceID: session.workspaceID),
            agent: submission.agent, model: submission.model, variant: submission.variant, attachments: attachments,
            agentMentions: OpenCodeAgentMention.reconciled(mentions, in: submission.arguments), resume: true)
        let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: text, agentMentions: mentions, attachments: attachments,
            messageID: messageID, sessionID: session.id, partID: isV2 ? "\(messageID):v2:text:0" : OpenCodeIdentifier.part(),
            agent: submission.agent, model: submission.model.map {
                .init(providerID: $0.providerID, modelID: $0.modelID, variant: submission.variant)
            })
        guard reservedPromptDay != nil || !userVisible || !meterPrompt || reserveUserPromptIfAllowed() else { return false }
        let chargedDay = reservedPromptDay ?? (userVisible && meterPrompt && !hasProUnlock ? usageMeter.promptDay : nil)
        let refund = { [self] in
            if let chargedDay, usageMeter.promptDay == chargedDay, chargedDay == OpenClientUsageMeter.dayString(for: Date()) {
                refundReservedUserPromptIfNeeded()
            }
        }
        let began = chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: messageID, text: text,
            scope: request.scope, attachments: attachments, agentMentions: mentions,
            agent: request.agent, model: request.model, variant: request.variant), connectionID: connection.id)
        guard began else { refund(); return false }
        if connection.openCodeCompatibility == nil, !owner.syncState.messageEnvelopes(forSessionID: session.id).contains(where: { $0.id == messageID }) {
            owner.appendMessage(optimistic, forSessionID: session.id)
        }
        if connection.openCodeCompatibility == nil, userVisible, isVisible(), !chatStore.messages.contains(where: { $0.id == messageID }) {
            chatStore.insertOptimisticUserMessage(optimistic)
        }
        let previousStatus = owner.sessionStatuses[session.id] ?? "idle"
        owner.applySessionStatus("busy", forSessionID: session.id)
        let statusRevision = owner.statusRevision
        defer {
            if backendConnection?.id == connection.id, !connection.isClosed, directoryStoreRegistry.generation == generation {
                chatStore.applyPromptAdmission(.uncertain, messageID: messageID, connectionID: connection.id)
            }
        }

        let admission: BackendAdmission
        do {
            admission = try await service.submitCommand(request)
        } catch {
            admission = .uncertain(sessionID: session.id, messageID: messageID)
        }
        guard isCurrent() else { return false }
        // Canonical input received while HTTP was pending is stronger than its response.
        var admitted = chatFacade.isPromptAdmitted(messageID: messageID, sessionID: session.id)
            || (isV2 && chatStore.submissionRecoveries[messageID]?.phase == .cancelled)
        switch admission {
        case let .accepted(sessionID, inputID) where sessionID == session.id && inputID == messageID:
            admitted = true
        case let .rejected(sessionID, inputID) where sessionID == session.id && inputID == messageID:
            if !admitted {
                chatStore.applyPromptAdmission(.rejected, messageID: messageID, connectionID: connection.id)
                chatStore.rollbackOptimisticUserMessage(messageID: messageID)
                if let cached = chatStore.cachedMessagesBySessionID[session.id] {
                    chatStore.cacheMessages(cached.filter { $0.id != messageID }, forSessionID: session.id)
                }
                _ = owner.removeMessage(sessionID: session.id, messageID: messageID)
                if owner.statusRevision == statusRevision { owner.applySessionStatus(previousStatus, forSessionID: session.id) }
                refund()
                restoreEmptyDraft()
                if isVisible() { errorMessage = String(localized: "OpenCode rejected the prompt.") }
                return false
            }
        default: break
        }
        guard admitted else {
            chatStore.applyPromptAdmission(.uncertain, messageID: messageID, connectionID: connection.id)
            restoreEmptyDraft()
            if connection.openCodeCompatibility == nil, isVisible() { errorMessage = String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.") }
            return false
        }
        chatStore.applyPromptAdmission(.admitted, messageID: messageID, connectionID: connection.id)
        if userVisible, isVisible(), composerStore.resetToken == previousResetToken,
           draftMessage == previousDraft, draftAgentMentions == previousMentions, draftAttachments == previousAttachments,
           attachments == previousAttachments, matchesDraft || previousDraft.isEmpty,
           !previousDraft.isEmpty || restoreDraftOnFailure {
            composerStore.resetActiveDraft()
            clearPersistedMessageDraft(forSessionID: session.id)
        }
        if connection.openCodeCompatibility != nil {
            connectionStore.clearPromptError(connectionID: connection.id, sessionID: session.id, messageID: messageID)
        } else if isVisible() { errorMessage = nil }
        // Acceptance does not mean execution completed. Status remains event-owned.
        return true
    }

    @discardableResult
    func stopSession(_ session: OpenCodeSession) async -> Bool {
        if connectionStore.apiProfile == .v2 { return await interruptV2Session(sessionID: session.id) }
        if isUsingAppleIntelligence {
            appleIntelligenceResponseTask?.cancel()
            sessionStatuses[session.id] = "idle"
            persistAppleIntelligenceMessages()
            return true
        }

        let abortSubmission = sessionCoordinator.prepareAbortSession(
            session: session,
            selectedDirectory: effectiveSelectedDirectory,
            currentProjectID: currentProject?.id
        )

        guard let connection = try? requireBackendConnection() else { return false }
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let revision = owner.statusRevision
        var accepted = false
        do {
            appendDebugLog(
                "abort request session=\(debugSessionLabel(session)) directory=\(debugDirectoryLabel(abortSubmission.directory)) workspace=\(abortSubmission.workspaceID ?? "nil")"
            )
            try await connection.chat.interrupt(sessionID: session.id,
                scope: .init(projectID: session.projectID, directory: abortSubmission.directory, workspaceID: abortSubmission.workspaceID))
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                  directoryStoreRegistry.key(for: owner) != nil else { return true }
            if owner.statusRevision == revision { owner.applySessionStatus("idle", forSessionID: session.id) }
            appendDebugLog("abort accepted session=\(debugSessionLabel(session))")
            accepted = true
        } catch {
            appendDebugLog("abort error: \(error.localizedDescription)")
            if isCurrentBackendConnection(connection), sessionNavigationGeneration == navigationGeneration {
                errorMessage = error.localizedDescription
            }
        }

        guard isCurrentBackendConnection(connection), connection.openCodeCompatibility != nil,
              directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration else { return accepted }
        do {
            try await reloadSessionStatuses()
            try await loadMessages(for: session)
        } catch {
            appendDebugLog("post-abort refresh error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        return accepted
    }

    @discardableResult
    func sendMessage(_ text: String, agentMentions: [OpenCodeAgentMention] = [], attachments: [OpenCodeComposerAttachment] = [], sessionID: String, userVisible: Bool, meterPrompt: Bool = true) async -> Bool {
        if isUsingAppleIntelligence {
            guard let session = session(matching: sessionID) else { return false }
            await sendAppleIntelligenceMessage(text, attachments: attachments, in: session, userVisible: userVisible)
            return true
        }

        guard let session = session(matching: sessionID) else { return false }
        return await sendMessage(text, agentMentions: agentMentions, attachments: attachments, in: session, userVisible: userVisible, meterPrompt: meterPrompt)
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
        if backendConnection?.openCodeCompatibility != nil { return (resolvedMessageID, resolvedPartID) }
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
        directoryStore.appendMessage(localUserMessage, forSessionID: selectedSession.id)
        markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        return (resolvedMessageID, resolvedPartID)
    }

    @discardableResult
    func sendMessage(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        in selectedSession: OpenCodeSession,
        userVisible: Bool,
        messageID: String? = nil,
        partID: String? = nil,
        appendOptimisticMessage: Bool = true,
        meterPrompt: Bool = true,
        reservedPromptDay: String? = nil,
        windowContext: ChatWindowContext? = nil
    ) async -> Bool {
        guard !funAndGamesStore.hasPendingSetup(for: selectedSession.id), windowContext?.isCurrent ?? true else { return false }
        if connectionStore.apiProfile == .v2 {
            guard let connection = try? requireBackendConnection() else { return false }
            let generation = directoryStoreRegistry.generation
            let navigationGeneration = sessionNavigationGeneration
            let accepted = await sendV2TextPrompt(text, in: selectedSession, attachments: attachments,
                agentMentions: agentMentions, meterPrompt: userVisible && meterPrompt, messageID: messageID,
                reservedPromptDay: reservedPromptDay, windowContext: windowContext)
            if accepted, userVisible, isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
               sessionNavigationGeneration == navigationGeneration, self.selectedSession?.id == selectedSession.id,
               draftMessage == text, draftAttachments == attachments {
                composerStore.resetActiveDraft()
                clearPersistedMessageDraft(forSessionID: selectedSession.id)
            }
            return accepted
        }
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
            return true
        }

        guard !Task.isCancelled, let connection = try? requireBackendConnection() else { return false }
        if let messageID, let phase = chatFacade.promptAdmissionPhase(messageID: messageID, sessionID: selectedSession.id) {
            return phase == .admitted
        }
        guard !chatFacade.hasPendingPromptAdmission(sessionID: selectedSession.id) else { return false }
        let owner = directoryStoreRegistry.ownerStore(forSessionID: selectedSession.id) ?? directoryStore
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let key = directoryStoreRegistry.key(for: owner) ?? directoryStoreRegistry.activeKey
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && directoryStoreRegistry.generation == generation
                && (windowContext?.isCurrent ?? true)
                && directoryStoreRegistry.contains(owner, forKey: key)
        }
        let isVisible = { [self] in
            windowContext == nil && isCurrent() && isSessionNavigationCurrent(sessionID: selectedSession.id, generation: navigationGeneration, directoryKey: key)
        }
        let modelReference = effectiveModelReference(for: selectedSession)
        let agentName = effectiveAgentName(for: selectedSession)
        let variant = selectedVariant(for: selectedSession)
        guard let promptPreparation = sessionCoordinator.preparePromptSubmission(
            text: text,
            agentMentions: agentMentions,
            attachments: attachments,
            session: selectedSession,
            selectedDirectory: windowContext == nil ? effectiveSelectedDirectory : selectedSession.directory,
            currentProjectID: windowContext == nil ? currentProject?.id : selectedSession.projectID,
            messageID: messageID,
            partID: partID,
            model: modelReference,
            agent: agentName,
            variant: variant
        ) else { return false }

        let submission = promptPreparation.submission
        guard chatStore.promptAdmissions[submission.messageID]?.connectionID != connection.id else { return false }

        if userVisible, meterPrompt, reservedPromptDay == nil, !reserveUserPromptIfAllowed() {
            appendDebugLog("send blocked paywall session=\(debugSessionLabel(selectedSession))")
            return false
        }
        let chargedDay = reservedPromptDay ?? (userVisible && meterPrompt && !hasProUnlock ? usageMeter.promptDay : nil)
        let request = BackendSubmission(sessionID: submission.sessionID, messageID: submission.messageID, text: submission.text,
            scope: .init(projectID: selectedSession.projectID, directory: submission.directory, workspaceID: selectedSession.workspaceID),
            partID: submission.partID, attachments: submission.attachments, agentMentions: submission.agentMentions,
            agent: submission.agent, model: submission.model, variant: submission.variant)
        guard chatStore.beginPromptAdmission(request, connectionID: connection.id) else { return false }
        if connection.openCodeCompatibility != nil {
            owner.applyCanonicalMessages(chatStore.withoutRecoveryMessages(owner.syncState.messageEnvelopes(forSessionID: selectedSession.id),
                sessionID: selectedSession.id), forSessionID: selectedSession.id)
        }

        let start = sessionCoordinator.promptStart(for: promptPreparation)
        let resolvedMessageID = start.messageID
        let resolvedPartID = start.partID
        if windowContext == nil { isLoading = true }
        let previousStatus = owner.sessionStatuses[selectedSession.id]
        let statusTransition = sessionCoordinator.promptStatusTransition(
            for: promptPreparation,
            previousStatus: previousStatus
        )
        owner.applySessionStatus(statusTransition.nextStatus, forSessionID: selectedSession.id)
        let statusRevision = owner.statusRevision
        defer {
            if backendConnection?.id == connection.id, !connection.isClosed {
                if windowContext == nil { isLoading = false }
                chatStore.applyPromptAdmission(.uncertain, messageID: submission.messageID, connectionID: connection.id)
            }
        }

        let localUserMessage = sessionCoordinator.optimisticUserMessage(for: promptPreparation)
        if userVisible, appendOptimisticMessage, isVisible() {
            composerStore.draftMessage = ""
            composerStore.draftAgentMentions = []
            clearDraftAttachments()
            clearPersistedMessageDraft(forSessionID: selectedSession.id)
            composerStore.resetToken = UUID()
            if connection.openCodeCompatibility == nil {
                chatStore.insertOptimisticUserMessage(localUserMessage)
                owner.appendMessage(localUserMessage, forSessionID: selectedSession.id)
            }
            markChatBreadcrumb("optimistic insert", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
        }
        let draftAtSubmission = draftMessage
        let mentionsAtSubmission = draftAgentMentions
        let attachmentsAtSubmission = draftAttachments
        let resetTokenAtSubmission = composerStore.resetToken
        let restoreDraft = { [self] in
            guard userVisible, appendOptimisticMessage, isVisible(), composerStore.resetToken == resetTokenAtSubmission,
                  draftMessage == draftAtSubmission, draftAgentMentions == mentionsAtSubmission,
                  draftAttachments == attachmentsAtSubmission else { return }
            composerStore.resetActiveDraft(text: text, agentMentions: agentMentions, attachments: attachments)
            persistCurrentMessageDraft(forSessionID: selectedSession.id)
        }
        markChatBreadcrumb("send start", sessionID: start.sessionID, messageID: start.messageID, partID: start.partID)
        appendDebugLog("send: \(start.text)")
        appendDebugLog(
            "send scope session=\(debugSessionLabel(selectedSession)) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) currentProject=\(currentProject?.id ?? "nil") requestDir=\(debugDirectoryLabel(start.requestDirectory)) msgID=\(start.messageID) partID=\(start.partID)"
        )

        if (try? connection.requireOpenCodeClient(for: .liveActivities)) != nil { await maybeAutoStartLiveActivity(for: selectedSession) }

        do {
            let admission = try await connection.chat.submit(request)
            guard isCurrent() else { return false }
            switch admission {
            case let .accepted(sessionID, messageID) where sessionID == submission.sessionID && messageID == submission.messageID:
                chatStore.applyPromptAdmission(.admitted, messageID: submission.messageID, connectionID: connection.id)
            case let .rejected(sessionID, messageID) where sessionID == submission.sessionID && messageID == submission.messageID:
                if chatStore.applyPromptAdmission(.rejected, messageID: submission.messageID, connectionID: connection.id) == .admitted { return true }
                throw BackendPromptFailure.rejected
            default:
                throw BackendPromptFailure.uncertain
            }
            let success = sessionCoordinator.promptSuccess(for: promptPreparation)
            appendDebugLog("prompt_async accepted session=\(debugSessionLabel(selectedSession)) msgID=\(success.messageID) partID=\(success.partID)")
            markChatBreadcrumb("prompt_async accepted", sessionID: success.sessionID, messageID: success.messageID, partID: success.partID)
            if isCapturingStreamingDiagnostics, connection.openCodeCompatibility != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard self?.isCurrentBackendConnection(connection) == true else { return }
                    await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 500ms")
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard self?.isCurrentBackendConnection(connection) == true else { return }
                    await self?.logServerMessageSnapshot(for: selectedSession, reason: "post-send 2s")
                }
            }
            if (try? connection.requireOpenCodeClient(for: .liveActivities)) != nil { refreshLiveActivityIfNeeded(for: selectedSession.id) }
            if connection.openCodeCompatibility != nil {
                connectionStore.clearPromptError(connectionID: connection.id, sessionID: selectedSession.id, messageID: submission.messageID)
            } else if isVisible() { errorMessage = nil }
            return true
        } catch BackendPromptFailure.rejected {
            guard isCurrent() else { return false }
            if let chargedDay, usageMeter.promptDay == chargedDay, chargedDay == OpenClientUsageMeter.dayString(for: Date()) {
                refundReservedUserPromptIfNeeded()
            }
            if owner.statusRevision == statusRevision {
                owner.applySessionStatus(statusTransition.previousStatus ?? "idle", forSessionID: selectedSession.id)
            }
            if userVisible {
                let rollback = sessionCoordinator.promptRollback(
                    for: promptPreparation,
                    optimisticMessage: localUserMessage,
                    previousStatus: statusTransition.previousStatus
                )
                chatStore.rollbackOptimisticUserMessage(messageID: rollback.optimisticMessageID)
                owner.removeMessage(sessionID: selectedSession.id, messageID: rollback.optimisticMessageID)
                if let cached = chatStore.cachedMessagesBySessionID[selectedSession.id] {
                    chatStore.cacheMessages(cached.filter { $0.id != rollback.optimisticMessageID }, forSessionID: selectedSession.id)
                }
                markChatBreadcrumb("send rollback", sessionID: rollback.sessionID, messageID: rollback.messageID, partID: rollback.partID)
                restoreDraft()
            }
            appendDebugLog("send rejected session=\(selectedSession.id) message=\(resolvedMessageID)")
            markChatBreadcrumb("send error", sessionID: selectedSession.id, messageID: resolvedMessageID, partID: resolvedPartID)
            if isVisible() { errorMessage = String(localized: "OpenCode rejected the prompt.") }
            return false
        } catch {
            guard isCurrent() else { return false }
            if chatStore.applyPromptAdmission(.uncertain, messageID: submission.messageID, connectionID: connection.id) == .admitted { return true }
            restoreDraft()
            if connection.openCodeCompatibility == nil, isVisible() { errorMessage = String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.") }
            return false
        }
    }

    func removeOptimisticUserMessage(messageID: String, sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        if let connectionID = backendConnection?.id,
           let phase = chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID, connectionID: connectionID),
           phase != .rejected { return }
        chatStore.removeOptimisticUserMessage(messageID: messageID)
        directoryStore.removeMessage(sessionID: sessionID, messageID: messageID)
        markChatBreadcrumb("optimistic remove", sessionID: sessionID, messageID: messageID)
    }

    /// Event owners must pass the connection that delivered this canonical user message.
    @discardableResult
    func confirmCanonicalPromptAdmission(_ message: OpenCodeMessage, connectionID: UUID) -> Bool {
        guard backendConnection?.id == connectionID, backendConnection?.isClosed == false,
              message.role == "user", let sessionID = message.sessionID else { return false }
        let generic = chatStore.confirmPromptAdmission(from: message, connectionID: connectionID)
        let v2 = chatStore.confirmCanonicalSubmission(message)
        guard generic || v2 else { return false }
        if backendConnection?.openCodeCompatibility != nil {
            connectionStore.clearPromptError(connectionID: connectionID, sessionID: sessionID, messageID: message.id)
        } else if selectedSession?.id == message.sessionID,
           errorMessage == String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.") {
            errorMessage = nil
        }
        return true
    }

    func slashCommandInput(from text: String) -> (command: OpenCodeCommand, arguments: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }

        let body = String(trimmed.dropFirst())
        guard !body.isEmpty else { return nil }

        let parts = body.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let commandName = parts.first.map(String.init), !commandName.isEmpty,
              let sessionID = selectedSession?.id,
              let command = chatFacade.commands(forSessionID: sessionID, canFork: !forkableMessages.isEmpty)
                .first(where: { $0.name == commandName }) else {
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
        command.source == "client" && command.name == "compact"
    }

    @discardableResult
    func compactSession(sessionID: String, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async -> Bool {
        guard let session = session(matching: sessionID) else { return false }
        return await compactSession(session, userVisible: userVisible, meterPrompt: meterPrompt, restoreDraftOnFailure: restoreDraftOnFailure)
    }

    @discardableResult
    func compactSession(_ selectedSession: OpenCodeSession, userVisible: Bool, meterPrompt: Bool = true, restoreDraftOnFailure: Bool = true) async -> Bool {
        guard compatibilityClient(for: .compaction) != nil else { return false }
        if connectionStore.apiProfile == .v2 {
            return await submitV2Compaction(in: selectedSession, userVisible: userVisible, meterPrompt: meterPrompt)
        }
        guard selectedSession.parentID == nil else {
            appendDebugLog("compact blocked child session=\(debugSessionLabel(selectedSession))")
            errorMessage = String(localized: "Compact is only available in root sessions.")
            return false
        }

        guard sessionStatuses[selectedSession.id] != "busy" else {
            appendDebugLog("compact blocked busy session=\(debugSessionLabel(selectedSession))")
            return false
        }

        guard let modelReference = effectiveModelReference(for: selectedSession) else {
            appendDebugLog("compact blocked missing model session=\(debugSessionLabel(selectedSession))")
            errorMessage = String(localized: "Select a model before compacting this session.")
            return false
        }

        if userVisible, meterPrompt, !reserveUserPromptIfAllowed() {
            appendDebugLog("compact blocked paywall session=\(debugSessionLabel(selectedSession))")
            return false
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
            refreshLiveActivityIfNeeded(for: selectedSession.id)
            errorMessage = nil
            return true
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
            return false
        }
    }

    func shouldOpenForkSheet(forSlashInput text: String) -> Bool {
        compatibilityClient(for: .fork) != nil && text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/fork"
    }

    func forkSelectedSession(from messageID: String) async {
        guard let selectedSession else { return }
        await forkSession(selectedSession, from: messageID)
    }

    private func submitV2Compaction(
        in session: OpenCodeSession, userVisible: Bool, meterPrompt: Bool
    ) async -> Bool {
        guard let connection = try? requireBackendConnection(),
              let client = try? connection.requireOpenCodeClient(for: .compaction) else { return false }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        guard !Task.isCancelled, owner.sessionStatuses[session.id] != "busy",
              !chatStore.isV2PromptInFlight(sessionID: session.id) else { return false }
        let charged = userVisible && meterPrompt && !hasProUnlock
        guard !userVisible || !meterPrompt || reserveUserPromptIfAllowed() else { return false }
        let chargedDay = usageMeter.promptDay
        let previousStatus = owner.sessionStatuses[session.id] ?? "idle"
        let previousDraft = draftMessage
        let previousAttachments = draftAttachments
        owner.applySessionStatus("busy", forSessionID: session.id)
        let revision = owner.statusRevision
        let isCurrent = { [self] in
            isCurrentBackendConnection(connection) && config == client.config && connectionStore.apiProfile == .v2
                && directoryStoreRegistry.generation == generation && directoryStoreRegistry.key(for: owner) != nil
        }
        do {
            try await client.compactV2Session(sessionID: session.id)
            guard isCurrent() else { return true }
            directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
            scheduleV2TimelineReconciliation()
            if userVisible, selectedSession?.id == session.id, sessionNavigationGeneration == navigationGeneration,
               draftMessage == previousDraft, draftAttachments == previousAttachments {
                composerStore.resetActiveDraft()
                clearPersistedMessageDraft(forSessionID: session.id)
                errorMessage = nil
            }
            return true
        } catch {
            if case let OpenCodeAPIError.httpError(status, _) = error, Self.isDefinitiveV2PromptRejection(status) {
                if charged, usageMeter.promptDay == chargedDay, chargedDay == OpenClientUsageMeter.dayString(for: Date()) {
                    refundReservedUserPromptIfNeeded()
                }
                if isCurrent(), owner.statusRevision == revision { owner.applySessionStatus(previousStatus, forSessionID: session.id) }
            }
            if isCurrent() {
                directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
                scheduleV2TimelineReconciliation()
                if selectedSession?.id == session.id, sessionNavigationGeneration == navigationGeneration {
                    errorMessage = error.localizedDescription
                }
            }
            return false
        }
    }

    func forkSession(_ selectedSession: OpenCodeSession, from messageID: String) async {
        guard compatibilityClient(for: .fork) != nil else { return }
        if connectionStore.apiProfile == .v2 {
            guard pendingForkSessionID == nil else { return }
            let client = client
            let generation = directoryStoreRegistry.generation
            let navigationGeneration = sessionNavigationGeneration
            let key = directoryStoreRegistry.activeKey
            let owner = directoryStoreRegistry.ownerStore(forSessionID: selectedSession.id) ?? directoryStore
            pendingForkSessionID = selectedSession.id
            pendingForkMessageID = messageID
            defer {
                if config == client.config, directoryStoreRegistry.generation == generation,
                   pendingForkSessionID == selectedSession.id, pendingForkMessageID == messageID {
                    pendingForkSessionID = nil
                    pendingForkMessageID = nil
                }
            }
            do {
                let forked = try await client.forkV2Session(sessionID: selectedSession.id, messageID: messageID)
                guard connectionStore.apiProfile == .v2, config == client.config, directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.key(for: owner) != nil,
                      !directoryStoreRegistry.isV2SessionDeleted(forked.id) else { return }
                directoryStoreRegistry.store(for: forked.directory).insertV2Session(forked)
                guard !Task.isCancelled, isSessionNavigationCurrent(sessionID: selectedSession.id,
                    generation: navigationGeneration, directoryKey: key) else { return }
                isShowingForkSessionSheet = false
                await selectSession(forked)
            } catch {
                if directoryStoreRegistry.generation == generation, isSessionNavigationCurrent(sessionID: selectedSession.id,
                    generation: navigationGeneration, directoryKey: key) { errorMessage = error.localizedDescription }
            }
            return
        }
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
        refreshTodos: Bool = true,
        presentationIndependent: Bool = false,
        canonicalOwner: DirectoryStore? = nil
    ) async throws {
        if connectionStore.apiProfile == .v2 {
            await reconcileV2TimelineFromEvent(sessionID: session.id)
            return
        }
        let targetStore = canonicalOwner ?? directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let targetGeneration = directoryStoreRegistry.generation
        let existingMessages = targetStore.syncState.messageEnvelopes(forSessionID: session.id)
        #if targetEnvironment(macCatalyst)
        let messageLimit = max(200, existingMessages.count)
        #else
        let messageLimit = max(20, existingMessages.count)
        #endif
        let connection = try requireBackendConnection()
        let navigationGeneration = sessionNavigationGeneration
        let page = try await connection.chat.transcript(sessionID: session.id,
            scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID), cursor: nil, limit: messageLimit)
        guard !Task.isCancelled, isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
              (presentationIndependent || sessionNavigationGeneration == navigationGeneration),
              directoryStoreRegistry.key(for: targetStore) != nil else { return }
        for message in page.messages where message.info.sessionID == session.id {
            confirmCanonicalPromptAdmission(message.info, connectionID: connection.id)
        }
        let currentMessages = targetStore.syncState.messageEnvelopes(forSessionID: session.id)
        var loadedMessages = ChatStore.mergingCanonicalMessagePage(page.messages.filter { $0.info.sessionID == session.id },
            into: chatStore.withoutRecoveryMessages(existingMessages, sessionID: session.id))
        if currentMessages != existingMessages {
            let previousByID = Dictionary(existingMessages.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            let removedIDs = Set(previousByID.keys).subtracting(currentMessages.map(\.id))
            let changedMessages = chatStore.withoutRecoveryMessages(currentMessages, sessionID: session.id).filter { previousByID[$0.id] != $0 }
            loadedMessages = ChatStore.mergingCanonicalMessagePage(changedMessages, into: loadedMessages)
                .filter { !removedIDs.contains($0.id) }
        }
        refreshSessionPreview(for: session.id, messages: loadedMessages)
        let isActiveSession = selectedSession?.id == session.id
        targetStore.applyCanonicalMessages(loadedMessages, forSessionID: session.id)
        chatStore.applyCanonicalMessages(loadedMessages, forSessionID: session.id, isActiveSession: isActiveSession)
        finishTranscriptCommit(in: targetStore, sessionID: session.id, completeInventory: page.messages)
        chatStore.applyMessageHistoryPage(nextCursor: page.olderCursor, forSessionID: session.id)
        if (try? connection.requireOpenCodeClient(for: .localCache)) != nil {
            persistLoadedMessagesToLocalCache(loadedMessages, sessionID: session.id)
        }
        inferFunAndGames(from: loadedMessages, forSessionID: session.id)
        guard isActiveSession else { return }
        if isCapturingStreamingDiagnostics {
            appendDebugLog(serverMessageSummary(loadedMessages, sessionID: session.id, reason: "loadMessages"))
        }
        syncComposerSelections(for: session, sourceMessages: loadedMessages)
        if prefetchToolDetails, connection.openCodeCompatibility != nil {
            prefetchToolMessageDetails(for: session, messages: messages)
        }
        if (try? connection.requireOpenCodeClient(for: .liveActivities)) != nil { refreshLiveActivityIfNeeded(for: session.id) }
        if refreshTodos, connection.openCodeCompatibility != nil {
            await loadTodos(for: session)
        }
    }

    @discardableResult
    func loadOlderMessages(for session: OpenCodeSession, count: Int, windowContext: ChatWindowContext? = nil) async -> Int {
        guard windowContext?.isCurrent ?? true else { return 0 }
        if connectionStore.apiProfile == .v2 {
            let before = chatStore.cachedMessagesBySessionID[session.id]?.count ?? 0
            guard await loadOlderV2Messages(sessionID: session.id, windowContext: windowContext) else { return 0 }
            return max(0, (chatStore.cachedMessagesBySessionID[session.id]?.count ?? 0) - before)
        }
        guard let connection = try? requireBackendConnection(),
              let cursor = chatStore.beginLoadingOlderMessages(forSessionID: session.id) else { return 0 }
        let targetStore = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let targetGeneration = directoryStoreRegistry.generation
        let existingMessages = targetStore.syncState.messageEnvelopes(forSessionID: session.id)
        let navigationGeneration = sessionNavigationGeneration

        do {
            let page = try await connection.chat.transcript(sessionID: session.id,
                scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID),
                cursor: cursor, limit: max(1, count))
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
                   (windowContext?.isCurrent ?? (sessionNavigationGeneration == navigationGeneration)),
                  directoryStoreRegistry.key(for: targetStore) != nil else {
                return 0
            }

            // Do not let an older page resurrect a message removed by an in-flight live event.
            for message in page.messages where message.info.sessionID == session.id {
                confirmCanonicalPromptAdmission(message.info, connectionID: connection.id)
            }
            guard targetStore.syncState.messageEnvelopes(forSessionID: session.id) == existingMessages else {
                chatStore.failLoadingOlderMessages(forSessionID: session.id)
                return 0
            }
            let loadedMessages = ChatStore.mergingCanonicalMessagePage(page.messages.filter { $0.info.sessionID == session.id },
                into: chatStore.withoutRecoveryMessages(existingMessages, sessionID: session.id))
            let addedCount = max(0, loadedMessages.count - existingMessages.count)
            let isActiveSession = selectedSession?.id == session.id
            targetStore.applyCanonicalMessages(loadedMessages, forSessionID: session.id)
            chatStore.applyCanonicalMessages(loadedMessages, forSessionID: session.id, isActiveSession: isActiveSession)
            finishTranscriptCommit(in: targetStore, sessionID: session.id, completeInventory: page.messages)
            chatStore.applyMessageHistoryPage(nextCursor: page.olderCursor, forSessionID: session.id)
            refreshSessionPreview(for: session.id, messages: loadedMessages)
            if (try? connection.requireOpenCodeClient(for: .localCache)) != nil {
                persistLoadedMessagesToLocalCache(loadedMessages, sessionID: session.id)
            }
            inferFunAndGames(from: loadedMessages, forSessionID: session.id)
            if let windowContext { windowContext.errorMessage = nil }
            else { errorMessage = nil }
            return addedCount
        } catch {
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == targetGeneration,
                   (windowContext?.isCurrent ?? (sessionNavigationGeneration == navigationGeneration)) else { return 0 }
            chatStore.failLoadingOlderMessages(forSessionID: session.id)
            appendDebugLog("older messages error session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            if let windowContext { windowContext.errorMessage = error.localizedDescription }
            else { errorMessage = error.localizedDescription }
            return 0
        }
    }

    func refreshChatData(for sessionID: String) async {
        let connectionID = backendConnection?.id
        let generation = directoryStoreRegistry.generation
        await funAndGamesFacade.reconcileSetup(for: sessionID)
        guard !Task.isCancelled, backendConnection?.id == connectionID, directoryStoreRegistry.generation == generation else { return }
        if connectionStore.apiProfile == .v2 {
            directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID, reconnect: true)
            scheduleV2TimelineReconciliation(immediate: true)
            return
        }
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
            if compatibilityClient(for: .interactions) != nil {
                await refreshToolMessageDetails(for: refreshedSession, messages: cachedMessagesBySessionID[sessionID] ?? messages)
            }
            errorMessage = nil
        } catch {
            appendDebugLog("manual chat refresh error session=\(debugSessionLabel(session)) error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func scheduleForegroundChatCatchUp(reason: String) -> Task<Void, Never>? {
        guard isApplicationActive, isConnected, !isUsingAppleIntelligence, !isBrowsingLocalCache,
              let sessionID = selectedSession?.id ?? activeChatSessionID,
              let session = session(matching: sessionID),
              let connection = try? requireBackendConnection() else { return nil }
        let context = ForegroundChatRefreshCoordinator.Context(
            connectionID: connection.id,
            registryGeneration: directoryStoreRegistry.generation,
            navigationGeneration: sessionNavigationGeneration,
            directoryKey: directoryStoreRegistry.activeKey,
            sessionID: sessionID,
            scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID),
            apiProfile: connectionStore.apiProfile,
            lifecycleRevision: directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        )
        foregroundChatCatchUpTask = chatFacade.foregroundChatRefreshCoordinator.schedule(context: context) { [weak self] in
            await self?.runForegroundChatCatchUp(context: context, reason: reason)
        }
        return foregroundChatCatchUpTask
    }

    private func isForegroundChatCatchUpCurrent(_ context: ForegroundChatRefreshCoordinator.Context) -> Bool {
        guard !Task.isCancelled, isApplicationActive, isConnected,
              let connection = backendConnection, isCurrentBackendConnection(connection),
              connection.id == context.connectionID,
              connectionStore.apiProfile == context.apiProfile,
              directoryStoreRegistry.generation == context.registryGeneration,
              sessionNavigationGeneration == context.navigationGeneration,
              directoryStoreRegistry.activeKey == context.directoryKey,
              (selectedSession?.id ?? activeChatSessionID) == context.sessionID,
              directoryStoreRegistry.v2LifecycleRevision(sessionID: context.sessionID) == context.lifecycleRevision,
              let session = session(matching: context.sessionID) else { return false }
        return BackendScope(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID) == context.scope
    }

    private func runForegroundChatCatchUp(context: ForegroundChatRefreshCoordinator.Context, reason: String) async {
        guard isForegroundChatCatchUpCurrent(context), let session = session(matching: context.sessionID) else { return }
        appendDebugLog("foreground catch-up start session=\(debugSessionLabel(session)) reason=\(reason)")
        // Prepared transcripts still need a canonical snapshot after suspension, even with healthy SSE.
        do {
            if context.apiProfile == .v2 {
                await reconcileV2TimelineFromEvent(sessionID: session.id)
            } else {
                try await loadMessages(for: session)
            }
        } catch {
            guard isForegroundChatCatchUpCurrent(context) else { return }
            appendDebugLog("foreground transcript catch-up error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        guard isForegroundChatCatchUpCurrent(context) else { return }
        do {
            try await reloadSessionStatuses()
        } catch {
            guard isForegroundChatCatchUpCurrent(context) else { return }
            appendDebugLog("foreground status catch-up error: \(error.localizedDescription)")
        }
        guard isForegroundChatCatchUpCurrent(context) else { return }
        if context.apiProfile == .v2 {
            await hydrateV2Interactions(for: session)
        } else {
            await loadAllPermissions(for: session)
            guard isForegroundChatCatchUpCurrent(context) else { return }
            await loadAllQuestions(for: session)
        }
        guard isForegroundChatCatchUpCurrent(context) else { return }
        appendDebugLog("foreground catch-up finish session=\(debugSessionLabel(session))")
    }

    func fetchMessageDetails(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        if connectionStore.apiProfile == .v2 {
            let connection = try requireBackendConnection()
            guard let client = connection.openCodeCompatibility?.client else { throw BackendError.unsupported(.interactions) }
            let generation = directoryStoreRegistry.generation
            let detail = try await client.getV2Message(sessionID: sessionID, messageID: messageID)
            guard isCurrentBackendConnection(connection), config == client.config, connectionStore.apiProfile == .v2,
                  directoryStoreRegistry.generation == generation else { throw CancellationError() }
            toolMessageDetails[messageID] = detail
            return detail
        }
        if isBrowsingLocalCache {
            let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) ?? directoryStore
            if let cached = owner.syncState.messageEnvelopes(forSessionID: sessionID).first(where: { $0.id == messageID }) {
                return cached
            }
            throw URLError(.notConnectedToInternet)
        }
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1",
           let detail = toolMessageDetails[messageID] {
            return detail
        }

        guard let client = compatibilityClient(for: .interactions) else {
            let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) ?? directoryStore
            if let message = owner.syncState.messageEnvelopes(forSessionID: sessionID).first(where: { $0.id == messageID }) {
                return message
            }
            let connection = try requireBackendConnection()
            let generation = directoryStoreRegistry.generation
            let page = try await connection.chat.transcript(sessionID: sessionID,
                scope: .init(directory: session(matching: sessionID)?.directory), cursor: nil, limit: 50)
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation else { throw CancellationError() }
            guard let message = page.messages.first(where: { $0.id == messageID }) else { throw BackendError.invalidScope }
            return message
        }
        let connectionID = backendConnection?.id
        let generation = directoryStoreRegistry.generation
        let detail = try await client.getMessage(sessionID: sessionID, messageID: messageID)
        guard !Task.isCancelled, backendConnection?.id == connectionID,
              directoryStoreRegistry.generation == generation else { throw CancellationError() }
        toolMessageDetails[messageID] = detail
        return detail
    }

    @MainActor
    func logServerMessageSnapshot(for session: OpenCodeSession, reason: String) async {
        guard connectionStore.apiProfile != .v2, let client = compatibilityClient(for: .interactions) else { return }
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
                let snippet = String((part.text ?? "").prefix(40)).replacingOccurrences(of: "\n", with: "\\n")
                return "\(part.id ?? "nil"):\(part.type):\(snippet)"
            }.joined(separator: "|")
            return "\(message.id):\(message.info.role ?? "nil")[\(parts)]"
        }.joined(separator: "; ")

        return "server snapshot session=\(sessionID) reason=\(reason) count=\(messages.count) tail=\(tail)"
    }

    func refreshTodosAndLatestTodoMessage() async throws -> (todos: [OpenCodeTodo], detail: OpenCodeMessageEnvelope?) {
        guard compatibilityClient(for: .interactions) != nil else { return ([], nil) }
        guard connectionStore.apiProfile != .v2 else { return (todos, nil) }
        guard let selectedSession else {
            return (todos, nil)
        }

        if isBrowsingLocalCache {
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

        return try await refreshTodosAndLatestTodoMessage(for: selectedSession, owner: directoryStore)
    }

    func refreshTodosAndLatestTodoMessage(for session: OpenCodeSession, owner: DirectoryStore,
                                         windowContext: ChatWindowContext? = nil) async throws -> (todos: [OpenCodeTodo], detail: OpenCodeMessageEnvelope?) {
        let connection = try requireBackendConnection()
        guard connection.openCodeCompatibility?.profile == .legacy else { return ([], nil) }
        let client = try connection.requireOpenCodeClient(for: .interactions)
        guard let ownerKey = directoryStoreRegistry.key(for: owner) else { throw BackendError.invalidScope }
        let generation = directoryStoreRegistry.generation
        let lifecycle = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let navigationRevision = windowContext?.navigationRevision ?? sessionNavigationGeneration
        let isCurrent = { [self] in
            let canonical = owner.sessions.first { $0.id == session.id }
                ?? (owner.selectedSession?.id == session.id ? owner.selectedSession : nil)
            return !Task.isCancelled && isCurrentBackendConnection(connection)
                && directoryStoreRegistry.generation == generation
                && directoryStoreRegistry.contains(owner, forKey: ownerKey)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycle
                && canonical?.id == session.id && canonical?.directory == session.directory
                && canonical?.workspaceID == session.workspaceID && canonical?.projectID == session.projectID
                && (windowContext.map { $0.isCurrent && $0.session.id == session.id && $0.navigationRevision == navigationRevision }
                    ?? (selectedSession?.id == session.id && sessionNavigationGeneration == navigationRevision))
        }
        guard isCurrent() else { throw CancellationError() }
        let previousTodos = owner.syncState.todosBySessionID[session.id]
        let refreshedTodos = try await client.getTodos(sessionID: session.id)
        guard isCurrent() else { throw CancellationError() }
        // A live todo update during the read remains newer than this snapshot.
        if owner.syncState.todosBySessionID[session.id] == previousTodos {
            owner.applyTodos(refreshedTodos, forSessionID: session.id)
            if directoryStore === owner, selectedSession?.id == session.id {
                sessionInteractionStore.applyTodos(refreshedTodos, forSessionID: session.id, selectedSessionID: session.id)
            }
            persistLoadedTodosToLocalCache(refreshedTodos, sessionID: session.id)
        }
        let currentTodos = owner.syncState.todosBySessionID[session.id] ?? []
        guard let messageID = owner.syncState.messageEnvelopes(forSessionID: session.id).reversed().first(where: {
            $0.parts.contains { $0.tool == "todowrite" }
        })?.id else { return (currentTodos, nil) }
        let detail = try await client.getMessage(sessionID: session.id, messageID: messageID)
        guard isCurrent(), detail.id == messageID, detail.info.sessionID == session.id,
              owner.syncStore.containsMessage(id: messageID, forSessionID: session.id) else { throw CancellationError() }
        toolMessageDetails[messageID] = detail
        return (owner.syncState.todosBySessionID[session.id] ?? [], detail)
    }

    func loadTodos(for session: OpenCodeSession) async {
        guard connectionStore.apiProfile != .v2, let client = compatibilityClient(for: .interactions) else { return }
        let targetStore = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let targetGeneration = directoryStoreRegistry.generation
        do {
            let todos = try await client.getTodos(sessionID: session.id)
            guard directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.key(for: targetStore) != nil else { return }
            objectWillChange.send()
            targetStore.applyTodos(todos, forSessionID: session.id)
            sessionInteractionStore.applyTodos(todos, forSessionID: session.id, selectedSessionID: selectedSession?.id)
            persistLoadedTodosToLocalCache(todos, sessionID: session.id)
            refreshLiveActivityIfNeeded(for: session.id)
        } catch {
            guard directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.key(for: targetStore) != nil else { return }
            guard !usesLocalCache else { return }
            objectWillChange.send()
            targetStore.applyTodos([], forSessionID: session.id)
            sessionInteractionStore.applyTodos([], forSessionID: session.id, selectedSessionID: selectedSession?.id)
            refreshLiveActivityIfNeeded(for: session.id)
        }
    }

    func loadAllPermissions(directory: String? = nil, workspaceID: String? = nil, canonicalOwner: DirectoryStore? = nil) async {
        guard connectionStore.apiProfile != .v2, let client = compatibilityClient(for: .interactions) else { return }
        let targetStore = canonicalOwner ?? directoryStore
        guard let targetKey = directoryStoreRegistry.key(for: targetStore) else { return }
        let targetGeneration = directoryStoreRegistry.generation
        let permissionRevision = targetStore.permissionRevision
        do {
            let permissions = try await client.listPermissions(directory: directory, workspaceID: workspaceID)
            let interactionSessions = await OpenCodeBootstrap.loadMissingSessions(
                sessionIDs: permissions.map(\.sessionID),
                knownSessions: targetStore.sessions,
                client: client,
                directory: directory,
                workspaceID: workspaceID
            )
            guard directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
            let warmedSessions = targetStore.upsertSessions(interactionSessions)
            let appliedPermissions = targetStore.applyPermissions(permissions, ifUnchangedSince: permissionRevision)
            if warmedSessions || appliedPermissions {
                objectWillChange.send()
                if directoryStoreRegistry.activeStore === targetStore,
                   let selectedSessionID = targetStore.selectedSession?.id {
                    sessionInteractionStore.applySelectedSession(
                        sessionID: selectedSessionID,
                        sessions: targetStore.sessions,
                        syncState: targetStore.syncState
                    )
                }
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            return
        }
    }

    func loadAllPermissions(for session: OpenCodeSession) async {
        if connectionStore.apiProfile == .v2 {
            await hydrateV2Interactions(for: session)
            return
        }
        await loadAllPermissions(directory: session.directory, workspaceID: session.workspaceID,
            canonicalOwner: directoryStoreRegistry.ownerStore(forSessionID: session.id))
    }

    func loadAllQuestions(directory: String? = nil, workspaceID: String? = nil, canonicalOwner: DirectoryStore? = nil) async {
        guard connectionStore.apiProfile != .v2, let client = compatibilityClient(for: .interactions) else { return }
        let targetStore = canonicalOwner ?? directoryStore
        guard let targetKey = directoryStoreRegistry.key(for: targetStore) else { return }
        let targetGeneration = directoryStoreRegistry.generation
        let questionRevision = targetStore.questionRevision
        do {
            let questions = try await client.listQuestions(directory: directory, workspaceID: workspaceID)
            let interactionSessions = await OpenCodeBootstrap.loadMissingSessions(
                sessionIDs: questions.map(\.sessionID),
                knownSessions: targetStore.sessions,
                client: client,
                directory: directory,
                workspaceID: workspaceID
            )
            guard directoryStoreRegistry.generation == targetGeneration,
                  directoryStoreRegistry.contains(targetStore, forKey: targetKey) else { return }
            let warmedSessions = targetStore.upsertSessions(interactionSessions)
            let appliedQuestions = targetStore.applyQuestions(questions, ifUnchangedSince: questionRevision)
            if warmedSessions || appliedQuestions {
                objectWillChange.send()
                if directoryStoreRegistry.activeStore === targetStore,
                   let selectedSessionID = targetStore.selectedSession?.id {
                    sessionInteractionStore.applySelectedSession(
                        sessionID: selectedSessionID,
                        sessions: targetStore.sessions,
                        syncState: targetStore.syncState
                    )
                }
            }
            refreshLiveActivityIfNeeded(for: selectedSession?.id)
        } catch {
            return
        }
    }

    func loadAllQuestions(for session: OpenCodeSession) async {
        if connectionStore.apiProfile == .v2 {
            await hydrateV2Interactions(for: session)
            return
        }
        if let connection = backendConnection, let service = connection.sessionForms,
           let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id),
           let ownerKey = directoryStoreRegistry.key(for: owner) {
            let generation = directoryStoreRegistry.generation
            let lifecycle = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
            let revision = owner.sessionFormStore.revision
            do {
                let forms = try await service.pendingForms(sessionID: session.id,
                    scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID))
                guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.contains(owner, forKey: ownerKey),
                      directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycle else { return }
                owner.applySessionForms(forms, sessionID: session.id, ifUnchangedSince: revision)
                if !forms.isEmpty { handleBackendEvent(.actionSignal(.needsAttention(sessionID: session.id))) }
            } catch { appendDebugLog("session form hydration failed") }
            return
        }
        await loadAllQuestions(directory: session.directory, workspaceID: session.workspaceID,
            canonicalOwner: directoryStoreRegistry.ownerStore(forSessionID: session.id))
    }

    var selectedSessionPermissions: [OpenCodePermission] {
        guard let selectedSession else { return [] }
        return permissions(for: selectedSession.id)
    }

    func permissions(for sessionID: String) -> [OpenCodePermission] {
        let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) ?? directoryStore
        let visiblePermissions = owner === directoryStore
            ? sessionInteractionStore.permissions(forSessionTreeRootID: sessionID, sessions: owner.sessions)
            : []
        if !visiblePermissions.isEmpty {
            return visiblePermissions
        }
        return SessionInteractionStore.permissions(
            forSessionTreeRootID: sessionID,
            sessions: owner.sessions,
            permissionsBySessionID: owner.syncState.permissionsBySessionID
        )
    }

    var selectedSessionQuestions: [OpenCodeQuestionRequest] {
        guard let selectedSession else { return [] }
        return questions(for: selectedSession.id)
    }

    func questions(for sessionID: String) -> [OpenCodeQuestionRequest] {
        let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) ?? directoryStore
        let visibleQuestions = owner === directoryStore
            ? sessionInteractionStore.questions(forSessionTreeRootID: sessionID, sessions: owner.sessions)
            : []
        if !visibleQuestions.isEmpty {
            return visibleQuestions
        }
        return SessionInteractionStore.questions(
            forSessionTreeRootID: sessionID,
            sessions: owner.sessions,
            questionsBySessionID: owner.syncState.questionsBySessionID
        )
    }

    func hasPermissionRequest(for session: OpenCodeSession) -> Bool {
        !permissions(for: session.id).isEmpty
    }

    func respondToPermission(_ permission: OpenCodePermission, response: String, windowContext: ChatWindowContext? = nil) async {
        guard windowContext?.isCurrent ?? true else { return }
        guard let client = compatibilityClient(for: .interactions) else { return }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let owner = directoryStoreRegistry.ownerStore(forSessionID: permission.sessionID) ?? directoryStore
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

            if connectionStore.apiProfile == .v2 {
                try await client.replyToV2Permission(
                    sessionID: permission.sessionID,
                    requestID: permission.id,
                    reply: reply
                )
                guard connectionStore.apiProfile == .v2, config == client.config, directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.key(for: owner) != nil else { return }
                withAnimation(opencodeSelectionAnimation) {
                    objectWillChange.send()
                    if directoryStore === owner, sessionNavigationGeneration == navigationGeneration {
                        sessionInteractionStore.removePermission(id: permission.id)
                    }
                    owner.removeV2Permission(id: permission.id, sessionID: permission.sessionID)
                }
                return
            }

            let session = session(matching: permission.sessionID)
            let directory = windowContext == nil ? session.flatMap(sendDirectory(for:)) : session?.directory
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
            guard directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration else { return }
            if let windowContext { windowContext.errorMessage = error.localizedDescription }
            else { errorMessage = error.localizedDescription }
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

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]], windowContext: ChatWindowContext? = nil) async {
        guard windowContext?.isCurrent ?? true else { return }
        guard let client = compatibilityClient(for: .interactions) else { return }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let owner = directoryStoreRegistry.ownerStore(forSessionID: request.sessionID) ?? directoryStore
        do {
            if connectionStore.apiProfile == .v2 {
                try await client.replyToV2Question(sessionID: request.sessionID, requestID: request.id, answers: answers)
                guard connectionStore.apiProfile == .v2, config == client.config, directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.key(for: owner) != nil else { return }
                withAnimation(opencodeSelectionAnimation) {
                    objectWillChange.send()
                    if directoryStore === owner, sessionNavigationGeneration == navigationGeneration {
                        sessionInteractionStore.removeQuestion(id: request.id)
                    }
                    owner.removeV2Question(id: request.id, sessionID: request.sessionID)
                }
                return
            }

            let session = session(matching: request.sessionID)
            let directory = windowContext == nil ? session.flatMap(sendDirectory(for:)) : session?.directory
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
            guard directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration else { return }
            if let windowContext { windowContext.errorMessage = error.localizedDescription }
            else { errorMessage = error.localizedDescription }
        }
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest, windowContext: ChatWindowContext? = nil) async {
        guard windowContext?.isCurrent ?? true else { return }
        guard let client = compatibilityClient(for: .interactions) else { return }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let owner = directoryStoreRegistry.ownerStore(forSessionID: request.sessionID) ?? directoryStore
        do {
            if connectionStore.apiProfile == .v2 {
                try await client.rejectV2Question(sessionID: request.sessionID, requestID: request.id)
                guard connectionStore.apiProfile == .v2, config == client.config, directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.key(for: owner) != nil else { return }
                withAnimation(opencodeSelectionAnimation) {
                    objectWillChange.send()
                    if directoryStore === owner, sessionNavigationGeneration == navigationGeneration {
                        sessionInteractionStore.removeQuestion(id: request.id)
                    }
                    owner.removeV2Question(id: request.id, sessionID: request.sessionID)
                }
                return
            }

            let session = session(matching: request.sessionID)
            let directory = windowContext == nil ? session.flatMap(sendDirectory(for:)) : session?.directory
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
            guard directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration else { return }
            if let windowContext { windowContext.errorMessage = error.localizedDescription }
            else { errorMessage = error.localizedDescription }
        }
    }

    @discardableResult
    func deleteSession(_ session: OpenCodeSession) async -> Bool {
        guard let connection = try? requireBackendConnection() else { return false }
        let scope = BackendScope(projectID: session.projectID, directory: sendDirectory(for: session), workspaceID: session.workspaceID)
        if connectionStore.apiProfile == .v2 {
            let generation = directoryStoreRegistry.generation
            let navigationGeneration = sessionNavigationGeneration
            do {
                try await connection.sessions.deleteSession(id: session.id, scope: scope)
                guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, directoryStoreRegistry.generation == generation else { return true }
                let wasSelected = selectedSession?.id == session.id
                directoryStoreRegistry.markV2SessionDeleted(session.id)
                if wasSelected { selectedSession = nil }
                for owner in directoryStoreRegistry.stores(containingSessionID: session.id) {
                    owner.removeV2Session(sessionID: session.id)
                }
                chatStore.clearCachedMessages(forSessionID: session.id)
                if wasSelected {
                    sessionNavigationGeneration &+= 1
                    chatStore.clearActiveTranscript()
                    _ = sessionInteractionStore.applyVisibleInteractions(todos: [], permissions: [], questions: [])
                }
                removePinnedSessionIDFromAllScopes(session.id)
                sessionListStore.removeRecentSession(sessionID: session.id)
                removeSessionPreview(for: session.id)
                clearPersistedMessageDraft(forSessionID: session.id)
                removeSessionFromLocalCache(session.id)
                removeWidgetSessionSnapshot(for: session.id)
                return true
            } catch {
                if isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration {
                    errorMessage = error.localizedDescription
                }
                return false
            }
        }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        var accepted = false
        do {
            try await connection.sessions.deleteSession(id: session.id, scope: scope)
            accepted = true
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation else { return true }
            withAnimation(opencodeSelectionAnimation) {
                removePinnedSessionIDFromAllScopes(session.id)
                sessionListStore.removeRecentSession(sessionID: session.id)
            }
            removeSessionPreview(for: session.id)
            if selectedSession?.id == session.id {
                persistCurrentMessageDraft(forSessionID: session.id)
                withAnimation(opencodeSelectionAnimation) {
                    selectedSession = nil
                    messages = []
                }
            }
            for owner in directoryStoreRegistry.stores(containingSessionID: session.id) {
                owner.removeV2Session(sessionID: session.id)
            }
            chatStore.clearCachedMessages(forSessionID: session.id)
            clearPersistedMessageDraft(forSessionID: session.id)
            removeSessionFromLocalCache(session.id)
            try await reloadSessions()
        } catch {
            if isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
               sessionNavigationGeneration == navigationGeneration { errorMessage = error.localizedDescription }
        }
        return accepted
    }

    func renameSession(_ session: OpenCodeSession, title: String) async {
        guard let connection = try? requireBackendConnection() else { return }
        let scope = BackendScope(projectID: session.projectID, directory: sendDirectory(for: session), workspaceID: session.workspaceID)
        if connectionStore.apiProfile == .v2 {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title != session.title else { return }
            let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
            let generation = directoryStoreRegistry.generation
            let revision = owner.v2SessionRevision
            let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
            let navigationGeneration = sessionNavigationGeneration
            do {
                let updated = try await connection.sessions.renameSession(id: session.id, title: title, scope: scope)
                guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2, directoryStoreRegistry.generation == generation,
                      directoryStoreRegistry.key(for: owner) != nil else { return }
                guard owner.v2SessionRevision == revision,
                      directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision else {
                    directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
                    scheduleV2TimelineReconciliation()
                    return
                }
                owner.insertV2Session(updated)
            } catch {
                if isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        let owner = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let previous = owner.sessions.first { $0.id == session.id }
        do {
            guard let renameSubmission = sessionCoordinator.prepareRenameSession(
                session: session,
                title: title,
                selectedDirectory: effectiveSelectedDirectory,
                currentProjectID: currentProject?.id
            ) else { return }
            let updatedSession = try await connection.sessions.renameSession(id: session.id, title: renameSubmission.title, scope: scope)
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                  directoryStoreRegistry.key(for: owner) != nil,
                  owner.sessions.first(where: { $0.id == session.id }) == previous else { return }
            _ = owner.upsertSessions([updatedSession])
            if selectedSession?.id == updatedSession.id {
                withAnimation(opencodeSelectionAnimation) {
                    selectedSession = updatedSession
                }
            }
            if (try? connection.requireOpenCodeClient(for: .localCache)) != nil {
                persistDirectoryToLocalCache(owner, directory: updatedSession.directory, marksValidated: false)
            }
            publishWidgetSnapshots()
        } catch {
            if isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
               sessionNavigationGeneration == navigationGeneration { errorMessage = error.localizedDescription }
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
        guard !isBrowsingLocalCache else { return }
        if connectionStore.apiProfile == .v2 {
            let owner = directoryStore
            let generation = directoryStoreRegistry.generation
            var seen = Set<String>()
            while let cursor = owner.nextSessionCursor, seen.insert(cursor).inserted {
                guard !Task.isCancelled, directoryStore === owner, directoryStoreRegistry.generation == generation else { return }
                do { try await reloadV2Sessions(replacing: false, cursor: cursor) }
                catch { return }
            }
            return
        }
        do {
            let connection = try requireBackendConnection()
            let key = directoryStoreRegistry.activeKey
            let generation = directoryStoreRegistry.generation
            let page = try await connection.sessions.sessions(scope: .init(projectID: currentProject?.id, directory: effectiveSelectedDirectory),
                cursor: nil, limit: Int.max, roots: false)
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                  directoryStoreRegistry.activeKey == key else { return }
            withAnimation(opencodeSelectionAnimation) {
                mergeSessions(page.sessions)
            }
        } catch {
            return
        }
    }

    func openSession(sessionID: String) async {
        guard let session = await sessionForPresentation(sessionID: sessionID) else { return }
        await selectSession(session)
    }

    func sessionForPresentation(sessionID: String) async -> OpenCodeSession? {
        if let session = session(matching: sessionID) {
            return session
        }

        guard !isBrowsingLocalCache else { return nil }
        guard let connection = try? requireBackendConnection() else { return nil }
        if connectionStore.apiProfile == .v2 {
            let generation = directoryStoreRegistry.generation
            let navigationGeneration = sessionNavigationGeneration
            let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
            do {
                let loaded = try await connection.sessions.session(id: sessionID, scope: .init(directory: effectiveSelectedDirectory))
                guard isCurrentBackendConnection(connection), connectionStore.apiProfile == .v2,
                      directoryStoreRegistry.generation == generation, sessionNavigationGeneration == navigationGeneration,
                      directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision else { return nil }
                directoryStoreRegistry.store(for: loaded.directory).insertV2Session(loaded)
                return loaded
            } catch { return nil }
        }
        let directory = selectedSession?.directory ?? streamDirectory ?? effectiveSelectedDirectory
        let generation = directoryStoreRegistry.generation
        let navigationGeneration = sessionNavigationGeneration
        do {
            let loaded = try await connection.sessions.session(id: sessionID, scope: .init(projectID: currentProject?.id, directory: directory))
            guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation,
                  sessionNavigationGeneration == navigationGeneration else { return nil }
            mergeSessions([loaded])
            return session(matching: sessionID) ?? loaded
        } catch {
            return nil
        }
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
            .sorted { OpenCodeMessage.isOrderedBefore($0.info, $1.info) }

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

        if session.title?.isEmpty == false {
            return session.displayTitle(fallback: "New Session").replacingOccurrences(of: #"\s+\(@[^)]+ subagent\)"#, with: "", options: .regularExpression)
        }

        return String(localized: "New Session")
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
        guard compatibilityClient(for: .interactions) != nil else { return }
        let connectionID = backendConnection?.id
        let generation = directoryStoreRegistry.generation
        let toolMessageIDs = chatStore.recentToolMessageIDs(in: messages, limit: 12)

        for messageID in toolMessageIDs where chatStore.reserveToolMessageDetailFetchIfNeeded(messageID: messageID) {
            Task { [weak self] in
                guard let self, self.backendConnection?.id == connectionID,
                      self.directoryStoreRegistry.generation == generation else { return }
                defer {
                    Task { @MainActor [weak self] in
                        self?.chatStore.finishToolMessageDetailFetch(messageID: messageID)
                    }
                }
                do {
                    let detail = try await self.fetchMessageDetails(sessionID: session.id, messageID: messageID)
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
        guard compatibilityClient(for: .interactions) != nil else { return }
        let toolMessageIDs = chatStore.recentToolMessageIDs(in: messages, limit: 20)

        for messageID in toolMessageIDs {
            do {
                toolMessageDetails[messageID] = try await fetchMessageDetails(sessionID: session.id, messageID: messageID)
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
            errorMessage = String(localized: "No Apple Intelligence workspace is active.")
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
            if appendOptimisticMessage {
                directoryStore.appendMessage(localUserMessage, forSessionID: session.id)
            }
            directoryStore.appendMessage(localAssistantMessage, forSessionID: session.id)
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
                    text: appleIntelligenceAvailabilitySummary ?? String(localized: "Apple Intelligence is unavailable."),
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
                    text: String(localized: "Apple Intelligence does not support the current device language or locale for this demo yet.")
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
                    throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Apple Intelligence is unavailable on this OS version.")])
                }
#else
                throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Apple Intelligence is unavailable on this build.")])
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
                        text: String(localized: "Apple Intelligence error: \(error.localizedDescription)")
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
        if let message = chatStore.messages.first(where: { $0.id == messageID }) {
            directoryStore.appendMessage(message, forSessionID: sessionID)
        }
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
                userInfo: [NSLocalizedDescriptionKey: String(localized: "The saved Apple Intelligence folder is no longer available. Please pick it again.")]
            )
        }

        return url
    }

    @available(iOS 26.0, macOS 26.0, *)
    func makeAppleIntelligenceResponseStream(intent: AppleIntelligenceIntent, prompt: String, rootURL: URL) throws -> LanguageModelSession.ResponseStream<String> {
#if canImport(FoundationModels)
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw NSError(domain: "AppleIntelligence", code: 1, userInfo: [NSLocalizedDescriptionKey: appleIntelligenceAvailabilitySummary ?? String(localized: "Apple Intelligence is unavailable.")])
        }
        guard model.supportsLocale(Locale.current) else {
            throw NSError(
                domain: "AppleIntelligence",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "Apple Intelligence does not support the current device language/locale for this model.")]
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
        throw NSError(domain: "AppleIntelligence", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Apple Intelligence is unavailable on this build.")])
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
            throw NSError(domain: "AppleIntelligence", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "Expected a file path, but received a directory.")])
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
