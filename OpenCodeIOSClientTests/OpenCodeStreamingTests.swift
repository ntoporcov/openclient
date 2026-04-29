import XCTest
@testable import OpenClient

final class OpenCodeStreamingTests: XCTestCase {
    func testSSEParserBuildsEventFromRawLines() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: "event: message.part.delta").isEmpty)
        XCTAssertTrue(parser.process(line: "data: {\"type\":\"message.part.delta\"}").isEmpty)

        let event = parser.process(line: "").first
        XCTAssertEqual(event?.type, "message.part.delta")
        XCTAssertEqual(event?.data, #"{"type":"message.part.delta"}"#)
    }

    func testSSEParserPreservesLeadingSpaceInDataAfterFieldSeparator() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: "event: message.part.delta").isEmpty)
        XCTAssertTrue(parser.process(line: "data:  leading space").isEmpty)

        let event = parser.process(line: "").first
        XCTAssertEqual(event?.data, " leading space")
    }

    func testSSEParserJoinsMultipleDataLines() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: "event: message").isEmpty)
        XCTAssertTrue(parser.process(line: "data: line one").isEmpty)
        XCTAssertTrue(parser.process(line: "data: line two").isEmpty)

        let event = parser.process(line: "").first
        XCTAssertEqual(event?.type, "message")
        XCTAssertEqual(event?.data, "line one\nline two")
    }

    func testSSEParserIgnoresCommentLines() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: ": ping").isEmpty)
        XCTAssertTrue(parser.process(line: "event: session.idle").isEmpty)
        XCTAssertTrue(parser.process(line: "data: {\"type\":\"session.idle\"}").isEmpty)

        let event = parser.process(line: "").first
        XCTAssertEqual(event?.type, "session.idle")
    }

    func testSSEParserFlushesConsecutiveJSONDataLinesWithoutBlankSeparator() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: "data: {\"type\":\"server.connected\"}").isEmpty)
        let events = parser.process(line: "data: {\"type\":\"session.diff\"}")

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, #"{"type":"server.connected"}"#)

        let trailing = parser.process(line: "")
        XCTAssertEqual(trailing.first?.data, #"{"type":"session.diff"}"#)
    }

    func testReducerBuildsAssistantMessageFromUpdatedAndDeltaEvents() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let partUpdated = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":""}}}"#
        )
        let delta1 = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )
        let delta2 = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":" world"}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: partUpdated, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: delta1, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: delta2, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].info.id, "msg_assistant")
        XCTAssertEqual(messages[0].parts.first?.text, "Hello world")
    }

    func testReducerMarksSessionIdleForReload() throws {
        let payload = try decodeEvent(
            #"{"type":"session.idle","properties":{"sessionID":"ses_test"}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])
        XCTAssertTrue(update.shouldReload)
    }

    func testReducerIgnoresOtherSessions() throws {
        let payload = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_other","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_other"}}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])
        XCTAssertTrue(update.messages.isEmpty)
        XCTAssertFalse(update.shouldReload)
    }

    func testReducerHandlesCapturedLocalStreamingSequence() throws {
        let sessionID = "ses_256f9ad04ffeLgT3eAydjN4nF7"
        let events = [
            #"{"type":"message.updated","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","info":{"id":"msg_da90cc122001BnWCARPndu7l9S","role":"assistant","sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7"}}}"#,
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","part":{"id":"prt_da90cd0c6001up6XLstCviVA31","messageID":"msg_da90cc122001BnWCARPndu7l9S","sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","type":"text","text":""}}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","messageID":"msg_da90cc122001BnWCARPndu7l9S","partID":"prt_da90cd0c6001up6XLstCviVA31","field":"text","delta":"S"}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","messageID":"msg_da90cc122001BnWCARPndu7l9S","partID":"prt_da90cd0c6001up6XLstCviVA31","field":"text","delta":"SE"}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","messageID":"msg_da90cc122001BnWCARPndu7l9S","partID":"prt_da90cd0c6001up6XLstCviVA31","field":"text","delta":" test"}}"#,
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7","messageID":"msg_da90cc122001BnWCARPndu7l9S","partID":"prt_da90cd0c6001up6XLstCviVA31","field":"text","delta":" ok"}}"#,
            #"{"type":"session.idle","properties":{"sessionID":"ses_256f9ad04ffeLgT3eAydjN4nF7"}}"#
        ]

        var messages: [OpenCodeMessageEnvelope] = []
        var sawReload = false

        for json in events {
            let payload = try decodeEvent(json)
            let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: sessionID, messages: messages)
            messages = update.messages
            sawReload = sawReload || update.shouldReload
        }

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.first?.text, "SSE test ok")
        XCTAssertTrue(sawReload)
    }

    func testCanonicalMergePreservesLongerStreamedText() throws {
        let streamed = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello world")
            ]
        )
        let canonical = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
            ]
        )

        let merged = streamed.mergedWithCanonical(canonical)

        XCTAssertEqual(merged.parts.first?.text, "Hello world")
    }

    func testCanonicalMergeAcceptsNewerCompletedText() throws {
        let streamed = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello")
            ]
        )
        let canonical = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello world")
            ]
        )

        let merged = streamed.mergedWithCanonical(canonical)

        XCTAssertEqual(merged.parts.first?.text, "Hello world")
    }

    func testSessionUpdatedPreservesExistingDirectoryWhenEventIsPartial() {
        let existingSession = OpenCodeSession(
            id: "ses_test",
            title: "Original",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_1",
            parentID: nil
        )
        let partialUpdate = OpenCodeSession(
            id: "ses_test",
            title: "Renamed",
            workspaceID: nil,
            directory: nil,
            projectID: nil,
            parentID: nil
        )
        var state = OpenCodeDirectoryState(
            sessions: [existingSession],
            selectedSession: existingSession,
            messages: [],
            sessionStatuses: [:],
            todos: [],
            permissions: [],
            questions: []
        )

        let result = OpenCodeStateReducer.applyDirectoryEvent(event: .sessionUpdated(partialUpdate), state: &state)

        guard case .sessionChanged = result else {
            return XCTFail("Expected sessionChanged, got \(result)")
        }
        XCTAssertEqual(state.sessions.first?.title, "Renamed")
        XCTAssertEqual(state.sessions.first?.directory, "/tmp/project")
        XCTAssertEqual(state.selectedSession?.directory, "/tmp/project")
    }

    func testQuestionAskedDecodesWithUpstreamOptionalDefaults() throws {
        let payload = try decodeEvent(
            #"{"type":"question.asked","properties":{"id":"q_1","sessionID":"ses_test","questions":[{"question":"Choose","header":"Question","options":[{"label":"Build","description":"Build it"}]}]}}"#
        )

        guard case let .questionAsked(request) = try XCTUnwrap(OpenCodeTypedEvent(envelope: payload)) else {
            return XCTFail("Expected questionAsked typed event")
        }

        XCTAssertEqual(request.id, "q_1")
        XCTAssertEqual(request.sessionID, "ses_test")
        XCTAssertEqual(request.questions.count, 1)
        XCTAssertFalse(request.questions[0].multiple)
        XCTAssertEqual(request.questions[0].custom, true)
    }

    func testQuestionAskedReducerStoresQuestionWhenOptionalFieldsOmitted() throws {
        let payload = try decodeEvent(
            #"{"type":"question.asked","properties":{"id":"q_1","sessionID":"ses_test","questions":[{"question":"Choose","header":"Question","options":[{"label":"Build","description":"Build it"}]}]}}"#
        )

        guard let typed = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected questionAsked typed event")
        }

        var state = OpenCodeDirectoryState(
            sessions: [],
            selectedSession: OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil),
            messages: [],
            commands: [],
            sessionStatuses: [:],
            todos: [],
            permissions: [],
            questions: []
        )

        let result = OpenCodeStateReducer.applyDirectoryEvent(event: typed, state: &state)

        guard case .questionChanged = result else {
            return XCTFail("Expected questionChanged, got \(result)")
        }
        XCTAssertEqual(state.questions.map(\.id), ["q_1"])
    }

    func testManagedEventDecodeReportsDroppedQuestionPayloads() {
        let result = OpenCodeEventManager.decodeManagedEvent(
            from: #"{"directory":"/tmp/project","type":"question.asked","properties":{"id":"q_1","sessionID":"ses_test"}}"#
        )

        guard case let .dropped(message) = result else {
            return XCTFail("Expected dropped result")
        }
        XCTAssertEqual(message, "drop event: untyped question.asked dir=/tmp/project")
    }

    func testManagedEventDecodeBuildsQuestionEventForValidPayload() {
        let result = OpenCodeEventManager.decodeManagedEvent(
            from: #"{"directory":"/tmp/project","type":"question.asked","properties":{"id":"q_1","sessionID":"ses_test","questions":[{"question":"Choose","header":"Question","options":[{"label":"Build","description":"Build it"}]}]}}"#
        )

        guard case let .event(managed) = result else {
            return XCTFail("Expected managed event")
        }
        XCTAssertEqual(managed.directory, "/tmp/project")
        XCTAssertEqual(managed.envelope.type, "question.asked")
        guard case let .questionAsked(question) = managed.typed else {
            return XCTFail("Expected questionAsked typed event")
        }
        XCTAssertEqual(question.id, "q_1")
    }

    func testReducerCreatesPlaceholderWhenDeltaArrivesBeforeMessageShell() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])

        XCTAssertEqual(update.messages.count, 1)
        XCTAssertEqual(update.messages[0].info.id, "msg_assistant")
        XCTAssertEqual(update.messages[0].info.role, "assistant")
        XCTAssertEqual(update.messages[0].parts.first?.id, "prt_text")
        XCTAssertEqual(update.messages[0].parts.first?.text, "Hello")
    }

    func testReducerIgnoresDeltaMissingPartID() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","field":"text","delta":"Hello"}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])

        XCTAssertTrue(update.messages.isEmpty)
        XCTAssertFalse(update.applied)
        XCTAssertEqual(update.reason, "missing delta target")
    }

    func testReducerDoesNotDuplicateRepeatedPartUpdates() throws {
        let first = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":"Hello"}}}"#
        )
        let second = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":"Hello world"}}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: first, selectedSessionID: "ses_test", messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: second, selectedSessionID: "ses_test", messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts.first?.text, "Hello world")
    }

    func testPartRemovedForMissingMessageDoesNotMutateSelectedChat() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var state = OpenCodeDirectoryState(
            sessions: [],
            selectedSession: selected,
            messages: [.local(role: "assistant", text: "Keep me", messageID: "msg_keep", sessionID: selected.id, partID: "prt_keep")],
            commands: [],
            sessionStatuses: [:],
            todos: [],
            permissions: [],
            questions: []
        )

        let result = OpenCodeStateReducer.applyDirectoryEvent(event: .messagePartRemoved(messageID: "msg_other", partID: "prt_other"), state: &state)

        guard case .ignored = result else {
            return XCTFail("Expected ignored result, got \(result)")
        }
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages.first?.id, "msg_keep")
        XCTAssertEqual(state.messages.first?.parts.count, 1)
    }

    private func decodeEvent(_ json: String) throws -> OpenCodeEventEnvelope {
        try JSONDecoder().decode(OpenCodeEventEnvelope.self, from: Data(json.utf8))
    }
}
