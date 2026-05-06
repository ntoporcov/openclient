import Foundation

@MainActor
final class EventSyncCoordinator {
    enum GlobalEventAction {
        case refreshProjectsAndSessions
    }

    struct DirectoryEventState: Equatable {
        var sessions: [OpenCodeSession]
        var selectedSession: OpenCodeSession?
        var sessionStatuses: [String: String]
        var messages: [OpenCodeMessageEnvelope]
        var todos: [OpenCodeTodo]
        var permissions: [OpenCodePermission]
        var questions: [OpenCodeQuestionRequest]
    }

    struct DirectoryEventApplication {
        var state: DirectoryEventState
        var results: [SessionEventResult]

        var result: SessionEventResult {
            results.last ?? .ignored("no events")
        }

        var messageApplyCount: Int {
            results.reduce(0) { count, result in
                if case .message = result {
                    return count + 1
                }
                return count
            }
        }
    }

    func shouldProcessEvent(isConnected: Bool) -> Bool {
        isConnected
    }

    func shouldProcessLiveMessageEvent(
        eventType: String,
        eventSessionID: String?,
        selectedSessionID: String?,
        activeChatSessionID: String?,
        activeLiveActivitySessionIDs: Set<String>,
        affectsSelectedTranscript: Bool
    ) -> Bool {
        guard Self.isLiveActivityMessageEventType(eventType) else { return true }

        if let eventSessionID, activeLiveActivitySessionIDs.contains(eventSessionID) {
            return true
        }

        if let eventSessionID, eventSessionID == activeChatSessionID {
            return true
        }

        if let eventSessionID, eventSessionID == selectedSessionID {
            return true
        }

        // Some removal events only carry message ids. Keep those when they match the selected transcript.
        if eventSessionID == nil, affectsSelectedTranscript {
            return true
        }

        return false
    }

    func shouldApplyDirectoryEvent(
        eventDirectory: String,
        eventSessionID: String?,
        selectedSessionID: String?,
        selectedSessionDirectory: String?,
        effectiveSelectedDirectory: String?,
        activeLiveActivitySessionIDs: Set<String>
    ) -> Bool {
        if let selectedSessionID,
           eventSessionID == selectedSessionID {
            return true
        }

        if let eventSessionID,
           activeLiveActivitySessionIDs.contains(eventSessionID) {
            return true
        }

        let acceptedDirectories = [selectedSessionDirectory, effectiveSelectedDirectory]
            .compactMap { directory -> String? in
                guard let directory, !directory.isEmpty else { return nil }
                return directory
            }

        guard !acceptedDirectories.isEmpty else {
            return eventDirectory == "global"
        }

        if acceptedDirectories.contains(eventDirectory) {
            return true
        }

        guard eventDirectory == "global" else { return false }

        return eventSessionID != nil
    }

    func eventAffectsSelectedSession(
        _ event: OpenCodeTypedEvent,
        selectedSessionID: String?,
        selectedMessages: [OpenCodeMessageEnvelope],
        hasGitProject: Bool
    ) -> Bool {
        guard let selectedSessionID else {
            return true
        }

        switch event {
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            return session.id == selectedSessionID
        case let .sessionStatus(sessionID, _), let .sessionIdle(sessionID), let .sessionDiff(sessionID), let .todoUpdated(sessionID, _), let .messageRemoved(sessionID, _), let .messagePartDelta(sessionID, _, _, _, _), let .permissionReplied(sessionID, _, _), let .questionReplied(sessionID, _), let .questionRejected(sessionID, _):
            return sessionID == selectedSessionID
        case let .sessionError(sessionID, _):
            return sessionID == nil || sessionID == selectedSessionID
        case let .messageUpdated(info):
            return info.sessionID == selectedSessionID
        case let .messagePartUpdated(part):
            return part.sessionID == selectedSessionID
        case let .permissionAsked(permission):
            return permission.sessionID == selectedSessionID
        case let .questionAsked(question):
            return question.sessionID == selectedSessionID
        case let .messagePartRemoved(messageID, _):
            return selectedMessages.contains { $0.info.id == messageID }
        case .vcsBranchUpdated, .fileWatcherUpdated:
            return hasGitProject
        default:
            return false
        }
    }

    func sessionID(for event: OpenCodeTypedEvent) -> String? {
        switch event {
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            return session.id
        case let .sessionStatus(sessionID, _), let .sessionIdle(sessionID), let .sessionDiff(sessionID), let .todoUpdated(sessionID, _), let .messageRemoved(sessionID, _), let .messagePartDelta(sessionID, _, _, _, _), let .permissionReplied(sessionID, _, _), let .questionReplied(sessionID, _), let .questionRejected(sessionID, _):
            return sessionID
        case let .sessionError(sessionID, _):
            return sessionID
        case let .messageUpdated(info):
            return info.sessionID
        case let .messagePartUpdated(part):
            return part.sessionID
        case let .permissionAsked(permission):
            return permission.sessionID
        case let .questionAsked(question):
            return question.sessionID
        default:
            return nil
        }
    }

    func applyGlobalEvent(
        _ managed: OpenCodeManagedEvent,
        projects: inout [OpenCodeProject],
        currentProject: inout OpenCodeProject?
    ) -> GlobalEventAction? {
        guard OpenCodeStateReducer.applyGlobalEvent(
            event: managed.typed,
            projects: &projects,
            currentProject: &currentProject
        ) else {
            return nil
        }

        switch managed.typed {
        case .serverConnected, .globalDisposed:
            return .refreshProjectsAndSessions
        default:
            return nil
        }
    }

    func applyDirectoryEvent(
        _ managed: OpenCodeManagedEvent,
        sessions: inout [OpenCodeSession],
        selectedSession: inout OpenCodeSession?,
        sessionStatuses: inout [String: String],
        messages: inout [OpenCodeMessageEnvelope],
        todos: inout [OpenCodeTodo],
        permissions: inout [OpenCodePermission],
        questions: inout [OpenCodeQuestionRequest]
    ) -> SessionEventResult {
        OpenCodeStateReducer.applyDirectoryEvent(
            event: managed.typed,
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
    }

    func applyDirectoryEvent(
        _ event: OpenCodeTypedEvent,
        sessions: inout [OpenCodeSession],
        selectedSession: inout OpenCodeSession?,
        sessionStatuses: inout [String: String],
        messages: inout [OpenCodeMessageEnvelope],
        todos: inout [OpenCodeTodo],
        permissions: inout [OpenCodePermission],
        questions: inout [OpenCodeQuestionRequest]
    ) -> SessionEventResult {
        OpenCodeStateReducer.applyDirectoryEvent(
            event: event,
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
    }

    func applyDirectoryEvent(_ managed: OpenCodeManagedEvent, to state: DirectoryEventState) -> DirectoryEventApplication {
        applyDirectoryEvents([managed.typed], to: state)
    }

    func applyDirectoryEvents(_ events: [OpenCodeTypedEvent], to state: DirectoryEventState) -> DirectoryEventApplication {
        var nextState = state
        var results: [SessionEventResult] = []

        for event in events {
            let result = OpenCodeStateReducer.applyDirectoryEvent(
                event: event,
                sessions: &nextState.sessions,
                selectedSession: &nextState.selectedSession,
                sessionStatuses: &nextState.sessionStatuses,
                messages: &nextState.messages,
                todos: &nextState.todos,
                permissions: &nextState.permissions,
                questions: &nextState.questions
            )
            results.append(result)
        }

        return DirectoryEventApplication(state: nextState, results: results)
    }

    nonisolated static func isLiveActivityMessageEventType(_ type: String) -> Bool {
        switch type {
        case "message.updated", "message.part.updated", "message.part.delta", "message.removed", "message.part.removed":
            return true
        default:
            return false
        }
    }
}
