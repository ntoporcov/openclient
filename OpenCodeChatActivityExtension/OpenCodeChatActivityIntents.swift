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
    @Parameter(title: "Activity ID") var activityID: String?
    @Parameter(title: "API Profile") var profile: String?

    init() {}

    init(
        sessionID: String,
        requestID: String,
        reply: String,
        credentialID: String,
        baseURL: String,
        username: String,
        directory: String?,
        workspaceID: String?,
        activityID: String? = nil,
        profile: String? = nil
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reply = reply
        self.credentialID = credentialID
        self.baseURL = baseURL
        self.username = username
        self.directory = directory
        self.workspaceID = workspaceID
        self.activityID = activityID
        self.profile = profile
    }

    func perform() async throws -> some IntentResult {
        let activity = try actionActivity(sessionID: sessionID, credentialID: credentialID, baseURL: baseURL,
            username: username, directory: directory, workspaceID: workspaceID, activityID: activityID,
            profile: profile, requestID: requestID, kind: "permission")
        let attributes = activity.attributes
        guard let identity = attributes.identity else { throw OpenCodeLiveActivityActionError.requestFailed }
        let client = OpenCodeLiveActivityActionClient(baseURL: attributes.serverBaseURL, username: attributes.serverUsername,
            credentialID: attributes.credentialID, profile: identity.owner.profile, sessionID: identity.sessionID)
        try await client.replyToPermission(requestID: requestID, reply: reply, directory: attributes.requestDirectory, workspaceID: attributes.workspaceID)
        await clearPendingInteraction(activity: activity, requestID: requestID, kind: "permission")
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
    @Parameter(title: "Activity ID") var activityID: String?
    @Parameter(title: "API Profile") var profile: String?

    init() {}

    init(
        sessionID: String,
        requestID: String,
        answer: String,
        credentialID: String,
        baseURL: String,
        username: String,
        directory: String?,
        workspaceID: String?,
        activityID: String? = nil,
        profile: String? = nil
    ) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.answer = answer
        self.credentialID = credentialID
        self.baseURL = baseURL
        self.username = username
        self.directory = directory
        self.workspaceID = workspaceID
        self.activityID = activityID
        self.profile = profile
    }

    func perform() async throws -> some IntentResult {
        let activity = try actionActivity(sessionID: sessionID, credentialID: credentialID, baseURL: baseURL,
            username: username, directory: directory, workspaceID: workspaceID, activityID: activityID,
            profile: profile, requestID: requestID, kind: "question")
        let attributes = activity.attributes
        guard attributes.identity?.owner.profile == .legacy,
              activity.content.state.canReplyToQuestionInline,
              activity.content.state.questionOptionLabels.contains(answer) else { throw OpenCodeLiveActivityActionError.requestFailed }
        let client = OpenCodeLiveActivityActionClient(baseURL: attributes.serverBaseURL, username: attributes.serverUsername,
            credentialID: attributes.credentialID, profile: .legacy, sessionID: attributes.sessionID)
        try await client.replyToQuestion(requestID: requestID, answers: [[answer]], directory: attributes.requestDirectory, workspaceID: attributes.workspaceID)
        await clearPendingInteraction(activity: activity, requestID: requestID, kind: "question")
        return .result()
    }
}

private func actionActivity(sessionID: String, credentialID: String, baseURL: String, username: String,
                            directory: String?, workspaceID: String?, activityID: String?, profile: String?,
                            requestID: String, kind: String) throws -> Activity<OpenCodeChatActivityAttributes> {
    guard let profile = OpenCodeProfileIdentity(rawValue: profile ?? "legacy") else { throw OpenCodeLiveActivityActionError.requestFailed }
    let identity = OpenCodeLiveActivityOwner(profile: profile, serverID: credentialID).session(sessionID)
    let matches = Activity<OpenCodeChatActivityAttributes>.activities.filter {
        $0.attributes.matches(identity, activityID: activityID, actualActivityID: $0.id) &&
            $0.attributes.serverBaseURL == baseURL && $0.attributes.serverUsername == username &&
            $0.attributes.directory == directory && $0.attributes.workspaceID == workspaceID &&
            ($0.activityState == .active || $0.activityState == .stale) &&
            $0.content.state.interactionID == requestID && $0.content.state.pendingInteractionKind == kind
    }
    guard matches.count == 1, let activity = matches.first else { throw OpenCodeLiveActivityActionError.requestFailed }
    return activity
}

private func clearPendingInteraction(activity: Activity<OpenCodeChatActivityAttributes>, requestID: String, kind: String) async {
    guard activity.activityState == .active || activity.activityState == .stale,
          activity.content.state.interactionID == requestID,
          activity.content.state.pendingInteractionKind == kind else { return }

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
