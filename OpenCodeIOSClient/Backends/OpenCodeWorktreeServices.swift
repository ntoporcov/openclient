import Foundation

@MainActor
final class OpenCodeWorktreeServices: BackendProjectLifecycleService, BackendWorktreesService {
    let client: OpenCodeAPIClient
    let profile: OpenCodeAPIProfile

    init(client: OpenCodeAPIClient, profile: OpenCodeAPIProfile) {
        self.client = client
        self.profile = profile
    }

    var requiresDestinationParent: Bool { profile == .v2 }

    func searchDirectories(query: String, root: String) async throws -> BackendDirectorySearch {
        let input = query.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !input.isEmpty, !input.contains("/"), input != "~" {
            let found: [String]
            if profile == .v2 {
                found = try await client.findV2Directories(query: input, directory: root)
            } else {
                found = try await client.findFiles(query: input, directory: root).filter { $0.hasSuffix("/") }.map {
                    let directory = String($0.dropLast())
                    return directory.hasPrefix("/") ? directory : URL(fileURLWithPath: root).appendingPathComponent(directory).path
                }
            }
            return .init(directories: Array(Set(found)).sorted(), selectedDirectory: nil)
        }
        let absolute: String
        if input.isEmpty { absolute = "/" }
        else if input == "~" || input == "~/" { absolute = root }
        else if input.hasPrefix("~/") { absolute = URL(fileURLWithPath: root).appendingPathComponent(String(input.dropFirst(2))).path }
        else if input.hasPrefix("/") { absolute = input }
        else { absolute = URL(fileURLWithPath: root).appendingPathComponent(input).path }
        let candidate = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let listsChildren = input.isEmpty || input.hasSuffix("/") || input == "~"
        let parent = listsChildren ? candidate : URL(fileURLWithPath: candidate).deletingLastPathComponent().path
        let nodes = try await listDirectories(parent)
        let partial = URL(fileURLWithPath: candidate).lastPathComponent
        let matches = listsChildren ? nodes : nodes.filter { URL(fileURLWithPath: $0).lastPathComponent.localizedCaseInsensitiveContains(partial) }
        // Browsing a selected directory is explicit server-side discovery; do not warm sessions or rename projects.
        let selected = input.isEmpty ? nil : (listsChildren || nodes.contains(candidate) ? candidate : nil)
        return .init(directories: Array(matches.sorted().prefix(50)), selectedDirectory: selected)
    }

    private func listDirectories(_ directory: String) async throws -> [String] {
        let nodes = try await (profile == .v2 ? client.listV2Files(directory: directory) : client.listFiles(directory: directory))
        return nodes.filter(\.isDirectory).map(\.absolute)
    }

    func resolveProject(directory: String) async throws -> BackendProjectResolution {
        if profile == .v2 {
            let location = try await client.getV2Location(directory: directory)
            let metadata = try await client.project(for: location)
            guard metadata.id == location.project.id else { throw BackendError.invalidScope }
            // A shared project identity may have another clone as its catalog canonical path.
            let project = OpenCodeProject(id: location.project.id, worktree: location.project.directory,
                vcs: metadata.vcs, name: metadata.name, sandboxes: metadata.sandboxes,
                icon: metadata.icon, time: metadata.time)
            return .init(project: project,
                         scope: .init(projectID: project.id, directory: location.directory, workspaceID: location.workspaceID),
                         canonicalDirectory: location.project.canonical)
        }
        let project = try await client.currentProject(directory: directory)
        return .init(project: project, scope: .init(projectID: project.id, directory: directory), canonicalDirectory: project.worktree)
    }

    func inventory(scope: BackendScope) async throws -> [BackendWorktree] {
        if profile == .v2 { return try await client.listV2Worktrees(scope: scope) }
        guard let directory = scope.directory, scope.workspaceID == nil else { throw BackendWorktreeError.unsupportedLocation }
        let paths = try await client.listWorktrees(directory: directory)
        var seen: Set<String> = [directory]
        return [.init(directory: directory, kind: .root)] + paths.compactMap {
            seen.insert($0).inserted ? .init(directory: $0, kind: .gitCopy) : nil
        }
    }

    func create(_ request: BackendWorktreeCreation) async throws -> BackendWorktreeCreationResult {
        if profile == .v2 { return try await client.createV2Worktree(request) }
        guard let directory = request.scope.directory, request.scope.workspaceID == nil else { throw BackendWorktreeError.unsupportedLocation }
        let created = try await client.createWorktree(directory: directory, name: request.name)
        return .init(worktree: .init(directory: created.directory, kind: .gitCopy),
                     readiness: .preparing(name: created.name, branch: created.branch))
    }

    func remove(scope: BackendScope, directory: String, force: Bool) async throws {
        if profile == .v2 {
            try await client.removeV2Worktree(scope: scope, directory: directory, force: force)
        } else {
            guard let root = scope.directory, scope.workspaceID == nil else { throw BackendWorktreeError.unsupportedLocation }
            guard try await client.removeWorktree(rootDirectory: root, worktreeDirectory: directory) else {
                throw BackendWorktreeError.failed(String(localized: "OpenCode did not remove this worktree."))
            }
        }
    }

    func refresh(scope: BackendScope) async throws -> [BackendWorktree] {
        if profile == .v2 { try await client.refreshV2Worktrees(scope: scope) }
        return try await inventory(scope: scope)
    }
}

@MainActor
final class OpenCodeLegacyWorktreeResetService: BackendWorktreeResetService {
    let client: OpenCodeAPIClient
    init(client: OpenCodeAPIClient) { self.client = client }

    func reset(scope: BackendScope, directory: String) async throws -> BackendWorktreeResetResult {
        guard let root = scope.directory, scope.workspaceID == nil, directory != root else {
            throw BackendWorktreeError.unsupportedLocation
        }
        let sessions = try await client.listSessions(directory: directory)
        _ = try await client.disposeInstance(directory: directory)
        guard try await client.resetWorktree(rootDirectory: root, worktreeDirectory: directory) else {
            throw BackendWorktreeError.failed(String(localized: "OpenCode did not reset this worktree."))
        }
        var archived: [String] = []
        let time = Date()
        for session in sessions where !session.isArchived {
            _ = try await client.archiveSession(sessionID: session.id, directory: session.directory,
                                               workspaceID: session.workspaceID, archivedAt: time)
            archived.append(session.id)
        }
        return .init(archivedSessionIDs: archived)
    }
}
