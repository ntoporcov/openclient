import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class OpenClientBridgeCoordinator {
    private let store: OpenClientBridgeStore
    private let connectionStore: ConnectionStore
    private let chatStore: ChatStore
    private let configProvider: @MainActor () -> OpenCodeServerConfig
    private let client: any OpenClientBridgeConnecting
    private var observations: Set<AnyCancellable> = []
    private var lifecycleTask: Task<Void, Never>?
    private var sessionUpdateTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var lifecycleID = UUID()
    private let reconnectDelay: @MainActor (Int) -> Duration

    init(
        store: OpenClientBridgeStore,
        connectionStore: ConnectionStore,
        chatStore: ChatStore,
        configProvider: @escaping @MainActor () -> OpenCodeServerConfig,
        client: any OpenClientBridgeConnecting = OpenClientBridgeClient(),
        reconnectDelay: @escaping @MainActor (Int) -> Duration = { attempt in
            .seconds(min(15, 1 << min(attempt, 4)))
        }
    ) {
        self.store = store
        self.connectionStore = connectionStore
        self.chatStore = chatStore
        self.configProvider = configProvider
        self.client = client
        self.reconnectDelay = reconnectDelay

        Publishers.CombineLatest4(
            connectionStore.$backendMode,
            connectionStore.$isConnected,
            connectionStore.$connectionPhase,
            connectionStore.$apiProfile
        )
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 && $0.3 == $1.3 }
            .sink { [weak self] backendMode, isConnected, connectionPhase, apiProfile in
                self?.connectionStateChanged(
                    backendMode: backendMode,
                    isConnected: isConnected,
                    connectionPhase: connectionPhase,
                    apiProfile: apiProfile
                )
            }
            .store(in: &observations)

        chatStore.$activeChatSessionID
            .removeDuplicates()
            .sink { [weak self] sessionID in
                guard let self else { return }
                let previousUpdate = sessionUpdateTask
                sessionUpdateTask = Task {
                    await previousUpdate?.value
                    guard !Task.isCancelled else { return }
                    await client.updateSession(sessionID)
                }
            }
            .store(in: &observations)

#if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconcileConnection() }
            .store(in: &observations)
#elseif canImport(AppKit)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reconcileConnection() }
            .store(in: &observations)
#endif
    }

    deinit {
        lifecycleTask?.cancel()
        sessionUpdateTask?.cancel()
        reconnectTask?.cancel()
        let client = client
        Task { await client.disconnect() }
    }

    func start() {
        connectionStateChanged()
    }

    func forceConnect() {
        guard shouldConnect else {
            store.apply(.disconnected("Connect to an OpenCode server before connecting to its plugin bridge."))
            return
        }
        reconnectAttempt = 0
        reconcileConnection()
    }

    private var shouldConnect: Bool {
        shouldConnect(
            backendMode: connectionStore.backendMode,
            isConnected: connectionStore.isConnected,
            connectionPhase: connectionStore.connectionPhase,
            apiProfile: connectionStore.apiProfile
        )
    }

    private func shouldConnect(
        backendMode: AppBackendMode,
        isConnected: Bool,
        connectionPhase: OpenClientConnectionPhase,
        apiProfile: OpenCodeAPIProfile?
    ) -> Bool {
        guard store.isEnabled else { return false }
        guard apiProfile != .v2 else { return false }
        if backendMode == .server && isConnected {
            return true
        }
        switch connectionPhase {
        case .loadingWorkspace, .preparingInterface, .startingLiveUpdates:
            return true
        case .idle, .checkingServer:
            return false
        }
    }

    private func connectionStateChanged() {
        connectionStateChanged(
            backendMode: connectionStore.backendMode,
            isConnected: connectionStore.isConnected,
            connectionPhase: connectionStore.connectionPhase,
            apiProfile: connectionStore.apiProfile
        )
    }

    private func connectionStateChanged(
        backendMode: AppBackendMode,
        isConnected: Bool,
        connectionPhase: OpenClientConnectionPhase,
        apiProfile: OpenCodeAPIProfile?
    ) {
        let connect = shouldConnect(
            backendMode: backendMode,
            isConnected: isConnected,
            connectionPhase: connectionPhase,
            apiProfile: apiProfile
        )
        guard connect else {
            if store.phase != .idle || lifecycleTask != nil || reconnectTask != nil {
                reconcileConnection(connect: false)
            }
            return
        }
        switch store.phase {
        case .idle:
            guard lifecycleTask == nil, reconnectTask == nil else { return }
            reconcileConnection(connect: true)
        case .searching, .connecting, .connected:
            return
        }
    }

    private func reconcileConnection(connect requestedConnectionState: Bool? = nil) {
        reconnectTask?.cancel()
        reconnectTask = nil
        lifecycleTask?.cancel()
        let lifecycleID = UUID()
        self.lifecycleID = lifecycleID
        let connect = requestedConnectionState ?? shouldConnect
        let config = connect ? configProvider() : OpenCodeServerConfig()
        let registration = OpenClientBridgeRegistration(
            clientID: store.clientID,
            displayName: store.displayName,
            appVersion: store.appVersion
        )
        let initialSessionID = chatStore.activeChatSessionID
        if !connect {
            reconnectAttempt = 0
            store.reset()
        }

        lifecycleTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, lifecycleID == self.lifecycleID else { return }
            await client.disconnect()
            guard !Task.isCancelled, lifecycleID == self.lifecycleID, connect else {
                if lifecycleID == self.lifecycleID { lifecycleTask = nil }
                return
            }
            do {
                try await client.connect(
                    config: config,
                    registration: registration,
                    initialSessionID: initialSessionID
                ) { [weak self] event in
                    Task { @MainActor in self?.handle(event, lifecycleID: lifecycleID) }
                }
                guard !Task.isCancelled, lifecycleID == self.lifecycleID else { return }
                lifecycleTask = nil
            } catch {
                guard !Task.isCancelled, lifecycleID == self.lifecycleID else { return }
                lifecycleTask = nil
                store.apply(.disconnected(error.localizedDescription))
                scheduleReconnect()
            }
        }
    }

    private func handle(_ event: OpenClientBridgeClientEvent, lifecycleID: UUID) {
        guard lifecycleID == self.lifecycleID else { return }
        store.apply(event)
        if case .connected = event {
            reconnectAttempt = 0
        } else if case .disconnected = event {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard shouldConnect, reconnectTask == nil else { return }
        let delay = reconnectDelay(reconnectAttempt)
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            reconnectTask = nil
            reconcileConnection()
        }
    }
}
