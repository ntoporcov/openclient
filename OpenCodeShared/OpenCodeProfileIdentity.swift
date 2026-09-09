import Foundation

/// Persisted destinations use a resolved profile, never the user's negotiation preference.
enum OpenCodeProfileIdentity: String, Codable, Hashable, Sendable {
    case legacy
    case v2
}

struct OpenCodeWidgetOwner: Hashable, Sendable {
    let profile: OpenCodeProfileIdentity
    let serverID: String

    func entityID(_ components: [String] = []) -> String {
        if profile == .legacy { return ([serverID] + components).joined(separator: "|") }
        // Length framing avoids collisions with separators in raw server/resource identifiers.
        return "v2:" + ([serverID] + components).map { "\($0.utf8.count):\($0)" }.joined()
    }
}

protocol OpenCodeWidgetOwnedSnapshot {
    var profile: OpenCodeProfileIdentity? { get }
    var serverID: String { get }
}

extension OpenCodeWidgetOwnedSnapshot {
    var owner: OpenCodeWidgetOwner {
        OpenCodeWidgetOwner(profile: profile ?? .legacy, serverID: serverID)
    }
}
