import Foundation

struct OpenCodeAPIClient {
    let config: OpenCodeServerConfig
    var session: URLSession = .shared

    func health() async throws -> HealthResponse {
        try await send(path: "/global/health", method: "GET")
    }

    func listSessions(directory: String? = nil, roots: Bool? = nil, limit: Int? = nil) async throws -> [OpenCodeSession] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let roots {
            queryItems.append(URLQueryItem(name: "roots", value: roots ? "true" : "false"))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await send(path: "/session", method: "GET", queryItems: queryItems)
    }

    func deleteSession(sessionID: String) async throws {
        try await sendNoContent(path: "/session/\(sessionID)", method: "DELETE")
    }

    func createSession(title: String?, directory: String? = nil) async throws -> OpenCodeSession {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session", method: "POST", queryItems: queryItems, body: CreateSessionRequest(title: title))
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await send(path: "/project", method: "GET")
    }

    func currentProject() async throws -> OpenCodeProject {
        try await send(path: "/project/current", method: "GET")
    }

    func currentProject(directory: String) async throws -> OpenCodeProject {
        try await send(path: "/project/current", method: "GET", queryItems: [URLQueryItem(name: "directory", value: directory)])
    }

    func updateProject(projectID: String, directory: String? = nil, name: String? = nil) async throws -> OpenCodeProject {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/project/\(projectID)", method: "PATCH", queryItems: queryItems, body: UpdateProjectRequest(name: name))
    }

    func findFiles(query: String, directory: String) async throws -> [String] {
        return try await send(path: "/find/file", method: "GET", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "directory", value: directory),
        ])
    }

    func listFiles(directory: String, path: String = "") async throws -> [OpenCodeFileNode] {
        return try await send(path: "/file", method: "GET", queryItems: [
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "path", value: path),
        ])
    }

    func listMessages(sessionID: String, limit: Int? = nil) async throws -> [OpenCodeMessageEnvelope] {
        var path = "/session/\(sessionID)/message"
        if let limit {
            path += "?limit=\(limit)"
        }
        return try await send(path: path, method: "GET")
    }

    func getMessage(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        try await send(path: "/session/\(sessionID)/message/\(messageID)", method: "GET")
    }

    func getTodos(sessionID: String) async throws -> [OpenCodeTodo] {
        try await send(path: "/session/\(sessionID)/todo", method: "GET")
    }

    func listAgents(directory: String? = nil) async throws -> [OpenCodeAgent] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/agent", method: "GET", queryItems: queryItems)
    }

    func listProviders(directory: String? = nil) async throws -> [OpenCodeProvider] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        let response: OpenCodeProvidersResponse = try await send(path: "/config/providers", method: "GET", queryItems: queryItems)
        return response.providers
    }

    func providerDefaults(directory: String? = nil) async throws -> [String: String] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        let response: OpenCodeProvidersResponse = try await send(path: "/config/providers", method: "GET", queryItems: queryItems)
        return response.default ?? [:]
    }

    func listPermissions() async throws -> [OpenCodePermission] {
        try await send(path: "/permission", method: "GET")
    }

    func listQuestions() async throws -> [OpenCodeQuestionRequest] {
        try await send(path: "/question", method: "GET")
    }

    func getNextControlRequest(directory: String?) async throws -> OpenCodeControlRequest {
        var path = "/tui/control/next"
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path += "?directory=\(directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory)"
        }
        return try await send(path: path, method: "GET")
    }

    func respondToPermission(sessionID: String, permissionID: String, response: String, remember: Bool = false) async throws {
        struct PermissionResponse: Encodable {
            let response: String
            let remember: Bool
        }

        try await sendNoContent(path: "/session/\(sessionID)/permissions/\(permissionID)", method: "POST", body: PermissionResponse(response: response, remember: remember))
    }

    func replyToPermission(requestID: String, reply: String, message: String? = nil) async throws {
        try await sendNoContent(path: "/permission/\(requestID)/reply", method: "POST", body: OpenCodePermissionReplyRequest(reply: reply, message: message))
    }

    func replyToQuestion(requestID: String, answers: [[String]]) async throws {
        try await sendNoContent(path: "/question/\(requestID)/reply", method: "POST", body: OpenCodeQuestionReplyRequest(answers: answers))
    }

    func rejectQuestion(requestID: String) async throws {
        try await sendNoContent(path: "/question/\(requestID)/reject", method: "POST")
    }

    func sendMessage(
        sessionID: String,
        text: String,
        directory: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OpenCodeMessageEnvelope {
        let payload = SendMessageRequest(model: model, agent: agent, variant: variant, parts: [SendMessagePart(type: "text", text: text)])
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session/\(sessionID)/message", method: "POST", queryItems: queryItems, body: payload)
    }

    func sendMessageAsync(
        sessionID: String,
        text: String,
        directory: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let payload = SendMessageRequest(model: model, agent: agent, variant: variant, parts: [SendMessagePart(type: "text", text: text)])
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/prompt_async", method: "POST", queryItems: queryItems, body: payload)
    }

    func eventURLs(directory: String?) throws -> [URL] {
        var urls: [URL] = []

        if var eventURL = resolvedURL(path: "/event", queryItems: []),
           let directory,
           !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var components = URLComponents(url: eventURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
            if let scopedURL = components?.url {
                eventURL = scopedURL
            }
            urls.append(eventURL)
        } else if let eventURL = resolvedURL(path: "/event", queryItems: []) {
            urls.append(eventURL)
        }

        if let globalURL = resolvedURL(path: "/global/event", queryItems: []) {
            urls.append(globalURL)
        }

        guard !urls.isEmpty else {
            throw OpenCodeAPIError.invalidURL
        }
        return urls
    }

    func globalEventURL() -> URL? {
        resolvedURL(path: "/global/event", queryItems: [])
    }

    private func send<T: Decodable>(path: String, method: String) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [])
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<T: Decodable>(path: String, method: String, queryItems: [URLQueryItem]) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, body: Body) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, body: Body) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func sendNoContent(path: String, method: String) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard let url = resolvedURL(path: path, queryItems: queryItems) else {
            throw OpenCodeAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeRequest<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func decode<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeAPIError.httpError(http.statusCode, body)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func resolvedURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard let baseURL = config.sanitizedBaseURL else { return nil }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !queryItems.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url
    }

    private func basicAuthHeader() -> String {
        let credentials = "\(config.username):\(config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}

private struct UpdateProjectRequest: Encodable {
    let name: String?
}
