import Foundation

/// The workspace feed is a registry, not a sequence of independent project
/// upserts. Reconnect baselines replace it, and order frames are authoritative.
struct DSHWorkspaceState: Sendable {
    private(set) var workspaces: [DSHWorkspace] = []
    private(set) var archived: Set<String> = []

    var snapshot: BackendProjectsSnapshot {
        .init(projects: workspaces.map(\.project), defaultDirectory: workspaces.first?.path)
    }

    mutating func apply(_ frame: DSHJSON) throws {
        switch frame[dsh: "type"].dshString {
        case "baseline":
            let rows = try frame[dsh: "value"][dsh: "items"].dshDecode([DSHWorkspace].self)
            guard Set(rows.map(\.workspaceId)).count == rows.count else { throw URLError(.cannotParseResponse) }
            workspaces = rows
            archived = Set(frame[dsh: "value"][dsh: "archivedSessionIds"].dshArray.compactMap(\.dshString))
        case "upsert":
            let row = try frame[dsh: "workspace"].dshDecode(DSHWorkspace.self)
            if let index = workspaces.firstIndex(where: { $0.workspaceId == row.workspaceId }) {
                workspaces[index] = row
            } else { workspaces.append(row) }
        case "remove": workspaces.removeAll { $0.workspaceId == frame[dsh: "workspaceId"].dshString }
        case "order":
            let ids = try frame[dsh: "workspaceIds"].dshDecode([String].self)
            let rows = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0) })
            guard Set(ids).count == ids.count, Set(ids) == Set(rows.keys) else { throw URLError(.cannotParseResponse) }
            workspaces = ids.compactMap { rows[$0] }
        case "archived": archived = Set(try frame[dsh: "archivedSessionIds"].dshDecode([String].self))
        case "pinned": break
        default: throw URLError(.cannotParseResponse)
        }
    }

    func workspace(forSession id: String, cwd: String?) -> DSHWorkspace? {
        // Explicit membership wins over a working directory that may be a child
        // folder, another workspace, or an old cwd from before a session move.
        workspaces.first { $0.sessionIds.contains(id) } ?? workspaces.first { $0.path == cwd }
    }
}
