import Foundation

struct OpenCodeLiveActivityOwner: Codable, Hashable, Sendable {
    let profile: OpenCodeProfileIdentity
    let serverID: String

    func session(_ sessionID: String) -> OpenCodeLiveActivityIdentity {
        .init(owner: self, sessionID: sessionID)
    }
}

struct OpenCodeLiveActivityIdentity: Codable, Hashable, Sendable {
    let owner: OpenCodeLiveActivityOwner
    let sessionID: String
}

enum OpenCodeTalkActivityPhase: String, Codable, Hashable {
    case listening
    case working
    case speaking
    case paused
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct OpenCodeChatActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var latestSnippet: String
        var transcriptLines: [OpenCodeChatActivityLine]
        var updatedAt: Date
        var pendingInteractionKind: String?
        var interactionID: String?
        var interactionTitle: String?
        var interactionSummary: String?
        var questionOptionLabels: [String]
        var canReplyToQuestionInline: Bool
    }

    var sessionID: String
    var sessionTitle: String
    var credentialID: String
    var serverBaseURL: String
    var serverUsername: String
    var directory: String?
    var workspaceID: String?
    // Raw storage keeps future profiles decodable but non-actionable. Pre-profile OS
    // attributes belonged exclusively to the legacy API, never to negotiated v2.
    var profile: String? = nil
    var projectID: String? = nil

    // Location is persisted verbatim; legacy global transport is intentionally unscoped.
    var requestDirectory: String? {
        identity?.owner.profile == .legacy && projectID == "global" ? nil : directory
    }

    var identity: OpenCodeLiveActivityIdentity? {
        guard let resolved = OpenCodeProfileIdentity(rawValue: profile ?? "legacy"),
              !credentialID.isEmpty, !sessionID.isEmpty else { return nil }
        return OpenCodeLiveActivityOwner(profile: resolved, serverID: credentialID).session(sessionID)
    }

    func matches(_ identity: OpenCodeLiveActivityIdentity, activityID: String? = nil, actualActivityID: String) -> Bool {
        self.identity == identity && (activityID == nil || activityID == actualActivityID)
    }
}

struct OpenCodeChatActivityLine: Codable, Hashable, Identifiable {
    var id: String
    var role: String
    var text: String
    var isStreaming: Bool
}

struct OpenCodeTalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: OpenCodeTalkActivityPhase
        var sessionID: String?
        var updatedAt: Date
    }

    var activityID: String
    var title: String
    var directory: String?
    var workspaceID: String?
}

#endif

enum OpenCodeChatActivityDeepLink {
    static let scheme = "openclient"
    static let host = "live-activity"

    static func openAppURL(sessionID: String, directory: String? = nil, workspaceID: String? = nil,
                           owner: OpenCodeLiveActivityOwner? = nil, activityID: String? = nil) -> URL? {
        // Unknown restored profiles may launch the app, but must not target a chat.
        if activityID != nil, owner == nil { return URL(string: "openclient://") }
        var components = baseComponents(sessionID: sessionID, directory: directory, workspaceID: workspaceID)
        if let owner {
            components.queryItems = (components.queryItems ?? []) + [
                URLQueryItem(name: "profile", value: owner.profile.rawValue),
                URLQueryItem(name: "serverID", value: owner.serverID)
            ]
        }
        if let activityID {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "activityID", value: activityID)]
        }
        components.queryItems = components.queryItems.map { $0 + [URLQueryItem(name: "action", value: "open")] } ?? [URLQueryItem(name: "action", value: "open")]
        return components.url
    }

    static func permissionURL(sessionID: String, requestID: String, reply: String, directory: String? = nil, workspaceID: String? = nil) -> URL? {
        var components = baseComponents(sessionID: sessionID, directory: directory, workspaceID: workspaceID)
        let items = [
            URLQueryItem(name: "action", value: "permission"),
            URLQueryItem(name: "requestID", value: requestID),
            URLQueryItem(name: "reply", value: reply)
        ]
        components.queryItems = components.queryItems.map { $0 + items } ?? items
        return components.url
    }

    static func questionURL(sessionID: String, requestID: String, answer: String, directory: String? = nil, workspaceID: String? = nil) -> URL? {
        var components = baseComponents(sessionID: sessionID, directory: directory, workspaceID: workspaceID)
        let items = [
            URLQueryItem(name: "action", value: "question"),
            URLQueryItem(name: "requestID", value: requestID),
            URLQueryItem(name: "answer", value: answer)
        ]
        components.queryItems = components.queryItems.map { $0 + items } ?? items
        return components.url
    }

    private static func baseComponents(sessionID: String, directory: String?, workspaceID: String?) -> URLComponents {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/session/\(sessionID)"
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components
    }
}
