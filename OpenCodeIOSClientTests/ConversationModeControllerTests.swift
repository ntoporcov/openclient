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

    func testWireSyntheticRecordsAndReasoningAreNeverSpokenByInjectedSpeaker() {
        var spoken: [String] = []
        let controller = ConversationModeController(usesNativeAudio: false, responseSpeaker: { spoken.append($0) })
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "")
        controller.receiveFinalTranscript("Question")
        controller.didSubmit(baselineMessageIDs: [])
        var records = ["synthetic", "system", "skill", "agent-switched", "model-switched", "location-switched"].map { origin in
            responseMessage(parts: [responsePart(id: origin, text: "Wire metadata", completed: true, synthetic: true)])
        }
        records.append(responseMessage(parts: [responsePart(id: "reasoning", text: "Private thought", type: "reasoning", completed: true)]))
        records.append(responseMessage(parts: [responsePart(id: "answer", text: "Public answer", completed: true)]))
        controller.update(messages: records, isSessionBusy: true)
        XCTAssertEqual(spoken, ["Public answer"])
        XCTAssertFalse(controller.hasStartedLiveActivity)
        controller.stop()
    }

    func testBackgroundAdmissionAndCanonicalUpdatesCannotResumeAudio() {
        var spoken: [String] = []
        let controller = ConversationModeController(usesNativeAudio: false, responseSpeaker: { spoken.append($0) })
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "")
        controller.receiveFinalTranscript("Question")
        controller.didSubmit(baselineMessageIDs: [])
        controller.submissionAdmissionChanged(isAdmitted: false)
        controller.setAudioAvailable(false)
        controller.submissionAdmissionChanged(isAdmitted: true)
        controller.resume(isSessionBusy: false)
        let answer = responseMessage(parts: [responsePart(id: "answer", text: "Answer", completed: true)])
        controller.update(messages: [answer], isSessionBusy: false)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertTrue(spoken.isEmpty)
        controller.setAudioAvailable(true)
        controller.resume(isSessionBusy: true)
        controller.update(messages: [answer], isSessionBusy: true)
        XCTAssertEqual(spoken, ["Answer"])
        controller.stop()
    }

    func testUncertainSubmissionCannotBeRestartedByFailureOrForegroundRecovery() {
        let controller = ConversationModeController(usesNativeAudio: false)
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "")
        controller.receiveFinalTranscript("Original")
        controller.didSubmit(baselineMessageIDs: [])
        let token = controller.sendRequestToken
        controller.submissionAdmissionChanged(isAdmitted: false)
        controller.submissionDidNotStart()
        controller.setAudioAvailable(false)
        controller.setAudioAvailable(true)
        controller.resume(isSessionBusy: false)
        controller.receiveFinalTranscript("Duplicate")
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.sendRequestToken, token)
        controller.stop()
    }

    func testFormSettlementCannotResumeDuringAudioInterruption() async {
        let controller = ConversationModeController(usesNativeAudio: false)
        controller.setHoldToTalkEnabled(true)
        controller.start(initialTranscript: "")
        controller.setAudioAvailable(false)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await Task.yield()
        controller.setAudioAvailable(true)
        controller.resume(isSessionBusy: false)
        XCTAssertEqual(controller.state, .paused)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        await Task.yield()
        XCTAssertEqual(controller.state, .ready)
        controller.stop()
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
        completed: Bool,
        synthetic: Bool? = nil
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
            synthetic: synthetic,
            time: OpenCodePartTime(start: 1, end: completed ? 2 : nil)
        )
    }

}
