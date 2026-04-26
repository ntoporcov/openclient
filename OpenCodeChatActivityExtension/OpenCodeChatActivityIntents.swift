#if os(iOS)
import ActivityKit
import AppIntents

struct OpenCodeReplyPermissionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reply to Permission"
    static let openAppWhenRun = false

    @Parameter(title: "Session ID") var sessionID: String
    @Parameter(title: "Request ID") var requestID: String
    @Parameter(title: "Reply") var reply: String
    @Parameter(title: "Credential ID") var credentialID: String
    @Parameter(title: "Base URL") var baseURL: String
    @Parameter(title: "Username") var username: String
    @Parameter(title: "Directory") var directory: String?
    @Parameter(title: "Workspace") var workspaceID: String?

    init() {}

    init(
        sessionID: String,
        requestID: String,
        reply: String,
        credentialID: String,
        baseURL: String,
        username: String,
        directory: String?,
        workspaceID: String?
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reply = reply
        self.credentialID = credentialID
        self.baseURL = baseURL
        self.username = username
        self.directory = directory
        self.workspaceID = workspaceID
    }

    func perform() async throws -> some IntentResult {
        let client = OpenCodeLiveActivityActionClient(baseURL: baseURL, username: username, credentialID: credentialID)
        try await client.replyToPermission(requestID: requestID, reply: reply, directory: directory, workspaceID: workspaceID)
        await clearPendingInteraction(for: sessionID)
        return .result()
    }
}

struct OpenCodeReplyQuestionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reply to Question"
    static let openAppWhenRun = false

    @Parameter(title: "Session ID") var sessionID: String
    @Parameter(title: "Request ID") var requestID: String
    @Parameter(title: "Answer") var answer: String
    @Parameter(title: "Credential ID") var credentialID: String
    @Parameter(title: "Base URL") var baseURL: String
    @Parameter(title: "Username") var username: String
    @Parameter(title: "Directory") var directory: String?
    @Parameter(title: "Workspace") var workspaceID: String?

    init() {}

    init(
        sessionID: String,
        requestID: String,
        answer: String,
        credentialID: String,
        baseURL: String,
        username: String,
        directory: String?,
        workspaceID: String?
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.answer = answer
        self.credentialID = credentialID
        self.baseURL = baseURL
        self.username = username
        self.directory = directory
        self.workspaceID = workspaceID
    }

    func perform() async throws -> some IntentResult {
        let client = OpenCodeLiveActivityActionClient(baseURL: baseURL, username: username, credentialID: credentialID)
        try await client.replyToQuestion(requestID: requestID, answers: [[answer]], directory: directory, workspaceID: workspaceID)
        await clearPendingInteraction(for: sessionID)
        return .result()
    }
}

private func clearPendingInteraction(for sessionID: String) async {
    guard let activity = Activity<OpenCodeChatActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) else {
        return
    }

    var state = activity.content.state
    state.status = "Live"
    state.updatedAt = .now
    state.pendingInteractionKind = nil
    state.interactionID = nil
    state.interactionTitle = nil
    state.interactionSummary = nil
    state.questionOptionLabels = []
    state.canReplyToQuestionInline = false

    await activity.update(
        ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(45)
        )
    )
}

#endif
