import Foundation
import SwiftUI

let opencodeSelectionAnimation = Animation.snappy(duration: 0.28, extraBounce: 0.02)

@MainActor
final class AppViewModel: ObservableObject {
    enum StorageKey {
        static let lastServerConfig = "lastServerConfig"
        static let newSessionDefaults = "newSessionDefaults"
    }

    @Published var config = OpenCodeServerConfig()
    @Published var isConnected = false
    @Published var serverVersion = ""
    @Published var projects: [OpenCodeProject] = []
    @Published var currentProject: OpenCodeProject?
    @Published var selectedDirectory: String?
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
    @Published var composerResetToken = UUID()
    @Published var errorMessage: String?
    @Published var isLoading = false
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

        if let savedConfig = loadSavedConfig() {
            config = savedConfig
            hasSavedServer = true
            showSavedServerPrompt = true
        }
    }

    var client: OpenCodeAPIClient {
        OpenCodeAPIClient(config: config)
    }

    var sessions: [OpenCodeSession] { directoryState.sessions }

    var selectedSession: OpenCodeSession? {
        get { directoryState.selectedSession }
        set { directoryState.selectedSession = newValue }
    }

    var messages: [OpenCodeMessageEnvelope] { directoryState.messages }
    var sessionStatuses: [String: String] { directoryState.sessionStatuses }
    var todos: [OpenCodeTodo] { directoryState.todos }
    var permissions: [OpenCodePermission] { directoryState.permissions }
    var questions: [OpenCodeQuestionRequest] { directoryState.questions }
}
