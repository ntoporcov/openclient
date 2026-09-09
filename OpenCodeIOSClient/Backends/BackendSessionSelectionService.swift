import Foundation

/// Presence means selections are session-scoped and must be applied before submitting text.
/// Backends without this service carry selections in BackendSubmission instead.
@MainActor
protocol BackendSessionSelectionService: Sendable {
    func setModel(sessionID: String, model: OpenCodeModelReference, variant: String?, scope: BackendScope) async throws
    func setAgent(sessionID: String, agent: String, scope: BackendScope) async throws
}

/// Optional read evidence. A missing ID is unknown, never a rejection or permission to repost.
@MainActor
protocol BackendPendingInputReading: Sendable {
    func pendingInputIDs(sessionID: String, scope: BackendScope) async throws -> Set<String>
}

@MainActor
struct OpenCodeV2SessionSelectionService: BackendSessionSelectionService, BackendPendingInputReading {
    private let client: OpenCodeAPIClient
    private let version: String

    init(client: OpenCodeAPIClient, version: String) {
        self.client = client
        self.version = version
    }

    func setModel(sessionID: String, model: OpenCodeModelReference, variant: String?, scope: BackendScope) async throws {
        try await client.switchV2SessionModel(sessionID: sessionID, model: model, variant: variant)
    }

    func setAgent(sessionID: String, agent: String, scope: BackendScope) async throws {
        try await client.switchV2SessionAgent(sessionID: sessionID, agent: agent)
    }

    func pendingInputIDs(sessionID: String, scope: BackendScope) async throws -> Set<String> {
        guard version == "0.0.0-next-17155" else { throw OpenCodeAPIError.invalidResponse }
        return try await client.listV2PendingInputIDs(sessionID: sessionID, endpoint: .pending)
    }
}
