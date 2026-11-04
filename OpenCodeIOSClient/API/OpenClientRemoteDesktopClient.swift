import Foundation

struct OpenClientDesktopHandoff: Codable, Equatable, Sendable {
    let requestID: String
    let sessionID: String
    let messageID: String
    let reason: String
    let outcome: String?

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
        let (data, response) = try await session.data(for: request)
        try validate(response)
        struct Ticket: Decodable { let ticket: String }
        let ticket = try JSONDecoder().decode(Ticket.self, from: data).ticket
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
