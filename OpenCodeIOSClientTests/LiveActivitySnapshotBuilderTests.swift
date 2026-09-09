import XCTest
@testable import OpenClient

#if canImport(ActivityKit) && os(iOS)
@MainActor
final class LiveActivitySnapshotBuilderTests: XCTestCase {
    func testV2FormsRemainOpenAppOnlyAndIgnoreLegacyQuestionProjection() {
        let session = makeSession(id: "ses_live")
        var input = makeInput(session: session, questions: [
            .init(id: "question", sessionID: session.id,
                  questions: [.init(question: "Proceed?", header: "Question", options: [.init(label: "Yes", description: "Continue")])], tool: nil)
        ])
        input.profile = .v2
        XCTAssertNil(LiveActivitySnapshotBuilder.state(for: input).pendingInteractionKind)
        input.forms = [
            .init(id: "foreign", sessionID: "other", title: "Not this session", fields: []),
            .init(id: "form", sessionID: session.id, title: "Provide details", fields: [])
        ]
        let state = LiveActivitySnapshotBuilder.state(for: input)
        XCTAssertEqual(state.pendingInteractionKind, "form")
        XCTAssertEqual(state.interactionID, "form")
        XCTAssertEqual(state.interactionSummary, "Provide details")
        XCTAssertEqual(state.status, "Action")
        XCTAssertTrue(state.questionOptionLabels.isEmpty)
        XCTAssertFalse(state.canReplyToQuestionInline)
    }

    func testTranscriptShowsLatestAssistantLineOnly() {
        let session = makeSession(id: "ses_live")
        let input = makeInput(
            session: session,
            selectedSessionID: session.id,
            selectedMessages: [
                .local(role: "user", text: "Can you fix the build?", messageID: "msg_user", sessionID: session.id),
                .local(role: "assistant", text: "I am checking the failing test now.", messageID: "msg_assistant", sessionID: session.id),
            ],
            sessionStatus: "busy"
        )

        let lines = LiveActivitySnapshotBuilder.transcriptLines(for: input)

        XCTAssertEqual(lines.map(\.role), ["assistant"])
        XCTAssertEqual(lines.map(\.text), ["I am checking the failing test now."])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testTranscriptUsesCachedMessagesForUnselectedActiveSession() {
        let session = makeSession(id: "ses_background")
        let input = makeInput(
            session: session,
            selectedSessionID: "ses_selected",
            cachedMessages: [
                .local(role: "user", text: "Ship it", messageID: "msg_user", sessionID: session.id),
                .local(role: "assistant", text: "Shipping now", messageID: "msg_assistant", sessionID: session.id),
            ],
            sessionStatus: "busy"
        )

        let lines = LiveActivitySnapshotBuilder.transcriptLines(for: input)

        XCTAssertEqual(lines.map(\.text), ["Shipping now"])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testStateProjectsPermissionInteraction() {
        let session = makeSession(id: "ses_live")
        let permission = OpenCodePermission(
            id: "perm_1",
            sessionID: session.id,
            permission: "bash",
            patterns: ["git status"],
            always: nil,
            metadata: nil,
            tool: nil
        )

        let state = LiveActivitySnapshotBuilder.state(for: makeInput(session: session, permissions: [permission]))

        XCTAssertEqual(state.status, "Action")
        XCTAssertEqual(state.pendingInteractionKind, "permission")
        XCTAssertEqual(state.interactionID, "perm_1")
        XCTAssertFalse(state.canReplyToQuestionInline)
    }

    func testBusyUserOnlyStateDoesNotGetStuckOnUserMessage() {
        let session = makeSession(id: "ses_live")
        let input = makeInput(
            session: session,
            selectedSessionID: session.id,
            selectedMessages: [
                .local(role: "user", text: "Please continue", messageID: "msg_user", sessionID: session.id),
            ],
            sessionStatus: "busy"
        )

        let state = LiveActivitySnapshotBuilder.state(for: input)

        XCTAssertEqual(state.latestSnippet, "Waiting for assistant...")
        XCTAssertTrue(state.transcriptLines.isEmpty)
    }

    func testTranscriptUsesReasoningTextWhenAnswerTextHasNotStarted() {
        let session = makeSession(id: "ses_live")
        let input = makeInput(
            session: session,
            selectedSessionID: session.id,
            selectedMessages: [
                message(
                    id: "msg_assistant",
                    role: "assistant",
                    sessionID: session.id,
                    parts: [part(id: "prt_reasoning", messageID: "msg_assistant", sessionID: session.id, type: "reasoning", text: "Checking the current implementation")]
                ),
            ],
            sessionStatus: "busy"
        )

        let lines = LiveActivitySnapshotBuilder.transcriptLines(for: input)

        XCTAssertEqual(lines.map(\.text), ["Checking the current implementation"])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testTranscriptUsesToolProgressWhenAssistantHasNoAnswerText() {
        let session = makeSession(id: "ses_live")
        let input = makeInput(
            session: session,
            selectedSessionID: session.id,
            selectedMessages: [
                message(
                    id: "msg_assistant",
                    role: "assistant",
                    sessionID: session.id,
                    parts: [
                        part(
                            id: "prt_tool",
                            messageID: "msg_assistant",
                            sessionID: session.id,
                            type: "tool",
                            tool: "bash",
                            state: OpenCodeToolState(status: "running", title: "Running tests", error: nil, input: nil, output: nil, metadata: nil)
                        )
                    ]
                ),
            ],
            sessionStatus: "busy"
        )

        let lines = LiveActivitySnapshotBuilder.transcriptLines(for: input)

        XCTAssertEqual(lines.map(\.text), ["Running tests"])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testStateProjectsSingleChoiceQuestionInteraction() {
        let session = makeSession(id: "ses_live")
        let question = OpenCodeQuestionRequest(
            id: "q_1",
            sessionID: session.id,
            questions: [
                OpenCodeQuestion(
                    question: "Proceed?",
                    header: "Question",
                    options: [
                        OpenCodeQuestionOption(label: "Yes", description: "Continue"),
                        OpenCodeQuestionOption(label: "No", description: "Stop"),
                    ]
                )
            ],
            tool: nil
        )

        let state = LiveActivitySnapshotBuilder.state(for: makeInput(session: session, questions: [question]))

        XCTAssertEqual(state.status, "Action")
        XCTAssertEqual(state.pendingInteractionKind, "question")
        XCTAssertEqual(state.interactionID, "q_1")
        XCTAssertEqual(state.questionOptionLabels, ["Yes", "No"])
        XCTAssertTrue(state.canReplyToQuestionInline)
    }

    func testStatesMatchIgnoresUpdatedAtOnly() {
        let session = makeSession(id: "ses_live")
        let first = LiveActivitySnapshotBuilder.state(for: makeInput(session: session), now: Date(timeIntervalSince1970: 1))
        let second = LiveActivitySnapshotBuilder.state(for: makeInput(session: session), now: Date(timeIntervalSince1970: 2))

        XCTAssertTrue(LiveActivitySnapshotBuilder.statesMatch(first, second))
    }

    func testShouldScheduleRefreshPolicy() {
        XCTAssertTrue(LiveActivitySnapshotBuilder.shouldScheduleRefresh(pendingRefreshExists: false, immediate: false, endIfIdle: false))
        XCTAssertFalse(LiveActivitySnapshotBuilder.shouldScheduleRefresh(pendingRefreshExists: true, immediate: false, endIfIdle: false))
        XCTAssertFalse(LiveActivitySnapshotBuilder.shouldScheduleRefresh(pendingRefreshExists: false, immediate: true, endIfIdle: false))
        XCTAssertFalse(LiveActivitySnapshotBuilder.shouldScheduleRefresh(pendingRefreshExists: false, immediate: false, endIfIdle: true))
    }

    private func makeInput(
        session: OpenCodeSession,
        selectedSessionID: String? = nil,
        selectedMessages: [OpenCodeMessageEnvelope] = [],
        cachedMessages: [OpenCodeMessageEnvelope] = [],
        sessionStatus: String? = nil,
        permissions: [OpenCodePermission] = [],
        questions: [OpenCodeQuestionRequest] = []
    ) -> LiveActivitySnapshotInput {
        LiveActivitySnapshotInput(
            session: session,
            sessionTitle: session.title ?? "Session",
            selectedSessionID: selectedSessionID,
            selectedMessages: selectedMessages,
            cachedMessages: cachedMessages,
            sessionStatus: sessionStatus,
            sessionPreviewText: nil,
            permissions: permissions,
            questions: questions
        )
    }

    private func makeSession(id: String) -> OpenCodeSession {
        OpenCodeSession(id: id, title: "Live", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
    }

    private func message(id: String, role: String, sessionID: String, parts: [OpenCodePart]) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: parts
        )
    }

    private func part(
        id: String,
        messageID: String,
        sessionID: String,
        type: String,
        text: String? = nil,
        tool: String? = nil,
        state: OpenCodeToolState? = nil
    ) -> OpenCodePart {
        OpenCodePart(
            id: id,
            messageID: messageID,
            sessionID: sessionID,
            type: type,
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: tool,
            callID: nil,
            state: state,
            text: text
        )
    }
}
#endif
