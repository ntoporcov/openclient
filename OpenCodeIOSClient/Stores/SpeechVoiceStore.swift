import AVFoundation
import Combine
import Foundation

enum SpeechVoiceQuality: Int, Codable, Comparable, Sendable {
    case standard
    case enhanced
    case premium

    static func < (lhs: SpeechVoiceQuality, rhs: SpeechVoiceQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: LocalizedStringResource {
        switch self {
        case .standard: "Standard"
        case .enhanced: "Enhanced"
        case .premium: "Premium"
        }
    }
}

struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: SpeechVoiceQuality

    var id: String { identifier }
}

enum PersonalVoiceAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case unsupported
}

@MainActor
final class SpeechVoiceStore: NSObject, ObservableObject {
    static let selectedVoiceIdentifierKey = "selectedSpeechVoiceIdentifier"
    static let holdToTalkEnabledKey = "talkHoldToTalkEnabled"

    @Published private(set) var voiceOptions: [SpeechVoiceOption] = []
    @Published private(set) var selectedVoiceIdentifier: String?
    @Published private(set) var isHoldToTalkEnabled: Bool
    @Published private(set) var previewingVoiceIdentifier: String?
    @Published private(set) var isPreviewingAutomaticVoice = false
    @Published private(set) var personalVoiceAccess: PersonalVoiceAccess = .notDetermined
    @Published private(set) var isRequestingPersonalVoiceAccess = false

    private let defaults: UserDefaults
    private let previewSynthesizer = AVSpeechSynthesizer()
    private var activePreviewUtterance: AVSpeechUtterance?
    private var isPreviewAudioSessionActive = false
    private var observations: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedVoiceIdentifier = defaults.string(forKey: Self.selectedVoiceIdentifierKey)
        isHoldToTalkEnabled = defaults.bool(forKey: Self.holdToTalkEnabledKey)
        super.init()
        previewSynthesizer.delegate = self
        refreshVoices()

        NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshVoices()
            }
            .store(in: &observations)
    }

    var preferredLanguage: String {
        let appLanguage = Bundle.main.preferredLocalizations.first ?? ""
        if appLanguage.contains("-") {
            return appLanguage
        }
        let currentLanguage = AVSpeechSynthesisVoice.currentLanguageCode()
        if Self.baseLanguage(currentLanguage) == Self.baseLanguage(appLanguage) {
            return currentLanguage
        }
        return appLanguage.isEmpty ? currentLanguage : appLanguage
    }

    var compatibleVoiceOptions: [SpeechVoiceOption] {
        let language = Self.baseLanguage(preferredLanguage)
        return voiceOptions.filter { Self.baseLanguage($0.language) == language }
    }

    var selectionSummary: String {
        if let selectedVoiceIdentifier,
           let selected = voiceOptions.first(where: { $0.identifier == selectedVoiceIdentifier }) {
            return selected.name
        }
        return String(localized: "Best Available")
    }

    func selectVoice(identifier: String?) {
        selectedVoiceIdentifier = identifier
        if let identifier {
            defaults.set(identifier, forKey: Self.selectedVoiceIdentifierKey)
        } else {
            defaults.removeObject(forKey: Self.selectedVoiceIdentifierKey)
        }
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        isHoldToTalkEnabled = isEnabled
        defaults.set(isEnabled, forKey: Self.holdToTalkEnabledKey)
    }

    func resolvedVoice(preferredLanguage: String? = nil) -> AVSpeechSynthesisVoice? {
        let language = preferredLanguage ?? self.preferredLanguage
        guard let identifier = Self.preferredVoiceIdentifier(
            from: voiceOptions,
            preferredLanguage: language,
            selectedIdentifier: selectedVoiceIdentifier
        ) else {
            return AVSpeechSynthesisVoice(language: language)
        }
        return AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice(language: language)
    }

    func previewVoice(identifier: String?) {
        let voice: AVSpeechSynthesisVoice?
        if let identifier {
            voice = AVSpeechSynthesisVoice(identifier: identifier)
        } else {
            voice = resolvedVoice()
        }
        guard let voice else { return }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true)
            isPreviewAudioSessionActive = true
        } catch {
            return
        }

        previewSynthesizer.stopSpeaking(at: .immediate)
        previewingVoiceIdentifier = identifier
        isPreviewingAutomaticVoice = identifier == nil
        let utterance = AVSpeechUtterance(string: String(localized: "Hello. This is how I will sound in voice conversations."))
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        activePreviewUtterance = utterance
        previewSynthesizer.speak(utterance)
    }

    func stopPreview() {
        guard let activePreviewUtterance else { return }
        if !previewSynthesizer.stopSpeaking(at: .immediate) {
            finishPreview(utteranceID: ObjectIdentifier(activePreviewUtterance))
        }
    }

    func isPreviewingVoice(identifier: String?) -> Bool {
        if let identifier {
            return !isPreviewingAutomaticVoice && identifier == previewingVoiceIdentifier
        }
        return isPreviewingAutomaticVoice
    }

    func requestPersonalVoiceAccess() {
        guard !isRequestingPersonalVoiceAccess else { return }
        isRequestingPersonalVoiceAccess = true
        AVSpeechSynthesizer.requestPersonalVoiceAuthorization { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.isRequestingPersonalVoiceAccess = false
                self.personalVoiceAccess = Self.personalVoiceAccess(from: status)
                self.refreshVoices()
            }
        }
    }

    func refreshVoices() {
        voiceOptions = AVSpeechSynthesisVoice.speechVoices()
            .map { voice in
                SpeechVoiceOption(
                    identifier: voice.identifier,
                    name: voice.name,
                    language: voice.language,
                    quality: Self.quality(from: voice.quality)
                )
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
                if lhs.language != rhs.language { return lhs.language.localizedCaseInsensitiveCompare(rhs.language) == .orderedAscending }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        personalVoiceAccess = Self.personalVoiceAccess(from: AVSpeechSynthesizer.personalVoiceAuthorizationStatus)
    }

    static func preferredVoiceIdentifier(
        from options: [SpeechVoiceOption],
        preferredLanguage: String,
        selectedIdentifier: String?
    ) -> String? {
        if let selectedIdentifier,
           options.contains(where: { $0.identifier == selectedIdentifier }) {
            return selectedIdentifier
        }

        let preferredBaseLanguage = Self.baseLanguage(preferredLanguage)
        let compatible = options.filter { Self.baseLanguage($0.language) == preferredBaseLanguage }
        let candidates = compatible.isEmpty ? options : compatible
        return candidates.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            let lhsExact = lhs.language.caseInsensitiveCompare(preferredLanguage) == .orderedSame
            let rhsExact = rhs.language.caseInsensitiveCompare(preferredLanguage) == .orderedSame
            if lhsExact != rhsExact { return lhsExact }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }.first?.identifier
    }

    private static func baseLanguage(_ language: String) -> String {
        language.split(separator: "-").first.map(String.init)?.lowercased() ?? language.lowercased()
    }

    private static func quality(from quality: AVSpeechSynthesisVoiceQuality) -> SpeechVoiceQuality {
        switch quality {
        case .premium: .premium
        case .enhanced: .enhanced
        default: .standard
        }
    }

    private static func personalVoiceAccess(
        from status: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus
    ) -> PersonalVoiceAccess {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .unsupported: .unsupported
        case .notDetermined: .notDetermined
        @unknown default: .unsupported
        }
    }

    private func finishPreview(utteranceID: ObjectIdentifier) {
        guard let activeUtterance = activePreviewUtterance,
              ObjectIdentifier(activeUtterance) == utteranceID else { return }
        self.activePreviewUtterance = nil
        previewingVoiceIdentifier = nil
        isPreviewingAutomaticVoice = false
        guard isPreviewAudioSessionActive else { return }
        isPreviewAudioSessionActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SpeechVoiceStore: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishPreview(utteranceID: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.finishPreview(utteranceID: utteranceID)
        }
    }
}
