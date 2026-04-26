import Foundation
import SwiftUI

let opencodeSelectionAnimation = Animation.snappy(duration: 0.28, extraBounce: 0.02)
let defaultAppleIntelligenceUserInstructions = ""
let defaultAppleIntelligenceSystemInstructions = ""

@MainActor
final class AppViewModel: ObservableObject {
    enum SavedServerEditorMode: Equatable {
        case add
        case edit(originalServerID: String)
    }

    enum ProjectContentTab: String, CaseIterable {
        case sessions
        case git

        var title: String {
            switch self {
            case .sessions:
                return "Sessions"
            case .git:
                return "Files"
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
    }

    @Published var config = OpenCodeServerConfig()
    @Published var backendMode: AppBackendMode = .none
    @Published var isConnected = false
    @Published var serverVersion = ""
    @Published var appleIntelligenceRecentWorkspaces: [AppleIntelligenceWorkspaceRecord] = []
    @Published var activeAppleIntelligenceWorkspaceID: String?
    @Published var isShowingAppleIntelligenceFolderPicker = false
    @Published var projects: [OpenCodeProject] = []
    @Published var currentProject: OpenCodeProject?
    @Published var selectedDirectory: String?
    @Published var selectedProjectContentTab: ProjectContentTab = .sessions
    @Published var isShowingProjectPicker = false
    @Published var projectSearchQuery = ""
    @Published var projectSearchResults: [String] = []
    @Published var isShowingCreateProjectSheet = false
    @Published var createProjectQuery = ""
    @Published var createProjectResults: [String] = []
    @Published var createProjectSelectedDirectory: String?
    @Published var directoryState = OpenCodeDirectoryState()
    @Published var toolMessageDetails: [String: OpenCodeMessageEnvelope] = [:]
    @Published var cachedMessagesBySessionID: [String: [OpenCodeMessageEnvelope]] = [:]
    @Published var sessionPreviews: [String: SessionPreview] = [:]
    @Published var pinnedSessionIDsByScope: [String: [String]] = [:]
    @Published var liveActivityAutoStartByScope: [String: Bool] = [:]
    @Published var draftTitle = ""
    @Published var draftMessage = ""
    @Published var draftAttachments: [OpenCodeComposerAttachment] = []
    @Published var composerResetToken = UUID()
    @Published var errorMessage: String?
    @Published var appleIntelligenceDebugPickedPath = ""
    @Published var appleIntelligenceDebugActivePath = ""
    @Published var appleIntelligenceDebugResolvedPath = ""
    @Published var appleIntelligenceDebugToolRootPath = ""
    @Published var isShowingAppleIntelligenceInstructionsSheet = false
    @Published var appleIntelligenceUserInstructions = ""
    @Published var appleIntelligenceSystemInstructions = ""
    @Published var isLoading = false
    @Published var recentServerConfigs: [OpenCodeServerConfig] = []
    @Published var hasSavedServer = false
    @Published var showSavedServerPrompt = false
    @Published var isShowingAddServerSheet = false
    @Published var savedServerEditorMode: SavedServerEditorMode = .add
    @Published var isShowingCreateSessionSheet = false
    @Published var isShowingConfigurationsSheet = false
    @Published var isShowingForkSessionSheet = false
    @Published var debugLastEventSummary = ""
    @Published var debugProbeLog: [String] = []
    @Published var isShowingDebugProbe = false
    @Published var isRunningDebugProbe = false
    @Published var debugLastControlSummary = ""
    @Published var availableAgents: [OpenCodeAgent] = []
    @Published var availableProviders: [OpenCodeProvider] = []
    @Published var defaultModelsByProviderID: [String: String] = [:]
    @Published var selectedAgentNamesBySessionID: [String: String] = [:]
    @Published var selectedModelsBySessionID: [String: OpenCodeModelReference] = [:]
    @Published var selectedVariantsBySessionID: [String: String] = [:]
    @Published var newSessionDefaults = NewSessionDefaults()
    @Published var activeLiveActivitySessionIDs: Set<String> = []
    @Published var activeChatSessionID: String?

    let passwordStore = OpenCodeServerPasswordStore()

    let eventManager = OpenCodeEventManager()
    var eventStreamRestartTask: Task<Void, Never>?
    var reloadTask: Task<Void, Never>?
    var liveRefreshTask: Task<Void, Never>?
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
    var liveRefreshGeneration = 0
    var lastFallbackMessageCount = 0
    var lastFallbackAssistantLength = 0
    var nextStreamPartHapticAllowedAt = Date.distantPast
    var liveActivityPreviewRefreshTasksBySessionID: [String: Task<Void, Never>] = [:]

    let debugProbePrompt = "Write four short paragraphs about why responsive streaming matters in mobile AI apps. Make each paragraph 2-3 sentences."
    let defaultSearchRoot = NSHomeDirectory()

    init() {
        if configureUITestEnvironmentIfNeeded() {
            return
        }

        let recentConfigs = loadRecentServerConfigs()
        appleIntelligenceUserInstructions = defaultAppleIntelligenceUserInstructions
        appleIntelligenceSystemInstructions = defaultAppleIntelligenceSystemInstructions
        sessionPreviews = loadSessionPreviews()
        pinnedSessionIDsByScope = loadPinnedSessionIDsByScope()
        liveActivityAutoStartByScope = loadLiveActivityAutoStartByScope()
        recentServerConfigs = recentConfigs
        hasSavedServer = recentConfigs.isEmpty == false
        showSavedServerPrompt = hasSavedServer
        if let savedConfig = recentConfigs.first {
            config = savedConfig
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

    var sessions: [OpenCodeSession] { directoryState.sessions.filter(\.isRootSession) }

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
        get { directoryState.selectedSession }
        set { directoryState.selectedSession = newValue }
    }

    var messages: [OpenCodeMessageEnvelope] { directoryState.messages }
    var commands: [OpenCodeCommand] {
        var result = directoryState.commands
        if selectedSession != nil, !forkableMessages.isEmpty, !result.contains(where: { $0.name == "fork" }) {
            result.append(Self.forkClientCommand)
        }
        return result
    }
    var sessionStatuses: [String: String] { directoryState.sessionStatuses }
    var todos: [OpenCodeTodo] { directoryState.todos }
    var permissions: [OpenCodePermission] { directoryState.permissions }
    var questions: [OpenCodeQuestionRequest] { directoryState.questions }
    var vcsInfo: OpenCodeVCSInfo? { directoryState.vcsInfo }
    var vcsFileStatuses: [OpenCodeVCSFileStatus] { directoryState.vcsFileStatuses }
    var projectFilesMode: OpenCodeProjectFilesMode {
        get { directoryState.projectFilesMode }
        set { directoryState.projectFilesMode = newValue }
    }
    var fileTreeRootNodes: [OpenCodeFileNode] { directoryState.fileTreeRootNodes }
    var selectedProjectFilePath: String? {
        get { directoryState.selectedProjectFilePath }
        set { directoryState.selectedProjectFilePath = newValue }
    }
    var selectedVCSDiffMode: OpenCodeVCSDiffMode {
        get { directoryState.selectedVCSMode }
        set { directoryState.selectedVCSMode = newValue }
    }
    var selectedVCSFile: String? {
        get { directoryState.selectedVCSFile }
        set { directoryState.selectedVCSFile = newValue }
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
    var hasGitProject: Bool { currentProject?.vcs == "git" && effectiveSelectedDirectory != nil }
    var currentVCSDiffs: [OpenCodeVCSFileDiff] { directoryState.vcsDiffsByMode[selectedVCSDiffMode] ?? [] }
    var selectedProjectFileContent: OpenCodeFileContent? {
        guard let selectedProjectFilePath else { return nil }
        return directoryState.fileContentsByPath[selectedProjectFilePath]
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
}
