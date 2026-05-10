import Combine
import Foundation
import SwiftUI

let opencodeSelectionAnimation = Animation.snappy(duration: 0.28, extraBounce: 0.02)
let defaultAppleIntelligenceUserInstructions = ""
let defaultAppleIntelligenceSystemInstructions = ""

struct OpenCodePendingTranscriptEvent: Sendable {
    let typedEvent: OpenCodeTypedEvent
    let eventType: String
    let sessionID: String?
    let messageID: String?
    let partID: String?
    let deltaCharacterCount: Int
    let enqueuedAt: Date
}

@MainActor
final class AppViewModel: ObservableObject {
    enum SavedServerEditorMode: Equatable {
        case add
        case edit(originalServerID: String)
    }

    enum ProjectContentTab: String, CaseIterable {
        case sessions
        case git
        case mcp

        var title: String {
            switch self {
            case .sessions:
                return "Sessions"
            case .git:
                return "Files"
            case .mcp:
                return "MCP"
            }
        }
    }

    enum StorageKey {
        static let recentServerConfigs = "recentServerConfigs"
        static let newSessionDefaults = "newSessionDefaults"
        static let appleIntelligenceWorkspaces = "appleIntelligenceWorkspaces"
        static let sessionPreviews = "sessionPreviews"
        static let pinnedSessionsByScope = "pinnedSessionsByScope"
        static let liveActivityAutoStartByScope = "liveActivityAutoStartByScope"
        static let projectWorkspacesEnabledByScope = "projectWorkspacesEnabledByScope"
        static let projectActionsByScope = "projectActionsByScope"
        static let messageDraftsByChat = "messageDraftsByChat"
        static let chatBreadcrumbs = "chatBreadcrumbs"
    }

    @Published var config = OpenCodeServerConfig()
    let connectionStore = ConnectionStore()
    lazy var connectionCoordinator = ConnectionCoordinator(connectionStore: connectionStore)
    let eventSyncCoordinator = EventSyncCoordinator()
    let projectCoordinator = ProjectCoordinator()
    let sessionCoordinator = SessionCoordinator()
    var backendMode: AppBackendMode {
        get { connectionStore.backendMode }
        set {
            objectWillChange.send()
            connectionStore.backendMode = newValue
        }
    }
    var isConnected: Bool {
        get { connectionStore.isConnected }
        set {
            objectWillChange.send()
            connectionStore.isConnected = newValue
        }
    }
    var serverVersion: String {
        get { connectionStore.serverVersion }
        set {
            objectWillChange.send()
            connectionStore.serverVersion = newValue
        }
    }
    var connectionPhase: OpenClientConnectionPhase {
        get { connectionStore.connectionPhase }
        set {
            objectWillChange.send()
            connectionStore.connectionPhase = newValue
        }
    }
    @Published var isShowingConnectionOverlay = false
    var connectionOverlayStartedAt: Date?
    @Published var appleIntelligenceRecentWorkspaces: [AppleIntelligenceWorkspaceRecord] = []
    @Published var activeAppleIntelligenceWorkspaceID: String?
    @Published var isShowingAppleIntelligenceFolderPicker = false
    let mcpStore = MCPStore()
    let projectFilesStore = ProjectFilesStore()
    let sessionInteractionStore = SessionInteractionStore()
    var mcpStatuses: [String: OpenCodeMCPStatus] {
        get { mcpStore.statuses }
        set {
            objectWillChange.send()
            mcpStore.statuses = newValue
        }
        _modify {
            objectWillChange.send()
            yield &mcpStore.statuses
        }
    }
    var isMCPReady: Bool {
        get { mcpStore.isReady }
        set {
            objectWillChange.send()
            mcpStore.isReady = newValue
        }
    }
    var isLoadingMCP: Bool {
        get { mcpStore.isLoading }
        set {
            objectWillChange.send()
            mcpStore.isLoading = newValue
        }
    }
    var togglingMCPServerNames: Set<String> {
        get { mcpStore.togglingServerNames }
        set {
            objectWillChange.send()
            mcpStore.togglingServerNames = newValue
        }
        _modify {
            objectWillChange.send()
            yield &mcpStore.togglingServerNames
        }
    }
    var mcpErrorMessage: String? {
        get { mcpStore.errorMessage }
        set {
            objectWillChange.send()
            mcpStore.errorMessage = newValue
        }
    }
    let projectStore = ProjectStore()
    var projects: [OpenCodeProject] {
        get { projectStore.projects }
        set {
            objectWillChange.send()
            projectStore.projects = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectStore.projects
        }
    }
    var currentProject: OpenCodeProject? {
        get { projectStore.currentProject }
        set {
            objectWillChange.send()
            projectStore.currentProject = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectStore.currentProject
        }
    }
    var selectedDirectory: String? {
        get { projectStore.selectedDirectory }
        set {
            objectWillChange.send()
            projectStore.selectedDirectory = newValue
        }
    }
    var selectedProjectContentTab: ProjectContentTab {
        get { projectStore.selectedContentTab }
        set {
            objectWillChange.send()
            projectStore.selectedContentTab = newValue
        }
    }
    var isShowingProjectPicker: Bool {
        get { projectStore.isShowingProjectPicker }
        set {
            objectWillChange.send()
            projectStore.isShowingProjectPicker = newValue
        }
    }
    var projectSearchQuery: String {
        get { projectStore.searchQuery }
        set {
            objectWillChange.send()
            projectStore.searchQuery = newValue
        }
    }
    var projectSearchResults: [String] {
        get { projectStore.searchResults }
        set {
            objectWillChange.send()
            projectStore.searchResults = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectStore.searchResults
        }
    }
    var isShowingCreateProjectSheet: Bool {
        get { projectStore.isShowingCreateProjectSheet }
        set {
            objectWillChange.send()
            projectStore.isShowingCreateProjectSheet = newValue
        }
    }
    var createProjectQuery: String {
        get { projectStore.createProjectQuery }
        set {
            objectWillChange.send()
            projectStore.createProjectQuery = newValue
        }
    }
    var createProjectResults: [String] {
        get { projectStore.createProjectResults }
        set {
            objectWillChange.send()
            projectStore.createProjectResults = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectStore.createProjectResults
        }
    }
    var createProjectSelectedDirectory: String? {
        get { projectStore.createProjectSelectedDirectory }
        set {
            objectWillChange.send()
            projectStore.createProjectSelectedDirectory = newValue
        }
    }
    let directoryStore = DirectoryStore()
    var isLoadingSessions: Bool {
        get { directoryStore.isLoadingSessions }
        set {
            objectWillChange.send()
            directoryStore.isLoadingSessions = newValue
        }
    }
    var allSessions: [OpenCodeSession] {
        get { directoryStore.sessions }
        set {
            objectWillChange.send()
            directoryStore.sessions = newValue
        }
        _modify {
            objectWillChange.send()
            yield &directoryStore.sessions
        }
    }
    var directoryCommands: [OpenCodeCommand] {
        get { directoryStore.commands }
        set {
            objectWillChange.send()
            directoryStore.commands = newValue
        }
        _modify {
            objectWillChange.send()
            yield &directoryStore.commands
        }
    }
    var sessionStatuses: [String: String] {
        get { directoryStore.sessionStatuses }
        set {
            objectWillChange.send()
            directoryStore.sessionStatuses = newValue
        }
        _modify {
            objectWillChange.send()
            yield &directoryStore.sessionStatuses
        }
    }
    let chatStore = ChatStore()
    var toolMessageDetails: [String: OpenCodeMessageEnvelope] {
        get { chatStore.toolMessageDetails }
        set {
            objectWillChange.send()
            chatStore.toolMessageDetails = newValue
        }
        _modify {
            objectWillChange.send()
            yield &chatStore.toolMessageDetails
        }
    }
    var cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]] {
        get { chatStore.cachedMessagesBySessionID }
        set {
            objectWillChange.send()
            chatStore.cachedMessagesBySessionID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &chatStore.cachedMessagesBySessionID
        }
    }
    let sessionListStore = SessionListStore()
    var sessionPreviews: [String: SessionPreview] {
        get { sessionListStore.previews }
        set {
            objectWillChange.send()
            sessionListStore.previews = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionListStore.previews
        }
    }
    var pinnedSessionIDsByScope: [String: [String]] {
        get { sessionListStore.pinnedSessionIDsByScope }
        set {
            objectWillChange.send()
            sessionListStore.pinnedSessionIDsByScope = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionListStore.pinnedSessionIDsByScope
        }
    }
    let projectPreferencesStore = ProjectPreferencesStore()
    var liveActivityAutoStartByScope: [String: Bool] {
        get { projectPreferencesStore.liveActivityAutoStartByScope }
        set {
            objectWillChange.send()
            projectPreferencesStore.liveActivityAutoStartByScope = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectPreferencesStore.liveActivityAutoStartByScope
        }
    }
    var projectWorkspacesEnabledByScope: [String: Bool] {
        get { projectPreferencesStore.projectWorkspacesEnabledByScope }
        set {
            objectWillChange.send()
            projectPreferencesStore.projectWorkspacesEnabledByScope = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectPreferencesStore.projectWorkspacesEnabledByScope
        }
    }
    var projectActionsByScope: [String: [OpenCodeAction]] {
        get { projectPreferencesStore.projectActionsByScope }
        set {
            objectWillChange.send()
            projectPreferencesStore.projectActionsByScope = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectPreferencesStore.projectActionsByScope
        }
    }
    var pendingActionRunsBySessionID: [String: PendingOpenCodeActionRun] {
        get { sessionListStore.pendingActionRunsBySessionID }
        set {
            objectWillChange.send()
            sessionListStore.pendingActionRunsBySessionID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionListStore.pendingActionRunsBySessionID
        }
    }
    var workspaceSessionsByDirectory: [String: OpenCodeWorkspaceSessionState] {
        get { sessionListStore.workspaceSessionsByDirectory }
        set {
            objectWillChange.send()
            sessionListStore.workspaceSessionsByDirectory = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionListStore.workspaceSessionsByDirectory
        }
    }
    @Published var draftTitle = ""
    @Published var newSessionWorkspaceSelection: NewSessionWorkspaceSelection = .main
    @Published var newWorkspaceName = ""
    @Published var selectedFilesWorkspaceDirectory: String?
    let composerStore = ComposerStore()
    var draftMessage: String {
        get { composerStore.draftMessage }
        set {
            objectWillChange.send()
            composerStore.draftMessage = newValue
        }
    }
    var draftAgentMentions: [OpenCodeAgentMention] {
        get { composerStore.draftAgentMentions }
        set {
            objectWillChange.send()
            composerStore.draftAgentMentions = newValue
        }
    }
    var draftAttachments: [OpenCodeComposerAttachment] {
        get { composerStore.draftAttachments }
        set {
            objectWillChange.send()
            composerStore.draftAttachments = newValue
        }
        _modify {
            objectWillChange.send()
            yield &composerStore.draftAttachments
        }
    }
    var messageDraftsByChatKey: [String: OpenCodeMessageDraft] {
        get { composerStore.draftsByChatKey }
        set {
            objectWillChange.send()
            composerStore.draftsByChatKey = newValue
        }
        _modify {
            objectWillChange.send()
            yield &composerStore.draftsByChatKey
        }
    }
    var composerResetToken: UUID {
        get { composerStore.resetToken }
        set {
            objectWillChange.send()
            composerStore.resetToken = newValue
        }
    }
    var errorMessage: String? {
        get { connectionStore.errorMessage }
        set {
            objectWillChange.send()
            connectionStore.errorMessage = newValue
        }
    }
    @Published var appleIntelligenceDebugPickedPath = ""
    @Published var appleIntelligenceDebugActivePath = ""
    @Published var appleIntelligenceDebugResolvedPath = ""
    @Published var appleIntelligenceDebugToolRootPath = ""
    @Published var isShowingAppleIntelligenceInstructionsSheet = false
    @Published var appleIntelligenceUserInstructions = ""
    @Published var appleIntelligenceSystemInstructions = ""
    var isLoading: Bool {
        get { connectionStore.isLoading }
        set {
            objectWillChange.send()
            connectionStore.isLoading = newValue
        }
    }
    var recentServerConfigs: [OpenCodeServerConfig] {
        get { connectionStore.recentServerConfigs }
        set {
            objectWillChange.send()
            connectionStore.recentServerConfigs = newValue
        }
        _modify {
            objectWillChange.send()
            yield &connectionStore.recentServerConfigs
        }
    }
    var hasSavedServer: Bool {
        get { connectionStore.hasSavedServer }
        set {
            objectWillChange.send()
            connectionStore.hasSavedServer = newValue
        }
    }
    var showSavedServerPrompt: Bool {
        get { connectionStore.showSavedServerPrompt }
        set {
            objectWillChange.send()
            connectionStore.showSavedServerPrompt = newValue
        }
    }
    @Published var isShowingAddServerSheet = false
    var savedServerEditorMode: SavedServerEditorMode {
        get { connectionStore.savedServerEditorMode }
        set {
            objectWillChange.send()
            connectionStore.savedServerEditorMode = newValue
        }
    }
    @Published var isShowingCreateSessionSheet = false
    @Published var isShowingProjectSettingsSheet = false
    @Published var isShowingConfigurationsSheet = false
    @Published var isShowingFindPlaceModelSheet = false
    @Published var isShowingFindBugLanguageSheet = false
    @Published var isShowingFindBugModelSheet = false
    @Published var isShowingForkSessionSheet = false
    @Published var pendingForkSessionID: String?
    @Published var pendingForkMessageID: String?
    var debugLastEventSummary = ""
    @Published var debugProbeLog: [String] = []
    @Published var chatBreadcrumbs: [OpenCodeChatBreadcrumb] = []
    @Published var isShowingDebugProbe = false
    @Published var isRunningDebugProbe = false
    @Published var debugLastControlSummary = ""
    let modelConfigurationStore = ModelConfigurationStore()
    var availableAgents: [OpenCodeAgent] {
        get { modelConfigurationStore.availableAgents }
        set {
            objectWillChange.send()
            modelConfigurationStore.availableAgents = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.availableAgents
        }
    }
    var availableProviders: [OpenCodeProvider] {
        get { modelConfigurationStore.availableProviders }
        set {
            objectWillChange.send()
            modelConfigurationStore.availableProviders = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.availableProviders
        }
    }
    var defaultModelsByProviderID: [String: String] {
        get { modelConfigurationStore.defaultModelsByProviderID }
        set {
            objectWillChange.send()
            modelConfigurationStore.defaultModelsByProviderID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.defaultModelsByProviderID
        }
    }
    var selectedAgentNamesBySessionID: [String: String] {
        get { modelConfigurationStore.selectedAgentNamesBySessionID }
        set {
            objectWillChange.send()
            modelConfigurationStore.selectedAgentNamesBySessionID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.selectedAgentNamesBySessionID
        }
    }
    var selectedModelsBySessionID: [String: OpenCodeModelReference] {
        get { modelConfigurationStore.selectedModelsBySessionID }
        set {
            objectWillChange.send()
            modelConfigurationStore.selectedModelsBySessionID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.selectedModelsBySessionID
        }
    }
    var selectedVariantsBySessionID: [String: String] {
        get { modelConfigurationStore.selectedVariantsBySessionID }
        set {
            objectWillChange.send()
            modelConfigurationStore.selectedVariantsBySessionID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.selectedVariantsBySessionID
        }
    }
    var newSessionDefaults: NewSessionDefaults {
        get { modelConfigurationStore.newSessionDefaults }
        set {
            objectWillChange.send()
            modelConfigurationStore.newSessionDefaults = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.newSessionDefaults
        }
    }
    let funAndGamesStore = FunAndGamesStore()
    var funAndGamesPreferences: FunAndGamesPreferences {
        get { funAndGamesStore.preferences }
        set {
            objectWillChange.send()
            funAndGamesStore.preferences = newValue
        }
        _modify {
            objectWillChange.send()
            yield &funAndGamesStore.preferences
        }
    }
    var findPlaceSessionsByID: [String: FindPlaceGameSession] {
        get { funAndGamesStore.findPlaceSessionsByID }
        set {
            objectWillChange.send()
            funAndGamesStore.findPlaceSessionsByID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &funAndGamesStore.findPlaceSessionsByID
        }
    }
    var findBugSessionsByID: [String: FindBugGameSession] {
        get { funAndGamesStore.findBugSessionsByID }
        set {
            objectWillChange.send()
            funAndGamesStore.findBugSessionsByID = newValue
        }
        _modify {
            objectWillChange.send()
            yield &funAndGamesStore.findBugSessionsByID
        }
    }
    var pendingFindBugLanguage: FindBugGameLanguage? {
        get { funAndGamesStore.pendingFindBugLanguage }
        set {
            objectWillChange.send()
            funAndGamesStore.pendingFindBugLanguage = newValue
        }
    }
    let liveActivityStore = LiveActivityStore()
    var activeLiveActivitySessionIDs: Set<String> {
        get { liveActivityStore.activeSessionIDs }
        set {
            objectWillChange.send()
            liveActivityStore.activeSessionIDs = newValue
        }
        _modify {
            objectWillChange.send()
            yield &liveActivityStore.activeSessionIDs
        }
    }
    var activeChatSessionID: String? {
        get { liveActivityStore.activeChatSessionID }
        set {
            objectWillChange.send()
            liveActivityStore.activeChatSessionID = newValue
        }
    }
    @Published var usageMeter = OpenClientUsageMeter.empty
    @Published var paywallReason: OpenClientPaywallReason?
#if DEBUG
    @Published var debugEntitlementOverride: OpenClientDebugEntitlementOverride = .unlocked
#endif

    let passwordStore = OpenCodeServerPasswordStore()
    let usageStore = OpenClientUsageStore()
    let purchaseManager = OpenClientPurchaseManager()

    let eventManager = OpenCodeEventManager()
    var eventStreamRestartTask: Task<Void, Never>?
    var reloadTask: Task<Void, Never>?
    var connectionAttemptTask: Task<Void, Never>?
    var appleIntelligenceResponseTask: Task<Void, Never>?
    var activeAppleIntelligenceWorkspaceURL: URL?
    var currentAppleIntelligenceWorkspace: AppleIntelligenceWorkspaceRecord?
    var isAccessingActiveAppleIntelligenceWorkspace = false
    var debugProbeStreamTasks: [Task<Void, Never>] = []
    var uiTestBootstrapTitle: String?
    var uiTestBootstrapPrompt: String?
    var uiTestDirectory: String?
    var lastStreamEventAt = Date.distantPast
    var streamDirectory: String?
    var liveRefreshTask: Task<Void, Never>? {
        get { chatStore.liveRefreshTask }
        set { chatStore.liveRefreshTask = newValue }
    }
    var liveRefreshGeneration: Int {
        get { chatStore.liveRefreshGeneration }
        set { chatStore.liveRefreshGeneration = newValue }
    }
    var lastFallbackMessageCount: Int {
        get { chatStore.lastFallbackMessageCount }
        set { chatStore.lastFallbackMessageCount = newValue }
    }
    var lastFallbackAssistantLength: Int {
        get { chatStore.lastFallbackAssistantLength }
        set { chatStore.lastFallbackAssistantLength = newValue }
    }
    var nextStreamPartHapticAllowedAt: Date {
        get { chatStore.nextStreamPartHapticAllowedAt }
        set { chatStore.nextStreamPartHapticAllowedAt = newValue }
    }
    var liveActivityPreviewRefreshTasksBySessionID: [String: Task<Void, Never>] = [:]
    var pendingTranscriptEvents: [OpenCodePendingTranscriptEvent] {
        get { chatStore.pendingTranscriptEvents }
        set { chatStore.pendingTranscriptEvents = newValue }
        _modify { yield &chatStore.pendingTranscriptEvents }
    }
    var streamDeltaFlushTask: Task<Void, Never>? {
        get { chatStore.streamDeltaFlushTask }
        set { chatStore.streamDeltaFlushTask = newValue }
    }
    var streamDeltaLastFlushAt: Date? {
        get { chatStore.streamDeltaLastFlushAt }
        set { chatStore.streamDeltaLastFlushAt = newValue }
    }
    var storeObservationCancellables: Set<AnyCancellable> = []
    var isComposerStreamingFocused: Bool {
        get { composerStore.isStreamingFocused }
        set { composerStore.isStreamingFocused = newValue }
    }
    #if canImport(ActivityKit) && os(iOS)
    var liveActivityRefreshTasksBySessionID: [String: Task<Void, Never>] = [:]
    var lastLiveActivityStatesBySessionID: [String: OpenCodeChatActivityAttributes.ContentState] = [:]
    #endif

    let debugProbePrompt = "Write four short paragraphs about why responsive streaming matters in mobile AI apps. Make each paragraph 2-3 sentences."
    let defaultSearchRoot = NSHomeDirectory()
    static let actionSessionTitlePrefix = "__openclient_action__:"

    init() {
        observeStores()

        if configureUITestEnvironmentIfNeeded() {
            return
        }

        let recentConfigs = loadRecentServerConfigs()
        appleIntelligenceRecentWorkspaces = loadAppleIntelligenceWorkspaces()
        appleIntelligenceUserInstructions = defaultAppleIntelligenceUserInstructions
        appleIntelligenceSystemInstructions = defaultAppleIntelligenceSystemInstructions
        usageMeter = usageStore.load()
#if DEBUG
        if let override = ProcessInfo.processInfo.environment["OPENCLIENT_DEBUG_ENTITLEMENT"],
           let value = OpenClientDebugEntitlementOverride(rawValue: override) {
            debugEntitlementOverride = value
        }
#endif
        sessionPreviews = loadSessionPreviews()
        pinnedSessionIDsByScope = loadPinnedSessionIDsByScope()
        liveActivityAutoStartByScope = loadLiveActivityAutoStartByScope()
        projectWorkspacesEnabledByScope = loadProjectWorkspacesEnabledByScope()
        projectActionsByScope = loadProjectActionsByScope()
        messageDraftsByChatKey = loadMessageDraftsByChatKey()
        chatBreadcrumbs = loadChatBreadcrumbs()
        recentServerConfigs = recentConfigs
        hasSavedServer = recentConfigs.isEmpty == false
        showSavedServerPrompt = hasSavedServer
        if let savedConfig = recentConfigs.first {
            config = savedConfig
        }
    }

    private func observeStores() {
        [
            // Most store-backed AppViewModel facades send objectWillChange explicitly.
            // Observing all stores here doubles invalidations during hot paths like send.
            // ConnectionStore changes are low-frequency and are mostly routed through helpers.
            connectionStore.objectWillChange.eraseToAnyPublisher(),
            // ProjectFilesStore still has a few direct dictionary/set mutations during tree loading.
            projectFilesStore.objectWillChange.eraseToAnyPublisher(),
        ]
        .forEach { publisher in
            publisher
                .sink { [weak self] _ in
                    self?.objectWillChange.send()
                }
                .store(in: &storeObservationCancellables)
        }
    }

    var client: OpenCodeAPIClient {
        OpenCodeAPIClient(config: config)
    }

    var isUsingAppleIntelligence: Bool {
        backendMode == .appleIntelligence
    }

    var hasActiveWorkspace: Bool {
        isConnected || isUsingAppleIntelligence
    }

    var activeAppleIntelligenceWorkspace: AppleIntelligenceWorkspaceRecord? {
        if let currentAppleIntelligenceWorkspace,
           currentAppleIntelligenceWorkspace.id == activeAppleIntelligenceWorkspaceID {
            return currentAppleIntelligenceWorkspace
        }
        guard let activeAppleIntelligenceWorkspaceID else { return nil }
        return appleIntelligenceRecentWorkspaces.first { $0.id == activeAppleIntelligenceWorkspaceID }
    }

    var sessions: [OpenCodeSession] { allSessions.filter { $0.isRootSession && !isActionSession($0) } }

    var isProjectWorkspacesEnabled: Bool {
        projectWorkspacesEnabledByScope[currentProjectPreferenceScopeKey] ?? false
    }

    var pinnedSessionIDs: [String] {
        pinnedSessionIDsByScope[currentPinScopeKey] ?? []
    }

    var pinnedRootSessions: [OpenCodeSession] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return pinnedSessionIDs.compactMap { sessionsByID[$0] }
    }

    var unpinnedRootSessions: [OpenCodeSession] {
        let pinnedIDs = Set(pinnedSessionIDs)
        return sessions.filter { !pinnedIDs.contains($0.id) }
    }

    var selectedSession: OpenCodeSession? {
        get { directoryStore.selectedSession }
        set {
            objectWillChange.send()
            directoryStore.selectedSession = newValue
        }
    }

    var isLoadingSelectedSession: Bool {
        get { chatStore.isLoadingSelectedSession }
        set {
            objectWillChange.send()
            chatStore.isLoadingSelectedSession = newValue
        }
    }
    var messages: [OpenCodeMessageEnvelope] {
        get { chatStore.messages }
        set {
            objectWillChange.send()
            chatStore.messages = newValue
        }
        _modify {
            objectWillChange.send()
            yield &chatStore.messages
        }
    }
    var commands: [OpenCodeCommand] {
        commands(canFork: selectedSession != nil && !forkableMessages.isEmpty)
    }

    func commands(canFork: Bool) -> [OpenCodeCommand] {
        var result = directoryCommands
        if selectedSession != nil, !result.contains(where: { $0.name == "compact" }) {
            result.append(Self.compactClientCommand)
        }
        if selectedSession != nil, canFork, !result.contains(where: { $0.name == "fork" }) {
            result.append(Self.forkClientCommand)
        }
        return result
    }
    var todos: [OpenCodeTodo] {
        get { sessionInteractionStore.todos }
        set {
            objectWillChange.send()
            sessionInteractionStore.todos = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionInteractionStore.todos
        }
    }
    var permissions: [OpenCodePermission] {
        get { sessionInteractionStore.permissions }
        set {
            objectWillChange.send()
            sessionInteractionStore.permissions = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionInteractionStore.permissions
        }
    }
    var questions: [OpenCodeQuestionRequest] {
        get { sessionInteractionStore.questions }
        set {
            objectWillChange.send()
            sessionInteractionStore.questions = newValue
        }
        _modify {
            objectWillChange.send()
            yield &sessionInteractionStore.questions
        }
    }
    var vcsInfo: OpenCodeVCSInfo? {
        get { projectFilesStore.vcsInfo }
        set {
            objectWillChange.send()
            projectFilesStore.vcsInfo = newValue
        }
    }
    var vcsFileStatuses: [OpenCodeVCSFileStatus] {
        get { projectFilesStore.vcsFileStatuses }
        set {
            objectWillChange.send()
            projectFilesStore.vcsFileStatuses = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectFilesStore.vcsFileStatuses
        }
    }
    var projectFilesMode: OpenCodeProjectFilesMode {
        get { projectFilesStore.mode }
        set {
            objectWillChange.send()
            projectFilesStore.mode = newValue
        }
    }
    var fileTreeRootNodes: [OpenCodeFileNode] {
        get { projectFilesStore.fileTreeRootNodes }
        set {
            objectWillChange.send()
            projectFilesStore.fileTreeRootNodes = newValue
        }
        _modify {
            objectWillChange.send()
            yield &projectFilesStore.fileTreeRootNodes
        }
    }
    var selectedProjectFilePath: String? {
        get { projectFilesStore.selectedFilePath }
        set {
            objectWillChange.send()
            projectFilesStore.selectedFilePath = newValue
        }
    }
    var selectedVCSDiffMode: OpenCodeVCSDiffMode {
        get { projectFilesStore.selectedVCSMode }
        set {
            objectWillChange.send()
            projectFilesStore.selectedVCSMode = newValue
        }
    }
    var selectedVCSFile: String? {
        get { projectFilesStore.selectedVCSFile }
        set {
            objectWillChange.send()
            projectFilesStore.selectedVCSFile = newValue
        }
    }

    static let forkClientCommand = OpenCodeCommand(
        name: "fork",
        description: "Create a new session from a previous message",
        agent: nil,
        model: nil,
        source: "client",
        template: "",
        subtask: false,
        hints: []
    )

    static let compactClientCommand = OpenCodeCommand(
        name: "compact",
        description: "Summarize the session context",
        agent: nil,
        model: nil,
        source: "client",
        template: "",
        subtask: false,
        hints: []
    )
    var hasGitProject: Bool { currentProject?.vcs == "git" && effectiveSelectedDirectory != nil }
    var currentVCSDiffs: [OpenCodeVCSFileDiff] { projectFilesStore.vcsDiffsByMode[selectedVCSDiffMode] ?? [] }
    var selectedProjectFileContent: OpenCodeFileContent? {
        guard let selectedProjectFilePath else { return nil }
        return projectFilesStore.fileContentsByPath[selectedProjectFilePath]
    }
    var selectedVCSFileDiff: OpenCodeVCSFileDiff? {
        let path = selectedProjectFilePath ?? selectedVCSFile
        guard let path else { return nil }
        return currentVCSDiffs.first { $0.file == path }
    }
    var selectedProjectFileIsChanged: Bool {
        guard let selectedProjectFilePath else { return false }
        return vcsFileStatuses.contains { $0.path == selectedProjectFilePath }
    }
    var isLoadingVCS: Bool {
        get { projectFilesStore.isLoadingVCS }
        set {
            objectWillChange.send()
            projectFilesStore.isLoadingVCS = newValue
        }
    }
    var isLoadingFileTree: Bool {
        get { projectFilesStore.isLoadingFileTree }
        set {
            objectWillChange.send()
            projectFilesStore.isLoadingFileTree = newValue
        }
    }
    var isLoadingSelectedFileContent: Bool {
        get { projectFilesStore.isLoadingSelectedFileContent }
        set {
            objectWillChange.send()
            projectFilesStore.isLoadingSelectedFileContent = newValue
        }
    }
    var vcsErrorMessage: String? {
        get { projectFilesStore.vcsErrorMessage }
        set {
            objectWillChange.send()
            projectFilesStore.vcsErrorMessage = newValue
        }
    }
    var fileTreeErrorMessage: String? {
        get { projectFilesStore.fileTreeErrorMessage }
        set {
            objectWillChange.send()
            projectFilesStore.fileTreeErrorMessage = newValue
        }
    }
    var fileContentErrorMessage: String? {
        get { projectFilesStore.fileContentErrorMessage }
        set {
            objectWillChange.send()
            projectFilesStore.fileContentErrorMessage = newValue
        }
    }
}
