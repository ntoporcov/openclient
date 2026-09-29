import XCTest
@testable import OpenClient

@MainActor
final class V2InitialTranscriptTests: XCTestCase {
    func testColdAndWarmInitialPagesUseBoundedWindowAndKeepHistoryCursor() async throws {
        for (cached, expected) in [(0, 20), (12, 20), (75, 75), (200, 200), (500, 200)] {
            var calls = 0
            let message = OpenCodeMessageEnvelope.local(role: "user", text: "Hello", messageID: "m", sessionID: "s")
            let page = try await SessionCoordinator().initialV2Transcript(cachedMessageCount: cached) { cursor, limit in
                XCTAssertNil(cursor)
                XCTAssertEqual(limit, expected)
                calls += 1
                return .init(messages: [message], olderCursor: "older")
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(page.messages, [message])
            XCTAssertEqual(page.olderCursor, "older")
        }
    }

    func testNonDisplayablePagesDoNotLeaveChatBlank() async throws {
        var cursors: [String?] = []
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "Visible", messageID: "m", sessionID: "s")
        let page = try await SessionCoordinator().initialV2Transcript(cachedMessageCount: 0) { cursor, _ in
            cursors.append(cursor)
            switch cursor {
            case nil: return .init(messages: [], olderCursor: "a")
            case "a": return .init(messages: [], olderCursor: "b")
            default: return .init(messages: [message], olderCursor: "c")
            }
        }
        XCTAssertEqual(cursors, [nil, "a", "b"])
        XCTAssertEqual(page.messages, [message])
        XCTAssertEqual(page.olderCursor, "c")
    }

    func testEmptyHistoryStopsAtTerminalPage() async throws {
        let page = try await SessionCoordinator().initialV2Transcript(cachedMessageCount: 0) { _, _ in
            .init(messages: [], olderCursor: nil)
        }
        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertNil(page.olderCursor)
    }

    func testRepeatedCursorFailsInsteadOfLooping() async {
        var calls = 0
        do {
            _ = try await SessionCoordinator().initialV2Transcript(cachedMessageCount: 0) { _, _ in
                calls += 1
                return .init(messages: [], olderCursor: "repeat")
            }
            XCTFail("Expected repeated cursor to fail")
        } catch {
            XCTAssertTrue(error is OpenCodeV2TransportError)
        }
        XCTAssertEqual(calls, 2)
    }
}
