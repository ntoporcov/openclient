import Foundation
import SwiftUI

let opencodeSelectionAnimation = Animation.snappy(duration: 0.28, extraBounce: 0.02)
let defaultAppleIntelligenceUserInstructions = ""
let defaultAppleIntelligenceSystemInstructions = ""

@MainActor
final class AppViewModel: ObservableObject {
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
        static let lastServerConfig = "lastServerConfig"
        static let recentServerConfigs = "recentServerConfigs"
        static let newSessionDefaults = "newSessionDefaults"
        static let appleIntelligenceWorkspaces = "appleIntelligenceWorkspaces"
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
    @Published var sessionPreviews: [String: SessionPreview] = [:]
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
    @Published var isShowingCreateSessionSheet = false
    @Published var isShowingConfigurationsSheet = false
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

    let debugProbePrompt = "Write four short paragraphs about why responsive streaming matters in mobile AI apps. Make each paragraph 2-3 sentences."
    let defaultSearchRoot = NSHomeDirectory()

    init() {
        if configureUITestEnvironmentIfNeeded() {
            return
        }

        let recentConfigs = loadRecentServerConfigs()
        appleIntelligenceUserInstructions = defaultAppleIntelligenceUserInstructions
        appleIntelligenceSystemInstructions = defaultAppleIntelligenceSystemInstructions
        if let savedConfig = recentConfigs.first {
            recentServerConfigs = recentConfigs
            config = savedConfig
            hasSavedServer = true
            showSavedServerPrompt = true
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

    var sessions: [OpenCodeSession] { directoryState.sessions }

    var selectedSession: OpenCodeSession? {
        get { directoryState.selectedSession }
        set { directoryState.selectedSession = newValue }
    }

    var messages: [OpenCodeMessageEnvelope] { directoryState.messages }
    var commands: [OpenCodeCommand] { directoryState.commands }
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
