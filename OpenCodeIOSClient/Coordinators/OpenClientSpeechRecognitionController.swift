import Combine
import Foundation

#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
import AVFoundation
import Speech
import UIKit

private struct OpenClientAudioMetrics: Sendable {
    let level: Float
    let pitch: Float
}

private final class OpenClientAudioLevelSink: @unchecked Sendable {
    private let handler: @MainActor @Sendable (OpenClientAudioMetrics) -> Void

    init(handler: @escaping @MainActor @Sendable (OpenClientAudioMetrics) -> Void) {
        self.handler = handler
    }

    nonisolated func report(_ metrics: OpenClientAudioMetrics) {
        Task { @MainActor [handler] in
            handler(metrics)
        }
    }
}

@MainActor
final class OpenClientSpeechRecognitionController: ObservableObject {
    enum State: Equatable {
        case idle
        case authorizing
        case recording
        case finishing

        var isActive: Bool {
            self != .idle
        }
    }

    enum AudioMode {
        case dictation
        case conversation
    }

    private enum RecognitionError: LocalizedError {
        case recognizerUnavailable
        case speechDenied
        case microphoneDenied

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable:
                String(localized: "Dictation is not available right now.")
            case .speechDenied:
                String(localized: "Enable Speech Recognition for OpenClient in Settings to dictate messages.")
            case .microphoneDenied:
                String(localized: "Enable Microphone access for OpenClient in Settings to dictate messages.")
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var inputLevel: CGFloat = 0
    @Published private(set) var inputPitch: CGFloat = 0

    private let speechRecognizer = SFSpeechRecognizer()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hasAudioTap = false
    private var hasEndedAudio = false
    private var activeStartID: UUID?
    private var activeRecognitionID: UUID?
    private var finishCleanupTask: Task<Void, Never>?
    private var silenceDetectionTask: Task<Void, Never>?
    private var latestTranscript = ""
    private var hasDetectedSpeech = false
    private var hasReportedSilence = false
    private var lastVoiceActivityAt = Date.distantPast
    private var automaticallyFinishesAfterSilence = false
    private var silenceTimeout: TimeInterval = 1.1
    private var audioMode: AudioMode = .dictation
    private var onTranscript: ((String) -> Void)?
    private var onFinalTranscript: ((String) -> Void)?
    private var onInputLevel: ((CGFloat) -> Void)?
    private var onPitch: ((CGFloat) -> Void)?
    private var onSilenceDetected: (() -> Void)?
    private var onVoiceActivityResumed: ((String) -> Bool)?
    private var onError: ((String) -> Void)?

    var isRecording: Bool {
        state == .recording
    }

    var isActive: Bool {
        state.isActive
    }

    static func isCurrentRecognitionCallback(_ recognitionID: UUID, activeRecognitionID: UUID?) -> Bool {
        recognitionID == activeRecognitionID
    }

    init() {
        speechRecognizer?.queue = .main
    }

    func start(
        audioMode: AudioMode = .dictation,
        automaticallyFinishesAfterSilence: Bool = false,
        silenceTimeout: TimeInterval = 1.1,
        onTranscript: @escaping (String) -> Void,
        onFinalTranscript: ((String) -> Void)? = nil,
        onInputLevel: ((CGFloat) -> Void)? = nil,
        onPitch: ((CGFloat) -> Void)? = nil,
        onSilenceDetected: (() -> Void)? = nil,
        onVoiceActivityResumed: ((String) -> Bool)? = nil,
        onError: @escaping (String) -> Void
    ) async throws {
        if state != .idle {
            cleanup(cancelTask: true, deactivatesAudioSession: false)
        }
        self.audioMode = audioMode
        self.automaticallyFinishesAfterSilence = automaticallyFinishesAfterSilence
        self.silenceTimeout = silenceTimeout
        self.onTranscript = onTranscript
        self.onFinalTranscript = onFinalTranscript
        self.onInputLevel = onInputLevel
        self.onPitch = onPitch
        self.onSilenceDetected = onSilenceDetected
        self.onVoiceActivityResumed = onVoiceActivityResumed
        self.onError = onError
        latestTranscript = ""
        hasDetectedSpeech = false
        hasReportedSilence = false
        lastVoiceActivityAt = .distantPast
        state = .authorizing
        let startID = UUID()
        activeStartID = startID

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            resetAfterStartFailure()
            throw RecognitionError.recognizerUnavailable
        }

        let speechStatus = await requestSpeechAuthorization()
        guard isCurrentAuthorizingStart(startID) else { return }

        guard speechStatus == .authorized else {
            resetAfterStartFailure()
            throw RecognitionError.speechDenied
        }

        let hasMicrophonePermission = await requestMicrophonePermission()
        guard isCurrentAuthorizingStart(startID) else { return }

        guard hasMicrophonePermission else {
            resetAfterStartFailure()
            throw RecognitionError.microphoneDenied
        }

        do {
            try configureAudioSession(for: audioMode)

            let engine = AVAudioEngine()
            audioEngine = engine

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            recognitionRequest = request
            hasEndedAudio = false

            let inputNode = engine.inputNode
            if case .conversation = audioMode {
                try inputNode.setVoiceProcessingEnabled(true)
            }
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw RecognitionError.recognizerUnavailable
            }

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: recordingFormat,
                block: Self.makeAudioTapBlock(
                    request: request,
                    levelSink: OpenClientAudioLevelSink { [weak self] metrics in
                        self?.updateVoiceMetrics(metrics)
                    }
                )
            )
            hasAudioTap = true

            let recognitionID = UUID()
            activeRecognitionID = recognitionID
            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    self?.handleRecognition(result: result, error: error, recognitionID: recognitionID)
                }
            }

            engine.prepare()
            try engine.start()
            activeStartID = nil
            state = .recording
        } catch {
            cleanup(cancelTask: true, deactivatesAudioSession: true)
            throw error
        }
    }

    func stop() {
        switch state {
        case .recording:
            finishAudioInput()
        case .authorizing:
            cleanup(cancelTask: true, deactivatesAudioSession: true)
        case .idle, .finishing:
            return
        }
    }

    func cancel(deactivatesAudioSession: Bool = true) {
        cleanup(cancelTask: true, deactivatesAudioSession: deactivatesAudioSession)
    }

    func clearError() {
    }

    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: Error?,
        recognitionID: UUID
    ) {
        guard Self.isCurrentRecognitionCallback(recognitionID, activeRecognitionID: activeRecognitionID) else { return }
        if let result {
            let transcript = result.bestTranscription.formattedString
            if !transcript.isEmpty {
                let transcriptChanged = transcript != latestTranscript
                latestTranscript = transcript
                onTranscript?(transcript)
                if transcriptChanged {
                    markVoiceActivity(
                        allowsResumingFromSilence: true,
                        recognizedTranscript: transcript
                    )
                }
            }

            if result.isFinal {
                completeRecognition(with: transcript)
                return
            }
        }

        if let error, state.isActive {
            if state == .finishing {
                completeRecognition(with: latestTranscript)
            } else {
                onError?(error.localizedDescription)
                cleanup(cancelTask: true, deactivatesAudioSession: true)
            }
        }
    }

    private func completeRecognition(with transcript: String) {
        let finalTranscript = transcript.isEmpty ? latestTranscript : transcript
        let completion = onFinalTranscript
        let shouldDeactivate = audioMode == .dictation
        cleanup(cancelTask: false, deactivatesAudioSession: shouldDeactivate)
        completion?(finalTranscript)
    }

    private func finishAudioInput() {
        guard state == .recording || state == .authorizing else { return }
        state = .finishing
        inputLevel = 0
        inputPitch = 0
        onInputLevel?(0)
        onPitch?(0)
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil

        stopEngineAndEndAudio()

        finishCleanupTask?.cancel()
        finishCleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.state == .finishing else { return }
            self.completeRecognition(with: self.latestTranscript)
        }
    }

    private func cleanup(cancelTask: Bool, deactivatesAudioSession: Bool) {
        finishCleanupTask?.cancel()
        finishCleanupTask = nil
        silenceDetectionTask?.cancel()
        silenceDetectionTask = nil

        stopEngineAndEndAudio()

        if cancelTask {
            recognitionTask?.cancel()
        }

        recognitionRequest = nil
        recognitionTask = nil
        activeRecognitionID = nil
        audioEngine = nil
        hasEndedAudio = false
        activeStartID = nil
        inputLevel = 0
        inputPitch = 0
        state = .idle
        automaticallyFinishesAfterSilence = false
        hasDetectedSpeech = false
        hasReportedSilence = false
        onTranscript = nil
        onFinalTranscript = nil
        onInputLevel = nil
        onPitch = nil
        onSilenceDetected = nil
        onVoiceActivityResumed = nil
        onError = nil

        if deactivatesAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func stopEngineAndEndAudio() {
        if audioEngine?.isRunning == true {
            audioEngine?.stop()
        }

        if hasAudioTap {
            audioEngine?.inputNode.removeTap(onBus: 0)
            hasAudioTap = false
        }

        if !hasEndedAudio {
            recognitionRequest?.endAudio()
            hasEndedAudio = true
        }
    }

    private func resetAfterStartFailure() {
        state = .idle
        hasEndedAudio = false
        activeStartID = nil
        inputLevel = 0
        inputPitch = 0
        latestTranscript = ""
        hasDetectedSpeech = false
        hasReportedSilence = false
        onTranscript = nil
        onFinalTranscript = nil
        onInputLevel = nil
        onPitch = nil
        onSilenceDetected = nil
        onVoiceActivityResumed = nil
        onError = nil
    }

    private nonisolated static func makeAudioTapBlock(
        request: SFSpeechAudioBufferRecognitionRequest,
        levelSink: OpenClientAudioLevelSink
    ) -> AVAudioNodeTapBlock {
        { [weak request, levelSink] buffer, _ in
            request?.append(buffer)
            let level = Self.normalizedInputLevel(from: buffer)
            levelSink.report(
                OpenClientAudioMetrics(
                    level: level,
                    pitch: Self.normalizedPitch(from: buffer, level: level)
                )
            )
        }
    }

    private nonisolated static func normalizedInputLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }

        let channelCount = min(Int(buffer.format.channelCount), 2)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        let sampleStride = max(frameLength / 256, 1)
        var sum: Float = 0
        var sampleCount = 0

        for channel in 0 ..< channelCount {
            let samples = channelData[channel]
            var frame = 0
            while frame < frameLength {
                let sample = samples[frame]
                sum += sample * sample
                sampleCount += 1
                frame += sampleStride
            }
        }

        guard sampleCount > 0 else { return 0 }

        let rms = sqrt(sum / Float(sampleCount))
        return min(max((rms - 0.015) / 0.18, 0), 1)
    }

    private nonisolated static func normalizedPitch(from buffer: AVAudioPCMBuffer, level: Float) -> Float {
        guard level >= 0.04,
              let samples = buffer.floatChannelData?[0] else {
            return 0
        }

        let frameLength = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        let downsample = 2
        let sampleCount = frameLength / downsample
        guard sampleCount >= 160, sampleRate > 0 else { return 0 }

        var mean: Float = 0
        for index in 0 ..< sampleCount {
            mean += samples[index * downsample]
        }
        mean /= Float(sampleCount)

        let minLag = max(1, Int(sampleRate / 400) / downsample)
        let maxLag = min(sampleCount - 2, Int(sampleRate / 80) / downsample)
        guard minLag < maxLag else { return 0 }

        var bestLag = 0
        var bestCorrelation: Float = 0
        for lag in stride(from: minLag, through: maxLag, by: 2) {
            let availableSamples = sampleCount - lag
            var correlation: Float = 0
            var leadingEnergy: Float = 0
            var laggingEnergy: Float = 0

            for index in stride(from: 0, to: availableSamples, by: 2) {
                let leading = samples[index * downsample] - mean
                let lagging = samples[(index + lag) * downsample] - mean
                correlation += leading * lagging
                leadingEnergy += leading * leading
                laggingEnergy += lagging * lagging
            }

            let energy = sqrt(leadingEnergy * laggingEnergy)
            guard energy > 0 else { continue }
            let normalizedCorrelation = correlation / energy
            if normalizedCorrelation > bestCorrelation {
                bestCorrelation = normalizedCorrelation
                bestLag = lag
            }
        }

        guard bestLag > 0, bestCorrelation >= 0.34 else { return 0 }
        let pitch = sampleRate / Float(bestLag * downsample)
        return min(max((pitch - 70) / 330, 0.03), 1)
    }

    private func updateVoiceMetrics(_ metrics: OpenClientAudioMetrics) {
        guard state == .recording else { return }
        let clampedLevel = min(max(CGFloat(metrics.level), 0), 1)
        inputLevel = inputLevel * 0.62 + clampedLevel * 0.38
        if metrics.pitch > 0 {
            let clampedPitch = min(max(CGFloat(metrics.pitch), 0), 1)
            inputPitch = inputPitch * 0.70 + clampedPitch * 0.30
        } else {
            inputPitch *= 0.78
        }
        onInputLevel?(inputLevel)
        onPitch?(inputPitch)

        if inputLevel >= 0.08 {
            // Resume decisions use changed recognition hypotheses so app playback cannot cancel its own grace period.
            markVoiceActivity(allowsResumingFromSilence: false, recognizedTranscript: nil)
        }
    }

    private func markVoiceActivity(
        allowsResumingFromSilence: Bool,
        recognizedTranscript: String?
    ) {
        hasDetectedSpeech = true
        lastVoiceActivityAt = Date()
        if hasReportedSilence,
           allowsResumingFromSilence,
           let recognizedTranscript,
           onVoiceActivityResumed?(recognizedTranscript) != false {
            hasReportedSilence = false
        }
        guard automaticallyFinishesAfterSilence || onSilenceDetected != nil else { return }
        guard silenceDetectionTask == nil else { return }

        silenceDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled, let self else { return }
                guard self.state == .recording else { return }
                guard self.hasDetectedSpeech else { continue }
                if !self.hasReportedSilence,
                   Date().timeIntervalSince(self.lastVoiceActivityAt) >= self.silenceTimeout {
                    self.hasReportedSilence = true
                    if self.automaticallyFinishesAfterSilence {
                        self.finishAudioInput()
                        return
                    }
                    self.onSilenceDetected?()
                }
            }
        }
    }

    private func isCurrentAuthorizingStart(_ startID: UUID) -> Bool {
        activeStartID == startID && state == .authorizing
    }

    private func configureAudioSession(for mode: AudioMode) throws {
        let audioSession = AVAudioSession.sharedInstance()
        switch mode {
        case .dictation:
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        case .conversation:
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        try audioSession.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        let audioApplication = AVAudioApplication.shared
        switch audioApplication.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
        @unknown default:
            return false
        }
    }
}
#endif
