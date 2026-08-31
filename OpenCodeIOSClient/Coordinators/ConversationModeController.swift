import Combine
import Foundation

#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
import AVFoundation
import Speech
import UIKit
#endif

@MainActor
final class ConversationModeController: NSObject, ObservableObject {
    static let automaticSilenceTimeout: TimeInterval = 2
    static let automaticSendGracePeriod: TimeInterval = 2.35

    enum State: String, Equatable, Sendable {
        case inactive
        case ready
        case starting
        case listening
        case waitingToSend
        case finalizing
        case submitting
        case waitingForResponse
        case speakingResponse
        case paused

        var isActive: Bool {
            self != .inactive
        }
    }

    enum InputMode: String, Equatable, Sendable {
        case automatic
        case holdToTalk
    }

    struct ResponseSpeechSegment: Equatable, Sendable {
        let id: String
        let text: String
    }

    struct ResponseSpeechQueue: Equatable, Sendable {
        private(set) var pending: [ResponseSpeechSegment] = []
        private var acceptedIDs: Set<String> = []

        mutating func enqueue(_ segments: [ResponseSpeechSegment]) {
            for segment in segments where acceptedIDs.insert(segment.id).inserted {
                pending.append(segment)
            }
        }

        mutating func popFirst() -> ResponseSpeechSegment? {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }

        mutating func reset() {
            pending = []
            acceptedIDs = []
        }
    }

    @Published private(set) var state: State = .inactive
    @Published private(set) var inputMode: InputMode = .automatic
    @Published private(set) var transcript = ""
    @Published private(set) var inputLevel: CGFloat = 0
    @Published private(set) var inputPitch: CGFloat = 0
    @Published private(set) var isSpeakingFiller = false
    @Published private(set) var isSendHeld = false
    @Published private(set) var isMuted = false
    @Published private(set) var isSilenceDetected = false
    @Published private(set) var sendRequestToken = 0
    @Published var errorMessage: String?

    private var committedTranscript = ""
    private var liveHypothesis = ""
    private var submittedTranscript: String?
    private var responseBaselineMessageIDs: Set<String> = []
    private var responseSpeechQueue = ResponseSpeechQueue()
    private var isResponseSessionBusy = false
    private var hasObservedResponseBusyState = false
    private var hasObservedResponseContent = false
    private var pausedContext: State?
    private var pendingResponseText: String?
    private var autoSendTask: Task<Void, Never>?
    private var activeFillerPhrase: String?
    private var transcriptBeforeFiller = ""
    private var activeResponseSpeechText: String?
    private var isMonitoringResponseSpeech = false
    private var responseEchoCooldownTask: Task<Void, Never>?
    private var bargeInCandidate: String?
    private var bargeInConfirmationTask: Task<Void, Never>?
    private var bargeInEndpointTask: Task<Void, Never>?
    private var recognitionAttemptID: UUID?
    private let voiceStore: SpeechVoiceStore
    private let liveActivitySession = TalkLiveActivitySession()
    private var observations: Set<AnyCancellable> = []
    private var isPausedForAudioInterruption = false

    #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
    private enum SpeechPurpose {
        case thinkingFiller
        case response
    }

    private let recognizer = OpenClientSpeechRecognitionController()
    private let synthesizer = AVSpeechSynthesizer()
    private var speechPurpose: SpeechPurpose?
    private var fillerPhraseIndex = 0
    private var waitingEarconTask: Task<Void, Never>?
    private var waitingEarconEngine: AVAudioEngine?
    private var waitingEarconPlayer: AVAudioPlayerNode?
    #endif

    init(voiceStore: SpeechVoiceStore = SpeechVoiceStore()) {
        self.voiceStore = voiceStore
        super.init()
        inputMode = voiceStore.isHoldToTalkEnabled ? .holdToTalk : .automatic
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(notification)
                }
            }
            .store(in: &observations)
        #endif
        $state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.liveActivitySession.update(phase: Self.talkActivityPhase(for: state))
            }
            .store(in: &observations)
        voiceStore.$isHoldToTalkEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isEnabled in
                self?.setHoldToTalkEnabled(isEnabled)
            }
            .store(in: &observations)
    }

    var isActive: Bool {
        state.isActive
    }

    func startLiveActivity(
        title: String,
        directory: String?,
        workspaceID: String?,
        sessionID: String?
    ) {
        liveActivitySession.start(
            title: title,
            directory: directory,
            workspaceID: workspaceID,
            sessionID: sessionID,
            phase: Self.talkActivityPhase(for: state)
        )
    }

    func updateLiveActivitySessionID(_ sessionID: String) {
        liveActivitySession.update(
            phase: Self.talkActivityPhase(for: state),
            sessionID: sessionID
        )
    }

    static func talkActivityPhase(for state: State) -> OpenCodeTalkActivityPhase {
        switch state {
        case .ready, .starting, .listening, .waitingToSend, .finalizing:
            return .listening
        case .submitting, .waitingForResponse:
            return .working
        case .speakingResponse:
            return .speaking
        case .inactive, .paused:
            return .paused
        }
    }

    func start(initialTranscript: String) {
        guard state == .inactive else { return }
        committedTranscript = initialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveHypothesis = ""
        submittedTranscript = nil
        transcript = committedTranscript
        responseBaselineMessageIDs = []
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        pausedContext = nil
        pendingResponseText = nil
        activeFillerPhrase = nil
        isSpeakingFiller = false
        isSendHeld = false
        isMuted = false
        isSilenceDetected = false
        transcriptBeforeFiller = ""
        activeResponseSpeechText = nil
        isMonitoringResponseSpeech = false
        responseEchoCooldownTask?.cancel()
        responseEchoCooldownTask = nil
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        errorMessage = nil
        resumeInput()
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        let newMode: InputMode = isEnabled ? .holdToTalk : .automatic
        guard inputMode != newMode else { return }
        inputMode = newMode

        guard state.isActive, state != .paused else { return }
        if isEnabled {
            switch state {
            case .ready:
                break
            case .starting, .listening, .waitingToSend, .finalizing:
                preserveCurrentTranscript()
                cancelListening()
                state = .ready
            case .speakingResponse:
                #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
                recognizer.cancel(deactivatesAudioSession: false)
                #endif
                isMonitoringResponseSpeech = false
            case .inactive, .submitting, .waitingForResponse, .paused:
                break
            }
        } else if state == .ready {
            beginListening()
        }
    }

    func toggleSendHold() {
        isSendHeld.toggle()
        if isSendHeld {
            if state == .waitingToSend {
                cancelAutoSendGracePeriod()
            }
        } else if inputMode == .automatic,
                  state == .listening,
                  isSilenceDetected,
                  !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            beginAutoSendGracePeriod()
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        inputLevel = 0
        inputPitch = 0

        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if muted {
            recognitionAttemptID = nil
            if state == .starting || state == .listening {
                preserveCurrentTranscript()
                recognizer.cancel(deactivatesAudioSession: false)
                state = .listening
            } else if state == .waitingToSend {
                recognizer.cancel(deactivatesAudioSession: false)
            } else if state == .speakingResponse {
                recognizer.cancel(deactivatesAudioSession: false)
                isMonitoringResponseSpeech = false
            }
        } else {
            switch state {
            case .listening:
                preserveCurrentTranscript()
                beginListening()
            case .speakingResponse where inputMode == .automatic:
                beginResponseMonitoring()
            default:
                break
            }
        }
        #endif
    }

    func beginHoldToTalk() {
        guard inputMode == .holdToTalk, !isMuted else { return }
        if state == .speakingResponse {
            interruptResponseForHoldToTalk()
        }
        guard state == .ready else { return }
        beginListening()
    }

    func endHoldToTalk() {
        guard inputMode == .holdToTalk,
              state == .starting || state == .listening || state == .waitingToSend else {
            return
        }

        autoSendTask?.cancel()
        autoSendTask = nil
        if isSendHeld {
            preserveCurrentTranscript()
            recognitionAttemptID = nil
            #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
            recognizer.cancel(deactivatesAudioSession: false)
            #endif
            state = .ready
            return
        }
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if speechPurpose == .thinkingFiller {
            speechPurpose = nil
            isSpeakingFiller = false
            synthesizer.stopSpeaking(at: .immediate)
        }
        if recognizer.isRecording {
            state = .finalizing
            recognizer.stop()
        } else {
            recognizer.cancel()
            finishListening(with: liveHypothesis)
        }
        #else
        finishListening(with: liveHypothesis)
        #endif
    }

    func stop() {
        recognitionAttemptID = nil
        isPausedForAudioInterruption = false
        liveActivitySession.end()
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        recognizer.cancel()
        speechPurpose = nil
        synthesizer.stopSpeaking(at: .immediate)
        stopWaitingEarcon()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        autoSendTask?.cancel()
        autoSendTask = nil
        inputLevel = 0
        inputPitch = 0
        isSendHeld = false
        isMuted = false
        isSilenceDetected = false
        pausedContext = nil
        responseBaselineMessageIDs = []
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        pendingResponseText = nil
        submittedTranscript = nil
        activeFillerPhrase = nil
        isSpeakingFiller = false
        transcriptBeforeFiller = ""
        activeResponseSpeechText = nil
        isMonitoringResponseSpeech = false
        responseEchoCooldownTask?.cancel()
        responseEchoCooldownTask = nil
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        state = .inactive
    }

    func didSubmit(baselineMessageIDs: Set<String>) {
        guard state == .submitting else { return }
        responseBaselineMessageIDs = baselineMessageIDs
        responseSpeechQueue.reset()
        isResponseSessionBusy = true
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        submittedTranscript = transcript
        committedTranscript = ""
        liveHypothesis = ""
        transcript = ""
        inputLevel = 0
        inputPitch = 0
        state = .waitingForResponse
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        startWaitingEarcon()
        #endif
    }

    func submissionDidNotStart() {
        guard state == .submitting || state == .waitingForResponse else { return }
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        stopWaitingEarcon()
        #endif
        committedTranscript = submittedTranscript ?? committedTranscript
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        submittedTranscript = nil
        transcript = committedTranscript
        resumeInput()
    }

    func update(messages: [OpenCodeMessageEnvelope], isSessionBusy: Bool) {
        guard state == .waitingForResponse || state == .speakingResponse else { return }
        isResponseSessionBusy = isSessionBusy
        if isSessionBusy {
            hasObservedResponseBusyState = true
        }
        let segments = Self.responseSpeechSegments(
            from: messages,
            excludingMessageIDs: responseBaselineMessageIDs,
            includeIncompleteParts: !isSessionBusy
        )
        if !segments.isEmpty {
            hasObservedResponseContent = true
        }
        responseSpeechQueue.enqueue(segments)

        if state == .waitingForResponse {
            continueResponseTurn()
        }
    }

    func pause() {
        guard state.isActive, state != .paused else { return }
        if state == .listening || state == .waitingToSend || state == .finalizing {
            committedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            liveHypothesis = ""
        }
        pausedContext = state
        recognitionAttemptID = nil
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        recognizer.cancel()
        speechPurpose = nil
        isSpeakingFiller = false
        synthesizer.stopSpeaking(at: .immediate)
        stopWaitingEarcon()
        #endif
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        autoSendTask?.cancel()
        autoSendTask = nil
        inputLevel = 0
        inputPitch = 0
        state = .paused
    }

    func resume(isSessionBusy: Bool) {
        guard state == .paused else { return }
        let context = pausedContext
        pausedContext = nil

        isResponseSessionBusy = isSessionBusy
        if context == .speakingResponse, let pendingResponseText {
            speakResponse(pendingResponseText)
        } else if context == .waitingForResponse || context == .submitting || isSessionBusy {
            state = .waitingForResponse
            continueResponseTurn()
        } else {
            resumeInput()
        }
    }

    #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            guard state.isActive, state != .paused else { return }
            isPausedForAudioInterruption = true
            pause()
        case .ended:
            guard isPausedForAudioInterruption else { return }
            isPausedForAudioInterruption = false
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            guard options.contains(.shouldResume) else { return }
            resume(isSessionBusy: isResponseSessionBusy)
        @unknown default:
            break
        }
    }
    #endif

    static func responseSpeechSegments(
        from messages: [OpenCodeMessageEnvelope],
        excludingMessageIDs baselineMessageIDs: Set<String>,
        includeIncompleteParts: Bool
    ) -> [ResponseSpeechSegment] {
        messages.flatMap { message -> [ResponseSpeechSegment] in
            guard !baselineMessageIDs.contains(message.id),
                  (message.info.role ?? "").lowercased() == "assistant",
                  !message.info.isCompactionSummary else {
                return []
            }

            return message.parts.enumerated().compactMap { index, part in
                guard part.type == "text",
                      part.synthetic != true,
                      part.ignored != true,
                      part.reason?.lowercased().contains("reasoning") != true,
                      includeIncompleteParts || part.time?.end != nil,
                      let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    return nil
                }

                let speakable = speakableText(from: text)
                guard !speakable.isEmpty else { return nil }
                return ResponseSpeechSegment(
                    id: "\(message.id)/\(part.id ?? "index:\(index)")",
                    text: speakable
                )
            }
        }
    }

    static func responseText(
        from messages: [OpenCodeMessageEnvelope],
        excludingMessageIDs baselineMessageIDs: Set<String>
    ) -> String? {
        let combined = responseSpeechSegments(
            from: messages,
            excludingMessageIDs: baselineMessageIDs,
            includeIncompleteParts: true
        ).map(\.text).joined(separator: "\n\n")
        guard !combined.isEmpty else { return nil }
        return combined
    }

    static func speakableText(from markdown: String) -> String {
        var value = markdown
        value = value.replacingOccurrences(
            of: "```[\\s\\S]*?```",
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "!?(?:\\[([^\\]]+)\\])\\([^\\)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "(?m)^\\s{0,3}(?:#{1,6}|>|[-*+]\\s)\\s*",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: "[`*_~]", with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginListening() {
        autoSendTask?.cancel()
        autoSendTask = nil
        isSilenceDetected = false
        if isMuted {
            recognitionAttemptID = nil
            state = .listening
            inputLevel = 0
            inputPitch = 0
            return
        }
        let attemptID = UUID()
        recognitionAttemptID = attemptID
        state = .starting
        inputLevel = 0
        inputPitch = 0

        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        Task { @MainActor [weak self] in
            guard let self,
                  self.recognitionAttemptID == attemptID,
                  self.state == .starting else { return }
            do {
                try await self.recognizer.start(
                    audioMode: .conversation,
                    automaticallyFinishesAfterSilence: false,
                    silenceTimeout: Self.automaticSilenceTimeout,
                    onTranscript: { [weak self] hypothesis in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        let filteredHypothesis = self.filteredFillerEcho(from: hypothesis)
                        if self.state == .waitingToSend,
                           filteredHypothesis != self.liveHypothesis {
                            self.cancelAutoSendGracePeriod()
                        }
                        self.liveHypothesis = filteredHypothesis
                        self.transcript = Self.joinedTranscript(
                            committed: self.committedTranscript,
                            live: filteredHypothesis
                        )
                    },
                    onFinalTranscript: { [weak self] finalTranscript in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.finishListening(with: finalTranscript)
                    },
                    onInputLevel: { [weak self] level in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.inputLevel = level
                    },
                    onPitch: { [weak self] pitch in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.inputPitch = pitch
                    },
                    onSilenceDetected: { [weak self] in
                        guard let self,
                              self.recognitionAttemptID == attemptID,
                              self.inputMode == .automatic else { return }
                        self.isSilenceDetected = true
                        if !self.isSendHeld {
                            self.beginAutoSendGracePeriod()
                        }
                    },
                    onVoiceActivityResumed: { [weak self] hypothesis in
                        guard let self else { return true }
                        guard self.recognitionAttemptID == attemptID else { return false }
                        guard !self.isOnlyFillerEcho(hypothesis) else { return false }
                        self.isSilenceDetected = false
                        self.cancelAutoSendGracePeriod()
                        return true
                    },
                    onError: { [weak self] message in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.fail(with: message)
                    }
                )
                guard self.recognitionAttemptID == attemptID else { return }
                guard self.state == .starting, self.recognizer.isRecording else {
                    self.recognitionAttemptID = nil
                    self.recognizer.cancel()
                    return
                }
                self.state = .listening
            } catch {
                guard self.recognitionAttemptID == attemptID else { return }
                self.fail(with: error.localizedDescription)
            }
        }
        #else
        state = .inactive
        #endif
    }

    private func finishListening(with finalTranscript: String) {
        guard state == .listening || state == .waitingToSend || state == .starting || state == .finalizing else { return }
        recognitionAttemptID = nil
        autoSendTask?.cancel()
        autoSendTask = nil
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        state = .finalizing
        inputLevel = 0
        inputPitch = 0
        isSilenceDetected = false
        let filteredFinalTranscript = filteredFillerEcho(from: finalTranscript)
        committedTranscript = Self.joinedTranscript(
            committed: committedTranscript,
            live: filteredFinalTranscript.isEmpty ? liveHypothesis : filteredFinalTranscript
        )
        activeFillerPhrase = nil
        isSpeakingFiller = false
        transcriptBeforeFiller = ""
        liveHypothesis = ""
        transcript = committedTranscript

        if committedTranscript.isEmpty {
            resumeInput()
        } else {
            state = .submitting
            sendRequestToken &+= 1
        }
    }

    private func beginAutoSendGracePeriod() {
        guard inputMode == .automatic, state == .listening, !isSendHeld else { return }
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        state = .waitingToSend
        autoSendTask?.cancel()
        autoSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.automaticSendGracePeriod))
            guard !Task.isCancelled, let self, self.state == .waitingToSend else { return }
            self.beginThinkingFillerBeforeSend()
        }
    }

    private func beginThinkingFillerBeforeSend() {
        guard state == .waitingToSend else { return }
        autoSendTask = nil
        speakThinkingFiller()

        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        autoSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.state == .waitingToSend else { return }
            self.finalizePendingAutoSend()
        }
        #else
        finalizePendingAutoSend()
        #endif
    }

    private func cancelAutoSendGracePeriod() {
        guard state == .waitingToSend else { return }
        autoSendTask?.cancel()
        autoSendTask = nil
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if speechPurpose == .thinkingFiller {
            speechPurpose = nil
            isSpeakingFiller = false
            synthesizer.stopSpeaking(at: .immediate)
        }
        activeFillerPhrase = nil
        transcriptBeforeFiller = ""
        #endif
        state = .listening
    }

    private func finalizePendingAutoSend() {
        guard state == .waitingToSend else { return }
        autoSendTask?.cancel()
        autoSendTask = nil
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if speechPurpose == .thinkingFiller {
            speechPurpose = nil
            isSpeakingFiller = false
            synthesizer.stopSpeaking(at: .immediate)
        }
        #endif
        state = .finalizing
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        recognizer.stop()
        #endif
    }

    private func speakThinkingFiller() {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        let phrases = [
            String(localized: "Hmm, let me think about that."),
            String(localized: "Let me check on that."),
            String(localized: "Give me a moment."),
            String(localized: "Let me work through that."),
            String(localized: "One moment while I think."),
            String(localized: "Let me take a closer look."),
            String(localized: "I'm thinking that through."),
            String(localized: "Let me see what I can find."),
            String(localized: "Okay, give me a second."),
        ]
        let phrase = phrases[fillerPhraseIndex % phrases.count]
        fillerPhraseIndex = (fillerPhraseIndex + 1) % phrases.count
        speechPurpose = .thinkingFiller
        activeFillerPhrase = phrase
        isSpeakingFiller = true
        transcriptBeforeFiller = liveHypothesis

        let utterance = AVSpeechUtterance(string: phrase)
        if let voice = voiceStore.resolvedVoice() {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        utterance.volume = 0.72
        synthesizer.speak(utterance)
        #endif
    }

    private func speakResponse(_ response: String) {
        pendingResponseText = response
        submittedTranscript = nil
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = nil
        state = .speakingResponse
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        stopWaitingEarcon()
        activeResponseSpeechText = response
        if inputMode == .holdToTalk || isMuted {
            isMonitoringResponseSpeech = false
            speak(response, purpose: .response)
        } else if isMonitoringResponseSpeech, recognizer.isRecording {
            speak(response, purpose: .response, cancelsRecognition: false)
        } else {
            beginResponseSpeech(response)
        }
        #else
        state = .inactive
        #endif
    }

    private func continueResponseTurn() {
        if let segment = responseSpeechQueue.popFirst() {
            speakResponse(segment.text)
            return
        }

        pendingResponseText = nil
        if Self.shouldKeepWaitingForResponse(
            isSessionBusy: isResponseSessionBusy,
            hasObservedBusyState: hasObservedResponseBusyState,
            hasObservedContent: hasObservedResponseContent
        ) {
            state = .waitingForResponse
            #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
            recognitionAttemptID = nil
            recognizer.cancel(deactivatesAudioSession: false)
            isMonitoringResponseSpeech = false
            activeResponseSpeechText = nil
            startWaitingEarcon()
            #endif
            return
        }

        finishResponseTurn()
    }

    private func finishResponseTurn() {
        responseBaselineMessageIDs = []
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        pendingResponseText = nil
        submittedTranscript = nil
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil

        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        stopWaitingEarcon()
        if inputMode == .holdToTalk {
            recognizer.cancel()
            isMonitoringResponseSpeech = false
            state = .ready
        } else if isMonitoringResponseSpeech {
            state = .listening
        } else {
            beginListening()
        }
        responseEchoCooldownTask?.cancel()
        responseEchoCooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.activeResponseSpeechText = nil
            self?.responseEchoCooldownTask = nil
        }
        #else
        state = .inactive
        #endif
    }

    #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
    private func beginResponseSpeech(_ response: String) {
        guard !isMuted else {
            speak(response, purpose: .response)
            return
        }
        beginResponseRecognition(responseToSpeak: response)
    }

    private func beginResponseMonitoring() {
        guard state == .speakingResponse,
              !isMuted,
              inputMode == .automatic,
              !recognizer.isRecording else { return }
        beginResponseRecognition(responseToSpeak: nil)
    }

    private func beginResponseRecognition(responseToSpeak: String?) {
        let attemptID = UUID()
        recognitionAttemptID = attemptID
        Task { @MainActor [weak self] in
            guard let self,
                  self.recognitionAttemptID == attemptID,
                  self.state == .speakingResponse else { return }
            do {
                try await self.recognizer.start(
                    audioMode: .conversation,
                    automaticallyFinishesAfterSilence: false,
                    silenceTimeout: Self.automaticSilenceTimeout,
                    onTranscript: { [weak self] hypothesis in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.handleResponseSpeechHypothesis(hypothesis)
                    },
                    onFinalTranscript: { [weak self] finalTranscript in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.handleResponseSpeechFinalTranscript(finalTranscript)
                    },
                    onInputLevel: { [weak self] level in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.inputLevel = level
                    },
                    onPitch: { [weak self] pitch in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.inputPitch = pitch
                    },
                    onSilenceDetected: { [weak self] in
                        guard let self,
                              self.recognitionAttemptID == attemptID,
                              self.state == .listening,
                              self.inputMode == .automatic else { return }
                        self.isSilenceDetected = true
                        if !self.isSendHeld {
                            self.beginAutoSendGracePeriod()
                        }
                    },
                    onVoiceActivityResumed: { [weak self] hypothesis in
                        guard let self else { return true }
                        guard self.recognitionAttemptID == attemptID else { return false }
                        if self.state == .speakingResponse {
                            return !Self.isLikelySpokenEcho(
                                hypothesis: hypothesis,
                                spokenText: self.activeResponseSpeechText ?? ""
                            )
                        }
                        self.isSilenceDetected = false
                        self.cancelAutoSendGracePeriod()
                        return true
                    },
                    onError: { [weak self] _ in
                        guard let self, self.recognitionAttemptID == attemptID else { return }
                        self.isMonitoringResponseSpeech = false
                    }
                )
                guard self.recognitionAttemptID == attemptID else { return }
                guard self.state == .speakingResponse, self.recognizer.isRecording else {
                    self.recognitionAttemptID = nil
                    self.recognizer.cancel(deactivatesAudioSession: false)
                    return
                }
                self.isMonitoringResponseSpeech = true
            } catch {
                guard self.recognitionAttemptID == attemptID else { return }
                self.isMonitoringResponseSpeech = false
            }

            guard self.recognitionAttemptID == attemptID,
                  self.state == .speakingResponse else { return }
            if let responseToSpeak {
                self.speak(responseToSpeak, purpose: .response, cancelsRecognition: false)
            }
        }
    }

    private func speak(
        _ text: String,
        purpose: SpeechPurpose,
        cancelsRecognition: Bool = true
    ) {
        if cancelsRecognition {
            recognizer.cancel(deactivatesAudioSession: false)
        }
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            fail(with: error.localizedDescription)
            return
        }

        speechPurpose = purpose
        let utterance = AVSpeechUtterance(string: text)
        if let voice = voiceStore.resolvedVoice() {
            utterance.voice = voice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    private func handleResponseSpeechHypothesis(_ hypothesis: String) {
        let hypothesis = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hypothesis.isEmpty else { return }
        if let activeResponseSpeechText,
           Self.isLikelySpokenEcho(hypothesis: hypothesis, spokenText: activeResponseSpeechText) {
            bargeInCandidate = nil
            bargeInConfirmationTask?.cancel()
            bargeInConfirmationTask = nil
            return
        }

        if state == .speakingResponse {
            scheduleResponseSpeechInterruption(with: hypothesis)
            return
        }

        guard state == .listening || state == .waitingToSend else { return }
        if state == .waitingToSend {
            cancelAutoSendGracePeriod()
        }
        liveHypothesis = hypothesis
        transcript = Self.joinedTranscript(committed: committedTranscript, live: hypothesis)
        scheduleBargeInEndpointFallback()
    }

    private func handleResponseSpeechFinalTranscript(_ finalTranscript: String) {
        let finalTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEcho = activeResponseSpeechText.map {
            Self.isLikelySpokenEcho(hypothesis: finalTranscript, spokenText: $0)
        } ?? false
        if state == .speakingResponse {
            guard !finalTranscript.isEmpty, !isEcho else {
                isMonitoringResponseSpeech = false
                return
            }
            interruptResponseSpeech(with: finalTranscript)
        } else if Self.shouldFinalizePostResponseRecognition(in: state) {
            if !finalTranscript.isEmpty, !isEcho {
                finishListening(with: finalTranscript)
            } else {
                resumeInput()
            }
        }
        isMonitoringResponseSpeech = false
    }

    private func interruptResponseSpeech(with hypothesis: String) {
        guard state == .speakingResponse else { return }
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        bargeInCandidate = nil
        speechPurpose = nil
        synthesizer.stopSpeaking(at: .immediate)
        pendingResponseText = nil
        submittedTranscript = nil
        responseBaselineMessageIDs = []
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        responseEchoCooldownTask?.cancel()
        responseEchoCooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.activeResponseSpeechText = nil
            self?.responseEchoCooldownTask = nil
        }
        liveHypothesis = hypothesis
        transcript = Self.joinedTranscript(committed: committedTranscript, live: hypothesis)
        state = .listening
        scheduleBargeInEndpointFallback()
    }

    private func scheduleResponseSpeechInterruption(with hypothesis: String) {
        guard state == .speakingResponse else { return }
        bargeInCandidate = hypothesis
        guard bargeInConfirmationTask == nil else { return }

        bargeInConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled,
                  let self,
                  self.state == .speakingResponse,
                  let candidate = self.bargeInCandidate else {
                return
            }
            self.bargeInConfirmationTask = nil
            self.interruptResponseSpeech(with: candidate)
        }
    }

    private func scheduleBargeInEndpointFallback() {
        guard state == .listening else { return }
        bargeInEndpointTask?.cancel()
        bargeInEndpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.automaticSilenceTimeout))
            guard !Task.isCancelled,
                  let self,
                  self.state == .listening,
                  !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            self.bargeInEndpointTask = nil
            self.beginAutoSendGracePeriod()
        }
    }
    #endif

    private func speechDidFinish() {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        let completedPurpose = speechPurpose
        speechPurpose = nil
        switch completedPurpose {
        case .thinkingFiller:
            isSpeakingFiller = false
            guard state == .waitingToSend else { break }
            autoSendTask?.cancel()
            autoSendTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.finalizePendingAutoSend()
            }
        case .response:
            continueResponseTurn()
        case nil:
            break
        }
        #endif
    }

    #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
    private func startWaitingEarcon() {
        stopWaitingEarcon()
        waitingEarconTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                guard !Task.isCancelled, let self, self.state == .waitingForResponse else { return }
                self.playWaitingEarcon()
                try? await Task.sleep(for: .milliseconds(1_800))
            }
        }
    }

    private func stopWaitingEarcon() {
        waitingEarconTask?.cancel()
        waitingEarconTask = nil
        waitingEarconPlayer?.stop()
        waitingEarconEngine?.stop()
        waitingEarconPlayer = nil
        waitingEarconEngine = nil
    }

    private func playWaitingEarcon() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let engine: AVAudioEngine
            let player: AVAudioPlayerNode
            if let waitingEarconEngine, let waitingEarconPlayer {
                engine = waitingEarconEngine
                player = waitingEarconPlayer
            } else {
                engine = AVAudioEngine()
                player = AVAudioPlayerNode()
                engine.attach(player)
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                try engine.start()
                waitingEarconEngine = engine
                waitingEarconPlayer = player
            }

            guard let buffer = Self.waitingEarconBuffer() else { return }
            player.scheduleBuffer(buffer)
            if !player.isPlaying {
                player.play()
            }
        } catch {
            stopWaitingEarcon()
        }
    }

    private static func waitingEarconBuffer() -> AVAudioPCMBuffer? {
        let sampleRate = 44_100.0
        let toneDuration = 0.105
        let gapDuration = 0.075
        let frequencies = [587.33, 659.25, 783.99]
        let totalDuration = Double(frequencies.count) * toneDuration + Double(frequencies.count - 1) * gapDuration
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            return nil
        }

        buffer.frameLength = frameCount
        for frame in 0 ..< Int(frameCount) {
            let time = Double(frame) / sampleRate
            samples[frame] = 0

            for (index, frequency) in frequencies.enumerated() {
                let start = Double(index) * (toneDuration + gapDuration)
                let localTime = time - start
                guard localTime >= 0, localTime < toneDuration else { continue }
                let fadeDuration = 0.018
                let attack = min(localTime / fadeDuration, 1)
                let release = min((toneDuration - localTime) / fadeDuration, 1)
                let envelope = Float(min(attack, release))
                samples[frame] = Float(sin(2 * .pi * frequency * localTime)) * envelope * 0.12
                break
            }
        }
        return buffer
    }
    #endif

    private func fail(with message: String) {
        errorMessage = message
        stop()
    }

    private func resumeInput() {
        if inputMode == .holdToTalk {
            state = .ready
            inputLevel = 0
            inputPitch = 0
        } else {
            beginListening()
        }
    }

    private func preserveCurrentTranscript() {
        committedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        liveHypothesis = ""
        transcript = committedTranscript
    }

    private func cancelListening() {
        recognitionAttemptID = nil
        autoSendTask?.cancel()
        autoSendTask = nil
        inputLevel = 0
        inputPitch = 0
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if speechPurpose == .thinkingFiller {
            speechPurpose = nil
            isSpeakingFiller = false
            synthesizer.stopSpeaking(at: .immediate)
        }
        recognizer.cancel()
        #endif
        activeFillerPhrase = nil
        isSpeakingFiller = false
        transcriptBeforeFiller = ""
    }

    private func interruptResponseForHoldToTalk() {
        guard state == .speakingResponse else { return }
        recognitionAttemptID = nil
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        speechPurpose = nil
        synthesizer.stopSpeaking(at: .immediate)
        recognizer.cancel(deactivatesAudioSession: false)
        #endif
        pendingResponseText = nil
        activeResponseSpeechText = nil
        isMonitoringResponseSpeech = false
        responseBaselineMessageIDs = []
        responseSpeechQueue.reset()
        isResponseSessionBusy = false
        hasObservedResponseBusyState = false
        hasObservedResponseContent = false
        responseEchoCooldownTask?.cancel()
        responseEchoCooldownTask = nil
        bargeInCandidate = nil
        bargeInConfirmationTask?.cancel()
        bargeInConfirmationTask = nil
        state = .ready
    }

    private func filteredFillerEcho(from hypothesis: String) -> String {
        guard let analysis = fillerEchoAnalysis(hypothesis) else { return hypothesis }
        switch analysis {
        case .fillerOnly:
            return transcriptBeforeFiller
        case let .followedByUserSpeech(continuation):
            return Self.joinedTranscript(committed: transcriptBeforeFiller, live: continuation)
        }
    }

    private func isOnlyFillerEcho(_ hypothesis: String) -> Bool {
        fillerEchoAnalysis(hypothesis) == .fillerOnly
    }

    private enum FillerEchoAnalysis: Equatable {
        case fillerOnly
        case followedByUserSpeech(String)
    }

    private func fillerEchoAnalysis(_ hypothesis: String) -> FillerEchoAnalysis? {
        guard let activeFillerPhrase else { return nil }
        let baseline = Self.normalizedSpeech(transcriptBeforeFiller)
        let candidate = Self.normalizedSpeech(hypothesis)
        let filler = Self.normalizedSpeech(activeFillerPhrase)
        guard candidate.hasPrefix(baseline) else { return nil }

        let suffix = candidate.dropFirst(baseline.count).trimmingCharacters(in: .whitespaces)
        guard !suffix.isEmpty else { return nil }
        if filler.hasPrefix(suffix) {
            return .fillerOnly
        }
        if suffix.hasPrefix(filler) {
            let continuation = suffix.dropFirst(filler.count).trimmingCharacters(in: .whitespaces)
            if !continuation.isEmpty {
                return .followedByUserSpeech(continuation)
            }
        }
        return nil
    }

    private static func normalizedSpeech(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func isLikelySpokenEcho(hypothesis: String, spokenText: String) -> Bool {
        let hypothesis = normalizedSpeech(hypothesis)
        let spokenText = normalizedSpeech(spokenText)
        guard hypothesis.count >= 2, !spokenText.isEmpty else { return false }
        if spokenText.contains(hypothesis) {
            return true
        }

        let hypothesisWords = hypothesis.split(separator: " ").map(String.init)
        let spokenWords = spokenText.split(separator: " ").map(String.init)
        guard !hypothesisWords.isEmpty else { return false }

        let matchingWordCount = hypothesisWords.reduce(into: 0) { count, hypothesisWord in
            if spokenWords.contains(where: { spokenWord in
                wordsLikelyMatch(spokenWord, hypothesisWord)
            }) {
                count += 1
            }
        }
        return Double(matchingWordCount) / Double(hypothesisWords.count) >= 0.65
    }

    static func shouldFinalizePostResponseRecognition(in state: State) -> Bool {
        state == .listening || state == .waitingToSend || state == .finalizing
    }

    static func shouldKeepWaitingForResponse(
        isSessionBusy: Bool,
        hasObservedBusyState: Bool,
        hasObservedContent: Bool
    ) -> Bool {
        isSessionBusy || (!hasObservedBusyState && !hasObservedContent)
    }

    private static func wordsLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let shorterCount = min(lhs.count, rhs.count)
        if shorterCount >= 3, lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            return true
        }
        let sharedPrefixCount = zip(lhs, rhs).prefix { $0 == $1 }.count
        return sharedPrefixCount >= 4
    }

    private static func joinedTranscript(committed: String, live: String) -> String {
        let committed = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let live = live.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return live }
        if live.isEmpty { return committed }
        return committed + " " + live
    }
}

#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
extension ConversationModeController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            self?.speechDidFinish()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }
}
#endif
