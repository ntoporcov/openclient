import Combine
import XCTest
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenClient

final class OpenCodeStreamingTests: XCTestCase {
    func testSSEByteFramingDispatchesWithoutWaitingForAnotherEvent() {
        for separator in ["\n", "\r\n", "\r"] {
            var lines = OpenCodeSSELineDecoder()
            var parser = OpenCodeSSEParser()
            var events: [OpenCodeServerEvent] = []
            let payload = #"{"id":"evt_connected","type":"server.connected","data":{}}"#
            for byte in ("data: " + payload + separator + separator).utf8 {
                if let line = lines.process(byte: byte) {
                    events.append(contentsOf: parser.process(line: line))
                }
            }
            XCTAssertEqual(events.count, 1, "Separator: \(separator.debugDescription)")
            XCTAssertEqual(events.first?.data, payload)
        }
    }

    func testSSEByteFramingPreservesBlankLinesAndSplitUTF8() {
        var decoder = OpenCodeSSELineDecoder()
        let lines = "\u{FEFF}data: caf\u{E9}\r\n\r\n: heartbeat\n\ndata: end\n\n".utf8.compactMap {
            decoder.process(byte: $0)
        }
        XCTAssertEqual(lines, ["data: caf\u{E9}", "", ": heartbeat", "", "data: end", ""])
    }

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

    func testSSEParserCarriesEventIDAndRetryMetadata() {
        var parser = OpenCodeSSEParser()

        XCTAssertTrue(parser.process(line: "id: evt_123").isEmpty)
        XCTAssertTrue(parser.process(line: "retry: 2500").isEmpty)
        XCTAssertTrue(parser.process(line: "data: {\"type\":\"session.execution.started\"}").isEmpty)

        let event = parser.process(line: "").first
        XCTAssertEqual(event?.id, "evt_123")
        XCTAssertEqual(event?.retry, 2_500)
    }

    func testV2ManagedEventDecodesExecutionSessionAndLocation() throws {
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"id":"evt_1","created":1234,"type":"session.execution.started","location":{"directory":"/tmp/project","workspaceID":"wrk_1"},"data":{"sessionID":"ses_1"}}"#))

        XCTAssertEqual(event.id, "evt_1")
        XCTAssertEqual(event.type, "session.execution.started")
        XCTAssertEqual(event.location?.directory, "/tmp/project")
        XCTAssertEqual(event.location?.workspaceID, "wrk_1")
        XCTAssertEqual(event.sessionID, "ses_1")
        XCTAssertTrue(event.isExecutionStarted)
        XCTAssertFalse(event.isExecutionTerminal)
    }

    func testV2ManagedEventRecognizesTerminalExecutionEvents() throws {
        for type in ["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"\#(type)","data":{"sessionID":"ses_1"}}"#))
            XCTAssertTrue(event.isExecutionTerminal, type)
        }
    }

    func testV2MovedEventRoutesToPayloadLocationRatherThanPreviousEnvelopeLocation() throws {
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.moved","location":{"directory":"/old","workspaceID":"wrk_old"},"data":{"sessionID":"ses_1","location":{"directory":"/new"},"projectID":"proj_new"}}"#))
        XCTAssertEqual(event.routingLocation?.directory, "/new")
        XCTAssertNil(event.routingLocation?.workspaceID)
    }

    func testV2InvalidOrdinalsCannotTrapOrTruncate() throws {
        for ordinal in ["1e100", "0.5", "-0.5"] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.text.delta","data":{"sessionID":"ses_1","assistantMessageID":"msg_1","ordinal":\#(ordinal),"delta":"x"}}"#))
            XCTAssertNil(event.data.objectValue?["ordinal"]?.intValue)
        }
    }

    func testV217155InputBoundaryRejectsMixedContractsAndMalformedPayloads() throws {
        for raw in [
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_1","inboxID":"msg_1","item":{"type":"user","payload":{"text":"wrong contract"}}}}"#,
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_1","inputID":"msg_1","input":{"type":"future","data":{"text":"not a user message"}}}}"#,
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_1","inputID":"msg_1","input":{"type":"user","data":{"text":123}}}}"#,
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_1","inputID":"msg_1","input":{"type":"user","data":{"text":"File","files":[{"uri":"file:///tmp/a"}]}}}}"#,
        ] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw))
            XCTAssertNil(event.admittedInput)
        }
        let unverified = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.input.delivered","data":{"sessionID":"ses_1","inputID":"msg_1"}}"#))
        XCTAssertNil(unverified.inputID, "Neither next-17155's OpenAPI nor its publisher defines this alias")
        for type in ["session.input.promoted", "session.input.cancelled", "session.inbox.delivered", "session.inbox.cancelled"] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"\#(type)","data":{"sessionID":"ses_1"}}"#))
            XCTAssertTrue(event.affectsTranscript)
        }
    }

    @MainActor
    func testV217155SSEPublishesInputAndAssistantThroughHandlerWithoutRefresh() async throws {
        let model = AppViewModel()
        model.config = OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: "", apiPreference: .v2)
        model.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        let session = OpenCodeSession(id: "ses_1", title: "Streaming", workspaceID: nil,
            directory: "/tmp/project", projectID: "project", parentID: nil)
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        model.activeChatSessionID = session.id
        model.chatStore.beginV2TranscriptHydration(sessionID: session.id)
        model.chatStore.applyInitialV2Transcript([], olderCursor: nil, sessionID: session.id)
        let facade = model.chatFacade
        let directory = model.directoryStore
        let manager = OpenCodeEventManager()
        defer {
            manager.stop()
            model.stopEventStream()
            model.resetLocalCacheRuntimeState()
        }

        // Vocabulary/payloads audited in next-17155 schema/session-event.ts and
        // core/session/runner/publish-llm-event.ts. These are fixtures, not provider execution.
        let facts: [(String, String)] = [
            ("session.input.admitted", #""inputID":"msg_user","input":{"type":"user","delivery":"steer","data":{"text":"Hello"}}"#),
            ("session.input.promoted", #""inputID":"msg_user""#),
            ("session.step.started", #""assistantMessageID":"msg_assistant","agent":"build","model":{"id":"model","providerID":"provider"}"#),
            ("session.reasoning.started", #""assistantMessageID":"msg_assistant","ordinal":0"#),
            ("session.reasoning.delta", #""assistantMessageID":"msg_assistant","ordinal":0,"delta":"Think""#),
            ("session.reasoning.ended", #""assistantMessageID":"msg_assistant","ordinal":0,"text":"Thought""#),
            ("session.tool.input.started", #""assistantMessageID":"msg_assistant","id":"call_1","name":"read""#),
            ("session.tool.input.delta", #""assistantMessageID":"msg_assistant","id":"call_1","delta":"{""#),
            ("session.tool.input.ended", #""assistantMessageID":"msg_assistant","id":"call_1","text":"{}""#),
            ("session.tool.called", #""assistantMessageID":"msg_assistant","id":"call_1","input":{},"executed":false"#),
            ("session.tool.progress", #""assistantMessageID":"msg_assistant","id":"call_1","metadata":{"description":"Reading"}"#),
            ("session.tool.success", #""assistantMessageID":"msg_assistant","id":"call_1","content":[{"type":"text","text":"Read result"}],"executed":false"#),
            ("session.text.started", #""assistantMessageID":"msg_assistant","ordinal":0"#),
            ("session.text.delta", #""assistantMessageID":"msg_assistant","ordinal":0,"delta":"Hello""#),
            ("session.text.delta", #""assistantMessageID":"msg_assistant","ordinal":0,"delta":" world""#),
            ("session.text.ended", #""assistantMessageID":"msg_assistant","ordinal":0,"text":"Hello world!""#),
            ("session.step.ended", #""assistantMessageID":"msg_assistant","finish":"stop","cost":0,"tokens":{"input":1,"output":2,"reasoning":1,"cache":{"read":0,"write":0}}"#),
        ]
        let delivered = expectation(description: "All fixture events reach the production handler")
        delivered.expectedFulfillmentCount = facts.count
        let streamed = expectation(description: "Visible text arrives before its canonical end")
        let client = OpenCodeAPIClient(config: model.config)
        manager.startV2(client: client, onStatus: { _ in }, onDroppedEvent: { message in
            XCTFail(message)
        }, consume: { _, _, _, _, emit in
            var lines = OpenCodeSSELineDecoder()
            var parser = OpenCodeSSEParser()
            var seq = 0
            for (index, fact) in facts.enumerated() {
                let (type, fields) = fact
                let ephemeral = type.hasSuffix(".delta") || type == "session.tool.progress"
                if !ephemeral { seq += 1 }
                let durable = ephemeral ? "" : #", "durable":{"aggregateID":"ses_1","seq":\#(seq),"version":\#(type == "session.tool.success" ? 2 : 1)}"#
                let raw = #"{"id":"evt_\#(index)","created":\#(1000 + index),"type":"\#(type)"\#(durable),"location":{"directory":"/tmp/project"},"data":{"sessionID":"ses_1",\#(fields)}}"#
                for byte in ("data: " + raw + "\n\n").utf8 {
                    if let line = lines.process(byte: byte) {
                        for event in parser.process(line: line) { await emit(event) }
                    }
                }
            }
            try? await Task.sleep(for: .seconds(60))
        }, onEvent: { event in
            await MainActor.run {
                model.handleV2Event(event)
                if event.type == "session.text.delta", event.data.objectValue?["delta"]?.literalStringValue == " world" {
                    XCTAssertEqual(facade.messageSource(for: session).last?.parts.last?.text, "Hello world")
                    streamed.fulfill()
                }
                delivered.fulfill()
            }
        })
        await fulfillment(of: [delivered, streamed], timeout: 2)
        await manager.stopAndWait()
        XCTAssertNil(model.v2TimelineReconcileTask, "Successfully projected events must not depend on HTTP refresh")
        XCTAssertFalse(model.isV2TimelineReconcilePending)
        XCTAssertEqual(model.messages.map(\.id), ["msg_user", "msg_assistant"])
        let assistant = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(assistant.parts.map(\.type), ["reasoning", "tool", "text"])
        XCTAssertEqual(assistant.parts[0].text, "Thought")
        XCTAssertEqual(assistant.parts[1].state?.status, "completed")
        XCTAssertEqual(assistant.parts[2].text, "Hello world!")
        XCTAssertNotNil(assistant.info.time?.completed)
        XCTAssertEqual(directory.syncStore.messageEnvelopes(forSessionID: session.id, suffix: 2), model.messages)
        XCTAssertEqual(facade.messageSource(for: session), model.messages)
    }

    func testHeartbeatOwnershipCancelsAndJoinsConsumerWithParent() async {
        let started = XCTestExpectation(description: "consumer started")
        let ended = XCTestExpectation(description: "consumer cancelled")
        let timeout = XCTestExpectation(description: "no timeout after cancellation")
        timeout.isInverted = true
        let task = Task {
            await OpenCodeEventManager.withHeartbeat(timeout: 60, onTimeout: { timeout.fulfill() }) { activity in
                await activity()
                started.fulfill()
                do { try await Task.sleep(for: .seconds(60)) } catch { ended.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [ended], timeout: 1)
        await task.value
        await fulfillment(of: [timeout], timeout: 0.02)
    }

    func testHeartbeatTimeoutCancelsAndJoinsSilentConsumer() async {
        let timeout = XCTestExpectation(description: "heartbeat timeout")
        let ended = XCTestExpectation(description: "consumer cancelled")
        await OpenCodeEventManager.withHeartbeat(timeout: 0.01, onTimeout: { timeout.fulfill() }) { _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { ended.fulfill() }
        }
        await fulfillment(of: [timeout, ended], timeout: 1)
    }

    @MainActor
    func testV2ManagerReplacementCancelsOldConsumerAndRejectsItsLateCallbacks() async {
        actor Recorder {
            var sessions: [String] = []
            func append(_ id: String) { sessions.append(id) }
        }
        let recorder = Recorder()
        let firstStarted = XCTestExpectation(description: "first stream started")
        let firstEnded = XCTestExpectation(description: "first stream cancelled")
        let secondStarted = XCTestExpectation(description: "replacement stream started")
        let secondEnded = XCTestExpectation(description: "replacement stream cancelled")
        let manager = OpenCodeEventManager()
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: ""))
        manager.startV2(client: client, onStatus: { _ in }, consume: { _, _, status, _, event in
            firstStarted.fulfill()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await status("stream open event")
                await event(OpenCodeServerEvent(type: "message", data: #"{"type":"session.execution.started","data":{"sessionID":"ses_old"}}"#, id: nil, retry: nil))
                firstEnded.fulfill()
            }
        }, onEvent: { event in await recorder.append(event.sessionID ?? "missing") })
        await fulfillment(of: [firstStarted], timeout: 1)
        manager.startV2(client: client, onStatus: { _ in }, consume: { _, _, _, _, event in
            await event(OpenCodeServerEvent(type: "message", data: #"{"type":"session.execution.started","data":{"sessionID":"ses_new"}}"#, id: nil, retry: nil))
            secondStarted.fulfill()
            do { try await Task.sleep(for: .seconds(60)) } catch { secondEnded.fulfill() }
        }, onEvent: { event in await recorder.append(event.sessionID ?? "missing") })
        await fulfillment(of: [firstEnded, secondStarted], timeout: 1)
        await manager.stopAndWait()
        await fulfillment(of: [secondEnded], timeout: 1)
        let sessions = await recorder.sessions
        XCTAssertEqual(sessions, ["ses_new"])
    }

    @MainActor
    func testV2ManagerStopDuringReconnectBackoffDoesNotStartAnotherConsumer() async {
        actor Recorder {
            var starts = 0
            func start() { starts += 1 }
        }
        let recorder = Recorder()
        let reconnecting = XCTestExpectation(description: "reconnect backoff")
        let manager = OpenCodeEventManager()
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: ""))
        manager.startV2(client: client, onStatus: { status in
            if status == "stream v2 reconnecting" {
                await manager.stop()
                reconnecting.fulfill()
            }
        }, consume: { _, _, _, _, _ in await recorder.start() }, onEvent: { _ in })
        await fulfillment(of: [reconnecting], timeout: 1)
        await manager.stopAndWait()
        let starts = await recorder.starts
        XCTAssertEqual(starts, 1)
    }

    func testStoppedLegacyBatcherCannotRescheduleQueuedEvents() async {
        let delivered = XCTestExpectation(description: "no delivery after stop")
        delivered.isInverted = true
        let batcher = OpenCodeManagedEventBatcher { _ in delivered.fulfill() }
        await batcher.enqueue(managedDeltaEvent(delta: "old"))
        await batcher.stop()
        await batcher.enqueue(managedDeltaEvent(delta: "new"))
        await batcher.flush()
        await fulfillment(of: [delivered], timeout: 0.03)
    }

    func testLegacyBatcherTimerDeliversWithoutCancellingMainActorCallbacks() async {
        let delivered = XCTestExpectation(description: "Timer delivers in a live task")
        let batcher = OpenCodeManagedEventBatcher { _ in
            XCTAssertFalse(Task.isCancelled)
            await MainActor.run {
                XCTAssertFalse(Task.isCancelled, "The legacy backend rejects cancelled callbacks")
                delivered.fulfill()
            }
        }
        await batcher.enqueue(managedDeltaEvent(delta: "Hello"))
        // Do not call flush(): only the scheduled timer reproduced the self-cancellation.
        await fulfillment(of: [delivered], timeout: 1)
        await batcher.stop()
    }

    @MainActor
    func testLegacyBatchedEventsPublishDirectoryAndActiveTranscriptWithoutRefresh() async throws {
        let model = AppViewModel()
        model.config = OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: "", apiPreference: .legacy)
        model.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        let connection = try model.requireBackendConnection()
        defer {
            model.stopEventStream()
            model.resetLocalCacheRuntimeState()
            connection.close()
        }
        let session = OpenCodeSession(id: "ses_test", title: "Streaming", workspaceID: nil,
            directory: "/tmp/project", projectID: "project", parentID: nil)
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        model.streamDirectory = "/tmp/stale-stream-directory"
        model.activeChatSessionID = session.id
        let user = message(id: "msg_user", role: "user", text: "Hello", created: 1)
        model.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [user])
        model.messages = [user]
        let directory = model.directoryStore
        let facade = model.chatFacade
        let published = expectation(description: "Chat facade observes the projected answer")
        let observation = facade.objectWillChange.first { _ in
            model.messages.last?.parts.first?.text == "Hello world"
                && directory.syncStore.messageEnvelopes(forSessionID: session.id, suffix: 2).last?.parts.first?.text == "Hello world"
        }.sink { _ in published.fulfill() }
        defer { observation.cancel() }

        let delivered = expectation(description: "Legacy events reach the compatibility sink")
        delivered.expectedFulfillmentCount = 4
        let batcher = OpenCodeManagedEventBatcher { event in
            await MainActor.run {
                defer { delivered.fulfill() }
                // This is the production compatibility sink's connection/cancellation gate.
                guard model.isCurrentBackendConnection(connection) else { return }
                model.handleManagedEvent(event)
            }
        }
        for payload in [
            #"{"directory":"/tmp/project","payload":{"type":"message.updated","properties":{"info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test","time":{"created":2}}}}}"#,
            #"{"directory":"/tmp/project","payload":{"type":"message.part.updated","properties":{"part":{"id":"part_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":""}}}}"#,
        ] {
            guard case let .event(event) = OpenCodeEventManager.decodeManagedEvent(from: payload) else {
                return XCTFail("Invalid legacy streaming fixture")
            }
            await batcher.enqueue(event)
        }
        await batcher.enqueue(managedDeltaEvent(delta: "Hello"))
        await batcher.enqueue(managedDeltaEvent(delta: " world"))
        await fulfillment(of: [delivered], timeout: 1)
        await batcher.stop()
        await fulfillment(of: [published], timeout: 1)

        XCTAssertTrue(model.directoryStoreRegistry.ownerStore(forSessionID: session.id) === directory)
        XCTAssertEqual(model.messages.last?.parts.first?.text, "Hello world")
        XCTAssertEqual(directory.syncStore.messageEnvelopes(forSessionID: session.id, suffix: 2), model.messages)
        XCTAssertEqual(facade.messageSource(for: session), model.messages)
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

    func testManagedEventBatcherPreservesOrderWhenDeliverySuspends() async throws {
        final class DeliveryRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String] = []

            func append(_ value: String) {
                lock.lock()
                values.append(value)
                lock.unlock()
            }

            func snapshot() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return values
            }
        }

        let recorder = DeliveryRecorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            guard case let .messagePartDelta(_, _, _, _, delta) = event.typed else { return }
            if delta == "1" {
                try? await Task.sleep(for: .milliseconds(80))
            }
            recorder.append(delta)
        }

        await batcher.enqueue(managedDeltaEvent(delta: "1"))
        try await Task.sleep(for: .milliseconds(25))
        await batcher.enqueue(managedDeltaEvent(delta: "2"))
        try await Task.sleep(for: .milliseconds(140))

        XCTAssertEqual(recorder.snapshot(), ["1", "2"])
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

    func testReducerIgnoresDeltaWhenPartUpdateHasNotArrived() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let delta = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: delta, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].parts.isEmpty)
    }

    func testReducerDoesNotCreateProvisionalTextPartForUnknownDelta() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let delta = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )
        let partUpdated = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":""}}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: delta, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: partUpdated, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts[0].type, "text")
        XCTAssertEqual(messages[0].parts[0].text, "")
    }

    func testUnknownReasoningDeltaDoesNotRenderAsTextPart() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let delta = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_reasoning","field":"text","delta":"Thinking"}}"#
        )
        let reasoningPart = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_test","type":"reasoning","text":""}}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: delta, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: reasoningPart, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts[0].type, "reasoning")
        XCTAssertEqual(messages[0].parts[0].text, "")
    }

    func testReducerUsesPartTypeNotDeltaTextForReasoning() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let earlyReasoningDelta = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_reasoning","field":"text","delta":"Thinking before typed part"}}"#
        )
        let reasoningPart = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_test","type":"reasoning","text":""}}}"#
        )
        let reasoningDelta = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_reasoning","field":"text","delta":"Typed reasoning"}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: earlyReasoningDelta, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: reasoningPart, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: reasoningDelta, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts[0].type, "reasoning")
        XCTAssertEqual(messages[0].parts[0].text, "Typed reasoning")
    }

    func testBufferedDeltaReplaysAfterPartUpdateEstablishesTypedPart() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let partUpdated = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","text":""}}}"#
        )
        let bufferedDelta = OpenCodePendingTranscriptEvent(
            typedEvent: .messagePartDelta(sessionID: sessionID, messageID: "msg_assistant", partID: "prt_text", field: "text", delta: "Buffered text"),
            eventType: "message.part.delta",
            sessionID: sessionID,
            messageID: "msg_assistant",
            partID: "prt_text",
            deltaCharacterCount: "Buffered text".count,
            enqueuedAt: Date()
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: partUpdated, selectedSessionID: sessionID, messages: messages).messages
        for event in ChatStore.coalescedTranscriptEvents([bufferedDelta]) {
            guard case let .messagePartDelta(sessionID, messageID, partID, field, delta) = event.typedEvent else { continue }
            let payload = OpenCodeEventEnvelope(
                type: "message.part.delta",
                properties: .init(sessionID: sessionID, messageID: messageID, partID: partID, field: field, delta: delta)
            )
            messages = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: sessionID, messages: messages).messages
        }

        XCTAssertEqual(messages[0].parts[0].type, "text")
        XCTAssertEqual(messages[0].parts[0].text, "Buffered text")
    }

    func testBufferedReasoningDeltaReplaysAfterPartUpdateWithoutBecomingText() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let partUpdated = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","part":{"id":"prt_reasoning","messageID":"msg_assistant","sessionID":"ses_test","type":"reasoning","text":""}}}"#
        )
        let bufferedDelta = OpenCodePendingTranscriptEvent(
            typedEvent: .messagePartDelta(sessionID: sessionID, messageID: "msg_assistant", partID: "prt_reasoning", field: "text", delta: "Buffered reasoning"),
            eventType: "message.part.delta",
            sessionID: sessionID,
            messageID: "msg_assistant",
            partID: "prt_reasoning",
            deltaCharacterCount: "Buffered reasoning".count,
            enqueuedAt: Date()
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: partUpdated, selectedSessionID: sessionID, messages: messages).messages
        for event in ChatStore.coalescedTranscriptEvents([bufferedDelta]) {
            guard case let .messagePartDelta(sessionID, messageID, partID, field, delta) = event.typedEvent else { continue }
            let payload = OpenCodeEventEnvelope(
                type: "message.part.delta",
                properties: .init(sessionID: sessionID, messageID: messageID, partID: partID, field: field, delta: delta)
            )
            messages = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: sessionID, messages: messages).messages
        }

        XCTAssertEqual(messages[0].parts[0].type, "reasoning")
        XCTAssertEqual(messages[0].parts[0].text, "Buffered reasoning")
    }

    func testReducerAppliesToolPartUpdatedWithEnvelopeMessageMetadata() throws {
        let sessionID = "ses_test"
        let info = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"}}}"#
        )
        let toolPart = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_tool","part":{"id":"prt_tool","type":"tool","tool":"bash"}}}"#
        )

        var messages: [OpenCodeMessageEnvelope] = []
        messages = OpenCodeStreamReducer.apply(payload: info, selectedSessionID: sessionID, messages: messages).messages
        messages = OpenCodeStreamReducer.apply(payload: toolPart, selectedSessionID: sessionID, messages: messages).messages

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts[0].id, "prt_tool")
        XCTAssertEqual(messages[0].parts[0].messageID, "msg_assistant")
        XCTAssertEqual(messages[0].parts[0].sessionID, "ses_test")
        XCTAssertEqual(messages[0].parts[0].tool, "bash")
    }

    func testTypedPartUpdatedPreservesEnvelopeMessageMetadata() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_tool","part":{"type":"tool","tool":"bash"}}}"#
        )

        guard case let .messagePartUpdated(part) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected message.part.updated")
        }

        XCTAssertEqual(part.id, "prt_tool")
        XCTAssertEqual(part.messageID, "msg_assistant")
        XCTAssertEqual(part.sessionID, "ses_test")
        XCTAssertEqual(part.tool, "bash")
    }

    func testMessagePartUpdatedToleratesTopLevelToolString() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_tool","tool":"bash","part":{"type":"tool","tool":"bash"}}}"#
        )

        guard case let .messagePartUpdated(part) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected message.part.updated")
        }

        XCTAssertEqual(part.id, "prt_tool")
        XCTAssertEqual(part.messageID, "msg_assistant")
        XCTAssertEqual(part.sessionID, "ses_test")
        XCTAssertEqual(part.tool, "bash")
    }

    func testManagedEventDecodeRecoversPartUpdatedWhenNestedPartShapeIsInvalid() throws {
        let raw = #"{"directory":"/tmp/project","payload":{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","part":{"id":"prt_text","messageID":"msg_assistant","sessionID":"ses_test","type":"text","source":"unexpected"}}}}"#

        guard case let .event(managed) = OpenCodeEventManager.decodeManagedEvent(from: raw) else {
            return XCTFail("Expected recovered managed event")
        }
        guard case let .messagePartUpdated(part) = managed.typed else {
            return XCTFail("Expected recovered message.part.updated")
        }

        XCTAssertEqual(managed.directory, "/tmp/project")
        XCTAssertEqual(part.id, "prt_text")
        XCTAssertEqual(part.messageID, "msg_assistant")
        XCTAssertEqual(part.sessionID, "ses_test")
        XCTAssertEqual(part.type, "text")
    }

    func testManagedEventDecodeKeepsPartStateWhenPartUpdatedHasNumericEventTime() throws {
        let raw = #"{"directory":"/tmp/project","payload":{"type":"message.part.updated","properties":{"sessionID":"ses_test","time":1779843902424,"part":{"id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_test","type":"tool","tool":"bash","callID":"call_1","state":{"status":"completed","title":"Run build","output":"done"}}}}}"#

        guard case let .event(managed) = OpenCodeEventManager.decodeManagedEvent(from: raw) else {
            return XCTFail("Expected managed event")
        }
        guard case let .messagePartUpdated(part) = managed.typed else {
            return XCTFail("Expected message.part.updated")
        }

        XCTAssertEqual(managed.directory, "/tmp/project")
        XCTAssertEqual(part.id, "prt_tool")
        XCTAssertEqual(part.messageID, "msg_assistant")
        XCTAssertEqual(part.sessionID, "ses_test")
        XCTAssertEqual(part.type, "tool")
        XCTAssertEqual(part.state?.output, "done")
    }

    func testManagedEventDecodeBuildsSessionUpdatedWhenModelUsesIDAlias() {
        let result = OpenCodeEventManager.decodeManagedEvent(
            from: #"{"directory":"/tmp/project","project":"proj_1","payload":{"id":"evt_title","type":"session.updated","properties":{"sessionID":"ses_test","info":{"id":"ses_test","slug":"curious-mountain","projectID":"proj_1","directory":"/tmp/project","path":"","title":"Whitelabeling app plan","agent":"plan","model":{"id":"gpt-5.5","providerID":"openai","variant":"medium"},"version":"1.15.6","summary":{"additions":0,"deletions":0,"files":0},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1779843899535,"updated":1779843902424}}}}}"#
        )

        guard case let .event(managed) = result else {
            return XCTFail("Expected managed session.updated event")
        }
        XCTAssertEqual(managed.directory, "/tmp/project")
        XCTAssertEqual(managed.envelope.type, "session.updated")
        guard case let .sessionUpdated(session) = managed.typed else {
            return XCTFail("Expected sessionUpdated typed event")
        }

        XCTAssertEqual(session.id, "ses_test")
        XCTAssertEqual(session.title, "Whitelabeling app plan")
        XCTAssertEqual(session.directory, "/tmp/project")
    }

    func testMessageModelReferenceDecodesIDAliasAsModelID() throws {
        let model = try JSONDecoder().decode(
            OpenCodeMessageModelReference.self,
            from: Data(#"{"id":"gpt-5.5","providerID":"openai","variant":"medium"}"#.utf8)
        )

        XCTAssertEqual(model.providerID, "openai")
        XCTAssertEqual(model.modelID, "gpt-5.5")
        XCTAssertEqual(model.variant, "medium")
    }

    func testToolLikeTextPartUpdatedNormalizesToToolPart() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_tool","part":{"id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_test","type":"text","tool":"bash","callID":"call_1","text":"bash"}}}"#
        )

        guard case let .messagePartUpdated(part) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected message.part.updated")
        }

        XCTAssertEqual(part.type, "tool")
        XCTAssertEqual(part.tool, "bash")
        XCTAssertEqual(part.callID, "call_1")
        XCTAssertNil(part.text)
    }

    func testDirectorySyncStoresNonSelectedSessionMessagesForLaterSelection() {
        let selectedSession = OpenCodeSession(id: "ses_selected", title: nil, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        let otherSession = OpenCodeSession(id: "ses_other", title: nil, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        let message = OpenCodeMessage(id: "msg_other", role: "assistant", sessionID: "ses_other", time: nil, agent: nil, model: nil)
        let part = OpenCodePart(id: "prt_other", messageID: "msg_other", sessionID: "ses_other", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")

        var sessions = [selectedSession, otherSession]
        var currentSelection: OpenCodeSession? = selectedSession
        var statuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var visibleMessages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messageUpdated(message),
            sessions: &sessions,
            selectedSession: &currentSelection,
            sessionStatuses: &statuses,
            syncState: &syncState,
            messages: &visibleMessages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messagePartUpdated(part),
            sessions: &sessions,
            selectedSession: &currentSelection,
            sessionStatuses: &statuses,
            syncState: &syncState,
            messages: &visibleMessages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messagePartDelta(sessionID: "ses_other", messageID: "msg_other", partID: "prt_other", field: "text", delta: "Hello other"),
            sessions: &sessions,
            selectedSession: &currentSelection,
            sessionStatuses: &statuses,
            syncState: &syncState,
            messages: &visibleMessages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        XCTAssertTrue(visibleMessages.isEmpty)
        let derived = syncState.messageEnvelopes(forSessionID: "ses_other")
        XCTAssertEqual(derived.count, 1)
        XCTAssertEqual(derived[0].parts.first?.text, "Hello other")
    }

    func testDirectorySyncIgnoresDeltaBeforeTypedPart() {
        var syncState = OpenCodeDirectorySyncState()
        let message = OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil)

        XCTAssertTrue(syncState.applyMessageUpdated(message))
        XCTAssertFalse(syncState.applyPartDelta(messageID: "msg_assistant", partID: "prt_text", field: "text", delta: "ignored"))
        XCTAssertTrue(syncState.messageEnvelopes(forSessionID: "ses_test")[0].parts.isEmpty)
    }

    func testDirectorySyncSkipsUpstreamSkippedPartTypes() {
        var syncState = OpenCodeDirectorySyncState()
        let message = OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil)
        let stepStart = OpenCodePart(id: "prt_step", messageID: "msg_assistant", sessionID: "ses_test", type: "step-start", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: nil)

        XCTAssertTrue(syncState.applyMessageUpdated(message))
        XCTAssertFalse(syncState.applyPartUpdated(stepStart))
        XCTAssertTrue(syncState.messageEnvelopes(forSessionID: "ses_test")[0].parts.isEmpty)
    }

    func testDirectorySyncMaterializesAssistantShellWhenPartArrivesFirst() {
        var syncState = OpenCodeDirectorySyncState()
        let sessionID = "ses_test"
        let userID = "msg_user"
        let messageID = "msg_assistant"
        let user = OpenCodeMessageEnvelope.local(role: "user", text: "Start", messageID: userID, sessionID: sessionID, partID: "prt_user")
        let reasoning = OpenCodePart(id: "prt_reasoning", messageID: messageID, sessionID: sessionID, type: "reasoning", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
        let text = OpenCodePart(id: "prt_text", messageID: messageID, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
        let tool = OpenCodePart(id: "prt_tool", messageID: messageID, sessionID: sessionID, type: "tool", mime: nil, filename: nil, url: nil, reason: nil, tool: "bash", callID: "call_1", state: OpenCodeToolState(status: "running", title: nil, error: nil, input: nil, output: nil, metadata: nil), text: nil)

        syncState.replaceMessages([user], forSessionID: sessionID)
        XCTAssertTrue(syncState.applyPartUpdated(reasoning))
        XCTAssertTrue(syncState.applyPartDelta(messageID: messageID, partID: "prt_reasoning", field: "text", delta: "Thinking"))
        XCTAssertTrue(syncState.applyPartUpdated(text))
        XCTAssertTrue(syncState.applyPartDelta(messageID: messageID, partID: "prt_text", field: "text", delta: "Answer"))
        XCTAssertTrue(syncState.applyPartUpdated(tool))

        let messages = syncState.messageEnvelopes(forSessionID: sessionID)
        XCTAssertEqual(messages.count, 2)
        let assistant = messages.first { $0.id == messageID }
        XCTAssertEqual(assistant?.info.role, "assistant")
        XCTAssertEqual(assistant?.info.parentID, userID)
        XCTAssertEqual(assistant?.parts.map(\.id), ["prt_reasoning", "prt_text", "prt_tool"])
        XCTAssertEqual(assistant?.parts[0].text, "Thinking")
        XCTAssertEqual(assistant?.parts[1].text, "Answer")
        XCTAssertEqual(assistant?.parts[2].tool, "bash")
    }

    func testDirectorySyncCanonicalReplaceUsesLoadedParts() {
        var syncState = OpenCodeDirectorySyncState()
        let sessionID = "ses_test"
        let messageID = "msg_assistant"
        let live = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_reasoning", messageID: messageID, sessionID: sessionID, type: "reasoning", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Thinking"),
                OpenCodePart(id: "prt_text", messageID: messageID, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Answer"),
                OpenCodePart(id: "prt_tool", messageID: messageID, sessionID: sessionID, type: "tool", mime: nil, filename: nil, url: nil, reason: nil, tool: "bash", callID: "call_1", state: nil, text: nil),
            ]
        )
        let staleCanonical = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "prt_reasoning", messageID: messageID, sessionID: sessionID, type: "reasoning", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Thinking")
            ]
        )

        syncState.replaceMessages([live], forSessionID: sessionID)
        syncState.replaceMessages([staleCanonical], forSessionID: sessionID)

        let messages = syncState.messageEnvelopes(forSessionID: sessionID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.map(\.id), ["prt_reasoning"])
        XCTAssertEqual(messages[0].parts[0].text, "Thinking")
    }

    func testFlatToolPartUpdatedReconstructsToolPart() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.updated","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_tool","type":"tool","tool":"bash","callID":"call_1","state":{"status":"running","title":"Shell"}}}"#
        )

        guard case let .messagePartUpdated(part) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected message.part.updated")
        }

        XCTAssertEqual(part.id, "prt_tool")
        XCTAssertEqual(part.messageID, "msg_assistant")
        XCTAssertEqual(part.sessionID, "ses_test")
        XCTAssertEqual(part.type, "tool")
        XCTAssertEqual(part.tool, "bash")
        XCTAssertEqual(part.callID, "call_1")
        XCTAssertEqual(part.state?.status, "running")
        XCTAssertEqual(part.state?.title, "Shell")
    }

    func testReducerMarksSessionIdleForReload() throws {
        let payload = try decodeEvent(
            #"{"type":"session.idle","properties":{"sessionID":"ses_test"}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])
        XCTAssertTrue(update.shouldReload)
    }

    func testTypedProjectUpdatedEventDecodesIconPreferences() throws {
        let payload = try decodeEvent(
            #"{"type":"project.updated","properties":{"id":"proj_123","worktree":"/tmp/project","name":"Project","icon":{"color":"cyan","url":"https://example.test/icon.png","override":"data:image/png;base64,AAA"},"sandboxes":["/tmp/project-wt"],"time":{"created":1,"updated":2}}}"#
        )

        guard case let .projectUpdated(project) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected project.updated")
        }

        XCTAssertEqual(project.id, "proj_123")
        XCTAssertEqual(project.worktree, "/tmp/project")
        XCTAssertEqual(project.icon?.color, "cyan")
        XCTAssertEqual(project.icon?.url, "https://example.test/icon.png")
        XCTAssertEqual(project.icon?.override, "data:image/png;base64,AAA")
        XCTAssertEqual(project.sandboxes, ["/tmp/project-wt"])
    }

    func testTypedWorktreeLifecycleEventsDecode() throws {
        let readyPayload = try decodeEvent(
            #"{"type":"worktree.ready","properties":{"name":"demo","branch":"opencode/demo"}}"#
        )

        guard case let .worktreeReady(name, branch) = OpenCodeTypedEvent(envelope: readyPayload) else {
            return XCTFail("Expected worktree.ready")
        }
        XCTAssertEqual(name, "demo")
        XCTAssertEqual(branch, "opencode/demo")

        let failedPayload = try decodeEvent(
            #"{"type":"worktree.failed","properties":{"message":"checkout failed"}}"#
        )

        guard case let .worktreeFailed(message) = OpenCodeTypedEvent(envelope: failedPayload) else {
            return XCTFail("Expected worktree.failed")
        }
        XCTAssertEqual(message, "checkout failed")
    }

    func testManagedWorktreeReadyEventUsesGlobalEnvelopeDirectory() throws {
        let raw = #"{"directory":"/tmp/project-wt","payload":{"type":"worktree.ready","properties":{"name":"demo","branch":"opencode/demo"}}}"#

        switch OpenCodeEventManager.decodeManagedEvent(from: raw) {
        case let .event(managed):
            XCTAssertEqual(managed.directory, "/tmp/project-wt")
            guard case let .worktreeReady(name, branch) = managed.typed else {
                return XCTFail("Expected worktree.ready")
            }
            XCTAssertEqual(name, "demo")
            XCTAssertEqual(branch, "opencode/demo")
        case let .dropped(message):
            XCTFail(message)
        }
    }

    func testSessionDiffDecodesSnapshotFileDiffPayload() throws {
        let payload = try decodeEvent(
            #"{"type":"session.diff","properties":{"sessionID":"ses_test","diff":[{"file":"Sources/App.swift","patch":"@@ -1 +1 @@","additions":2,"deletions":1,"status":"modified"}]}}"#
        )

        guard case let .sessionDiff(sessionID, diff) = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected session.diff typed event")
        }

        XCTAssertEqual(sessionID, "ses_test")
        XCTAssertEqual(diff.count, 1)
        XCTAssertEqual(diff[0].file, "Sources/App.swift")
        XCTAssertEqual(diff[0].patch, "@@ -1 +1 @@")
        XCTAssertEqual(diff[0].additions, 2)
        XCTAssertEqual(diff[0].deletions, 1)
        XCTAssertEqual(diff[0].status, "modified")
    }

    func testLowRiskTypedParityEventsDecode() throws {
        let disposed = try decodeEvent(
            #"{"type":"server.instance.disposed","properties":{"directory":"/tmp/project"}}"#
        )
        guard case let .serverInstanceDisposed(directory) = OpenCodeTypedEvent(envelope: disposed) else {
            return XCTFail("Expected server.instance.disposed")
        }
        XCTAssertEqual(directory, "/tmp/project")

        let lsp = try decodeEvent(
            #"{"type":"lsp.updated","properties":{}}"#
        )
        guard case .lspUpdated = OpenCodeTypedEvent(envelope: lsp) else {
            return XCTFail("Expected lsp.updated")
        }

        let fileEdited = try decodeEvent(
            #"{"type":"file.edited","properties":{"file":"Sources/App.swift"}}"#
        )
        guard case let .fileEdited(file) = OpenCodeTypedEvent(envelope: fileEdited) else {
            return XCTFail("Expected file.edited")
        }
        XCTAssertEqual(file, "Sources/App.swift")

        let installationUpdated = try decodeEvent(
            #"{"type":"installation.updated","properties":{"version":"1.2.3"}}"#
        )
        guard case let .installationUpdated(version) = OpenCodeTypedEvent(envelope: installationUpdated) else {
            return XCTFail("Expected installation.updated")
        }
        XCTAssertEqual(version, "1.2.3")

        let updateAvailable = try decodeEvent(
            #"{"type":"installation.update-available","properties":{"version":"1.2.4"}}"#
        )
        guard case let .installationUpdateAvailable(version) = OpenCodeTypedEvent(envelope: updateAvailable) else {
            return XCTFail("Expected installation.update-available")
        }
        XCTAssertEqual(version, "1.2.4")
    }

    func testSessionDiffReducerStoresSessionLocalDiffs() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let diff = [
            OpenCodeSnapshotFileDiff(file: "b.swift", patch: "b", additions: 1, deletions: 0, status: "added"),
            OpenCodeSnapshotFileDiff(file: "a.swift", patch: "a", additions: 0, deletions: 1, status: "deleted")
        ]
        var sessions = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var messages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .sessionDiff(sessionID: selected.id, diff: diff),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .statusChanged = result else {
            return XCTFail("Expected statusChanged, got \(result)")
        }
        XCTAssertEqual(syncState.sessionDiffsBySessionID[selected.id]?.map(\.file), ["a.swift", "b.swift"])
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
        var sessions = [existingSession]
        var selectedSession: OpenCodeSession? = existingSession
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var messages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .sessionUpdated(partialUpdate),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .sessionChanged = result else {
            return XCTFail("Expected sessionChanged, got \(result)")
        }
        XCTAssertEqual(sessions.first?.title, "Renamed")
        XCTAssertEqual(sessions.first?.directory, "/tmp/project")
        XCTAssertEqual(selectedSession?.directory, "/tmp/project")
    }

    func testSessionUpdatedWithArchivedTimeRemovesSessionAndSelectedCaches() throws {
        let payload = try decodeEvent(
            #"{"type":"session.updated","properties":{"sessionID":"ses_test","info":{"id":"ses_test","title":"Archived","directory":"/tmp/project","projectID":"proj_1","time":{"created":1,"updated":2,"archived":3}}}}"#
        )

        guard let typed = OpenCodeTypedEvent(envelope: payload) else {
            return XCTFail("Expected session.updated typed event")
        }

        let selected = OpenCodeSession(id: "ses_test", title: "Active", workspaceID: nil, directory: "/tmp/project", projectID: "proj_1", parentID: nil)
        var sessions = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses = ["ses_test": "busy"]
        var syncState = OpenCodeDirectorySyncState()
        syncState.todosBySessionID["ses_test"] = [OpenCodeTodo(content: "Do it", status: "pending", priority: "high")]
        syncState.permissionsBySessionID["ses_test"] = [OpenCodePermission(id: "perm_1", sessionID: "ses_test", permission: "bash", patterns: nil, always: nil, metadata: nil, tool: nil)]
        syncState.questionsBySessionID["ses_test"] = [OpenCodeQuestionRequest(id: "q_1", sessionID: "ses_test", questions: [OpenCodeQuestion(question: "Continue?", header: "Confirm", options: [])], tool: nil)]
        syncState.replaceMessages([.local(role: "assistant", text: "Streaming", messageID: "msg_1", sessionID: "ses_test", partID: "prt_1")], forSessionID: "ses_test")
        var messages: [OpenCodeMessageEnvelope] = [.local(role: "assistant", text: "Visible", messageID: "msg_1", sessionID: "ses_test", partID: "prt_1")]
        var todos = [OpenCodeTodo(content: "Do it", status: "pending", priority: "high")]
        var permissions = [OpenCodePermission(id: "perm_1", sessionID: "ses_test", permission: "bash", patterns: nil, always: nil, metadata: nil, tool: nil)]
        var questions = [OpenCodeQuestionRequest(id: "q_1", sessionID: "ses_test", questions: [OpenCodeQuestion(question: "Continue?", header: "Confirm", options: [])], tool: nil)]

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: typed,
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .sessionChanged = result else {
            return XCTFail("Expected sessionChanged, got \(result)")
        }
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertNil(selectedSession)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertTrue(todos.isEmpty)
        XCTAssertTrue(permissions.isEmpty)
        XCTAssertTrue(questions.isEmpty)
        XCTAssertNil(sessionStatuses["ses_test"])
        XCTAssertNil(syncState.todosBySessionID["ses_test"])
        XCTAssertNil(syncState.permissionsBySessionID["ses_test"])
        XCTAssertNil(syncState.questionsBySessionID["ses_test"])
        XCTAssertTrue(syncState.messageEnvelopes(forSessionID: "ses_test").isEmpty)
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

        var sessions: [OpenCodeSession] = []
        var selectedSession: OpenCodeSession? = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var messages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: typed,
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .questionChanged = result else {
            return XCTFail("Expected questionChanged, got \(result)")
        }
        XCTAssertEqual(questions.map(\.id), ["q_1"])
    }

    func testMessageUpdatedDecodesTokenCostAndSystemFields() throws {
        let payload = try decodeEvent(
            #"{"type":"message.updated","properties":{"sessionID":"ses_test","info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test","providerID":"openai","modelID":"gpt-4.1","cost":1.25,"tokens":{"input":300,"output":100,"reasoning":50,"cache":{"read":25,"write":25}},"system":"system prompt"}}}"#
        )

        guard case let .messageUpdated(message) = try XCTUnwrap(OpenCodeTypedEvent(envelope: payload)) else {
            return XCTFail("Expected messageUpdated typed event")
        }

        XCTAssertEqual(message.cost, 1.25)
        XCTAssertEqual(message.tokens?.input, 300)
        XCTAssertEqual(message.tokens?.output, 100)
        XCTAssertEqual(message.tokens?.reasoning, 50)
        XCTAssertEqual(message.tokens?.cache.read, 25)
        XCTAssertEqual(message.tokens?.cache.write, 25)
        XCTAssertEqual(message.tokens?.computedTotal, 500)
        XCTAssertEqual(message.providerID, "openai")
        XCTAssertEqual(message.modelID, "gpt-4.1")
        XCTAssertEqual(message.system, "system prompt")
    }

    func testModelDecodesContextLimit() throws {
        let model = try JSONDecoder().decode(
            OpenCodeModel.self,
            from: Data(#"{"id":"gpt-4.1","providerID":"openai","name":"GPT-4.1","capabilities":{"reasoning":true},"limit":{"context":200000,"output":8192}}"#.utf8)
        )

        XCTAssertEqual(model.limit?.context, 200_000)
    }

    func testSessionContextMetricsUseLatestAssistantWithTokens() {
        let messages = [
            contextMessage(id: "msg_user", role: "user", text: "hello", system: "system prompt"),
            contextMessage(
                id: "msg_a1",
                role: "assistant",
                text: "first",
                cost: 0.5,
                tokens: OpenCodeMessageTokens(input: 0, output: 0, reasoning: 0, cache: OpenCodeMessageTokenCache(read: 0, write: 0)),
                providerID: "openai",
                modelID: "gpt-4.1"
            ),
            contextMessage(
                id: "msg_a2",
                role: "assistant",
                text: "second",
                cost: 1.25,
                tokens: OpenCodeMessageTokens(input: 300, output: 100, reasoning: 50, cache: OpenCodeMessageTokenCache(read: 25, write: 25)),
                providerID: "openai",
                modelID: "gpt-4.1"
            )
        ]
        let providers = [
            OpenCodeProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-4.1": OpenCodeModel(
                        id: "gpt-4.1",
                        providerID: "openai",
                        name: "GPT-4.1",
                        capabilities: OpenCodeModelCapabilities(reasoning: true),
                        limit: OpenCodeModelLimit(context: 1_000)
                    )
                ]
            )
        ]

        let metrics = OpenCodeSessionContextMetricsBuilder.metrics(messages: messages, providers: providers)

        XCTAssertEqual(metrics.totalCost, 1.75)
        XCTAssertEqual(metrics.messageCount, 3)
        XCTAssertEqual(metrics.userMessageCount, 1)
        XCTAssertEqual(metrics.assistantMessageCount, 2)
        XCTAssertEqual(metrics.systemPrompt, "system prompt")
        XCTAssertEqual(metrics.context?.messageID, "msg_a2")
        XCTAssertEqual(metrics.context?.total, 500)
        XCTAssertEqual(metrics.context?.usage, 50)
        XCTAssertEqual(metrics.context?.providerLabel, "OpenAI")
        XCTAssertEqual(metrics.context?.modelLabel, "GPT-4.1")
        XCTAssertFalse(metrics.breakdown.isEmpty)
    }

#if canImport(UIKit)
    @MainActor
    func testComposerMentionHighlightingIsIdempotentAndPreservesSelection() {
        let textView = makeComposerTextView()
        let text = "Hi 👋 @explore"
        let mentionRange = (text as NSString).range(of: "@explore")
        let mention = OpenCodeAgentMention(
            name: "explore",
            content: "@explore",
            start: mentionRange.location,
            end: NSMaxRange(mentionRange)
        )
        textView.text = text
        textView.selectedRange = NSRange(location: mentionRange.location, length: 0)

        XCTAssertTrue(textView.applyMentionHighlighting(agentMentions: [mention]))
        XCTAssertEqual(textView.selectedRange, NSRange(location: mentionRange.location, length: 0))
        XCTAssertFalse(textView.applyMentionHighlighting(agentMentions: [mention]))

        let attributes = textView.attributedText.attributes(at: mentionRange.location, effectiveRange: nil)
        XCTAssertTrue((attributes[.foregroundColor] as? UIColor)?.isEqual(UIColor.systemIndigo) == true)
        XCTAssertTrue((attributes[.font] as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }

    @MainActor
    func testComposerPlainTextHighlightingDoesNotRewriteAttributedText() {
        let textView = makeComposerTextView()
        textView.text = "ordinary draft"

        XCTAssertFalse(textView.applyMentionHighlighting(agentMentions: []))
        XCTAssertEqual(textView.attributedText.string, "ordinary draft")

        textView.text = textView.text + "!"
        XCTAssertFalse(textView.applyMentionHighlighting(agentMentions: []))
        XCTAssertEqual(textView.attributedText.string, "ordinary draft!")
    }

    @MainActor
    func testComposerFittedHeightCapsAtMaximumLinesAndUpdatesScrolling() {
        let textView = makeComposerTextView()
        textView.applyText(Array(repeating: "line", count: 8).joined(separator: "\n"), agentMentions: [])

        let height = textView.fittedHeight(width: 240, maxLines: 6)
        let maximumHeight = ceil(
            textView.font!.lineHeight * 6
                + textView.textContainerInset.top
                + textView.textContainerInset.bottom
        )

        XCTAssertEqual(height, maximumHeight, accuracy: 0.5)
        XCTAssertTrue(textView.isScrollEnabled)

        textView.applyText("one line", agentMentions: [])
        _ = textView.fittedHeight(width: 240, maxLines: 6)
        XCTAssertFalse(textView.isScrollEnabled)
    }

    @MainActor
    private func makeComposerTextView() -> ComposerPlaceholderTextView {
        let textView = ComposerPlaceholderTextView()
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
        return textView
    }
#endif

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

    func testReducerIgnoresDeltaWhenMessageShellHasNotArrived() throws {
        let payload = try decodeEvent(
            #"{"type":"message.part.delta","properties":{"sessionID":"ses_test","messageID":"msg_assistant","partID":"prt_text","field":"text","delta":"Hello"}}"#
        )

        let update = OpenCodeStreamReducer.apply(payload: payload, selectedSessionID: "ses_test", messages: [])

        XCTAssertTrue(update.messages.isEmpty)
        XCTAssertFalse(update.applied)
        XCTAssertEqual(update.reason, "missing delta target")
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

    func testDirectorySyncPreservesAccumulatedTextWhenPartUpdateIsStale() {
        var syncState = OpenCodeDirectorySyncState()
        let initial = OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello")
        let stale = OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello")

        XCTAssertTrue(syncState.applyPartUpdated(initial))
        XCTAssertTrue(syncState.applyPartDelta(messageID: "msg_assistant", partID: "prt_text", field: "text", delta: " world"))
        XCTAssertTrue(syncState.applyPartUpdated(stale))

        XCTAssertEqual(syncState.partsByMessageID["msg_assistant"]?.first?.text, "Hello world")
    }

    func testDirectorySyncPreservesPartArrivalOrder() {
        var syncState = OpenCodeDirectorySyncState()
        let laterIDFirst = OpenCodePart(id: "prt_z", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "first ")
        let earlierIDSecond = OpenCodePart(id: "prt_a", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "second")

        XCTAssertTrue(syncState.applyPartUpdated(laterIDFirst))
        XCTAssertTrue(syncState.applyPartUpdated(earlierIDSecond))

        XCTAssertEqual(syncState.partsByMessageID["msg_assistant"]?.map(\.id), ["prt_z", "prt_a"])
        XCTAssertEqual(syncState.messageEnvelopes(forSessionID: "ses_test").first?.parts.compactMap(\.text).joined(), "first second")
    }

    func testDirectorySyncAppendsOptimisticEnvelopeWithoutReplacingSessionSnapshot() {
        let sessionID = "ses_test"
        var syncState = OpenCodeDirectorySyncState()
        let existing = OpenCodeMessageEnvelope.local(role: "user", text: "old", messageID: "msg_old", sessionID: sessionID, partID: "prt_old")
        let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: "new", messageID: "msg_new", sessionID: sessionID, partID: "prt_new")

        syncState.replaceMessages([existing], forSessionID: sessionID)
        syncState.appendMessageEnvelope(optimistic, forSessionID: sessionID)

        XCTAssertEqual(syncState.messagesBySessionID[sessionID]?.map(\.id), ["msg_old", "msg_new"])
        XCTAssertEqual(syncState.partsByMessageID["msg_old"]?.first?.text, "old")
        XCTAssertEqual(syncState.partsByMessageID["msg_new"]?.first?.text, "new")
    }

    func testDirectorySyncOrdersMessagesByCreationTimeAcrossIdentifierRollover() {
        let beforeRollover = message(
            id: "msg_ffdf4c869002UnMgGIBK3IkWiK",
            role: "assistant",
            text: "Before rollover",
            created: 1_786_672_105_577
        )
        let afterRollover = message(
            id: "msg_00336e353001iqV1Ewk4n4w1sW",
            role: "user",
            text: "After rollover",
            created: 1_786_752_323_000
        )

        let merged = ChatStore.mergingCanonicalMessagePage([afterRollover], into: [beforeRollover])
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages(Array(merged.reversed()), forSessionID: "ses_test")

        XCTAssertEqual(merged.map(\.id), [beforeRollover.id, afterRollover.id])
        XCTAssertEqual(
            syncState.messageEnvelopes(forSessionID: "ses_test").map(\.id),
            [beforeRollover.id, afterRollover.id]
        )
        XCTAssertEqual(syncState.messageEnvelopes(forSessionID: "ses_test", suffix: 1).first?.id, afterRollover.id)
    }

    func testDirectorySyncKeepsTimestampFreeOptimisticMessageAtEnd() {
        let canonical = message(id: "msg_z", role: "assistant", text: "Canonical", created: 1)
        let optimistic = message(id: "msg_0", role: "user", text: "Optimistic")
        var syncState = OpenCodeDirectorySyncState()

        syncState.replaceMessages([optimistic, canonical], forSessionID: "ses_test")

        XCTAssertEqual(syncState.messageEnvelopes(forSessionID: "ses_test").map(\.id), [canonical.id, optimistic.id])
    }

    func testDirectorySyncAcceptsNewerFullPartUpdate() {
        var syncState = OpenCodeDirectorySyncState()
        let initial = OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello")
        let newer = OpenCodePart(id: "prt_text", messageID: "msg_assistant", sessionID: "ses_test", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "Hello world")

        XCTAssertTrue(syncState.applyPartUpdated(initial))
        XCTAssertTrue(syncState.applyPartUpdated(newer))

        XCTAssertEqual(syncState.partsByMessageID["msg_assistant"]?.first?.text, "Hello world")
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

    func testChatStoreBuffersSelectedTranscriptDeltasWhileOffscreen() {
        let event = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_assistant",
            partID: "part_msg_assistant",
            field: "text",
            delta: "Hello"
        )

        XCTAssertTrue(ChatStore.shouldBufferTranscriptEvent(
            event,
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_current"
        ))

        XCTAssertTrue(ChatStore.shouldBufferTranscriptEvent(
            event,
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_other"
        ))

        XCTAssertTrue(ChatStore.shouldBufferTranscriptEvent(
            event,
            selectedSessionID: "ses_current",
            activeChatSessionID: nil
        ))

        XCTAssertFalse(ChatStore.shouldBufferTranscriptEvent(
            event,
            selectedSessionID: "ses_other",
            activeChatSessionID: "ses_other"
        ))

        XCTAssertFalse(ChatStore.shouldBufferTranscriptEvent(
            OpenCodeTypedEvent.messagePartDelta(
                sessionID: "ses_current",
                messageID: "msg_assistant",
                partID: "part_msg_assistant",
                field: "metadata",
                delta: "{}"
            ),
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_current"
        ))
    }

    func testChatStoreDoesNotBufferNonDeltaTranscriptEvents() {
        let event = OpenCodeTypedEvent.messageUpdated(
            OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: "ses_current", time: nil, agent: nil, model: nil)
        )

        XCTAssertFalse(ChatStore.shouldBufferTranscriptEvent(
            event,
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_current"
        ))
    }

    func testChatStoreAllowsHapticForVisibleSelectedAssistantTextDelta() {
        let event = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_assistant",
            partID: "part_msg_assistant",
            field: "text",
            delta: "Hello"
        )
        let messages = [message(id: "msg_assistant", role: "assistant", text: "", sessionID: "ses_current")]

        XCTAssertTrue(ChatStore.shouldEmitStreamPartHaptic(
            for: event,
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_current",
            messages: messages
        ))
    }

    func testChatStoreSuppressesHapticForNonVisibleOrWhitespaceDeltas() {
        let messages = [message(id: "msg_assistant", role: "assistant", text: "", sessionID: "ses_current")]
        let whitespace = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_assistant",
            partID: "part_msg_assistant",
            field: "text",
            delta: "   "
        )
        let missingPart = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_assistant",
            partID: "missing_part",
            field: "text",
            delta: "Hello"
        )
        let inactiveChat = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_assistant",
            partID: "part_msg_assistant",
            field: "text",
            delta: "Hello"
        )

        XCTAssertFalse(ChatStore.shouldEmitStreamPartHaptic(for: whitespace, selectedSessionID: "ses_current", activeChatSessionID: "ses_current", messages: messages))
        XCTAssertFalse(ChatStore.shouldEmitStreamPartHaptic(for: missingPart, selectedSessionID: "ses_current", activeChatSessionID: "ses_current", messages: messages))
        XCTAssertFalse(ChatStore.shouldEmitStreamPartHaptic(for: inactiveChat, selectedSessionID: "ses_current", activeChatSessionID: "ses_other", messages: messages))
    }

    func testChatStoreSuppressesHapticForUserMessages() {
        let event = OpenCodeTypedEvent.messagePartDelta(
            sessionID: "ses_current",
            messageID: "msg_user",
            partID: "part_msg_user",
            field: "text",
            delta: "Hello"
        )
        let userMessages = [message(id: "msg_user", role: "user", text: "", sessionID: "ses_current")]

        XCTAssertFalse(ChatStore.shouldEmitStreamPartHaptic(
            for: event,
            selectedSessionID: "ses_current",
            activeChatSessionID: "ses_current",
            messages: userMessages
        ))
    }

    func testChatStoreAssistantTextLengthUsesLatestAssistantMessage() {
        let messages = [
            message(id: "msg_old_assistant", role: "assistant", text: "old assistant text"),
            message(id: "msg_user", role: "user", text: "user text"),
            message(id: "msg_new_assistant", role: "assistant", text: "  new assistant text  "),
        ]

        XCTAssertEqual(ChatStore.assistantTextLength(in: messages), "new assistant text".count)
    }

    func testChatStoreAssistantTextLengthIgnoresCompletedAssistantMessage() {
        let messages = [
            completedMessage(id: "msg_old_assistant", role: "assistant", text: String(repeating: "x", count: 12_000)),
            message(id: "msg_user", role: "user", text: "user text"),
        ]

        XCTAssertEqual(ChatStore.assistantTextLength(in: messages), 0)
    }

    func testChatStoreStreamDeltaCoalescingIntervalUsesProjectedLengthThresholds() {
        let short: Duration = .milliseconds(50)
        let medium: Duration = .milliseconds(90)
        let long: Duration = .milliseconds(140)
        let veryLong: Duration = .milliseconds(220)

        XCTAssertEqual(ChatStore.streamDeltaCoalescingInterval(currentAssistantTextLength: 100, pendingTranscriptCharacterCount: 100, short: short, medium: medium, long: long, veryLong: veryLong), short)
        XCTAssertEqual(ChatStore.streamDeltaCoalescingInterval(currentAssistantTextLength: 2_499, pendingTranscriptCharacterCount: 1, short: short, medium: medium, long: long, veryLong: veryLong), medium)
        XCTAssertEqual(ChatStore.streamDeltaCoalescingInterval(currentAssistantTextLength: 5_999, pendingTranscriptCharacterCount: 1, short: short, medium: medium, long: long, veryLong: veryLong), long)
        XCTAssertEqual(ChatStore.streamDeltaCoalescingInterval(currentAssistantTextLength: 11_999, pendingTranscriptCharacterCount: 1, short: short, medium: medium, long: long, veryLong: veryLong), veryLong)
    }

    func testChatStoreActivePendingTranscriptLengthUsesPendingTargetPart() {
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([
            completedMessage(id: "msg_old_assistant", role: "assistant", text: String(repeating: "x", count: 12_000)),
            message(id: "msg_active_assistant", role: "assistant", text: "active text"),
        ], forSessionID: "ses_test")
        let events = [
            pendingDelta(messageID: "msg_active_assistant", partID: "part_msg_active_assistant", delta: " more"),
        ]

        XCTAssertEqual(ChatStore.activePendingTranscriptTextLength(events, in: syncState), "active text".count)
    }

    func testTranscriptCoalescingCombinesConsecutiveDeltasForSamePart() {
        let events = [
            pendingDelta(delta: "Hello", enqueuedAt: Date(timeIntervalSince1970: 2)),
            pendingDelta(delta: " ", enqueuedAt: Date(timeIntervalSince1970: 3)),
            pendingDelta(delta: "world", enqueuedAt: Date(timeIntervalSince1970: 4)),
        ]

        let coalesced = ChatStore.coalescedTranscriptEvents(events)

        XCTAssertEqual(coalesced.count, 1)
        XCTAssertEqual(deltaText(coalesced[0]), "Hello world")
        XCTAssertEqual(coalesced[0].deltaCharacterCount, 11)
        XCTAssertEqual(coalesced[0].enqueuedAt, Date(timeIntervalSince1970: 2))
    }

    func testTranscriptCoalescingPreservesInterleavedTargetOrder() {
        let events = [
            pendingDelta(messageID: "msg_a", partID: "part_a", delta: "A1"),
            pendingDelta(messageID: "msg_b", partID: "part_b", delta: "B1"),
            pendingDelta(messageID: "msg_a", partID: "part_a", delta: "A2"),
        ]

        let coalesced = ChatStore.coalescedTranscriptEvents(events)

        XCTAssertEqual(coalesced.count, 3)
        XCTAssertEqual(coalesced[0].messageID, "msg_a")
        XCTAssertEqual(deltaText(coalesced[0]), "A1")
        XCTAssertEqual(coalesced[1].messageID, "msg_b")
        XCTAssertEqual(deltaText(coalesced[1]), "B1")
        XCTAssertEqual(coalesced[2].messageID, "msg_a")
        XCTAssertEqual(deltaText(coalesced[2]), "A2")
    }

    func testTranscriptCoalescingFlushesBeforeNonDeltaEvents() {
        let sessionID = "ses_test"
        let messageEvent = OpenCodePendingTranscriptEvent(
            typedEvent: .messageUpdated(OpenCodeMessage(id: "msg_shell", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil)),
            eventType: "message.updated",
            sessionID: sessionID,
            messageID: "msg_shell",
            partID: nil,
            deltaCharacterCount: 0,
            enqueuedAt: Date(timeIntervalSince1970: 2)
        )
        let events = [
            pendingDelta(messageID: "msg_a", partID: "part_a", delta: "A1"),
            messageEvent,
            pendingDelta(messageID: "msg_a", partID: "part_a", delta: "A2"),
        ]

        let coalesced = ChatStore.coalescedTranscriptEvents(events)

        XCTAssertEqual(coalesced.count, 3)
        XCTAssertEqual(deltaText(coalesced[0]), "A1")
        XCTAssertEqual(coalesced[1].eventType, "message.updated")
        XCTAssertEqual(deltaText(coalesced[2]), "A2")
    }

    @MainActor
    func testChatStorePendingTranscriptQueueTracksCharacters() {
        let store = ChatStore()

        store.enqueuePendingTranscriptEvent(pendingDelta(delta: "Hello"))
        store.enqueuePendingTranscriptEvent(pendingDelta(delta: " world"))

        XCTAssertTrue(store.hasPendingTranscriptEvents)
        XCTAssertEqual(store.pendingTranscriptEventCount, 1)
        XCTAssertEqual(store.pendingTranscriptCharacterCount, 11)
    }

    func testChatStoreMergesLatestCanonicalPageIntoCachedHistory() {
        let old = message(id: "msg_old", role: "user", text: "Old", sessionID: "ses_test", created: 1)
        let stale = message(id: "msg_latest", role: "assistant", text: "Stale", sessionID: "ses_test", created: 2)
        let current = message(id: "msg_latest", role: "assistant", text: "Current", sessionID: "ses_test", created: 2)
        let new = message(id: "msg_new", role: "assistant", text: "New", sessionID: "ses_test", created: 3)

        let merged = ChatStore.mergingCanonicalMessagePage([current, new], into: [old, stale])

        XCTAssertEqual(merged.map(\.id), ["msg_old", "msg_latest", "msg_new"])
        XCTAssertEqual(merged[1].parts.first?.text, "Current")
    }

    @MainActor
    func testChatStoreIgnoresDeltaUntilCanonicalPartExists() {
        let store = ChatStore()
        let event = pendingDelta(partID: "part_msg_assistant", delta: "Hello")

        XCTAssertFalse(store.enqueuePendingTranscriptEventIfAvailable(event, in: OpenCodeDirectorySyncState()))
        XCTAssertFalse(store.hasPendingTranscriptEvents)

        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([
            message(id: "msg_assistant", role: "assistant", text: "", sessionID: "ses_test"),
        ], forSessionID: "ses_test")
        XCTAssertTrue(store.enqueuePendingTranscriptEventIfAvailable(event, in: syncState))
        XCTAssertTrue(store.hasPendingTranscriptEvents)
    }

    @MainActor
    func testChatStoreClearsPendingTranscriptWhenSelectingAnotherSession() {
        let store = ChatStore()
        store.beginSelectingSession(sessionID: "ses_old", cachedMessages: [])
        store.enqueuePendingTranscriptEvent(pendingDelta(sessionID: "ses_old", delta: "old"))

        store.beginSelectingSession(sessionID: "ses_new", cachedMessages: [])

        XCTAssertFalse(store.hasPendingTranscriptEvents)
    }

    @MainActor
    func testChatStoreBoundsRawQueueWhileWaitingForTypedPart() {
        let store = ChatStore()

        for _ in 0..<10_000 {
            store.enqueuePendingTranscriptEvent(pendingDelta(delta: "x"))
        }

        XCTAssertEqual(store.pendingTranscriptCharacterCount, 10_000)
        XCTAssertLessThanOrEqual(store.pendingTranscriptEventCount, 3)
        XCTAssertNil(store.drainAvailablePendingTranscriptEvents(in: OpenCodeDirectorySyncState()))
    }

    @MainActor
    func testChatStoreDrainPendingTranscriptEventsCoalescesAndClearsQueue() {
        let store = ChatStore()
        store.enqueuePendingTranscriptEvent(pendingDelta(delta: "Hello"))
        store.enqueuePendingTranscriptEvent(pendingDelta(delta: " world"))

        let drained = store.drainPendingTranscriptEvents()

        XCTAssertEqual(drained?.events.count, 1)
        XCTAssertEqual(drained?.coalescedEvents.count, 1)
        XCTAssertEqual(drained?.coalescedEvents.first.flatMap(deltaText), "Hello world")
        XCTAssertFalse(store.hasPendingTranscriptEvents)
        XCTAssertEqual(store.pendingTranscriptCharacterCount, 0)
        XCTAssertNil(store.drainPendingTranscriptEvents())
    }

    @MainActor
    func testChatStoreDrainAvailablePendingTranscriptEventsStopsAtMissingTarget() {
        let store = ChatStore()
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([
            message(id: "msg_b", role: "assistant", text: "", sessionID: "ses_test"),
        ], forSessionID: "ses_test")

        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_a", partID: "part_a", delta: "held"))
        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_b", partID: "part_msg_b", delta: "must not jump ahead"))

        XCTAssertNil(store.drainAvailablePendingTranscriptEvents(in: syncState))
        XCTAssertEqual(store.pendingTranscriptEventCount, 2)
    }

    @MainActor
    func testChatStoreDrainAvailablePendingTranscriptEventsDrainsAvailablePrefixOnly() {
        let store = ChatStore()
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([
            message(id: "msg_a", role: "assistant", text: "", sessionID: "ses_test"),
        ], forSessionID: "ses_test")

        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_a", partID: "part_msg_a", delta: "drained"))
        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_b", partID: "part_b", delta: "held"))

        let drained = store.drainAvailablePendingTranscriptEvents(in: syncState)

        XCTAssertEqual(drained?.events.count, 1)
        XCTAssertEqual(drained?.events.first?.messageID, "msg_a")
        XCTAssertEqual(deltaText(drained!.coalescedEvents[0]), "drained")
        XCTAssertTrue(store.hasPendingTranscriptEvents)
        XCTAssertEqual(store.pendingTranscriptEventCount, 1)
        XCTAssertNil(store.drainAvailablePendingTranscriptEvents(in: syncState))
    }

    @MainActor
    func testChatStoreDrainAvailablePendingTranscriptEventsDrainsHeldDeltasAfterPartAppears() {
        let store = ChatStore()
        var syncState = OpenCodeDirectorySyncState()

        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_a", partID: "part_a", delta: "Hello"))
        store.enqueuePendingTranscriptEvent(pendingDelta(messageID: "msg_a", partID: "part_a", delta: " world"))

        XCTAssertNil(store.drainAvailablePendingTranscriptEvents(in: syncState))

        XCTAssertTrue(syncState.applyPartUpdated(OpenCodePart(
            id: "part_a",
            messageID: "msg_a",
            sessionID: "ses_test",
            type: "text",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: ""
        )))

        let drained = store.drainAvailablePendingTranscriptEvents(in: syncState)

        XCTAssertEqual(drained?.events.count, 1)
        XCTAssertEqual(drained?.coalescedEvents.count, 1)
        XCTAssertEqual(deltaText(drained!.coalescedEvents[0]), "Hello world")
        XCTAssertFalse(store.hasPendingTranscriptEvents)
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

    func testPartRemovedForMissingMessageDoesNotMutateSelectedChat() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = []
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var messages: [OpenCodeMessageEnvelope] = [.local(role: "assistant", text: "Keep me", messageID: "msg_keep", sessionID: selected.id, partID: "prt_keep")]
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messagePartRemoved(messageID: "msg_other", partID: "prt_other"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .ignored = result else {
            return XCTFail("Expected ignored result, got \(result)")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "msg_keep")
        XCTAssertEqual(messages.first?.parts.count, 1)
    }

    func testMessageRemovedClearsSelectedMessageAndParts() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([
            message(id: "msg_keep", role: "user", text: "Keep me"),
            message(id: "msg_remove", role: "assistant", text: "Remove me")
        ], forSessionID: selected.id)
        var messages = syncState.messageEnvelopes(forSessionID: selected.id)
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messageRemoved(sessionID: selected.id, messageID: "msg_remove"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .message("message removed") = result else {
            return XCTFail("Expected message removed, got \(result)")
        }
        XCTAssertEqual(messages.map(\.id), ["msg_keep"])
        XCTAssertEqual(syncState.messageEnvelopes(forSessionID: selected.id).map(\.id), ["msg_keep"])
        XCTAssertNil(syncState.partsByMessageID["msg_remove"])
    }

    func testPartRemovedDeletesPartBucketWhenLastPartIsRemoved() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([message(id: "msg_1", role: "assistant", text: "Only part")], forSessionID: selected.id)
        var messages = syncState.messageEnvelopes(forSessionID: selected.id)
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .messagePartRemoved(messageID: "msg_1", partID: "part_msg_1"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .message("part removed") = result else {
            return XCTFail("Expected part removed, got \(result)")
        }
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].parts.isEmpty)
        XCTAssertNil(syncState.partsByMessageID["msg_1"])
    }

    func testPermissionLifecycleUpsertsSortedAndRemovesOnReply() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        syncState.permissionsBySessionID[selected.id] = [
            permission(id: "perm_1", sessionID: selected.id, permission: "bash"),
            permission(id: "perm_3", sessionID: selected.id, permission: "edit")
        ]
        var messages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions = syncState.permissionsBySessionID[selected.id] ?? []
        var questions: [OpenCodeQuestionRequest] = []

        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .permissionAsked(permission(id: "perm_2", sessionID: selected.id, permission: "read")),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .permissionAsked(permission(id: "perm_2", sessionID: selected.id, permission: "write")),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        XCTAssertEqual(permissions.map(\.id), ["perm_1", "perm_2", "perm_3"])
        XCTAssertEqual(syncState.permissionsBySessionID[selected.id]?.map(\.id), ["perm_1", "perm_2", "perm_3"])
        XCTAssertEqual(permissions.first { $0.id == "perm_2" }?.permission, "write")

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .permissionReplied(sessionID: selected.id, requestID: "perm_2", reply: "once"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .permissionChanged = result else {
            return XCTFail("Expected permissionChanged, got \(result)")
        }
        XCTAssertEqual(permissions.map(\.id), ["perm_1", "perm_3"])
        XCTAssertEqual(syncState.permissionsBySessionID[selected.id]?.map(\.id), ["perm_1", "perm_3"])
    }

    func testQuestionLifecycleUpsertsSortedAndRemovesOnReplyOrReject() {
        let selected = OpenCodeSession(id: "ses_test", title: "Test", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = [selected]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        syncState.questionsBySessionID[selected.id] = [
            questionRequest(id: "q_1", sessionID: selected.id, header: "First"),
            questionRequest(id: "q_3", sessionID: selected.id, header: "Third")
        ]
        var messages: [OpenCodeMessageEnvelope] = []
        var todos: [OpenCodeTodo] = []
        var permissions: [OpenCodePermission] = []
        var questions = syncState.questionsBySessionID[selected.id] ?? []

        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .questionAsked(questionRequest(id: "q_2", sessionID: selected.id, header: "Second")),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .questionAsked(questionRequest(id: "q_2", sessionID: selected.id, header: "Updated")),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        XCTAssertEqual(questions.map(\.id), ["q_1", "q_2", "q_3"])
        XCTAssertEqual(syncState.questionsBySessionID[selected.id]?.map(\.id), ["q_1", "q_2", "q_3"])
        XCTAssertEqual(questions.first { $0.id == "q_2" }?.questions.first?.header, "Updated")

        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .questionReplied(sessionID: selected.id, requestID: "q_2"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )
        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .questionRejected(sessionID: selected.id, requestID: "q_3"),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .questionChanged = result else {
            return XCTFail("Expected questionChanged, got \(result)")
        }
        XCTAssertEqual(questions.map(\.id), ["q_1"])
        XCTAssertEqual(syncState.questionsBySessionID[selected.id]?.map(\.id), ["q_1"])
    }

    func testTodoUpdatedStoresSessionLocalStateAndOnlyUpdatesSelectedVisibleTodos() {
        let selected = OpenCodeSession(id: "ses_selected", title: "Selected", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        let other = OpenCodeSession(id: "ses_other", title: "Other", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        var sessions: [OpenCodeSession] = [selected, other]
        var selectedSession: OpenCodeSession? = selected
        var sessionStatuses: [String: String] = [:]
        var syncState = OpenCodeDirectorySyncState()
        var messages: [OpenCodeMessageEnvelope] = []
        var todos = [OpenCodeTodo(content: "Visible", status: "pending", priority: "high")]
        var permissions: [OpenCodePermission] = []
        var questions: [OpenCodeQuestionRequest] = []
        let otherTodos = [OpenCodeTodo(content: "Other", status: "in_progress", priority: "medium")]
        let selectedTodos = [OpenCodeTodo(content: "Selected", status: "completed", priority: "low")]

        _ = OpenCodeStateReducer.applyDirectoryEvent(
            event: .todoUpdated(sessionID: other.id, todos: otherTodos),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        XCTAssertEqual(todos.map(\.content), ["Visible"])
        XCTAssertEqual(syncState.todosBySessionID[other.id], otherTodos)

        let result = OpenCodeStateReducer.applyDirectoryEvent(
            event: .todoUpdated(sessionID: selected.id, todos: selectedTodos),
            sessions: &sessions,
            selectedSession: &selectedSession,
            sessionStatuses: &sessionStatuses,
            syncState: &syncState,
            messages: &messages,
            todos: &todos,
            permissions: &permissions,
            questions: &questions
        )

        guard case .todoChanged = result else {
            return XCTFail("Expected todoChanged, got \(result)")
        }
        XCTAssertEqual(todos, selectedTodos)
        XCTAssertEqual(syncState.todosBySessionID[selected.id], selectedTodos)
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

    func testLargeMessageChunkerKeepsTablesWithBlankRowsTogether() throws {
        let text = """
Intro paragraph before the table.

| Name | Value |
| --- | --- |
| Alpha | 1 |

| Beta | 2 |

| Gamma | 3 |

Closing paragraph after the table.
"""

        let chunks = OpenCodeLargeMessageChunker.makeChunks(from: text)
        let tableChunk = try XCTUnwrap(chunks.first { $0.text.contains("| Name | Value |") })

        XCTAssertTrue(tableChunk.text.contains("| Alpha | 1 |"))
        XCTAssertTrue(tableChunk.text.contains("| Beta | 2 |"))
        XCTAssertTrue(tableChunk.text.contains("| Gamma | 3 |"))
        XCTAssertEqual(chunks.map(\.text).joined(), OpenCodeLargeMessageChunker.normalizedText(text))
    }

#if DEBUG
    @MainActor
    func testMarkdownRendererParsesTablesWithBlankRowsAndCRLF() throws {
        let text = "| Name | Value |\r\n| --- | --- |\r\n| Alpha | 1 |\r\n\r\n| Beta | 2 |\r\n\r\n| Gamma | 3 |"

        XCTAssertEqual(MarkdownMessageText._testFirstTableRowCount(in: text), 3)
    }

#if canImport(UIKit)
    @MainActor
    func testMarkdownRendererReportsFullTableHeight() throws {
        let text = """
| Feature | Status | Notes |
| --- | --- | --- |
| Header row | Visible | Should stay at the top |

| First data row | Visible | This used to be where rendering stopped |

| Second data row | Visible | Blank line above should not break the table |

| Third data row | Visible | CRLF-like spacing should still render all rows |

| Final row | Visible | Table should not be clipped |
"""
        let controller = UIHostingController(rootView: MarkdownMessageText(text: text, isUser: false, style: .standard).frame(width: 360))

        let size = controller.sizeThatFits(in: CGSize(width: 360, height: 10_000))

        XCTAssertEqual(MarkdownMessageText._testFirstTableRowCount(in: text), 5)
        XCTAssertGreaterThan(size.height, 280)
    }

    @MainActor
    func testStreamingMarkdownTablePreservesFullEstimatedHeight() throws {
        let text = """
| Feature | Status | Notes |
| --- | --- | --- |
| Table layout | Improved | This deliberately wraps across several lines at large accessibility sizes. |
| Last row | Visible | The final row must contribute its full measured height instead of overflowing an estimated placeholder. |
"""
        let estimatedHeight = try XCTUnwrap(MarkdownMessageText._testFirstTableEstimatedHeight(in: text))
        let view = MarkdownMessageText(
            text: text,
            isUser: false,
            style: .standard,
            isStreaming: true,
            tableMaximumWidth: 328
        )
        .frame(width: 360)
        let controller = UIHostingController(rootView: view)

        let size = controller.sizeThatFits(in: CGSize(width: 360, height: 10_000))

        XCTAssertGreaterThanOrEqual(size.height, estimatedHeight + 10)
    }

    @MainActor
    func testMarkdownRendererAvoidsExcessiveTableBottomPadding() throws {
        let text = """
| Area | Status | Notes |
| --- | --- | --- |
| Markdown table parsing | Passing | Handles CRLF input, blank lines between rows, and normal separator rows. |
| Chat chunking | Passing | Keeps the whole table together instead of splitting the header from later rows. |
| Table layout | Improved | The table content now owns the minimum height, so multi-line cells should not clip at the bottom. |
| Regression coverage | Added | Tests cover blank-line rows, renderer parsing, the 5-row reproduction sample, and layout height. |
| TestFlight build | Uploaded | Version 1.0.11 build 4 is confirmed as the latest TestFlight upload. |
| Short note | OK | This row checks normal single-line cells. |
| Longer wrapped note | Needs visual check | This cell is intentionally longer so it should wrap to multiple lines on iPhone. It should remain fully visible with no clipping, including the final line at the bottom of the cell. |
| Very long wrapped note | Needs visual check | This row pushes the layout harder with a longer paragraph that should wrap several times. If the fix is solid, every wrapped line should be visible, the row should expand naturally, and the table should scroll horizontally without cutting off text vertically. |
| Final row | Critical | The last row is the one most likely to expose bottom clipping. This line should be completely visible, including descenders like g, p, q, and y. |
"""
        let estimatedHeight = try XCTUnwrap(MarkdownMessageText._testFirstTableEstimatedHeight(in: text))

        XCTAssertEqual(MarkdownMessageText._testFirstTableRowCount(in: text), 9)
        XCTAssertGreaterThan(estimatedHeight, 900)
        XCTAssertLessThan(estimatedHeight, 1_350)
    }
#endif
#endif

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

    func testLargeMessageChunkCacheFallsBackForLongerNonPrefixRewrite() throws {
        let cache = OpenCodeLargeMessageChunkCache()
        let initialText = Self.capturedPerformanceSessionText
        let rewrittenText = "Completely replaced prefix\n\n" + initialText + "\n\nAdditional canonical text"
        let initialMessage = Self.performanceSessionMessage(text: initialText)
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

    private func pendingDelta(
        sessionID: String = "ses_test",
        messageID: String = "msg_assistant",
        partID: String = "part_text",
        field: String = "text",
        delta: String,
        enqueuedAt: Date = Date(timeIntervalSince1970: 1)
    ) -> OpenCodePendingTranscriptEvent {
        OpenCodePendingTranscriptEvent(
            typedEvent: .messagePartDelta(
                sessionID: sessionID,
                messageID: messageID,
                partID: partID,
                field: field,
                delta: delta
            ),
            eventType: "message.part.delta",
            sessionID: sessionID,
            messageID: messageID,
            partID: partID,
            deltaCharacterCount: delta.count,
            enqueuedAt: enqueuedAt
        )
    }

    private func deltaText(_ event: OpenCodePendingTranscriptEvent) -> String? {
        guard case let .messagePartDelta(_, _, _, _, delta) = event.typedEvent else { return nil }
        return delta
    }

    private func managedDeltaEvent(delta: String) -> OpenCodeManagedEvent {
        let properties = OpenCodeEventProperties(
            sessionID: "ses_test",
            messageID: "msg_assistant",
            partID: "part_text",
            field: "text",
            delta: delta
        )
        return OpenCodeManagedEvent(
            directory: "/tmp/project",
            envelope: OpenCodeEventEnvelope(type: "message.part.delta", properties: properties),
            typed: .messagePartDelta(
                sessionID: "ses_test",
                messageID: "msg_assistant",
                partID: "part_text",
                field: "text",
                delta: delta
            )
        )
    }

    private func contextMessage(
        id: String,
        role: String,
        text: String,
        cost: Double? = nil,
        tokens: OpenCodeMessageTokens? = nil,
        providerID: String? = nil,
        modelID: String? = nil,
        system: String? = nil,
        sessionID: String = "ses_test"
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: OpenCodeMessageTime(created: 1_711_236_000, completed: nil),
                agent: nil,
                model: nil,
                providerID: providerID,
                modelID: modelID,
                cost: cost,
                tokens: tokens,
                system: system
            ),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text),
            ]
        )
    }

    private func message(
        id: String,
        role: String,
        text: String,
        sessionID: String = "ses_test",
        created: Double? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: created.map { OpenCodeMessageTime(created: $0) },
                agent: nil,
                model: nil
            ),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text),
            ]
        )
    }

    private func completedMessage(id: String, role: String, text: String, sessionID: String = "ses_test") -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: OpenCodeMessageTime(created: 1, completed: 2), agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text),
            ]
        )
    }

    private func permission(id: String, sessionID: String, permission: String) -> OpenCodePermission {
        OpenCodePermission(
            id: id,
            sessionID: sessionID,
            permission: permission,
            patterns: [permission],
            always: nil,
            metadata: nil,
            tool: nil
        )
    }

    private func questionRequest(id: String, sessionID: String, header: String) -> OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(
            id: id,
            sessionID: sessionID,
            questions: [
                OpenCodeQuestion(
                    question: "Choose",
                    header: header,
                    options: [OpenCodeQuestionOption(label: "Yes", description: "Continue")]
                )
            ],
            tool: nil
        )
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
        text: String?,
        tool: String? = nil
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
