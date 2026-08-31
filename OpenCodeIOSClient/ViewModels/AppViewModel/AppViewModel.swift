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
final class ChatPresentationStore: ObservableObject {
    @Published var isShowingAppleIntelligenceInstructionsSheet = false
    @Published var appleIntelligenceUserInstructions = ""
    @Published var appleIntelligenceSystemInstructions = ""
    @Published var isShowingForkSessionSheet = false
    @Published var pendingForkSessionID: String?
    @Published var pendingForkMessageID: String?
    @Published var isShowingDebugProbe = false
}

@MainActor
final class AppViewModel: ObservableObject {
    typealias StorageKey = OpenClientStorageKey

    @Published var config = OpenCodeServerConfig()
    let connectionStore = ConnectionStore()
    let appCustomizationStore = AppCustomizationStore()
    let appIconStore = AppIconStore()
    let speechVoiceStore = SpeechVoiceStore()
    lazy var talkSessionCoordinator = TalkSessionCoordinator(viewModel: self)
    lazy var localCacheRepository: any OpenCodeLocalCacheRepository = OpenCodeLocalCacheRepositoryFactory.makeDefault()
    var localCacheDirectoryRefreshedAtByKey: [String: Date] = [:]
    var localCacheMessageRefreshedAtByKey: [String: Date] = [:]
    var localCacheTodoRefreshedAtByKey: [String: Date] = [:]
    var localCacheHydratedChatKeys: Set<String> = []
    var localCacheWriteTasksByKey: [String: Task<Void, Never>] = [:]
    var localCachePrefetchTasksByKey: [String: Task<OpenCodeCachedChatSnapshot?, Never>] = [:]
    var localCachePrefetchedChatsByKey: [String: OpenCodeCachedChatSnapshot] = [:]
    var localCachePrefetchedChatKeys: [String] = []
    var sessionNavigationGeneration: UInt = 0
    lazy var connectionFacade = ConnectionFacade(viewModel: self)
    lazy var connectionCoordinator = ConnectionCoordinator(connectionStore: connectionStore)
    let eventSyncCoordinator = EventSyncCoordinator()
    lazy var directorySyncFacade = DirectorySyncFacade(
        registry: directoryStoreRegistry,
        coordinator: eventSyncCoordinator
    )
    let projectCoordinator = ProjectCoordinator()
    lazy var projectFacade = ProjectFacade(viewModel: self)
    lazy var newProjectChatFacade = NewProjectChatFacade(viewModel: self)
    let pluginStore = PluginStore()
    lazy var configurationsFacade = ConfigurationsFacade(viewModel: self)
    lazy var funAndGamesFacade = FunAndGamesFacade(viewModel: self)
    lazy var appShellFacade = AppShellFacade(viewModel: self)
    lazy var widgetSnapshotPublisher: WidgetSnapshotPublisher = {
        let publisher = WidgetSnapshotPublisher(inputProvider: { [weak self] includeModelOptions in
            self?.widgetSnapshotInput(includeModelOptions: includeModelOptions)
        })
        publisher.observe(
            contentChanges: [
                objectWillChange.eraseToAnyPublisher(),
                projectStore.objectWillChange.eraseToAnyPublisher(),
                projectPreferencesStore.objectWillChange.eraseToAnyPublisher(),
                sessionListStore.objectWillChange.eraseToAnyPublisher(),
                sessionInteractionStore.objectWillChange.eraseToAnyPublisher(),
            ]
        )
        return publisher
    }()
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
    lazy var mcpFacade = MCPFacade(
        store: mcpStore,
        clientProvider: { [weak self] in self?.client },
        directoryProvider: { [weak self] in self?.effectiveSelectedDirectory }
    )
    let terminalStore = TerminalStore()
    lazy var terminalFacade = TerminalFacade(
        store: terminalStore,
        clientProvider: { [weak self] in self?.client },
        directoryProvider: { [weak self] in self?.effectiveSelectedDirectory }
    )
    let projectFilesStore = ProjectFilesStore()
    lazy var projectFilesFacade = ProjectFilesFacade(
        store: projectFilesStore,
        clientProvider: { [weak self] in self?.client },
        hasGitProjectProvider: { [weak self] in
            self?.currentProject?.vcs == "git" && self?.effectiveSelectedDirectory != nil
        },
        effectiveSelectedDirectoryProvider: { [weak self] in self?.effectiveSelectedDirectory },
        currentProjectProvider: { [weak self] in self?.currentProject },
        workspaceDirectoriesProvider: { [weak self] in self?.workspaceDirectories() ?? [] },
        workspaceDisplayNameProvider: { [weak self] in self?.workspaceDisplayName(for: $0) },
        workspaceKeyProvider: { [weak self] in self?.workspaceKey($0) ?? $0 },
        isFilesPresentedProvider: { [weak self] in self?.selectedProjectContentTab == .git },
        preserveNavigationState: { [weak self] in self?.preserveCurrentMessageDraftForNavigation() },
        showFilesRoute: { [weak self] in
            self?.selectedProjectContentTab = .git
            self?.selectedSession = nil
        }
    )
    let sessionInteractionStore = SessionInteractionStore()
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
            if DirectoryStoreRegistry.key(for: newValue) != directoryStoreRegistry.activeKey {
                prepareForDirectoryStoreActivation()
            }
            objectWillChange.send()
            projectStore.selectedDirectory = newValue
            directoryStoreRegistry.activate(newValue)
        }
    }
    var selectedProjectContentTab: OpenClientProjectContentTab {
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
    let directoryStoreRegistry = DirectoryStoreRegistry()
    var directoryStore: DirectoryStore { directoryStoreRegistry.activeStore }
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
            directoryStore.applySessionStatuses(newValue)
        }
        _modify {
            objectWillChange.send()
            yield &directoryStore.sessionStatuses
            directoryStore.applySessionStatuses(directoryStore.sessionStatuses)
        }
    }
    let chatStore = ChatStore()
    lazy var chatFacade = ChatFacade(viewModel: self)
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
    lazy var sessionListFacade = SessionListFacade(viewModel: self)
    lazy var activityFacade = ActivityFacade(viewModel: self)
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
    var showsRecentSessionsInProjectList: Bool {
        get { projectPreferencesStore.showsRecentSessionsInProjectList }
        set {
            objectWillChange.send()
            projectPreferencesStore.showsRecentSessionsInProjectList = newValue
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
    let chatPresentationStore = ChatPresentationStore()
    var isShowingAppleIntelligenceInstructionsSheet: Bool {
        get { chatPresentationStore.isShowingAppleIntelligenceInstructionsSheet }
        set {
            objectWillChange.send()
            chatPresentationStore.isShowingAppleIntelligenceInstructionsSheet = newValue
        }
    }
    var appleIntelligenceUserInstructions: String {
        get { chatPresentationStore.appleIntelligenceUserInstructions }
        set {
            objectWillChange.send()
            chatPresentationStore.appleIntelligenceUserInstructions = newValue
        }
    }
    var appleIntelligenceSystemInstructions: String {
        get { chatPresentationStore.appleIntelligenceSystemInstructions }
        set {
            objectWillChange.send()
            chatPresentationStore.appleIntelligenceSystemInstructions = newValue
        }
    }
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
    var savedServerEditorMode: OpenClientSavedServerEditorMode {
        get { connectionStore.savedServerEditorMode }
        set {
            objectWillChange.send()
            connectionStore.savedServerEditorMode = newValue
        }
    }
    @Published var isShowingCreateSessionSheet = false
    @Published var newProjectChatSheetRequest: NewProjectChatSheetRequest?
    @Published var isShowingProjectSettingsSheet = false
    @Published var isShowingConfigurationsSheet = false
    @Published var isShowingFindPlaceModelSheet = false
    @Published var isShowingFindBugLanguageSheet = false
    @Published var isShowingFindBugModelSheet = false
    @Published var openURLNavigationMessage: String?
    @Published var chatDetailPresentationRequest = 0
    var isShowingForkSessionSheet: Bool {
        get { chatPresentationStore.isShowingForkSessionSheet }
        set {
            objectWillChange.send()
            chatPresentationStore.isShowingForkSessionSheet = newValue
        }
    }
    var pendingForkSessionID: String? {
        get { chatPresentationStore.pendingForkSessionID }
        set {
            objectWillChange.send()
            chatPresentationStore.pendingForkSessionID = newValue
        }
    }
    var pendingForkMessageID: String? {
        get { chatPresentationStore.pendingForkMessageID }
        set {
            objectWillChange.send()
            chatPresentationStore.pendingForkMessageID = newValue
        }
    }
    var debugLastEventSummary = ""
    @Published var debugProbeLog: [String] = []
    @Published var chatBreadcrumbs: [OpenCodeChatBreadcrumb] = []
    var isShowingDebugProbe: Bool {
        get { chatPresentationStore.isShowingDebugProbe }
        set {
            objectWillChange.send()
            chatPresentationStore.isShowingDebugProbe = newValue
        }
    }
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
    var allProviders: [OpenCodeProvider] {
        get { modelConfigurationStore.allProviders }
        set {
            objectWillChange.send()
            modelConfigurationStore.allProviders = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.allProviders
        }
    }
    var connectedProviderIDs: Set<String> {
        get { modelConfigurationStore.connectedProviderIDs }
        set {
            objectWillChange.send()
            modelConfigurationStore.connectedProviderIDs = newValue
        }
        _modify {
            objectWillChange.send()
            yield &modelConfigurationStore.connectedProviderIDs
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
    lazy var liveActivityFacade = LiveActivityFacade(viewModel: self)
    var activeLiveActivitySessionIDs: Set<String> {
        get { liveActivityStore.activeSessionIDs }
        set {
            objectWillChange.send()
            liveActivityStore.activeSessionIDs = newValue
            updateEventInterestSnapshot()
        }
        _modify {
            objectWillChange.send()
            defer { updateEventInterestSnapshot() }
            yield &liveActivityStore.activeSessionIDs
        }
    }
    var activeChatSessionID: String? {
        get { chatStore.activeChatSessionID }
        set {
            objectWillChange.send()
            chatStore.activeChatSessionID = newValue
            updateEventInterestSnapshot()
        }
    }
    let commerceStore = CommerceStore()
    lazy var commerceFacade = CommerceFacade(store: commerceStore)
    var usageMeter: OpenClientUsageMeter {
        get { commerceFacade.usageMeter }
        set { commerceFacade.usageMeter = newValue }
    }
    var paywallReason: OpenClientPaywallReason? {
        get { commerceFacade.paywallReason }
        set { commerceFacade.paywallReason = newValue }
    }
#if DEBUG
    var debugEntitlementOverride: OpenClientDebugEntitlementOverride {
        get { commerceFacade.debugEntitlementOverride }
        set { commerceFacade.debugEntitlementOverride = newValue }
    }
#endif

    let passwordStore = OpenCodeServerPasswordStore()
    var purchaseManager: OpenClientPurchaseManager { commerceFacade.purchaseManager }

    let eventManager = OpenCodeEventManager()
    let eventInterestSnapshot = OpenCodeEventInterestSnapshot()
    var eventStreamRestartTask: Task<Void, Never>?
    var foregroundChatCatchUpTask: Task<Void, Never>?
    var lastForegroundChatCatchUpScheduledAt = Date.distantPast
    var reloadTask: Task<Void, Never>?
    var pendingRecentSessionOpenID: String?
    var recentProjectSessionsLoadTask: Task<Void, Never>?
    var recentProjectSessionsLoadGeneration = 0
    var connectionAttemptTask: Task<Void, Never>?
    var connectionAttemptID: UUID?
    var hasAttemptedAutomaticConnection = false
    var automaticConnectionRetryTask: Task<Void, Never>?
    var automaticConnectionRetryGeneration: UInt = 0
    var automaticConnectionRetryAttempt = 0
    var automaticConnectionRetryEnabled = false
    var isApplicationActive = true
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
    var nextStreamPartHapticAllowedAt: Date {
        get { chatStore.nextStreamPartHapticAllowedAt }
        set { chatStore.nextStreamPartHapticAllowedAt = newValue }
    }
    var pendingTranscriptEvents: [OpenCodePendingTranscriptEvent] {
        get { chatStore.pendingTranscriptEvents }
        set { chatStore.replacePendingTranscriptEvents(newValue) }
    }
    var streamDeltaFlushTask: Task<Void, Never>? {
        get { chatStore.streamDeltaFlushTask }
        set { chatStore.streamDeltaFlushTask = newValue }
    }
    var streamDeltaFlushGeneration: Int {
        get { chatStore.streamDeltaFlushGeneration }
        set { chatStore.streamDeltaFlushGeneration = newValue }
    }
    var streamDeltaLastFlushAt: Date? {
        get { chatStore.streamDeltaLastFlushAt }
        set { chatStore.streamDeltaLastFlushAt = newValue }
    }
    var streamDeltaScheduledIntervalMS: Int? {
        get { chatStore.streamDeltaScheduledIntervalMS }
        set { chatStore.streamDeltaScheduledIntervalMS = newValue }
    }
    var streamDeltaScheduledActiveTextLength: Int {
        get { chatStore.streamDeltaScheduledActiveTextLength }
        set { chatStore.streamDeltaScheduledActiveTextLength = newValue }
    }
    var streamDeltaScheduledPendingCharacterCount: Int {
        get { chatStore.streamDeltaScheduledPendingCharacterCount }
        set { chatStore.streamDeltaScheduledPendingCharacterCount = newValue }
    }
    var storeObservationCancellables: Set<AnyCancellable> = []
    var isComposerStreamingFocused: Bool {
        get { composerStore.isStreamingFocused }
        set { composerStore.isStreamingFocused = newValue }
    }
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
        commerceFacade.hydratePersistedState(
            debugEntitlementRawValue: ProcessInfo.processInfo.environment["OPENCLIENT_DEBUG_ENTITLEMENT"]
        )
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
        appCustomizationStore.reconcileAutoConnectServer(in: recentConfigs)
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
            directoryStoreRegistry.objectWillChange.eraseToAnyPublisher(),
            commerceFacade.objectWillChange.eraseToAnyPublisher(),
            // Provider configuration changes need to invalidate configuration sheets immediately.
            modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
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
        isConnected || isUsingAppleIntelligence || backendMode == .cachedServer
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
        var sessionsByID: [String: OpenCodeSession] = [:]
        for session in sessions {
            sessionsByID[session.id] = session
        }
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
            updateEventInterestSnapshot()
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
            if let selectedSessionID = selectedSession?.id {
                directoryStore.applyCanonicalMessages(newValue, forSessionID: selectedSessionID)
            }
        }
        _modify {
            objectWillChange.send()
            yield &chatStore.messages
            if let selectedSessionID = selectedSession?.id {
                directoryStore.applyCanonicalMessages(chatStore.messages, forSessionID: selectedSessionID)
            }
        }
    }
    var commands: [OpenCodeCommand] {
        commands(canFork: selectedSession != nil && !forkableMessages.isEmpty)
    }

    func commands(canFork: Bool) -> [OpenCodeCommand] {
        var result = directoryCommands
        if selectedSession != nil, !result.contains(where: { $0.name == "compact" }) {
            result.append(OpenClientChatCommands.compact)
        }
        if selectedSession != nil, canFork, !result.contains(where: { $0.name == "fork" }) {
            result.append(OpenClientChatCommands.fork)
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
    var hasGitProject: Bool { currentProject?.vcs == "git" && effectiveSelectedDirectory != nil }
}
