import XCTest
@testable import OpenCodeIOSClient

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
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: "Hello world")
            ]
        )
        let canonical = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: "")
            ]
        )

        let merged = streamed.mergedWithCanonical(canonical)

        XCTAssertEqual(merged.parts.first?.text, "Hello world")
    }

    func testCanonicalMergeAcceptsNewerCompletedText() throws {
        let streamed = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: "Hello")
            ]
        )
        let canonical = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil),
            parts: [
                OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: "Hello world")
            ]
        )

        let merged = streamed.mergedWithCanonical(canonical)

        XCTAssertEqual(merged.parts.first?.text, "Hello world")
    }

    private func decodeEvent(_ json: String) throws -> OpenCodeEventEnvelope {
        try JSONDecoder().decode(OpenCodeEventEnvelope.self, from: Data(json.utf8))
    }
}
