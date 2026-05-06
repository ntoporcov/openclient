import Foundation

@MainActor
final class ConnectionCoordinator {
    private let connectionStore: ConnectionStore

    init(connectionStore: ConnectionStore) {
        self.connectionStore = connectionStore
    }

    func connect(
        client: OpenCodeAPIClient,
        applyBootstrap: @MainActor (OpenCodeGlobalBootstrap) async -> Void,
        handleFailure: @MainActor () -> Void
    ) async {
        connectionStore.beginConnecting()
        defer { connectionStore.finishConnecting() }

        do {
            let bootstrap = try await OpenCodeBootstrap.bootstrapGlobal(client: client)
            connectionStore.applySuccessfulServerConnection(
                version: bootstrap.health.version,
                healthy: bootstrap.health.healthy
            )
            await applyBootstrap(bootstrap)
        } catch {
            handleFailure()
            connectionStore.applyConnectionFailure(error)
        }
    }

    func disconnect(
        hasSavedServer: Bool,
        stopActiveWorkspace: @MainActor () -> Void,
        stopEventStream: @MainActor () -> Void,
        resetAppState: @MainActor () -> Void
    ) {
        stopActiveWorkspace()
        stopEventStream()
        connectionStore.resetToDisconnected(showPrompt: hasSavedServer)
        resetAppState()
    }

    func leaveAppleIntelligenceSession(
        preserveDraft: @MainActor () -> Void,
        stopActiveWorkspace: @MainActor () -> Void,
        resetAppState: @MainActor () -> Void,
        clearComposer: @MainActor () -> Void
    ) {
        preserveDraft()
        stopActiveWorkspace()
        connectionStore.resetToDisconnected()
        resetAppState()
        clearComposer()
    }
}
