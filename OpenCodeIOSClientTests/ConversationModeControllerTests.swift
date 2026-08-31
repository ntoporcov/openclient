import XCTest
import AVFoundation
@testable import OpenClient

@MainActor
final class ConversationModeControllerTests: XCTestCase {
    func testAutomaticModeAllowsLongerPauseBeforeEndingTurn() {
        XCTAssertEqual(ConversationModeController.automaticSilenceTimeout, 2)
        XCTAssertEqual(ConversationModeController.automaticSendGracePeriod, 2.35)
    }

    func testTalkActivityPhaseMapping() {
        XCTAssertEqual(ConversationModeController.talkActivityPhase(for: .listening), .listening)
        XCTAssertEqual(ConversationModeController.talkActivityPhase(for: .waitingForResponse), .working)
        XCTAssertEqual(ConversationModeController.talkActivityPhase(for: .speakingResponse), .speaking)
        XCTAssertEqual(ConversationModeController.talkActivityPhase(for: .paused), .paused)
    }

    func testAudioInterruptionPausesAndResumesTalk() async {
        let controller = ConversationModeController()
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "")
        XCTAssertEqual(controller.state, .ready)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await Task.yield()
        XCTAssertEqual(controller.state, .paused)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        await Task.yield()
        XCTAssertEqual(controller.state, .ready)
        controller.stop()
    }

    func testResponseTextUsesOnlyNewAssistantAnswerParts() {
        let baseline = OpenCodeMessageEnvelope.local(
            role: "assistant",
            text: "Old response",
            messageID: "old"
        )
        var response = OpenCodeMessageEnvelope.local(
            role: "assistant",
            text: "**New response** with [details](https://example.com).",
            messageID: "new"
        )
        response.parts.append(
            OpenCodePart(
                id: "reasoning",
                messageID: "new",
                sessionID: nil,
                type: "reasoning",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: "Internal reasoning"
            )
        )
        let user = OpenCodeMessageEnvelope.local(role: "user", text: "Question", messageID: "user")

        let text = ConversationModeController.responseText(
            from: [baseline, user, response],
            excludingMessageIDs: ["old"]
        )

        XCTAssertEqual(text, "New response with details.")
    }

    func testSpeakableTextDropsFencedCode() {
        let text = ConversationModeController.speakableText(
            from: "Here is the result.\n```swift\nprint(\"Hello\")\n```\nUse it carefully."
        )

        XCTAssertEqual(text, "Here is the result. Use it carefully.")
    }

    func testResponseSpeechSegmentsOnlyIncludesCompletedPartsWhileBusy() {
        let message = responseMessage(parts: [
            responsePart(id: "first", text: "**First result.**", completed: true),
            responsePart(id: "second", text: "Still streaming", completed: false),
            responsePart(id: "reasoning", text: "Internal reasoning", type: "reasoning", completed: true),
        ])

        let segments = ConversationModeController.responseSpeechSegments(
            from: [message],
            excludingMessageIDs: [],
            includeIncompleteParts: false
        )

        XCTAssertEqual(segments, [.init(id: "response/first", text: "First result.")])
    }

    func testResponseSpeechQueuePreservesPartOrderAndDeduplicatesSnapshots() {
        let segments = ConversationModeController.responseSpeechSegments(
            from: [responseMessage(parts: [
                responsePart(id: "first", text: "Same answer", completed: true),
                responsePart(id: "second", text: "Same answer", completed: true),
            ])],
            excludingMessageIDs: [],
            includeIncompleteParts: false
        )
        var queue = ConversationModeController.ResponseSpeechQueue()

        queue.enqueue(segments)
        queue.enqueue(segments)

        XCTAssertEqual(queue.popFirst()?.id, "response/first")
        XCTAssertEqual(queue.popFirst()?.id, "response/second")
        XCTAssertNil(queue.popFirst())
    }

    func testResponseSpeechSegmentsTreatsRemainingTextAsCompleteWhenSessionIsIdle() {
        let message = responseMessage(parts: [
            responsePart(id: "streaming", text: "Final text without an end timestamp", completed: false),
        ])

        let segments = ConversationModeController.responseSpeechSegments(
            from: [message],
            excludingMessageIDs: [],
            includeIncompleteParts: true
        )

        XCTAssertEqual(segments.map(\.text), ["Final text without an end timestamp"])
    }

    func testTextPartDecodesCompletionTimestamp() throws {
        let data = Data(#"{"id":"part","messageID":"response","sessionID":"session","type":"text","text":"Ready","time":{"start":1,"end":2}}"#.utf8)

        let part = try JSONDecoder().decode(OpenCodePart.self, from: data)

        XCTAssertEqual(part.time, OpenCodePartTime(start: 1, end: 2))
    }

    func testSpokenEchoDetectionIgnoresResponseFragmentsButAllowsBargeIn() {
        let response = "I found the issue. The connection needs to be restarted before trying again."

        XCTAssertTrue(
            ConversationModeController.isLikelySpokenEcho(
                hypothesis: "The connection needs to be restarted",
                spokenText: response
            )
        )
        XCTAssertTrue(
            ConversationModeController.isLikelySpokenEcho(
                hypothesis: "Connection need restarting before we try again",
                spokenText: response
            )
        )
        XCTAssertFalse(
            ConversationModeController.isLikelySpokenEcho(
                hypothesis: "Wait, I want to add another detail",
                spokenText: response
            )
        )
    }

    func testPostResponseRecognitionFinalizesAfterAutoSendStopsInput() {
        XCTAssertTrue(
            ConversationModeController.shouldFinalizePostResponseRecognition(in: .finalizing)
        )
    }

    func testResponseWaitDoesNotFinishBeforeActivityOrContentArrives() {
        XCTAssertTrue(
            ConversationModeController.shouldKeepWaitingForResponse(
                isSessionBusy: false,
                hasObservedBusyState: false,
                hasObservedContent: false
            )
        )
        XCTAssertTrue(
            ConversationModeController.shouldKeepWaitingForResponse(
                isSessionBusy: true,
                hasObservedBusyState: true,
                hasObservedContent: false
            )
        )
        XCTAssertFalse(
            ConversationModeController.shouldKeepWaitingForResponse(
                isSessionBusy: false,
                hasObservedBusyState: true,
                hasObservedContent: false
            )
        )
        XCTAssertFalse(
            ConversationModeController.shouldKeepWaitingForResponse(
                isSessionBusy: false,
                hasObservedBusyState: false,
                hasObservedContent: true
            )
        )
    }

    func testHoldToTalkStartsArmedWithoutOpeningMicrophone() {
        let controller = ConversationModeController()
        controller.setHoldToTalkEnabled(true)

        controller.start(initialTranscript: "Existing draft")

        XCTAssertEqual(controller.inputMode, .holdToTalk)
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(controller.transcript, "Existing draft")
        controller.stop()
        XCTAssertEqual(controller.state, .inactive)
    }

    func testSendHoldAndMuteAreIndependentTalkControls() {
        let controller = ConversationModeController()
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "Existing draft")

        controller.toggleSendHold()
        XCTAssertTrue(controller.isSendHeld)
        XCTAssertFalse(controller.isMuted)
        XCTAssertEqual(controller.transcript, "Existing draft")

        controller.toggleMute()
        XCTAssertTrue(controller.isSendHeld)
        XCTAssertTrue(controller.isMuted)
        XCTAssertEqual(controller.state, .ready)

        controller.toggleSendHold()
        controller.toggleMute()
        XCTAssertFalse(controller.isSendHeld)
        XCTAssertFalse(controller.isMuted)
        controller.stop()
    }

    func testSpeechRecognizerRejectsCallbacksFromCancelledRecognition() {
        let cancelledRecognitionID = UUID()
        let activeRecognitionID = UUID()

        XCTAssertFalse(
            OpenClientSpeechRecognitionController.isCurrentRecognitionCallback(
                cancelledRecognitionID,
                activeRecognitionID: activeRecognitionID
            )
        )
        XCTAssertTrue(
            OpenClientSpeechRecognitionController.isCurrentRecognitionCallback(
                activeRecognitionID,
                activeRecognitionID: activeRecognitionID
            )
        )
    }

    private func responseMessage(parts: [OpenCodePart]) -> OpenCodeMessageEnvelope {
        var message = OpenCodeMessageEnvelope.local(
            role: "assistant",
            text: "",
            messageID: "response"
        )
        message.parts = parts
        return message
    }

    private func responsePart(
        id: String,
        text: String,
        type: String = "text",
        completed: Bool
    ) -> OpenCodePart {
        OpenCodePart(
            id: id,
            messageID: "response",
            sessionID: "session",
            type: type,
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: text,
            time: OpenCodePartTime(start: 1, end: completed ? 2 : nil)
        )
    }

}
