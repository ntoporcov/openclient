import Combine
import Foundation

/// Optional connection-owned managed MCP inventory/control. DSH exposes profile-wide
/// management only; the legacy OpenCode workspace MCP service remains separate.
/// Absence of scope arguments reflects that supported API, not universal MCP scope.
@MainActor
protocol BackendMCPService: AnyObject, Sendable {
    var state: BackendMCPState { get }
    var statePublisher: AnyPublisher<BackendMCPState, Never> { get }
    func refresh() async
    func setEnabled(id: String, enabled: Bool) async
}

struct BackendMCPState: Hashable, Sendable {
    var servers: [BackendMCPServer] = []
    var isCurrent = false
    var isLoading = false
    var togglingIDs: Set<String> = []
    var errorMessage: String? = nil
    var notice: String? = nil
}

struct BackendMCPServer: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool?
    let phase: BackendMCPPluginPhase?
    let scope: BackendMCPScope
    let canToggle: Bool
    let restriction: BackendMCPRestriction?
}

enum BackendMCPPluginPhase: String, Codable, Hashable, Sendable {
    case pending, loading, active, failed, unloading
}

enum BackendMCPScope: Hashable, Sendable {
    case profile
    case agentPreset(id: String, name: String)
}

enum BackendMCPRestriction: Hashable, Sendable {
    case managementUnavailable, unaddressable, preset
}
