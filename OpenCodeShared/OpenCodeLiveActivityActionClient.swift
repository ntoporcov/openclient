import Foundation

private struct OpenCodeLiveActivityPermissionReplyRequest: Encodable {
    let reply: String
    let message: String?
}

private struct OpenCodeLiveActivityQuestionReplyRequest: Encodable {
    let answers: [[String]]
}

struct OpenCodeLiveActivityActionClient: Sendable {
    let baseURL: String
    let username: String
    let credentialID: String
    var session: URLSession = .shared
    var profile: OpenCodeProfileIdentity = .legacy
    var sessionID: String? = nil
    var loadPassword: @Sendable (String) -> String? = { OpenCodeServerPasswordStore().loadPassword(for: $0) }

    func replyToPermission(requestID: String, reply: String, directory: String?, workspaceID: String?, message: String? = nil) async throws {
        let request = try permissionRequest(requestID: requestID, reply: reply, directory: directory, workspaceID: workspaceID, message: message)
        try await send(request)
    }

    func permissionRequest(requestID: String, reply: String, directory: String?, workspaceID: String?, message: String? = nil) throws -> URLRequest {
        guard ["once", "always", "reject"].contains(reply) else { throw OpenCodeLiveActivityActionError.requestFailed }
        let path: String
        switch profile {
        case .legacy:
            path = "/permission/\(try pathComponent(requestID))/reply"
        case .v2:
            guard let sessionID else { throw OpenCodeLiveActivityActionError.requestFailed }
            path = "/api/session/\(try pathComponent(sessionID))/permission/\(try pathComponent(requestID))/reply"
        }
        return try makeRequest(path: path, body: OpenCodeLiveActivityPermissionReplyRequest(reply: reply, message: message), directory: directory, workspaceID: workspaceID)
    }

    func replyToQuestion(requestID: String, answers: [[String]], directory: String?, workspaceID: String?) async throws {
        try await send(questionRequest(requestID: requestID, answers: answers, directory: directory, workspaceID: workspaceID))
    }

    func questionRequest(requestID: String, answers: [[String]], directory: String?, workspaceID: String?) throws -> URLRequest {
        // V2 forms require a typed field-keyed contract, not legacy question answers.
        guard profile == .legacy else { throw OpenCodeLiveActivityActionError.requestFailed }
        return try makeRequest(
            path: "/question/\(try pathComponent(requestID))/reply",
            body: OpenCodeLiveActivityQuestionReplyRequest(answers: answers),
            directory: directory,
            workspaceID: workspaceID
        )
    }

    private func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..",
              let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")) else {
            throw OpenCodeLiveActivityActionError.invalidURL
        }
        return encoded
    }

    private func makeRequest<Body: Encodable>(path: String, body: Body, directory: String?, workspaceID: String?) throws -> URLRequest {
        guard let url = requestURL(path: path, directory: directory, workspaceID: workspaceID) else {
            throw OpenCodeLiveActivityActionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let directoryHeader = encodedDirectoryHeader(directory) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }

        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func send(_ unsignedRequest: URLRequest) async throws {
        var request = unsignedRequest
        request.setValue(try basicAuthHeader(), forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw OpenCodeLiveActivityActionError.requestFailed
        }
    }

    private func requestURL(path: String, directory: String?, workspaceID: String?) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else {
            return nil
        }

        components.percentEncodedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? path : "/" + components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path
        components.fragment = nil

        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }

    private func encodedDirectoryHeader(_ directory: String?) -> String? {
        guard let directory,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
    }

    private func basicAuthHeader() throws -> String {
        guard let password = loadPassword(credentialID) else {
            throw OpenCodeLiveActivityActionError.missingCredentials
        }
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

enum OpenCodeLiveActivityActionError: LocalizedError {
    case invalidURL
    case missingCredentials
    case requestFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The OpenClient server URL is invalid.")
        case .missingCredentials:
            return String(localized: "The saved OpenClient credentials are unavailable.")
        case .requestFailed:
            return String(localized: "OpenClient could not send the Live Activity response.")
        }
    }
}
