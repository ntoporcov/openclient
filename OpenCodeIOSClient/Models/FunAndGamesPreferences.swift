import Foundation

struct FunAndGamesPreferences: Codable, Equatable {
    var showsSection = true
}

struct ServerScopedFunAndGamesPreferences: Codable, Equatable {
    var preferencesByBaseURL: [String: FunAndGamesPreferences] = [:]
}

enum FunAndGamesPreferencesStore {
    private static let storageKey = "funAndGamesPreferences"

    static func load() -> ServerScopedFunAndGamesPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(ServerScopedFunAndGamesPreferences.self, from: data) else {
            return ServerScopedFunAndGamesPreferences()
        }

        return preferences
    }

    static func save(_ preferences: ServerScopedFunAndGamesPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
