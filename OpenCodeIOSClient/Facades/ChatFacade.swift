import Combine
import Foundation

struct OpenClientChatWindowRoute: Codable, Hashable, Sendable {
    static let sceneID = "chat"

    let serverID: String
    let directoryKey: String
    let sessionID: String
    let apiProfile: OpenCodeAPIProfile?
    let canonicalDirectoryKey: String?
    let workspaceID: String?

    init(serverID: String, directoryKey: String, sessionID: String, apiProfile: OpenCodeAPIProfile? = nil,
         canonicalDirectoryKey: String? = nil, workspaceID: String? = nil) {
        self.serverID = serverID
        self.directoryKey = directoryKey
        self.sessionID = sessionID
        self.apiProfile = apiProfile
        self.canonicalDirectoryKey = canonicalDirectoryKey
        self.workspaceID = workspaceID
    }
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
    let foregroundChatRefreshCoordinator = ForegroundChatRefreshCoordinator()
    let windowContext: ChatWindowContext?

    var selectedSession: OpenCodeSession? {
        if let windowContext {
            return windowContext.isCurrent ? windowContext.owner.sessions.first { $0.id == windowContext.session.id } : nil
        }
        return viewModel.selectedSession
    }

    var presentationMessages: [OpenCodeMessageEnvelope] {
        if let windowContext {
            guard windowContext.isCurrent else { return [] }
            let messages = windowContext.owner.syncState.messageEnvelopes(forSessionID: windowContext.session.id)
            return chatStore.withoutRecoveryMessages(messages, sessionID: windowContext.session.id)
        }
        guard let session = selectedSession else { return [] }
        return chatStore.withoutRecoveryMessages(messageSource(for: session), sessionID: session.id)
    }

    var isLoadingPresentation: Bool { windowContext?.isLoading ?? chatStore.isLoadingSelectedSession }
    var presentationErrorMessage: String? {
        if let windowContext { return windowContext.errorMessage }
        return connectionStore.errorMessage
    }

    var sessionSwitcherPresentation: OpenClientSessionSwitcherPresentation? {
        if let windowContext { return windowContext.sessionSwitcherPresentation }
        return viewModel.directoryStore.sessionSwitcherPresentation
    }

    func advanceSessionSwitcher(from sessionID: String) -> OpenCodeSession? {
        if let windowContext { return windowContext.advanceSessionSwitcher() }
        return viewModel.directoryStore.advanceSessionSwitcher(from: sessionID)
    }

    func monitorSessionSwitcher() {
        let monitor = windowContext?.commandHoldMonitor ?? .shared
        let rootOwner = viewModel.directoryStore
        monitor.monitor(onHold: { [weak self] in
            guard let self else { return }
            if let windowContext = self.windowContext { windowContext.revealSessionSwitcher() }
            else { rootOwner.revealSessionSwitcher() }
        }, onRelease: { [weak self] in
            guard let self else { return }
            let target: OpenCodeSession?
            if let windowContext = self.windowContext { target = windowContext.finishSessionSwitcher() }
            else { target = rootOwner.finishSessionSwitcher() }
            if let target { Task { await self.selectSession(target) } }
        })
    }

    func previouslyOpenedSession(excluding sessionID: String) -> OpenCodeSession? {
        if let windowContext { return windowContext.history.reversed().first { $0.id != sessionID } }
        return viewModel.directoryStore.previouslyOpenedSession(excluding: sessionID)
    }

    private unowned let viewModel: AppViewModel
    private weak var liveActivityBackgroundBridge: LiveActivityBackgroundBridge?
    private var observations: Set<AnyCancellable> = []
    private var activeDirectoryObservations: Set<AnyCancellable> = []
    // The app's root facade owns canonical configuration work, not any window presentation.
    private var configurationTasksByConnectionID: [UUID: [String: (id: UUID, task: Task<Bool, Never>)]] = [:]
    var v2ConfigurationTasks: [String: (id: UUID, task: Task<Bool, Never>)] {
        guard let connectionID = viewModel.backendConnection?.id else { return [:] }
        return viewModel.chatFacade.configurationTasksByConnectionID[connectionID] ?? [:]
    }

    init(viewModel: AppViewModel, windowContext: ChatWindowContext? = nil) {
        self.viewModel = viewModel
        self.windowContext = windowContext
        connectionStore = viewModel.connectionStore
        appCustomizationStore = viewModel.appCustomizationStore
        speechVoiceStore = viewModel.speechVoiceStore
        projectStore = viewModel.projectStore
        sessionListStore = viewModel.sessionListStore
        chatStore = viewModel.chatStore
        sessionInteractionStore = viewModel.sessionInteractionStore
        composerStore = windowContext?.composer ?? viewModel.composerStore
        modelConfigurationStore = viewModel.modelConfigurationStore
        mcpStore = windowContext?.mcpStore ?? viewModel.mcpStore
        funAndGamesStore = viewModel.funAndGamesStore
        chatPresentationStore = windowContext?.presentation ?? viewModel.chatPresentationStore
        mcpFacade = windowContext?.mcpFacade ?? viewModel.mcpFacade
        Publishers.MergeMany([
            viewModel.objectWillChange.eraseToAnyPublisher(),
            viewModel.appCustomizationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.chatStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.funAndGamesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.sessionInteractionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.chatPresentationStore.objectWillChange.eraseToAnyPublisher(),
            mcpStore.objectWillChange.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        if let windowContext {
            windowContext.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observations)
            windowContext.$owner.sink { [weak self] owner in self?.bindActiveDirectoryStore(owner) }
                .store(in: &observations)
            return
        }
        connectionStore.$apiProfile.removeDuplicates().sink { [weak self] profile in
            if profile != .v2 { self?.cancelConfigurationTasks() }
        }.store(in: &observations)
        viewModel.$backendConnection.dropFirst().sink { [weak self] _ in self?.cancelConfigurationTasks() }
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
        if let windowContext, windowContext.session.id == sessionID { return windowContext.owner }
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
            serverID: viewModel.backendConnection?.openCodeCompatibility?.client.config.recentServerID ?? viewModel.config.recentServerID,
            directoryKey: ownerKey ?? DirectoryStoreRegistry.key(for: session.directory),
            sessionID: session.id,
            apiProfile: viewModel.backendConnection?.openCodeCompatibility?.profile,
            canonicalDirectoryKey: DirectoryStoreRegistry.key(for: session.directory),
            workspaceID: session.workspaceID
        )
    }

    var activeChatSessionID: String? {
        if let windowContext { return windowContext.isCurrent ? windowContext.session.id : nil }
        return viewModel.activeChatSessionID
    }

    var showsChatActivityShimmer: Bool {
        appCustomizationStore.showsChatActivityShimmer
    }

    var isReadOnly: Bool {
        connectionStore.backendMode == .cachedServer || (windowContext.map { !$0.isCurrent } ?? false)
    }

    var isPaywallPresented: Bool { viewModel.commerceFacade.paywallReason != nil }
    var supportsTalkLiveActivities: Bool { viewModel.liveActivityFacade.supportsLiveActivities }

    var isV2Connection: Bool { connectionStore.apiProfile == .v2 }

    var promptConnectionID: UUID? {
        if let windowContext { return windowContext.isCurrent ? windowContext.connectionID : nil }
        return viewModel.backendConnection?.id
    }

    var promptContextID: String {
        if let windowContext { return windowContext.contextID }
        return "\(promptConnectionID?.uuidString ?? "disconnected")|\(viewModel.directoryStoreRegistry.generation)|\(viewModel.sessionNavigationGeneration)|\(viewModel.directoryStoreRegistry.activeKey)"
    }

    func hasPendingPromptAdmission(sessionID: String) -> Bool {
        let ids = Set(chatStore.promptAdmissions.keys).union(chatStore.submissionRecoveries.keys)
        return ids.contains {
            let phase = promptAdmissionPhase(messageID: $0, sessionID: sessionID)
            return phase == .submitting || phase == .uncertain
        }
    }

    func hasUncertainPromptAdmission(sessionID: String) -> Bool {
        let ids = Set(chatStore.promptAdmissions.keys).union(chatStore.submissionRecoveries.keys)
        return ids.contains { promptAdmissionPhase(messageID: $0, sessionID: sessionID) == .uncertain }
    }

    func recoveryInputs(sessionID: String) -> [ChatStore.SubmissionRecovery] {
        guard promptConnectionID != nil, !isReadOnly else { return [] }
        return chatStore.recoveryInputs(sessionID: sessionID)
    }

    func checkRecoveryStatus(messageID: String, sessionID: String) async {
        guard !isReadOnly, let connection = viewModel.backendConnection,
               chatStore.submissionRecoveries[messageID]?.sessionID == sessionID else { return }
        let context = promptContextID
        if !isV2Connection {
            _ = await resolvePromptAdmission(messageID: messageID, sessionID: sessionID, checkCanonicalStatus: true)
            guard promptContextID == context, viewModel.isCurrentBackendConnection(connection),
                  let session = selectedSession, session.id == sessionID else { return }
            try? await viewModel.loadMessages(for: session, prefetchToolDetails: false, refreshTodos: false,
                presentationIndependent: windowContext != nil, canonicalOwner: directoryStore(forSessionID: sessionID))
            return
        }
        _ = await viewModel.resolveV2PromptAdmission(sessionID: sessionID, messageID: messageID, checkPendingStatus: true)
        guard promptContextID == context, viewModel.isCurrentBackendConnection(connection) else { return }
        await viewModel.reconcileV2TimelineFromEvent(sessionID: sessionID, presentationIndependent: windowContext != nil)
    }

    func promptAdmissionPhase(messageID: String, sessionID: String) -> ChatStore.PromptAdmission.Phase? {
        guard windowContext?.isCurrent ?? true else { return nil }
        let generic = promptConnectionID.flatMap {
            chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID, connectionID: $0)
        }
        let recovery = chatStore.submissionRecoveries[messageID]
        let matchingRecovery = recovery?.sessionID == sessionID ? recovery : nil
        if chatStore.canonicalSubmissionSessions[messageID] == sessionID { return .admitted }
        if matchingRecovery?.phase == .cancelled { return .cancelled }
        if generic == .admitted || matchingRecovery?.phase == .admitted { return .admitted }
        if let generic { return generic }
        switch matchingRecovery?.phase {
        case .submitting?: return .submitting
        case .uncertain?: return .uncertain
        case .admitted?: return .admitted
        case .cancelled?: return .cancelled
        case nil: return nil
        }
    }

    func isPromptAdmitted(messageID: String, sessionID: String) -> Bool {
        // Cached transcripts can contain optimistic rows. Only explicit admission
        // evidence is safe for clearing a draft or releasing its original identity.
        promptAdmissionPhase(messageID: messageID, sessionID: sessionID) == .admitted
    }

    func resolvePromptAdmission(messageID: String, sessionID: String, checkCanonicalStatus: Bool = false) async -> Bool {
        if !checkCanonicalStatus, isPromptAdmitted(messageID: messageID, sessionID: sessionID) { return true }
        guard let connection = viewModel.backendConnection, !connection.isClosed,
              let session = viewModel.session(matching: sessionID) else { return false }
        let context = promptContextID
        let rememberVerifiedAdmission = { [self] in
            // Retain exact-ID server evidence after the v2 transcript reducer has
            // retired its pending entry. This is never called for an optimistic row.
            if chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID, connectionID: connection.id) == nil {
                _ = chatStore.beginPromptAdmission(.init(sessionID: sessionID, messageID: messageID, text: "",
                    scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID)),
                    connectionID: connection.id)
            }
            chatStore.applyPromptAdmission(.admitted, messageID: messageID, connectionID: connection.id)
        }
        if isV2Connection, connection.openCodeCompatibility != nil {
            let confirmed = await viewModel.resolveV2PromptAdmission(sessionID: sessionID, messageID: messageID)
            guard promptContextID == context, viewModel.isCurrentBackendConnection(connection), confirmed else { return false }
            rememberVerifiedAdmission()
            return true
        }
        if let adapter = connection.openCodeCompatibility, adapter.profile == .legacy {
            let owner = directoryStore(forSessionID: sessionID)
            let generation = viewModel.directoryStoreRegistry.generation
            let beforeRead = owner.syncState.messageEnvelopes(forSessionID: sessionID)
            do {
                let canonical = try await adapter.client.getMessage(sessionID: sessionID, messageID: messageID, directory: session.directory)
                guard promptContextID == context, viewModel.isCurrentBackendConnection(connection),
                      viewModel.directoryStoreRegistry.generation == generation,
                      viewModel.session(matching: sessionID)?.directory == session.directory,
                      viewModel.session(matching: sessionID)?.workspaceID == session.workspaceID,
                      viewModel.directoryStoreRegistry.key(for: owner) != nil else { return false }
                if canonical.id == messageID, canonical.info.sessionID == sessionID, canonical.info.role == "user" {
                    viewModel.confirmCanonicalPromptAdmission(canonical.info, connectionID: connection.id)
                    if owner.syncState.messageEnvelopes(forSessionID: sessionID) == beforeRead {
                        let committed = ChatStore.mergingCanonicalMessagePage([canonical], into: beforeRead)
                        owner.applyCanonicalMessages(committed, forSessionID: sessionID)
                        chatStore.applyCanonicalMessages(committed, forSessionID: sessionID,
                            isActiveSession: viewModel.selectedSession?.id == sessionID)
                        viewModel.finishTranscriptCommit(in: owner, sessionID: sessionID, completeInventory: [canonical])
                    }
                    connectionStore.clearPromptError(connectionID: connection.id, sessionID: sessionID, messageID: messageID)
                    return true
                }
            } catch { }
            guard promptContextID == context, viewModel.isCurrentBackendConnection(connection),
                  viewModel.directoryStoreRegistry.generation == generation else { return false }
            if checkCanonicalStatus { chatStore.markSubmissionStatusUnknown(messageID: messageID, sessionID: sessionID) }
            return isPromptAdmitted(messageID: messageID, sessionID: sessionID)
        }
        var cursor: String?
        var seen: Set<String> = []
        do {
            repeat {
                let page = try await connection.chat.transcript(sessionID: sessionID,
                    scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID),
                    cursor: cursor, limit: 200)
                guard promptContextID == context, viewModel.isCurrentBackendConnection(connection) else { return false }
                if let canonical = page.messages.first(where: {
                    $0.id == messageID && $0.info.sessionID == sessionID && $0.info.role == "user"
                }) {
                    rememberVerifiedAdmission()
                    viewModel.confirmCanonicalPromptAdmission(canonical.info, connectionID: connection.id)
                    return true
                }
                cursor = page.messages.isEmpty ? nil : page.olderCursor
                if let cursor, !seen.insert(cursor).inserted { break }
            } while cursor != nil
        } catch { }
        return promptContextID == context && viewModel.isCurrentBackendConnection(connection)
            && isPromptAdmitted(messageID: messageID, sessionID: sessionID)
    }

    var reservedPromptDay: String? { viewModel.hasProUnlock ? nil : viewModel.usageMeter.promptDay }

    func refundReservedPrompt(on day: String?) {
        guard let day, viewModel.usageMeter.promptDay == day, day == OpenClientUsageMeter.dayString(for: Date()) else { return }
        viewModel.refundReservedUserPromptIfNeeded()
    }

    func unsupportedV2Forms(forSessionID sessionID: String) -> [OpenCodeV2Form] {
        guard isV2Connection else { return [] }
        return sessionForms(forSessionID: sessionID).filter { !$0.contract.isSupported() }.map {
            OpenCodeV2Form(id: $0.id, sessionID: $0.sessionID, title: $0.title, metadata: $0.metadata, fields: $0.fields.map(\.raw))
        }
    }

    func sessionForms(forSessionID sessionID: String) -> [BackendForm] {
        let owner = directoryStore(forSessionID: sessionID)
        // Global MCP elicitations need a project-level surface, not attribution to this chat.
        return SessionInteractionStore.forms(forSessionTreeRootID: sessionID, sessions: owner.sessions,
            forms: Array(owner.sessionFormStore.forms.values))
    }

    var allowsSessionForms: Bool {
        !isReadOnly && viewModel.backendConnection?.isClosed == false && viewModel.backendConnection?.sessionForms != nil
    }

    func hasGlobalForms(sessionID: String) -> Bool {
        guard let session = directoryStore(forSessionID: sessionID).sessions.first(where: { $0.id == sessionID }),
              let directory = session.directory else { return false }
        return !viewModel.globalFormsFacade.pending(for: .init(directory: directory, workspaceID: session.workspaceID)).isEmpty
    }

    func sessionFormStore(forSessionID sessionID: String) -> SessionFormStore {
        let canonical = directoryStore(forSessionID: sessionID).sessionFormStore
        return windowContext?.formEditor(for: canonical) ?? canonical
    }

    func submitSessionForm(_ form: BackendForm) async {
        guard let (store, context) = sessionFormContext(form) else { return }
        await SessionFormCoordinator(store: store).submit(context)
    }

    func cancelSessionForm(_ form: BackendForm) async {
        guard let (store, context) = sessionFormContext(form) else { return }
        await SessionFormCoordinator(store: store).cancel(context)
    }

    func refreshSessionForm(_ form: BackendForm) async {
        guard let (store, context) = sessionFormContext(form) else { return }
        await SessionFormCoordinator(store: store).refresh(context)
    }

    private func sessionFormContext(_ form: BackendForm) -> (SessionFormStore, SessionFormContext)? {
        guard allowsSessionForms, form.sessionID != "global", let connection = viewModel.backendConnection,
              let service = connection.sessionForms else { return nil }
        let owner = directoryStore(forSessionID: form.sessionID)
        guard owner.sessionFormStore.forms[form.key] == form,
              let ownerKey = viewModel.directoryStoreRegistry.key(for: owner) else { return nil }
        let generation = viewModel.directoryStoreRegistry.generation
        let lifecycle = viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: form.sessionID)
        let session = owner.sessions.first { $0.id == form.sessionID }
        let reference = BackendFormReference(key: form.key,
            directory: session?.directory ?? DirectoryStoreRegistry.directory(forKey: ownerKey),
            workspaceID: session?.workspaceID, projectID: session?.projectID)
        let context = SessionFormContext(connectionID: connection.id, service: service, reference: reference,
            isCurrent: { [weak self, weak owner] in
                guard let self, let owner else { return false }
                return self.viewModel.isCurrentBackendConnection(connection)
                    && (self.windowContext?.isCurrent ?? true)
                    && self.viewModel.directoryStoreRegistry.generation == generation
                    && self.viewModel.directoryStoreRegistry.key(for: owner) == ownerKey
                    && self.viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: form.sessionID) == lifecycle
                    && owner.sessions.first(where: { $0.id == form.sessionID })?.directory == session?.directory
                    && owner.sessions.first(where: { $0.id == form.sessionID })?.workspaceID == session?.workspaceID
                    && owner.sessions.first(where: { $0.id == form.sessionID })?.projectID == session?.projectID
                    && owner.sessionFormStore.forms[form.key] == form
            }, didSettle: { [weak self, weak owner] key in
                owner?.removeV2Question(id: key.formID, sessionID: key.sessionID)
                if let self, let owner, self.viewModel.directoryStore === owner {
                    self.sessionInteractionStore.removeQuestion(id: key.formID)
                }
            })
        return (windowContext?.formEditor(for: owner.sessionFormStore) ?? owner.sessionFormStore, context)
    }

    func cancelUnsupportedV2Form(_ form: OpenCodeV2Form) async {
        await cancelSessionForm(form.backendForm)
    }

    var allowsV2TextPromptAdmission: Bool {
        !isReadOnly && connectionStore.backendMode == .serverV2
            && connectionStore.apiProfile == .v2
            && connectionStore.isConnected
    }

    func isV2PromptInFlight(sessionID: String) -> Bool {
        hasPendingPromptAdmission(sessionID: sessionID)
    }

    var v2DraftContextID: String {
        "\(viewModel.config.recentServerID)|\(promptContextID)"
    }

    func isV2PromptAdmitted(messageID: String, sessionID: String) -> Bool {
        isV2Connection && isPromptAdmitted(messageID: messageID, sessionID: sessionID)
    }

    func sendV2TextPrompt(_ text: String, in session: OpenCodeSession, attachments: [OpenCodeComposerAttachment] = [], agentMentions: [OpenCodeAgentMention] = [], messageID: String? = nil) async -> Bool {
        guard allowsV2TextPromptAdmission else { return false }
        let context = promptContextID
        guard await waitForV2Configuration(sessionID: session.id) else { return false }
        guard allowsV2TextPromptAdmission, !Task.isCancelled, promptContextID == context else { return false }
        if windowContext != nil {
            return await sendMessage(text, agentMentions: agentMentions, attachments: attachments,
                in: session, userVisible: true, messageID: messageID)
        }
        return await viewModel.sendV2TextPrompt(text, in: session, attachments: attachments, agentMentions: agentMentions, messageID: messageID)
    }

    func isV2SessionBusy(sessionID: String) -> Bool {
        directoryStore(forSessionID: sessionID).sessionStatuses[sessionID] == "busy"
    }

    func interruptV2Session(sessionID: String) async -> Bool {
        guard allowsV2TextPromptAdmission else { return false }
        if let windowContext {
            guard let session = windowContext.owner.sessions.first(where: { $0.id == sessionID }) else { return false }
            await stopSession(session)
            return windowContext.isCurrent
        }
        return await viewModel.interruptV2Session(sessionID: sessionID)
    }

    func hasOlderV2Messages(sessionID: String) -> Bool {
        chatStore.hasOlderV2Messages(sessionID: sessionID)
    }

    func isLoadingOlderV2Messages(sessionID: String) -> Bool {
        chatStore.isLoadingOlderV2Messages(sessionID: sessionID)
    }

    func loadOlderV2Messages(sessionID: String) async -> Bool {
        guard allowsV2TextPromptAdmission else { return false }
        return await viewModel.loadOlderV2Messages(sessionID: sessionID, windowContext: windowContext)
    }

    func setActiveChatSessionID(_ sessionID: String) {
        guard windowContext == nil else { return }
        viewModel.activeChatSessionID = sessionID
    }

    func clearActiveChatSessionIfMatching(_ sessionID: String) {
        guard windowContext == nil else { return }
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
        if windowContext != nil {
            let state = directoryStore.syncState
            return ChatComposerOverlaySnapshot(todos: state.todosBySessionID[sessionID] ?? [], attachments: composerStore.draftAttachments,
                permissions: SessionInteractionStore.permissions(forSessionTreeRootID: sessionID, sessions: directoryStore.sessions,
                    permissionsBySessionID: state.permissionsBySessionID),
                questions: SessionInteractionStore.questions(forSessionTreeRootID: sessionID, sessions: directoryStore.sessions,
                    questionsBySessionID: state.questionsBySessionID)
                    .filter { directoryStore.sessionFormStore.forms[.init(sessionID: $0.sessionID, formID: $0.id)] == nil })
        }
        let supportsInteractions = viewModel.compatibilityClient(for: .interactions) != nil
        return ChatComposerOverlaySnapshot(
            todos: isV2Connection || !supportsInteractions ? [] : sessionInteractionStore.todos,
            attachments: composerStore.draftAttachments,
            permissions: !supportsInteractions ? [] : sessionInteractionStore.permissions(
                forSessionTreeRootID: sessionID,
                sessions: directoryStore.sessions
            ),
            questions: !supportsInteractions ? [] : sessionInteractionStore.questions(
                forSessionTreeRootID: sessionID,
                sessions: directoryStore.sessions
            ).filter { directoryStore.sessionFormStore.forms[.init(sessionID: $0.sessionID, formID: $0.id)] == nil }
        )
    }

    func composerSnapshot(
        for session: OpenCodeSession,
        isBusy: Bool,
        forkableMessages: [OpenCodeForkableMessage]
    ) -> ChatComposerSnapshot {
        let canFork = viewModel.compatibilityClient(for: .fork) != nil && !forkableMessages.isEmpty
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
        let connection = viewModel.backendConnection
        let hasService = connection?.isClosed == false && connection?.commands != nil
        let allowsLegacyFallback = connection?.openCodeCompatibility?.profile == .legacy
            || (connection == nil && viewModel.backendFactory == nil && connectionStore.apiProfile != .v2 && viewModel.config.apiPreference == .legacy)
        var result = hasService || (allowsLegacyFallback && viewModel.compatibilityClient(for: .commands) != nil)
            ? store.commands.filter { $0.source != "client" } : []
        if viewModel.compatibilityClient(for: .compaction) != nil, store.selectedSession != nil, !result.contains(where: { $0.name == "compact" }) {
            result.append(OpenClientChatCommands.compact)
        }
        if viewModel.compatibilityClient(for: .fork) != nil, store.selectedSession != nil, canFork, !result.contains(where: { $0.name == "fork" }) {
            result.append(OpenClientChatCommands.fork)
        }
        return result
    }

    func preferenceScopeKey() -> String {
        if let windowContext {
            return "\(windowContext.connectionID)|\(DirectoryStoreRegistry.key(for: windowContext.session.directory))|\(windowContext.session.workspaceID ?? "")"
        }
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
        if windowContext != nil { composerStore.isStreamingFocused = isFocused; return }
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
        if let windowContext {
            guard windowContext.isCurrent, windowContext.session.id == sessionID else { return }
            _ = composerStore.saveDraft(text, agentMentions: agentMentions ?? composerStore.draftAgentMentions,
                forKey: sessionID, removesEmpty: removesEmpty, updateActiveDraft: updateActiveDraft)
            windowContext.saveDraft()
            return
        }
        viewModel.saveMessageDraft(
            text,
            agentMentions: agentMentions,
            forSessionID: sessionID,
            removesEmpty: removesEmpty,
            updateActiveDraft: updateActiveDraft
        )
    }

    func resetComposer() {
        composerStore.resetToken = UUID()
    }

    func setDraftAgentMentions(_ mentions: [OpenCodeAgentMention], forSessionID sessionID: String) {
        if let windowContext {
            guard windowContext.isCurrent, windowContext.session.id == sessionID else { return }
            composerStore.draftAgentMentions = mentions
            windowContext.saveDraft()
            return
        }
        viewModel.setDraftAgentMentions(mentions, forSessionID: sessionID)
    }

    func addDraftAttachments(_ attachments: [OpenCodeComposerAttachment]) {
        if windowContext != nil { composerStore.addAttachments(attachments); return }
        viewModel.addDraftAttachments(attachments)
    }

    func removeDraftAttachment(_ attachment: OpenCodeComposerAttachment) {
        if windowContext != nil { composerStore.removeAttachment(id: attachment.id); return }
        viewModel.removeDraftAttachment(attachment)
    }

    func clearDraftAttachments() {
        if windowContext != nil { composerStore.clearAttachments(); return }
        viewModel.clearDraftAttachments()
    }

    func dismissPermission(_ permission: OpenCodePermission) {
        guard !isReadOnly || allowsV2TextPromptAdmission else { return }
        viewModel.dismissPermission(permission)
    }

    func respondToPermission(_ permission: OpenCodePermission, response: String) async {
        guard !isReadOnly || allowsV2TextPromptAdmission else { return }
        await viewModel.respondToPermission(permission, response: response, windowContext: windowContext)
    }

    func dismissQuestion(_ request: OpenCodeQuestionRequest) async {
        guard !isReadOnly || allowsV2TextPromptAdmission else { return }
        await viewModel.dismissQuestion(request, windowContext: windowContext)
    }

    func respondToQuestion(_ request: OpenCodeQuestionRequest, answers: [[String]]) async {
        guard !isReadOnly || allowsV2TextPromptAdmission else { return }
        await viewModel.respondToQuestion(request, answers: answers, windowContext: windowContext)
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
        if let windowContext {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("/") else { return nil }
            let parts = trimmed.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard let name = parts.first,
                  let command = commands(forSessionID: windowContext.session.id, canFork: !forkSessionSnapshot.messages.isEmpty)
                    .first(where: { $0.name == name }) else { return nil }
            return (command, parts.count > 1 ? String(parts[1]) : "")
        }
        return viewModel.slashCommandInput(from: text)
    }

    func presentForkSessionSheet() {
        guard !isReadOnly, viewModel.compatibilityClient(for: .fork) != nil else { return }
        if windowContext != nil { chatPresentationStore.isShowingForkSessionSheet = true; return }
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
        if isV2Connection, await waitForV2Configuration(sessionID: sessionID) == false { return false }
        let intent = armLiveActivityBackgroundBridge(sessionID: sessionID, userVisible: userVisible)
        if let windowContext {
            guard windowContext.isCurrent, windowContext.session.id == sessionID,
                  let connection = viewModel.backendConnection,
                  let client = try? connection.requireOpenCodeClient(for: .compaction) else { return false }
            let session = windowContext.session
            let owner = windowContext.owner
            guard session.parentID == nil, owner.sessionStatuses[sessionID] != "busy" else { return false }
            let accepted = await submitInWindow(meterPrompt: userVisible && meterPrompt, reservedDay: nil) { day in
                do {
                    if self.isV2Connection {
                        try await client.compactV2Session(sessionID: sessionID)
                    } else {
                        guard let model = self.modelConfigurationStore.effectiveModelReference(for: sessionID) else { return false }
                        let preparation = self.viewModel.sessionCoordinator.prepareCompactSession(session: session,
                            selectedDirectory: session.directory, currentProjectID: session.projectID, model: model)
                        try await self.viewModel.sessionCoordinator.submitCompact(client: client, preparation: preparation)
                    }
                    guard windowContext.isCurrent else { return false }
                    await windowContext.hydrate()
                    return true
                } catch {
                    if windowContext.isCurrent { windowContext.errorMessage = error.localizedDescription }
                    _ = day
                    return false
                }
            }
            resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: sessionID)
            return accepted
        }
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
        restoreDraftOnFailure: Bool = true,
        arguments: String = "",
        attachments: [OpenCodeComposerAttachment]? = nil,
        messageID: String? = nil,
        agentMentions: [OpenCodeAgentMention]? = nil,
        reservedPromptDay: String? = nil
    ) async -> Bool {
        guard !isReadOnly else { return false }
        let context = promptContextID
        let submittedAttachments = attachments ?? composerStore.draftAttachments
        let submittedMentions = agentMentions ?? composerStore.draftAgentMentions
        if isV2Connection, await waitForV2Configuration(sessionID: sessionID) == false { return false }
        guard !isReadOnly, !Task.isCancelled, promptContextID == context else { return false }
        if let windowContext {
            guard windowContext.session.id == sessionID else { return false }
            if isCompactClientCommand(command) {
                return await compactSession(sessionID: sessionID, userVisible: userVisible, meterPrompt: meterPrompt)
            }
            return await submitInWindow(meterPrompt: userVisible && meterPrompt, reservedDay: reservedPromptDay) { day in
                await self.viewModel.sendCommand(command, arguments: arguments, attachments: submittedAttachments,
                    in: windowContext.session, userVisible: false, meterPrompt: false, restoreDraftOnFailure: false,
                    messageID: messageID, agentMentions: submittedMentions, reservedPromptDay: day, windowContext: windowContext)
            }
        }
        let intent = armLiveActivityBackgroundBridge(sessionID: sessionID, userVisible: userVisible)
        let accepted = await viewModel.sendCommand(
            command,
            arguments: arguments,
            attachments: submittedAttachments,
            sessionID: sessionID,
            userVisible: userVisible,
            meterPrompt: meterPrompt,
            restoreDraftOnFailure: restoreDraftOnFailure,
            messageID: messageID,
            agentMentions: submittedMentions,
            reservedPromptDay: reservedPromptDay
        )
        resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: sessionID)
        return accepted
    }

    func loadMCPStatusIfNeeded() async {
        guard !isReadOnly else { return }
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
        if let windowContext {
            await windowContext.select(session, owner: directoryStore(forSessionID: session.id))
            return
        }
        await viewModel.selectSession(session)
    }

    @discardableResult
    func scheduleForegroundChatCatchUp(reason: String) -> Task<Void, Never>? {
        if let windowContext { return Task { await windowContext.hydrate() } }
        return viewModel.scheduleForegroundChatCatchUp(reason: reason)
    }

    func refreshChatData(for sessionID: String) async {
        guard !isReadOnly else { return }
        if let windowContext { await windowContext.hydrate(); return }
        if isV2Connection {
            let context = promptContextID
            let pendingIDs = Set(chatStore.promptAdmissions.keys).union(chatStore.submissionRecoveries.keys).filter {
                let phase = promptAdmissionPhase(messageID: $0, sessionID: sessionID)
                return phase == .submitting || phase == .uncertain
            }
            await viewModel.reconcileV2TimelineFromEvent(sessionID: sessionID)
            guard promptContextID == context else { return }
            if let session = viewModel.session(matching: sessionID) {
                await viewModel.hydrateV2Interactions(for: session)
            }
            // This is the explicit refresh action, not foreground refresh or polling.
            for id in pendingIDs {
                guard promptContextID == context else { return }
                _ = await resolvePromptAdmission(messageID: id, sessionID: sessionID)
            }
            return
        }
        await viewModel.refreshChatData(for: sessionID)
    }

    func resolveTaskSessionID(from part: OpenCodePart, currentSessionID: String) -> String? {
        viewModel.resolveTaskSessionID(from: part, currentSessionID: currentSessionID)
    }

    func openSession(sessionID: String) async {
        if windowContext != nil {
            if let session = await sessionForPresentation(sessionID: sessionID) { await selectSession(session) }
            return
        }
        await viewModel.openSession(sessionID: sessionID)
    }

    func sessionForPresentation(sessionID: String) async -> OpenCodeSession? {
        if let windowContext {
            guard windowContext.isCurrent, let connection = viewModel.backendConnection else { return nil }
            if let session = viewModel.directoryStoreRegistry.session(matching: sessionID) { return session }
            let result = try? await connection.sessions.session(id: sessionID,
                scope: .init(directory: windowContext.session.directory, workspaceID: windowContext.session.workspaceID))
            guard windowContext.isCurrent, let result, result.id == sessionID else { return nil }
            viewModel.directoryStoreRegistry.targetStore(forV2Session: result).insertV2Session(result)
            return result
        }
        return await viewModel.sessionForPresentation(sessionID: sessionID)
    }

    func hydrateSessionForPresentation(_ session: OpenCodeSession) async {
        guard !isReadOnly else { return }
        if let windowContext {
            if session.id == windowContext.session.id { await windowContext.hydrate() }
            else if let child = childPresentation(for: session) {
                defer { child.windowContext?.close() }
                await child.hydrateSessionForPresentation(session)
            }
            return
        }
        if isV2Connection {
            _ = await viewModel.hydrateV2Transcript(for: session, navigationGeneration: viewModel.sessionNavigationGeneration,
                expectedDirectoryKey: viewModel.directoryStoreRegistry.activeKey)
            await viewModel.hydrateV2Interactions(for: session)
            return
        }
        try? await viewModel.loadMessages(
            for: session,
            prefetchToolDetails: false,
            refreshTodos: false
        )
    }

    func childPresentation(for session: OpenCodeSession) -> ChatFacade? {
        guard !isReadOnly, let connection = try? viewModel.requireBackendConnection(),
              let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id),
              owner.sessions.contains(where: { $0.id == session.id && $0.directory == session.directory && $0.workspaceID == session.workspaceID }) else { return nil }
        let context = ChatWindowContext(model: viewModel, connection: connection, session: session,
            owner: owner, parentContext: windowContext)
        return ChatFacade(viewModel: viewModel, windowContext: context)
    }

    func hasOlderMessages(forSessionID sessionID: String) -> Bool {
        if connectionStore.backendMode == .serverV2 {
            return hasOlderV2Messages(sessionID: sessionID)
        }
        return chatStore.hasOlderMessages(forSessionID: sessionID)
    }

    func isLoadingOlderMessages(forSessionID sessionID: String) -> Bool {
        if connectionStore.backendMode == .serverV2 {
            return isLoadingOlderV2Messages(sessionID: sessionID)
        }
        return chatStore.isLoadingOlderMessages(forSessionID: sessionID)
    }

    @discardableResult
    func loadOlderMessages(for session: OpenCodeSession, count: Int) async -> Int {
        if connectionStore.backendMode == .serverV2 {
            let owner = directoryStore(forSessionID: session.id)
            let previousIDs = Set(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id))
            guard await loadOlderV2Messages(sessionID: session.id) else { return 0 }
            return Set(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id))
                .subtracting(previousIDs).count
        }
        return await viewModel.loadOlderMessages(for: session, count: count, windowContext: windowContext)
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
        if viewModel.backendConnection?.openCodeCompatibility != nil { return (messageID ?? OpenCodeIdentifier.message(), partID ?? OpenCodeIdentifier.part()) }
        if let windowContext {
            let messageID = messageID ?? OpenCodeIdentifier.message()
            let partID = partID ?? OpenCodeIdentifier.part()
            guard windowContext.isCurrent else { return (messageID, partID) }
            let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: text, agentMentions: agentMentions,
                attachments: attachments, messageID: messageID, sessionID: session.id, partID: partID)
            directoryStore(forSessionID: session.id).appendMessage(optimistic, forSessionID: session.id)
            return (messageID, partID)
        }
        return viewModel.insertOptimisticUserMessage(
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
        meterPrompt: Bool = true,
        reservedPromptDay: String? = nil
    ) async -> Bool {
        guard !isReadOnly, !viewModel.funAndGamesStore.hasPendingSetup(for: session.id) else { return false }
        let intent = armLiveActivityBackgroundBridge(sessionID: session.id, userVisible: userVisible)
        let connectionID = viewModel.backendConnection?.id
        let generation = viewModel.directoryStoreRegistry.generation
        if isV2Connection, await waitForV2Configuration(sessionID: session.id) == false {
            resolveLiveActivityBackgroundBridge(intent, accepted: false, sessionID: session.id)
            return false
        }
        guard connectionID == viewModel.backendConnection?.id,
              generation == viewModel.directoryStoreRegistry.generation, !Task.isCancelled else {
            resolveLiveActivityBackgroundBridge(intent, accepted: false, sessionID: session.id)
            return false
        }
        if let windowContext {
            guard windowContext.session.id == session.id else { return false }
            let accepted = await submitInWindow(meterPrompt: userVisible && meterPrompt, reservedDay: reservedPromptDay) { day in
                await self.viewModel.sendMessage(text, agentMentions: agentMentions, attachments: attachments,
                    in: session, userVisible: false, messageID: messageID, partID: partID,
                    appendOptimisticMessage: false, meterPrompt: false, reservedPromptDay: day, windowContext: windowContext)
            }
            resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: session.id)
            return accepted
        }
        let accepted = await viewModel.sendMessage(
            text,
            agentMentions: agentMentions,
            attachments: attachments,
            in: session,
            userVisible: userVisible,
            messageID: messageID,
            partID: partID,
            appendOptimisticMessage: appendOptimisticMessage,
            meterPrompt: meterPrompt,
            reservedPromptDay: reservedPromptDay
        )
        resolveLiveActivityBackgroundBridge(intent, accepted: accepted, sessionID: session.id)
        return accepted
    }

    private func submitInWindow(meterPrompt: Bool, reservedDay: String?, operation: (String?) async -> Bool) async -> Bool {
        guard let windowContext, windowContext.isCurrent, !Task.isCancelled else { return false }
        let revision = windowContext.navigationRevision
        let text = composerStore.draftMessage
        let mentions = composerStore.draftAgentMentions
        let attachments = composerStore.draftAttachments
        let reset = composerStore.resetToken
        guard reservedDay != nil || !meterPrompt || reserveUserPromptIfAllowed() else { return false }
        let day = reservedDay ?? (meterPrompt ? reservedPromptDay : nil)
        let accepted = await operation(day)
        guard windowContext.isCurrent, windowContext.navigationRevision == revision else { return accepted }
        if accepted, composerStore.resetToken == reset, composerStore.draftMessage == text,
           composerStore.draftAgentMentions == mentions, composerStore.draftAttachments == attachments {
            composerStore.resetActiveDraft()
            windowContext.saveDraft()
        }
        return accepted
    }

    func removeOptimisticUserMessage(messageID: String, sessionID: String) {
        if let windowContext {
            guard windowContext.isCurrent else { return }
            if let phase = chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID,
                connectionID: windowContext.connectionID), phase != .rejected { return }
            directoryStore(forSessionID: sessionID).removeMessage(sessionID: sessionID, messageID: messageID)
            return
        }
        viewModel.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
    }

    func stopSession(_ session: OpenCodeSession) async {
        guard !isReadOnly else { return }
        if let windowContext {
            guard windowContext.isCurrent, let connection = viewModel.backendConnection else { return }
            do {
                try await connection.chat.interrupt(sessionID: session.id,
                    scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID))
            } catch {
                if windowContext.isCurrent { windowContext.errorMessage = error.localizedDescription }
            }
            return
        }
        let lifetime = viewModel.liveActivityFacade.currentLifetime
        let accepted = await viewModel.stopSession(session)
        if accepted {
            liveActivityBackgroundBridge?.cancel(sessionID: session.id, reason: "Stopped", lifetime: lifetime)
        }
    }

    private func armLiveActivityBackgroundBridge(
        sessionID: String,
        userVisible: Bool
    ) -> LiveActivityBackgroundBridge.Intent? {
        guard userVisible,
              !viewModel.isUsingAppleIntelligence else { return nil }
        return viewModel.liveActivityFacade.armBackgroundBridge(sessionID: sessionID)
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
        if let windowContext {
            return TodoInspectorSnapshot(selectedSessionID: selectedSession?.id,
                todos: windowContext.owner.syncState.todosBySessionID[windowContext.session.id] ?? [])
        }
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
        if windowContext != nil {
            return ForkSessionSnapshot(messages: presentationMessages.reversed().compactMap { message in
                guard message.info.role == "user" else { return nil }
                let text = viewModel.sessionCoordinator.forkPromptDraft(from: message).text
                guard !text.isEmpty else { return nil }
                return OpenCodeForkableMessage(id: message.id, text: text, created: message.info.time?.created)
            }, pendingMessageID: chatPresentationStore.pendingForkMessageID)
        }
        return ForkSessionSnapshot(
            messages: viewModel.forkableMessages,
            pendingMessageID: viewModel.chatPresentationStore.pendingForkMessageID
        )
    }

    func fetchMessageDetails(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        return try await viewModel.fetchMessageDetails(sessionID: sessionID, messageID: messageID)
    }

    func refreshTodosAndLatestTodoMessage() async throws -> (todos: [OpenCodeTodo], detail: OpenCodeMessageEnvelope?) {
        if isV2Connection { return ([], nil) }
        if let windowContext {
            return try await viewModel.refreshTodosAndLatestTodoMessage(for: windowContext.session,
                owner: windowContext.owner, windowContext: windowContext)
        }
        return try await viewModel.refreshTodosAndLatestTodoMessage()
    }

    func forkSelectedSession(from messageID: String) async {
        guard !isReadOnly else { return }
        if let windowContext {
            guard windowContext.isCurrent, let connection = viewModel.backendConnection,
                  let client = try? connection.requireOpenCodeClient(for: .fork) else { return }
            let session = windowContext.session
            let revision = windowContext.navigationRevision
            do {
                let fork: OpenCodeSession
                if isV2Connection { fork = try await client.forkV2Session(sessionID: session.id, messageID: messageID) }
                else { fork = try await client.forkSession(sessionID: session.id, messageID: messageID,
                    directory: session.directory, workspaceID: session.workspaceID) }
                guard windowContext.isCurrent, windowContext.navigationRevision == revision else { return }
                windowContext.owner.insertV2Session(fork)
                chatPresentationStore.isShowingForkSessionSheet = false
                await selectSession(fork)
            } catch {
                if windowContext.isCurrent { windowContext.errorMessage = error.localizedDescription }
            }
            return
        }
        await viewModel.forkSelectedSession(from: messageID)
    }

    func dismissForkSessionSheet() {
        chatPresentationStore.isShowingForkSessionSheet = false
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
        guard !isReadOnly else { return }
        if isV2Connection {
            guard let agent = name ?? viewModel.effectiveAgentName(for: session) else { return }
            queueV2Configuration(sessionID: session.id, operation: { client in
                try await client.switchV2SessionAgent(sessionID: session.id, agent: agent)
            }, apply: { [modelConfigurationStore] in
                modelConfigurationStore.selectAgent(named: name, forSessionID: session.id)
            })
            return
        }
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectAgent(named: name, forSessionID: session.id)
    }

    func selectModel(_ reference: OpenCodeModelReference?, for session: OpenCodeSession) {
        guard !isReadOnly else { return }
        if isV2Connection {
            guard let model = reference ?? viewModel.defaultModelReference() else { return }
            queueV2Configuration(sessionID: session.id, operation: { client in
                try await client.switchV2SessionModel(sessionID: session.id, model: model)
            }, apply: { [modelConfigurationStore] in
                modelConfigurationStore.selectModel(reference, forSessionID: session.id)
            })
            return
        }
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectModel(reference, forSessionID: session.id)
    }

    func selectReasoningVariant(_ variant: String?, for session: OpenCodeSession) {
        guard !isReadOnly else { return }
        if isV2Connection {
            guard let model = viewModel.effectiveModelReference(for: session) else { return }
            queueV2Configuration(sessionID: session.id, operation: { client in
                try await client.switchV2SessionModel(sessionID: session.id, model: model, variant: variant)
            }, apply: { [modelConfigurationStore] in
                modelConfigurationStore.selectVariant(variant, forSessionID: session.id)
            })
            return
        }
        viewModel.objectWillChange.send()
        viewModel.modelConfigurationStore.selectVariant(variant, forSessionID: session.id)
    }

    func queueV2Configuration(
        sessionID: String,
        operation: @escaping @Sendable (OpenCodeAPIClient) async throws -> Void,
        apply: @escaping @MainActor () -> Void
    ) {
        guard allowsV2TextPromptAdmission,
              let connection = try? viewModel.requireBackendConnection(),
              let adapter = connection.openCodeCompatibility, adapter.profile == .v2 else { return }
        let client = adapter.client
        let connectionID = connection.id
        let generation = viewModel.directoryStoreRegistry.generation
        let lifecycle = viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        let originContextID = promptContextID
        let root = viewModel.chatFacade
        let previous = root.configurationTasksByConnectionID[connectionID]?[sessionID]?.task
        let taskID = UUID()
        let task = Task { @MainActor [weak self, weak root, weak viewModel, weak connection] in
            defer {
                if root?.configurationTasksByConnectionID[connectionID]?[sessionID]?.id == taskID {
                    root?.configurationTasksByConnectionID[connectionID]?[sessionID] = nil
                    if root?.configurationTasksByConnectionID[connectionID]?.isEmpty == true {
                        root?.configurationTasksByConnectionID[connectionID] = nil
                    }
                }
            }
            _ = await previous?.value
            guard let viewModel, let connection else { return false }
            let isCurrent = {
                !Task.isCancelled && viewModel.isCurrentBackendConnection(connection)
                    && viewModel.connectionStore.isConnected
                    && connection.openCodeCompatibility?.profile == .v2
                    && viewModel.directoryStoreRegistry.generation == generation
                    && viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycle
            }
            guard isCurrent() else { return false }
            do {
                try await operation(client)
                guard isCurrent() else { return false }
                // A successful server mutation remains canonical even if its originating window closed.
                apply()
                return true
            } catch {
                guard isCurrent(), let self, self.promptContextID == originContextID else { return false }
                if let windowContext = self.windowContext {
                    if windowContext.isCurrent { windowContext.errorMessage = error.localizedDescription }
                } else { self.connectionStore.applyErrorMessage(error.localizedDescription) }
                return false
            }
        }
        root.configurationTasksByConnectionID[connectionID, default: [:]][sessionID] = (id: taskID, task: task)
    }

    private func waitForV2Configuration(sessionID: String) async -> Bool {
        let connectionID = viewModel.backendConnection?.id
        // A second window can enqueue another configuration while the first barrier is awaited.
        while let pending = v2ConfigurationTasks[sessionID] {
            let accepted = await pending.task.value
            guard accepted, !Task.isCancelled, viewModel.backendConnection?.id == connectionID else { return false }
        }
        return !Task.isCancelled && viewModel.backendConnection?.id == connectionID
    }

    private func cancelConfigurationTasks() {
        for tasks in configurationTasksByConnectionID.values {
            tasks.values.forEach { $0.task.cancel() }
        }
        configurationTasksByConnectionID.removeAll()
    }

    func messageSource(for session: OpenCodeSession) -> [OpenCodeMessageEnvelope] {
        let directoryStore = directoryStore(forSessionID: session.id)
        if windowContext != nil { return directoryStore.syncState.messageEnvelopes(forSessionID: session.id) }
        if directoryStore.selectedSession?.id == session.id,
           viewModel.chatStore.preparedSessionID == session.id,
           viewModel.chatStore.messages.contains(where: {
               $0.info.sessionID == session.id && ($0.info.role ?? "").lowercased() == "user"
           }) {
            return viewModel.chatStore.messages.filter { $0.info.sessionID == session.id }
        }
        let syncedMessages = directoryStore.syncState.messageEnvelopes(forSessionID: session.id)
        if !syncedMessages.isEmpty { return syncedMessages }
        if let cachedMessages = viewModel.cachedMessagesBySessionID[session.id], !cachedMessages.isEmpty { return cachedMessages }
        if directoryStore.selectedSession?.id == session.id {
            return viewModel.messages.filter { $0.info.sessionID == session.id }
        }
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

struct OpenCodeV2RetryDraft: Equatable {
    let messageID: String
    let sessionID: String
    let contextID: String
    let revision: UInt
    let resetToken: UUID
    let text: String
    let mentions: [OpenCodeAgentMention]
    let attachments: [OpenCodeComposerAttachment]

    func canClear(
        admittedMessageID: String?, sessionID: String, contextID: String, revision: UInt, resetToken: UUID,
        text: String, mentions: [OpenCodeAgentMention], attachments: [OpenCodeComposerAttachment]
    ) -> Bool {
        admittedMessageID == messageID && self.sessionID == sessionID && self.contextID == contextID
            && self.revision == revision && self.resetToken == resetToken && self.text == text && self.mentions == mentions
            && self.attachments == attachments
    }
}
