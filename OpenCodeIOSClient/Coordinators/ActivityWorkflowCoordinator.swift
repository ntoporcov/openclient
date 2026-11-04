import Foundation

@MainActor
enum ActivityWorkflowCoordinator {
    /// Activity includes all root sessions, including quiet sessions beyond the first page.
    static func rootSessions(service: any BackendSessionsService, scope: BackendScope) async throws -> [OpenCodeSession] {
        var sessions: [String: OpenCodeSession] = [:]
        var cursor: String?
        var visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await service.sessions(scope: scope, cursor: cursor, limit: 100, roots: true)
            for session in page.sessions where session.isRootSession { sessions[session.id] = session }
            cursor = page.nextCursor
            if let cursor, !visited.insert(cursor).inserted { throw OpenCodeV2TransportError.invalidTimelineRecord }
        } while cursor != nil
        return sessions.values.sorted { $0.id < $1.id }
    }

    /// Enumerate every page, not just Activity's visible/recent window or project filter.
    static func sessions(connection: BackendConnection, scopes: [BackendScope]) async throws -> [OpenCodeSession] {
        guard !connection.isClosed else { throw BackendError.disconnected }
        let projects = try await connection.projects.projectsSnapshot().projects
        let isV2 = connection.openCodeCompatibility?.profile == .v2
        var inventoryScopes = scopes
        for project in projects {
            if isV2 {
                // Project-wide V2 listing also includes sessions in subdirectories
                // that are not represented by Activity's worktree scopes.
                inventoryScopes.append(.init(projectID: project.id))
            } else {
                inventoryScopes.append(.init(projectID: project.id, directory: project.id == "global" ? nil : project.worktree))
                inventoryScopes += (project.sandboxes ?? []).map { .init(projectID: project.id, directory: $0) }
            }
        }
        if isV2 { inventoryScopes = inventoryScopes.map { .init(projectID: $0.projectID) } }
        var sessions: [String: OpenCodeSession] = [:]
        for scope in Set(inventoryScopes) {
            var cursor: String?
            var visited = Set<String>()
            repeat {
                try Task.checkCancellation()
                guard !connection.isClosed else { throw BackendError.disconnected }
                let page = try await connection.sessions.sessions(scope: scope, cursor: cursor, limit: 100, roots: false)
                for session in page.sessions { sessions[session.id] = session }
                cursor = page.nextCursor
                if let cursor, !visited.insert(cursor).inserted { throw OpenCodeV2TransportError.invalidTimelineRecord }
            } while cursor != nil
        }
        return sessions.values.sorted { $0.id < $1.id }
    }

    static func assign(_ status: ActivityWorkflowStatus, to session: OpenCodeSession,
                       connection: BackendConnection,
                       ifMatching matches: (OpenCodeSession) -> Bool = { _ in true }) async throws -> OpenCodeSession? {
        guard !connection.isClosed else { throw BackendError.disconnected }
        guard let annotations = connection.sessions as? any BackendSessionAnnotationsService,
              annotations.supportsSessionAnnotations else { return nil }
        let current = try await connection.sessions.session(id: session.id,
            scope: .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID))
        try Task.checkCancellation()
        guard !connection.isClosed else { throw BackendError.disconnected }
        // Another client may have moved this session after the bulk operation's inventory.
        guard matches(current) else { return current }
        // V2 replaces metadata rather than merging it. Preserve all unrelated annotations.
        return try await annotations.setSessionMetadata(id: session.id, metadata: status.merging(into: current.metadata, sessionID: session.id))
    }
}
