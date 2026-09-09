import Foundation

struct WidgetSnapshotInput {
    let backendMode: AppBackendMode
    let config: OpenCodeServerConfig
    let projects: [OpenCodeProject]
    let currentProject: OpenCodeProject?
    let effectiveDirectory: String?
    let sessions: [OpenCodeSession]
    let sessionTitlesByID: [String: String]
    let statuses: [String: String]
    let previews: [String: SessionPreview]
    let pinnedSessionIDs: [String]
    let permissionsBySessionID: [String: [OpenCodePermission]]
    let questionsBySessionID: [String: [OpenCodeQuestionRequest]]
    let commands: [OpenCodeCommand]
    let providers: [OpenCodeProvider]
    let visibleModelsByProviderID: [String: [OpenCodeModel]]
    var profile: OpenCodeProfileIdentity? = .legacy
    var projectsAreAuthoritative = true
    var commandsAreAuthoritative = false
    var modelsAreAuthoritative = false
    var supportsNewSession = false
    var supportsCommands = false
    var defaultDirectory: String? = nil
}

struct WidgetServerPublication: Sendable {
    let server: OpenCodeWidgetServerSnapshot
    let projects: [OpenCodeWidgetProjectSnapshot]
    let sessions: [OpenCodeWidgetSessionSnapshot]
    let replacingSessionIDs: Set<String>
    let commands: [OpenCodeWidgetCommandSnapshot]
    let replacingCommandProjectIDs: Set<String>
    let models: [OpenCodeWidgetModelSnapshot]
    let projectsAreAuthoritative: Bool
    let modelsAreAuthoritative: Bool
}

enum WidgetSnapshotBuilder {
    static let modelLimit = 120
    static let modelPerProviderLimit = 40

    static func build(
        from input: WidgetSnapshotInput,
        includeModelOptions: Bool,
        now: Date = .now
    ) -> WidgetServerPublication? {
        guard input.backendMode == .server || input.backendMode == .serverV2,
              input.config.hasCredentials, let profile = input.profile else { return nil }
        guard (input.backendMode == .serverV2) == (profile == .v2) else { return nil }

        let serverID = input.config.recentServerID
        let server = OpenCodeWidgetServerSnapshot(
            id: serverID,
            displayName: input.config.displayName,
            baseURL: input.config.trimmedBaseURL,
            username: input.config.trimmedUsername,
            generatedAt: now,
            isLastConnected: true,
            profile: profile,
            supportsNewSession: profile == .legacy || input.supportsNewSession,
            supportsCommands: profile == .legacy || input.supportsCommands
        )
        let projects = input.projects.map { project in
            let title = projectTitle(project)
            return OpenCodeWidgetProjectSnapshot(
                id: project.id,
                serverID: serverID,
                title: title,
                worktree: project.worktree,
                sortTitle: title.localizedLowercase,
                profile: profile,
                executionDirectory: project.id == "global" ? input.defaultDirectory : project.worktree,
                offersNewSession: profile == .legacy || (input.supportsNewSession
                    && (project.id != "global" || input.defaultDirectory?.isEmpty == false))
            )
        }
        let rootSessions = input.sessions.filter(\.isRootSession)
        var pinnedOrder: [String: Int] = [:]
        for (index, sessionID) in input.pinnedSessionIDs.enumerated() {
            pinnedOrder[sessionID] = index
        }
        let sessions = rootSessions.map { session in
            let summary = summary(for: session, input: input, now: now)
            return OpenCodeWidgetSessionSnapshot(
                id: session.id,
                serverID: serverID,
                projectID: projectID(for: session, input: input),
                title: sessionTitle(for: session, input: input),
                projectLabel: projectLabel(for: session, input: input),
                directory: session.directory,
                workspaceID: session.workspaceID,
                status: status(for: session, summaryKind: summary.kind, input: input),
                summaryKind: summary.kind,
                summaryText: summary.text,
                updatedAt: summary.updatedAt,
                lastActiveAt: summary.updatedAt ?? input.previews[session.id]?.date ?? .distantPast,
                isPinned: pinnedOrder[session.id] != nil,
                pinOrder: pinnedOrder[session.id],
                profile: profile
            )
        }
        let commands = profile == .legacy || input.supportsCommands ? commandSnapshots(input: input, serverID: serverID) : []
        let models = (profile == .legacy || input.supportsNewSession) && includeModelOptions ? modelSnapshots(input: input, serverID: serverID) : []
        let commandProjects = input.commandsAreAuthoritative ? Set([input.currentProject?.id].compactMap { $0 }) : Set(commands.map(\.projectID))

        return WidgetServerPublication(
            server: server,
            projects: projects,
            sessions: sessions,
            replacingSessionIDs: Set(rootSessions.map(\.id)),
            commands: commands,
            replacingCommandProjectIDs: commandProjects,
            models: models,
            projectsAreAuthoritative: input.projectsAreAuthoritative,
            modelsAreAuthoritative: includeModelOptions && input.modelsAreAuthoritative
        )
    }

    private static func commandSnapshots(input: WidgetSnapshotInput, serverID: String) -> [OpenCodeWidgetCommandSnapshot] {
        guard let project = input.currentProject else { return [] }
        let directory = project.id == "global" ? (input.profile == .v2 ? input.defaultDirectory : nil) : (input.effectiveDirectory ?? project.worktree)
        if input.profile == .v2, project.id == "global", directory?.isEmpty != false { return [] }
        var seen = Set<String>()
        return input.commands
            .filter { $0.source != "client" && seen.insert($0.name).inserted }
            .map { command in
                OpenCodeWidgetCommandSnapshot(
                    id: [serverID, project.id, command.name].joined(separator: "|"),
                    serverID: serverID,
                    projectID: project.id,
                    directory: directory,
                    name: command.name,
                    summary: command.description,
                    sortTitle: command.name.localizedLowercase,
                    profile: input.profile
                )
            }
            .sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
    }

    private static func modelSnapshots(input: WidgetSnapshotInput, serverID: String) -> [OpenCodeWidgetModelSnapshot] {
        var result: [OpenCodeWidgetModelSnapshot] = []
        for provider in input.providers {
            for model in (input.visibleModelsByProviderID[provider.id] ?? []).prefix(modelPerProviderLimit) {
                guard result.count < modelLimit else { break }
                let variants = model.capabilities.reasoning
                    ? (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    : []
                result.append(OpenCodeWidgetModelSnapshot(
                    id: [serverID, provider.id, model.id].joined(separator: "|"),
                    serverID: serverID,
                    providerID: provider.id,
                    providerName: provider.name,
                    modelID: model.id,
                    modelName: model.name,
                    reasoningVariants: variants,
                    sortTitle: "\(provider.name) \(model.name)".localizedLowercase,
                    profile: input.profile
                ))
            }
            if result.count >= modelLimit { break }
        }
        return result.sorted { $0.sortTitle.localizedCaseInsensitiveCompare($1.sortTitle) == .orderedAscending }
    }

    private static func projectID(for session: OpenCodeSession, input: WidgetSnapshotInput) -> String {
        if let projectID = session.projectID, !projectID.isEmpty { return projectID }
        if let directory = session.directory,
           let project = input.projects.first(where: { $0.worktree == directory }) {
            return project.id
        }
        return input.currentProject?.id ?? "global"
    }

    private static func projectLabel(for session: OpenCodeSession, input: WidgetSnapshotInput) -> String {
        let project = input.projects.first { project in
            if let projectID = session.projectID, project.id == projectID { return true }
            return session.directory == project.worktree
        }
        if let project { return projectTitle(project) }
        if let directory = session.directory, let component = lastPathComponent(directory), !component.isEmpty { return component }
        return String(localized: "Global")
    }

    private static func projectTitle(_ project: OpenCodeProject) -> String {
        if let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let component = lastPathComponent(project.worktree), !component.isEmpty { return component }
        return project.id == "global" ? String(localized: "Global") : project.id
    }

    private static func sessionTitle(for session: OpenCodeSession, input: WidgetSnapshotInput) -> String {
        let title = (input.sessionTitlesByID[session.id] ?? session.displayTitle())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Session") : title
    }

    private static func status(
        for session: OpenCodeSession,
        summaryKind: OpenCodeWidgetSummaryKind,
        input: WidgetSnapshotInput
    ) -> OpenCodeWidgetSessionStatus {
        if summaryKind == .permission || summaryKind == .question { return .needsAction }
        switch input.statuses[session.id] {
        case "busy": return .working
        case "idle": return .ready
        default: return .watching
        }
    }

    private static func summary(
        for session: OpenCodeSession,
        input: WidgetSnapshotInput,
        now: Date
    ) -> (kind: OpenCodeWidgetSummaryKind, text: String, updatedAt: Date?) {
        if let permission = input.permissionsBySessionID[session.id]?.first {
            return (.permission, permission.summary, now)
        }
        if let request = input.questionsBySessionID[session.id]?.first,
           let question = request.questions.first {
            return (.question, question.question, now)
        }
        if let preview = input.previews[session.id] {
            return (.snippet, preview.text, preview.date)
        }
        return (.snippet, String(localized: "No messages yet"), nil)
    }

    private static func lastPathComponent(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init)
    }
}
