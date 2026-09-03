import Foundation
import StoreKit

enum OpenCodeShortcutError: LocalizedError {
    case missingConnection
    case missingCredentials(String)
    case mismatchedConnection
    case mismatchedProject
    case mismatchedSession
    case emptyMessage
    case sessionLimitReached
    case promptLimitReached

    var errorDescription: String? {
        switch self {
        case .missingConnection:
            return String(localized: "Add and connect to an OpenClient server before running this shortcut.")
        case let .missingCredentials(name):
            return String(localized: "The saved password for \(name) is unavailable. Reconnect this server in OpenClient.")
        case .mismatchedConnection:
            return String(localized: "The selected shortcut items belong to different OpenClient connections.")
        case .mismatchedProject:
            return String(localized: "The selected session does not belong to the selected project.")
        case .mismatchedSession:
            return String(localized: "The selected session is no longer available for this project.")
        case .emptyMessage:
            return String(localized: "Enter a message before running this shortcut.")
        case .sessionLimitReached:
            return String(localized: "Free users can create one session. Open OpenClient to upgrade for unlimited sessions.")
        case .promptLimitReached:
            return String(localized: "The daily free prompt limit has been reached. Open OpenClient to upgrade for unlimited prompts.")
        }
    }
}

enum OpenCodeShortcutPromptReservation: Sendable {
    case none
    case reserved
}

struct OpenCodeShortcutUsageGate: Sendable {
    var isProUnlocked: @Sendable () async -> Bool = { await OpenCodeShortcutUsageGate.currentProUnlock() }

    func ensureCanCreateSession() async throws {
        guard !(await isProUnlocked()) else { return }
        let meter = normalizedMeter()
        guard meter.createdSessionCount < OpenClientCommerceLimits.freeSessionLimit else {
            throw OpenCodeShortcutError.sessionLimitReached
        }
    }

    func recordCreatedSession() async {
        guard !(await isProUnlocked()) else { return }
        var meter = normalizedMeter()
        meter.createdSessionCount += 1
        OpenClientUsageStore().save(meter)
    }

    func reservePrompt() async throws -> OpenCodeShortcutPromptReservation {
        guard !(await isProUnlocked()) else { return .none }
        var meter = normalizedMeter()
        guard meter.dailyPromptCount < OpenClientCommerceLimits.dailyPromptLimit else {
            throw OpenCodeShortcutError.promptLimitReached
        }
        meter.dailyPromptCount += 1
        OpenClientUsageStore().save(meter)
        return .reserved
    }

    func refundPrompt(_ reservation: OpenCodeShortcutPromptReservation) async {
        guard reservation == .reserved else { return }
        guard !(await isProUnlocked()) else { return }
        var meter = normalizedMeter()
        guard meter.dailyPromptCount > 0 else { return }
        meter.dailyPromptCount -= 1
        OpenClientUsageStore().save(meter)
    }

    private func normalizedMeter() -> OpenClientUsageMeter {
        var meter = OpenClientUsageStore().load()
        let original = meter
        meter.normalize()
        if meter != original {
            OpenClientUsageStore().save(meter)
        }
        return meter
    }

    private static func currentProUnlock() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if OpenClientProductID.grantsProAccess(transaction.productID), transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }
}

struct OpenCodeShortcutResolvedConnection: Sendable {
    let entity: OpenCodeShortcutConnectionEntity
    let config: OpenCodeServerConfig
}

struct OpenCodeShortcutService {
    private static let recentServerConfigsKey = "recentServerConfigs"

    var session: URLSession = .shared
    var usageGate = OpenCodeShortcutUsageGate()

    private let passwordStore = OpenCodeServerPasswordStore()

    init(session: URLSession = .shared, usageGate: OpenCodeShortcutUsageGate = OpenCodeShortcutUsageGate()) {
        self.session = session
        self.usageGate = usageGate
    }

    func connections() -> [OpenCodeShortcutConnectionEntity] {
        loadSavedServers().map { savedServer in
            let config = savedServer.serverConfig(password: "")
            return OpenCodeShortcutConnectionEntity(
                id: savedServer.recentServerID,
                displayName: config.displayName,
                baseURL: config.trimmedBaseURL,
                username: config.trimmedUsername
            )
        }
    }

    func projects(connection selectedConnection: OpenCodeShortcutConnectionEntity?) async throws -> [OpenCodeShortcutProjectEntity] {
        let resolved = try resolveConnection(selectedConnection)
        let projects = try await client(for: resolved).listProjects()
        return projects.map { projectEntity(from: $0, connectionID: resolved.entity.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func projects(matching identifiers: [OpenCodeShortcutProjectEntity.ID]) async throws -> [OpenCodeShortcutProjectEntity] {
        let requested = Set(identifiers)
        let connectionIDs = Set(identifiers.compactMap { identifier in
            OpenCodeShortcutEntityID.components(from: identifier, kind: "project")?.first
        })
        var values: [OpenCodeShortcutProjectEntity] = []
        for connection in connections().filter({ connectionIDs.contains($0.id) }) {
            values.append(contentsOf: try await projects(connection: connection).filter { requested.contains($0.id) })
        }
        return values
    }

    func sessions(
        connection selectedConnection: OpenCodeShortcutConnectionEntity?,
        project: OpenCodeShortcutProjectEntity
    ) async throws -> [OpenCodeShortcutSessionEntity] {
        let resolved = try resolveConnection(selectedConnection, fallbackConnectionID: project.connectionID)
        try validate(project: project, connection: resolved.entity)
        let sessions = try await client(for: resolved).listSessions(directory: project.directory, roots: true, limit: 100)
        return sessions.filter(\.isRootSession).map { session in
            sessionEntity(from: session, connectionID: resolved.entity.id, projectID: project.projectID, model: nil, reasoning: nil)
        }
    }

    func sessions(matching identifiers: [OpenCodeShortcutSessionEntity.ID]) async throws -> [OpenCodeShortcutSessionEntity] {
        let requested = Set(identifiers)
        var values: [OpenCodeShortcutSessionEntity] = []
        for identifier in identifiers {
            guard let components = OpenCodeShortcutEntityID.components(from: identifier, kind: "session"),
                  components.count == 3 else { continue }
            let connectionID = components[0]
            let projectID = components[1]
            guard let connection = connections().first(where: { $0.id == connectionID }),
                  let project = try await projects(connection: connection).first(where: { $0.projectID == projectID }) else { continue }
            values.append(contentsOf: try await sessions(connection: connection, project: project).filter { requested.contains($0.id) })
        }
        return values
    }

    func models(connection selectedConnection: OpenCodeShortcutConnectionEntity?) async throws -> [OpenCodeShortcutModelEntity] {
        let resolved = try resolveConnection(selectedConnection)
        let providerState = try await client(for: resolved).providerState()
        let connectedProviderIDs = Set(providerState.connected)
        let providers = providerState.all.filter { connectedProviderIDs.contains($0.id) }
        return providers.flatMap { provider in
            provider.models.values
                .filter { $0.status != "deprecated" }
                .map { modelEntity(from: $0, provider: provider, connectionID: resolved.entity.id) }
        }
        .sorted { lhs, rhs in
            let lhsTitle = "\(lhs.providerName) \(lhs.modelName)"
            let rhsTitle = "\(rhs.providerName) \(rhs.modelName)"
            return lhsTitle.localizedCaseInsensitiveCompare(rhsTitle) == .orderedAscending
        }
    }

    func models(matching identifiers: [OpenCodeShortcutModelEntity.ID]) async throws -> [OpenCodeShortcutModelEntity] {
        let requested = Set(identifiers)
        let connectionIDs = Set(identifiers.compactMap { identifier in
            OpenCodeShortcutEntityID.components(from: identifier, kind: "model")?.first
        })
        var values: [OpenCodeShortcutModelEntity] = []
        for connection in connections().filter({ connectionIDs.contains($0.id) }) {
            values.append(contentsOf: try await models(connection: connection).filter { requested.contains($0.id) })
        }
        return values
    }

    func createSession(
        connection selectedConnection: OpenCodeShortcutConnectionEntity?,
        project: OpenCodeShortcutProjectEntity,
        title: String?,
        model: OpenCodeShortcutModelEntity?,
        reasoning: String?
    ) async throws -> OpenCodeShortcutSessionEntity {
        let resolved = try resolveConnection(selectedConnection, fallbackConnectionID: project.connectionID)
        try validate(project: project, connection: resolved.entity)
        try validate(model: model, connection: resolved.entity)
        try await usageGate.ensureCanCreateSession()

        let created = try await client(for: resolved).createSession(
            title: normalizedTitle(title),
            directory: project.directory
        )
        await usageGate.recordCreatedSession()
        return sessionEntity(
            from: created,
            connectionID: resolved.entity.id,
            projectID: project.projectID,
            model: model,
            reasoning: reasoning
        )
    }

    func sendMessage(
        connection selectedConnection: OpenCodeShortcutConnectionEntity?,
        project: OpenCodeShortcutProjectEntity,
        session selectedSession: OpenCodeShortcutSessionEntity,
        message: String,
        model: OpenCodeShortcutModelEntity?,
        reasoning: String?
    ) async throws -> OpenCodeShortcutSessionEntity {
        let resolved = try resolveConnection(selectedConnection, fallbackConnectionID: project.connectionID)
        try validate(project: project, connection: resolved.entity)
        try validate(session: selectedSession, project: project, connection: resolved.entity)
        try validate(model: model, connection: resolved.entity)

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw OpenCodeShortcutError.emptyMessage }

        let outputSession = selectedSession.applying(model: model, reasoning: reasoning)
        let reservation = try await usageGate.reservePrompt()
        do {
            try await client(for: resolved).sendMessageAsync(
                sessionID: selectedSession.sessionID,
                text: trimmedMessage,
                directory: messageDirectory(session: selectedSession, project: project),
                model: model?.modelReference ?? selectedSession.modelReference,
                variant: Self.normalizedReasoning(reasoning) ?? selectedSession.reasoningVariant
            )
            return outputSession
        } catch {
            await usageGate.refundPrompt(reservation)
            throw error
        }
    }

    func createSessionAndSendMessage(
        connection selectedConnection: OpenCodeShortcutConnectionEntity?,
        project: OpenCodeShortcutProjectEntity,
        title: String?,
        message: String,
        model: OpenCodeShortcutModelEntity?,
        reasoning: String?
    ) async throws -> OpenCodeShortcutSessionEntity {
        let resolved = try resolveConnection(selectedConnection, fallbackConnectionID: project.connectionID)
        try validate(project: project, connection: resolved.entity)
        try validate(model: model, connection: resolved.entity)

        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { throw OpenCodeShortcutError.emptyMessage }

        try await usageGate.ensureCanCreateSession()
        let reservation = try await usageGate.reservePrompt()
        do {
            let created = try await client(for: resolved).createSession(
                title: normalizedTitle(title),
                directory: project.directory
            )
            await usageGate.recordCreatedSession()
            let sessionEntity = sessionEntity(
                from: created,
                connectionID: resolved.entity.id,
                projectID: project.projectID,
                model: model,
                reasoning: reasoning
            )
            try await client(for: resolved).sendMessageAsync(
                sessionID: sessionEntity.sessionID,
                text: trimmedMessage,
                directory: messageDirectory(session: sessionEntity, project: project),
                model: model?.modelReference,
                variant: Self.normalizedReasoning(reasoning)
            )
            return sessionEntity
        } catch {
            await usageGate.refundPrompt(reservation)
            throw error
        }
    }

    func resolveConnection(
        _ selectedConnection: OpenCodeShortcutConnectionEntity?,
        fallbackConnectionID: String? = nil
    ) throws -> OpenCodeShortcutResolvedConnection {
        let savedConnections = connections()
        let entity = selectedConnection
            ?? fallbackConnectionID.flatMap { fallbackID in savedConnections.first { $0.id == fallbackID } }
            ?? savedConnections.first

        guard let entity else { throw OpenCodeShortcutError.missingConnection }
        if let selectedConnection, let fallbackConnectionID, selectedConnection.id != fallbackConnectionID {
            throw OpenCodeShortcutError.mismatchedConnection
        }

        let password = passwordStore.loadPassword(for: entity.id)
        guard let password, !password.isEmpty else {
            throw OpenCodeShortcutError.missingCredentials(entity.displayName)
        }

        let config = OpenCodeServerConfig(
            name: entity.displayName,
            baseURL: entity.baseURL,
            username: entity.username,
            password: password
        )
        return OpenCodeShortcutResolvedConnection(entity: entity, config: config)
    }

    static func normalizedReasoning(_ reasoning: String?) -> String? {
        let trimmed = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func client(for connection: OpenCodeShortcutResolvedConnection) -> OpenCodeAPIClient {
        OpenCodeAPIClient(config: connection.config, session: session)
    }

    private func validate(project: OpenCodeShortcutProjectEntity, connection: OpenCodeShortcutConnectionEntity) throws {
        guard project.connectionID == connection.id else { throw OpenCodeShortcutError.mismatchedConnection }
    }

    private func validate(session: OpenCodeShortcutSessionEntity, project: OpenCodeShortcutProjectEntity, connection: OpenCodeShortcutConnectionEntity) throws {
        guard session.connectionID == connection.id else { throw OpenCodeShortcutError.mismatchedConnection }
        guard session.projectID == project.projectID else { throw OpenCodeShortcutError.mismatchedProject }
    }

    private func validate(model: OpenCodeShortcutModelEntity?, connection: OpenCodeShortcutConnectionEntity) throws {
        guard let model else { return }
        guard model.connectionID == connection.id else { throw OpenCodeShortcutError.mismatchedConnection }
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func messageDirectory(session: OpenCodeShortcutSessionEntity, project: OpenCodeShortcutProjectEntity) -> String? {
        if session.directory == "/" { return nil }
        if let directory = Self.normalizedDirectory(session.directory) {
            return directory
        }
        return project.projectID == "global" ? nil : project.directory
    }

    private func projectEntity(from project: OpenCodeProject, connectionID: String) -> OpenCodeShortcutProjectEntity {
        OpenCodeShortcutProjectEntity(
            id: OpenCodeShortcutEntityID.make(kind: "project", components: [connectionID, project.id]),
            connectionID: connectionID,
            projectID: project.id,
            title: Self.projectTitle(for: project),
            directory: project.id == "global" ? nil : Self.normalizedDirectory(project.worktree)
        )
    }

    private func sessionEntity(
        from session: OpenCodeSession,
        connectionID: String,
        projectID: String,
        model: OpenCodeShortcutModelEntity?,
        reasoning: String?
    ) -> OpenCodeShortcutSessionEntity {
        let title = (session.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenCodeShortcutSessionEntity(
            id: OpenCodeShortcutEntityID.make(kind: "session", components: [connectionID, projectID, session.id]),
            connectionID: connectionID,
            projectID: projectID,
            sessionID: session.id,
            title: title.isEmpty ? String(localized: "Session") : title,
            directory: Self.normalizedDirectory(session.directory),
            workspaceID: session.workspaceID,
            providerID: model?.providerID,
            modelID: model?.modelID,
            reasoningVariant: Self.normalizedReasoning(reasoning)
        )
    }

    private func modelEntity(from model: OpenCodeModel, provider: OpenCodeProvider, connectionID: String) -> OpenCodeShortcutModelEntity {
        let reasoningVariants = model.capabilities.reasoning
            ? (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            : []
        return OpenCodeShortcutModelEntity(
            id: OpenCodeShortcutEntityID.make(kind: "model", components: [connectionID, provider.id, model.id]),
            connectionID: connectionID,
            providerID: provider.id,
            providerName: provider.name,
            modelID: model.id,
            modelName: model.name,
            reasoningVariants: reasoningVariants
        )
    }

    private static func projectTitle(for project: OpenCodeProject) -> String {
        if let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let component = directoryLastPathComponent(project.worktree), !component.isEmpty {
            return component
        }
        return project.id == "global" ? String(localized: "Global") : project.id
    }

    private static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              directory != "/" else { return nil }
        return directory
    }

    private static func directoryLastPathComponent(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init)
    }

    private func loadSavedServers() -> [OpenCodeSavedServer] {
        guard let data = UserDefaults.standard.data(forKey: Self.recentServerConfigsKey) else {
            return []
        }
        if let savedServers = try? JSONDecoder().decode([OpenCodeSavedServer].self, from: data) {
            return savedServers
        }
        guard let rawEntries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return []
        }
        return rawEntries.compactMap { entry -> OpenCodeSavedServer? in
            guard JSONSerialization.isValidJSONObject(entry),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry) else {
                return nil
            }
            return try? JSONDecoder().decode(OpenCodeSavedServer.self, from: entryData)
        }
    }
}
