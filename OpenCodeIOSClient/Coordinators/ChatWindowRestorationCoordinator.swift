import Combine
import Foundation
import Observation

/// Validates persisted routing against the actual connection before creating a window context.
@MainActor
@Observable
final class ChatWindowRestorationCoordinator {
    private(set) var revision = 0
    private var approvedRoute: OpenClientChatWindowRoute?
    private var approvedConnectionID: UUID?
    private var validationID = UUID()
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        // Invalidate synchronously, including disconnect/reconnect on the same server.
        viewModel.$backendConnection.dropFirst().sink { [weak self] _ in self?.invalidate() }
            .store(in: &observations)
        viewModel.connectionStore.$isConnected.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.invalidate() }.store(in: &observations)
        viewModel.connectionStore.$backendMode.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.invalidate() }.store(in: &observations)
    }

    func invalidate() {
        revision &+= 1
        approvedRoute = nil
        approvedConnectionID = nil
    }

    private func connection(for route: OpenClientChatWindowRoute) -> BackendConnection? {
        guard viewModel.backendFactory == nil,
              viewModel.connectionStore.isConnected,
              [.server, .serverV2].contains(viewModel.connectionStore.backendMode),
              let connection = viewModel.backendConnection, !connection.isClosed,
              let adapter = connection.openCodeCompatibility, adapter.profile == (route.apiProfile ?? .legacy),
              adapter.client.config.recentServerID == route.serverID,
              !route.sessionID.isEmpty,
               DirectoryStoreRegistry.key(for: DirectoryStoreRegistry.directory(forKey: route.directoryKey)) == route.directoryKey,
               route.apiProfile != .v2 || route.canonicalDirectoryKey != nil
        else { return nil }
        if let key = route.canonicalDirectoryKey,
           DirectoryStoreRegistry.key(for: DirectoryStoreRegistry.directory(forKey: key)) != key { return nil }
        if route.apiProfile == nil, route.workspaceID != nil { return nil }
        return connection
    }

    func isApproved(_ route: OpenClientChatWindowRoute) -> Bool {
        guard approvedRoute == route, let connection = connection(for: route),
              approvedConnectionID == connection.id,
              !viewModel.directoryStoreRegistry.isV2SessionDeleted(route.sessionID) else { return false }
        // ChatFacade prefers a cached owner over the supplied directory. Never admit a conflicting owner.
        if let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: route.sessionID) {
            guard viewModel.directoryStoreRegistry.key(for: owner) == route.directoryKey else { return false }
        }
        guard let cached = viewModel.directoryStoreRegistry.session(matching: route.sessionID),
              cached.workspaceID == route.workspaceID,
              DirectoryStoreRegistry.key(for: cached.directory) == (route.canonicalDirectoryKey ?? route.directoryKey) else { return false }
        return true
    }

    func validate(_ route: OpenClientChatWindowRoute?) async {
        let validationID = UUID()
        self.validationID = validationID
        approvedRoute = nil
        approvedConnectionID = nil
        guard let route, let connection = connection(for: route) else { return }
        let revision = revision
        let registryGeneration = viewModel.directoryStoreRegistry.generation
        let lifecycle = viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: route.sessionID)
        do {
            let session = try await connection.sessions.session(id: route.sessionID,
                scope: .init(directory: DirectoryStoreRegistry.directory(forKey: route.canonicalDirectoryKey ?? route.directoryKey), workspaceID: route.workspaceID))
            guard !Task.isCancelled, self.revision == revision, self.validationID == validationID,
                  self.connection(for: route)?.id == connection.id,
                  viewModel.directoryStoreRegistry.generation == registryGeneration,
                  viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: route.sessionID) == lifecycle,
                  !viewModel.directoryStoreRegistry.isV2SessionDeleted(route.sessionID),
                  session.id == route.sessionID,
                   DirectoryStoreRegistry.key(for: session.directory) == (route.canonicalDirectoryKey ?? route.directoryKey),
                   session.workspaceID == route.workspaceID else { return }
            // Persisted legacy routes have no workspace/profile field. Do not infer either from mutable UI config.
            approvedConnectionID = connection.id
            approvedRoute = route
            let owner = viewModel.directoryStoreRegistry.store(for: DirectoryStoreRegistry.directory(forKey: route.directoryKey))
            if viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id).map({ $0 !== owner }) != true {
                owner.insertV2Session(session)
            }
        } catch {
            // Fail closed without switching servers, hydrating chat, or exposing transport errors.
        }
    }
}
