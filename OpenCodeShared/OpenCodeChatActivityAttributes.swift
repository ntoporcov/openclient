import Foundation

#if canImport(ActivityKit) && os(iOS)
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
}

struct OpenCodeChatActivityLine: Codable, Hashable, Identifiable {
    var id: String
    var role: String
    var text: String
    var isStreaming: Bool
}

#endif

enum OpenCodeChatActivityDeepLink {
    static let scheme = "openclient"
    static let host = "live-activity"

    static func openAppURL(sessionID: String, directory: String? = nil, workspaceID: String? = nil) -> URL? {
        var components = baseComponents(sessionID: sessionID, directory: directory, workspaceID: workspaceID)
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
