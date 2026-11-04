import Foundation

struct OpenClientDesktopHandoff: Codable, Equatable, Sendable {
    let requestID: String
    let sessionID: String
    let messageID: String
    let reason: String
    let outcome: String?
    let mode: String?

    var preparesFollowupDraft: Bool { mode == "draft" }

    init?(part: OpenCodePart) {
        guard part.type == "tool", part.tool == "openclient_request_remote_access",
              part.state?.metadata?.renderer == "openclient.remote-desktop",
              let payload = part.state?.metadata?.payload,
              let data = try? JSONEncoder().encode(payload),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              UUID(uuidString: decoded.requestID) != nil,
              part.sessionID == nil || part.sessionID == decoded.sessionID,
              part.messageID == nil || part.messageID == decoded.messageID else { return nil }
        self = decoded
    }
}

struct OpenClientRemoteDesktopClient: Sendable {
    let endpoint: OpenClientBridgeEndpoint
    var session: URLSession = .shared

    func open(token: String) async throws -> URL {
        let request = try request(path: "sessions", token: token)
        let (data, response) = try await session.data(for: request, delegate: DesktopNoRedirects.shared)
        try validate(response)
        struct Ticket: Decodable { let ticket: String }
        let ticket = try JSONDecoder().decode(Ticket.self, from: data).ticket
        return try viewerURL(ticket: ticket)
    }

    func viewerURL(ticket: String) throws -> URL {
        guard ticket.count == 43, ticket.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw DesktopError.unavailable
        }
        var viewer = try components(path: "viewer")
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "ticket", value: ticket),
                               URLQueryItem(name: "language", value: Locale.current.identifier.replacingOccurrences(of: "_", with: "-"))]
        viewer.percentEncodedFragment = fragment.percentEncodedQuery
        guard let url = viewer.url else { throw DesktopError.unavailable }
        return url
    }

    func complete(_ handoff: OpenClientDesktopHandoff, outcome: String, token: String) async throws {
        guard UUID(uuidString: handoff.requestID) != nil, ["done", "cancelled"].contains(outcome) else { throw DesktopError.unavailable }
        var request = try request(path: "handoffs/\(handoff.requestID)", token: token)
        request.httpBody = try JSONEncoder().encode(["sessionID": handoff.sessionID, "messageID": handoff.messageID, "outcome": outcome])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func components(path: String) throws -> URLComponents {
        guard var value = URLComponents(url: endpoint.healthURL, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(value.scheme), value.host != nil,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.path == "/openclient/v1/health" else { throw DesktopError.unavailable }
        value.path = "/openclient/v1/desktop/\(path)"
        return value
    }

    private func request(path: String, token: String) throws -> URLRequest {
        guard let url = try components(path: path).url else { throw DesktopError.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw DesktopError.unavailable }
        if response.statusCode == 401 { throw DesktopError.authentication }
        if response.statusCode == 404 { throw DesktopError.expired }
        guard (200..<300).contains(response.statusCode) else { throw DesktopError.unavailable }
    }

    enum DesktopError: LocalizedError {
        case unavailable, authentication, expired
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Remote desktop is unavailable. Check the host and try again.")
            case .authentication: String(localized: "The remote access token was not accepted.")
            case .expired: String(localized: "This remote desktop request is no longer pending.")
            }
        }
    }
}

/// Uses the current OpenCode client to authorize control operations. Secrets and
/// one-use tickets deliberately bypass transcript/debug response logging.
struct OpenClientDesktopAccess: Sendable {
    let client: OpenCodeAPIClient
    let directory: String?
    let workspaceID: String?
    var session: URLSession = .shared

    struct Ticket: Decodable { let ticket: String; let targetID: String }
    private struct Response<Value: Decodable>: Decodable { let output: Value }

    func open() async throws -> Ticket {
        try await call("open", input: [:])
    }

    func complete(_ handoff: OpenClientDesktopHandoff, outcome: String) async throws {
        struct Completion: Decodable { let completed: Bool }
        let result: Completion = try await call("complete", input: [
            "requestID": handoff.requestID, "sessionID": handoff.sessionID,
            "messageID": handoff.messageID, "outcome": outcome,
        ])
        guard result.completed else { throw OpenClientRemoteDesktopClient.DesktopError.expired }
    }

    private func call<Value: Decodable>(_ method: String, input: [String: String]) async throws -> Value {
        var request = try client.makeRequest(path: "/api/rpc/openclient.desktop/\(method)", method: "POST",
            queryItems: client.v2LocationQueryItems(directory: directory, workspaceID: workspaceID), logRequest: false)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["input": input])
        let (data, response) = try await session.data(for: request, delegate: DesktopNoRedirects.shared)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AccessError.unavailable
        }
        return try JSONDecoder().decode(Response<Value>.self, from: data).output
    }

    enum AccessError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "Could not authorize remote desktop through OpenCode. Check your connection and update the host plugin.")
        }
    }
}

private final class DesktopNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = DesktopNoRedirects()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
