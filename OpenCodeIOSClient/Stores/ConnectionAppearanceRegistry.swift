import Combine
import Foundation

/// Each connection owns a stable observable child. Selecting another connection
/// never mutates a shared "active appearance" object used by existing windows.
@MainActor
final class ConnectionAppearanceRegistry: ObservableObject {
    private struct Archive: Codable {
        var migrationVersion: Int
        var initialAppearance: AppCustomizationPreferences
        var connections: [String: AppCustomizationPreferences]
        var customizedIDs: Set<String>
    }

    private final class Identity {
        var serverID: String
        init(serverID: String) { self.serverID = serverID }
    }

    private struct Entry {
        let identity: Identity
        let store: AppCustomizationStore
        let observation: AnyCancellable
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var archive: Archive
    private var entries: [String: Entry] = [:]
    // Existing windows keep their store when a saved server's address is edited.
    // New lifetimes at the old address are a different connection, not an alias.
    private var connectionStores: [UUID: AppCustomizationStore] = [:]

    init(defaults: UserDefaults, storageKey: String, legacyPreferences: AppCustomizationPreferences) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey), let saved = try? JSONDecoder().decode(Archive.self, from: data) {
            archive = saved
        } else {
            archive = Archive(migrationVersion: 0, initialAppearance: legacyPreferences.appearanceOnly,
                              connections: [:], customizedIDs: [])
        }
    }

    /// Run after saved servers are loaded. Settings and marker are written together;
    /// rerunning after an interrupted launch is safe and never replaces overrides.
    func migrateSavedServers(_ serverIDs: [String]) {
        guard archive.migrationVersion < 1 else { return }
        for id in serverIDs where archive.connections[id] == nil {
            archive.connections[id] = archive.initialAppearance
        }
        archive.migrationVersion = 1
        persist()
    }

    func store(for serverID: String) -> AppCustomizationStore {
        let id = serverID
        if let entry = entries[id] { return entry.store }
        if archive.connections[id] == nil {
            archive.connections[id] = archive.initialAppearance
            persist()
        }
        let identity = Identity(serverID: id)
        let store = AppCustomizationStore(appearance: archive.connections[id] ?? archive.initialAppearance) { [weak self, weak identity] preferences in
            guard let self, let identity else { return }
            self.archive.connections[identity.serverID] = preferences
            self.archive.customizedIDs.insert(identity.serverID)
            self.persist()
        }
        let observation = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        entries[id] = Entry(identity: identity, store: store, observation: observation)
        return store
    }

    func store(for serverID: String, connectionID: UUID) -> AppCustomizationStore {
        if let store = connectionStores[connectionID] { return store }
        let store = store(for: serverID)
        connectionStores[connectionID] = store
        return store
    }

    /// A server URL/username edit changes recentServerID. Keep the appearance and
    /// its observable identity, but never overwrite a customized destination.
    func migrateServerID(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        objectWillChange.send()
        if !archive.customizedIDs.contains(newID) {
            _ = store(for: oldID)
            archive.connections[newID] = archive.connections[oldID] ?? archive.initialAppearance
            if let entry = entries.removeValue(forKey: oldID) {
                let replacedStore = entries[newID]?.store
                entry.identity.serverID = newID
                entries[newID] = entry
                if let replacedStore {
                    for (id, store) in connectionStores where store === replacedStore {
                        connectionStores[id] = entry.store
                    }
                }
            } else {
                entries.removeValue(forKey: newID)
            }
            if archive.customizedIDs.contains(oldID) { archive.customizedIDs.insert(newID) }
        } else {
            entries.removeValue(forKey: oldID)
        }
        archive.connections.removeValue(forKey: oldID)
        archive.customizedIDs.remove(oldID)
        persist()
    }

    func removeServer(_ serverID: String) {
        let id = serverID
        objectWillChange.send()
        entries.removeValue(forKey: id)
        archive.connections.removeValue(forKey: id)
        archive.customizedIDs.remove(id)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
