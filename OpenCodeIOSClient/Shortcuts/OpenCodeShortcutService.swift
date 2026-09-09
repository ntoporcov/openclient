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
    case uncertainAdmission
    case uncertainCreation
    case rejected

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
        case .uncertainAdmission:
            return String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.")
        case .uncertainCreation:
            return String(localized: "Session creation could not be confirmed. Check the server before running this action again.")
        case .rejected:
            return String(localized: "OpenCode rejected the prompt.")
        }
    }
}

enum OpenCodeShortcutPromptReservation: Sendable {
    case none
    case reserved
}

@MainActor
struct OpenCodeShortcutUsageGate: Sendable {
    var isProUnlocked: @Sendable () async -> Bool = { await OpenCodeShortcutUsageGate.currentProUnlock() }
    var loadMeter: @MainActor @Sendable () -> OpenClientUsageMeter = { OpenClientUsageStore().load() }
    var saveMeter: @MainActor @Sendable (OpenClientUsageMeter) -> Void = { OpenClientUsageStore().save($0) }

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
        saveMeter(meter)
    }

    func reservePrompt() async throws -> OpenCodeShortcutPromptReservation {
        guard !(await isProUnlocked()) else { return .none }
        var meter = normalizedMeter()
        guard meter.dailyPromptCount < OpenClientCommerceLimits.dailyPromptLimit else {
            throw OpenCodeShortcutError.promptLimitReached
        }
        meter.dailyPromptCount += 1
        saveMeter(meter)
        return .reserved
    }

    func refundPrompt(_ reservation: OpenCodeShortcutPromptReservation) async {
        guard reservation == .reserved else { return }
        guard !(await isProUnlocked()) else { return }
        var meter = normalizedMeter()
        guard meter.dailyPromptCount > 0 else { return }
        meter.dailyPromptCount -= 1
        saveMeter(meter)
    }

    private func normalizedMeter() -> OpenClientUsageMeter {
        var meter = loadMeter()
        let original = meter
        meter.normalize()
        if meter != original {
            saveMeter(meter)
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

@MainActor
struct OpenCodeShortcutService {
    var session: URLSession = .shared
    var usageGate = OpenCodeShortcutUsageGate()
    var makeBackend: (@MainActor (OpenCodeServerConfig, URLSession) async throws -> BackendConnection)?
    var pendingOperations = ShortcutPendingOperationStore()

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
        let backend = try await backend(for: resolved)
        defer { backend.close() }
        let projects = try await backend.projects.projectsSnapshot().projects
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
        let backend = try await backend(for: resolved)
        defer { backend.close() }
        return try await sessionEntities(backend: backend, project: project, connectionID: resolved.entity.id)
    }

    func sessions(matching identifiers: [OpenCodeShortcutSessionEntity.ID]) async throws -> [OpenCodeShortcutSessionEntity] {
        let requested = Set(identifiers)
        let components = identifiers.compactMap { OpenCodeShortcutEntityID.components(from: $0, kind: "session") }
            .filter { $0.count == 3 }
        var values: [OpenCodeShortcutSessionEntity] = []
        for connection in connections() {
            let projectIDs = Set(components.filter { $0[0] == connection.id }.map { $0[1] })
            guard !projectIDs.isEmpty else { continue }
            let resolved = try resolveConnection(connection)
            let backend = try await backend(for: resolved)
            defer { backend.close() }
            let projects = try await backend.projects.projectsSnapshot().projects
            for project in projects where projectIDs.contains(project.id) {
                let entity = projectEntity(from: project, connectionID: connection.id)
                values.append(contentsOf: try await sessionEntities(backend: backend, project: entity, connectionID: connection.id)
                    .filter { requested.contains($0.id) })
            }
        }
        return values
    }

    private func sessionEntities(backend: BackendConnection, project: OpenCodeShortcutProjectEntity,
                                 connectionID: String) async throws -> [OpenCodeShortcutSessionEntity] {
        var values: [OpenCodeShortcutSessionEntity] = []
        var cursor: String?
        var cursors = Set<String>()
        var ids = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await backend.sessions.sessions(scope: scope(project: project), cursor: cursor, limit: 100, roots: true)
            for session in page.sessions where session.isRootSession && session.projectID == project.projectID {
                guard ids.insert(session.id).inserted else { continue }
                values.append(sessionEntity(from: session, connectionID: connectionID, projectID: project.projectID, model: nil, reasoning: nil))
            }
            guard let next = page.nextCursor, cursors.insert(next).inserted else { break }
            cursor = next
        } while true
        return values
    }

    func models(connection selectedConnection: OpenCodeShortcutConnectionEntity?) async throws -> [OpenCodeShortcutModelEntity] {
        let resolved = try resolveConnection(selectedConnection)
        let backend = try await backend(for: resolved)
        defer { backend.close() }
        let providers = try await backend.models.modelCatalog(scope: .init()).providers
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
        let backend = try await backend(for: resolved)
        defer { backend.close() }
        let identity = operationIdentity(resolved: resolved, backend: backend)
        let hash = try operationHash("create", identity: identity, project: project, title: title, model: model, reasoning: reasoning)
        if let pending = try pendingOperations.record(for: hash) {
            let wasActive = pendingOperations.isActive(pending)
            guard let sessionID = pending.sessionID else { throw OpenCodeShortcutError.uncertainCreation }
            let created = try await backend.sessions.session(id: sessionID, scope: scope(project: project, pending: pending))
            guard created.id == sessionID else { throw OpenCodeShortcutError.uncertainCreation }
            guard try pendingOperations.confirm(pending), !wasActive else { throw OpenCodeShortcutError.uncertainCreation }
            return sessionEntity(from: created, connectionID: resolved.entity.id, projectID: project.projectID, model: model, reasoning: reasoning)
        }
        let creation = try await creationRequest(backend: backend, project: project, title: title, model: model, reasoning: reasoning)
        // Claim again after suspension so concurrent invocations cannot both create.
        guard try pendingOperations.record(for: hash) == nil else { throw OpenCodeShortcutError.uncertainCreation }
        var pending = ShortcutPendingOperationStore.Record(requestHash: hash,
            serverNamespace: try ShortcutPendingOperationStore.requestHash(identity), directory: creation.scope.directory)
        guard try pendingOperations.claim(pending) else { throw OpenCodeShortcutError.uncertainCreation }
        defer { pendingOperations.finishInvocation(pending) }
        let created = try await create(creation, backend: backend, pending: &pending)
        guard try pendingOperations.remove(pending) || pendingOperations.isConfirmed(pending) else { throw OpenCodeShortcutError.uncertainCreation }
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
        let backend = try await backend(for: resolved)
        defer { backend.close() }
        let identity = operationIdentity(resolved: resolved, backend: backend)
        let hash = try operationHash("send", identity: identity, project: project, selectedSession: outputSession, message: trimmedMessage)
        if let pending = try pendingOperations.record(for: hash) {
            try await reconcile(pending, backend: backend, project: project)
            return outputSession
        }
        let scope = scope(project: project, session: selectedSession)
        let pending = ShortcutPendingOperationStore.Record(requestHash: hash,
            serverNamespace: try ShortcutPendingOperationStore.requestHash(identity), sessionID: selectedSession.sessionID,
            messageID: OpenCodeIdentifier.message(), directory: scope.directory, workspaceID: scope.workspaceID)
        try await pendingOperations.acquireSession(pending)
        defer { pendingOperations.finishInvocation(pending) }
        // A previous invocation may have become uncertain while this one waited for the lock.
        if let previous = try pendingOperations.record(for: hash) {
            try await reconcile(previous, backend: backend, project: project)
            return outputSession
        }
        try await checkSessionPending(pending, backend: backend, project: project)
        guard try pendingOperations.claim(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
        var reservation: OpenCodeShortcutPromptReservation = .none
        do {
            reservation = try await usageGate.reservePrompt()
            guard try pendingOperations.isCurrent(pending), pendingOperations.ownsSession(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
            if let selection = backend.sessionSelection,
               outputSession.modelReference != nil || outputSession.reasoningVariant != nil {
                let latest = try await revalidate(selectedSession, backend: backend, project: project)
                var reference = outputSession.modelReference
                if reference == nil {
                    reference = latest.model.map { .init(providerID: $0.providerID, modelID: $0.modelID) }
                }
                guard let reference else { throw BackendError.invalidScope }
                guard try pendingOperations.isCurrent(pending), pendingOperations.ownsSession(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
                try await selection.setModel(sessionID: selectedSession.sessionID, model: reference,
                    variant: outputSession.reasoningVariant, scope: scope)
            }
            try Task.checkCancellation()
        } catch {
            if try pendingOperations.remove(pending) { await usageGate.refundPrompt(reservation) }
            throw error
        }
        try await submit(pending, text: trimmedMessage, model: outputSession.modelReference, variant: outputSession.reasoningVariant,
            backend: backend, project: project, target: selectedSession, reservation: reservation)
        return outputSession
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

        let backend = try await backend(for: resolved)
        defer { backend.close() }
        let identity = operationIdentity(resolved: resolved, backend: backend)
        let hash = try operationHash("create-send", identity: identity, project: project, title: title,
            message: trimmedMessage, model: model, reasoning: reasoning)
        if let pending = try pendingOperations.record(for: hash) {
            guard let sessionID = pending.sessionID else { throw OpenCodeShortcutError.uncertainCreation }
            let created = try await backend.sessions.session(id: sessionID, scope: scope(project: project, pending: pending))
            guard created.id == sessionID else { throw OpenCodeShortcutError.uncertainCreation }
            try await reconcile(pending, backend: backend, project: project)
            return sessionEntity(from: created, connectionID: resolved.entity.id, projectID: project.projectID, model: model, reasoning: reasoning)
        }
        let creation = try await creationRequest(backend: backend, project: project, title: title, model: model, reasoning: reasoning)
        guard try pendingOperations.record(for: hash) == nil else { throw OpenCodeShortcutError.uncertainCreation }
        var pending = ShortcutPendingOperationStore.Record(requestHash: hash,
            serverNamespace: try ShortcutPendingOperationStore.requestHash(identity),
            messageID: OpenCodeIdentifier.message(), directory: creation.scope.directory)
        guard try pendingOperations.claim(pending) else { throw OpenCodeShortcutError.uncertainCreation }
        defer { pendingOperations.finishInvocation(pending) }
        let reservation: OpenCodeShortcutPromptReservation
        do {
            reservation = try await usageGate.reservePrompt()
        } catch {
            try pendingOperations.remove(pending)
            throw error
        }
        let created: OpenCodeSession
        do {
            created = try await create(creation, backend: backend, pending: &pending)
        } catch {
            // No prompt was transmitted, even if session creation itself is uncertain.
            await usageGate.refundPrompt(reservation)
            throw error
        }
        try await pendingOperations.acquireSession(pending)
        try await checkSessionPending(pending, backend: backend, project: project)
        try await submit(pending, text: trimmedMessage, model: model?.modelReference, variant: Self.normalizedReasoning(reasoning),
            backend: backend, project: project,
            target: sessionEntity(from: created, connectionID: resolved.entity.id, projectID: project.projectID, model: model, reasoning: reasoning),
            reservation: reservation)
        return sessionEntity(from: created, connectionID: resolved.entity.id, projectID: project.projectID, model: model, reasoning: reasoning)
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

        guard let savedServer = loadSavedServers().first(where: { $0.recentServerID == entity.id }) else {
            throw OpenCodeShortcutError.missingConnection
        }
        let password = passwordStore.loadPassword(for: entity.id)
        guard let password else {
            throw OpenCodeShortcutError.missingCredentials(entity.displayName)
        }

        let config = savedServer.serverConfig(password: password)
        return OpenCodeShortcutResolvedConnection(entity: entity, config: config)
    }

    nonisolated static func normalizedReasoning(_ reasoning: String?) -> String? {
        let trimmed = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func backend(for connection: OpenCodeShortcutResolvedConnection) async throws -> BackendConnection {
        if let makeBackend { return try await makeBackend(connection.config, session) }
        let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: connection.config, session: session),
            eventManager: OpenCodeEventManager())
        if connection.config.apiPreference == .legacy {
            // Known preference, not a health assertion. Shortcuts never publish connection UI state.
            return factory.makeConnection(profile: .legacy, version: "", healthy: false)
        }
        return try await factory.connect()
    }

    private func scope(project: OpenCodeShortcutProjectEntity, session: OpenCodeShortcutSessionEntity? = nil,
                       pending: ShortcutPendingOperationStore.Record? = nil) -> BackendScope {
        if let pending {
            return .init(projectID: project.projectID, directory: project.projectID == "global" ? nil : pending.directory, workspaceID: pending.workspaceID)
        }
        if let session {
            return .init(projectID: project.projectID, directory: messageDirectory(session: session, project: project), workspaceID: session.workspaceID)
        }
        return .init(projectID: project.projectID, directory: project.projectID == "global" ? nil : project.directory)
    }

    private func creationRequest(backend: BackendConnection, project: OpenCodeShortcutProjectEntity, title: String?,
                                 model: OpenCodeShortcutModelEntity?, reasoning: String?) async throws -> BackendSessionCreation {
        try await usageGate.ensureCanCreateSession()
        var scope = scope(project: project)
        if backend.sessionSelection != nil, scope.directory == nil {
            let snapshot = try await backend.projects.projectsSnapshot()
            let candidate = project.projectID == "global"
                ? snapshot.defaultDirectory
                : snapshot.projects.first(where: { $0.id == project.projectID })?.worktree
            guard let directory = Self.normalizedDirectory(candidate) else { throw BackendError.invalidScope }
            scope.directory = directory
        }
        var reference = model?.modelReference
        if backend.sessionSelection != nil, reference == nil, Self.normalizedReasoning(reasoning) != nil {
            let catalog = try await backend.models.modelCatalog(scope: scope)
            guard catalog.defaults.count == 1, let value = catalog.defaults.first else { throw BackendError.invalidScope }
            reference = .init(providerID: value.key, modelID: value.value)
        }
        return .init(title: normalizedTitle(title), scope: scope, model: reference, variant: Self.normalizedReasoning(reasoning))
    }

    private func create(_ request: BackendSessionCreation, backend: BackendConnection,
                        pending: inout ShortcutPendingOperationStore.Record) async throws -> OpenCodeSession {
        do { try Task.checkCancellation() } catch {
            try pendingOperations.remove(pending)
            throw error
        }
        guard try pendingOperations.isCurrent(pending) else { throw OpenCodeShortcutError.uncertainCreation }
        let created: OpenCodeSession
        do {
            created = try await backend.sessions.createSession(request)
        } catch let OpenCodeAPIError.httpError(status, body) where (400..<500).contains(status) && status != 408 && status != 409 {
            try pendingOperations.remove(pending)
            throw OpenCodeAPIError.httpError(status, body)
        } catch {
            throw OpenCodeShortcutError.uncertainCreation
        }
        pending.sessionID = created.id
        pending.directory = Self.normalizedDirectory(created.directory) ?? request.scope.directory
        pending.workspaceID = created.workspaceID ?? request.scope.workspaceID
        let saved = try pendingOperations.save(pending)
        await usageGate.recordCreatedSession()
        guard saved else { throw OpenCodeShortcutError.uncertainCreation }
        return created
    }

    private func submit(_ pending: ShortcutPendingOperationStore.Record, text: String, model: OpenCodeModelReference?, variant: String?,
                         backend: BackendConnection, project: OpenCodeShortcutProjectEntity,
                         target: OpenCodeShortcutSessionEntity,
                         reservation: OpenCodeShortcutPromptReservation) async throws {
        guard let sessionID = pending.sessionID, let messageID = pending.messageID else { throw OpenCodeShortcutError.uncertainAdmission }
        guard try pendingOperations.isCurrent(pending), pendingOperations.ownsSession(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
        do {
            _ = try await revalidate(target, backend: backend, project: project)
            try Task.checkCancellation()
        } catch {
            // No prompt reached the transport, so this invocation can safely release its reservation.
            if try pendingOperations.remove(pending) { await usageGate.refundPrompt(reservation) }
            throw error
        }
        guard try pendingOperations.isCurrent(pending), pendingOperations.ownsSession(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
        let admission: BackendAdmission
        do {
            admission = try await backend.chat.submit(.init(sessionID: sessionID, messageID: messageID, text: text,
                scope: scope(project: project, pending: pending), model: model, variant: variant))
        } catch {
            // Once handed to the transport, thrown errors do not prove rejection.
            if pendingOperations.isConfirmed(pending) { return }
            throw OpenCodeShortcutError.uncertainAdmission
        }
        // A read-only reconciler can confirm this input while its POST receipt is delayed.
        // That evidence belongs to this invocation, not to a newer record with the same hash.
        if pendingOperations.isConfirmed(pending) { return }
        switch admission {
        case .accepted(let admittedSession, let admittedMessage) where admittedSession == sessionID && admittedMessage == messageID:
            guard try pendingOperations.remove(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
        case .rejected(let rejectedSession, let rejectedMessage) where rejectedSession == sessionID && rejectedMessage == messageID:
            guard try pendingOperations.remove(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
            await usageGate.refundPrompt(reservation)
            throw OpenCodeShortcutError.rejected
        default:
            throw OpenCodeShortcutError.uncertainAdmission
        }
    }

    private func reconcile(_ pending: ShortcutPendingOperationStore.Record, backend: BackendConnection,
                           project: OpenCodeShortcutProjectEntity) async throws {
        guard try pendingOperations.isCurrent(pending) else { throw OpenCodeShortcutError.uncertainAdmission }
        // Confirmation can unblock the session, but only the active original invocation
        // returns its success. An abandoned operation instead returns recovery to this caller.
        let wasActive = pendingOperations.isActive(pending)
        guard let sessionID = pending.sessionID, let messageID = pending.messageID else { throw OpenCodeShortcutError.uncertainAdmission }
        let scope = scope(project: project, pending: pending)
        if let reader = backend.sessionSelection as? any BackendPendingInputReading,
           let ids = try? await reader.pendingInputIDs(sessionID: sessionID, scope: scope), ids.contains(messageID) {
            guard try pendingOperations.confirm(pending), !wasActive else { throw OpenCodeShortcutError.uncertainAdmission }
            return
        }
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await backend.chat.transcript(sessionID: sessionID, scope: scope, cursor: cursor, limit: 200)
            if page.messages.contains(where: { $0.id == messageID && $0.info.sessionID == sessionID && $0.info.role == "user" }) {
                guard try pendingOperations.confirm(pending), !wasActive else { throw OpenCodeShortcutError.uncertainAdmission }
                return
            }
            cursor = page.olderCursor
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil
        throw OpenCodeShortcutError.uncertainAdmission
    }

    private func checkSessionPending(_ candidate: ShortcutPendingOperationStore.Record, backend: BackendConnection,
                                     project: OpenCodeShortcutProjectEntity) async throws {
        guard let sessionID = candidate.sessionID else { throw OpenCodeShortcutError.uncertainCreation }
        for pending in try pendingOperations.records(serverNamespace: candidate.serverNamespace, sessionID: sessionID)
            where pending.operationID != candidate.operationID {
            try await reconcile(pending, backend: backend, project: project)
            // Resolving a different input is a read-only recovery invocation, never an
            // instruction to automatically change selection and POST the new input too.
            throw OpenCodeShortcutError.uncertainAdmission
        }
    }

    private func operationIdentity(resolved: OpenCodeShortcutResolvedConnection, backend: BackendConnection) -> [String?] {
        if let profile = backend.openCodeCompatibility?.profile {
            // Shipped profile-less records belong to legacy. Preserve that exact hash format
            // for legacy recovery only; negotiation preference is never a persisted owner.
            return profile == .legacy ? [resolved.entity.id] : [resolved.entity.id, "profile", profile.rawValue]
        }
        return [resolved.entity.id, "backend", backend.descriptor.id]
    }

    private func operationHash(_ operation: String, identity: [String?], project: OpenCodeShortcutProjectEntity,
                               selectedSession: OpenCodeShortcutSessionEntity? = nil, title: String? = nil, message: String? = nil,
                               model: OpenCodeShortcutModelEntity? = nil, reasoning: String? = nil) throws -> String {
        let fields: [String?] = [project.projectID, project.directory,
            selectedSession?.sessionID, selectedSession?.directory, selectedSession?.workspaceID, normalizedTitle(title), message,
            model?.providerID ?? selectedSession?.providerID, model?.modelID ?? selectedSession?.modelID,
            Self.normalizedReasoning(reasoning) ?? selectedSession?.reasoningVariant]
        return try ShortcutPendingOperationStore.requestHash([operation] + identity + fields)
    }

    private func validate(project: OpenCodeShortcutProjectEntity, connection: OpenCodeShortcutConnectionEntity) throws {
        guard project.connectionID == connection.id else { throw OpenCodeShortcutError.mismatchedConnection }
    }

    private func validate(session: OpenCodeShortcutSessionEntity, project: OpenCodeShortcutProjectEntity, connection: OpenCodeShortcutConnectionEntity) throws {
        guard session.connectionID == connection.id else { throw OpenCodeShortcutError.mismatchedConnection }
        guard session.projectID == project.projectID else { throw OpenCodeShortcutError.mismatchedProject }
    }

    private func revalidate(_ target: OpenCodeShortcutSessionEntity, backend: BackendConnection,
                            project: OpenCodeShortcutProjectEntity) async throws -> OpenCodeSession {
        let latest = try await backend.sessions.session(id: target.sessionID, scope: scope(project: project, session: target))
        guard latest.id == target.sessionID, latest.isRootSession,
              latest.projectID == project.projectID,
              project.projectID == "global" || Self.normalizedDirectory(target.directory) != nil,
              Self.normalizedDirectory(latest.directory) == Self.normalizedDirectory(target.directory),
              latest.workspaceID == target.workspaceID else { throw OpenCodeShortcutError.mismatchedSession }
        return latest
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
        if project.projectID == "global" { return nil }
        return Self.normalizedDirectory(session.directory)
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
        OpenCodeSavedServer.loadPublicSavedServers()
    }
}
