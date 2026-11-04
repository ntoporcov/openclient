import XCTest
@testable import OpenClient

@MainActor
final class DesktopHandoffTests: XCTestCase {
    func testCompletedToolRemainsAnActionableDraftCardAfterDecode() throws {
        let json = #"{"id":"part","type":"tool","tool":"openclient_request_remote_access","sessionID":"session","messageID":"message","state":{"status":"completed","input":{"reason":"Sign in"},"metadata":{"renderer":"openclient.remote-desktop","payload":{"requestID":"00000000-0000-0000-0000-000000000001","sessionID":"session","messageID":"message","reason":"Sign in","mode":"draft"}}}}"#
        let part = try JSONDecoder().decode(OpenCodePart.self, from: Data(json.utf8))
        let handoff = try XCTUnwrap(OpenClientDesktopHandoff(part: part))
        XCTAssertTrue(handoff.preparesFollowupDraft)
        XCTAssertNil(handoff.outcome, "Returning the card must not claim the human task is done")
        let restored = try JSONDecoder().decode(OpenClientDesktopHandoff.self, from: JSONEncoder().encode(handoff))
        XCTAssertEqual(restored, handoff)
    }

    func testExistingDraftIsPreservedAndFollowupIsNotDuplicated() {
        let store = ComposerStore(draftMessage: "I got a different login screen.")
        let updated = store.textAppendingDesktopFollowup()
        XCTAssertTrue(updated.hasPrefix("I got a different login screen.\n\n"))
        XCTAssertEqual(store.draftMessage, "I got a different login screen.", "Preparing text must not send or mutate the draft")
        store.draftMessage = updated
        XCTAssertEqual(store.textAppendingDesktopFollowup(), updated)
    }

    func testEmptyDraftGetsOnlyFollowupAndLegacyModeStillDecodes() throws {
        let store = ComposerStore()
        XCTAssertEqual(store.textAppendingDesktopFollowup(), String(localized: "I’ve finished the desktop task. Please continue."))
        let data = Data(#"{"requestID":"00000000-0000-0000-0000-000000000001","sessionID":"session","messageID":"message","reason":"Sign in"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(OpenClientDesktopHandoff.self, from: data).preparesFollowupDraft)
    }
}
