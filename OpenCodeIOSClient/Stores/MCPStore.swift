import Combine
import Foundation

@MainActor
final class MCPStore: ObservableObject {
    @Published var statuses: [String: OpenCodeMCPStatus]
    @Published var isReady: Bool
    @Published var isLoading: Bool
    @Published var togglingServerNames: Set<String>
    @Published var errorMessage: String?

    init(
        statuses: [String: OpenCodeMCPStatus] = [:],
        isReady: Bool = false,
        isLoading: Bool = false,
        togglingServerNames: Set<String> = [],
        errorMessage: String? = nil
    ) {
        self.statuses = statuses
        self.isReady = isReady
        self.isLoading = isLoading
        self.togglingServerNames = togglingServerNames
        self.errorMessage = errorMessage
    }

    func reset() {
        statuses = [:]
        isReady = false
        isLoading = false
        togglingServerNames = []
        errorMessage = nil
    }

    var servers: [OpenCodeMCPServer] {
        statuses
            .map { OpenCodeMCPServer(name: $0.key, status: $0.value) }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var connectedServerCount: Int {
        servers.filter { $0.status.isConnected }.count
    }

    func shouldLoadStatus() -> Bool {
        !isReady && !isLoading
    }

    func beginLoading() {
        isLoading = true
    }

    func finishLoading() {
        isLoading = false
    }

    func applyLoadedStatuses(_ nextStatuses: [String: OpenCodeMCPStatus]) {
        statuses = nextStatuses
        isReady = true
        errorMessage = nil
    }

    func applyLoadError(_ error: Error) {
        isReady = true
        errorMessage = error.localizedDescription
    }

    func beginToggling(name: String) -> Bool {
        guard !togglingServerNames.contains(name) else { return false }
        togglingServerNames.insert(name)
        return true
    }

    func finishToggling(name: String) {
        togglingServerNames.remove(name)
    }

    func isConnected(name: String) -> Bool {
        statuses[name]?.isConnected == true
    }

    func applyToggleError(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
