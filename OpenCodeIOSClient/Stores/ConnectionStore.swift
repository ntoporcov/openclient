import Combine
import Foundation

enum OpenClientConnectionPhase: String, Equatable, Sendable {
    case idle
    case checkingServer
    case loadingWorkspace
    case preparingInterface
    case startingLiveUpdates

    var title: LocalizedStringResource {
        switch self {
        case .idle:
            return "Ready"
        case .checkingServer:
            return "Checking server"
        case .loadingWorkspace:
            return "Loading workspace"
        case .preparingInterface:
            return "Preparing interface"
        case .startingLiveUpdates:
            return "Starting live updates"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .idle:
            return "Waiting for coordinates."
        case .checkingServer:
            return "Tuning the antenna and looking for the OpenCode signal."
        case .loadingWorkspace:
            return "Negotiating with the tiny AI gremlins about projects and sessions."
        case .preparingInterface:
            return "Warming up models, agents, and other cockpit switches."
        case .startingLiveUpdates:
            return "Opening the event stream so tokens can arrive at warp speed."
        }
    }
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published var backendMode: AppBackendMode
    @Published var isConnected: Bool
    @Published var serverVersion: String
    @Published var apiProfile: OpenCodeAPIProfile?
    @Published private(set) var v2NoticeConnectionID: UUID?
    private var noticeSourceConnectionID: UUID?
    private var dismissedV2NoticeConnectionID: UUID?
    @Published var errorMessage: String? {
        didSet { transcriptErrorOwner = nil; promptErrorOwner = nil }
    }
    private var transcriptErrorOwner: (connectionID: UUID, sessionID: String)?
    private var promptErrorOwner: (connectionID: UUID, sessionID: String, messageID: String)?
    @Published var isLoading: Bool
    @Published var connectionPhase: OpenClientConnectionPhase
    @Published var isOfferingCachedServerConnection: Bool
    @Published var recentServerConfigs: [OpenCodeServerConfig]
    @Published var hasSavedServer: Bool
    @Published var showSavedServerPrompt: Bool
    @Published var savedServerEditorMode: OpenClientSavedServerEditorMode

    init(
        backendMode: AppBackendMode = .none,
        isConnected: Bool = false,
        serverVersion: String = "",
        apiProfile: OpenCodeAPIProfile? = nil,
        errorMessage: String? = nil,
        isLoading: Bool = false,
        connectionPhase: OpenClientConnectionPhase = .idle,
        isOfferingCachedServerConnection: Bool = false,
        recentServerConfigs: [OpenCodeServerConfig] = [],
        hasSavedServer: Bool = false,
        showSavedServerPrompt: Bool = false,
        savedServerEditorMode: OpenClientSavedServerEditorMode = .add
    ) {
        self.backendMode = backendMode
        self.isConnected = isConnected
        self.serverVersion = serverVersion
        self.apiProfile = apiProfile
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.connectionPhase = connectionPhase
        self.isOfferingCachedServerConnection = isOfferingCachedServerConnection
        self.recentServerConfigs = recentServerConfigs
        self.hasSavedServer = hasSavedServer
        self.showSavedServerPrompt = showSavedServerPrompt
        self.savedServerEditorMode = savedServerEditorMode
    }

    func beginConnecting() {
        bindNoticeConnection(nil)
        isLoading = true
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        errorMessage = nil
        isOfferingCachedServerConnection = false
        connectionPhase = .checkingServer
    }

    func updateConnectionPhase(_ phase: OpenClientConnectionPhase) {
        connectionPhase = phase
    }

    func resolveAPIProfile(_ profile: OpenCodeAPIProfile) {
        apiProfile = profile
    }

    func bindNoticeConnection(_ connectionID: UUID?) {
        guard noticeSourceConnectionID != connectionID else { return }
        noticeSourceConnectionID = connectionID
        v2NoticeConnectionID = nil
        dismissedV2NoticeConnectionID = nil
    }

    func dismissV2Notice(connectionID: UUID) {
        guard v2NoticeConnectionID == connectionID else { return }
        dismissedV2NoticeConnectionID = connectionID
        v2NoticeConnectionID = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func applyErrorMessage(_ message: String) {
        errorMessage = message
    }

    func applyTranscriptError(_ error: Error, connectionID: UUID, sessionID: String) {
        errorMessage = error.localizedDescription
        transcriptErrorOwner = (connectionID, sessionID)
    }

    func applyPromptError(_ message: String, connectionID: UUID, sessionID: String, messageID: String) {
        errorMessage = message
        promptErrorOwner = (connectionID, sessionID, messageID)
    }

    func clearPromptError(connectionID: UUID, sessionID: String, messageID: String) {
        guard promptErrorOwner?.connectionID == connectionID, promptErrorOwner?.sessionID == sessionID,
              promptErrorOwner?.messageID == messageID else { return }
        errorMessage = nil
    }

    func clearTranscriptError(connectionID: UUID, sessionID: String) {
        guard transcriptErrorOwner?.connectionID == connectionID,
              transcriptErrorOwner?.sessionID == sessionID else { return }
        errorMessage = nil
    }

    func finishConnecting() {
        isLoading = false
        if isConnected == false {
            connectionPhase = .idle
        }
    }

    func applySuccessfulServerConnection(version: String, healthy: Bool) {
        bindNoticeConnection(nil)
        backendMode = .server
        serverVersion = version
        apiProfile = .legacy
        errorMessage = nil
        isConnected = healthy
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
    }

    func applySuccessfulV2Connection(version: String, healthy: Bool) {
        backendMode = .serverV2
        serverVersion = version
        apiProfile = .v2
        errorMessage = nil
        isConnected = healthy
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
        // Profile detection alone is not success: only post-bootstrap calls arm the notice.
        v2NoticeConnectionID = healthy && noticeSourceConnectionID != dismissedV2NoticeConnectionID
            ? noticeSourceConnectionID : nil
    }

    func applyConnectionFailure(_ error: Error) {
        bindNoticeConnection(nil)
        backendMode = .none
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        errorMessage = error.localizedDescription
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
    }

    func applyConnectionCancellation() {
        bindNoticeConnection(nil)
        backendMode = .none
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        isLoading = false
        errorMessage = nil
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
    }

    func offerCachedServerConnection() {
        bindNoticeConnection(nil)
        backendMode = .none
        isConnected = false
        apiProfile = nil
        isOfferingCachedServerConnection = true
        connectionPhase = .idle
    }

    func dismissCachedServerConnectionOffer() {
        isOfferingCachedServerConnection = false
    }

    func applyCachedServerConnection(preservingError: Bool = false) {
        bindNoticeConnection(nil)
        backendMode = .cachedServer
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        if preservingError == false {
            errorMessage = nil
        }
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
    }

    func resetToDisconnected(showPrompt: Bool? = nil) {
        bindNoticeConnection(nil)
        backendMode = .none
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        errorMessage = nil
        isOfferingCachedServerConnection = false
        connectionPhase = .idle
        if let showPrompt {
            showSavedServerPrompt = showPrompt
        }
    }

    func applyAppleIntelligenceMode() {
        bindNoticeConnection(nil)
        backendMode = .appleIntelligence
        isConnected = false
        serverVersion = ""
        apiProfile = nil
        errorMessage = nil
        isOfferingCachedServerConnection = false
    }

    func prepareAddServerSheet() {
        errorMessage = nil
        savedServerEditorMode = .add
    }

    func prepareEditServerSheet(originalServerID: String) {
        errorMessage = nil
        savedServerEditorMode = .edit(originalServerID: originalServerID)
    }

    func dismissServerSheet() {
        savedServerEditorMode = .add
        errorMessage = nil
    }

    func markSavedServerPromptDismissed() {
        showSavedServerPrompt = false
    }

    func markSavedServerPersistenceComplete() {
        savedServerEditorMode = .add
        showSavedServerPrompt = false
    }

    func setRecentServerConfigs(_ configs: [OpenCodeServerConfig]) {
        recentServerConfigs = configs
        hasSavedServer = recentServerConfigs.isEmpty == false
    }

    @discardableResult
    func upsertRecentServerConfig(
        _ updatedConfig: OpenCodeServerConfig,
        replacingServerID originalServerID: String?
    ) -> OpenCodeServerConfig? {
        let updatedID = updatedConfig.recentServerID
        let replacedConfig = originalServerID.flatMap { originalID in
            recentServerConfigs.first { $0.recentServerID == originalID }
        }

        var orderedConfigs = [updatedConfig]
        orderedConfigs.append(contentsOf: recentServerConfigs.filter { existing in
            if existing.recentServerID == updatedID {
                return false
            }

            if let originalServerID, existing.recentServerID == originalServerID {
                return false
            }

            return true
        })

        setRecentServerConfigs(orderedConfigs)
        return replacedConfig
    }

    func updateRecentServerPassword(for serverID: String, password: String) {
        guard let index = recentServerConfigs.firstIndex(where: { $0.recentServerID == serverID }) else { return }
        recentServerConfigs[index].password = password
    }

    func removeRecentServer(_ serverConfig: OpenCodeServerConfig) {
        recentServerConfigs.removeAll { $0.recentServerID == serverConfig.recentServerID }
        hasSavedServer = recentServerConfigs.isEmpty == false
        showSavedServerPrompt = hasSavedServer && showSavedServerPrompt
    }

    func clearRecentServers() {
        recentServerConfigs = []
        hasSavedServer = false
        showSavedServerPrompt = false
    }
}
