import Combine
import XCTest
@testable import OpenClient

@MainActor
final class V2TranscriptPerformanceTests: XCTestCase {
    func testReplacementMatchesExistingSemanticsAcrossUpdatesAndRemoval() throws {
        var state = OpenCodeDirectorySyncState()
        var reference = state
        let a = try message("z", text: "original")
        let b = try message("a", text: "second")
        let replacement = try message("z", text: "updated")
        let hiddenOnly = try message("z", text: "hidden", type: "step-start")
        let other = try message("other", text: "other session")
        state.replaceMessagesPreservingOrder([other], forSessionID: "other")
        reference = state
        for page in [[a, b, replacement], [b, hiddenOnly], [a], [], [], [b, a]] {
            let before = state
            legacyReplace(page, state: &reference)
            let changed = state.replaceMessagesPreservingOrder(page, forSessionID: "session")
            XCTAssertEqual(state, reference)
            XCTAssertEqual(changed, before != reference)
            XCTAssertEqual(state.messageEnvelopes(forSessionID: "other"), [other])
        }
        XCTAssertEqual(state.messagesBySessionID["session"]?.map(\.id), ["a", "z"])
    }

    func testReplacementPreservesPartOrderAndDuplicates() throws {
        var envelope = try message("message", text: "one")
        envelope.parts += [try message("message", text: "two").parts[0],
            try message("message", text: "skipped", type: "patch").parts[0]]
        var state = OpenCodeDirectorySyncState()
        state.replaceMessagesPreservingOrder([envelope], forSessionID: "session")
        XCTAssertEqual(state.partsByMessageID["message"]?.compactMap(\.text), ["one", "two"])
        XCTAssertFalse(state.replaceMessagesPreservingOrder([envelope], forSessionID: "session"))
    }

    func testDirectoryPublishesOnlyChangedTranscripts() throws {
        let store = DirectoryStore()
        let original = try message("message", text: "one")
        let updated = try message("message", text: "two")
        var publications = 0
        let observation = store.syncStore.objectWillChange.sink { publications += 1 }
        store.applyV2Messages([original], forSessionID: "session")
        store.applyV2Messages([original], forSessionID: "session")
        XCTAssertEqual(publications, 1)
        store.applyV2Messages([updated], forSessionID: "session")
        XCTAssertEqual(publications, 2)
        store.applyV2Messages([], forSessionID: "session")
        XCTAssertEqual(publications, 3)
        XCTAssertNil(store.syncState.partsByMessageID[original.id])
        withExtendedLifetime(observation) {}
    }

    func testMeasureUnchangedThousandMessageV2Replacement() throws {
        let messages = try (0..<1_000).map { try message("msg-\($0)", text: "Transcript \($0)") }
        var state = OpenCodeDirectorySyncState()
        state.replaceMessagesPreservingOrder(messages, forSessionID: "session")
        measure {
            for _ in 0..<5 { state.replaceMessagesPreservingOrder(messages, forSessionID: "session") }
        }
        XCTAssertEqual(state.messageCount(forSessionID: "session"), 1_000)
    }

    func testMeasureLegacyUnchangedThousandMessageV2Replacement() throws {
        let messages = try (0..<1_000).map { try message("msg-\($0)", text: "Transcript \($0)") }
        var state = OpenCodeDirectorySyncState()
        legacyReplace(messages, state: &state)
        measure {
            for _ in 0..<5 { legacyReplace(messages, state: &state) }
        }
        XCTAssertEqual(state.messageCount(forSessionID: "session"), 1_000)
    }

    // Pre-optimization implementation, used as both a semantic oracle and a controlled baseline.
    private func legacyReplace(_ messages: [OpenCodeMessageEnvelope], state: inout OpenCodeDirectorySyncState) {
        for id in state.messagesBySessionID["session"]?.map(\.id) ?? [] { state.partsByMessageID[id] = nil }
        state.messagesBySessionID["session"] = []
        var ordered: [OpenCodeMessageEnvelope] = []
        var indices: [String: Int] = [:]
        for message in messages {
            if let index = indices[message.id] { ordered[index] = message }
            else { indices[message.id] = ordered.count; ordered.append(message) }
        }
        for message in ordered { state.appendMessageEnvelope(message, forSessionID: "session") }
    }

    private func message(_ id: String, text: String, type: String = "text") throws -> OpenCodeMessageEnvelope {
        let object: [String: Any] = [
            "info": ["id": id, "sessionID": "session", "role": "assistant"],
            "parts": [["id": "part-\(id)", "messageID": id, "sessionID": "session", "type": type, "text": text]]
        ]
        return try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
