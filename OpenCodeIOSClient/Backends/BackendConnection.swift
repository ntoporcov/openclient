import Foundation

// The existing normalized domain values are shared deliberately; transport DTOs are not.
struct BackendDescriptor: Equatable, Hashable, Sendable {
    /// Stable, non-secret namespace chosen by the factory. Never put credentials here.
    let id: String
    let name: String
    let version: String
}

enum BackendCapability: Hashable, Sendable {
    case commands, fork, compaction, files, terminal, mcp, providerConfiguration
    case worktrees, interactions, bridge, localCache, liveActivities, sessionPermissions, sessionMetadata
}

enum BackendAgentSelectionPolicy: Sendable {
    case mutable
    case creationOnly
}

@MainActor protocol BackendSessionViewingService: Sendable {
    var supportsSessionViewing: Bool { get }
    func viewSession(id: String, idle: Double) async throws
}

enum BackendError: Error, Equatable {
    case unsupported(BackendCapability)
    case disconnected
    case invalidScope
}

struct BackendScope: Equatable, Hashable, Sendable {
    var projectID: String? = nil
    var directory: String? = nil
    var workspaceID: String? = nil
}

struct BackendProjectsSnapshot: Sendable {
    var projects: [OpenCodeProject]
    var currentProject: OpenCodeProject? = nil
    var defaultDirectory: String? = nil
}

struct BackendSessionPage: Sendable {
    var sessions: [OpenCodeSession]
    var nextCursor: String? = nil
}

struct BackendTranscriptPage: Sendable {
    var messages: [OpenCodeMessageEnvelope]
    var olderCursor: String? = nil
}

/// Explicit per-session intent, never a change to the server's future-session default.
enum BackendSessionPermissionPreset: String, Equatable, Sendable {
    case workspaceWrite = "workspace-write"
    case fullAccess = "danger-full-access"
}

/// Canonical backend permission metadata. An unknown value is not Workspace Write.
struct BackendSessionPermissionState: Codable, Hashable, Sendable {
    var currentPreset: String?
}

@MainActor protocol BackendSessionPermissionsService: Sendable {
    func refreshPermissions(sessionID: String, scope: BackendScope) async throws -> OpenCodeSession
    func setPermissions(sessionID: String, preset: BackendSessionPermissionPreset, scope: BackendScope) async throws -> OpenCodeSession
}

struct BackendSessionCreation: Sendable {
    var title: String? = nil
    var scope: BackendScope
    var agent: String? = nil
    var model: OpenCodeModelReference? = nil
    var variant: String? = nil
    var permissionPreset: BackendSessionPermissionPreset? = nil
}

struct BackendSubmission: Sendable {
    let sessionID: String
    /// Caller-generated identity, retained across uncertain admission. Never retry with a new ID.
    let messageID: String
    let text: String
    var scope: BackendScope = .init()
    var partID: String? = nil
    var attachments: [OpenCodeComposerAttachment] = []
    var agentMentions: [OpenCodeAgentMention] = []
    var agent: String? = nil
    var model: OpenCodeModelReference? = nil
    var variant: String? = nil
    var delivery: OpenCodePromptDelivery? = nil
    var skillIDs: [String] = []
}

enum BackendAdmission: Sendable {
    /// Acknowledges acceptance, not completion of execution.
    case accepted(sessionID: String, messageID: String)
    case rejected(sessionID: String, messageID: String)
    /// Preserve the optimistic identity/draft and reconcile before offering a retry.
    case uncertain(sessionID: String, messageID: String)
}

struct BackendModelCatalog: Sendable {
    var agents: [OpenCodeAgent] = []
    var providers: [OpenCodeProvider] = []
    var defaults: [String: String] = [:]
}

@MainActor protocol BackendProjectsService: Sendable {
    func projectsSnapshot() async throws -> BackendProjectsSnapshot
}

@MainActor protocol BackendSessionsService: Sendable {
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession
    func deleteSession(id: String, scope: BackendScope) async throws
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession]
}

@MainActor protocol BackendSessionActivityService: Sendable {
    /// Complete current statuses within the requested scope; live changes arrive
    /// through the connection's existing event source.
    func sessionStatuses(scope: BackendScope) async throws -> [String: String]
}

@MainActor protocol BackendChatService: Sendable {
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission
    func interrupt(sessionID: String, scope: BackendScope) async throws
}

@MainActor protocol BackendModelsService: Sendable {
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog
}

enum BackendEvent: Sendable {
    /// Complete registry replacement, including removals and server ordering.
    case projectsSnapshot(BackendProjectsSnapshot)
    case mutation(directory: String?, event: OpenCodeTypedEvent)
    case actionSignal(BackendActionSignal)
    case sessionForm(directory: String?, event: BackendSessionFormsEvent)
    case globalForm(location: BackendFormLocation?, event: BackendSessionFormsEvent)
    case status(String)
    case diagnostic(String)
}

@MainActor protocol BackendEventSource: AnyObject, Sendable {
    /// One upstream owner; BackendConnection handles subscriber fanout.
    func start(receive: @escaping @MainActor (BackendEvent) -> Void)
    func stop()
}

@MainActor protocol BackendFactory: Sendable {
    /// Each call creates a fresh lifetime. Implementations capture their own configuration.
    func connect() async throws -> BackendConnection
}

@MainActor
final class BackendConnection {
    let id = UUID()
    let descriptor: BackendDescriptor
    let capabilities: Set<BackendCapability>
    let healthy: Bool
    let agentSelectionPolicy: BackendAgentSelectionPolicy
    let projects: any BackendProjectsService
    let sessions: any BackendSessionsService
    let chat: any BackendChatService
    let models: any BackendModelsService
    let events: any BackendEventSource
    let commands: (any BackendCommandsService)?
    let sessionForms: (any BackendSessionFormsService)?
    var globalForms: (any BackendGlobalFormsService)? { sessionForms as? any BackendGlobalFormsService }
    let projectLifecycle: (any BackendProjectLifecycleService)?
    let worktrees: (any BackendWorktreesService)?
    let worktreeReset: (any BackendWorktreeResetService)?
    let sessionSelection: (any BackendSessionSelectionService)?
    let sessionActivity: (any BackendSessionActivityService)?
    let sessionPermissions: (any BackendSessionPermissionsService)?
    let mcp: (any BackendMCPService)?
    private(set) var isClosed = false
    private var subscribers: [UUID: AsyncStream<BackendEvent>.Continuation] = [:]
    private var eventGeneration = 0

    init(
        descriptor: BackendDescriptor,
        capabilities: Set<BackendCapability> = [],
        healthy: Bool = true,
        projects: any BackendProjectsService,
        sessions: any BackendSessionsService,
        chat: any BackendChatService,
        models: any BackendModelsService,
        events: any BackendEventSource,
        commands: (any BackendCommandsService)? = nil,
        sessionForms: (any BackendSessionFormsService)? = nil,
        projectLifecycle: (any BackendProjectLifecycleService)? = nil,
        worktrees: (any BackendWorktreesService)? = nil,
        worktreeReset: (any BackendWorktreeResetService)? = nil,
        sessionSelection: (any BackendSessionSelectionService)? = nil,
        sessionActivity: (any BackendSessionActivityService)? = nil,
        agentSelectionPolicy: BackendAgentSelectionPolicy = .mutable,
        sessionPermissions: (any BackendSessionPermissionsService)? = nil,
        mcp: (any BackendMCPService)? = nil
    ) {
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.healthy = healthy
        self.agentSelectionPolicy = agentSelectionPolicy
        self.projects = projects
        self.sessions = sessions
        self.chat = chat
        self.models = models
        self.events = events
        self.commands = commands
        self.sessionForms = sessionForms
        self.projectLifecycle = projectLifecycle
        self.worktrees = worktrees
        self.worktreeReset = worktreeReset
        self.sessionSelection = sessionSelection
        self.sessionActivity = sessionActivity
        self.sessionPermissions = sessionPermissions
        self.mcp = mcp
    }

    func require(_ capability: BackendCapability) throws {
        guard !isClosed else { throw BackendError.disconnected }
        guard capabilities.contains(capability) else { throw BackendError.unsupported(capability) }
    }

    func eventStream() -> AsyncStream<BackendEvent> {
        let subscriberID = UUID()
        let pair = AsyncStream<BackendEvent>.makeStream()
        guard !isClosed else {
            pair.continuation.finish()
            return pair.stream
        }
        let shouldStart = subscribers.isEmpty
        subscribers[subscriberID] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.removeSubscriber(subscriberID) }
        }
        if shouldStart {
            eventGeneration &+= 1
            let generation = eventGeneration
            events.start { [weak self] event in
                guard let self, !self.isClosed, self.eventGeneration == generation else { return }
                for subscriber in self.subscribers.values { subscriber.yield(event) }
            }
        }
        return pair.stream
    }

    private func removeSubscriber(_ id: UUID) {
        guard subscribers.removeValue(forKey: id) != nil, subscribers.isEmpty else { return }
        eventGeneration &+= 1
        events.stop()
    }

    func stopEvents() {
        eventGeneration &+= 1
        events.stop()
        let current = Array(subscribers.values)
        subscribers.removeAll()
        for subscriber in current { subscriber.finish() }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        stopEvents()
    }
}
