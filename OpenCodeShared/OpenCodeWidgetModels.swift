import Foundation

enum OpenCodeWidgetKind {
    static let recentSessions = "OpenCodeRecentSessionsWidget"
    static let pinnedSessions = "OpenCodePinnedSessionsWidget"
    static let actionShortcut = "OpenCodeActionWidget"
    static let newSessionShortcut = "OpenCodeNewSessionWidget"
    static let actionControl = "OpenCodeActionControl"
    static let newSessionControl = "OpenCodeNewSessionControl"
    static let providerUsageBars = "OpenCodeProviderUsageBarsWidget"
    static let providerUsageRings = "OpenCodeProviderUsageRingsWidget"
}

enum OpenCodeWidgetSessionStatus: String, Codable, Hashable, Sendable {
    case needsAction
    case working
    case ready
    case watching

    var title: LocalizedStringResource {
        switch self {
        case .needsAction:
            return "Needs Action"
        case .working:
            return "Working"
        case .ready:
            return "Ready"
        case .watching:
            return "Watching"
        }
    }
}

enum OpenCodeWidgetSummaryKind: String, Codable, Hashable, Sendable {
    case permission
    case question
    case snippet

    var title: LocalizedStringResource {
        switch self {
        case .permission:
            return "PERMISSION"
        case .question:
            return "QUESTION"
        case .snippet:
            return "LATEST"
        }
    }
}

struct OpenCodeWidgetServerSnapshot: Codable, Identifiable, Hashable, Sendable, OpenCodeWidgetOwnedSnapshot {
    let id: String
    let displayName: String
    let baseURL: String
    let username: String
    let generatedAt: Date
    let isLastConnected: Bool
    var profile: OpenCodeProfileIdentity? = nil
    var serverID: String { id }
    var entityID: String { owner.entityID() }
    var supportsNewSession: Bool? = nil
    var supportsCommands: Bool? = nil
    var offersNewSession: Bool { supportsNewSession ?? (owner.profile == .legacy) }
    var offersCommands: Bool { supportsCommands ?? (owner.profile == .legacy) }
}

struct OpenCodeWidgetProjectSnapshot: Codable, Identifiable, Hashable, Sendable, OpenCodeWidgetOwnedSnapshot {
    let id: String
    let serverID: String
    let title: String
    let worktree: String?
    let sortTitle: String
    var profile: OpenCodeProfileIdentity? = nil
    var entityID: String { owner.entityID([id]) }
    var executionDirectory: String? = nil
    var offersNewSession: Bool? = nil
}

struct OpenCodeWidgetSessionSnapshot: Codable, Identifiable, Hashable, Sendable, OpenCodeWidgetOwnedSnapshot {
    let id: String
    let serverID: String
    let projectID: String
    let title: String
    let projectLabel: String
    let directory: String?
    let workspaceID: String?
    let status: OpenCodeWidgetSessionStatus
    let summaryKind: OpenCodeWidgetSummaryKind
    let summaryText: String
    let updatedAt: Date?
    let lastActiveAt: Date
    let isPinned: Bool
    let pinOrder: Int?
    var profile: OpenCodeProfileIdentity? = nil
    var entityID: String { owner.entityID([id]) }
}

struct OpenCodeWidgetCommandSnapshot: Codable, Identifiable, Hashable, Sendable, OpenCodeWidgetOwnedSnapshot {
    let id: String
    let serverID: String
    let projectID: String
    let directory: String?
    let name: String
    let summary: String?
    let sortTitle: String
    var profile: OpenCodeProfileIdentity? = nil
    var entityID: String { owner.profile == .legacy ? id : owner.entityID([projectID, name]) }
}

struct OpenCodeWidgetModelSnapshot: Codable, Identifiable, Hashable, Sendable, OpenCodeWidgetOwnedSnapshot {
    let id: String
    let serverID: String
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let reasoningVariants: [String]
    let sortTitle: String
    var profile: OpenCodeProfileIdentity? = nil
    var entityID: String { owner.profile == .legacy ? id : owner.entityID([providerID, modelID]) }
}

struct OpenCodeWidgetSnapshotPayload: Codable, Hashable, Sendable {
    var servers: [OpenCodeWidgetServerSnapshot]
    var projects: [OpenCodeWidgetProjectSnapshot]
    var sessions: [OpenCodeWidgetSessionSnapshot]
    var commands: [OpenCodeWidgetCommandSnapshot]
    var models: [OpenCodeWidgetModelSnapshot]
    var generatedAt: Date

    static let empty = OpenCodeWidgetSnapshotPayload(
        servers: [],
        projects: [],
        sessions: [],
        commands: [],
        models: [],
        generatedAt: .distantPast
    )

    init(
        servers: [OpenCodeWidgetServerSnapshot],
        projects: [OpenCodeWidgetProjectSnapshot],
        sessions: [OpenCodeWidgetSessionSnapshot],
        commands: [OpenCodeWidgetCommandSnapshot] = [],
        models: [OpenCodeWidgetModelSnapshot] = [],
        generatedAt: Date
    ) {
        self.servers = servers
        self.projects = projects
        self.sessions = sessions
        self.commands = commands
        self.models = models
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case servers
        case projects
        case sessions
        case commands
        case models
        case generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        servers = try container.decodeIfPresent([OpenCodeWidgetServerSnapshot].self, forKey: .servers) ?? []
        projects = try container.decodeIfPresent([OpenCodeWidgetProjectSnapshot].self, forKey: .projects) ?? []
        sessions = try container.decodeIfPresent([OpenCodeWidgetSessionSnapshot].self, forKey: .sessions) ?? []
        commands = try container.decodeIfPresent([OpenCodeWidgetCommandSnapshot].self, forKey: .commands) ?? []
        models = try container.decodeIfPresent([OpenCodeWidgetModelSnapshot].self, forKey: .models) ?? []
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
    }

    func lastConnectedServerID() -> String? {
        lastConnectedServer()?.id
    }

    func lastConnectedServer() -> OpenCodeWidgetServerSnapshot? {
        servers.first(where: \.isLastConnected) ?? servers.sorted { $0.generatedAt > $1.generatedAt }.first
    }
}

enum OpenCodeWidgetDeepLink {
    enum Kind: Equatable, Sendable {
        case session(sessionID: String)
        case action(commandName: String)
        case newSession
    }

    struct Request: Equatable, Sendable {
        var kind: Kind
        var serverID: String?
        var projectID: String?
        var directory: String?
        var providerID: String?
        var modelID: String?
        var reasoningVariant: String?
        var profile: OpenCodeProfileIdentity = .legacy
        var workspaceID: String? = nil
    }

    static let scheme = "openclient"
    static let host = "widget"

    static func sessionURL(_ session: OpenCodeWidgetSessionSnapshot) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/session"
        components.queryItems = [
            URLQueryItem(name: "profile", value: session.owner.profile.rawValue),
            URLQueryItem(name: "serverID", value: session.serverID),
            URLQueryItem(name: "sessionID", value: session.id),
            URLQueryItem(name: "projectID", value: session.projectID)
        ]
        if let directory = normalizedDirectory(session.directory), session.owner.profile == .v2 || directory != "/" {
            components.queryItems?.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID = session.workspaceID {
            components.queryItems?.append(URLQueryItem(name: "workspaceID", value: workspaceID))
        }
        return components.url
    }

    static func actionURL(
        serverID: String?,
        projectID: String?,
        directory: String?,
        commandName: String?,
        providerID: String?,
        modelID: String?,
        reasoningVariant: String?,
        profile: OpenCodeProfileIdentity = .legacy
    ) -> URL? {
        guard let commandName, !commandName.isEmpty,
              serverID?.isEmpty == false, projectID?.isEmpty == false else { return nil }
        return url(
            path: "/action",
            serverID: serverID,
            projectID: projectID,
            directory: directory,
            commandName: commandName,
            providerID: providerID,
            modelID: modelID,
            reasoningVariant: reasoningVariant,
            profile: profile
        )
    }

    static func newSessionURL(
        serverID: String?,
        projectID: String?,
        directory: String?,
        providerID: String?,
        modelID: String?,
        reasoningVariant: String?,
        profile: OpenCodeProfileIdentity = .legacy
    ) -> URL? {
        guard let serverID, !serverID.isEmpty, let projectID, !projectID.isEmpty else { return nil }
        return url(
            path: "/new-session",
            serverID: serverID,
            projectID: projectID,
            directory: directory,
            commandName: nil,
            providerID: providerID,
            modelID: modelID,
            reasoningVariant: reasoningVariant,
            profile: profile
        )
    }

    static func request(from url: URL) -> Request? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        guard Set(queryItems.map(\.name)).count == queryItems.count else { return nil }
        let profile: OpenCodeProfileIdentity
        if queryItems.contains(where: { $0.name == "profile" }) {
            guard let raw = queryItems.value(named: "profile"),
                  let decoded = OpenCodeProfileIdentity(rawValue: raw) else { return nil }
            profile = decoded
        } else {
            profile = .legacy
        }

        let kind: Kind
        switch url.path {
        case "/session":
            guard let sessionID = queryItems.value(named: "sessionID"), !sessionID.isEmpty,
                  let serverID = queryItems.value(named: "serverID"), !serverID.isEmpty,
                  let projectID = queryItems.value(named: "projectID"), !projectID.isEmpty else { return nil }
            kind = .session(sessionID: sessionID)
        case "/action":
            guard let commandName = queryItems.value(named: "command"), !commandName.isEmpty else { return nil }
            kind = .action(commandName: commandName)
        case "/new-session":
            kind = .newSession
        default:
            return nil
        }

        return Request(
            kind: kind,
            serverID: queryItems.value(named: "serverID"),
            projectID: queryItems.value(named: "projectID"),
            directory: profile == .legacy && queryItems.value(named: "directory") == "/" ? nil : normalizedDirectory(queryItems.value(named: "directory")),
            providerID: queryItems.value(named: "providerID"),
            modelID: queryItems.value(named: "modelID"),
            reasoningVariant: queryItems.value(named: "reasoning"),
            profile: profile,
            workspaceID: queryItems.value(named: "workspaceID")
        )
    }

    private static func url(
        path: String,
        serverID: String?,
        projectID: String?,
        directory: String?,
        commandName: String?,
        providerID: String?,
        modelID: String?,
        reasoningVariant: String?,
        profile: OpenCodeProfileIdentity
    ) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        var queryItems: [URLQueryItem] = []
        appendQueryItem(name: "profile", value: profile.rawValue, to: &queryItems)
        appendQueryItem(name: "serverID", value: serverID, to: &queryItems)
        appendQueryItem(name: "projectID", value: projectID, to: &queryItems)
        appendQueryItem(name: "directory", value: profile == .legacy && directory == "/" ? nil : normalizedDirectory(directory), to: &queryItems)
        appendQueryItem(name: "command", value: commandName, to: &queryItems)
        appendQueryItem(name: "providerID", value: providerID, to: &queryItems)
        appendQueryItem(name: "modelID", value: modelID, to: &queryItems)
        appendQueryItem(name: "reasoning", value: reasoningVariant, to: &queryItems)
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private static func appendQueryItem(name: String, value: String?, to queryItems: inout [URLQueryItem]) {
        guard let value, !value.isEmpty else { return }
        queryItems.append(URLQueryItem(name: name, value: value))
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory
    }
}

private extension [URLQueryItem] {
    func value(named name: String) -> String? {
        first(where: { $0.name == name })?.value
    }
}
