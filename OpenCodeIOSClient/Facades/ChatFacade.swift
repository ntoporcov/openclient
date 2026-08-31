import Combine
import Foundation

struct OpenClientChatWindowRoute: Codable, Hashable, Sendable {
    static let sceneID = "chat"

    let serverID: String
    let directoryKey: String
    let sessionID: String
}

enum OpenClientChatCommands {
    static let fork = OpenCodeCommand(
        name: "fork",
        description: String(localized: "Create a new session from a previous message"),
        agent: nil,
        model: nil,
        source: "client",
        template: "",
        subtask: false,
        hints: []
    )

    static let compact = OpenCodeCommand(
        name: "compact",
        description: String(localized: "Summarize the session context"),
        agent: nil,
        model: nil,
        source: "client",
        template: "",
        subtask: false,
        hints: []
    )
}

@MainActor
final class ChatFacade: ObservableObject {
    struct ChatComposerOverlaySnapshot {
        let todos: [OpenCodeTodo]
        let attachments: [OpenCodeComposerAttachment]
        let permissions: [OpenCodePermission]
        let questions: [OpenCodeQuestionRequest]

        var showsAccessoryArea: Bool {
            todos.contains { !$0.isComplete } || !attachments.isEmpty
        }

        var attachmentIDs: [String] {
            attachments.map(\.id)
        }

        var incompleteTodoIDs: [String] {
            todos.filter { !$0.isComplete }.map(\.id)
        }
    }

    struct ChatComposerSnapshot {
        let commands: [OpenCodeCommand]
        let attachmentCount: Int
        let isBusy: Bool
        let canFork: Bool
        let forkableMessages: [OpenCodeForkableMessage]
        let forkSignature: String
        let mcp: MCPFacade.Snapshot
        let mcpSignature: String
        let actionSignature: String
    }

    struct ChatSessionHeaderSnapshot {
        let session: OpenCodeSession
        let isChildSession: Bool
        let parentSession: OpenCodeSession?
        let parentTitle: String
        let childTitle: String
        let shimmersNavigationTitle: Bool

        var navigationTitle: String {
            isChildSession ? childTitle : session.displayTitle(fallback: String(localized: "Session"))
        }
    }

    struct ToolbarProviderGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let models: [OpenCodeModel]
    }

    struct ToolbarReasoningVariant: Identifiable, Equatable {
        let id: String
        let title: String
    }

    struct ToolbarSnapshot: Equatable {
        let selectableAgents: [OpenCodeAgent]
        let providerGroups: [ToolbarProviderGroup]
        let reasoningVariants: [ToolbarReasoningVariant]
        let selectedAgentName: String?
        let selectedModelReference: OpenCodeModelReference?
        let selectedReasoningVariant: String?
        let agentTitle: String
        let modelTitle: String
        let reasoningTitle: String
        let isAgentLoading: Bool
        let isModelLoading: Bool
        let isLoading: Bool
        let showsAgentMenu: Bool
    }

    struct ChildSessionToolbarSnapshot: Equatable {
        let agentTitle: String
        let modelTitle: String
    }

    struct TodoInspectorSnapshot: Equatable {
        let selectedSessionID: String?
        let todos: [OpenCodeTodo]
    }

    struct ForkSessionSnapshot: Equatable {
        let messages: [OpenCodeForkableMessage]
        let pendingMessageID: String?
    }

    let connectionStore: ConnectionStore
    let appCustomizationStore: AppCustomizationStore
    let speechVoiceStore: SpeechVoiceStore
    let projectStore: ProjectStore
    let sessionListStore: SessionListStore
    let chatStore: ChatStore
    let sessionInteractionStore: SessionInteractionStore
    let composerStore: ComposerStore
    let modelConfigurationStore: ModelConfigurationStore
    let mcpStore: MCPStore
    let funAndGamesStore: FunAndGamesStore
    let chatPresentationStore: ChatPresentationStore
    let mcpFacade: MCPFacade

    private unowned let viewModel: AppViewModel
    private weak var liveActivityBackgroundBridge: LiveActivityBackgroundBridge?
    private var observations: Set<AnyCancellable> = []
    private var activeDirectoryObservations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        connectionStore = viewModel.connectionStore
        appCustomizationStore = viewModel.appCustomizationStore
        speechVoiceStore = viewModel.speechVoiceStore
        projectStore = viewModel.projectStore
        sessionListStore = viewModel.sessionListStore
        chatStore = viewModel.chatStore
        sessionInteractionStore = viewModel.sessionInteractionStore
        composerStore = viewModel.composerStore
        modelConfigurationStore = viewModel.modelConfigurationStore
        mcpStore = viewModel.mcpStore
        funAndGamesStore = viewModel.funAndGamesStore
        chatPresentationStore = viewModel.chatPresentationStore
        mcpFacade = viewModel.mcpFacade
        Publishers.MergeMany([
            viewModel.objectWillChange.eraseToAnyPublisher(),
            viewModel.appCustomizationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.chatStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.funAndGamesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.sessionInteractionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.chatPresentationStore.objectWillChange.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        bindActiveDirectoryStore(viewModel.directoryStoreRegistry.activeStore)
        viewModel.directoryStoreRegistry.$activeStore
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] store in
                self?.bindActiveDirectoryStore(store)
                self?.objectWillChange.send()
            }
            .store(in: &observations)
    }

    func attachLiveActivityBackgroundBridge(_ bridge: LiveActivityBackgroundBridge) {
        liveActivityBackgroundBridge = bridge
    }

    func directoryStore(forSessionID sessionID: String, preferredDirectoryKey: String? = nil) -> DirectoryStore {
        if let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: sessionID) {
            return owner
        }
        if let preferredDirectoryKey {
            return viewModel.directoryStoreRegistry.store(
                for: DirectoryStoreRegistry.directory(forKey: preferredDirectoryKey)
            )
        }
        return viewModel.directoryStoreRegistry.activeStore
    }

    func windowRoute(for session: OpenCodeSession) -> OpenClientChatWindowRoute {
        let ownerKey = viewModel.directoryStoreRegistry
            .ownerStore(forSessionID: session.id)
            .flatMap { viewModel.directoryStoreRegistry.key(for: $0) }
        return OpenClientChatWindowRoute(
            serverID: viewModel.config.recentServerID,
            directoryKey: ownerKey ?? DirectoryStoreRegistry.key(for: session.directory),
            sessionID: session.id
        )
    }

    var activeChatSessionID: String? {
        viewModel.activeChatSessionID
    }

    var showsChatActivityShimmer: Bool {
        appCustomizationStore.showsChatActivityShimmer
    }

    var isReadOnly: Bool {
        connectionStore.backendMode == .cachedServer
    }

    func setActiveChatSessionID(_ sessionID: String) {
        viewModel.activeChatSessionID = sessionID
    }

    func clearActiveChatSessionIfMatching(_ sessionID: String) {
        guard viewModel.activeChatSessionID == sessionID else { return }
        viewModel.activeChatSessionID = nil
    }

    var activeAppleIntelligenceWorkspaceID: String? {
        viewModel.activeAppleIntelligenceWorkspaceID
    }

    var defaultAppleIntelligenceUserInstructions: String {
        viewModel.defaultAppleIntelligenceUserInstructions
    }

    var defaultAppleIntelligenceSystemInstructions: String {
        viewModel.defaultAppleIntelligenceSystemInstructions
    }

    var isRunningDebugProbe: Bool {
        viewModel.isRunningDebugProbe
    }

    var debugProbeLogCount: Int {
        viewModel.debugProbeLog.count
    }

    var chatBreadcrumbCount: Int {
        viewModel.chatBreadcrumbs.count
    }

    func composerOverlaySnapshot(forSessionID sessionID: String) -> ChatComposerOverlaySnapshot {
        let directoryStore = directoryStore(forSessionID: sessionID)
        return ChatComposerOverlaySnapshot(
            todos: sessionInteractionStore.todos,
            attachments: composerStore.draftAttachments,
            permissions: sessionInteractionStore.permissions(
                forSessionTreeRootID: sessionID,
                sessions: directoryStore.sessions
            ),
            questions: sessionInteractionStore.questions(
                forSessionTreeRootID: sessionID,
                sessions: directoryStore.sessions
            )
        )
    }

    func composerSnapshot(
        for session: OpenCodeSession,
        isBusy: Bool,
        forkableMessages: [OpenCodeForkableMessage]
    ) -> ChatComposerSnapshot {
        let canFork = !forkableMessages.isEmpty
        let commands = commands(forSessionID: session.id, canFork: canFork)
        let forkSignature = forkableMessages
            .map { "\($0.id):\($0.text):\($0.created ?? 0)" }
            .joined(separator: "|")
        let mcpSnapshot = mcpFacade.snapshot
        let mcpSignature = mcpSnapshot.servers
            .map { "\($0.name):\($0.status.status):\($0.status.error ?? "")" }
            .joined(separator: "|") + "|loading=\(mcpSnapshot.isLoading)|toggling=\(mcpSnapshot.togglingServerNames.sorted().joined(separator: ","))|error=\(mcpSnapshot.errorMessage ?? "")"
        let actionSignature = [
            session.id,
            session.directory ?? "",
            session.workspaceID ?? "",
            session.projectID ?? "",
            session.parentID ?? ""
        ].joined(separator: "|")

        return ChatComposerSnapshot(
            commands: commands,
            attachmentCount: composerStore.draftAttachments.count,
            isBusy: isBusy,
            canFork: canFork,
            forkableMessages: forkableMessages,
            forkSignature: forkSignature,
            mcp: mcpSnapshot,
            mcpSignature: mcpSignature,
            actionSignature: actionSignature
        )
    }

    func headerSnapshot(for session: OpenCodeSession) -> ChatSessionHeaderSnapshot {
        let parent = viewModel.parentSession(for: session)
        return ChatSessionHeaderSnapshot(
            session: session,
            isChildSession: session.parentID != nil,
            parentSession: parent,
            parentTitle: parent?.displayTitle(fallback: String(localized: "Session")) ?? String(localized: "Session"),
            childTitle: viewModel.childSessionTitle(for: session),
            shimmersNavigationTitle: session.isDefaultGeneratedTitle && viewModel.latestTaskDescription(for: session) == nil
        )
    }

    func commands(forSessionID sessionID: String, canFork: Bool) -> [OpenCodeCommand] {
        let store = directoryStore(forSessionID: sessionID)
        var result = store.commands
        if store.selectedSession != nil, !result.contains(where: { $0.name == "compact" }) {
            result.append(OpenClientChatCommands.compact)
        }
        if store.selectedSession != nil, canFork, !result.contains(where: { $0.name == "fork" }) {
            result.append(OpenClientChatCommands.fork)
        }
        return result
    }

    func preferenceScopeKey() -> String {
        if connectionStore.backendMode == .appleIntelligence {
            return [
                "apple-intelligence",
                viewModel.activeAppleIntelligenceWorkspaceID ?? "global",
            ].joined(separator: "|")
        }

        let directory: String?
        if let selectedDirectory = projectStore.selectedDirectory, !selectedDirectory.isEmpty {
            directory = selectedDirectory
        } else if let currentProject = projectStore.currentProject, currentProject.id != "global" {
            directory = currentProject.worktree
        } else {
            directory = nil
        }

        return [
            "server",
            viewModel.config.recentServerID,
            directory ?? "global",
        ].joined(separator: "|")
    }

    func appendDebugLog(_ message: String) {
        viewModel.appendDebugLog(message)
    }

    func markChatBreadcrumb(
        _ event: String,
        sessionID: String? = nil,
        messageID: String? = nil,
        partID: String? = nil
    ) {
        viewModel.markChatBreadcrumb(
            event,
            sessionID: sessionID,
            messageID: messageID,
            partID: partID
        )
    }

    func startDebugProbe() async {
        await viewModel.startDebugProbe()
    }

    func dismissDebugProbe() {
        viewModel.isShowingDebugProbe = false
    }

    func copyDebugProbeLog() -> String {
        viewModel.copyDebugProbeLog()
    }

    func copyChatBreadcrumbs() -> String {
        viewModel.copyChatBreadcrumbs()
    }

    func setComposerStreamingFocus(_ isFocused: Bool) {
        viewModel.setComposerStreamingFocus(isFocused)
    }

    func flushBufferedTranscript(reason: String) {
        viewModel.flushBufferedTranscript(reason: reason)
    }

    func saveMessageDraft(
        _ text: String,
        agentMentions: [OpenCodeAgentMention]? = nil,
        forSessionID sessionID: String,
        removesEmpty: Bool = true,
        updateActiveDraft: Bool = true
    ) {
        viewModel.saveMessageDraft(
            text,
            agentMentions: agentMentions,
            forSessionID: sessionID,
            removesEmpty: removesEmpty,
            updateActiveDraft: updateActiveDraft
        )
    }

    func resetComposer() {
        viewModel.composerResetToken = UUID()
    }

    func setDraftAgentMentions(_ mentions: [OpenCodeAgentMention], forSessionID sessionID: String) {
        viewModel.setDraftAgentMentions(mentions, forSessionID: sessionID)
    }

    func addDraftAttachments(_ attachments: [OpenCodeComposerAttachment]) {
        viewModel.addDraftAttachments(attachments)
    }

    func removeDraftAttachment(_ attachment: OpenCodeComposerAttachment) {
        viewModel.removeDraftAttachment(attachment)
    }

    func clearDraftAttachments() {
        viewModel.clearDraftAttachments()
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        guard !isReadOnly else { return }
        viewModel.dismissPermission(permission)
    }

    func respondToPermission(_ permission: OpenCodePermission, response: String) async {
        guard !isReadOnly else { return }
        await viewModel.respondToPermission(permission, response: response)
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest) async {
        guard !isReadOnly else { return }
        await viewModel.dismissQuestion(request)
    }

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]]) async {
        guard !isReadOnly else { return }
        await viewModel.respondToQuestion(request, answers: answers)
    }

    func isForkClientCommand(_ command: OpenCodeCommand) -> Bool {
        viewModel.isForkClientCommand(command)
    }

    func isCompactClientCommand(_ command: OpenCodeCommand) -> Bool {
        viewModel.isCompactClientCommand(command)
    }

    func shouldOpenForkSheet(forSlashInput text: String) -> Bool {
        viewModel.shouldOpenForkSheet(forSlashInput: text)
    }

    func slashCommandInput(from text: String) -> (command: OpenCodeCommand, arguments: String)? {
        viewModel.slashCommandInput(from: text)
    }

    func presentForkSessionSheet() {
        guard !isReadOnly else { return }
        viewModel.presentForkSessionSheet()
    }

    func shouldMeterPrompts(for sessionID: String) -> Bool {
        viewModel.shouldMeterPrompts(for: sessionID)
    }

    func reserveUserPromptIfAllowed() -> Bool {
        viewModel.reserveUserPromptIfAllowed()
    }

    func refundReservedUserPromptIfNeeded() {
        viewModel.refundReservedUserPromptIfNeeded()
    }

    @discardableResult
    func compactSession(
        sessionID: String,
        userVisible: Bool,
        meterPrompt: Bool = true,
        restoreDraftOnFailure: Bool = true
    ) async -> Bool {
        guard !isReadOnly else { return false }
        let intent = armLiveActivityBackgroundBridge(sessionID: sessionID, userVisible: userVisible)
        let accepted = await viewModel.compactSession(
            sessionID: sessionID,
            userVisible: userVisible,
            meterPrompt: meterPrompt,
            restoreDraftOnFailure: restoreDraftOnFailure
        )
        resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: sessionID)
        return accepted
    }

    @discardableResult
    func sendCommand(
        _ command: OpenCodeCommand,
        sessionID: String,
        userVisible: Bool,
        meterPrompt: Bool = true,
        restoreDraftOnFailure: Bool = true
    ) async -> Bool {
        guard !isReadOnly else { return false }
        let intent = armLiveActivityBackgroundBridge(sessionID: sessionID, userVisible: userVisible)
        let accepted = await viewModel.sendCommand(
            command,
            sessionID: sessionID,
            userVisible: userVisible,
            meterPrompt: meterPrompt,
            restoreDraftOnFailure: restoreDraftOnFailure
        )
        resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: sessionID)
        return accepted
    }

    func loadMCPStatusIfNeeded() async {
        await mcpFacade.loadIfNeeded()
    }

    func toggleMCPServer(name: String) async {
        guard !isReadOnly else { return }
        await mcpFacade.toggleServer(name: name)
    }

    func forkPromptText(from message: OpenCodeMessageEnvelope) -> String {
        viewModel.sessionCoordinator.forkPromptDraft(from: message).text
    }

    func selectSession(_ session: OpenCodeSession) async {
        await viewModel.selectSession(session)
    }

    func refreshChatData(for sessionID: String) async {
        guard !isReadOnly else { return }
        await viewModel.refreshChatData(for: sessionID)
    }

    func resolveTaskSessionID(from part: OpenCodePart, currentSessionID: String) -> String? {
        viewModel.resolveTaskSessionID(from: part, currentSessionID: currentSessionID)
    }

    func openSession(sessionID: String) async {
        await viewModel.openSession(sessionID: sessionID)
    }

    func sessionForPresentation(sessionID: String) async -> OpenCodeSession? {
        await viewModel.sessionForPresentation(sessionID: sessionID)
    }

    func hydrateSessionForPresentation(_ session: OpenCodeSession) async {
        guard !isReadOnly else { return }
        try? await viewModel.loadMessages(
            for: session,
            prefetchToolDetails: false,
            refreshTodos: false
        )
    }

    func hasOlderMessages(forSessionID sessionID: String) -> Bool {
        chatStore.hasOlderMessages(forSessionID: sessionID)
    }

    func isLoadingOlderMessages(forSessionID sessionID: String) -> Bool {
        chatStore.isLoadingOlderMessages(forSessionID: sessionID)
    }

    @discardableResult
    func loadOlderMessages(for session: OpenCodeSession, count: Int) async -> Int {
        await viewModel.loadOlderMessages(for: session, count: count)
    }

    @discardableResult
    func insertOptimisticUserMessage(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        in session: OpenCodeSession,
        messageID: String? = nil,
        partID: String? = nil,
        animated: Bool = true
    ) -> (messageID: String, partID: String) {
        viewModel.insertOptimisticUserMessage(
            text,
            agentMentions: agentMentions,
            attachments: attachments,
            in: session,
            messageID: messageID,
            partID: partID,
            animated: animated
        )
    }

    @discardableResult
    func sendMessage(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        in session: OpenCodeSession,
        userVisible: Bool,
        messageID: String? = nil,
        partID: String? = nil,
        appendOptimisticMessage: Bool = true,
        meterPrompt: Bool = true
    ) async -> Bool {
        guard !isReadOnly else { return false }
        let intent = armLiveActivityBackgroundBridge(sessionID: session.id, userVisible: userVisible)
        let accepted = await viewModel.sendMessage(
            text,
            agentMentions: agentMentions,
            attachments: attachments,
            in: session,
            userVisible: userVisible,
            messageID: messageID,
            partID: partID,
            appendOptimisticMessage: appendOptimisticMessage,
            meterPrompt: meterPrompt
        )
        resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: session.id)
        return accepted
    }

    func removeOptimisticUserMessage(messageID: String, sessionID: String) {
        viewModel.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
    }

    func stopSession(_ session: OpenCodeSession) async {
        guard !isReadOnly else { return }
        let accepted = await viewModel.stopSession(session)
        if accepted {
            liveActivityBackgroundBridge?.cancel(sessionID: session.id, reason: "Stopped")
        }
    }

    private func armLiveActivityBackgroundBridge(
        sessionID: String,
        userVisible: Bool
    ) -> LiveActivityBackgroundBridge.Intent? {
        guard userVisible,
              viewModel.backendMode == .server,
              !viewModel.isUsingAppleIntelligence else { return nil }
        return liveActivityBackgroundBridge?.arm(sessionID: sessionID)
    }

    private func resolveLiveActivityBackgroundBridge(
        _ intent: LiveActivityBackgroundBridge.Intent?,
        accepted: Bool,
        sessionID: String
    ) {
        liveActivityBackgroundBridge?.resolve(
            intent,
            accepted: accepted,
            hasLiveActivity: viewModel.liveActivityFacade.isActive(sessionID: sessionID)
        )
    }

    func leaveAppleIntelligenceSession() {
        viewModel.leaveAppleIntelligenceSession()
    }

    var todoInspectorSnapshot: TodoInspectorSnapshot {
        let directoryStore = viewModel.directoryStoreRegistry.activeStore
        guard let selectedSessionID = directoryStore.selectedSession?.id else {
            return TodoInspectorSnapshot(selectedSessionID: nil, todos: [])
        }
        return TodoInspectorSnapshot(
            selectedSessionID: selectedSessionID,
            todos: directoryStore.syncState.todosBySessionID[selectedSessionID]
                ?? viewModel.sessionInteractionStore.todos
        )
    }

    var forkSessionSnapshot: ForkSessionSnapshot {
        ForkSessionSnapshot(
            messages: viewModel.forkableMessages,
            pendingMessageID: viewModel.chatPresentationStore.pendingForkMessageID
        )
    }

    func fetchMessageDetails(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        try await viewModel.fetchMessageDetails(sessionID: sessionID, messageID: messageID)
    }

    func refreshTodosAndLatestTodoMessage() async throws -> (todos: [OpenCodeTodo], detail: OpenCodeMessageEnvelope?) {
        try await viewModel.refreshTodosAndLatestTodoMessage()
    }

    func forkSelectedSession(from messageID: String) async {
        guard !isReadOnly else { return }
        await viewModel.forkSelectedSession(from: messageID)
    }

    func dismissForkSessionSheet() {
        viewModel.isShowingForkSessionSheet = false
    }

    func toolbarSnapshot(for session: OpenCodeSession) -> ToolbarSnapshot {
        let store = viewModel.modelConfigurationStore
        let lastUserMessage = lastUserMessage(for: session)
        let selectedAgentName = store.selectedAgentName(for: session.id)
        let selectedModelReference = store.selectedModelReference(for: session.id)
        let selectedReasoningVariant = store.selectedVariant(for: session.id)
        let isAgentLoading = isAgentToolbarLoading(
            for: session,
            selectedAgentName: selectedAgentName,
            lastUserMessage: lastUserMessage
        )
        let isModelLoading = isModelToolbarLoading(
            for: session,
            selectedModelReference: selectedModelReference,
            lastUserMessage: lastUserMessage
        )
        let reasoningVariants = store.reasoningVariants(forSessionID: session.id).map { variant in
            ToolbarReasoningVariant(id: variant, title: store.formattedVariantTitle(variant))
        }

        return ToolbarSnapshot(
            selectableAgents: store.selectableAgents,
            providerGroups: store.sortedProviders.map { provider in
                ToolbarProviderGroup(
                    id: provider.id,
                    name: provider.name,
                    models: store.visibleModels(for: provider)
                )
            },
            reasoningVariants: reasoningVariants,
            selectedAgentName: selectedAgentName,
            selectedModelReference: selectedModelReference,
            selectedReasoningVariant: selectedReasoningVariant,
            agentTitle: agentToolbarTitle(
                for: session,
                selectedAgentName: selectedAgentName,
                lastUserMessage: lastUserMessage,
                isLoading: isAgentLoading
            ),
            modelTitle: modelToolbarTitle(
                for: session,
                selectedModelReference: selectedModelReference,
                lastUserMessage: lastUserMessage,
                isLoading: isModelLoading
            ),
            reasoningTitle: selectedReasoningVariant.map(store.formattedVariantTitle) ?? String(localized: "Default"),
            isAgentLoading: isAgentLoading,
            isModelLoading: isModelLoading,
            isLoading: isAgentLoading || isModelLoading,
            showsAgentMenu: viewModel.funAndGamesStore.findPlaceGame(for: session.id) == nil
                && viewModel.funAndGamesStore.findBugGame(for: session.id) == nil
        )
    }

    func childSessionToolbarSnapshot(for session: OpenCodeSession) -> ChildSessionToolbarSnapshot {
        let messages = messageSource(for: session)
        let agentTitle = messages.reversed().compactMap { message -> String? in
            guard message.info.sessionID == session.id else { return nil }
            let agent = message.info.agent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return agent.isEmpty ? nil : agent
        }.first ?? String(localized: "Subagent")

        let modelReference = messages.reversed().compactMap { message -> OpenCodeModelReference? in
            guard message.info.sessionID == session.id else { return nil }
            if let model = message.info.model {
                return OpenCodeModelReference(providerID: model.providerID, modelID: model.modelID)
            }
            guard let providerID = message.info.providerID,
                  let modelID = message.info.modelID else { return nil }
            return OpenCodeModelReference(providerID: providerID, modelID: modelID)
        }.first
        let modelTitle = viewModel.modelConfigurationStore.model(for: modelReference)?.name
            ?? modelReference?.modelID
            ?? String(localized: "Model")

        return ChildSessionToolbarSnapshot(agentTitle: agentTitle, modelTitle: modelTitle)
    }

    func reasoningVariants(for session: OpenCodeSession) -> [String] {
        viewModel.modelConfigurationStore.reasoningVariants(forSessionID: session.id)
    }

    func reasoningTitle(for session: OpenCodeSession) -> String {
        guard let variant = viewModel.modelConfigurationStore.selectedVariant(for: session.id) else {
            return String(localized: "Default")
        }
        return viewModel.modelConfigurationStore.formattedVariantTitle(variant)
    }

    func selectAgent(named name: String?, for session: OpenCodeSession) {
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectAgent(named: name, forSessionID: session.id)
    }

    func selectModel(_ reference: OpenCodeModelReference?, for session: OpenCodeSession) {
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectModel(reference, forSessionID: session.id)
    }

    func selectReasoningVariant(_ variant: String?, for session: OpenCodeSession) {
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectVariant(variant, forSessionID: session.id)
    }

    func messageSource(for session: OpenCodeSession) -> [OpenCodeMessageEnvelope] {
        let directoryStore = directoryStore(forSessionID: session.id)
        if directoryStore.selectedSession?.id == session.id,
           viewModel.chatStore.preparedSessionID == session.id,
           viewModel.chatStore.messages.contains(where: {
               $0.info.sessionID == session.id && ($0.info.role ?? "").lowercased() == "user"
           }) {
            return viewModel.chatStore.messages
        }
        let syncedMessages = directoryStore.syncState.messageEnvelopes(forSessionID: session.id)
        if !syncedMessages.isEmpty { return syncedMessages }
        if let cachedMessages = viewModel.cachedMessagesBySessionID[session.id], !cachedMessages.isEmpty { return cachedMessages }
        if directoryStore.selectedSession?.id == session.id { return viewModel.messages }
        return []
    }

    private func lastUserMessage(for session: OpenCodeSession) -> OpenCodeMessageEnvelope? {
        messageSource(for: session).reversed().first { message in
            message.info.sessionID == session.id && (message.info.role ?? "").lowercased() == "user"
        }
    }

    private func isAgentToolbarLoading(
        for session: OpenCodeSession,
        selectedAgentName: String?,
        lastUserMessage: OpenCodeMessageEnvelope?
    ) -> Bool {
        guard !viewModel.isFunAndGamesSession(session.id) else { return false }
        guard directoryStore(forSessionID: session.id).selectedSession?.id == session.id else { return false }
        guard viewModel.chatStore.isLoadingSelectedSession else { return false }
        return selectedAgentName == nil && lastUserMessage?.info.agent == nil
    }

    private func isModelToolbarLoading(
        for session: OpenCodeSession,
        selectedModelReference: OpenCodeModelReference?,
        lastUserMessage: OpenCodeMessageEnvelope?
    ) -> Bool {
        guard directoryStore(forSessionID: session.id).selectedSession?.id == session.id else { return false }
        guard viewModel.chatStore.isLoadingSelectedSession else { return false }
        return selectedModelReference == nil && lastUserMessage?.info.model == nil
    }

    private func agentToolbarTitle(
        for session: OpenCodeSession,
        selectedAgentName: String?,
        lastUserMessage: OpenCodeMessageEnvelope?,
        isLoading: Bool
    ) -> String {
        if viewModel.isKnownFunAndGamesSession(session.id) {
            return "plan"
        }
        if let selectedAgentName {
            return selectedAgentName
        }
        if let agent = lastUserMessage?.info.agent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            return agent
        }
        guard !isLoading else { return String(localized: "Agent") }
        return viewModel.modelConfigurationStore.effectiveAgentName(for: session.id) ?? String(localized: "Agent")
    }

    private func modelToolbarTitle(
        for session: OpenCodeSession,
        selectedModelReference: OpenCodeModelReference?,
        lastUserMessage: OpenCodeMessageEnvelope?,
        isLoading: Bool
    ) -> String {
        let store = viewModel.modelConfigurationStore
        if let selectedModel = store.model(for: selectedModelReference) {
            return selectedModel.name
        }
        if let messageModel = lastUserMessage?.info.model {
            let reference = OpenCodeModelReference(providerID: messageModel.providerID, modelID: messageModel.modelID)
            return store.model(for: reference)?.name ?? messageModel.modelID
        }
        guard !isLoading else { return String(localized: "Model") }
        return store.effectiveModel(for: session.id)?.name ?? String(localized: "Model")
    }

    private func bindActiveDirectoryStore(_ store: DirectoryStore) {
        activeDirectoryObservations.removeAll()
        Publishers.Merge(
            store.objectWillChange.eraseToAnyPublisher(),
            store.syncStore.objectWillChange.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &activeDirectoryObservations)
    }
}
