import Combine
import Foundation

@MainActor
final class ConnectionStore: ObservableObject {
    @Published var backendMode: AppBackendMode
    @Published var isConnected: Bool
    @Published var serverVersion: String
    @Published var errorMessage: String?
    @Published var isLoading: Bool
    @Published var recentServerConfigs: [OpenCodeServerConfig]
    @Published var hasSavedServer: Bool
    @Published var showSavedServerPrompt: Bool
    @Published var savedServerEditorMode: AppViewModel.SavedServerEditorMode

    init(
        backendMode: AppBackendMode = .none,
        isConnected: Bool = false,
        serverVersion: String = "",
        errorMessage: String? = nil,
        isLoading: Bool = false,
        recentServerConfigs: [OpenCodeServerConfig] = [],
        hasSavedServer: Bool = false,
        showSavedServerPrompt: Bool = false,
        savedServerEditorMode: AppViewModel.SavedServerEditorMode = .add
    ) {
        self.backendMode = backendMode
        self.isConnected = isConnected
        self.serverVersion = serverVersion
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.recentServerConfigs = recentServerConfigs
        self.hasSavedServer = hasSavedServer
        self.showSavedServerPrompt = showSavedServerPrompt
        self.savedServerEditorMode = savedServerEditorMode
    }

    func beginConnecting() {
        isLoading = true
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func applyErrorMessage(_ message: String) {
        errorMessage = message
    }

    func finishConnecting() {
        isLoading = false
    }

    func applySuccessfulServerConnection(version: String, healthy: Bool) {
        backendMode = .server
        serverVersion = version
        errorMessage = nil
        isConnected = healthy
    }

    func applyConnectionFailure(_ error: Error) {
        backendMode = .none
        isConnected = false
        errorMessage = error.localizedDescription
    }

    func resetToDisconnected(showPrompt: Bool? = nil) {
        backendMode = .none
        isConnected = false
        serverVersion = ""
        errorMessage = nil
        if let showPrompt {
            showSavedServerPrompt = showPrompt
        }
    }

    func applyAppleIntelligenceMode() {
        backendMode = .appleIntelligence
        isConnected = false
        serverVersion = ""
        errorMessage = nil
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

    func setRecentServerConfigs(_ configs: [OpenCodeServerConfig], maxCount: Int) {
        recentServerConfigs = Array(configs.prefix(maxCount))
        hasSavedServer = recentServerConfigs.isEmpty == false
    }

    @discardableResult
    func upsertRecentServerConfig(
        _ updatedConfig: OpenCodeServerConfig,
        replacingServerID originalServerID: String?,
        maxCount: Int
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

        setRecentServerConfigs(orderedConfigs, maxCount: maxCount)
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
