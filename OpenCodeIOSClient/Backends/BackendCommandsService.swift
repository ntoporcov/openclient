import Foundation

struct BackendCommandSubmission: Sendable {
    let sessionID: String
    let messageID: String
    let command: String
    var arguments = ""
    var scope: BackendScope = .init()
    var agent: String?
    var model: OpenCodeModelReference?
    var variant: String?
    var attachments: [OpenCodeComposerAttachment] = []
    /// Ranges are relative to arguments. OpenCode's command wire contract only
    /// carries their literal text; other backends can consume the structured hints.
    var agentMentions: [OpenCodeAgentMention] = []
    var resume = true
}

struct BackendActionTurn: Equatable, Sendable {
    let sessionID: String
    let userMessageID: String
    let assistantMessageID: String
    let text: String
    let failed: Bool
}

/// Emitted by the existing shared event pipeline, never a feature-owned SSE stream.
enum BackendActionSignal: Sendable {
    case needsAttention(sessionID: String)
    case sessionParent(sessionID: String, parentID: String)
    case execution(sessionID: String)
}

/// Presence promises the entire action contract, not merely a command endpoint.
@MainActor protocol BackendCommandsService: Sendable {
    /// Stable wire-contract namespace, independent of a connection's transient UUID.
    var actionContractID: String { get }
    func listCommands(scope: BackendScope) async throws -> [OpenCodeCommand]
    func submitCommand(_ request: BackendCommandSubmission) async throws -> BackendAdmission
    /// A scheduling barrier only. Returning never establishes success or input completion.
    func waitUntilIdle(sessionID: String, scope: BackendScope) async throws
    /// Canonical, completed assistant text belonging to exactly this user input, or nil.
    /// Must exclude user, tool, reasoning, synthetic and compaction output.
    func completedTurn(sessionID: String, userMessageID: String, scope: BackendScope) async throws -> BackendActionTurn?
    /// Hydration covers interactions/children whose events preceded run registration.
    func needsAttention(sessionID: String, scope: BackendScope) async throws -> Bool
}
