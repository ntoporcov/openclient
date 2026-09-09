import AppIntents
import Foundation

struct OpenCodeWidgetServerEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Connection")
    static let defaultQuery = OpenCodeWidgetServerQuery()

    let id: String
    let displayName: String
    let baseURL: String
    let username: String
    var profile: OpenCodeProfileIdentity = .legacy
    var rawServerID: String? = nil

    var displayRepresentation: DisplayRepresentation {
        let subtitle = username.isEmpty ? baseURL : "\(username) · \(baseURL)"
        return DisplayRepresentation(title: "\(displayName)", subtitle: "\(subtitle)")
    }
}

struct OpenCodeWidgetProjectEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static let defaultQuery = OpenCodeWidgetProjectQuery()

    let id: String
    let serverID: String
    let projectID: String
    let title: String
    let directory: String?
    var profile: OpenCodeProfileIdentity = .legacy
    var rawServerID: String? = nil

    var displayRepresentation: DisplayRepresentation {
        if let directory {
            DisplayRepresentation(title: "\(title)", subtitle: "\(directory)")
        } else {
            DisplayRepresentation(title: "\(title)")
        }
    }
}

struct OpenCodeWidgetCommandEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Command")
    static let defaultQuery = OpenCodeWidgetCommandQuery()

    let id: String
    let serverID: String
    let projectID: String
    let directory: String?
    let name: String
    let summary: String?

    var displayRepresentation: DisplayRepresentation {
        if let summary {
            DisplayRepresentation(title: "/\(name)", subtitle: "\(summary)")
        } else {
            DisplayRepresentation(title: "/\(name)")
        }
    }
}

struct OpenCodeWidgetModelEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Model")
    static let defaultQuery = OpenCodeWidgetModelQuery()

    let id: String
    let serverID: String
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let reasoningVariants: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(modelName)",
            subtitle: "\(providerName)"
        )
    }
}

struct OpenCodeWidgetServerQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeWidgetServerEntity.ID]) async throws -> [OpenCodeWidgetServerEntity] {
        let requested = Set(identifiers)
        return OpenCodeWidgetOptions.servers().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [OpenCodeWidgetServerEntity] {
        OpenCodeWidgetOptions.servers()
    }

    func defaultResult() async -> OpenCodeWidgetServerEntity? {
        OpenCodeWidgetOptions.defaultServer()
    }
}

struct OpenCodeWidgetProjectQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeWidgetProjectEntity.ID]) async throws -> [OpenCodeWidgetProjectEntity] {
        let requested = Set(identifiers)
        return OpenCodeWidgetOptions.allProjects().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [OpenCodeWidgetProjectEntity] {
        OpenCodeWidgetOptions.projects(server: nil)
    }

    func defaultResult() async -> OpenCodeWidgetProjectEntity? {
        nil
    }
}

struct OpenCodeWidgetCommandQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeWidgetCommandEntity.ID]) async throws -> [OpenCodeWidgetCommandEntity] {
        let requested = Set(identifiers)
        return OpenCodeWidgetOptions.allCommands().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [OpenCodeWidgetCommandEntity] {
        OpenCodeWidgetOptions.commands(server: nil, project: nil)
    }
}

struct OpenCodeWidgetModelQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeWidgetModelEntity.ID]) async throws -> [OpenCodeWidgetModelEntity] {
        let requested = Set(identifiers)
        return OpenCodeWidgetOptions.allModels().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [OpenCodeWidgetModelEntity] {
        OpenCodeWidgetOptions.models(server: nil)
    }
}

struct OpenCodeActionWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Start Slash Command"
    static let description = IntentDescription("Create a new OpenClient session and send a selected slash command.")

    @Parameter(title: "Connection") var server: OpenCodeWidgetServerEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeActionWidgetProjectOptionsProvider()) var project: OpenCodeWidgetProjectEntity?
    @Parameter(title: "Command", optionsProvider: OpenCodeActionWidgetCommandOptionsProvider()) var command: OpenCodeWidgetCommandEntity?
    @Parameter(title: "Model", optionsProvider: OpenCodeActionWidgetModelOptionsProvider()) var model: OpenCodeWidgetModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeActionWidgetReasoningOptionsProvider()) var reasoning: String?

    init() {}
}

struct OpenCodeNewSessionWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Start Session"
    static let description = IntentDescription("Create a blank OpenClient session in a selected project.")

    @Parameter(title: "Connection") var server: OpenCodeWidgetServerEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeNewSessionWidgetProjectOptionsProvider()) var project: OpenCodeWidgetProjectEntity?
    @Parameter(title: "Model", optionsProvider: OpenCodeNewSessionWidgetModelOptionsProvider()) var model: OpenCodeWidgetModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeNewSessionWidgetReasoningOptionsProvider()) var reasoning: String?

    init() {}
}

@available(iOS 18.0, *)
struct OpenCodeActionControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Start Slash Command"
    static let description = IntentDescription("Open OpenClient, start a session, and send a selected slash command.")

    @Parameter(title: "Connection") var server: OpenCodeWidgetServerEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeActionControlProjectOptionsProvider()) var project: OpenCodeWidgetProjectEntity?
    @Parameter(title: "Command", optionsProvider: OpenCodeActionControlCommandOptionsProvider()) var command: OpenCodeWidgetCommandEntity?
    @Parameter(title: "Model", optionsProvider: OpenCodeActionControlModelOptionsProvider()) var model: OpenCodeWidgetModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeActionControlReasoningOptionsProvider()) var reasoning: String?

    init() {}
}

@available(iOS 18.0, *)
struct OpenCodeNewSessionControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Start Session"
    static let description = IntentDescription("Open OpenClient and start a blank session in a selected project.")

    @Parameter(title: "Connection") var server: OpenCodeWidgetServerEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeNewSessionControlProjectOptionsProvider()) var project: OpenCodeWidgetProjectEntity?
    @Parameter(title: "Model", optionsProvider: OpenCodeNewSessionControlModelOptionsProvider()) var model: OpenCodeWidgetModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeNewSessionControlReasoningOptionsProvider()) var reasoning: String?

    init() {}
}

struct OpenCodeActionWidgetProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionWidgetConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetProjectEntity] {
        OpenCodeWidgetOptions.projects(server: intent?.server)
    }
}

struct OpenCodeActionWidgetCommandOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionWidgetConfiguration>(\.$project) var intent

    func results() async throws -> [OpenCodeWidgetCommandEntity] {
        OpenCodeWidgetOptions.commands(server: intent?.server, project: intent?.project)
    }
}

struct OpenCodeActionWidgetModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionWidgetConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetModelEntity] {
        OpenCodeWidgetOptions.models(server: intent?.server)
    }
}

struct OpenCodeActionWidgetReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionWidgetConfiguration>(\.$model) var intent

    func results() async throws -> [String] {
        OpenCodeWidgetOptions.reasoningVariants(model: intent?.model)
    }
}

struct OpenCodeNewSessionWidgetProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionWidgetConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetProjectEntity] {
        OpenCodeWidgetOptions.projects(server: intent?.server)
    }
}

struct OpenCodeNewSessionWidgetModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionWidgetConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetModelEntity] {
        OpenCodeWidgetOptions.models(server: intent?.server)
    }
}

struct OpenCodeNewSessionWidgetReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionWidgetConfiguration>(\.$model) var intent

    func results() async throws -> [String] {
        OpenCodeWidgetOptions.reasoningVariants(model: intent?.model)
    }
}

@available(iOS 18.0, *)
struct OpenCodeActionControlProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionControlConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetProjectEntity] {
        OpenCodeWidgetOptions.projects(server: intent?.server)
    }
}

@available(iOS 18.0, *)
struct OpenCodeActionControlCommandOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionControlConfiguration>(\.$project) var intent

    func results() async throws -> [OpenCodeWidgetCommandEntity] {
        OpenCodeWidgetOptions.commands(server: intent?.server, project: intent?.project)
    }
}

@available(iOS 18.0, *)
struct OpenCodeActionControlModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionControlConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetModelEntity] {
        OpenCodeWidgetOptions.models(server: intent?.server)
    }
}

@available(iOS 18.0, *)
struct OpenCodeActionControlReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeActionControlConfiguration>(\.$model) var intent

    func results() async throws -> [String] {
        OpenCodeWidgetOptions.reasoningVariants(model: intent?.model)
    }
}

@available(iOS 18.0, *)
struct OpenCodeNewSessionControlProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionControlConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetProjectEntity] {
        OpenCodeWidgetOptions.projects(server: intent?.server)
    }
}

@available(iOS 18.0, *)
struct OpenCodeNewSessionControlModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionControlConfiguration>(\.$server) var intent

    func results() async throws -> [OpenCodeWidgetModelEntity] {
        OpenCodeWidgetOptions.models(server: intent?.server)
    }
}

@available(iOS 18.0, *)
struct OpenCodeNewSessionControlReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeNewSessionControlConfiguration>(\.$model) var intent

    func results() async throws -> [String] {
        OpenCodeWidgetOptions.reasoningVariants(model: intent?.model)
    }
}

enum OpenCodeWidgetOptions {
    static func servers() -> [OpenCodeWidgetServerEntity] {
        let payload = OpenCodeWidgetStore().load()
        return payload.servers
            .filter { $0.offersNewSession || $0.offersCommands }
            .sorted { lhs, rhs in
                if lhs.isLastConnected != rhs.isLastConnected {
                    return lhs.isLastConnected
                }
                let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.generatedAt > rhs.generatedAt
            }
            .map { server in
                OpenCodeWidgetServerEntity(
                    id: server.entityID,
                    displayName: server.displayName,
                    baseURL: server.baseURL,
                    username: server.username,
                    profile: server.owner.profile,
                    rawServerID: server.id
                )
            }
    }

    static func defaultServer() -> OpenCodeWidgetServerEntity? {
        servers().first
    }

    static func allProjects() -> [OpenCodeWidgetProjectEntity] {
        projectEntities(serverID: nil)
    }

    static func projects(server: OpenCodeWidgetServerEntity?) -> [OpenCodeWidgetProjectEntity] {
        guard let serverID = resolvedServerID(server) else { return [] }
        return projectEntities(serverID: serverID)
    }

    static func allCommands() -> [OpenCodeWidgetCommandEntity] {
        commandEntities(serverID: nil, projectID: nil)
    }

    static func commands(server: OpenCodeWidgetServerEntity?, project: OpenCodeWidgetProjectEntity?) -> [OpenCodeWidgetCommandEntity] {
        guard let serverID = resolvedServerID(server, fallbackServerID: project?.serverID) else { return [] }
        if let project, project.serverID != serverID { return [] }
        return commandEntities(serverID: serverID, projectID: project?.projectID)
    }

    static func allModels() -> [OpenCodeWidgetModelEntity] {
        modelEntities(serverID: nil)
    }

    static func models(server: OpenCodeWidgetServerEntity?) -> [OpenCodeWidgetModelEntity] {
        guard let serverID = resolvedServerID(server) else { return [] }
        return modelEntities(serverID: serverID)
    }

    static func reasoningVariants(model: OpenCodeWidgetModelEntity?) -> [String] {
        model?.reasoningVariants ?? []
    }

    static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory
    }

    private static func resolvedServerID(_ server: OpenCodeWidgetServerEntity?, fallbackServerID: String? = nil) -> String? {
        let candidate = server?.id ?? fallbackServerID ?? defaultServer()?.id
        return servers().contains(where: { $0.id == candidate }) ? candidate : nil
    }

    private static func projectEntities(serverID: String?) -> [OpenCodeWidgetProjectEntity] {
        let payload = OpenCodeWidgetStore().load()
        return payload.projects
            .filter { $0.offersNewSession ?? ($0.owner.profile == .legacy) }
            .filter { project in payload.servers.contains { $0.owner == project.owner && $0.offersNewSession } }
            .filter { serverID == nil || $0.owner.entityID() == serverID }
            .sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
            .map { project in
                OpenCodeWidgetProjectEntity(
                    id: project.entityID,
                    serverID: project.owner.entityID(),
                    projectID: project.id,
                    title: project.title,
                    directory: project.owner.profile == .v2 ? project.executionDirectory : (project.id == "global" ? nil : normalizedDirectory(project.worktree)),
                    profile: project.owner.profile,
                    rawServerID: project.serverID
                )
            }
    }

    private static func commandEntities(serverID: String?, projectID: String?) -> [OpenCodeWidgetCommandEntity] {
        let payload = OpenCodeWidgetStore().load()
        return payload.commands
            .filter { command in
                payload.servers.contains { $0.owner == command.owner && $0.offersCommands }
                    && payload.projects.contains { $0.owner == command.owner && $0.id == command.projectID }
            }
            .filter { serverID == nil || $0.owner.entityID() == serverID }
            .filter { projectID == nil || $0.projectID == projectID }
            .sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
            .map { command in
                OpenCodeWidgetCommandEntity(
                    id: command.entityID,
                    serverID: command.owner.entityID(),
                    projectID: command.projectID,
                    directory: normalizedDirectory(command.directory),
                    name: command.name,
                    summary: command.summary
                )
            }
    }

    private static func modelEntities(serverID: String?) -> [OpenCodeWidgetModelEntity] {
        let payload = OpenCodeWidgetStore().load()
        return payload.models
            .filter { model in payload.servers.contains { $0.owner == model.owner && $0.offersNewSession } }
            .filter { serverID == nil || $0.owner.entityID() == serverID }
            .sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
            .map { model in
                OpenCodeWidgetModelEntity(
                    id: model.entityID,
                    serverID: model.owner.entityID(),
                    providerID: model.providerID,
                    providerName: model.providerName,
                    modelID: model.modelID,
                    modelName: model.modelName,
                    reasoningVariants: model.reasoningVariants
                )
            }
    }

}
