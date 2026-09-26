import Foundation

@MainActor
final class OpenCodeCommandsService: BackendCommandsService {
    let actionContractID: String
    private let client: OpenCodeAPIClient
    private let profile: OpenCodeAPIProfile
    private let sessions: any BackendSessionsService
    private let chat: any BackendChatService

    /// Do not advertise an unverified v2 contract merely because /command exists.
    static func make(
        client: OpenCodeAPIClient, profile: OpenCodeAPIProfile, version: String,
        sessions: any BackendSessionsService, chat: any BackendChatService
    ) -> OpenCodeCommandsService? {
        guard profile == .legacy || version == "0.0.0-next-17155" else { return nil }
        return OpenCodeCommandsService(client: client, profile: profile, sessions: sessions, chat: chat)
    }

    private init(client: OpenCodeAPIClient, profile: OpenCodeAPIProfile, sessions: any BackendSessionsService, chat: any BackendChatService) {
        self.client = client
        self.profile = profile
        self.sessions = sessions
        self.chat = chat
        actionContractID = profile == .legacy ? "opencode.legacy.actions.v1" : "opencode.http-api.next-17155.actions.v1"
    }

    func listCommands(scope: BackendScope) async throws -> [OpenCodeCommand] {
        try Task.checkCancellation()
        if profile == .v2 {
            return try await client.listV2Commands(directory: scope.directory, workspaceID: scope.workspaceID)
        }
        return try await client.send(path: "/command", method: "GET", queryItems: query(scope))
    }

    func submitCommand(_ request: BackendCommandSubmission) async throws -> BackendAdmission {
        try Task.checkCancellation()
        do {
            return try await admitCommand(request)
        } catch let OpenCodeAPIError.httpError(status, _) where (400 ..< 500).contains(status) && status != 408 && status != 409 {
            return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        } catch {
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
    }

    private func admitCommand(_ request: BackendCommandSubmission) async throws -> BackendAdmission {
        if profile == .v2 {
            let receipt = try await client.admitV2Command(
                sessionID: request.sessionID, messageID: request.messageID, command: request.command,
                arguments: request.arguments, agent: request.agent, model: request.model,
                variant: request.variant, attachments: request.attachments, resume: request.resume
            )
            guard receipt.id == request.messageID, receipt.sessionID == request.sessionID else {
                return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
            }
            return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        }
        // Legacy command is synchronous and supports caller-assigned messageID.
        struct Command: Encodable, Sendable {
            struct File: Encodable, Sendable { let type = "file"; let mime: String; let filename: String; let url: String }
            let messageID: String
            let command: String
            let arguments: String
            let agent: String?
            let model: String?
            let variant: String?
            let parts: [File]
        }
        let response: OpenCodeMessageEnvelope = try await client.send(
            path: "/session/\(request.sessionID)/command", method: "POST", queryItems: query(request.scope),
            body: Command(messageID: request.messageID, command: request.command, arguments: request.arguments,
                agent: request.agent, model: request.model.map { "\($0.providerID)/\($0.modelID)" }, variant: request.variant,
                parts: request.attachments.map { .init(mime: $0.mime, filename: $0.filename, url: $0.dataURL) })
        )
        guard response.info.sessionID == request.sessionID, response.info.parentID == request.messageID else {
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
        return .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }

    func waitUntilIdle(sessionID: String, scope: BackendScope) async throws {
        try Task.checkCancellation()
        if profile == .v2 { try await client.waitForV2Session(sessionID: sessionID) }
        // Legacy has no wait endpoint. Canonical reads plus shared execution signals
        // complete its async evaluator, rather than adding a polling/SSE owner.
    }

    func completedTurn(sessionID: String, userMessageID: String, scope: BackendScope) async throws -> BackendActionTurn? {
        var cursor: String?
        var seen = Set<String>()
        if profile == .v2 {
            var records: [TimelineRecord] = []
            repeat {
                try Task.checkCancellation()
                var query = [URLQueryItem(name: "limit", value: "200")]
                query.append(cursor.map { URLQueryItem(name: "cursor", value: $0) } ?? URLQueryItem(name: "order", value: "desc"))
                let page: TimelinePage = try await client.send(path: "/api/session/\(sessionID)/message", method: "GET", queryItems: query)
                records.insert(contentsOf: page.data.reversed(), at: 0)
                if records.contains(where: { $0.id == userMessageID && $0.type == "user" }) { break }
                cursor = page.data.isEmpty ? nil : page.cursor?.next
                if let cursor, !seen.insert(cursor).inserted { throw OpenCodeAPIError.invalidResponse }
            } while cursor != nil
            return Self.completedV2Turn(records, sessionID: sessionID, userMessageID: userMessageID)
        }

        var messages: [OpenCodeMessageEnvelope] = []
        repeat {
            try Task.checkCancellation()
            let page = try await chat.transcript(sessionID: sessionID, scope: scope, cursor: cursor, limit: 200)
            messages.insert(contentsOf: page.messages, at: 0)
            if messages.contains(where: { $0.id == userMessageID && $0.info.role == "user" }) { break }
            cursor = page.messages.isEmpty ? nil : page.olderCursor
            if let cursor, !seen.insert(cursor).inserted { throw OpenCodeAPIError.invalidResponse }
        } while cursor != nil
        guard let index = messages.firstIndex(where: { $0.id == userMessageID && $0.info.role == "user" }) else { return nil }
        let turn = messages.dropFirst(index + 1).prefix { $0.info.role != "user" }
        guard let assistant = turn.last(where: { $0.info.role == "assistant" && $0.info.parentID == userMessageID && $0.info.summary != true }),
              assistant.info.sessionID == sessionID, assistant.info.time?.completed != nil,
              assistant.info.finish != "tool-calls" else { return nil }
        return .init(sessionID: sessionID, userMessageID: userMessageID, assistantMessageID: assistant.id,
            text: assistant.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"), failed: assistant.info.error != nil)
    }

    func needsAttention(sessionID: String, scope: BackendScope) async throws -> Bool {
        try Task.checkCancellation()
        if profile == .v2 {
            let permissions = try await client.listV2PendingPermissions(directory: scope.directory, workspaceID: scope.workspaceID)
            if permissions.contains(where: { $0.sessionID == sessionID }) { return true }
            try Task.checkCancellation()
            let forms = try await client.listV2PendingForms(directory: scope.directory, workspaceID: scope.workspaceID)
            if forms.contains(where: { $0.sessionID == sessionID }) { return true }
        } else {
            let permissions = try await client.listPermissions(directory: scope.directory, workspaceID: scope.workspaceID)
            if permissions.contains(where: { $0.sessionID == sessionID }) { return true }
            try Task.checkCancellation()
            let questions = try await client.listQuestions(directory: scope.directory, workspaceID: scope.workspaceID)
            if questions.contains(where: { $0.sessionID == sessionID }) { return true }
        }
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await sessions.sessions(scope: scope, cursor: cursor, limit: 200, roots: false)
            if page.sessions.contains(where: { $0.parentID == sessionID }) { return true }
            cursor = page.sessions.isEmpty ? nil : page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw OpenCodeAPIError.invalidResponse }
        } while cursor != nil
        return false
    }

    private func query(_ scope: BackendScope) -> [URLQueryItem] {
        var items = scope.directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        if let workspaceID = scope.workspaceID { items.append(.init(name: "workspace", value: workspaceID)) }
        return items
    }

    // Read the wire discriminator here: normalized chat envelopes also represent
    // synthetic/system/shell records as assistants and are not evaluator evidence.
    struct TimelineRecord: Decodable, Sendable {
        struct Time: Decodable, Sendable { let completed: Double? }
        struct Content: Decodable, Sendable { let type: String; let text: String? }
        let id: String
        let type: String
        let time: Time?
        let content: [Content]?
        let finish: String?
        let error: OpenCodeJSONValue?
    }

    private struct TimelinePage: Decodable, Sendable {
        struct Cursor: Decodable, Sendable { let next: String? }
        let data: [TimelineRecord]
        let cursor: Cursor?
    }

    static func completedV2Turn(_ records: [TimelineRecord], sessionID: String, userMessageID: String) -> BackendActionTurn? {
        guard let index = records.firstIndex(where: { $0.id == userMessageID && $0.type == "user" }) else { return nil }
        let turn = records.dropFirst(index + 1).prefix { $0.type != "user" }
        guard let assistant = turn.last(where: { $0.type == "assistant" }),
              assistant.time?.completed != nil, assistant.finish != "tool-calls" else { return nil }
        return .init(sessionID: sessionID, userMessageID: userMessageID, assistantMessageID: assistant.id,
            text: (assistant.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"),
            failed: assistant.error != nil && assistant.error != .null)
    }
}
