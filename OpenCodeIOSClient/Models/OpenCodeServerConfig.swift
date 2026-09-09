import Foundation

enum OpenCodeAPIPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case legacy
    case v2

    var id: Self { self }
}

enum OpenCodeAPIProfile: String, Codable, Sendable {
    case legacy
    case v2
}

enum OpenCodeInsecureConnectionKind: Sendable {
    case localNetwork
    case nonLocal
}

struct OpenCodeServerConfig: Equatable, Codable, Sendable {
    var name: String = ""
    var iconName: String = "server.rack"
    var baseURL: String = ""
    var username: String = "opencode"
    var password: String = ""
    var apiPreference: OpenCodeAPIPreference = .automatic

    init(
        name: String = "",
        iconName: String = "server.rack",
        baseURL: String = "",
        username: String = "opencode",
        password: String = "",
        apiPreference: OpenCodeAPIPreference = .automatic
    ) {
        self.name = name
        self.iconName = iconName
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.apiPreference = apiPreference
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case iconName
        case baseURL
        case username
        case password
        case apiPreference
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? "server.rack"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? "opencode"
        password = try container.decodeIfPresent(String.self, forKey: .password) ?? ""
        apiPreference = try container.decodeIfPresent(OpenCodeAPIPreference.self, forKey: .apiPreference) ?? .automatic
    }

    // Public saved preferences never pin a protocol. Captured API profiles remain separate.
    var publicConnectionConfig: Self {
        var config = self
        config.apiPreference = .automatic
        return config
    }

    var sanitizedBaseURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedIconName: String {
        iconName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var recentServerID: String {
        "\(trimmedBaseURL.lowercased())|\(trimmedUsername.lowercased())"
    }

    var displayHost: String {
        sanitizedBaseURL?.host() ?? trimmedBaseURL
    }

    var displayName: String {
        trimmedName.isEmpty ? displayHost : trimmedName
    }

    var displayIconName: String {
        trimmedIconName.isEmpty ? "server.rack" : trimmedIconName
    }

    var usesInsecureHTTP: Bool {
        sanitizedBaseURL?.scheme?.lowercased() == "http"
    }

    var insecureConnectionKind: OpenCodeInsecureConnectionKind? {
        guard usesInsecureHTTP else { return nil }
        guard let host = sanitizedBaseURL?.host()?.lowercased(), !host.isEmpty else {
            return .nonLocal
        }

        if host == "localhost" || host.hasSuffix(".local") {
            return .localNetwork
        }

        if let ipv4 = IPv4Address(host), ipv4.isLocalNetworkLike {
            return .localNetwork
        }

        return .nonLocal
    }

    var hasCredentials: Bool {
        !trimmedBaseURL.isEmpty && !trimmedUsername.isEmpty
    }

    var hasRequiredConnectionFields: Bool {
        !trimmedName.isEmpty && !trimmedBaseURL.isEmpty && !trimmedIconName.isEmpty
    }

    var connectionValidationMessage: String? {
        switch (trimmedName.isEmpty, trimmedBaseURL.isEmpty, trimmedIconName.isEmpty) {
        case (false, false, false):
            return nil
        case (true, false, false):
            return String(localized: "Add a name before connecting.")
        case (false, true, false):
            return String(localized: "Add a server URL before connecting.")
        case (false, false, true):
            return String(localized: "Add an icon before connecting.")
        case (true, true, false):
            return String(localized: "Add a name and server URL before connecting.")
        case (true, false, true):
            return String(localized: "Add a name and icon before connecting.")
        case (false, true, true):
            return String(localized: "Add a server URL and icon before connecting.")
        case (true, true, true):
            return String(localized: "Add a name, server URL, and icon before connecting.")
        }
    }
}

private struct IPv4Address {
    let octets: [UInt8]

    init?(_ string: String) {
        let parts = string.split(separator: ".")
        guard parts.count == 4 else { return nil }

        var parsed: [UInt8] = []
        parsed.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part) else { return nil }
            parsed.append(value)
        }
        octets = parsed
    }

    var isLocalNetworkLike: Bool {
        switch (octets[0], octets[1]) {
        case (10, _):
            return true
        case (127, _):
            return true
        case (169, 254):
            return true
        case (172, 16 ... 31):
            return true
        case (192, 168):
            return true
        case (100, 64 ... 127):
            return true
        default:
            return false
        }
    }
}
