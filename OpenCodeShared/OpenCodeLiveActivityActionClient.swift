import Foundation

private struct OpenCodeLiveActivityPermissionReplyRequest: Encodable {
    let reply: String
    let message: String?
}

private struct OpenCodeLiveActivityQuestionReplyRequest: Encodable {
    let answers: [[String]]
}

struct OpenCodeLiveActivityActionClient {
    let baseURL: String
    let username: String
    let credentialID: String
    var session: URLSession = .shared

    private let passwordStore = OpenCodeServerPasswordStore()

    func replyToPermission(requestID: String, reply: String, directory: String?, workspaceID: String?) async throws {
        try await sendNoContent(
            path: "/permission/\(requestID)/reply",
            body: OpenCodeLiveActivityPermissionReplyRequest(reply: reply, message: nil),
            directory: directory,
            workspaceID: workspaceID
        )
    }

    func replyToQuestion(requestID: String, answers: [[String]], directory: String?, workspaceID: String?) async throws {
        try await sendNoContent(
            path: "/question/\(requestID)/reply",
            body: OpenCodeLiveActivityQuestionReplyRequest(answers: answers),
            directory: directory,
            workspaceID: workspaceID
        )
    }

    private func sendNoContent<Body: Encodable>(path: String, body: Body, directory: String?, workspaceID: String?) async throws {
        guard let url = requestURL(path: path, directory: directory, workspaceID: workspaceID) else {
            throw OpenCodeLiveActivityActionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try basicAuthHeader(), forHTTPHeaderField: "Authorization")

        if let directoryHeader = encodedDirectoryHeader(directory) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }

        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200 ..< 300 ~= http.statusCode else {
            throw OpenCodeLiveActivityActionError.requestFailed
        }
    }

    private func requestURL(path: String, directory: String?, workspaceID: String?) -> URL? {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        let url = base.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

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
        guard let password = passwordStore.loadPassword(for: credentialID) else {
            throw OpenCodeLiveActivityActionError.missingCredentials
        }
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

enum OpenCodeLiveActivityActionError: Error {
    case invalidURL
    case missingCredentials
    case requestFailed
}
