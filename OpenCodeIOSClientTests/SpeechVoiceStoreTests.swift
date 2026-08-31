import XCTest
@testable import OpenClient

@MainActor
final class SpeechVoiceStoreTests: XCTestCase {
    func testAutomaticSelectionPrefersHighestQualityCompatibleVoice() {
        let options = [
            SpeechVoiceOption(identifier: "standard", name: "Standard", language: "en-US", quality: .standard),
            SpeechVoiceOption(identifier: "enhanced", name: "Enhanced", language: "en-US", quality: .enhanced),
            SpeechVoiceOption(identifier: "premium", name: "Premium", language: "en-GB", quality: .premium),
            SpeechVoiceOption(identifier: "italian", name: "Italian", language: "it-IT", quality: .premium),
        ]

        XCTAssertEqual(
            SpeechVoiceStore.preferredVoiceIdentifier(
                from: options,
                preferredLanguage: "en-US",
                selectedIdentifier: nil
            ),
            "premium"
        )
    }

    func testExplicitInstalledVoiceWinsOverAutomaticQualityRanking() {
        let options = [
            SpeechVoiceOption(identifier: "standard", name: "Standard", language: "en-US", quality: .standard),
            SpeechVoiceOption(identifier: "premium", name: "Premium", language: "en-US", quality: .premium),
        ]

        XCTAssertEqual(
            SpeechVoiceStore.preferredVoiceIdentifier(
                from: options,
                preferredLanguage: "en-US",
                selectedIdentifier: "standard"
            ),
            "standard"
        )
    }

    func testHoldToTalkPreferencePersists() {
        let suiteName = "SpeechVoiceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SpeechVoiceStore(defaults: defaults)
        XCTAssertFalse(store.isHoldToTalkEnabled)

        store.setHoldToTalkEnabled(true)

        XCTAssertTrue(SpeechVoiceStore(defaults: defaults).isHoldToTalkEnabled)
    }
}
