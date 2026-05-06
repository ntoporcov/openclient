import Foundation
import SwiftUI

extension AppViewModel {
    struct MCPSnapshot: Hashable {
        let servers: [OpenCodeMCPServer]
        let connectedServerCount: Int
        let isLoading: Bool
        let togglingServerNames: Set<String>
        let errorMessage: String?
    }

    var mcpSnapshot: MCPSnapshot {
        MCPSnapshot(
            servers: mcpServers,
            connectedServerCount: connectedMCPServerCount,
            isLoading: isLoadingMCP,
            togglingServerNames: togglingMCPServerNames,
            errorMessage: mcpErrorMessage
        )
    }

    var mcpServers: [OpenCodeMCPServer] {
        mcpStore.servers
    }

    var connectedMCPServerCount: Int {
        mcpStore.connectedServerCount
    }

    func presentMCPView() {
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .mcp
            selectedSession = nil
        }

        Task {
            await loadMCPStatusIfNeeded()
        }
    }

    func loadMCPStatusIfNeeded() async {
        guard mcpStore.shouldLoadStatus() else { return }
        await reloadMCPStatus()
    }

    func reloadMCPStatus() async {
        objectWillChange.send()
        mcpStore.beginLoading()
        defer {
            objectWillChange.send()
            mcpStore.finishLoading()
        }

        do {
            let statuses = try await client.listMCPStatus(directory: effectiveSelectedDirectory)
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                mcpStore.applyLoadedStatuses(statuses)
            }
        } catch {
            objectWillChange.send()
            mcpStore.applyLoadError(error)
        }
    }

    func toggleMCPServer(name: String) async {
        objectWillChange.send()
        guard mcpStore.beginToggling(name: name) else { return }

        defer {
            objectWillChange.send()
            mcpStore.finishToggling(name: name)
        }

        do {
            if mcpStore.isConnected(name: name) {
                try await client.disconnectMCPServer(name: name, directory: effectiveSelectedDirectory)
            } else {
                try await client.connectMCPServer(name: name, directory: effectiveSelectedDirectory)
            }

            let statuses = try await client.listMCPStatus(directory: effectiveSelectedDirectory)
            withAnimation(opencodeSelectionAnimation) {
                objectWillChange.send()
                mcpStore.applyLoadedStatuses(statuses)
            }
        } catch {
            objectWillChange.send()
            mcpStore.applyToggleError(error)
        }
    }
}
