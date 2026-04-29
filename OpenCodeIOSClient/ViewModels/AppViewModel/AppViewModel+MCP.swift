import Foundation
import SwiftUI

extension AppViewModel {
    var mcpServers: [OpenCodeMCPServer] {
        directoryState.mcpStatuses
            .map { OpenCodeMCPServer(name: $0.key, status: $0.value) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var connectedMCPServerCount: Int {
        mcpServers.filter { $0.status.isConnected }.count
    }

    func presentMCPView() {
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .mcp
            directoryState.selectedSession = nil
        }

        Task {
            await loadMCPStatusIfNeeded()
        }
    }

    func loadMCPStatusIfNeeded() async {
        guard !directoryState.isMCPReady, !directoryState.isLoadingMCP else { return }
        await reloadMCPStatus()
    }

    func reloadMCPStatus() async {
        directoryState.isLoadingMCP = true
        defer { directoryState.isLoadingMCP = false }

        do {
            let statuses = try await client.listMCPStatus(directory: effectiveSelectedDirectory)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.mcpStatuses = statuses
                directoryState.isMCPReady = true
                directoryState.mcpErrorMessage = nil
            }
        } catch {
            directoryState.isMCPReady = true
            directoryState.mcpErrorMessage = error.localizedDescription
        }
    }

    func toggleMCPServer(name: String) async {
        guard !directoryState.togglingMCPServerNames.contains(name) else { return }

        directoryState.togglingMCPServerNames.insert(name)
        defer { directoryState.togglingMCPServerNames.remove(name) }

        do {
            if directoryState.mcpStatuses[name]?.isConnected == true {
                try await client.disconnectMCPServer(name: name, directory: effectiveSelectedDirectory)
            } else {
                try await client.connectMCPServer(name: name, directory: effectiveSelectedDirectory)
            }

            let statuses = try await client.listMCPStatus(directory: effectiveSelectedDirectory)
            withAnimation(opencodeSelectionAnimation) {
                directoryState.mcpStatuses = statuses
                directoryState.isMCPReady = true
                directoryState.mcpErrorMessage = nil
            }
        } catch {
            directoryState.mcpErrorMessage = error.localizedDescription
        }
    }
}
