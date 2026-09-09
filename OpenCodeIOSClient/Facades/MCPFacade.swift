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
    }

    private let store: MCPStore
    private let clientProvider: () -> OpenCodeAPIClient?
    private let directoryProvider: () -> String?
    private let apiProfileProvider: () -> OpenCodeAPIProfile?
    private let workspaceIDProvider: () -> String?
    private let contextIDProvider: () -> String?
    private var observation: AnyCancellable?

    init(
        store: MCPStore,
        clientProvider: @escaping () -> OpenCodeAPIClient?,
        directoryProvider: @escaping () -> String?,
        apiProfileProvider: @escaping () -> OpenCodeAPIProfile? = { .legacy },
        workspaceIDProvider: @escaping () -> String? = { nil },
        contextIDProvider: @escaping () -> String? = { nil }
    ) {
        self.store = store
        self.clientProvider = clientProvider
        self.directoryProvider = directoryProvider
        self.apiProfileProvider = apiProfileProvider
        self.workspaceIDProvider = workspaceIDProvider
        self.contextIDProvider = contextIDProvider
        observation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var snapshot: Snapshot {
        Snapshot(
            servers: store.servers,
            connectedServerCount: store.connectedServerCount,
            isLoading: store.isLoading,
            togglingServerNames: store.togglingServerNames,
            errorMessage: store.errorMessage
        )
    }

    func loadIfNeeded() async {
        guard store.shouldLoadStatus() else { return }
        await reload()
    }

    func reload() async {
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
        store.reset()
    }

    private func isCurrent(client: OpenCodeAPIClient, directory: String?, workspaceID: String?, profile: OpenCodeAPIProfile, contextID: String?) -> Bool {
        clientProvider()?.config == client.config
            && directoryProvider() == directory && apiProfileProvider() == profile
            && workspaceIDProvider() == workspaceID && contextIDProvider() == contextID
    }
}
