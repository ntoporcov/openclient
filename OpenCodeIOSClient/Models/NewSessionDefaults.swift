import Foundation

struct NewSessionDefaults: Codable, Equatable {
    var agentName: String?
    var providerID: String?
    var modelID: String?
    var reasoningVariant: String?
}

struct ServerScopedComposerPreferences: Codable, Equatable {
    var defaultsByBaseURL: [String: NewSessionDefaults] = [:]
}

enum NewSessionDefaultsStore {
    private static let storageKey = "newSessionDefaults"

    static func load() -> ServerScopedComposerPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let preferences = try? JSONDecoder().decode(ServerScopedComposerPreferences.self, from: data) else {
            return ServerScopedComposerPreferences()
        }

        return preferences
    }

    static func save(_ preferences: ServerScopedComposerPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func normalizedBaseURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return trimmed.lowercased()
        }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""

        if let port = components.port,
           (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }

        return components.string ?? "\(scheme)://\(host)"
    }
}
