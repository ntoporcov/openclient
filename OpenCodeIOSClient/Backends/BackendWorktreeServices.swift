import Foundation

struct BackendDirectorySearch: Equatable, Sendable {
    var directories: [String]
    var selectedDirectory: String?
}

struct BackendProjectResolution: Sendable {
    let project: OpenCodeProject
    let scope: BackendScope
    let canonicalDirectory: String
}

struct BackendWorktree: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case root
        case gitCopy
        case unknownStrategy(String)
    }

    let directory: String
    let kind: Kind

    var isManaged: Bool { kind == .gitCopy }
}

struct BackendWorktreeCreation: Sendable {
    let scope: BackendScope
    var name: String? = nil
    var destinationParent: String? = nil
}

struct BackendWorktreeCreationResult: Equatable, Sendable {
    enum Readiness: Equatable, Sendable {
        case ready
        case preparing(name: String, branch: String)
    }

    let worktree: BackendWorktree
    let readiness: Readiness
    var directory: String { worktree.directory }
}

struct BackendWorktreeResetResult: Sendable {
    let archivedSessionIDs: [String]
}

enum BackendWorktreeRemovalOutcome: Equatable {
    case removed
    case requiresForce(String)
    case failed
}

// A linked checkout path is not a remote workspace ID. Include both in cache identity.
struct BackendWorktreeInventoryKey: Hashable, Sendable {
    let connectionID: UUID
    let projectID: String
    var workspaceID: String? = nil
}

struct BackendWorkspacePageKey: Hashable, Sendable {
    let inventory: BackendWorktreeInventoryKey
    let directory: String
}

@MainActor protocol BackendProjectLifecycleService: Sendable {
    func searchDirectories(query: String, root: String) async throws -> BackendDirectorySearch
    /// Explicit selection may register the project on the server, even when transported by GET.
    func resolveProject(directory: String) async throws -> BackendProjectResolution
}

@MainActor protocol BackendWorktreesService: Sendable {
    var requiresDestinationParent: Bool { get }
    func inventory(scope: BackendScope) async throws -> [BackendWorktree]
    func create(_ request: BackendWorktreeCreation) async throws -> BackendWorktreeCreationResult
    func remove(scope: BackendScope, directory: String, force: Bool) async throws
    /// Reconciles the directory inventory, never resets checkout contents.
    func refresh(scope: BackendScope) async throws -> [BackendWorktree]
}

@MainActor protocol BackendWorktreeResetService: Sendable {
    func reset(scope: BackendScope, directory: String) async throws -> BackendWorktreeResetResult
}

enum BackendWorktreeError: LocalizedError, Equatable {
    case unavailable
    case destinationParentRequired
    case invalidName
    case unsupportedLocation
    case forceRequired(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Workspace management is unavailable on this server.")
        case .destinationParentRequired: String(localized: "Choose an absolute destination parent directory on the server.")
        case .invalidName: String(localized: "Use a workspace name without path separators or dot components.")
        case .unsupportedLocation: String(localized: "Worktree management requires a local Git project.")
        case .forceRequired(let message), .failed(let message): message
        }
    }
}
