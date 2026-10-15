import Combine
import Foundation
import SwiftUI

@MainActor
final class MCPFacade: ObservableObject {
    struct Snapshot: Hashable {
        let servers: [OpenCodeMCPServer]
        let connectedServerCount: Int
        let isLoading: Bool
        let togglingServerNames: Set<String>
        let errorMessage: String?
        var managed: BackendMCPState? = nil
    }

    struct ManagedToggleRequest: Identifiable, Hashable {
        let id: UUID
        let connectionID: UUID
        let contextID: String?
        let directory: String?
        let workspaceID: String?
        let serverID: String
        let serverName: String
        let enabled: Bool
        let previousEnabled: Bool
        let scope: BackendMCPScope
        fileprivate let revision: UUID

        var confirmationMessage: LocalizedStringResource {
            "This changes \"\(serverName)\" for all projects, chats, and users on this DSH server profile, not just this chat. A server restart may be required."
        }
    }

    private let store: MCPStore
    private let clientProvider: () -> OpenCodeAPIClient?
    private let directoryProvider: () -> String?
    private let apiProfileProvider: () -> OpenCodeAPIProfile?
    private let workspaceIDProvider: () -> String?
    private let contextIDProvider: () -> String?
    private var observation: AnyCancellable?
    private let connectionProvider: (() -> BackendConnection?)?
    private var connectionObservation: AnyCancellable?
    private var managedObservation: AnyCancellable?
    private var boundConnectionID: UUID?
    private var boundServiceID: ObjectIdentifier?
    private var hasManagedContext = false
    private var confirmationRevision = UUID()

    /// Derived presentation identity, not another copy of canonical MCP state.
    private struct PresentationContext: Equatable {
        let connectionID: UUID?
        let serviceID: ObjectIdentifier?
        let contextID: String?
        let directory: String?
        let workspaceID: String?
        let profile: OpenCodeAPIProfile?
        let clientConfig: OpenCodeServerConfig?
        let isAvailable: Bool
    }
    private var observedContext: PresentationContext?

    init(
        store: MCPStore,
        clientProvider: @escaping () -> OpenCodeAPIClient?,
        directoryProvider: @escaping () -> String?,
        apiProfileProvider: @escaping () -> OpenCodeAPIProfile? = { .legacy },
        workspaceIDProvider: @escaping () -> String? = { nil },
        contextIDProvider: @escaping () -> String? = { nil },
        connectionProvider: (() -> BackendConnection?)? = nil,
        contextChanges: AnyPublisher<Void, Never>? = nil
    ) {
        self.store = store
        self.clientProvider = clientProvider
        self.directoryProvider = directoryProvider
        self.apiProfileProvider = apiProfileProvider
        self.workspaceIDProvider = workspaceIDProvider
        self.contextIDProvider = contextIDProvider
        self.connectionProvider = connectionProvider
        observedContext = presentationContext()
        connectionObservation = contextChanges?.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self else { return }
            let next = self.presentationContext()
            guard next != self.observedContext else { return }
            let affectsManagedPresentation = self.observedContext?.serviceID != nil || next.serviceID != nil || self.boundServiceID != nil
            self.observedContext = next
            self.bindManagedService()
            // Legacy context/store observations already own their invalidation timing.
            // Only actual transitions involving managed MCP add a deferred relay.
            if affectsManagedPresentation { self.objectWillChange.send() }
        }
        observation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var managedContextIdentity: String {
        "\(connectionProvider?()?.id.uuidString ?? "unavailable")|\(contextIDProvider() ?? "")|\(directoryProvider() ?? "")|\(workspaceIDProvider() ?? "")"
    }

    var isAvailable: Bool {
        bindManagedService()
        if let connectionProvider {
            guard let connection = connectionProvider() else {
                // Legacy presentation capability is independent of profile hydration.
                // Reads/writes still require an explicit profile below.
                return !hasManagedContext && clientProvider() != nil
            }
            guard !connection.isClosed, connection.capabilities.contains(.mcp) else { return false }
            return connection.mcp != nil || clientProvider() != nil
        }
        return clientProvider() != nil
    }

    var snapshot: Snapshot {
        bindManagedService()
        if let connection = currentManagedConnection, let service = connection.mcp {
            let state = service.state
            return Snapshot(servers: [], connectedServerCount: 0, isLoading: state.isLoading,
                            togglingServerNames: [], errorMessage: state.errorMessage,
                            managed: state.isCurrent ? state : unavailableManagedState(error: state.errorMessage, loading: state.isLoading, notice: state.notice))
        }
        if connectionProvider != nil && !isAvailable {
            return Snapshot(servers: [], connectedServerCount: 0, isLoading: false, togglingServerNames: [], errorMessage: nil,
                            managed: hasManagedContext ? unavailableManagedState() : nil)
        }
        return Snapshot(
            servers: store.servers,
            connectedServerCount: store.connectedServerCount,
            isLoading: store.isLoading,
            togglingServerNames: store.togglingServerNames,
            errorMessage: store.errorMessage
        )
    }

    func loadIfNeeded() async {
        // There is no remote event stream for profile CLI edits: every entry refreshes.
        if currentManagedConnection != nil { await reload(); return }
        guard store.shouldLoadStatus() else { return }
        await reload()
    }

    func reload() async {
        bindManagedService()
        if let service = currentManagedConnection?.mcp { await service.refresh(); return }
        guard connectionProvider == nil || isAvailable else { return }
        guard let client = clientProvider(), let profile = apiProfileProvider() else { return }
        let directory = directoryProvider()
        let workspaceID = workspaceIDProvider()
        let contextID = contextIDProvider()
        store.beginLoading()
        defer { if isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) { store.finishLoading() } }

        do {
            let statuses = try await (profile == .v2
                ? client.listV2MCPStatus(directory: directory, workspaceID: workspaceID)
                : client.listMCPStatus(directory: directory, workspaceID: workspaceID))
            guard !Task.isCancelled, isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) else { return }
            withAnimation(opencodeSelectionAnimation) {
                store.applyLoadedStatuses(statuses)
            }
        } catch {
            guard !Task.isCancelled, isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) else { return }
            store.applyLoadError(error)
        }
    }

    func toggleServer(name: String) async {
        // Profile management always requires the separate captured confirmation path.
        guard currentManagedConnection == nil, connectionProvider == nil || isAvailable else { return }
        guard let client = clientProvider(), let profile = apiProfileProvider() else { return }
        let directory = directoryProvider()
        let workspaceID = workspaceIDProvider()
        let contextID = contextIDProvider()
        guard store.beginToggling(name: name) else { return }
        defer { if isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) { store.finishToggling(name: name) } }

        do {
            if store.isConnected(name: name) {
                if profile == .v2 {
                    try await client.disconnectV2MCPServer(name: name, directory: directory, workspaceID: workspaceID)
                } else {
                    try await client.disconnectMCPServer(name: name, directory: directory, workspaceID: workspaceID)
                }
            } else {
                if profile == .v2 {
                    try await client.connectV2MCPServer(name: name, directory: directory, workspaceID: workspaceID)
                } else {
                    try await client.connectMCPServer(name: name, directory: directory, workspaceID: workspaceID)
                }
            }

            guard !Task.isCancelled, isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) else { return }
            let statuses = try await (profile == .v2
                ? client.listV2MCPStatus(directory: directory, workspaceID: workspaceID)
                : client.listMCPStatus(directory: directory, workspaceID: workspaceID))
            guard !Task.isCancelled, isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) else { return }
            withAnimation(opencodeSelectionAnimation) {
                store.applyLoadedStatuses(statuses)
            }
        } catch {
            guard !Task.isCancelled, isCurrent(client: client, directory: directory, workspaceID: workspaceID, profile: profile, contextID: contextID) else { return }
            store.applyToggleError(error)
        }
    }

    func reset() {
        // A project/window reset must not clear the connection-owned profile state.
        confirmationRevision = UUID()
        managedObservation = nil
        boundConnectionID = nil
        boundServiceID = nil
        store.reset()
    }

    func captureManagedToggle(id: String, enabled: Bool) -> ManagedToggleRequest? {
        bindManagedService()
        guard let connection = currentManagedConnection, let service = connection.mcp,
              service.state.isCurrent, !service.state.isLoading,
              let row = service.state.servers.first(where: { $0.id == id }),
              row.scope == .profile, row.canToggle, row.restriction == nil,
              let previous = row.enabled, previous != enabled,
              !service.state.togglingIDs.contains(id) else { return nil }
        return .init(id: UUID(), connectionID: connection.id, contextID: contextIDProvider(),
                     directory: directoryProvider(), workspaceID: workspaceIDProvider(), serverID: id,
                     serverName: row.name, enabled: enabled, previousEnabled: previous, scope: .profile, revision: confirmationRevision)
    }

    func confirmManagedToggle(_ request: ManagedToggleRequest) async {
        bindManagedService()
        guard let connection = currentManagedConnection, connection.id == request.connectionID,
              confirmationRevision == request.revision, request.scope == .profile, contextIDProvider() == request.contextID,
              directoryProvider() == request.directory, workspaceIDProvider() == request.workspaceID,
              let service = connection.mcp, service.state.isCurrent, !service.state.isLoading,
              let row = service.state.servers.first(where: { $0.id == request.serverID }),
              row.scope == .profile, row.canToggle, row.restriction == nil,
              row.enabled == request.previousEnabled, !service.state.togglingIDs.contains(row.id) else { return }
        // Consume this confirmation before awaiting so double taps cannot replay it.
        confirmationRevision = UUID()
        await service.setEnabled(id: row.id, enabled: request.enabled)
    }

    private func presentationContext() -> PresentationContext {
        let connection = connectionProvider?()
        let client = clientProvider()
        let available: Bool
        if let connection {
            available = !connection.isClosed && connection.capabilities.contains(.mcp) && (connection.mcp != nil || client != nil)
        } else {
            available = !hasManagedContext && client != nil
        }
        return .init(connectionID: connection?.id, serviceID: connection?.mcp.map { ObjectIdentifier($0) },
                     contextID: contextIDProvider(), directory: directoryProvider(), workspaceID: workspaceIDProvider(),
                     profile: apiProfileProvider(), clientConfig: client?.config, isAvailable: available)
    }

    private var currentManagedConnection: BackendConnection? {
        guard let connection = connectionProvider?(), !connection.isClosed,
              connection.capabilities.contains(.mcp), connection.mcp != nil else { return nil }
        return connection
    }

    private func unavailableManagedState(error: String? = nil, loading: Bool = false, notice: String? = nil) -> BackendMCPState {
        .init(servers: [], isCurrent: false, isLoading: loading, togglingIDs: [], errorMessage: error, notice: notice)
    }

    private func bindManagedService() {
        let connection = currentManagedConnection
        let service = connection?.mcp
        let identity = service.map { ObjectIdentifier($0) }
        guard boundConnectionID != connection?.id || boundServiceID != identity else { return }
        managedObservation = nil
        boundConnectionID = connection?.id
        boundServiceID = identity
        confirmationRevision = UUID()
        guard let connection, let service else { return }
        hasManagedContext = true
        let connectionID = connection.id
        managedObservation = service.statePublisher.receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self, self.currentManagedConnection?.id == connectionID,
                  self.boundServiceID == identity else { return }
            if !state.isCurrent { self.confirmationRevision = UUID() }
            self.objectWillChange.send()
        }
    }

    private func isCurrent(client: OpenCodeAPIClient, directory: String?, workspaceID: String?, profile: OpenCodeAPIProfile, contextID: String?) -> Bool {
        (connectionProvider == nil || isAvailable) && clientProvider()?.config == client.config
            && directoryProvider() == directory && apiProfileProvider() == profile
            && workspaceIDProvider() == workspaceID && contextIDProvider() == contextID
    }
}
