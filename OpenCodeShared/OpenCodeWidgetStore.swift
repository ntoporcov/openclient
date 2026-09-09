import Foundation

struct OpenCodeWidgetStore {
    static let appGroupIdentifier = "group.com.ntoporcov.openclient"

    private let storageKey = "OpenCodeWidgetSnapshotPayload"
    private let maxPayloadBytes = 1_000_000
    private let maxModelsPerServer = 120


    func load() -> OpenCodeWidgetSnapshotPayload {
        guard let data = defaults.data(forKey: storageKey),
              data.count <= maxPayloadBytes,
              let payload = try? JSONDecoder().decode(OpenCodeWidgetSnapshotPayload.self, from: data) else {
            return .empty
        }
        return payload
    }

    func save(_ payload: OpenCodeWidgetSnapshotPayload) {
        var payload = payload
        payload.models = limitedModelSnapshots(payload.models)
        guard var data = try? JSONEncoder().encode(payload) else { return }
        if data.count > maxPayloadBytes {
            payload.models = []
            guard let reducedData = try? JSONEncoder().encode(payload), reducedData.count <= maxPayloadBytes else { return }
            data = reducedData
        }
        defaults.set(data, forKey: storageKey)
    }

    func updatingServer(
        _ server: OpenCodeWidgetServerSnapshot,
        projects: [OpenCodeWidgetProjectSnapshot],
        sessions: [OpenCodeWidgetSessionSnapshot],
        replacingSessionIDs: Set<String>,
        commands: [OpenCodeWidgetCommandSnapshot] = [],
        replacingCommandProjectIDs: Set<String> = [],
        models: [OpenCodeWidgetModelSnapshot] = [],
        projectsAreAuthoritative: Bool = true,
        modelsAreAuthoritative: Bool = false
    ) {
        var payload = load()
        payload.servers.removeAll { $0.owner == server.owner }
        payload.servers = payload.servers.map { existing in
            OpenCodeWidgetServerSnapshot(
                id: existing.id,
                displayName: existing.displayName,
                baseURL: existing.baseURL,
                username: existing.username,
                generatedAt: existing.generatedAt,
                isLastConnected: false,
                profile: existing.profile,
                supportsNewSession: existing.supportsNewSession,
                supportsCommands: existing.supportsCommands
            )
        }
        payload.servers.insert(server, at: 0)
        if projectsAreAuthoritative {
            payload.projects.removeAll { $0.owner == server.owner }
            payload.projects.append(contentsOf: projects.filter { $0.owner == server.owner })
        }
        payload.sessions.removeAll { $0.owner == server.owner && replacingSessionIDs.contains($0.id) }
        payload.sessions.append(contentsOf: sessions.filter { $0.owner == server.owner })
        if !replacingCommandProjectIDs.isEmpty {
            payload.commands.removeAll { command in
                command.owner == server.owner && replacingCommandProjectIDs.contains(command.projectID)
            }
            payload.commands.append(contentsOf: commands.filter { $0.owner == server.owner })
        }
        if modelsAreAuthoritative || !models.isEmpty {
            payload.models.removeAll { $0.owner == server.owner }
            payload.models.append(contentsOf: models.filter { $0.owner == server.owner })
        }
        if projectsAreAuthoritative {
            let projectIDs = Set(payload.projects.filter { $0.owner == server.owner }.map(\.id))
            payload.sessions.removeAll { $0.owner == server.owner && !projectIDs.contains($0.projectID) }
            payload.commands.removeAll { $0.owner == server.owner && !projectIDs.contains($0.projectID) }
        }
        payload.generatedAt = Date()
        save(payload)
    }

    private func limitedModelSnapshots(_ models: [OpenCodeWidgetModelSnapshot]) -> [OpenCodeWidgetModelSnapshot] {
        var countsByServerID: [OpenCodeWidgetOwner: Int] = [:]
        return models.filter { model in
            let count = countsByServerID[model.owner, default: 0]
            guard count < maxModelsPerServer else { return false }
            countsByServerID[model.owner] = count + 1
            return true
        }
    }

    func removeSession(serverID: String, sessionID: String) {
        removeSession(owner: .init(profile: .legacy, serverID: serverID), sessionID: sessionID)
    }

    func removeSession(owner: OpenCodeWidgetOwner, sessionID: String) {
        var payload = load()
        payload.sessions.removeAll { $0.owner == owner && $0.id == sessionID }
        payload.generatedAt = Date()
        save(payload)
    }

    private var defaults: UserDefaults {
        UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
    }
}
