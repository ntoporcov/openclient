import Combine
import Foundation

@MainActor
final class PinnedCommandStore: ObservableObject {
    static let defaultStorageKey = "pinnedCommandsByScope"

    @Published private(set) var pinnedNamesByScope: [String: [String]]

    private let storageKey: String
    private let userDefaults: UserDefaults

    init(storageKey: String = PinnedCommandStore.defaultStorageKey, userDefaults: UserDefaults = .standard) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        self.pinnedNamesByScope = Self.load(storageKey: storageKey, userDefaults: userDefaults)
    }

    func pinnedNames(for scopeKey: String) -> [String] {
        pinnedNamesByScope[scopeKey] ?? []
    }

    func pinnedCommands(from commands: [OpenCodeCommand], scopeKey: String) -> [OpenCodeCommand] {
        let commandsByName = Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0) })
        return pinnedNames(for: scopeKey).compactMap { commandsByName[$0] }
    }

    func isPinned(_ command: OpenCodeCommand, scopeKey: String) -> Bool {
        pinnedNames(for: scopeKey).contains(command.name)
    }

    func pin(_ command: OpenCodeCommand, scopeKey: String) {
        var names = pinnedNames(for: scopeKey)
        guard !names.contains(command.name) else { return }
        names.append(command.name)
        setPinnedNames(names, scopeKey: scopeKey)
    }

    func unpin(_ command: OpenCodeCommand, scopeKey: String) {
        setPinnedNames(pinnedNames(for: scopeKey).filter { $0 != command.name }, scopeKey: scopeKey)
    }

    func toggle(_ command: OpenCodeCommand, scopeKey: String) {
        if isPinned(command, scopeKey: scopeKey) {
            unpin(command, scopeKey: scopeKey)
        } else {
            pin(command, scopeKey: scopeKey)
        }
    }

    private func setPinnedNames(_ names: [String], scopeKey: String) {
        var deduplicated: [String] = []
        var seen = Set<String>()

        for name in names where seen.insert(name).inserted {
            deduplicated.append(name)
        }

        if deduplicated.isEmpty {
            pinnedNamesByScope[scopeKey] = nil
        } else {
            pinnedNamesByScope[scopeKey] = deduplicated
        }

        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(pinnedNamesByScope) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private static func load(storageKey: String, userDefaults: UserDefaults) -> [String: [String]] {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }

        return decoded
    }
}
