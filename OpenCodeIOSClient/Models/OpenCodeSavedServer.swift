import Foundation

struct OpenCodeSavedServer: Equatable, Codable, Sendable {
    var name: String?
    var iconName: String?
    var baseURL: String
    var username: String
    var apiPreference: OpenCodeAPIPreference

    init(
        name: String? = nil,
        iconName: String? = nil,
        baseURL: String,
        username: String,
        apiPreference: OpenCodeAPIPreference = .automatic
    ) {
        self.name = name
        self.iconName = iconName
        self.baseURL = baseURL
        self.username = username
        self.apiPreference = apiPreference
    }

    init(config: OpenCodeServerConfig) {
        self.name = config.trimmedName.isEmpty ? nil : config.trimmedName
        self.iconName = config.trimmedIconName.isEmpty ? nil : config.trimmedIconName
        self.baseURL = config.baseURL
        self.username = config.username
        self.apiPreference = config.apiPreference
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case iconName
        case baseURL
        case username
        case apiPreference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        username = try container.decode(String.self, forKey: .username)
        apiPreference = try container.decodeIfPresent(OpenCodeAPIPreference.self, forKey: .apiPreference) ?? .automatic
    }

    // Used by both app launch and headless Shortcuts, before credentials are hydrated.
    static func loadPublicSavedServers(
        loadPassword: (String) -> String? = { OpenCodeServerPasswordStore().loadPassword(for: $0) },
        savePassword: (String, String) -> Void = { OpenCodeServerPasswordStore().savePassword($0, for: $1) }
    ) -> [OpenCodeSavedServer] {
        migratePublicSavedServers(loadPassword: loadPassword, savePassword: savePassword).servers
    }

    private static func migratePublicSavedServers(
        loadPassword: (String) -> String?,
        savePassword: (String, String) -> Void
    ) -> (servers: [Self], canPersist: Bool) {
        let key = OpenClientSharePayloadStore.recentServerConfigsKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return ([], true) }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return ([], false) }
        var canRewrite = true
        let servers = entries.compactMap { entry -> Self? in
            let raw = entry as? [String: Any]
            guard let raw,
                  let entryData = try? JSONSerialization.data(withJSONObject: raw),
                  let server = try? JSONDecoder().decode(Self.self, from: entryData) else {
                if raw == nil || raw?["password"] != nil { canRewrite = false }
                return nil
            }
            if let value = raw["password"] {
                guard let password = value as? String else {
                    canRewrite = false
                    return server
                }
                // Never discard the only credential copy or replace a saved empty-password marker.
                if loadPassword(server.recentServerID) == nil {
                    savePassword(password, server.recentServerID)
                    if loadPassword(server.recentServerID) != password { canRewrite = false }
                }
            }
            return server
        }
        let normalized = servers.map { server in
            var server = server
            server.apiPreference = server.serverConfig(password: "").publicConnectionConfig.apiPreference
            return server
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let normalizedData = try? encoder.encode(normalized) {
            if canRewrite, normalizedData != data {
                UserDefaults.standard.set(normalizedData, forKey: key)
            }
            OpenClientSharePayloadStore.mirrorRecentServersData(normalizedData)
        }
        return (normalized, canRewrite)
    }

    enum Change {
        case save(OpenCodeServerConfig, replacingServerID: String?)
        case remove(String)
    }

    enum PersistenceError: LocalizedError {
        case credentialsUnavailable

        var errorDescription: String? {
            String(localized: "Unable to safely update saved servers. Unlock your device and try again. If this continues, contact support.")
        }
    }

    static func persistPublicSavedServers(
        _ configs: [OpenCodeServerConfig],
        change: Change,
        loadPassword: (String) -> String? = { OpenCodeServerPasswordStore().loadPassword(for: $0) },
        savePassword: (String, String) -> Void = { OpenCodeServerPasswordStore().savePassword($0, for: $1) },
        deletePassword: (String) -> Void = { OpenCodeServerPasswordStore().deletePassword(for: $0) }
    ) throws -> [OpenCodeServerConfig] {
        // Retry migration before touching the requested credential, recents, or deletion state.
        let migration = migratePublicSavedServers(loadPassword: loadPassword, savePassword: savePassword)
        guard migration.canPersist else { throw PersistenceError.credentialsUnavailable }
        var updated = configs.map { OpenCodeSavedServer(config: $0.publicConnectionConfig) }
        for server in migration.servers where !updated.contains(where: { $0.recentServerID == server.recentServerID }) {
            updated.append(server)
        }
        let removedID: String?
        var credentialToSave: (id: String, password: String)?
        switch change {
        case let .save(config, originalID):
            let id = config.recentServerID
            let isExisting = updated.contains { $0.recentServerID == id }
            // Remembering an existing connection is not an explicit credential edit.
            if originalID == nil, isExisting, loadPassword(id) == nil {
                throw PersistenceError.credentialsUnavailable
            }
            if originalID != nil || !isExisting {
                let password: String
                if let originalID, originalID != id, config.password.isEmpty {
                    guard let originalPassword = loadPassword(originalID) else { throw PersistenceError.credentialsUnavailable }
                    password = originalPassword
                } else {
                    password = config.password
                }
                credentialToSave = (id, password)
            }
            updated.removeAll { $0.recentServerID == id || $0.recentServerID == originalID }
            updated.insert(Self(config: config.publicConnectionConfig), at: 0)
            removedID = originalID == id ? nil : originalID
        case let .remove(id):
            updated.removeAll { $0.recentServerID == id }
            removedID = id
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(updated)
        if let credentialToSave {
            savePassword(credentialToSave.password, credentialToSave.id)
            guard loadPassword(credentialToSave.id) == credentialToSave.password else {
                throw PersistenceError.credentialsUnavailable
            }
        }
        let key = OpenClientSharePayloadStore.recentServerConfigsKey
        if updated.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
            OpenClientSharePayloadStore.mirrorRecentServersData(nil)
        } else {
            UserDefaults.standard.set(data, forKey: key)
            OpenClientSharePayloadStore.mirrorRecentServersData(data)
        }
        if let removedID { deletePassword(removedID) }
        return updated.map { $0.serverConfig(password: loadPassword($0.recentServerID) ?? "") }
    }

    var recentServerID: String {
        OpenCodeServerConfig(baseURL: baseURL, username: username, password: "").recentServerID
    }

    func serverConfig(password: String) -> OpenCodeServerConfig {
        OpenCodeServerConfig(
            name: name ?? "",
            iconName: iconName ?? "",
            baseURL: baseURL,
            username: username,
            password: password,
            apiPreference: apiPreference
        )
    }
}
