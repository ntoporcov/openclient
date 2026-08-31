import Foundation

struct OpenCodeMessagePage: Sendable {
    let messages: [OpenCodeMessageEnvelope]
    let nextCursor: String?
}

struct OpenCodeAPIClient: Sendable {
    let config: OpenCodeServerConfig
    var session: URLSession = .shared

    func health() async throws -> HealthResponse {
        try await send(path: "/global/health", method: "GET")
    }

    func listPTYs(
        directory: String,
        workspaceID: String? = nil
    ) async throws -> [OpenCodePTY] {
        try await send(
            path: "/pty",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func createPTY(
        title: String? = nil,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: OpenCodePTYCreateRequest(title: title),
            directoryHeader: directory
        )
    }

    func getPTY(
        id: String,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty/\(id)",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func updatePTY(
        id: String,
        title: String? = nil,
        rows: Int? = nil,
        columns: Int? = nil,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty/\(id)",
            method: "PUT",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: OpenCodePTYUpdateRequest(title: title, rows: rows, columns: columns),
            directoryHeader: directory
        )
    }

    func deletePTY(
        id: String,
        directory: String,
        workspaceID: String? = nil
    ) async throws {
        try await sendNoContent(
            path: "/pty/\(id)",
            method: "DELETE",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func ptyConnectRequest(
        id: String,
        directory: String,
        workspaceID: String? = nil,
        cursor: Int
    ) throws -> URLRequest {
        var queryItems = scopedQueryItems(directory: directory, workspaceID: workspaceID)
        queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        guard let url = resolvedURL(path: "/pty/\(id)/connect", queryItems: queryItems),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeAPIError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw OpenCodeAPIError.invalidURL
        }
        guard let webSocketURL = components.url else {
            throw OpenCodeAPIError.invalidURL
        }

        var request = URLRequest(url: webSocketURL)
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        if let directoryHeader = explicitDirectoryHeader(directory) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }
        return request
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

    func listSessionStatuses(directory: String? = nil) async throws -> [String: String] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        let response: [String: OpenCodeSessionStatus] = try await send(path: "/session/status", method: "GET", queryItems: queryItems)
        return response.mapValues { $0.type }
    }

    func getSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func deleteSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(
            path: "/session/\(sessionID)",
            method: "DELETE",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func updateSessionTitle(sessionID: String, title: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "PATCH",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: UpdateSessionRequest(title: title),
            directoryHeader: directory
        )
    }

    func archiveSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil, archivedAt: Date = Date()) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "PATCH",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: UpdateSessionRequest(
                title: nil,
                time: UpdateSessionTimeRequest(archived: archivedAt.timeIntervalSince1970 * 1000)
            ),
            directoryHeader: directory
        )
    }

    func createSession(title: String?, directory: String? = nil) async throws -> OpenCodeSession {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session", method: "POST", queryItems: queryItems, body: CreateSessionRequest(title: title))
    }

    func forkSession(sessionID: String, messageID: String?, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(
            path: "/session/\(sessionID)/fork",
            method: "POST",
            queryItems: queryItems,
            body: ForkSessionRequest(messageID: messageID),
            directoryHeader: directory
        )
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

    func updateProject(projectID: String, directory: String? = nil, name: String? = nil, icon: OpenCodeProject.Icon? = nil) async throws -> OpenCodeProject {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/project/\(projectID)", method: "PATCH", queryItems: queryItems, body: UpdateProjectRequest(name: name, icon: icon))
    }

    func listWorktrees(directory: String) async throws -> [String] {
        try await send(path: "/experimental/worktree", method: "GET", queryItems: [URLQueryItem(name: "directory", value: directory)])
    }

    func createWorktree(directory: String, name: String? = nil, startCommand: String? = nil) async throws -> OpenCodeWorktree {
        try await send(
            path: "/experimental/worktree",
            method: "POST",
            queryItems: [URLQueryItem(name: "directory", value: directory)],
            body: WorktreeCreateRequest(name: name, startCommand: startCommand)
        )
    }

    func removeWorktree(rootDirectory: String, worktreeDirectory: String) async throws -> Bool {
        try await send(
            path: "/experimental/worktree",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "directory", value: rootDirectory)],
            body: WorktreeDirectoryRequest(directory: worktreeDirectory)
        )
    }

    func resetWorktree(rootDirectory: String, worktreeDirectory: String) async throws -> Bool {
        try await send(
            path: "/experimental/worktree/reset",
            method: "POST",
            queryItems: [URLQueryItem(name: "directory", value: rootDirectory)],
            body: WorktreeDirectoryRequest(directory: worktreeDirectory)
        )
    }

    func disposeInstance(directory: String? = nil, workspaceID: String? = nil) async throws -> Bool {
        try await send(
            path: "/instance/dispose",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
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

    func readFileContent(directory: String, path: String) async throws -> OpenCodeFileContent {
        return try await send(path: "/file/content", method: "GET", queryItems: [
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "path", value: path),
        ])
    }

    func getVCSInfo(directory: String? = nil) async throws -> OpenCodeVCSInfo {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/vcs", method: "GET", queryItems: queryItems)
    }

    func listFileStatus(directory: String? = nil) async throws -> [OpenCodeVCSFileStatus] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/file/status", method: "GET", queryItems: queryItems)
    }

    func getVCSDiff(mode: OpenCodeVCSDiffMode, directory: String? = nil) async throws -> [OpenCodeVCSFileDiff] {
        var queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        if let directory {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        return try await send(path: "/vcs/diff", method: "GET", queryItems: queryItems)
    }

    func listMessages(sessionID: String, limit: Int? = nil, directory: String? = nil) async throws -> [OpenCodeMessageEnvelope] {
        try await listMessagePage(sessionID: sessionID, limit: limit, directory: directory).messages
    }

    func listMessagePage(
        sessionID: String,
        limit: Int? = nil,
        before: String? = nil,
        directory: String? = nil
    ) async throws -> OpenCodeMessagePage {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        let request = try makeRequest(
            path: "/session/\(sessionID)/message",
            method: "GET",
            queryItems: queryItems,
            directoryHeader: directory
        )
        let (data, response) = try await session.data(for: request)
        let messages: [OpenCodeMessageEnvelope] = try decode(data: data, response: response)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        return OpenCodeMessagePage(
            messages: messages,
            nextCursor: http.value(forHTTPHeaderField: "X-Next-Cursor")
        )
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

    func listCommands(directory: String? = nil) async throws -> [OpenCodeCommand] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/command", method: "GET", queryItems: queryItems)
    }

    func listProviders(directory: String? = nil) async throws -> [OpenCodeProvider] {
        try await providerState(directory: directory).all
    }

    func providerDefaults(directory: String? = nil) async throws -> [String: String] {
        try await providerState(directory: directory).default
    }

    func providerConfiguration(directory: String? = nil) async throws -> OpenCodeProvidersResponse {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/config/providers", method: "GET", queryItems: queryItems)
    }

    func providerState(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeProviderListResponse {
        try await send(path: "/provider", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func providerAuthMethods(directory: String? = nil, workspaceID: String? = nil) async throws -> [String: [OpenCodeProviderAuthMethod]] {
        try await send(path: "/provider/auth", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func setProviderAPIKey(providerID: String, key: String) async throws {
        _ = try await send(path: "/auth/\(encodedPathComponent(providerID))", method: "PUT", body: SetProviderAuthRequest(type: "api", key: key)) as Bool
    }

    func authorizeProviderOAuth(providerID: String, method: Int, inputs: [String: String]? = nil, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeProviderAuthAuthorization? {
        try await send(
            path: "/provider/\(encodedPathComponent(providerID))/oauth/authorize",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: ProviderOAuthAuthorizeRequest(method: method, inputs: inputs),
            directoryHeader: directory
        )
    }

    func completeProviderOAuth(providerID: String, method: Int, code: String? = nil, directory: String? = nil, workspaceID: String? = nil) async throws -> Bool {
        try await send(
            path: "/provider/\(encodedPathComponent(providerID))/oauth/callback",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: ProviderOAuthCallbackRequest(method: method, code: code),
            directoryHeader: directory
        )
    }

    func removeProviderAuth(providerID: String) async throws {
        _ = try await send(path: "/auth/\(encodedPathComponent(providerID))", method: "DELETE") as Bool
    }

    func updateGlobalConfig(_ patch: OpenCodeGlobalConfigPatch) async throws {
        _ = try await send(path: "/global/config", method: "PATCH", body: patch) as OpenCodeJSONValue
    }

    func globalConfig() async throws -> OpenCodeJSONValue {
        try await send(path: "/global/config", method: "GET")
    }

    func resolvedConfig(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeResolvedConfig {
        try await send(
            path: "/config",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func disposeGlobal() async throws {
        try await sendNoContent(path: "/global/dispose", method: "POST")
    }

    func listMCPStatus(directory: String? = nil, workspaceID: String? = nil) async throws -> [String: OpenCodeMCPStatus] {
        try await send(path: "/mcp", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func connectMCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/mcp/\(encodedPathComponent(name))/connect", method: "POST", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func disconnectMCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/mcp/\(encodedPathComponent(name))/disconnect", method: "POST", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func listPermissions(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodePermission] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(path: "/permission", method: "GET", queryItems: queryItems)
    }

    func listQuestions(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeQuestionRequest] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(path: "/question", method: "GET", queryItems: queryItems)
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

    func replyToPermission(requestID: String, reply: String, message: String? = nil, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/permission/\(requestID)/reply",
            method: "POST",
            queryItems: queryItems,
            body: OpenCodePermissionReplyRequest(reply: reply, message: message),
            directoryHeader: directory
        )
    }

    func replyToQuestion(requestID: String, answers: [[String]], directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/question/\(requestID)/reply",
            method: "POST",
            queryItems: queryItems,
            body: OpenCodeQuestionReplyRequest(answers: answers),
            directoryHeader: directory
        )
    }

    func rejectQuestion(requestID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/question/\(requestID)/reject",
            method: "POST",
            queryItems: queryItems,
            directoryHeader: explicitDirectoryHeader(directory)
        )
    }

    func sendMessage(
        sessionID: String,
        text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        messageID: String? = nil,
        partID: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OpenCodeMessageEnvelope {
        let payload = makePromptRequest(text: text, agentMentions: agentMentions, attachments: attachments, messageID: messageID, partID: partID, model: model, agent: agent, variant: variant)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session/\(sessionID)/message", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func sendMessageAsync(
        sessionID: String,
        text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        messageID: String? = nil,
        partID: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let payload = makePromptRequest(text: text, agentMentions: agentMentions, attachments: attachments, messageID: messageID, partID: partID, model: model, agent: agent, variant: variant)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/prompt_async", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String = "",
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let payload = SendCommandRequest(
            agent: agent,
            model: model.map { "\($0.providerID)/\($0.modelID)" },
            arguments: arguments,
            command: command,
            variant: variant,
            parts: attachments.map(makeFilePart)
        )
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/command", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func summarizeSession(
        sessionID: String,
        directory: String? = nil,
        model: OpenCodeModelReference,
        auto: Bool = false
    ) async throws {
        let payload = SummarizeSessionRequest(providerID: model.providerID, modelID: model.modelID, auto: auto)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/summarize", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func abortSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        try await sendNoContent(path: "/session/\(sessionID)/abort", method: "POST", queryItems: queryItems, directoryHeader: directory)
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

    private func send<T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<T: Decodable>(path: String, method: String, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, body: Body) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, body: Body, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body, directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body, directoryHeader: directoryHeader)
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
        debugLog(response: http, for: request, body: nil)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, body: Body, directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body, directoryHeader: directoryHeader)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: request, body: nil)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body, directoryHeader: directoryHeader)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: request, body: nil)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func sendNoContent(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: request, body: nil)
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
        debugLog(response: http, for: request, body: nil)
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
        debugLog(response: http, for: request, body: nil)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, "")
        }
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String? = nil, logRequest: Bool = true) throws -> URLRequest {
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
        if let directoryHeader = explicitDirectoryHeader(directoryHeader) ?? encodedDirectoryHeader(from: queryItems) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }

        if logRequest {
            debugLog(request: request)
        }

        return request
    }

    private func makeRequest<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String? = nil) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader, logRequest: false)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        debugLog(request: request)

        return request
    }

    private func decode<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: nil, body: data)
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeAPIError.httpError(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard let repairedData = Self.repairingInvalidUnicodeEscapes(in: data) else {
                throw error
            }
            return try JSONDecoder().decode(T.self, from: repairedData)
        }
    }

    private static func repairingInvalidUnicodeEscapes(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("\\u") else { return nil }

        var repaired = ""
        repaired.reserveCapacity(text.count)
        var index = text.startIndex
        var changed = false

        while index < text.endIndex {
            guard isActiveUnicodeEscapeStart(at: index, in: text),
                  let escape = unicodeEscape(at: index, in: text) else {
                repaired.append(text[index])
                index = text.index(after: index)
                continue
            }

            if isHighSurrogate(escape.value) {
                let nextIndex = escape.endIndex
                if let nextEscape = unicodeEscape(at: nextIndex, in: text), isLowSurrogate(nextEscape.value) {
                    repaired.append(contentsOf: text[index ..< nextEscape.endIndex])
                    index = nextEscape.endIndex
                } else {
                    repaired.append("\\uFFFD")
                    index = escape.endIndex
                    changed = true
                }
                continue
            }

            if isLowSurrogate(escape.value) {
                repaired.append("\\uFFFD")
                index = escape.endIndex
                changed = true
                continue
            }

            repaired.append(contentsOf: text[index ..< escape.endIndex])
            index = escape.endIndex
        }

        guard changed else { return nil }
        return repaired.data(using: .utf8)
    }

    private static func isActiveUnicodeEscapeStart(at index: String.Index, in text: String) -> Bool {
        guard text[index] == "\\" else { return false }
        let next = text.index(after: index)
        guard next < text.endIndex, text[next] == "u" else { return false }

        var backslashCount = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }

        return backslashCount.isMultiple(of: 2)
    }

    private static func unicodeEscape(at index: String.Index, in text: String) -> (value: Int, endIndex: String.Index)? {
        guard index < text.endIndex, text[index] == "\\" else { return nil }
        let uIndex = text.index(after: index)
        guard uIndex < text.endIndex, text[uIndex] == "u" else { return nil }

        var cursor = text.index(after: uIndex)
        var value = 0
        for _ in 0 ..< 4 {
            guard cursor < text.endIndex, let digit = text[cursor].hexDigitValue else { return nil }
            value = value * 16 + digit
            cursor = text.index(after: cursor)
        }
        return (value, cursor)
    }

    private static func isHighSurrogate(_ value: Int) -> Bool {
        (0xD800 ... 0xDBFF).contains(value)
    }

    private static func isLowSurrogate(_ value: Int) -> Bool {
        (0xDC00 ... 0xDFFF).contains(value)
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

    private func debugLog(request: URLRequest) {
        #if DEBUG
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers["Authorization"] != nil {
            headers["Authorization"] = "<redacted>"
        }

        let sortedHeaders = headers.keys.sorted().map { key in
            "\(key)=\(headers[key] ?? "")"
        }.joined(separator: ", ")

        let body = Self.debugBodyDescription(request.httpBody)

        print("[OpenCodeRequest] method=\(request.httpMethod ?? "na") url=\(request.url?.absoluteString ?? "nil") headers=[\(sortedHeaders)] body=\(body)")
        #endif
    }

    private func debugLog(response: HTTPURLResponse, for request: URLRequest?, body: Data?) {
        #if DEBUG
        let responseBody = Self.debugBodyDescription(body)

        print(
            "[OpenCodeResponse] status=\(response.statusCode) url=\(request?.url?.absoluteString ?? response.url?.absoluteString ?? "nil") body=\(responseBody)"
        )
        #endif
    }

    private static func debugBodyDescription(_ body: Data?) -> String {
        let limit = 2_048
        guard let body, !body.isEmpty else { return "<empty>" }
        guard let text = String(data: body, encoding: .utf8) else {
            return "<\(body.count) bytes binary>"
        }
        guard text.count > limit else { return text }
        return "\(String(text.prefix(limit)))... <truncated \(body.count) bytes>"
    }

    private func encodedDirectoryHeader(from queryItems: [URLQueryItem]) -> String? {
        guard let directory = queryItems.first(where: { $0.name == "directory" })?.value,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
    }

    private func explicitDirectoryHeader(_ directory: String?) -> String? {
        guard let directory,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
    }

    private func scopedQueryItems(directory: String?, workspaceID: String?) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return queryItems
    }

    private func encodedPathComponent(_ value: String) -> String {
        value
    }

    private func makePromptRequest(
        text: String,
        agentMentions: [OpenCodeAgentMention],
        attachments: [OpenCodeComposerAttachment],
        messageID: String?,
        partID: String?,
        model: OpenCodeModelReference?,
        agent: String?,
        variant: String?
    ) -> SendMessageRequest {
        var parts: [SendMessagePart] = []
        if !text.isEmpty || attachments.isEmpty {
            parts.append(SendMessagePart(
                id: partID,
                type: "text",
                text: text,
                name: nil,
                mime: nil,
                filename: nil,
                url: nil,
                source: nil,
                synthetic: nil,
                metadata: nil
            ))
        }
        parts.append(contentsOf: agentMentions.map(makeAgentPart))
        parts.append(contentsOf: attachments.map(makeFilePart))
        return SendMessageRequest(
            messageID: messageID,
            model: model,
            agent: agent,
            variant: variant,
            parts: parts
        )
    }

    private func makeFilePart(_ attachment: OpenCodeComposerAttachment) -> SendMessagePart {
        SendMessagePart(
            id: attachment.id,
            type: "file",
            text: nil,
            name: nil,
            mime: attachment.mime,
            filename: attachment.filename,
            url: attachment.dataURL,
            source: nil,
            synthetic: nil,
            metadata: nil
        )
    }

    private func makeAgentPart(_ mention: OpenCodeAgentMention) -> SendMessagePart {
        SendMessagePart(
            id: OpenCodeIdentifier.part(),
            type: "agent",
            text: nil,
            name: mention.name,
            mime: nil,
            filename: nil,
            url: nil,
            source: SendMessagePartSource(value: mention.content, start: mention.start, end: mention.end),
            synthetic: nil,
            metadata: nil
        )
    }
}

private struct UpdateProjectRequest: Encodable {
    let name: String?
    let icon: OpenCodeProject.Icon?
}

private struct SetProviderAuthRequest: Encodable {
    let type: String
    let key: String
}

private struct ProviderOAuthAuthorizeRequest: Encodable {
    let method: Int
    let inputs: [String: String]?
}

private struct ProviderOAuthCallbackRequest: Encodable {
    let method: Int
    let code: String?
}

private struct WorktreeCreateRequest: Encodable {
    let name: String?
    let startCommand: String?
}

private struct WorktreeDirectoryRequest: Encodable {
    let directory: String
}

private struct SendCommandRequest: Encodable {
    let agent: String?
    let model: String?
    let arguments: String
    let command: String
    let variant: String?
    let parts: [SendMessagePart]
}

private struct SummarizeSessionRequest: Encodable {
    let providerID: String
    let modelID: String
    let auto: Bool
}
