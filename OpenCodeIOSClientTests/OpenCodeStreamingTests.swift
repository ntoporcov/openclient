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

    func testLiveMessageEventGateDropsInactiveTranscriptEvents() {
        XCTAssertFalse(AppViewModel.shouldProcessLiveMessageEvent(
            eventType: "message.part.delta",
            eventSessionID: "ses_background",
            activeChatSessionID: "ses_current",
            activeLiveActivitySessionIDs: [],
            affectsSelectedTranscript: false
        ))

        XCTAssertTrue(AppViewModel.shouldProcessLiveMessageEvent(
            eventType: "message.part.delta",
            eventSessionID: "ses_current",
            activeChatSessionID: "ses_current",
            activeLiveActivitySessionIDs: [],
            affectsSelectedTranscript: false
        ))
    }

    func testLiveMessageEventGateKeepsLiveActivitiesAndStatusEvents() {
        XCTAssertTrue(AppViewModel.shouldProcessLiveMessageEvent(
            eventType: "message.part.delta",
            eventSessionID: "ses_background",
            activeChatSessionID: "ses_current",
            activeLiveActivitySessionIDs: ["ses_background"],
            affectsSelectedTranscript: false
        ))

        XCTAssertTrue(AppViewModel.shouldProcessLiveMessageEvent(
            eventType: "session.status",
            eventSessionID: "ses_background",
            activeChatSessionID: "ses_current",
            activeLiveActivitySessionIDs: [],
            affectsSelectedTranscript: false
        ))
    }

    func testLiveActivityRefreshSchedulingThrottlesInsteadOfDebouncing() {
        XCTAssertTrue(AppViewModel.shouldScheduleLiveActivityRefresh(
            pendingRefreshExists: false,
            immediate: false,
            endIfIdle: false
        ))

        XCTAssertFalse(AppViewModel.shouldScheduleLiveActivityRefresh(
            pendingRefreshExists: true,
            immediate: false,
            endIfIdle: false
        ))

        XCTAssertFalse(AppViewModel.shouldScheduleLiveActivityRefresh(
            pendingRefreshExists: false,
            immediate: true,
            endIfIdle: false
        ))
    }

    func testPermissionAndQuestionEventsRefreshLiveActivitiesImmediately() {
        XCTAssertTrue(AppViewModel.shouldRefreshLiveActivityImmediately(
            after: .permissionChanged,
            event: .unknown("permission.asked")
        ))

        XCTAssertTrue(AppViewModel.shouldRefreshLiveActivityImmediately(
            after: .questionChanged,
            event: .unknown("question.asked")
        ))

        XCTAssertTrue(AppViewModel.shouldRefreshLiveActivityImmediately(
            after: .statusChanged,
            event: .permissionReplied(sessionID: "ses_live", requestID: "perm_1", reply: nil)
        ))

        XCTAssertTrue(AppViewModel.shouldRefreshLiveActivityImmediately(
            after: .statusChanged,
            event: .questionRejected(sessionID: "ses_live", requestID: "q_1")
        ))

        XCTAssertFalse(AppViewModel.shouldRefreshLiveActivityImmediately(
            after: .message("delta applied"),
            event: .messagePartDelta(sessionID: "ses_live", messageID: "msg_1", partID: "prt_1", field: "text", delta: "Hello")
        ))
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

    func testLargeMessageChunkerSplitsCapturedPerformanceSessionShape() throws {
        let text = Self.capturedPerformanceSessionText
        let message = Self.performanceSessionMessage(text: text)

        let textPart = try XCTUnwrap(OpenCodeLargeMessageChunker.chunkTextPart(in: message))
        let chunks = try XCTUnwrap(OpenCodeLargeMessageChunker.chunks(for: message))

        XCTAssertEqual(message.info.id, "msg_dde1491d8001Kl4SJDttx88s3j")
        XCTAssertEqual(message.parts.map(\.type), ["step-start", "reasoning", "text", "step-finish"])
        XCTAssertEqual(textPart.id, "prt_dde14a290001Hg6qh7Mm21YINd")
        XCTAssertGreaterThan(text.count, OpenCodeLargeMessageChunker.minimumCharacterCount)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.first?.text.hasPrefix("## 1. Why AI Chat UI Performance Is Different"), true)
        XCTAssertEqual(chunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(text))
        XCTAssertTrue(chunks.dropLast().allSatisfy { !$0.isTail })
        XCTAssertEqual(chunks.last?.isTail, true)
    }

    func testLargeMessageChunkerAllowsCompletedSessionOutputWithoutStreamingState() throws {
        let message = Self.performanceSessionMessage(text: Self.capturedPerformanceSessionText)

        let chunks = try XCTUnwrap(OpenCodeLargeMessageChunker.chunks(for: message))

        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testLargeMessageChunkerRejectsRenderableNonTextParts() {
        var message = Self.performanceSessionMessage(text: Self.capturedPerformanceSessionText)
        message.parts[1] = Self.part(id: "prt_reasoning", messageID: message.id, type: "reasoning", text: "Visible reasoning")

        XCTAssertNil(OpenCodeLargeMessageChunker.chunks(for: message))
    }

    func testLargeMessageChunkerRejectsToolMessages() {
        var message = Self.performanceSessionMessage(text: Self.capturedPerformanceSessionText)
        message.parts.insert(Self.part(id: "prt_tool", messageID: message.id, type: "tool", text: nil), at: 2)

        XCTAssertNil(OpenCodeLargeMessageChunker.chunks(for: message))
    }

    func testLargeMessageChunkerSplitsMarkdownListsAtItemBoundaries() throws {
        let recommendations = (1...40)
            .map { "\($0). Recommendation \($0) keeps list semantics inside a markdown-safe chunk row." }
            .joined(separator: "\n")
        let text = """
Intro paragraph before the list so the message is chunkable.

\(recommendations)

Closing paragraph after the list.
"""

        let chunks = OpenCodeLargeMessageChunker.makeChunks(from: text)
        let listChunks = chunks.filter { $0.text.contains("1. Recommendation") || $0.text.contains("40. Recommendation") }

        XCTAssertGreaterThan(listChunks.count, 1)
        XCTAssertTrue(listChunks[0].text.contains("1. Recommendation 1"))
        XCTAssertTrue(listChunks[listChunks.count - 1].text.contains("40. Recommendation 40"))
        XCTAssertTrue(listChunks.allSatisfy { chunk in
            chunk.text
                .split(separator: "\n")
                .allSatisfy { OpenCodeLargeMessageChunker.isMarkdownListLine(String($0)) }
        })
    }

    func testLargeMessageChunkerKeepsCodeAndQuotesInOwnChunks() throws {
        let quote = (1...12)
            .map { "> Quote line \($0) stays with the surrounding quote block." }
            .joined(separator: "\n")
        let code = """
```swift
func render(_ value: String) {
    print(value)
}
```
"""
        let text = """
Intro paragraph before structured markdown.

\(quote)

\(code)

Closing paragraph after structured markdown.
"""

        let chunks = OpenCodeLargeMessageChunker.makeChunks(from: text)
        let quoteChunks = chunks.filter { $0.text.contains("> Quote line") }
        let codeChunks = chunks.filter { $0.text.contains("```swift") }

        XCTAssertEqual(quoteChunks.count, 1)
        XCTAssertTrue(quoteChunks[0].text.contains("> Quote line 1"))
        XCTAssertTrue(quoteChunks[0].text.contains("> Quote line 12"))
        XCTAssertEqual(codeChunks.count, 1)
        XCTAssertTrue(codeChunks[0].text.contains("func render"))
        XCTAssertEqual(chunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(text))
    }

    func testLargeMessageChunkCachePreservesFrozenChunksOnAppend() throws {
        let cache = OpenCodeLargeMessageChunkCache()
        let initialText = Self.capturedPerformanceSessionText
        let appendedText = initialText + """


## 3. Cached Tail Work

This appended section simulates more streamed text arriving after some chunks have already become stable. The existing frozen rows should keep their ids and text while the cache only recomputes the mutable tail segment.
"""
        let initialMessage = Self.performanceSessionMessage(text: initialText)
        let appendedMessage = Self.performanceSessionMessage(text: appendedText)

        let initialChunks = try XCTUnwrap(cache.chunks(for: initialMessage))
        let appendedChunks = try XCTUnwrap(cache.chunks(for: appendedMessage))
        let statelessChunks = try XCTUnwrap(OpenCodeLargeMessageChunker.chunks(for: appendedMessage))

        XCTAssertGreaterThan(initialChunks.count, 1)
        XCTAssertEqual(appendedChunks, statelessChunks)
        XCTAssertEqual(Array(appendedChunks.prefix(initialChunks.count - 1)), Array(initialChunks.dropLast()))
        XCTAssertEqual(appendedChunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(appendedText))
    }

    func testLargeMessageChunkCacheFallsBackWhenTextIsRewritten() throws {
        let cache = OpenCodeLargeMessageChunkCache()
        let initialMessage = Self.performanceSessionMessage(text: Self.capturedPerformanceSessionText)
        let rewrittenText = Self.capturedPerformanceSessionText.replacingOccurrences(
            of: "Performance engineering",
            with: "Rendering performance",
            options: [],
            range: Self.capturedPerformanceSessionText.startIndex..<Self.capturedPerformanceSessionText.endIndex
        )
        let rewrittenMessage = Self.performanceSessionMessage(text: rewrittenText)

        _ = try XCTUnwrap(cache.chunks(for: initialMessage))
        let rewrittenChunks = try XCTUnwrap(cache.chunks(for: rewrittenMessage))

        XCTAssertEqual(rewrittenChunks, OpenCodeLargeMessageChunker.chunks(for: rewrittenMessage))
        XCTAssertEqual(rewrittenChunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(rewrittenText))
    }

    func testLargeMessageChunkCacheKeepsCompletedMessagesChunked() throws {
        let cache = OpenCodeLargeMessageChunkCache()
        let message = Self.performanceSessionMessage(text: Self.capturedPerformanceSessionText)

        let chunks = try XCTUnwrap(cache.chunks(for: message, isStreaming: false))

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(Self.capturedPerformanceSessionText))
    }

    func testLargeMessageChunkCacheFreezesPrefixMidStream() throws {
        let cache = OpenCodeLargeMessageChunkCache()
        let paragraph = String(repeating: "This completed paragraph should become a frozen markdown row once the next block starts. ", count: 10)
        let initialText = """
## Stable Heading

\(paragraph)

1. First streamed item has enough text to be useful but should remain inside its list item.
"""
        let appendedItems = (2...30)
            .map { "\($0). Streamed item \($0) can be grouped with nearby complete list items." }
            .joined(separator: "\n")
        let appendedText = initialText + "\n" + appendedItems
        let initialMessage = Self.performanceSessionMessage(text: initialText)
        let appendedMessage = Self.performanceSessionMessage(text: appendedText)

        let initialChunks = try XCTUnwrap(cache.chunks(for: initialMessage))
        let frozenPrefix = Array(initialChunks.dropLast())
        let appendedChunks = try XCTUnwrap(cache.chunks(for: appendedMessage))

        XCTAssertGreaterThan(frozenPrefix.count, 0)
        XCTAssertEqual(Array(appendedChunks.prefix(frozenPrefix.count)), frozenPrefix)
        XCTAssertGreaterThan(appendedChunks.count, initialChunks.count)
        XCTAssertEqual(appendedChunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(appendedText))
    }

    private func decodeEvent(_ json: String) throws -> OpenCodeEventEnvelope {
        try JSONDecoder().decode(OpenCodeEventEnvelope.self, from: Data(json.utf8))
    }

    private static func performanceSessionMessage(text: String) -> OpenCodeMessageEnvelope {
        let messageID = "msg_dde1491d8001Kl4SJDttx88s3j"
        let sessionID = "ses_221eb7f4cffepRCHpKa51GEnbY"

        return OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                part(id: "prt_step_start", messageID: messageID, sessionID: sessionID, type: "step-start", text: nil),
                part(id: "prt_reasoning", messageID: messageID, sessionID: sessionID, type: "reasoning", text: ""),
                part(id: "prt_dde14a290001Hg6qh7Mm21YINd", messageID: messageID, sessionID: sessionID, type: "text", text: text),
                part(id: "prt_step_finish", messageID: messageID, sessionID: sessionID, type: "step-finish", text: nil)
            ]
        )
    }

    private static func part(
        id: String,
        messageID: String,
        sessionID: String = "ses_221eb7f4cffepRCHpKa51GEnbY",
        type: String,
        text: String?
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
            tool: nil,
            callID: nil,
            state: nil,
            text: text
        )
    }

    private static let capturedPerformanceSessionText = """
## 1. Why AI Chat UI Performance Is Different

Performance engineering for AI chat interfaces is not the same as performance engineering for a typical CRUD app, document editor, or social feed. A chat UI is deceptively simple: messages go in, messages come out, the user scrolls. But AI chat adds a difficult combination of workload patterns: long-lived streaming responses, rapidly mutating text, syntax-highlighted code blocks, markdown rendering, attachments, tool events, citations, retries, partial failures, and conversation histories that can grow without a natural upper bound.

The hardest part is that the UI is expected to feel alive while doing a large amount of incremental work. Every token, sentence, paragraph, table row, or code block can cause layout invalidation. If the renderer naively reparses the entire assistant message on every chunk, it can create a death spiral: more text means more parsing, more parsing means slower frames, slower frames delay updates, delayed updates accumulate, and accumulated updates cause even larger rendering bursts.

Mobile makes this worse. The CPU is slower, thermal limits matter, memory pressure is real, and the input system is more sensitive to dropped frames. A desktop web chat can sometimes get away with inefficient markdown rendering or oversized DOM trees. A mobile chat feed usually cannot. The feed must preserve scrolling fluidity while handling unbounded content and maintaining a responsive composer, keyboard, attachment picker, and navigation shell.

| Concern | Traditional Chat | AI Chat UI |
|---|---:|---:|
| Message size | Usually small | Often very large |
| Update frequency | Per message | Per token or chunk |
| Rendering cost | Mostly static text | Markdown, code, tables |
| Scroll behavior | Predictable | Streaming changes height |
| Failure modes | Send failed | Stream interrupted, retry, partial tool state |
| Memory growth | Moderate | Potentially unbounded |

## 2. The Streaming Rendering Pipeline

A robust AI chat UI should treat streaming as a pipeline, not as a series of immediate UI mutations. The network layer receives bytes or events. The protocol layer converts those into structured chunks. The aggregation layer appends them into a message model. The rendering layer decides when and how much of that model to present. The layout layer measures and displays it. The scroll controller decides whether the viewport should follow the newest content.

The common mistake is to couple all of these layers together. For example, a WebSocket event arrives, appends a token to a string, reparses markdown, updates React or SwiftUI state, invalidates the list, measures every row, and scrolls to bottom. That might work for a short response, but it will break under stress when the assistant produces long tables, large code blocks, or thousands of tokens.

A better model is to buffer aggressively and render intentionally. Incoming stream chunks should be cheap to receive. The UI should commit updates at a controlled cadence, often aligned with animation frames or a small interval such as 30 to 100 milliseconds. This reduces layout churn while preserving the perception of streaming. Humans do not need every token rendered instantly; they need progress to feel continuous and the interface to remain responsive.
"""
}
