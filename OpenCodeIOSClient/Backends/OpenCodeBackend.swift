import CryptoKit
import Foundation

@MainActor
struct OpenCodeBackendFactory: BackendFactory {
    // Value snapshot, including the preference, for exactly one connection attempt.
    let client: OpenCodeAPIClient
    let eventManager: OpenCodeEventManager

    func connect() async throws -> BackendConnection {
        let profile: OpenCodeAPIProfile
        let version: String
        let healthy: Bool
        let probe: OpenCodeV2ProbeResult
        switch client.config.apiPreference {
        case .legacy:
            probe = .unavailable
        case .automatic, .v2:
            probe = try await Self.withTimeout(seconds: 8) {
                try await client.probeV2()
            }
        }
        try Task.checkCancellation()
        if case let .available(health) = probe {
            profile = .v2
            version = health.version
            healthy = health.healthy
        } else {
            // Only the probe's explicit unavailable result permits automatic fallback.
            guard client.config.apiPreference != .v2 else { throw OpenCodeAPIError.v2Unavailable }
            let health = try await Self.withTimeout(seconds: 8) {
                try await client.health()
            }
            profile = .legacy
            version = health.version
            healthy = health.healthy
        }
        try Task.checkCancellation()
        return makeConnection(profile: profile, version: version, healthy: healthy)
    }

    func makeConnection(profile: OpenCodeAPIProfile, version: String, healthy: Bool) -> BackendConnection {
        let adapter = OpenCodeBackendAdapter(client: client, profile: profile)
        let workspaceServices = OpenCodeWorktreeServices(client: client, profile: profile)
        let supportsCopies = profile == .legacy || version == "0.0.0-next-17155"
        return BackendConnection(
            descriptor: BackendDescriptor(
                id: "opencode:" + SHA256.hash(data: Data(client.config.recentServerID.utf8)).map { String(format: "%02x", $0) }.joined(),
                name: "OpenCode", version: version
            ),
            capabilities: Set<BackendCapability>([.commands, .fork, .compaction, .files, .terminal, .mcp,
                           .providerConfiguration, .interactions, .localCache])
                .union([.liveActivities])
                .union(profile == .legacy ? [.worktrees, .bridge] : []),
            healthy: healthy, projects: adapter, sessions: adapter, chat: adapter, models: adapter,
            events: OpenCodeBackendEventSource(client: client, profile: profile, manager: eventManager),
            commands: OpenCodeCommandsService.make(client: client, profile: profile, version: version, sessions: adapter, chat: adapter),
            sessionForms: profile == .v2 ? OpenCodeSessionFormsService(client: client) : nil,
            projectLifecycle: workspaceServices,
            worktrees: supportsCopies ? workspaceServices : nil,
            worktreeReset: profile == .legacy ? OpenCodeLegacyWorktreeResetService(client: client) : nil,
            sessionSelection: profile == .v2 ? OpenCodeV2SessionSelectionService(client: client, version: version) : nil
        )
    }

    nonisolated static func withTimeout<T: Sendable>(
        seconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw OpenCodeAPIError.timedOut
            }
            guard let result = try await group.next() else { throw OpenCodeAPIError.timedOut }
            group.cancelAll()
            return result
        }
    }
}

// Temporary compatibility access is intentionally outside the backend protocols. V2 callers
// must keep their existing lifecycle/stream revision guards when applying these service results.
extension BackendConnection {
    var openCodeCompatibility: OpenCodeBackendAdapter? { projects as? OpenCodeBackendAdapter }

    func requireOpenCodeClient(for capability: BackendCapability) throws -> OpenCodeAPIClient {
        try require(capability)
        guard let compatibility = openCodeCompatibility else { throw BackendError.unsupported(capability) }
        return compatibility.client
    }
}

@MainActor
final class OpenCodeBackendAdapter: BackendProjectsService, BackendSessionsService, BackendChatService, BackendModelsService {
    let client: OpenCodeAPIClient
    let profile: OpenCodeAPIProfile

    init(client: OpenCodeAPIClient, profile: OpenCodeAPIProfile) {
        self.client = client
        self.profile = profile
    }

    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        if profile == .v2 {
            let snapshot = try await client.bootstrapV2Projects()
            return .init(projects: snapshot.projects, currentProject: snapshot.currentProject,
                         defaultDirectory: snapshot.selectedDirectory)
        }
        return try await OpenCodeBackendFactory.withTimeout(seconds: 10) { [client] in
            async let projects = client.listProjects()
            async let currentProject = try? client.currentProject()
            return try await .init(projects: projects, currentProject: currentProject)
        }
    }

    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        if profile == .v2 {
            guard let projectID = scope.projectID else { throw BackendError.invalidScope }
            let page = try await client.listV2Sessions(projectID: projectID, directory: scope.directory,
                cursor: cursor, limit: limit, workspaceID: scope.workspaceID, roots: roots)
            return .init(sessions: page.sessions, nextCursor: page.nextCursor)
        }
        guard cursor == nil else { throw BackendError.invalidScope }
        return try await .init(sessions: client.listSessions(directory: scope.directory, roots: roots, limit: limit))
    }

    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        if profile == .v2 { return try await client.getV2Session(sessionID: id) }
        return try await client.getSession(sessionID: id, directory: scope.directory, workspaceID: scope.workspaceID)
    }

    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        if profile == .v2 {
            guard let directory = request.scope.directory, !directory.isEmpty else { throw BackendError.invalidScope }
            return try await client.createV2Session(title: request.title, directory: directory,
                workspaceID: request.scope.workspaceID, agent: request.agent, model: request.model, variant: request.variant)
        }
        return try await client.createSession(title: request.title, directory: request.scope.directory)
    }

    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        if profile == .v2 { return try await client.updateV2SessionTitle(sessionID: id, title: title) }
        return try await client.updateSessionTitle(sessionID: id, title: title, directory: scope.directory, workspaceID: scope.workspaceID)
    }

    func deleteSession(id: String, scope: BackendScope) async throws {
        if profile == .v2 { try await client.deleteV2Session(sessionID: id) }
        else { try await client.deleteSession(sessionID: id, directory: scope.directory, workspaceID: scope.workspaceID) }
    }

    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] {
        guard limit > 0 else { return [] }
        if profile == .legacy {
            let listed = try await client.listSessions(directory: scope.directory, roots: true)
            return Array(listed.filter { $0.title?.localizedCaseInsensitiveContains(query) == true }.prefix(limit))
        }
        var matches: [OpenCodeSession] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            try Task.checkCancellation()
            let page = try await sessions(scope: scope, cursor: cursor, limit: max(limit, 50), roots: true)
            matches.append(contentsOf: page.sessions.filter { $0.title?.localizedCaseInsensitiveContains(query) == true })
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil && matches.count < limit
        return Array(matches.prefix(limit))
    }

    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        if profile == .v2 {
            let page = try await client.listV2Messages(sessionID: sessionID, cursor: cursor, limit: limit)
            return .init(messages: page.messages, olderCursor: page.olderCursor)
        }
        let page = try await client.listMessagePage(sessionID: sessionID, limit: limit, before: cursor, directory: scope.directory)
        return .init(messages: page.messages, olderCursor: page.nextCursor)
    }

    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        // Cancellation before transmission is not an uncertain admission.
        try Task.checkCancellation()
        do {
            if profile == .v2 {
                let receipt = try await client.admitV2TextPrompt(sessionID: request.sessionID, messageID: request.messageID,
                    text: request.text, attachments: request.attachments, agentMentions: request.agentMentions)
                guard receipt.id == request.messageID, receipt.sessionID == request.sessionID else {
                    return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
                }
            } else {
                try await client.sendMessageAsync(sessionID: request.sessionID, text: request.text,
                    agentMentions: request.agentMentions, attachments: request.attachments, directory: request.scope.directory,
                    messageID: request.messageID, partID: request.partID, model: request.model, agent: request.agent, variant: request.variant)
            }
            return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        } catch let OpenCodeAPIError.httpError(status, _) where (400 ..< 500).contains(status) && status != 408 && status != 409 {
            // An exact-ID canonical event can still override this evidence at the store boundary.
            return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        } catch {
            return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
    }

    func interrupt(sessionID: String, scope: BackendScope) async throws {
        if profile == .v2 { try await client.interruptV2Session(sessionID: sessionID) }
        else { try await client.abortSession(sessionID: sessionID, directory: scope.directory, workspaceID: scope.workspaceID) }
    }

    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        if profile == .v2 {
            async let agents = client.listV2Agents(directory: scope.directory, workspaceID: scope.workspaceID)
            async let providers = client.listV2Providers(directory: scope.directory, workspaceID: scope.workspaceID)
            async let model = client.defaultV2Model(directory: scope.directory, workspaceID: scope.workspaceID)
            return try await .init(agents: agents, providers: providers, defaults: model.map { [$0.providerID: $0.id] } ?? [:])
        }
        async let agents = client.listAgents(directory: scope.directory)
        let state = try await client.providerState(directory: scope.directory, workspaceID: scope.workspaceID)
        return try await .init(agents: agents, providers: state.all.filter { state.connected.contains($0.id) }, defaults: state.default)
    }
}
