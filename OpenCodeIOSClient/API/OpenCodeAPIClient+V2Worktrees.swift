import Foundation

private struct V2ProjectDirectory: Decodable {
    let directory: String
    let strategy: String?

    var worktree: BackendWorktree {
        let kind: BackendWorktree.Kind = switch strategy {
        case nil: .root
        case "git_worktree": .gitCopy
        case let value?: .unknownStrategy(value)
        }
        return .init(directory: directory, kind: kind)
    }
}

private struct V2ProjectCopy: Decodable {
    let directory: String
}

private struct V2ProjectCopyError: Decodable {
    struct Details: Decodable {
        let message: String
        let forceRequired: Bool?
    }
    let name: String
    let data: Details
}

extension OpenCodeAPIClient {
    func listV2Worktrees(scope: BackendScope) async throws -> [BackendWorktree] {
        let projectID = try worktreeProjectID(scope)
        let response: [V2ProjectDirectory] = try await send(
            path: "/api/project/\(projectID)/directories", method: "GET",
            queryItems: v2LocationQueryItems(directory: scope.directory, workspaceID: scope.workspaceID)
        )
        return response.map(\.worktree)
    }

    func createV2Worktree(_ request: BackendWorktreeCreation) async throws -> BackendWorktreeCreationResult {
        let projectID = try worktreeProjectID(request.scope)
        guard let parent = request.destinationParent?.trimmingCharacters(in: .whitespacesAndNewlines),
              parent.hasPrefix("/"), !parent.contains("\0") else {
            throw BackendWorktreeError.destinationParentRequired
        }
        let name = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty,
           name == "." || name == ".." || name.contains("/") || name.contains("\\") || name.contains("\0") {
            throw BackendWorktreeError.invalidName
        }
        struct Create: Encodable {
            let strategy = "git_worktree"
            let directory: String
            let name: String?
        }
        do {
            let result: V2ProjectCopy = try await send(
                path: "/experimental/project/\(projectID)/copy", method: "POST",
                queryItems: v2LocationQueryItems(directory: request.scope.directory, workspaceID: request.scope.workspaceID),
                body: Create(directory: parent, name: name?.isEmpty == false ? name : nil)
            )
            return .init(worktree: .init(directory: result.directory, kind: .gitCopy), readiness: .ready)
        } catch { throw worktreeError(error) }
    }

    func removeV2Worktree(scope: BackendScope, directory: String, force: Bool) async throws {
        let projectID = try worktreeProjectID(scope)
        struct Remove: Encodable { let directory: String; let force: Bool }
        do {
            try await sendNoContent(
                path: "/experimental/project/\(projectID)/copy", method: "DELETE",
                queryItems: v2LocationQueryItems(directory: scope.directory, workspaceID: scope.workspaceID),
                body: Remove(directory: directory, force: force)
            )
        } catch { throw worktreeError(error) }
    }

    func refreshV2Worktrees(scope: BackendScope) async throws {
        let projectID = try worktreeProjectID(scope)
        do {
            try await sendNoContent(
                path: "/experimental/project/\(projectID)/copy/refresh", method: "POST",
                queryItems: v2LocationQueryItems(directory: scope.directory, workspaceID: scope.workspaceID),
                directoryHeader: nil
            )
        } catch { throw worktreeError(error) }
    }

    func findV2Directories(query: String, directory: String) async throws -> [String] {
        struct Entry: Decodable { let path: String; let type: String }
        struct Response: Decodable { let location: OpenCodeV2Location; let data: [Entry] }
        let response: Response = try await send(
            path: "/api/fs/find", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory) + [
                URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "directory"),
                URLQueryItem(name: "limit", value: "50")
            ]
        )
        return response.data.filter { $0.type == "directory" }.map {
            $0.path.hasPrefix("/") ? $0.path : URL(fileURLWithPath: response.location.directory).appendingPathComponent($0.path).path
        }
    }

    private func worktreeProjectID(_ scope: BackendScope) throws -> String {
        guard let id = scope.projectID, !id.isEmpty, id != "global", !id.contains("/"),
              !id.contains("?"), !id.contains("#"), let directory = scope.directory,
              directory.hasPrefix("/"), scope.workspaceID == nil else {
            throw BackendWorktreeError.unsupportedLocation
        }
        return id
    }

    private func worktreeError(_ error: Error) -> Error {
        guard case let OpenCodeAPIError.httpError(400, body) = error,
              let decoded = try? JSONDecoder().decode(V2ProjectCopyError.self, from: Data(body.utf8)),
              decoded.name == "ProjectCopyError" else { return error }
        return decoded.data.forceRequired == true
            ? BackendWorktreeError.forceRequired(decoded.data.message)
            : BackendWorktreeError.failed(decoded.data.message)
    }
}
