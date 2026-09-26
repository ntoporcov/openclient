import XCTest
@testable import OpenClient

@MainActor
final class SessionInteractionStoreTests: XCTestCase {
    func testApplySelectedSessionProjectsSessionLocalInteractions() {
        let selectedID = "ses_selected"
        let otherID = "ses_other"
        let selectedTodo = OpenCodeTodo(content: "Selected", status: "pending", priority: "high")
        let otherTodo = OpenCodeTodo(content: "Other", status: "completed", priority: "low")
        let selectedPermission = permission(id: "perm_selected", sessionID: selectedID)
        let otherPermission = permission(id: "perm_other", sessionID: otherID)
        let selectedQuestion = questionRequest(id: "q_selected", sessionID: selectedID)
        let otherQuestion = questionRequest(id: "q_other", sessionID: otherID)
        var syncState = OpenCodeDirectorySyncState()
        syncState.todosBySessionID = [selectedID: [selectedTodo], otherID: [otherTodo]]
        syncState.permissionsBySessionID = [selectedID: [selectedPermission], otherID: [otherPermission]]
        syncState.questionsBySessionID = [selectedID: [selectedQuestion], otherID: [otherQuestion]]
        let store = SessionInteractionStore(
            todos: [otherTodo],
            permissions: [otherPermission],
            questions: [otherQuestion]
        )

        store.applySelectedSession(sessionID: selectedID, sessions: [], syncState: syncState)

        XCTAssertEqual(store.todos, [selectedTodo])
        XCTAssertEqual(store.permissions, [selectedPermission])
        XCTAssertEqual(store.questions, [selectedQuestion])
    }

    func testApplySelectedSessionClearsMissingSessionInteractions() {
        let store = SessionInteractionStore(
            todos: [OpenCodeTodo(content: "Stale", status: "pending", priority: "high")],
            permissions: [permission(id: "perm_stale", sessionID: "ses_stale")],
            questions: [questionRequest(id: "q_stale", sessionID: "ses_stale")]
        )

        store.applySelectedSession(sessionID: "ses_missing", sessions: [], syncState: OpenCodeDirectorySyncState())

        XCTAssertTrue(store.todos.isEmpty)
        XCTAssertTrue(store.permissions.isEmpty)
        XCTAssertTrue(store.questions.isEmpty)
    }

    func testApplyTodosOnlyUpdatesVisibleTodosForSelectedSession() {
        let selectedTodo = OpenCodeTodo(content: "Selected", status: "pending", priority: "high")
        let staleTodo = OpenCodeTodo(content: "Stale", status: "completed", priority: "low")
        let store = SessionInteractionStore(todos: [staleTodo])

        store.applyTodos([selectedTodo], forSessionID: "ses_other", selectedSessionID: "ses_selected")
        XCTAssertEqual(store.todos, [staleTodo])

        store.applyTodos([selectedTodo], forSessionID: "ses_selected", selectedSessionID: "ses_selected")
        XCTAssertEqual(store.todos, [selectedTodo])
    }

    func testApplyLoadedPermissionsAndQuestionsReplaceVisibleCollections() {
        let permission = permission(id: "perm_1", sessionID: "ses_1")
        let question = questionRequest(id: "q_1", sessionID: "ses_1")
        let store = SessionInteractionStore(
            permissions: [self.permission(id: "perm_stale", sessionID: "ses_stale")],
            questions: [questionRequest(id: "q_stale", sessionID: "ses_stale")]
        )

        store.applyLoadedPermissions([permission])
        store.applyLoadedQuestions([question])

        XCTAssertEqual(store.permissions, [permission])
        XCTAssertEqual(store.questions, [question])
    }

    func testApplySelectedSessionProjectsNestedChildPermissionsAndQuestions() {
        let root = session(id: "ses_root")
        let child = session(id: "ses_child", parentID: root.id)
        let grandchild = session(id: "ses_grandchild", parentID: child.id)
        let unrelated = session(id: "ses_other")
        let rootPermission = permission(id: "perm_root", sessionID: root.id)
        let grandchildPermission = permission(id: "perm_grandchild", sessionID: grandchild.id)
        let unrelatedPermission = permission(id: "perm_other", sessionID: unrelated.id)
        let childQuestion = questionRequest(id: "q_child", sessionID: child.id)
        let unrelatedQuestion = questionRequest(id: "q_other", sessionID: unrelated.id)
        var syncState = OpenCodeDirectorySyncState()
        syncState.permissionsBySessionID = [
            root.id: [rootPermission],
            grandchild.id: [grandchildPermission],
            unrelated.id: [unrelatedPermission],
        ]
        syncState.questionsBySessionID = [
            child.id: [childQuestion],
            unrelated.id: [unrelatedQuestion],
        ]
        let store = SessionInteractionStore()

        store.applySelectedSession(
            sessionID: root.id,
            sessions: [root, child, grandchild, unrelated],
            syncState: syncState
        )

        XCTAssertEqual(store.permissions, [rootPermission, grandchildPermission])
        XCTAssertEqual(store.questions, [childQuestion])
        XCTAssertTrue(store.hasPermissionRequest(
            forSessionTreeRootID: root.id,
            sessions: [root, child, grandchild, unrelated]
        ))
        XCTAssertFalse(store.hasPermissionRequest(
            forSessionTreeRootID: unrelated.id,
            sessions: [root, child, grandchild, unrelated]
        ))
    }

    func testApplyVisibleInteractionsReportsAndAppliesChanges() {
        let todo = OpenCodeTodo(content: "Selected", status: "pending", priority: "high")
        let permission = permission(id: "perm_1", sessionID: "ses_1")
        let question = questionRequest(id: "q_1", sessionID: "ses_1")
        let store = SessionInteractionStore()

        XCTAssertTrue(store.applyVisibleInteractions(todos: [todo], permissions: [permission], questions: [question]))
        XCTAssertEqual(store.todos, [todo])
        XCTAssertEqual(store.permissions, [permission])
        XCTAssertEqual(store.questions, [question])

        XCTAssertFalse(store.applyVisibleInteractions(todos: [todo], permissions: [permission], questions: [question]))
    }

    func testEmptyFormsAcrossFourHundredSessionsRemainEmpty() {
        let sessions = (0..<400).map { session(id: "session-\($0)") }

        for session in sessions {
            XCTAssertTrue(SessionInteractionStore.forms(
                forSessionTreeRootID: session.id,
                sessions: sessions,
                forms: []
            ).isEmpty)
        }
    }

    private func permission(id: String, sessionID: String) -> OpenCodePermission {
        OpenCodePermission(
            id: id,
            sessionID: sessionID,
            permission: "bash",
            patterns: ["bash"],
            always: nil,
            metadata: nil,
            tool: nil
        )
    }

    private func questionRequest(id: String, sessionID: String) -> OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(
            id: id,
            sessionID: sessionID,
            questions: [
                OpenCodeQuestion(
                    question: "Choose",
                    header: "Question",
                    options: [OpenCodeQuestionOption(label: "Yes", description: "Continue")]
                )
            ],
            tool: nil
        )
    }

    private func session(id: String, parentID: String? = nil) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            title: id,
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parentID
        )
    }
}
