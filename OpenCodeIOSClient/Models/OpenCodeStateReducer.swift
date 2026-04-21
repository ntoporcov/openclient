import Foundation

enum OpenCodeStateReducer {
    static func applyGlobalEvent(
        event: OpenCodeTypedEvent,
        projects: inout [OpenCodeProject],
        currentProject: inout OpenCodeProject?
    ) -> Bool {
        switch event {
        case let .projectUpdated(project):
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
                projects.sort { $0.id < $1.id }
            }
            if currentProject?.id == project.id {
                currentProject = project
            }
            return true
        case .serverConnected, .globalDisposed:
            return true
        default:
            return false
        }
    }

    static func applyDirectoryEvent(
        event: OpenCodeTypedEvent,
        state: inout OpenCodeDirectoryState
    ) -> SessionEventResult {
        switch event {
        case let .sessionCreated(session):
            upsertSession(session, into: &state.sessions)
            return .sessionChanged
        case let .sessionUpdated(session):
            upsertSession(session, into: &state.sessions)
            if state.selectedSession?.id == session.id {
                state.selectedSession = session
            }
            return .sessionChanged
        case let .sessionDeleted(session):
            state.sessions.removeAll { $0.id == session.id }
            state.sessionStatuses[session.id] = nil
            if state.selectedSession?.id == session.id {
                state.selectedSession = nil
                state.messages = []
                state.todos = []
            }
            return .sessionChanged
        case let .sessionStatus(sessionID, status):
            state.sessionStatuses[sessionID] = status
            return status == "idle" && state.selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .sessionIdle(sessionID):
            state.sessionStatuses[sessionID] = "idle"
            return state.selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .todoUpdated(sessionID, todos):
            guard sessionID == state.selectedSession?.id else {
                return .ignored("session mismatch")
            }
            state.todos = todos
            return .todoChanged
        case let .messageUpdated(info):
            guard let selectedSessionID = state.selectedSession?.id,
                  info.sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.updated", properties: .init(sessionID: info.sessionID, info: info, part: nil, status: nil, todos: nil, messageID: nil, partID: nil, field: nil, delta: nil, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: state.messages)
            state.messages = update.messages
            return .message(update.reason)
        case let .messagePartUpdated(part):
            guard let selectedSessionID = state.selectedSession?.id,
                  part.sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.part.updated", properties: .init(sessionID: part.sessionID, info: nil, part: part, status: nil, todos: nil, messageID: nil, partID: nil, field: nil, delta: nil, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: state.messages)
            state.messages = update.messages
            return .message(update.reason)
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            guard let selectedSessionID = state.selectedSession?.id,
                  sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.part.delta", properties: .init(sessionID: sessionID, info: nil, part: nil, status: nil, todos: nil, messageID: messageID, partID: partID, field: field, delta: delta, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: state.messages)
            state.messages = update.messages
            return .message(update.reason)
        case let .messageRemoved(sessionID, messageID):
            guard sessionID == state.selectedSession?.id else {
                return .ignored("session mismatch")
            }
            state.messages.removeAll { $0.info.id == messageID }
            return .message("message removed")
        case let .messagePartRemoved(messageID, partID):
            guard let index = state.messages.firstIndex(where: { $0.info.id == messageID }) else {
                return .ignored("message missing")
            }
            state.messages[index] = state.messages[index].removingPart(partID: partID)
            return .message("part removed")
        case let .permissionAsked(permission):
            if let index = state.permissions.firstIndex(where: { $0.id == permission.id }) {
                state.permissions[index] = permission
            } else {
                state.permissions.append(permission)
            }
            return .permissionChanged
        case let .permissionReplied(sessionID, requestID, _):
            state.permissions.removeAll { $0.id == requestID }
            if state.selectedSession?.id != sessionID {
                return .statusChanged
            }
            return .permissionChanged
        case let .questionAsked(question):
            if let index = state.questions.firstIndex(where: { $0.id == question.id }) {
                state.questions[index] = question
            } else {
                state.questions.append(question)
            }
            return .questionChanged
        case let .questionReplied(sessionID, requestID), let .questionRejected(sessionID, requestID):
            state.questions.removeAll { $0.id == requestID }
            if state.selectedSession?.id != sessionID {
                return .statusChanged
            }
            return .questionChanged
        default:
            return .ignored("unhandled")
        }
    }

    private static func upsertSession(_ session: OpenCodeSession, into sessions: inout [OpenCodeSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
    }
}

enum SessionEventResult {
    case message(String)
    case sessionChanged
    case todoChanged
    case permissionChanged
    case questionChanged
    case statusChanged
    case idle
    case ignored(String)
}
