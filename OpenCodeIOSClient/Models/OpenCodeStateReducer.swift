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
        sessions: inout [OpenCodeSession],
        selectedSession: inout OpenCodeSession?,
        sessionStatuses: inout [String: String],
        messages: inout [OpenCodeMessageEnvelope],
        todos: inout [OpenCodeTodo],
        permissions: inout [OpenCodePermission],
        questions: inout [OpenCodeQuestionRequest]
    ) -> SessionEventResult {
        switch event {
        case let .sessionCreated(session):
            upsertSession(session, into: &sessions)
            return .sessionChanged
        case let .sessionUpdated(session):
            upsertSession(session, into: &sessions)
            if selectedSession?.id == session.id {
                selectedSession = selectedSession?.merged(with: session)
            }
            return .sessionChanged
        case let .sessionDeleted(session):
            sessions.removeAll { $0.id == session.id }
            sessionStatuses[session.id] = nil
            if selectedSession?.id == session.id {
                selectedSession = nil
                messages = []
                todos = []
            }
            return .sessionChanged
        case let .sessionStatus(sessionID, status):
            sessionStatuses[sessionID] = status
            return status == "idle" && selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .sessionIdle(sessionID):
            sessionStatuses[sessionID] = "idle"
            return selectedSession?.id == sessionID ? .idle : .statusChanged
        case let .todoUpdated(sessionID, updatedTodos):
            guard sessionID == selectedSession?.id else {
                return .ignored("session mismatch")
            }
            todos = updatedTodos
            return .todoChanged
        case let .messageUpdated(info):
            guard let selectedSessionID = selectedSession?.id,
                  info.sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.updated", properties: .init(sessionID: info.sessionID, info: OpenCodeEventInfo(message: info), part: nil, status: nil, todos: nil, messageID: nil, partID: nil, field: nil, delta: nil, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil, error: nil, branch: nil, file: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: messages)
            messages = update.messages
            return .message(update.reason)
        case let .messagePartUpdated(part):
            guard let selectedSessionID = selectedSession?.id,
                  part.sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.part.updated", properties: .init(sessionID: part.sessionID, info: nil, part: part, status: nil, todos: nil, messageID: nil, partID: nil, field: nil, delta: nil, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil, error: nil, branch: nil, file: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: messages)
            messages = update.messages
            return .message(update.reason)
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            guard let selectedSessionID = selectedSession?.id,
                  sessionID == selectedSessionID else {
                return .ignored("session mismatch")
            }
            let payload = OpenCodeEventEnvelope(type: "message.part.delta", properties: .init(sessionID: sessionID, info: nil, part: nil, status: nil, todos: nil, messageID: messageID, partID: partID, field: field, delta: delta, id: nil, permissionType: nil, pattern: nil, callID: nil, title: nil, metadata: nil, permissionID: nil, response: nil, reply: nil, message: nil, error: nil, branch: nil, file: nil))
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: selectedSessionID, messages: messages)
            messages = update.messages
            return .message(update.reason)
        case let .messageRemoved(sessionID, messageID):
            guard sessionID == selectedSession?.id else {
                return .ignored("session mismatch")
            }
            messages.removeAll { $0.info.id == messageID }
            return .message("message removed")
        case let .messagePartRemoved(messageID, partID):
            guard let index = messages.firstIndex(where: { $0.info.id == messageID }) else {
                return .ignored("message missing")
            }
            messages[index] = messages[index].removingPart(partID: partID)
            return .message("part removed")
        case let .permissionAsked(permission):
            if let index = permissions.firstIndex(where: { $0.id == permission.id }) {
                permissions[index] = permission
            } else {
                permissions.append(permission)
            }
            return .permissionChanged
        case let .permissionReplied(sessionID, requestID, _):
            permissions.removeAll { $0.id == requestID }
            if selectedSession?.id != sessionID {
                return .statusChanged
            }
            return .permissionChanged
        case let .questionAsked(question):
            if let index = questions.firstIndex(where: { $0.id == question.id }) {
                questions[index] = question
            } else {
                questions.append(question)
            }
            return .questionChanged
        case let .questionReplied(sessionID, requestID), let .questionRejected(sessionID, requestID):
            questions.removeAll { $0.id == requestID }
            if selectedSession?.id != sessionID {
                return .statusChanged
            }
            return .questionChanged
        default:
            return .ignored("unhandled")
        }
    }

    private static func upsertSession(_ session: OpenCodeSession, into sessions: inout [OpenCodeSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = sessions[index].merged(with: session)
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
