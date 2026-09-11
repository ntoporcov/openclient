import XCTest
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenClient

@MainActor
final class ResponseTurnCaptionTests: XCTestCase {
#if canImport(UIKit)
    func testCaptionOccupiesSpaceOnlyWhileRevealed() async throws {
        let turn = try XCTUnwrap(project([message("answer", parts: [part(text: "Answer")])]).first)
        let visibility = ResponseActionsVisibility()
        let host = UIHostingController(rootView:
            ResponseTurnCaption(turn: turn, visibility: visibility) { EmptyView() }
                .transaction { $0.disablesAnimations = true }
        )
        let proposal = CGSize(width: 320, height: 1_000)
        let window = UIWindow(frame: CGRect(origin: .zero, size: proposal))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded()

        func awaitHeight(_ expected: CGFloat) async {
            let settled = expectation(description: "Observed caption height becomes \(expected)")
            Task { @MainActor in
                for _ in 0..<100 {
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    if abs(host.sizeThatFits(in: proposal).height - expected) < 0.5 {
                        settled.fulfill()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            await fulfillment(of: [settled], timeout: 2)
        }

        XCTAssertEqual(host.sizeThatFits(in: proposal).height, 0, accuracy: 0.5)
        visibility.tappedMessageID = "answer"
        await awaitHeight(44)
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, 44, accuracy: 0.5)
        visibility.tappedMessageID = "another-turn"
        await awaitHeight(0)
        XCTAssertEqual(host.sizeThatFits(in: proposal).height, 0, accuracy: 0.5)
    }
#endif

    func testCopyIncludesLoadedTurnAnswersOutsideDisplayedWindow() throws {
        let messages = [message("prompt", role: "user")] + (0..<20).map {
            message("answer-\($0)", parts: [part(text: "Answer \($0)")])
        }
        let turn = try XCTUnwrap(project(messages, displayed: ["answer-19"]).first)
        XCTAssertEqual(turn.anchorMessageID, "answer-19")
        XCTAssertEqual(turn.markdownParts, (0..<20).map { "Answer \($0)" })
    }

    func testConsecutiveAssistantsAndPartsProduceOneAnswerOnlyCaption() throws {
        let first = message("a1", parts: [
            part(text: "\n# Heading\n"),
            part(type: "reasoning", text: "Private reasoning"),
            part(text: "Hidden reasoning", reason: "MODEL REASONING"),
            part(text: "Synthetic context", synthetic: true),
            part(text: " \t\n"),
            part(text: "  **First answer**  \n")
        ])
        let last = message("a2", parts: [part(text: "\n```swift\nlet value = 42\n```\n")])
        let turns = project([message("u1", role: "user"), first, last])
        let turn = try XCTUnwrap(turns.first)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turn.id, "u1")
        XCTAssertEqual(turn.messageIDs, ["a1", "a2"])
        XCTAssertEqual(turn.anchorMessageID, "a2")
        XCTAssertEqual(turn.markdown, "# Heading\n\n  **First answer**  \n\n```swift\nlet value = 42\n```")
        XCTAssertEqual(turn.message, last)
    }

    func testTrailingToolAnchorsCaptionButKeepsLatestAnswerMetadata() throws {
        let answer = message("a1", parts: [part(text: "Answer")])
        let tool = message("a2", parts: [part(type: "tool", text: "Not an answer")])
        let turn = try XCTUnwrap(project([answer, tool]).first)

        XCTAssertEqual(turn.id, "a1")
        XCTAssertEqual(turn.messageIDs, ["a1", "a2"])
        XCTAssertEqual(turn.anchorMessageID, "a2")
        XCTAssertEqual(turn.markdown, "Answer")
        XCTAssertEqual(turn.message, answer)
    }

    func testHiddenTrailingToolFallsBackToLastDisplayedAssistant() throws {
        let answer = message("a1", parts: [part(text: "Answer")])
        let tool = message("a2", parts: [part(type: "tool")], completed: 1_750_000_005_000)
        let turn = try XCTUnwrap(project([answer, tool], displayed: ["a1"]).first)

        XCTAssertEqual(turn.anchorMessageID, "a1")
        XCTAssertEqual(turn.messageIDs, ["a1", "a2"])
        XCTAssertEqual(turn.completedAt, Date(timeIntervalSince1970: 1_750_000_005))
    }

    func testMultipleUserRoundsRemainSeparateWithoutParentIDs() {
        let turns = project([
            message("u1", role: "user"), message("a1", parts: [part(text: "First")]),
            message("u2", role: "user"), message("a2", parts: [part(text: "Second")]),
            message("a3", parts: [part(text: "Third")])
        ])

        XCTAssertEqual(turns.map(\.id), ["u1", "u2"])
        XCTAssertEqual(turns.map(\.messageIDs), [["a1"], ["a2", "a3"]])
        XCTAssertEqual(turns.map(\.markdown), ["First", "Second\n\nThird"])
    }

    func testBusyLatestTurnIsExcludedEvenWithCompletedIntermediateAnswer() {
        let historical = [message("u1", role: "user"), message("a1", parts: [part(text: "First")])]
        let latest = [
            message("u2", role: "user"),
            message("a2", parts: [part(text: "Working")], completed: 1_750_000_000_000),
            message("a3", parts: [part(type: "tool")])
        ]

        XCTAssertEqual(project(historical + latest, busy: true).map(\.id), ["u1"])
        XCTAssertEqual(project(historical + latest, busy: false).map(\.id), ["u1", "u2"])
        XCTAssertEqual(project(historical + [latest[0]], busy: true).map(\.id), ["u1"])
        XCTAssertTrue(project([historical[1]], busy: true).isEmpty)
    }

    func testLeadingAssistantsUseKnownParentAndSplitDistinctParents() {
        let turns = project([
            message("a1", parentID: "outside1", parts: [part(text: "First")]),
            message("a2", parts: [part(type: "tool")]),
            message("a3", parentID: "outside1", parts: [part(text: "Second")]),
            message("a4", parentID: "outside2", parts: [part(text: "Third")])
        ])

        XCTAssertEqual(turns.map(\.id), ["outside1", "outside2"])
        XCTAssertEqual(turns.map(\.messageIDs), [["a1", "a2", "a3"], ["a4"]])
        XCTAssertEqual(turns.map(\.anchorMessageID), ["a3", "a4"])
    }

    func testFallbackIdentityStaysStableAsAssistantsAreAppended() throws {
        let first = message("a1", parts: [part(text: "First")])
        let next = message("a2", parts: [part(text: "Second")])
        let initial = try XCTUnwrap(project([first]).first)
        let appended = try XCTUnwrap(project([first, next]).first)

        XCTAssertEqual(initial.id, "a1")
        XCTAssertEqual(appended.id, initial.id)
        XCTAssertEqual(appended.anchorMessageID, "a2")
    }

    func testCompactionBoundariesAndSummariesAreExcludedFromTurn() throws {
        let turns = project([
            message("u1", role: "user"),
            message("a1", parts: [part(text: "Before")]),
            message("boundary", role: "user", parts: [part(type: "compaction")]),
            message("summary", parentID: "boundary", summary: true, parts: [part(text: "Private summary")]),
            message("a2", parentID: "u1", parts: [part(text: "After")])
        ])
        let turn = try XCTUnwrap(turns.first)

        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turn.id, "u1")
        XCTAssertEqual(turn.messageIDs, ["a1", "a2"])
        XCTAssertEqual(turn.markdown, "Before\n\nAfter")
        XCTAssertEqual(turn.anchorMessageID, "a2")
    }

    func testNoCaptionWithoutCopyableAnswerOrVisibleAnchor() {
        XCTAssertTrue(project([]).isEmpty)
        XCTAssertTrue(project([
            message("a1", parts: [part(type: "reasoning", text: "Thinking")]),
            message("a2", parts: [part(type: "tool", text: "Output")]),
            message("a3", parts: [part(text: " \n"), part(text: "Context", synthetic: true)])
        ]).isEmpty)
        XCTAssertTrue(project([
            message("u1", role: "user"), message("a1", parts: [part(text: "Answer")])
        ], displayed: ["u1"]).isEmpty)
    }

    func testMissingCompletionRemainsNilRatherThanUsingStartCreationOrNow() throws {
        let turn = try XCTUnwrap(project([
            message("a1", parts: [part(text: "Answer")]),
            message("a2", parts: [part(type: "tool", end: .infinity)], completed: .nan)
        ]).first)

        XCTAssertNil(turn.completedAt)
    }

    func testTurnCompletionPrefersEachMessageCompletionIncludingLastTool() throws {
        let turn = try XCTUnwrap(project([
            message("a1", parts: [part(text: "Answer", end: 1_750_000_099_000)], completed: 1_750_000_002_000),
            message("a2", parts: [part(type: "tool", end: 1_750_000_003_000)], completed: 1_750_000_007_000)
        ]).first)

        XCTAssertEqual(turn.completedAt, Date(timeIntervalSince1970: 1_750_000_007))
    }

    func testTurnCompletionUsesNormalizedMaximumAndPerMessagePartFallback() throws {
        let messages = [
            message("a1", parts: [part(text: "Answer")], completed: 1_750_000_010),
            message("a2", parts: [part(type: "tool", end: 1_750_000_008_000)], completed: 0),
            message("a3", parts: [part(type: "tool", end: 1_750_000_009_000)])
        ]
        let turn = try XCTUnwrap(project(messages).first)
        XCTAssertEqual(turn.completedAt, Date(timeIntervalSince1970: 1_750_000_010))

        let fallback = try XCTUnwrap(project(Array(messages.dropFirst()) + [
            message("a4", parts: [part(text: "Answer")])
        ]).first)
        XCTAssertEqual(fallback.completedAt, Date(timeIntervalSince1970: 1_750_000_009))
    }

    func testCompletionHelperComparesMixedUnitsAfterNormalization() {
        let answer = message("a1", parts: [
            part(text: "First", end: 1_750_000_020),
            part(text: "Second", end: 1_750_000_010_000)
        ], completed: 1_750_000_030_000)

        // Preserve the helper's existing part-first contract, unlike turn-end projection.
        XCTAssertEqual(
            ResponseCompletionTime.date(message: answer, parts: answer.parts),
            Date(timeIntervalSince1970: 1_750_000_020)
        )
    }

    func testDurationIncludesAllStepsAndLateToolWithMixedEndpointUnits() throws {
        for start in [1_750_000_000.0, 1_750_000_000_000] {
            for end in [1_750_000_083.0, 1_750_000_083_000] {
                let turn = try XCTUnwrap(project([
                    message("u", role: "user", created: start),
                    message("a", parentID: "u", parts: [part(text: "Answer")], completed: 1_750_000_010),
                    message("b", parentID: "u", parts: [part(text: "Final")], completed: 1_750_000_020),
                    message("tool", parentID: "u", parts: [part(type: "tool")], completed: end)
                ]).first)
                XCTAssertEqual(turn.duration, 83)
            }
        }
    }

    func testDurationUsesMatchingParentInsteadOfMostRecentPrompt() {
        let turns = project([
            message("u1", role: "user", created: 1_750_000_000),
            message("u2", role: "user", created: 1_750_000_050),
            message("a1", parentID: "u1", parts: [part(text: "First")], completed: 1_750_000_060),
            message("a2", parentID: "u2", parts: [part(text: "Second")], completed: 1_750_000_070),
            message("a3", parentID: "unloaded", parts: [part(text: "Partial")], completed: 1_750_000_080)
        ])
        XCTAssertEqual(turns.map(\.id), ["u1", "u2", "unloaded"])
        XCTAssertEqual(turns.map(\.duration), [60, 20, nil])
    }

    func testDurationOmitsMissingInvalidOrReversedEndpoints() throws {
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity, -.infinity]
        for timestamp in invalid {
            let badStart = project([
                message("u", role: "user", created: timestamp),
                message("a", parts: [part(text: "Answer")], completed: 1_750_000_083)
            ])
            XCTAssertNil(try XCTUnwrap(badStart.first).duration)
            let badEnd = project([
                message("u", role: "user"),
                message("a", parts: [part(text: "Answer")], completed: timestamp)
            ])
            XCTAssertNil(try XCTUnwrap(badEnd.first).duration)
        }
        for prompt in [
            message("u", role: "user", created: 1_750_000_100),
            message("u", role: "user", parts: [part(type: "compaction")]),
            message("u", summary: true)
        ] {
            XCTAssertNil(try XCTUnwrap(project([
                prompt, message("a", parentID: "u", parts: [part(text: "Answer")], completed: 1_750_000_083)
            ]).first).duration)
        }
        XCTAssertNil(try XCTUnwrap(project([
            message("a", parts: [part(text: "Answer")], completed: 1_750_000_083)
        ]).first).duration)
    }

    func testZeroElapsedIsValidAndDurationParticipatesInEqualityWithoutChangingIdentity() throws {
        let turn = try XCTUnwrap(project([
            message("u", role: "user"),
            message("a", parts: [part(text: "Answer")], completed: 1_750_000_000_000)
        ]).first)
        XCTAssertEqual(turn.duration, 0)
        var updated = turn
        updated.duration = 1
        XCTAssertEqual(turn.id, updated.id)
        XCTAssertNotEqual(turn, updated)
        XCTAssertEqual(Set([turn, updated]).count, 2)
    }

    func testDurationFormattingRoundsBeforeChoosingUnitsAndUsesLocale() throws {
        for localeID in ["en_US", "pt_BR", "it_IT"] {
            let locale = Locale(identifier: localeID)
            for (seconds, rounded) in [(0.0, 0.0), (59.6, 60), (83, 83), (3_723, 3_723)] {
                let expected = Duration.seconds(rounded).formatted(
                    .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(locale)
                )
                XCTAssertEqual(ResponseTurnDuration.formatted(seconds, locale: locale), expected)
            }
            for invalid: Double in [-1, .nan, .infinity, .greatestFiniteMagnitude, Double(Int64.max)] {
                XCTAssertNil(ResponseTurnDuration.formatted(invalid, locale: locale))
            }
            XCTAssertNil(ResponseTurnDuration.formatted(nil, locale: locale))
        }
    }

    private func project(
        _ messages: [OpenCodeMessageEnvelope],
        displayed: Set<String>? = nil,
        busy: Bool = false
    ) -> [AssistantResponseTurn] {
        AssistantResponseTurn.project(
            messages: messages,
            displayedMessageIDs: displayed ?? Set(messages.map(\.id)),
            isSessionBusy: busy
        )
    }

    private func message(
        _ id: String,
        role: String = "assistant",
        parentID: String? = nil,
        summary: Bool? = nil,
        parts: [OpenCodePart] = [],
        completed: Double? = nil,
        created: Double? = 1_750_000_000_000
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id, role: role, sessionID: "session",
                time: OpenCodeMessageTime(created: created, completed: completed),
                agent: nil, model: nil, parentID: parentID, summary: summary
            ),
            parts: parts
        )
    }

    private func part(
        type: String = "text",
        text: String? = nil,
        reason: String? = nil,
        synthetic: Bool? = nil,
        end: Double? = nil
    ) -> OpenCodePart {
        OpenCodePart(
            id: nil, messageID: nil, sessionID: "session", type: type,
            mime: nil, filename: nil, url: nil, reason: reason,
            tool: type == "tool" ? "read" : nil, callID: nil, state: nil,
            text: text, synthetic: synthetic, time: OpenCodePartTime(start: 1_750_000_000_000, end: end)
        )
    }
}
