import Combine
import Foundation

@MainActor
final class SessionInteractionStore: ObservableObject {
    @Published var todos: [OpenCodeTodo]
    @Published var permissions: [OpenCodePermission]
    @Published var questions: [OpenCodeQuestionRequest]

    init(
        todos: [OpenCodeTodo] = [],
        permissions: [OpenCodePermission] = [],
        questions: [OpenCodeQuestionRequest] = []
    ) {
        self.todos = todos
        self.permissions = permissions
        self.questions = questions
    }

    func reset() {
        replaceTodos([])
        replacePermissions([])
        replaceQuestions([])
    }

    func replaceTodos(_ nextTodos: [OpenCodeTodo]) {
        if todos != nextTodos {
            todos = nextTodos
        }
    }

    func replacePermissions(_ nextPermissions: [OpenCodePermission]) {
        if permissions != nextPermissions {
            permissions = nextPermissions
        }
    }

    func replaceQuestions(_ nextQuestions: [OpenCodeQuestionRequest]) {
        if questions != nextQuestions {
            questions = nextQuestions
        }
    }

    func applyDirectoryBootstrap(_ bootstrap: OpenCodeDirectoryBootstrap) {
        replacePermissions(bootstrap.permissions)
        replaceQuestions(bootstrap.questions)
    }

    func applySelectedSession(
        sessionID: String,
        sessions: [OpenCodeSession],
        syncState: OpenCodeDirectorySyncState
    ) {
        replaceTodos(syncState.todosBySessionID[sessionID] ?? [])
        replacePermissions(Self.permissions(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            permissionsBySessionID: syncState.permissionsBySessionID
        ))
        replaceQuestions(Self.questions(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            questionsBySessionID: syncState.questionsBySessionID
        ))
    }

    func applyTodos(_ nextTodos: [OpenCodeTodo], forSessionID sessionID: String, selectedSessionID: String?) {
        guard selectedSessionID == sessionID else { return }
        replaceTodos(nextTodos)
    }

    func applyLoadedPermissions(_ nextPermissions: [OpenCodePermission]) {
        replacePermissions(nextPermissions)
    }

    func applyLoadedQuestions(_ nextQuestions: [OpenCodeQuestionRequest]) {
        replaceQuestions(nextQuestions)
    }

    @discardableResult
    func applyVisibleInteractions(
        todos nextTodos: [OpenCodeTodo],
        permissions nextPermissions: [OpenCodePermission],
        questions nextQuestions: [OpenCodeQuestionRequest]
    ) -> Bool {
        var changed = false
        if todos != nextTodos {
            todos = nextTodos
            changed = true
        }
        if permissions != nextPermissions {
            permissions = nextPermissions
            changed = true
        }
        if questions != nextQuestions {
            questions = nextQuestions
            changed = true
        }
        return changed
    }

    func permissions(forSessionTreeRootID sessionID: String, sessions: [OpenCodeSession]) -> [OpenCodePermission] {
        Self.requests(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            requestsBySessionID: Dictionary(grouping: permissions, by: \.sessionID)
        )
    }

    func questions(forSessionTreeRootID sessionID: String, sessions: [OpenCodeSession]) -> [OpenCodeQuestionRequest] {
        Self.requests(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            requestsBySessionID: Dictionary(grouping: questions, by: \.sessionID)
        )
    }

    func hasPermissionRequest(forSessionTreeRootID sessionID: String, sessions: [OpenCodeSession]) -> Bool {
        !permissions(forSessionTreeRootID: sessionID, sessions: sessions).isEmpty
    }

    func removePermission(id: String) {
        permissions.removeAll { $0.id == id }
    }

    func removeQuestion(id: String) {
        questions.removeAll { $0.id == id }
    }

    static func permissions(
        forSessionTreeRootID sessionID: String,
        sessions: [OpenCodeSession],
        permissionsBySessionID: [String: [OpenCodePermission]]
    ) -> [OpenCodePermission] {
        requests(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            requestsBySessionID: permissionsBySessionID
        )
    }

    static func questions(
        forSessionTreeRootID sessionID: String,
        sessions: [OpenCodeSession],
        questionsBySessionID: [String: [OpenCodeQuestionRequest]]
    ) -> [OpenCodeQuestionRequest] {
        requests(
            forSessionTreeRootID: sessionID,
            sessions: sessions,
            requestsBySessionID: questionsBySessionID
        )
    }

    static func forms(forSessionTreeRootID sessionID: String, sessions: [OpenCodeSession], forms: [BackendForm]) -> [BackendForm] {
        let scopedForms = forms.filter { $0.sessionID != "global" }
        guard !scopedForms.isEmpty else { return [] }
        return requests(forSessionTreeRootID: sessionID, sessions: sessions,
            requestsBySessionID: Dictionary(grouping: scopedForms, by: \.sessionID))
            .sorted { $0.id < $1.id }
    }

    static func sessionTreeRootIDsWithRequests<Request>(
        sessions: [OpenCodeSession],
        requestsBySessionID: [String: [Request]]
    ) -> Set<String> {
        var parentBySessionID: [String: String] = [:]
        for session in sessions {
            if let parentID = session.parentID {
                parentBySessionID[session.id] = parentID
            }
        }

        var roots: Set<String> = []
        for sessionID in requestsBySessionID.keys where requestsBySessionID[sessionID]?.isEmpty == false {
            var current = sessionID
            var visited: Set<String> = []
            while visited.insert(current).inserted, let parentID = parentBySessionID[current] {
                current = parentID
            }
            roots.insert(current)
        }
        return roots
    }

    private static func requests<Request>(
        forSessionTreeRootID sessionID: String,
        sessions: [OpenCodeSession],
        requestsBySessionID: [String: [Request]]
    ) -> [Request] {
        guard !requestsBySessionID.isEmpty else { return [] }
        let childrenByParentID = Dictionary(grouping: sessions.compactMap { session -> (String, String)? in
            session.parentID.map { ($0, session.id) }
        }, by: \.0)
        var seen = Set([sessionID])
        var sessionIDs = [sessionID]
        var index = 0

        while index < sessionIDs.count {
            let currentID = sessionIDs[index]
            index += 1
            for child in childrenByParentID[currentID] ?? [] where seen.insert(child.1).inserted {
                sessionIDs.append(child.1)
            }
        }

        return sessionIDs.flatMap { requestsBySessionID[$0] ?? [] }
    }
}
