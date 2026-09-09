import Foundation

@MainActor
final class ConnectionCoordinator {
    private let connectionStore: ConnectionStore

    init(connectionStore: ConnectionStore) {
        self.connectionStore = connectionStore
    }

    func connect(
        client: OpenCodeAPIClient,
        isCurrentAttempt: @MainActor () -> Bool = { true },
        applyLegacyBootstrap: @MainActor (OpenCodeGlobalBootstrap) async -> Void,
        applyV2Connection: @MainActor () async throws -> Void,
        handleFailure: @MainActor () -> Void
    ) async {
        await connect(
            factory: OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager()),
            isCurrentAttempt: isCurrentAttempt,
            applyConnection: { connection in
                if connection.openCodeCompatibility?.profile == .v2 {
                    try await applyV2Connection()
                } else {
                    let snapshot = try await connection.projects.projectsSnapshot()
                    try Task.checkCancellation()
                    guard isCurrentAttempt() else { return }
                    self.connectionStore.updateConnectionPhase(.preparingInterface)
                    await applyLegacyBootstrap(.init(
                        health: .init(healthy: connection.healthy, version: connection.descriptor.version),
                        projects: snapshot.projects, currentProject: snapshot.currentProject
                    ))
                }
            },
            handleFailure: handleFailure
        )
    }

    func connect(
        factory: any BackendFactory,
        isCurrentAttempt: @MainActor () -> Bool = { true },
        applyConnection: @MainActor (BackendConnection) async throws -> Void,
        handleFailure: @MainActor () -> Void
    ) async {
        guard isCurrentAttempt() else { return }
        connectionStore.beginConnecting()
        var opened: BackendConnection?
        var retained = false
        defer {
            if !retained { opened?.close() }
            if isCurrentAttempt() {
                connectionStore.finishConnecting()
            }
        }

        do {
            let connection = try await factory.connect()
            opened = connection
            try Task.checkCancellation()
            guard isCurrentAttempt() else { return }
            if let profile = connection.openCodeCompatibility?.profile {
                connectionStore.resolveAPIProfile(profile)
            }
            connectionStore.updateConnectionPhase(.loadingWorkspace)
            try await applyConnection(connection)
            try Task.checkCancellation()
            guard isCurrentAttempt() else { return }
            if connection.openCodeCompatibility?.profile == .v2 {
                connectionStore.applySuccessfulV2Connection(version: connection.descriptor.version, healthy: connection.healthy)
            } else {
                connectionStore.applySuccessfulServerConnection(version: connection.descriptor.version, healthy: connection.healthy)
                // A third backend is a remote connection, not an OpenCode legacy connection.
                connectionStore.apiProfile = connection.openCodeCompatibility?.profile
            }
            retained = connection.healthy
        } catch is CancellationError {
            guard isCurrentAttempt() else { return }
            handleFailure()
            connectionStore.applyConnectionCancellation()
        } catch {
            guard isCurrentAttempt() else { return }
            handleFailure()
            connectionStore.applyConnectionFailure(error)
        }
    }

    func updateConnectionPhase(_ phase: OpenClientConnectionPhase) {
        connectionStore.updateConnectionPhase(phase)
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
