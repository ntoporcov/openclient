import Foundation

enum LiveActivityDeepLinkAction: Equatable {
    case open
    case permission(requestID: String, reply: String)
    case question(requestID: String, answer: String)
}

struct LiveActivityDeepLink: Equatable {
    var sessionID: String
    var directory: String?
    var workspaceID: String?
    var action: LiveActivityDeepLinkAction
    var owner: OpenCodeLiveActivityOwner? = nil
    var activityID: String? = nil
}

struct LiveActivitySessionSnapshot: Equatable {
    var sessionID: String
    var sessionTitle: String
    var workspaceID: String?
    var directory: String?
    var projectID: String? = nil
}

enum LiveActivitySessionResolution: Equatable {
    case existing(OpenCodeSession)
    case fallback(OpenCodeSession)

    var session: OpenCodeSession {
        switch self {
        case let .existing(session), let .fallback(session):
            return session
        }
    }
}

enum LiveActivityCoordinator {
    static func deepLink(from url: URL) -> LiveActivityDeepLink? {
        guard url.scheme == OpenCodeChatActivityDeepLink.scheme,
              url.host == OpenCodeChatActivityDeepLink.host else {
            return nil
        }

        let pathComponents = url.pathComponents
        guard pathComponents.count >= 3, pathComponents[1] == "session" else { return nil }

        let sessionID = pathComponents[2]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let actionValue = queryItems.first(where: { $0.name == "action" })?.value
        let directory = normalizedDirectory(queryItems.first(where: { $0.name == "directory" })?.value)
        let workspaceID = queryItems.first(where: { $0.name == "workspace" })?.value
        let profile = queryItems.first(where: { $0.name == "profile" })?.value
        let serverID = queryItems.first(where: { $0.name == "serverID" })?.value
        let owner: OpenCodeLiveActivityOwner?
        if let serverID, !serverID.isEmpty,
           let resolved = OpenCodeProfileIdentity(rawValue: profile ?? "legacy") {
            owner = .init(profile: resolved, serverID: serverID)
        } else {
            guard profile == nil, serverID == nil else { return nil }
            owner = nil
        }
        let action: LiveActivityDeepLinkAction

        switch actionValue {
        case "permission":
            guard let requestID = queryItems.first(where: { $0.name == "requestID" })?.value,
                  let reply = queryItems.first(where: { $0.name == "reply" })?.value else {
                return nil
            }
            action = .permission(requestID: requestID, reply: reply)
        case "question":
            guard let requestID = queryItems.first(where: { $0.name == "requestID" })?.value,
                  let answer = queryItems.first(where: { $0.name == "answer" })?.value else {
                return nil
            }
            action = .question(requestID: requestID, answer: answer)
        default:
            action = .open
        }

        return LiveActivityDeepLink(
            sessionID: sessionID,
            directory: directory,
            workspaceID: workspaceID,
            action: action,
            owner: owner,
            activityID: queryItems.first(where: { $0.name == "activityID" })?.value
        )
    }

    static func resolveSession(
        sessionID: String,
        directory: String?,
        workspaceID: String?,
        knownSessions: [OpenCodeSession],
        selectedSession: OpenCodeSession?,
        activitySnapshot: LiveActivitySessionSnapshot?
    ) -> LiveActivitySessionResolution {
        if let session = knownSessions.first(where: { $0.id == sessionID }) ?? (selectedSession?.id == sessionID ? selectedSession : nil) {
            return .existing(session)
        }

        if let activitySnapshot {
            return .fallback(OpenCodeSession(
                id: activitySnapshot.sessionID,
                title: activitySnapshot.sessionTitle,
                workspaceID: activitySnapshot.workspaceID,
                directory: normalizedDirectory(activitySnapshot.directory),
                projectID: activitySnapshot.projectID,
                parentID: nil
            ))
        }

        return .fallback(OpenCodeSession(
            id: sessionID,
            title: String(localized: "Session"),
            workspaceID: workspaceID,
            directory: normalizedDirectory(directory),
            projectID: nil,
            parentID: nil
        ))
    }

    static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty, directory != "/" else { return nil }
        return directory
    }
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct LiveActivityRecord {
    let id: String
    let attributes: OpenCodeChatActivityAttributes
    let state: OpenCodeChatActivityAttributes.ContentState
}

struct LiveActivityStartRequest {
    var sessionID: String
    var sessionTitle: String
    var credentialID: String
    var serverBaseURL: String
    var serverUsername: String
    var directory: String?
    var workspaceID: String?
    var state: OpenCodeChatActivityAttributes.ContentState
    var profile: OpenCodeProfileIdentity = .legacy
    var activityID: String? = nil
    var projectID: String? = nil

    var identity: OpenCodeLiveActivityIdentity {
        OpenCodeLiveActivityOwner(profile: profile, serverID: credentialID).session(sessionID)
    }
}

extension LiveActivityCoordinator {
    static func records() -> [LiveActivityRecord] {
        Activity<OpenCodeChatActivityAttributes>.activities.compactMap {
            guard $0.activityState == .active || $0.activityState == .stale else { return nil }
            return LiveActivityRecord(id: $0.id, attributes: $0.attributes, state: $0.content.state)
        }
    }

    @MainActor
    static func requestOrUpdate(_ request: LiveActivityStartRequest) async throws {
        if let existing = matchingActivities(request.identity, activityID: request.activityID).first {
            await existing.update(LiveActivitySnapshotBuilder.content(state: request.state))
            return
        }

        _ = try Activity.request(
            attributes: OpenCodeChatActivityAttributes(
                sessionID: request.sessionID,
                sessionTitle: request.sessionTitle,
                credentialID: request.credentialID,
                serverBaseURL: request.serverBaseURL,
                serverUsername: request.serverUsername,
                directory: request.directory,
                workspaceID: request.workspaceID,
                profile: request.profile.rawValue,
                projectID: request.projectID
            ),
            content: LiveActivitySnapshotBuilder.content(state: request.state),
            pushType: nil
        )
    }

    static func update(identity: OpenCodeLiveActivityIdentity, activityID: String? = nil, state: OpenCodeChatActivityAttributes.ContentState) async {
        for activity in matchingActivities(identity, activityID: activityID) {
            await activity.update(LiveActivitySnapshotBuilder.content(state: state))
        }
    }

    static func end(identity: OpenCodeLiveActivityIdentity, activityID: String? = nil, state: OpenCodeChatActivityAttributes.ContentState, immediate: Bool) async {
        for activity in matchingActivities(identity, activityID: activityID) {
            let dismissalPolicy: ActivityUIDismissalPolicy = immediate
                ? .immediate
                : .after(Date().addingTimeInterval(LiveActivitySnapshotBuilder.gracePeriod))
            await activity.end(LiveActivitySnapshotBuilder.content(state: state), dismissalPolicy: dismissalPolicy)
        }
    }

    static func matchingActivities(_ identity: OpenCodeLiveActivityIdentity, activityID: String? = nil) -> [Activity<OpenCodeChatActivityAttributes>] {
        Activity<OpenCodeChatActivityAttributes>.activities.filter {
            ($0.activityState == .active || $0.activityState == .stale) &&
                $0.attributes.matches(identity, activityID: activityID, actualActivityID: $0.id)
        }
    }

    static func currentActivities(owner: OpenCodeLiveActivityOwner) -> [Activity<OpenCodeChatActivityAttributes>] {
        Activity<OpenCodeChatActivityAttributes>.activities.filter {
            $0.attributes.identity?.owner == owner && ($0.activityState == .active || $0.activityState == .stale)
        }
    }

    static func sessionSnapshot(for sessionID: String, owner: OpenCodeLiveActivityOwner? = nil, activityID: String? = nil) -> LiveActivitySessionSnapshot? {
        // Old call sites without an owner cannot recover an arbitrary OS activity.
        guard let owner, let activity = matchingActivities(owner.session(sessionID), activityID: activityID).first else { return nil }
        return LiveActivitySessionSnapshot(
            sessionID: activity.attributes.sessionID,
            sessionTitle: activity.attributes.sessionTitle,
            workspaceID: activity.attributes.workspaceID,
            directory: activity.attributes.directory,
            projectID: activity.attributes.projectID
        )
    }
}

private enum TalkLiveActivityCoordinator {
    static func request(
        activityID: String,
        title: String,
        directory: String?,
        workspaceID: String?,
        state: OpenCodeTalkActivityAttributes.ContentState
    ) async {
        await Task.detached(priority: .userInitiated) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            _ = try? Activity.request(
                attributes: OpenCodeTalkActivityAttributes(
                    activityID: activityID,
                    title: title,
                    directory: directory,
                    workspaceID: workspaceID
                ),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        }.value
    }

    static func update(activityID: String, state: OpenCodeTalkActivityAttributes.ContentState) async {
        await Task.detached(priority: .utility) {
            guard let activity = Activity<OpenCodeTalkActivityAttributes>.activities.first(where: {
                $0.attributes.activityID == activityID
            }) else { return }
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }.value
    }

    static func end(activityID: String, state: OpenCodeTalkActivityAttributes.ContentState) async {
        await Task.detached(priority: .userInitiated) {
            guard let activity = Activity<OpenCodeTalkActivityAttributes>.activities.first(where: {
                $0.attributes.activityID == activityID
            }) else { return }
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }.value
    }
}

@MainActor
final class TalkLiveActivitySession {
    private var activityID: String?
    private var sessionID: String?
    private var phase: OpenCodeTalkActivityPhase = .listening
    private var operationTask: Task<Void, Never>?

    func start(
        title: String,
        directory: String?,
        workspaceID: String?,
        sessionID: String?,
        phase: OpenCodeTalkActivityPhase
    ) {
        let activityID = UUID().uuidString
        self.activityID = activityID
        self.sessionID = sessionID
        self.phase = phase
        enqueue { [activityID] in
            let state = OpenCodeTalkActivityAttributes.ContentState(
                phase: phase,
                sessionID: sessionID,
                updatedAt: Date()
            )
            await TalkLiveActivityCoordinator.request(
                activityID: activityID,
                title: title,
                directory: directory,
                workspaceID: workspaceID,
                state: state
            )
        }
    }

    func update(phase: OpenCodeTalkActivityPhase, sessionID: String? = nil) {
        guard let activityID else { return }
        self.phase = phase
        if let sessionID {
            self.sessionID = sessionID
        }
        let resolvedSessionID = self.sessionID
        enqueue { [activityID] in
            let state = OpenCodeTalkActivityAttributes.ContentState(
                phase: phase,
                sessionID: resolvedSessionID,
                updatedAt: Date()
            )
            await TalkLiveActivityCoordinator.update(activityID: activityID, state: state)
        }
    }

    func end() {
        guard let activityID else { return }
        let state = OpenCodeTalkActivityAttributes.ContentState(
            phase: phase,
            sessionID: sessionID,
            updatedAt: Date()
        )
        self.activityID = nil
        sessionID = nil
        enqueue { [activityID] in
            await TalkLiveActivityCoordinator.end(activityID: activityID, state: state)
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operationTask
        operationTask = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
}
#else
@MainActor
final class TalkLiveActivitySession {
    func start(
        title: String,
        directory: String?,
        workspaceID: String?,
        sessionID: String?,
        phase: OpenCodeTalkActivityPhase
    ) {}

    func update(phase: OpenCodeTalkActivityPhase, sessionID: String? = nil) {}
    func end() {}
}
#endif
