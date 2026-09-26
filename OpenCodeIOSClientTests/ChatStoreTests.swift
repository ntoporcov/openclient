import XCTest
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenClient

@MainActor
final class ChatStoreTests: XCTestCase {
    func testInitialTranscriptRequestContainsLatestThreeUserRounds() {
        let sessionID = "ses_test"
        let messages = [
            OpenCodeMessage(id: "system", role: "system", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "u0", role: "user", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "a0", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u0"),
            OpenCodeMessage(id: "u1", role: "user", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "a1", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u1"),
            OpenCodeMessage(id: "u2", role: "user", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "a2a", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u2"),
            OpenCodeMessage(id: "a2b", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u2"),
            OpenCodeMessage(id: "u3", role: "user", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "a3", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u3"),
            OpenCodeMessage(id: "u4", role: "user", sessionID: sessionID, time: nil, agent: nil, model: nil),
            OpenCodeMessage(id: "a4", role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: "u4"),
        ]

        let count = OpenCodeChatTranscriptWindowing.messageCountIncludingLatestUserRounds(
            3,
            fallbackMessageCount: 3,
            in: messages
        )

        XCTAssertEqual(count, 7)
        XCTAssertEqual(Array(messages.suffix(count)).map(\.id), ["u2", "a2a", "a2b", "u3", "a3", "u4", "a4"])
    }

    func testInitialTranscriptRequestFallsBackToThreeMessagesWithoutUserRounds() {
        let messages = (0..<20).map {
            OpenCodeMessage(id: "a\($0)", role: "assistant", sessionID: "ses_test", time: nil, agent: nil, model: nil)
        }

        XCTAssertEqual(
            OpenCodeChatTranscriptWindowing.messageCountIncludingLatestUserRounds(
                3,
                fallbackMessageCount: 3,
                in: messages
            ),
            3
        )
    }

    func testCanonicalCacheDeduplicatesMessageAndPartIDs() {
        let first = message(id: "msg_duplicate", role: "assistant", text: "First", sessionID: "ses_test")
        var replacement = message(id: "msg_duplicate", role: "assistant", text: "Replacement", sessionID: "ses_test")
        replacement.parts.append(replacement.parts[0])
        let store = ChatStore()

        store.applyCanonicalMessages([first, replacement], forSessionID: "ses_test", isActiveSession: false)

        let cached = store.cachedMessagesBySessionID["ses_test"]
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?.parts.count, 1)
        XCTAssertEqual(cached?.first?.parts.first?.text, "Replacement")
    }

    func testPreloadedMessagesSeedMissingOrEmptyTargetWithoutChangingActiveState() {
        let active = message(id: "msg_active", role: "assistant", text: "Active", sessionID: "ses_active")
        let preloaded = message(id: "msg_preloaded", role: "assistant", text: "Preloaded", sessionID: "ses_target")
        for targetCache in [nil, []] as [[OpenCodeMessageEnvelope]?] {
            let store = ChatStore(messages: [active], cachedMessagesBySessionID: ["ses_active": [active]],
                isLoadingSelectedSession: true, preparedSessionID: "ses_active", activeChatSessionID: "ses_active")
            store.cachedMessagesBySessionID["ses_target"] = targetCache
            store.applyMessageHistoryPage(nextCursor: "active-cursor", forSessionID: "ses_active")
            let history = store.messageHistoryBySessionID

            store.cachePreloadedMessages([preloaded], forSessionID: "ses_target", preservingOrder: true)

            XCTAssertEqual(store.cachedMessagesBySessionID, ["ses_active": [active], "ses_target": [preloaded]])
            XCTAssertEqual(store.messages, [active])
            XCTAssertEqual(store.preparedSessionID, "ses_active")
            XCTAssertEqual(store.activeChatSessionID, "ses_active")
            XCTAssertTrue(store.isLoadingSelectedSession)
            XCTAssertEqual(store.messageHistoryBySessionID, history)
            XCTAssertTrue(store.v2TranscriptStates.isEmpty)
            XCTAssertFalse(store.isHydratingV2Transcript(sessionID: "ses_target"))
        }
    }

    func testAcceptedPreloadedMessagesReplaceOlderNonemptyCache() {
        let existing = message(id: "msg_existing", role: "assistant", text: "Existing", sessionID: "ses_target")
        let replacement = message(id: existing.id, role: "assistant", text: "Replacement", sessionID: "ses_target")
        let newest = message(id: "msg_newest", role: "assistant", text: "Newest", sessionID: "ses_target")
        let store = ChatStore(cachedMessagesBySessionID: ["ses_target": [existing]])

        store.cachePreloadedMessages([replacement, newest], forSessionID: "ses_target", preservingOrder: true)

        XCTAssertEqual(store.cachedMessagesBySessionID["ses_target"], [replacement, newest])
    }

    func testPreloadedV2OrderSurvivesBackgroundProjectionBeforeInitialHydration() {
        let first = message(id: "z-first", role: "user", text: "First", sessionID: "ses_target")
        let second = message(id: "a-second", role: "assistant", text: "Second", sessionID: "ses_target")
        let store = ChatStore()
        store.cachePreloadedMessages([first, second], forSessionID: "ses_target", preservingOrder: true)
        XCTAssertTrue(store.v2TranscriptStates.isEmpty)

        store.applyV2EventProjection([first, second], olderCursor: "older", sessionID: "ses_target")

        XCTAssertEqual(store.cachedMessagesBySessionID["ses_target"], [first, second])
        XCTAssertNil(store.preparedSessionID)
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testPreloadedMessagesDoNotSeedPreparedOrHydratingSession() {
        let preloaded = message(id: "msg_preloaded", role: "assistant", text: "Preloaded", sessionID: "ses_target")
        for v2Hydration in [false, true] {
            let store = ChatStore()
            if v2Hydration {
                store.beginV2TranscriptHydration(sessionID: "ses_target")
            } else {
                store.beginSelectingSession(sessionID: "ses_target", cachedMessages: [])
            }
            let preparedSessionID = store.preparedSessionID
            let transcriptStates = store.v2TranscriptStates

            store.cachePreloadedMessages([preloaded], forSessionID: "ses_target", preservingOrder: true)

            XCTAssertNil(store.cachedMessagesBySessionID["ses_target"])
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertEqual(store.preparedSessionID, preparedSessionID)
            XCTAssertTrue(store.isLoadingSelectedSession)
            XCTAssertEqual(store.isHydratingV2Transcript(sessionID: "ses_target"), v2Hydration)
            XCTAssertEqual(store.v2TranscriptStates, transcriptStates)
            XCTAssertTrue(store.messageHistoryBySessionID.isEmpty)
        }

        let prepared = ChatStore(preparedSessionID: "ses_target")
        prepared.cachePreloadedMessages([preloaded], forSessionID: "ses_target", preservingOrder: true)
        XCTAssertNil(prepared.cachedMessagesBySessionID["ses_target"])
        XCTAssertFalse(prepared.isLoadingSelectedSession)
    }

    func testPreloadedMessagesDeduplicateAndRespectExplicitOrderingWithoutV2State() {
        let page = zip(["msg_z", "msg_a", "msg_m"], [30.0, 10.0, 20.0]).map { id, created in
            OpenCodeMessageEnvelope(
                info: OpenCodeMessage(id: id, role: "assistant", sessionID: "ses_target",
                    time: OpenCodeMessageTime(created: created), agent: nil, model: nil), parts: []
            )
        }
        var replacement = page[0]
        let part = message(id: replacement.id, role: "assistant", text: "Replacement", sessionID: "ses_target").parts[0]
        replacement.parts = [part, part]
        let merged = ChatStore.mergingPreloadedV2Page(page + [replacement], into: [], hasOlder: true)
        XCTAssertEqual(merged.map(\.id), ["msg_z", "msg_a", "msg_m"])
        XCTAssertEqual(merged.first?.parts, [part])
        for preservingOrder in [false, true] {
            let store = ChatStore()

            store.cachePreloadedMessages(page + [replacement], forSessionID: "ses_target", preservingOrder: preservingOrder)

            XCTAssertEqual(store.cachedMessagesBySessionID["ses_target"]?.map(\.id),
                preservingOrder ? ["msg_z", "msg_a", "msg_m"] : ["msg_a", "msg_m", "msg_z"])
            XCTAssertEqual(store.cachedMessagesBySessionID["ses_target"]?.first { $0.id == "msg_z" }?.parts, [part])
            XCTAssertNil(store.preparedSessionID)
            XCTAssertFalse(store.isLoadingSelectedSession)
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertTrue(store.v2TranscriptStates.isEmpty)
            XCTAssertTrue(store.messageHistoryBySessionID.isEmpty)
        }
    }

    func testPreloadedMessagesFilterRecoveryWithoutChangingAdmissionOrReadState() {
        let store = ChatStore()
        let connectionID = UUID()
        store.selectSubmissionOwner("server", connectionID: connectionID)
        let request = BackendSubmission(sessionID: "ses_target", messageID: "msg_pending", text: "Pending", scope: .init())
        XCTAssertTrue(store.beginPromptAdmission(request, connectionID: connectionID))
        let pending = message(id: request.messageID, role: "user", text: "Pending", sessionID: request.sessionID)
        let preloaded = message(id: "msg_preloaded", role: "assistant", text: "Preloaded", sessionID: request.sessionID)
        let recoveries = store.submissionRecoveries
        let admissions = store.promptAdmissions
        let readID = store.beginV2CanonicalRead(sessionID: request.sessionID)
        store.applyMessageHistoryPage(nextCursor: "older", forSessionID: request.sessionID)
        XCTAssertEqual(store.beginLoadingOlderMessages(forSessionID: request.sessionID), "older")
        let history = store.messageHistoryBySessionID

        store.cachePreloadedMessages([pending, preloaded], forSessionID: request.sessionID, preservingOrder: true)

        XCTAssertEqual(store.cachedMessagesBySessionID[request.sessionID], [preloaded])
        XCTAssertEqual(store.submissionRecoveries, recoveries)
        XCTAssertEqual(store.promptAdmissions, admissions)
        XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)
        XCTAssertEqual(store.v2CanonicalReadID(sessionID: request.sessionID), readID)
        XCTAssertEqual(store.v2StreamRevision(sessionID: request.sessionID), 0)
        XCTAssertEqual(store.messageHistoryBySessionID, history)
        XCTAssertTrue(store.v2TranscriptStates.isEmpty)
    }

    func testMergingPreloadedV2PageKeepsOnlyPrefixBeforeFirstRowAnchor() {
        let older = message(id: "msg_z", role: "user", text: "Older", sessionID: "ses_v2")
        let anchor = message(id: "msg_a", role: "assistant", text: "Stale anchor", sessionID: "ses_v2")
        let stale = message(id: "msg_stale", role: "assistant", text: "Reverted", sessionID: "ses_v2")
        let canonical = message(id: anchor.id, role: "assistant", text: "Canonical", sessionID: "ses_v2")
        let newest = message(id: "msg_m", role: "assistant", text: "Newest", sessionID: "ses_v2")

        let merged = ChatStore.mergingPreloadedV2Page([canonical, newest, newest],
            into: [older, older, anchor, stale], hasOlder: true)

        XCTAssertEqual(merged, [older, canonical, newest])
    }

    func testMergingPreloadedV2CompletePageReplacesEvenWithAnchor() {
        let older = message(id: "msg_older", role: "user", text: "Older", sessionID: "ses_v2")
        let anchor = message(id: "msg_z", role: "assistant", text: "Anchor", sessionID: "ses_v2")
        let newest = message(id: "msg_a", role: "assistant", text: "Newest", sessionID: "ses_v2")

        XCTAssertEqual(ChatStore.mergingPreloadedV2Page([anchor, newest], into: [older, anchor], hasOlder: false),
            [anchor, newest])
    }

    func testMergingPreloadedV2PageRequiresFirstRowAnchorNotLaterOverlap() {
        let older = message(id: "msg_older", role: "user", text: "Older", sessionID: "ses_v2")
        let overlap = message(id: "msg_a", role: "assistant", text: "Overlap", sessionID: "ses_v2")
        let first = message(id: "msg_z", role: "assistant", text: "First", sessionID: "ses_v2")

        XCTAssertEqual(ChatStore.mergingPreloadedV2Page([first, overlap], into: [older, overlap], hasOlder: true),
            [first, overlap])
        XCTAssertEqual(ChatStore.mergingPreloadedV2Page([first], into: [older], hasOlder: true), [first])
        for hasOlder in [false, true] {
            XCTAssertEqual(ChatStore.mergingPreloadedV2Page([], into: [older], hasOlder: hasOlder), [])
        }
    }

    func testMessageHistoryTracksCursorLoadingAndCompletion() {
        let store = ChatStore()

        store.applyMessageHistoryPage(nextCursor: "cursor-1", forSessionID: "ses_test")

        XCTAssertTrue(store.hasOlderMessages(forSessionID: "ses_test"))
        XCTAssertEqual(store.beginLoadingOlderMessages(forSessionID: "ses_test"), "cursor-1")
        XCTAssertTrue(store.isLoadingOlderMessages(forSessionID: "ses_test"))
        XCTAssertNil(store.beginLoadingOlderMessages(forSessionID: "ses_test"))

        store.applyMessageHistoryPage(nextCursor: nil, forSessionID: "ses_test")

        XCTAssertFalse(store.hasOlderMessages(forSessionID: "ses_test"))
        XCTAssertFalse(store.isLoadingOlderMessages(forSessionID: "ses_test"))
        XCTAssertNil(store.beginLoadingOlderMessages(forSessionID: "ses_test"))
    }

    func testMessageHistoryFailureAllowsCursorRetry() {
        let store = ChatStore()
        store.applyMessageHistoryPage(nextCursor: "cursor-1", forSessionID: "ses_test")
        XCTAssertEqual(store.beginLoadingOlderMessages(forSessionID: "ses_test"), "cursor-1")

        store.failLoadingOlderMessages(forSessionID: "ses_test")

        XCTAssertFalse(store.isLoadingOlderMessages(forSessionID: "ses_test"))
        XCTAssertEqual(store.beginLoadingOlderMessages(forSessionID: "ses_test"), "cursor-1")
    }

    func testV2TranscriptBecomesPreparedOnlyAfterInitialPage() {
        let store = ChatStore()
        let loaded = [
            message(id: "msg_user", role: "user", text: "Question", sessionID: "ses_v2"),
            message(id: "msg_assistant", role: "assistant", text: "Answer", sessionID: "ses_v2"),
        ]

        store.beginV2TranscriptHydration(sessionID: "ses_v2")

        XCTAssertTrue(store.isLoadingSelectedSession)
        XCTAssertNil(store.preparedSessionID)

        store.applyInitialV2Transcript(loaded, olderCursor: "older", sessionID: "ses_v2")

        XCTAssertEqual(store.preparedSessionID, "ses_v2")
        XCTAssertEqual(store.messages.map(\.id), ["msg_user", "msg_assistant"])
        XCTAssertTrue(store.hasOlderV2Messages(sessionID: "ses_v2"))
        XCTAssertFalse(store.isLoadingSelectedSession)
    }

    func testV2HydrationStagesOnlyTheSelectedSessionsMemoryCache() {
        let previous = message(id: "msg_previous", role: "assistant", text: "Previous", sessionID: "ses_previous")
        let selected = message(id: "msg_selected", role: "assistant", text: "Selected", sessionID: "ses_v2")
        let store = ChatStore(messages: [previous], cachedMessagesBySessionID: ["ses_v2": [selected]])

        store.beginV2TranscriptHydration(sessionID: "ses_v2")

        XCTAssertEqual(store.messages, [selected])
        XCTAssertNil(store.preparedSessionID)
        XCTAssertTrue(store.isHydratingV2Transcript(sessionID: "ses_v2"))
    }

    func testOlderV2TranscriptPrependsWithoutReorderingOrDuplicatingBoundary() {
        let store = ChatStore()
        let boundary = message(id: "msg_boundary", role: "user", text: "Boundary", sessionID: "ses_v2")
        let newest = message(id: "msg_newest", role: "assistant", text: "Newest", sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([boundary, newest], olderCursor: "older", sessionID: "ses_v2")
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "older")

        store.applyOlderV2Transcript(
            [message(id: "msg_oldest", role: "user", text: "Oldest", sessionID: "ses_v2"), boundary],
            olderCursor: nil,
            requestedCursor: "older",
            sessionID: "ses_v2"
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_oldest", "msg_boundary", "msg_newest"])
        XCTAssertFalse(store.hasOlderV2Messages(sessionID: "ses_v2"))
    }

    func testV2PromptReconciliationReplacesOptimisticMessageAndPreservesOlderPrefix() {
        let store = ChatStore()
        let older = message(id: "msg_older", role: "assistant", text: "Older", sessionID: "ses_v2")
        let overlap = message(id: "msg_overlap", role: "assistant", text: "Old overlap", sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([older, overlap], olderCursor: "older", sessionID: "ses_v2")
        let optimistic = message(id: "msg_prompt", role: "user", text: "Prompt", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(optimistic, sessionID: "ses_v2"))

        let canonicalOverlap = message(id: "msg_overlap", role: "assistant", text: "Canonical overlap", sessionID: "ses_v2")
        let canonicalPrompt = message(id: "msg_prompt", role: "user", text: "Prompt", sessionID: "ses_v2")
        let answer = message(id: "msg_answer", role: "assistant", text: "Answer", sessionID: "ses_v2")
        store.reconcileV2NewestPage(
            [canonicalOverlap, canonicalPrompt, answer],
            olderCursor: "older",
            optimisticMessage: optimistic,
            sessionID: "ses_v2"
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_older", "msg_overlap", "msg_prompt", "msg_answer"])
        XCTAssertEqual(store.messages[1].parts.first?.text, "Canonical overlap")
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
    }

    func testV2UncertainAdmissionUnlocksOnlyWhenOriginalCanonicalIDAppears() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let original = message(id: "msg_original", role: "user", text: "Send once", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(original, sessionID: "ses_v2"))
        store.markSubmissionUncertain(messageID: original.id, sessionID: "ses_v2")
        XCTAssertEqual(store.submissionRecoveries[original.id]?.phase, .uncertain)
        store.applyV2EventProjection([], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.recoveryInputs(sessionID: "ses_v2").map(\.message), [original])
        let other = message(id: "msg_other", role: "user", text: "Send once", sessionID: "ses_v2")
        store.applyV2EventProjection([other], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"), "Matching text is not identity evidence")
        XCTAssertFalse(store.beginV2Prompt(other, sessionID: "ses_v2"))
        store.applyV2EventProjection([other, original], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertEqual(store.submissionRecoveries[original.id]?.phase, .admitted)
        store.retireSubmissionPresentations(in: [other, original], sessionID: "ses_v2")
        XCTAssertNil(store.submissionRecoveries[original.id])
        XCTAssertEqual(store.messages.filter { $0.id == original.id }.count, 1)
    }

    func testRecoveryNeverEntersInitialOlderOrLiveCanonicalProjection() throws {
        let store = ChatStore()
        let input = message(id: "msg_local", role: "user", text: "Keep me", sessionID: "ses_v2")
        let recent = message(id: "msg_recent", role: "assistant", text: "Recent", sessionID: "ses_v2")
        let older = message(id: "msg_old", role: "user", text: "Old", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(input, sessionID: "ses_v2"))
        store.markSubmissionUncertain(messageID: input.id, sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([recent], olderCursor: "older", sessionID: "ses_v2")
        XCTAssertEqual(store.messages, [recent])
        // An old local overlay must be removed, not used as a canonical history anchor.
        store.cachedMessagesBySessionID["ses_v2"] = [recent, input]
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "older")
        store.applyOlderV2Transcript([older], olderCursor: nil, requestedCursor: "older", sessionID: "ses_v2")
        XCTAssertEqual(store.messages, [older, recent])
        try applyV2Event(#"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_live","ordinal":0}}"#, to: store)
        XCTAssertEqual(store.messages.map(\.id), [older.id, recent.id, "msg_live"])
        for index in 0..<3 {
            let newer = message(id: "msg_new_\(index)", role: "assistant", text: "New", sessionID: "ses_v2")
            store.applyV2EventProjection([older, recent, newer], olderCursor: nil, sessionID: "ses_v2")
            XCTAssertEqual(store.messages, [older, recent, newer])
            XCTAssertEqual(store.recoveryInputs(sessionID: "ses_v2").map(\.message), [input])
        }
        store.resetActiveSession()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([recent], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertEqual(store.messages, [recent])
        XCTAssertEqual(store.submissionRecoveries[input.id]?.message, input)
    }

    func testCanonicalInputRetiresRecoveryOnceAndWinsLateRejectionAndCancellation() throws {
        let store = ChatStore()
        let input = message(id: "msg_local", role: "user", text: "Local", sessionID: "ses_v2")
        let canonical = message(id: input.id, role: "user", text: "Server content", sessionID: "ses_v2")
        let answer = message(id: "msg_answer", role: "assistant", text: "Answer", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(input, sessionID: "ses_v2"))
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([canonical, answer], olderCursor: nil, sessionID: "ses_v2")
        store.retireSubmissionPresentations(in: [canonical, answer], sessionID: "ses_v2")
        store.markSubmissionUncertain(messageID: input.id, sessionID: "ses_v2")
        store.rollbackV2Prompt(messageID: input.id, sessionID: "ses_v2")
        try applyV2Event(#"{"type":"session.input.cancelled","data":{"sessionID":"ses_v2","inputID":"msg_local"}}"#, to: store, expectsProjection: false)
        store.applyV2EventProjection([canonical, answer], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertEqual(store.messages, [canonical, answer])
        XCTAssertTrue(store.recoveryInputs(sessionID: "ses_v2").isEmpty)
        XCTAssertEqual(store.canonicalSubmissionSessions[input.id], "ses_v2")
        XCTAssertTrue(store.confirmSubmissionAdmission(messageID: input.id, sessionID: "ses_v2"))
        XCTAssertFalse(store.beginV2Prompt(input, sessionID: "ses_v2"))
    }

    func testOlderCanonicalInputReplacesAnOwnedOldOverlayWithServerContent() {
        let store = ChatStore()
        let local = message(id: "msg_local", role: "user", text: "Local", sessionID: "ses_v2")
        let canonical = message(id: local.id, role: "user", text: "Canonical", sessionID: "ses_v2")
        let latest = message(id: "msg_latest", role: "assistant", text: "Latest", sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([latest], olderCursor: "older", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(local, sessionID: "ses_v2"))
        store.cachedMessagesBySessionID["ses_v2"] = [latest, local]
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "older")
        store.applyOlderV2Transcript([canonical], olderCursor: nil, requestedCursor: "older", sessionID: "ses_v2")
        store.retireSubmissionPresentations(in: [canonical, latest], sessionID: "ses_v2", completeInventory: true)
        XCTAssertEqual(store.messages, [canonical, latest])
        XCTAssertNil(store.submissionRecoveries[local.id])
        XCTAssertEqual(store.canonicalSubmissionSessions[local.id], "ses_v2")
    }

    func testExplicitCancellationRetainsContentAttachmentsAndMentionsWithoutBlocking() throws {
        let store = ChatStore()
        let file = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "note.txt", mime: "text/plain",
            dataURL: "data:text/plain;base64,aGk=")
        let mention = OpenCodeAgentMention(name: "build", content: "@build", start: 0, end: 6)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "@build keep", agentMentions: [mention],
            attachments: [file], messageID: "msg_local", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(input, sessionID: "ses_v2", attachments: [file], agentMentions: [mention]))
        try applyV2Event(#"{"type":"session.input.cancelled","data":{"sessionID":"ses_v2","inputID":"msg_local"}}"#, to: store, expectsProjection: false)
        XCTAssertEqual(store.submissionRecoveries[input.id]?.phase, .cancelled)
        XCTAssertEqual(store.submissionRecoveries[input.id]?.message, input)
        XCTAssertEqual(store.submissionRecoveries[input.id]?.attachments, [file])
        XCTAssertEqual(store.submissionRecoveries[input.id]?.agentMentions, [mention])
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        store.applyV2InboxAdmissionIDs([], sessionID: "ses_v2")
        XCTAssertEqual(store.submissionRecoveries[input.id]?.phase, .cancelled)
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testGenericV2CancellationPreservesAdmissionEvidenceAgainstLateRejectedReceipt() throws {
        let store = ChatStore()
        let connectionID = UUID()
        store.selectSubmissionOwner("server-v2", connectionID: connectionID)
        let request = BackendSubmission(sessionID: "ses_v2", messageID: "msg_local", text: "Keep content", scope: .init())
        XCTAssertTrue(store.beginPromptAdmission(request, connectionID: connectionID))
        try applyV2Event(#"{"type":"session.input.cancelled","data":{"sessionID":"ses_v2","inputID":"msg_local"}}"#,
            to: store, expectsProjection: false)
        XCTAssertEqual(store.applyPromptAdmission(.rejected, messageID: request.messageID, connectionID: connectionID), .admitted)
        XCTAssertEqual(store.submissionRecoveries[request.messageID]?.phase, .cancelled)
        XCTAssertEqual(store.submissionRecoveries[request.messageID]?.text, request.text)
        XCTAssertFalse(store.hasPendingPromptAdmission(sessionID: request.sessionID, connectionID: connectionID))
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: request.sessionID))
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testV2InboxProofConfirmsQueuedPromptWithoutDroppingItOrUnlockingAnotherPrompt() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let first = message(id: "msg_first", role: "user", text: "First", sessionID: "ses_v2")
        let second = message(id: "msg_second", role: "user", text: "Second", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(first, sessionID: "ses_v2"))
        store.markSubmissionUncertain(messageID: first.id, sessionID: "ses_v2")
        store.applyV2InboxAdmissionIDs([], sessionID: "ses_v2")
        store.applyV2InboxAdmissionIDs([first.id], sessionID: "ses_other")
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"))
        store.applyV2InboxAdmissionIDs([first.id], sessionID: "ses_v2")
        XCTAssertEqual(store.submissionRecoveries[first.id]?.phase, .admitted)
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertTrue(store.beginV2Prompt(second, sessionID: "ses_v2"))
        XCTAssertTrue(store.confirmSubmissionAdmission(messageID: first.id, sessionID: "ses_v2"))
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"), "An old receipt cannot release the second admission lock")
        store.applyV2EventProjection([], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.recoveryInputs(sessionID: "ses_v2").map(\.id), [first.id, second.id])
    }

    func testV2UncertainPromptSurvivesNavigationAndCanonicalInitialHydrationCanResolveIt() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let pending = message(id: "msg_pending", role: "user", text: "Pending", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(pending, sessionID: "ses_v2"))
        store.finishV2PromptWithoutReconciliation(sessionID: "ses_v2")
        store.resetActiveSession()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.submissionRecoveries[pending.id]?.message, pending)
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([pending], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertEqual(store.submissionRecoveries[pending.id]?.phase, .admitted)
        store.retireSubmissionPresentations(in: [pending], sessionID: "ses_v2")
        XCTAssertNil(store.submissionRecoveries[pending.id])
    }

    func testV2InboxDeliveredProvesAdmissionEvenWhenEnqueueWasMissed() throws {
        let store = ChatStore()
        let pending = message(id: "msg_pending", role: "user", text: "Pending", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(pending, sessionID: "ses_v2"))
        store.markSubmissionUncertain(messageID: pending.id, sessionID: "ses_v2")
        let delivered = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.inbox.delivered","data":{"sessionID":"ses_v2","inboxID":"msg_pending"}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(delivered, sessionID: "ses_v2"), "No projected payload without enqueue; timeline hydration follows")
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertEqual(store.submissionRecoveries[pending.id]?.phase, .admitted)
    }

    func testV2EventProjectionReplacesNewestPageAndPreservesOlderPrefix() {
        let store = ChatStore()
        let older = message(id: "msg_older", role: "user", text: "Older", sessionID: "ses_v2")
        let overlap = message(id: "msg_overlap", role: "assistant", text: "Partial", sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([older, overlap], olderCursor: "older", sessionID: "ses_v2")

        store.applyV2EventProjection(
            [
                message(id: "msg_overlap", role: "assistant", text: "Canonical", sessionID: "ses_v2"),
                message(id: "msg_latest", role: "assistant", text: "Streaming", sessionID: "ses_v2"),
            ],
            olderCursor: "older",
            sessionID: "ses_v2"
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_older", "msg_overlap", "msg_latest"])
        XCTAssertEqual(store.messages[1].parts.first?.text, "Canonical")
    }

    func testV2EventProjectionPreservesUnadmittedOptimisticPrompt() {
        let store = ChatStore()
        let canonical = message(id: "msg_existing", role: "assistant", text: "Existing", sessionID: "ses_v2")
        let optimistic = message(id: "msg_prompt", role: "user", text: "Prompt", sessionID: "ses_v2")
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([canonical], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(optimistic, sessionID: "ses_v2"))

        store.applyV2EventProjection([canonical], olderCursor: nil, sessionID: "ses_v2")

        XCTAssertEqual(store.messages.map(\.id), ["msg_existing"])
        XCTAssertEqual(store.submissionRecoveries[optimistic.id]?.message, optimistic)
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "ses_v2"))
    }

    func testV2StreamEventsAppendTextAndReasoningDeltasThenUseCanonicalEndValues() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")

        try applyV2Event(
            #"{"id":"evt_step","created":1000,"type":"session.step.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","agent":"build","model":{"id":"gpt-5","providerID":"openai"}}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_reason_start","created":1001,"type":"session.reasoning.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_reason_delta_1","created":1002,"type":"session.reasoning.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"Think"}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_reason_delta_2","created":1003,"type":"session.reasoning.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"ing"}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_reason_end","created":1004,"type":"session.reasoning.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"text":"Thinking."}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_text_start","created":1005,"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_text_delta_1","created":1006,"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"Hel"}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_text_delta_2","created":1007,"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"lo"}}"#,
            to: store
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_assistant"])
        XCTAssertEqual(store.messages[0].parts.map(\.type), ["reasoning", "text"])
        XCTAssertEqual(store.messages[0].parts.map(\.text), ["Thinking.", "Hello"])
        XCTAssertEqual(store.messages[0].parts.map(\.id), [
            "msg_assistant:v2:reasoning:0",
            "msg_assistant:v2:text:0",
        ])
        XCTAssertGreaterThan(store.v2StreamRevision(sessionID: "ses_v2"), 0)
    }

    func testV2InboxInputBecomesVisibleOnlyWhenDelivered() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let admitted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"id":"evt_admitted","created":1000,"type":"session.inbox.enqueued","data":{"sessionID":"ses_v2","inboxID":"msg_user","item":{"type":"user","payload":{"text":"Hello"},"delivery":"steer"}}}"#))

        XCTAssertFalse(store.applyV2StreamEvent(admitted, sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty)

        let deliveryChanged = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(
            from: #"{"id":"evt_delivery","created":1000.5,"type":"session.inbox.delivery.changed","data":{"sessionID":"ses_v2","inboxID":"msg_user","delivery":"queue"}}"#
        ))
        XCTAssertEqual(deliveryChanged.inputID, "msg_user")
        XCTAssertFalse(store.applyV2StreamEvent(deliveryChanged, sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty)

        try applyV2Event(
            #"{"id":"evt_promoted","created":1001,"type":"session.inbox.delivered","data":{"sessionID":"ses_v2","inboxID":"msg_user"}}"#,
            to: store
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_user"])
        XCTAssertEqual(store.messages.first?.parts.first?.text, "Hello")
    }

    func testV2StreamEventsProjectToolLifecycleWithoutTimelineRefresh() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")

        try applyV2Event(
            #"{"id":"evt_tool_start","created":1000,"type":"session.tool.input.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","name":"read"}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_tool_input","created":1001,"type":"session.tool.input.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","text":"{\"filePath\":\"README.md\"}"}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_tool_called","created":1002,"type":"session.tool.called","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","input":{"filePath":"README.md"},"executed":false}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_tool_progress","created":1003,"type":"session.tool.progress","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","metadata":{"description":"Reading"}}}"#,
            to: store
        )
        try applyV2Event(
            #"{"id":"evt_tool_success","created":1004,"type":"session.tool.success","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","content":[{"type":"text","text":"contents"}],"metadata":{"description":"Read complete"},"executed":false}}"#,
            to: store
        )

        let part = try XCTUnwrap(store.messages.first?.parts.first)
        XCTAssertEqual(part.type, "tool")
        XCTAssertEqual(part.tool, "read")
        XCTAssertEqual(part.callID, "call_1")
        XCTAssertEqual(part.state?.status, "completed")
        XCTAssertEqual(part.state?.input?.filePath, "README.md")
        XCTAssertEqual(part.state?.output, "contents")
        XCTAssertEqual(part.state?.metadata?.description, "Read complete")
    }

    func testV217155InputAdmissionPromotionAndCancellation() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let pending = message(id: "msg_user", role: "user", text: "@build hello", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(pending, sessionID: "ses_v2"))
        store.markSubmissionUncertain(messageID: pending.id, sessionID: "ses_v2")
        // Installed schema/session-event.ts + core/session/pending.ts, not the pinned inbox shape.
        let admitted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"id":"evt_admit","created":1000,"type":"session.input.admitted","durable":{"aggregateID":"ses_v2","seq":1,"version":1},"data":{"sessionID":"ses_v2","inputID":"msg_user","input":{"type":"user","delivery":"steer","data":{"text":"@build hello","files":[{"data":"aGk=","mime":"text/plain","name":"hi.txt","source":{"type":"inline"}}],"agents":[{"name":"build","mention":{"text":"@build","start":0,"end":6}}]}}}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(admitted, sessionID: "ses_v2"))
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty, "Admission is not a projected message")
        XCTAssertEqual(store.submissionRecoveries[pending.id]?.message, pending)
        try applyV2Event(#"{"id":"evt_promote","created":1001,"type":"session.input.promoted","durable":{"aggregateID":"ses_v2","seq":2,"version":1},"data":{"sessionID":"ses_v2","inputID":"msg_user"}}"#, to: store)
        XCTAssertEqual(store.messages.map(\.id), [pending.id])
        XCTAssertEqual(store.messages[0].info.time?.created, 1001)
        XCTAssertEqual(store.messages[0].parts.map(\.type), ["text", "file", "agent"])
        XCTAssertEqual(store.messages[0].parts[1].url, "data:text/plain;base64,aGk=")
        XCTAssertEqual(store.messages[0].parts[2].source?.value, "@build")
        XCTAssertEqual(store.messages[0].parts[2].source?.end, 6)

        let cancelled = message(id: "msg_cancel", role: "user", text: "Cancel", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(cancelled, sessionID: "ses_v2"))
        let revision = store.v2StreamRevision(sessionID: "ses_v2")
        try applyV2Event(#"{"type":"session.input.cancelled","data":{"sessionID":"ses_v2","inputID":"msg_cancel"}}"#, to: store, expectsProjection: false)
        XCTAssertGreaterThan(store.v2StreamRevision(sessionID: "ses_v2"), revision)
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertEqual(store.messages.map(\.id), [pending.id])
    }

    func testV217155SyntheticInputAndMissedAdmissionDoNotInventUserText() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let admitted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_synthetic","input":{"type":"synthetic","delivery":"queue","data":{"text":"Context","description":"A note"}}}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(admitted, sessionID: "ses_v2"))
        XCTAssertTrue(store.messages.isEmpty)
        try applyV2Event(#"{"created":1234,"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"msg_synthetic"}}"#, to: store)
        XCTAssertEqual(store.messages.first?.info.role, "assistant")
        XCTAssertEqual(store.messages.first?.parts.first?.synthetic, true)
        XCTAssertEqual(store.messages.first?.parts.first?.timelineContextType, .synthetic)

        let pending = message(id: "msg_missed", role: "user", text: "Pending", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(pending, sessionID: "ses_v2"))
        let promoted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"msg_missed"}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(promoted, sessionID: "ses_v2"))
        XCTAssertFalse(store.isV2PromptInFlight(sessionID: "ses_v2"))
        XCTAssertTrue(promoted.affectsTranscript, "The handler must reconcile when the admission payload was missed")
        XCTAssertFalse(store.messages.contains { $0.id == pending.id })
        XCTAssertEqual(store.submissionRecoveries[pending.id]?.message, pending)
    }

    func testV2ToolInputEndIsCanonicalAndStepFailurePreservesPartialOutput() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        try applyV2Event(#"{"created":1000,"type":"session.step.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","agent":"build","model":{"id":"model","providerID":"provider"}}}"#, to: store)
        try applyV2Event(#"{"type":"session.tool.input.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","name":"read"}}"#, to: store)
        try applyV2Event(#"{"type":"session.tool.input.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","delta":"{"}}"#, to: store)
        try applyV2Event(#"{"type":"session.tool.input.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","text":"{}"}}"#, to: store)
        let late = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.tool.input.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","delta":"stale"}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(late, sessionID: "ses_v2"))
        XCTAssertEqual(store.messages[0].parts[0].state?.raw, "{}")
        try applyV2Event(#"{"type":"session.tool.failed","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_1","error":{"type":"tool.input-json","message":"Malformed input"},"executed":false}}"#, to: store)
        XCTAssertEqual(store.messages[0].parts[0].state?.status, "error")
        try applyV2Event(#"{"type":"session.text.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"text":"Partial answer"}}"#, to: store)
        try applyV2Event(#"{"created":2000,"type":"session.step.failed","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","error":{"type":"provider.unknown","message":"Failed"}}}"#, to: store)
        XCTAssertEqual(store.messages[0].info.time?.completed, 2000)
        XCTAssertEqual(store.messages[0].info.error?.data?.message, "Failed")
        XCTAssertEqual(store.messages[0].parts.last?.text, "Partial answer")
        try applyV2Event(#"{"created":3000,"type":"session.step.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_next","agent":"build","model":{"id":"model","providerID":"provider"}}}"#, to: store)
        try applyV2Event(#"{"type":"session.tool.input.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_next","id":"call_1","name":"read"}}"#, to: store)
        try applyV2Event(#"{"type":"session.tool.input.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_next","id":"call_1","delta":"{"}}"#, to: store)
        XCTAssertEqual(store.messages.last?.parts.first?.state?.raw, "{", "Tool IDs can be reused in another assistant message")
    }

    func testV2MalformedAdmissionAndFragmentsNeverBecomeVisibleText() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        for raw in [
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_unknown","input":{"type":"future","delivery":"steer","data":{"text":"Unknown"}}}}"#,
            #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"msg_unknown"}}"#,
            #"{"type":"session.reasoning.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_unknown","ordinal":0,"delta":"No start"}}"#,
            #"{"type":"session.text.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_unknown","ordinal":0,"text":42}}"#,
            #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":123,"ordinal":0}}"#,
        ] {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw))
            XCTAssertFalse(store.applyV2StreamEvent(event, sessionID: "ses_v2"))
            XCTAssertTrue(store.messages.isEmpty)
        }
        try applyV2Event(#"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#, to: store)
        let malformed = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":false}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(malformed, sessionID: "ses_v2"))
        XCTAssertEqual(store.messages.first?.parts.first?.text, "")
    }

    private func applyV2Event(_ raw: String, to store: ChatStore, sessionID: String = "ses_v2", expectsProjection: Bool = true) throws {
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw))
        XCTAssertEqual(store.applyV2StreamEvent(event, sessionID: sessionID), expectsProjection)
    }

    func testV2HydratedMixedContentUsesIndependentTextAndReasoningOrdinals() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        try applyV2Event(#"{"type":"session.message.content.updated","data":{"sessionID":"ses_v2","messageID":"msg_assistant","content":[{"type":"reasoning","text":"Thought"},{"type":"text","text":"First"},{"type":"tool","id":"call_1","name":"read","state":{"status":"running","input":{},"metadata":{}}},{"type":"text","text":"Second"}]}}"#, to: store)
        try applyV2Event(#"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":1,"delta":" continuation"}}"#, to: store)
        XCTAssertEqual(store.messages[0].parts.map(\.id), [
            "msg_assistant:v2:reasoning:0", "msg_assistant:v2:text:0", "call_1", "msg_assistant:v2:text:1",
        ])
        XCTAssertEqual(store.messages[0].parts.last?.text, "Second continuation")
    }

    func testV2StartedDoesNotWipeHydratedTextAndUnknownDeltaDoesNotInventParts() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        try applyV2Event(#"{"type":"session.text.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"text":"Canonical"}}"#, to: store)
        let started = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(started, sessionID: "ses_v2"))
        let delta = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.reasoning.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":5,"delta":"lost start"}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(delta, sessionID: "ses_v2"))
        XCTAssertEqual(store.messages[0].parts.count, 1)
        XCTAssertEqual(store.messages[0].parts.first?.text, "Canonical")
    }

    func testV2EmptyOngoingHTTPTextPreservesLiveDeltaButNotStaleCache() throws {
        for initialRead in [false, true] {
            let store = ChatStore()
            store.beginV2TranscriptHydration(sessionID: "ses_v2")
            XCTAssertTrue(store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2"))
            try applyV2Event(#"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#, to: store)
            try applyV2Event(#"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"first. "}}"#, to: store)
            let live = try XCTUnwrap(store.cachedMessagesBySessionID["ses_v2"]?.first)
            var http = live
            http.parts[0].text = ""
            if initialRead {
                store.beginV2TranscriptHydration(sessionID: "ses_v2")
                XCTAssertTrue(store.applyInitialV2Transcript([http], olderCursor: nil, sessionID: "ses_v2"))
            } else {
                store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
            }
            XCTAssertEqual(store.messages.first?.parts.first?.text, "first. ")
            try applyV2Event(#"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"progress."}}"#, to: store)
            XCTAssertEqual(store.messages.first?.parts.first?.text, "first. progress.")
            http.info = OpenCodeMessage(id: http.id, role: "assistant", sessionID: "ses_v2",
                time: OpenCodeMessageTime(created: 1, completed: 2), agent: nil, model: nil)
            store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
            XCTAssertEqual(store.messages.first?.parts.first?.text, "", "Completed canonical state wins even when empty")

            let restored = ChatStore()
            restored.beginV2TranscriptHydration(sessionID: "ses_v2")
            XCTAssertTrue(restored.applyInitialV2Transcript([live], olderCursor: nil, sessionID: "ses_v2"))
            var ongoing = live
            ongoing.parts[0].text = ""
            restored.applyV2EventProjection([ongoing], olderCursor: nil, sessionID: "ses_v2")
            XCTAssertEqual(restored.messages.first?.parts.first?.text, "", "Persisted text without live delta ownership must not beat HTTP")
        }
    }

    func testV2CompletedReasoningPartWinsWhileAssistantIsOngoing() throws {
        for initialRead in [false, true] {
            for completedSource in ["incoming", "previous"] {
                let store = ChatStore()
                store.beginV2TranscriptHydration(sessionID: "ses_v2")
                XCTAssertTrue(store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2"))
                try applyV2Event(#"{"type":"session.reasoning.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#, to: store)
                try applyV2Event(#"{"type":"session.reasoning.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"Live thought"}}"#, to: store)
                var previous = try XCTUnwrap(store.cachedMessagesBySessionID["ses_v2"]?.first)
                let unfinishedPart = previous.parts[0]
                let completedPart = try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"id":"\#(try XCTUnwrap(unfinishedPart.id))","messageID":"msg_assistant","sessionID":"ses_v2","type":"reasoning","text":"Live thought","time":{"start":1,"end":2}}"#.utf8))
                var http = previous
                http.parts[0].text = ""
                if completedSource == "incoming" {
                    http.parts[0] = completedPart
                    http.parts[0].text = ""
                } else {
                    previous.parts[0] = completedPart
                    store.cacheMessages([previous], forSessionID: "ses_v2")
                }
                if initialRead {
                    store.beginV2TranscriptHydration(sessionID: "ses_v2")
                    XCTAssertTrue(store.applyInitialV2Transcript([http], olderCursor: nil, sessionID: "ses_v2"))
                } else {
                    store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
                }
                XCTAssertNil(store.messages.first?.info.time?.completed)
                XCTAssertEqual(store.messages.first?.parts.first?.text, "", "Completed \(completedSource) part must not preserve text")

                // Completion must retire ownership, not merely suppress one merge.
                http.parts[0] = unfinishedPart
                http.parts[0].text = "Later HTTP text"
                store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
                http.parts[0].text = ""
                store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
                XCTAssertEqual(store.messages.first?.parts.first?.text, "")
            }
        }
    }

    func testV2EndedPartWithoutEndTimeDoesNotPreserveText() throws {
        for initialRead in [false, true] {
            for type in ["text", "reasoning"] {
                let store = ChatStore()
                store.beginV2TranscriptHydration(sessionID: "ses_v2")
                XCTAssertTrue(store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2"))
                try applyV2Event(#"{"type":"session.\#(type).started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#, to: store)
                try applyV2Event(#"{"type":"session.\#(type).delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"Live text"}}"#, to: store)
                try applyV2Event(#"{"type":"session.\#(type).ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"text":"Ended text"}}"#, to: store)
                var http = try XCTUnwrap(store.cachedMessagesBySessionID["ses_v2"]?.first)
                XCTAssertNil(http.info.time?.completed)
                XCTAssertNil(http.parts[0].time?.end, "The ended-ID ledger must work without part timestamps")
                http.parts[0].text = ""
                if initialRead {
                    store.beginV2TranscriptHydration(sessionID: "ses_v2")
                    XCTAssertTrue(store.applyInitialV2Transcript([http], olderCursor: nil, sessionID: "ses_v2"))
                } else {
                    store.applyV2EventProjection([http], olderCursor: nil, sessionID: "ses_v2")
                }
                XCTAssertEqual(store.messages.first?.parts.first?.text, "")
                try applyV2Event(#"{"type":"session.\#(type).delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"delta":"Late text"}}"#, to: store, expectsProjection: false)
                XCTAssertEqual(store.messages.first?.parts.first?.text, "")
            }
        }
    }

    func testV2BackgroundStreamNeverCopiesOrPublishesSelectedTranscript() throws {
        let selected = message(id: "msg_selected", role: "user", text: "Selected", sessionID: "ses_selected")
        let store = ChatStore(messages: [selected], preparedSessionID: "ses_selected")
        try applyV2Event(#"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_background","ordinal":0}}"#, to: store)
        XCTAssertEqual(store.messages, [selected])
        XCTAssertEqual(store.cachedMessagesBySessionID["ses_v2"]?.map(\.id), ["msg_background"])
    }

    func testV2CompleteReconnectSnapshotRemovesHistoryDeletedWhileDisconnected() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([message(id: "msg_old", role: "user", text: "Reverted", sessionID: "ses_v2")], olderCursor: "older", sessionID: "ses_v2")
        store.applyV2EventProjection([], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.cachedMessagesBySessionID["ses_v2"], [])
        XCTAssertFalse(store.hasOlderV2Messages(sessionID: "ses_v2"))
    }

    func testV2SkippedOnlyPagesPreserveRawOlderCursorUntilPagingCompletes() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")

        XCTAssertTrue(store.applyInitialV2Transcript([], olderCursor: "older-1", sessionID: "ses_v2"))
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "older-1")

        store.applyOlderV2Transcript([], olderCursor: "older-2", requestedCursor: "older-1", sessionID: "ses_v2")
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "older-2")

        store.applyOlderV2Transcript([], olderCursor: nil, requestedCursor: "older-2", sessionID: "ses_v2")
        XCTAssertFalse(store.hasOlderV2Messages(sessionID: "ses_v2"))
    }

    func testV2NoOverlapPageDiscardsUnprovenPrefixAndResetsHistoryCursor() {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([message(id: "msg_reverted", role: "user", text: "Old", sessionID: "ses_v2")], olderCursor: "stale-cursor", sessionID: "ses_v2")
        let current = message(id: "msg_current", role: "assistant", text: "Current", sessionID: "ses_v2")
        store.applyV2EventProjection([current], olderCursor: "new-cursor", sessionID: "ses_v2")
        XCTAssertEqual(store.messages, [current])
        XCTAssertEqual(store.beginLoadingOlderV2Messages(sessionID: "ses_v2"), "new-cursor")
        store.applyV2EventProjection([], olderCursor: "unexpected-empty-cursor", sessionID: "ses_v2")
        XCTAssertTrue(store.messages.isEmpty)
    }

    func testV2CanonicalPageKeepsActualInFlightPromptEvenWhenAssistantIsLast() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        let prompt = message(id: "msg_prompt", role: "user", text: "Pending", sessionID: "ses_v2")
        XCTAssertTrue(store.beginV2Prompt(prompt, sessionID: "ses_v2"))
        try applyV2Event(#"{"type":"session.step.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","agent":"build","model":{"providerID":"provider","id":"model"}}}"#, to: store)
        store.applyV2EventProjection([], olderCursor: nil, sessionID: "ses_v2")
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertEqual(store.submissionRecoveries[prompt.id]?.message, prompt)
    }

    func testV2HTTPHydratedOngoingAssistantAcceptsLiveDeltasAndCanonicalToolFiles() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [V2ProjectionFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: ""), session: session)
        let hydrated = try await client.getV2Message(sessionID: "ses_v2", messageID: "msg_assistant")
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([hydrated], olderCursor: nil, sessionID: "ses_v2")

        // Public envelope and materialized content shapes from pinned v2 schema/message-updater.
        try applyV2Event(#"{"id":"evt_delta","created":1200,"type":"session.text.delta","location":{"directory":"/project"},"data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":1,"delta":" world"}}"#, to: store)
        try applyV2Event(#"{"id":"evt_reason_end","created":1300,"type":"session.reasoning.ended","durable":{"aggregateID":"ses_v2","seq":8,"version":1},"location":{"directory":"/project"},"data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0,"text":"Thought","state":{"provider":"opaque"}}}"#, to: store)
        try applyV2Event(#"{"id":"evt_success","created":1400,"type":"session.tool.success","durable":{"aggregateID":"ses_v2","seq":9,"version":2},"location":{"directory":"/project"},"data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_read","content":[{"type":"text","text":"result"},{"type":"file","name":"result.txt","mime":"text/plain","data":"aGk="}],"executed":false}}"#, to: store)
        let text = try XCTUnwrap(store.messages[0].parts.first { $0.id == "msg_assistant:v2:text:1" })
        XCTAssertEqual(text.text, "Hello world")
        XCTAssertEqual(store.messages[0].parts.count, hydrated.parts.count)
        let reasoning = try XCTUnwrap(store.messages[0].parts.first { $0.type == "reasoning" })
        XCTAssertEqual(reasoning.time, OpenCodePartTime(start: 1050, end: 1300))
        let tool = try XCTUnwrap(store.messages[0].parts.first { $0.type == "tool" })
        XCTAssertEqual(tool.state?.status, "completed")
        XCTAssertEqual(tool.state?.input?.arguments?["customFlag"], .bool(true))
        XCTAssertEqual(tool.state?.metadata?.files?.first?.objectValue?["data"], .string("aGk="))
        XCTAssertNil(tool.state?.metadata?.description, "Terminal metadata must not inherit ephemeral progress")
        XCTAssertNil(tool.state?.raw)

        let terminal = store.messages
        let calledAgain = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.tool.called","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","id":"call_read","input":{},"executed":false}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(calledAgain, sessionID: "ses_v2"))
        XCTAssertEqual(store.messages, terminal)
    }

    func testV2PinnedContentUpdateFixturePreservesReasoningTimeAndRejectsPartialDecode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [V2ProjectionFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "https://fixture.invalid", username: "", password: ""), session: session)
        let hydrated = try await client.getV2Message(sessionID: "ses_v2", messageID: "msg_assistant")
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([hydrated], olderCursor: nil, sessionID: "ses_v2")
        try applyV2Event(#"{"created":1500,"type":"session.step.ended","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","finish":"stop","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}"#, to: store)
        // Content from packages/core/test/session-message-update.test.ts, with encoded milliseconds.
        try applyV2Event(#"{"id":"evt_update","created":1600,"type":"session.message.content.updated","durable":{"aggregateID":"ses_v2","seq":10,"version":1},"data":{"sessionID":"ses_v2","messageID":"msg_assistant","content":[{"type":"text","text":"replacement"},{"type":"reasoning","text":"updated reasoning","time":{"created":1000}}]}}"#, to: store)
        XCTAssertEqual(store.messages[0].parts.map(\.text), ["replacement", "updated reasoning"])
        XCTAssertEqual(store.messages[0].parts.last?.time?.start, 1000)
        XCTAssertEqual(store.messages[0].info.time?.completed, 1500)
        let canonical = store.messages
        let invalid = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.message.content.updated","data":{"sessionID":"ses_v2","messageID":"msg_assistant","content":[{"type":"text","text":"partial"},{"type":"future"}]}}"#))
        XCTAssertFalse(store.applyV2StreamEvent(invalid, sessionID: "ses_v2"))
        XCTAssertEqual(store.messages, canonical)
        try applyV2Event(#"{"type":"session.message.content.updated","data":{"sessionID":"ses_v2","messageID":"msg_assistant","content":[]}}"#, to: store)
        XCTAssertTrue(store.messages[0].parts.isEmpty)
    }

    func testV2InitialHydrationRejectsRacingStreamAndCanReconcileAtCurrentRevision() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        try applyV2Event(#"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","ordinal":0}}"#, to: store)
        XCTAssertFalse(store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2"))
        XCTAssertTrue(store.isHydratingV2Transcript(sessionID: "ses_v2"))
        let canonical = try XCTUnwrap(store.cachedMessagesBySessionID["ses_v2"])
        XCTAssertTrue(store.applyInitialV2Transcript(canonical, olderCursor: nil, sessionID: "ses_v2", expectedStreamRevision: store.v2StreamRevision(sessionID: "ses_v2")))
        XCTAssertEqual(store.messages, canonical)
    }

    func testV2StepTerminalProjectsCompletionUsageAndError() throws {
        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_v2")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_v2")
        try applyV2Event(#"{"created":1000,"type":"session.step.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","agent":"build","model":{"providerID":"openai","id":"gpt-5"}}}"#, to: store)
        try applyV2Event(#"{"created":2000,"type":"session.step.streamed","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant"}}"#, to: store)
        XCTAssertNil(store.messages[0].info.time?.completed)
        XCTAssertEqual(store.messages[0].info.time?.streamed, 2000)
        try applyV2Event(#"{"created":3000,"type":"session.step.failed","data":{"sessionID":"ses_v2","assistantMessageID":"msg_assistant","error":{"type":"provider.unknown","message":"Failure"},"cost":0.5,"tokens":{"input":20,"output":10,"reasoning":5,"cache":{"read":2,"write":3}}}}"#, to: store)
        XCTAssertEqual(store.messages[0].info.time?.completed, 3000)
        XCTAssertEqual(store.messages[0].info.model?.modelID, "gpt-5")
        XCTAssertEqual(store.messages[0].info.error?.data?.message, "Failure")
        XCTAssertEqual(store.messages[0].info.tokens?.input, 20)
        XCTAssertEqual(store.messages[0].info.cost, 0.5)
    }

    func testActivityBudgetKeepsProtectedContentAndNewestSettledActivity() {
        let projection = MessageBubbleActivityBudget.project(
            protectedEntries: Array(repeating: false, count: 20) + [true],
            limit: 12
        )

        XCTAssertEqual(projection.hiddenCount, 8)
        XCTAssertEqual(projection.firstHiddenIndex, 0)
        XCTAssertEqual(projection.retainedIndices, Set(8...20))
    }

    func testActivityBudgetDoesNotSpendLimitOnProtectedEntries() {
        var protectedEntries = Array(repeating: false, count: 20)
        protectedEntries[2] = true

        let projection = MessageBubbleActivityBudget.project(
            protectedEntries: protectedEntries,
            limit: 3
        )

        XCTAssertEqual(projection.hiddenCount, 16)
        XCTAssertTrue(projection.retainedIndices.contains(2))
        XCTAssertTrue(projection.retainedIndices.isSuperset(of: [17, 18, 19]))
    }

    func testFullyRenderedActivityDoesNotOfferEarlierActivity() {
        for count in [0, 1, 12] {
            let projection = MessageBubbleActivityBudget.project(
                protectedEntries: Array(repeating: false, count: count) + [true],
                limit: 12
            )
            XCTAssertEqual(projection.hiddenCount, 0)
            XCTAssertNil(projection.firstHiddenIndex)
            XCTAssertEqual(projection.retainedIndices.count, count + 1)
        }

        let textOnly = MessageBubbleActivityBudget.project(
            protectedEntries: Array(repeating: true, count: 30),
            limit: 12
        )
        XCTAssertEqual(textOnly.hiddenCount, 0)
        XCTAssertNil(textOnly.firstHiddenIndex)
        XCTAssertEqual(textOnly.retainedIndices.count, 30)
    }

    func testInternalAssistantMetadataTextIsNotEligibleDisplayContent() throws {
        let part = try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"step-finish","text":"Internal metadata"}"#.utf8))
        var envelope = emptyMessage(id: "metadata", role: "assistant", sessionID: "ses_test")
        envelope.parts = Array(repeating: part, count: 30)

        XCTAssertNil(MessageBubblePartVisibilityPolicy.renderableText(for: part, isUser: false))
        XCTAssertFalse(MessageBubbleMessageVisibilityPolicy.shouldDisplay(envelope, showsToolCalls: true, showsReasoningBlocks: true))
    }

    func testTranscriptTailSpacingDoesNotStackStreamingReserveUnderProgress() {
        XCTAssertEqual(
            ChatTranscriptTailSpacing.height(showsProgress: true, hasStreamingMessage: true),
            ChatTranscriptTailSpacing.progressHeight
        )
        XCTAssertEqual(
            ChatTranscriptTailSpacing.height(showsProgress: false, hasStreamingMessage: true),
            ChatTranscriptTailSpacing.streamingReserveHeight
        )
        XCTAssertEqual(
            ChatTranscriptTailSpacing.height(showsProgress: false, hasStreamingMessage: false),
            0
        )
    }

    func testMessageBubbleVisibilityPolicyHidesConfiguredPartTypes() {
        let tool = OpenCodePart(
            id: "part_tool",
            messageID: "msg_1",
            sessionID: "ses_1",
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "read",
            callID: "call_1",
            state: nil,
            text: nil
        )
        let reasoning = OpenCodePart(
            id: "part_reasoning",
            messageID: "msg_1",
            sessionID: "ses_1",
            type: "reasoning",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: "Thinking"
        )

        XCTAssertTrue(MessageBubblePartVisibilityPolicy.shouldDisplay(tool, showsToolCalls: true, showsReasoningBlocks: true))
        XCTAssertFalse(MessageBubblePartVisibilityPolicy.shouldDisplay(tool, showsToolCalls: false, showsReasoningBlocks: true))
        XCTAssertTrue(MessageBubblePartVisibilityPolicy.shouldDisplay(reasoning, showsToolCalls: true, showsReasoningBlocks: true))
        XCTAssertFalse(MessageBubblePartVisibilityPolicy.shouldDisplay(reasoning, showsToolCalls: true, showsReasoningBlocks: false))
    }

    func testMessageBubbleVisibilityPolicyRemovesHiddenOnlyRowsButKeepsMixedMessages() {
        let sessionID = "ses_1"
        let tool = OpenCodePart(
            id: "part_tool",
            messageID: "msg_tool",
            sessionID: sessionID,
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "bash",
            callID: "call_1",
            state: OpenCodeToolState(status: "running", title: nil, error: nil, input: nil, output: nil, metadata: nil),
            text: nil
        )
        let reasoning = OpenCodePart(
            id: "part_reasoning",
            messageID: "msg_reasoning",
            sessionID: sessionID,
            type: "reasoning",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: "Thinking"
        )
        let answer = OpenCodePart(
            id: "part_answer",
            messageID: "msg_mixed",
            sessionID: sessionID,
            type: "text",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: "Answer"
        )
        var toolOnly = message(id: "msg_tool", role: "assistant", text: "", sessionID: sessionID)
        toolOnly.parts = [tool]
        var reasoningOnly = message(id: "msg_reasoning", role: "assistant", text: "", sessionID: sessionID)
        reasoningOnly.parts = [reasoning]
        var mixed = message(id: "msg_mixed", role: "assistant", text: "", sessionID: sessionID)
        mixed.parts = [tool, reasoning, answer]

        XCTAssertFalse(MessageBubbleMessageVisibilityPolicy.shouldDisplay(toolOnly, showsToolCalls: false, showsReasoningBlocks: true))
        XCTAssertFalse(MessageBubbleMessageVisibilityPolicy.shouldDisplay(reasoningOnly, showsToolCalls: true, showsReasoningBlocks: false))
        XCTAssertTrue(MessageBubbleMessageVisibilityPolicy.shouldDisplay(mixed, showsToolCalls: false, showsReasoningBlocks: false))
    }

    func testToolActivityPolicyRecognizesLegacyToolsAndSelectsLatestRunningTool() {
        let sessionID = "ses_1"
        let completed = OpenCodePart(
            id: "part_completed",
            messageID: "msg_1",
            sessionID: sessionID,
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "read",
            callID: "call_1",
            state: OpenCodeToolState(status: "completed", title: nil, error: nil, input: nil, output: nil, metadata: nil),
            text: nil
        )
        let running = OpenCodePart(
            id: "part_running",
            messageID: "msg_1",
            sessionID: sessionID,
            type: "bash",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "bash",
            callID: "call_2",
            state: OpenCodeToolState(status: "running", title: nil, error: nil, input: nil, output: nil, metadata: nil),
            text: nil
        )
        var assistant = message(id: "msg_1", role: "assistant", text: "", sessionID: sessionID)
        assistant.parts = [completed, running]

        XCTAssertTrue(OpenCodeToolActivityPolicy.isToolCall(running))
        XCTAssertEqual(OpenCodeToolActivityPolicy.latestRunningToolName(in: assistant), "bash")
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("bash").tint, .green)
    }

    func testAttachmentCardLayoutPreservesCommonImageAspectRatios() {
        XCTAssertEqual(
            AttachmentCardLayout.fittedImageSize(sourceSize: CGSize(width: 2_000, height: 1_000)),
            CGSize(width: 220, height: 110)
        )
        XCTAssertEqual(
            AttachmentCardLayout.fittedImageSize(sourceSize: CGSize(width: 1_000, height: 1_250)),
            CGSize(width: 112, height: 140)
        )
    }

    func testAttachmentCardLayoutKeepsExtremeImagesVisible() {
        XCTAssertEqual(
            AttachmentCardLayout.fittedImageSize(sourceSize: CGSize(width: 10_000, height: 100)),
            CGSize(width: 220, height: 72)
        )
        XCTAssertEqual(
            AttachmentCardLayout.fittedImageSize(sourceSize: CGSize(width: 100, height: 10_000)),
            CGSize(width: 72, height: 140)
        )
        XCTAssertEqual(
            AttachmentCardLayout.fittedImageSize(sourceSize: nil),
            CGSize(width: 140, height: 140)
        )
    }

    func testStreamingChunkAnimationCacheDoesNotReplayTextAfterViewRebuild() {
        let cache = StreamingChunkAnimationCache()
        let first = cache.snapshot(animationID: "part:block-0", text: "Hello", animatesAppend: true, at: 0)
        let rebuilt = cache.snapshot(animationID: "part:block-0", text: "Hello", animatesAppend: true, at: 0.05)
        let appended = cache.snapshot(animationID: "part:block-0", text: "Hello world", animatesAppend: true, at: 0.1)

        XCTAssertEqual(first.chunks, [
            .init(range: NSRange(location: 0, length: 5), startedAt: 0)
        ])
        XCTAssertEqual(rebuilt, first)
        XCTAssertEqual(appended.chunks, [
            .init(range: NSRange(location: 0, length: 5), startedAt: 0),
            .init(range: NSRange(location: 5, length: 6), startedAt: 0.1)
        ])
    }

    func testStreamingGradientOnlyTargetsTrailingFencedCodeBlock() {
        XCTAssertTrue(MarkdownMessageText._testHasActiveStreamingCodeBlock(in: "```json\n{\"ok\": true}"))
        XCTAssertTrue(MarkdownMessageText._testHasActiveStreamingCodeBlock(in: "```json\n{\"ok\": true}\n```"))
        XCTAssertFalse(MarkdownMessageText._testHasActiveStreamingCodeBlock(in: "```json\n{\"ok\": true}\n```\nFollowing text"))
        XCTAssertFalse(MarkdownMessageText._testHasActiveStreamingCodeBlock(in: "A normal streaming paragraph"))
    }

    func testMessageLinkExtractorFindsBareAndMarkdownLinks() {
        let urls = MessageLinkExtractor.urls(
            in: "Visit https://example.com/docs, then [Apple](https://apple.com/swift#overview)."
        )

        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/docs",
            "https://apple.com/swift"
        ])
    }

    func testMessageLinkExtractorIgnoresCodeAndDeduplicatesFragments() {
        let text = """
        Open https://example.com/page#first and https://example.com/page#second.
        `https://inline.example.com`
        ```swift
        let url = "https://code.example.com"
        ```
        """

        XCTAssertEqual(
            MessageLinkExtractor.urls(in: text).map(\.absoluteString),
            ["https://example.com/page"]
        )
    }

    func testMessageLinkExtractorLimitsPreviewsToThreeWebLinks() {
        let text = "mailto:hello@example.com https://one.example https://two.example https://three.example https://four.example"

        XCTAssertEqual(MessageLinkExtractor.urls(in: text).map(\.host), [
            "one.example",
            "two.example",
            "three.example"
        ])
    }

    func testContextIdentitySurvivesPartIndexChanges() {
        let part = OpenCodePart(
            id: "part_read",
            messageID: "msg_1",
            sessionID: "ses_1",
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "read",
            callID: "call_1",
            state: nil,
            text: nil
        )

        XCTAssertEqual(
            MessageBubbleDisplayIdentity.partID(index: 0, part: part),
            MessageBubbleDisplayIdentity.partID(index: 4, part: part)
        )
        XCTAssertEqual(
            MessageBubbleDisplayIdentity.contextID(messageID: "msg_1", firstIndex: 0, firstPart: part),
            MessageBubbleDisplayIdentity.contextID(messageID: "msg_1", firstIndex: 4, firstPart: part)
        )
    }

    func testBottomInsetPreservesAnchorOnlyWhenPinnedAndIdle() {
        XCTAssertTrue(OpenCodeChatBottomAnchorPolicy.preservesBottom(isAtBottom: true, isUserScrolling: false))
        XCTAssertFalse(OpenCodeChatBottomAnchorPolicy.preservesBottom(isAtBottom: false, isUserScrolling: false))
        XCTAssertFalse(OpenCodeChatBottomAnchorPolicy.preservesBottom(isAtBottom: true, isUserScrolling: true))
    }

    func testBottomInsetAnimationRequiresNewAccessoryTokenAndPinnedState() {
        XCTAssertTrue(OpenCodeChatBottomInsetAnimationPolicy.shouldAnimate(
            animationToken: 2,
            lastAnimationToken: 1,
            preservesBottom: true
        ))
        XCTAssertFalse(OpenCodeChatBottomInsetAnimationPolicy.shouldAnimate(
            animationToken: 2,
            lastAnimationToken: 2,
            preservesBottom: true
        ))
        XCTAssertFalse(OpenCodeChatBottomInsetAnimationPolicy.shouldAnimate(
            animationToken: 2,
            lastAnimationToken: 1,
            preservesBottom: false
        ))
    }

#if canImport(UIKit)
    func testTodoCardsReserveHeightBeforeFullContentArrives() {
        let provisional = UIHostingController(rootView: TodoCard(todo: OpenCodeTodo(
            content: "Updating todos",
            status: "pending",
            priority: "medium"
        )))
        let populated = UIHostingController(rootView: TodoCard(todo: OpenCodeTodo(
            content: "Verify that the populated todo content can wrap across two complete lines",
            status: "in_progress",
            priority: "high"
        )))

        let provisionalHeight = provisional.sizeThatFits(in: CGSize(width: 220, height: 1_000)).height
        let populatedHeight = populated.sizeThatFits(in: CGSize(width: 220, height: 1_000)).height

        XCTAssertEqual(provisionalHeight, populatedHeight, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(provisionalHeight, 78)
    }

    func testTodoStatusPresentationLocalizesEveryUpstreamStatus() {
        for status in ["pending", "in_progress", "completed", "cancelled"] {
            XCTAssertNotNil(TodoStatusPresentation.title(for: status), "Missing localized presentation for \(status)")
        }

        XCTAssertNil(TodoStatusPresentation.title(for: "future_status"))
    }

    func testTodoActivityReservesSubtitleHeight() {
        let provisionalStyle = ActivityStyle(
            title: "Updating Todos",
            subtitle: nil,
            icon: "checklist",
            tint: .blue,
            isRunning: true,
            showsDisclosure: true,
            shimmerTitle: false
        )
        let populatedStyle = ActivityStyle(
            title: "Todo Update",
            subtitle: "1 in progress, 2 pending",
            icon: "checklist",
            tint: .blue,
            isRunning: false,
            showsDisclosure: true,
            shimmerTitle: false
        )
        let provisional = UIHostingController(rootView: ActivityRow(style: provisionalStyle, reservesSubtitleSpace: true))
        let populated = UIHostingController(rootView: ActivityRow(style: populatedStyle, reservesSubtitleSpace: true))

        let provisionalHeight = provisional.sizeThatFits(in: CGSize(width: 360, height: 1_000)).height
        let populatedHeight = populated.sizeThatFits(in: CGSize(width: 360, height: 1_000)).height

        XCTAssertEqual(provisionalHeight, populatedHeight, accuracy: 0.5)
    }
#endif

    func testUserPartPolicyDisplaysOnlyFirstNonSyntheticTextPart() throws {
        let original = OpenCodePart(id: "part_original", messageID: "msg_1", sessionID: "ses_1", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "@general inspect Downloads")
        let agent = OpenCodePart(id: "part_agent", messageID: "msg_1", sessionID: "ses_1", type: "agent", mime: nil, filename: nil, name: "general", url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: nil)
        let synthetic = try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"id":"part_synthetic","messageID":"msg_1","sessionID":"ses_1","type":"text","text":"Use the above message and context to generate a prompt","synthetic":true}"#.utf8))
        let parts = [original, agent, synthetic]

        XCTAssertTrue(MessageBubbleUserPartPolicy.shouldDisplay(original, at: 0, in: parts))
        XCTAssertFalse(MessageBubbleUserPartPolicy.shouldDisplay(agent, at: 1, in: parts))
        XCTAssertFalse(MessageBubbleUserPartPolicy.shouldDisplay(synthetic, at: 2, in: parts))
        XCTAssertEqual(synthetic.synthetic, true)
    }

    func testPreviousUserContextUsesSyntheticTextInsteadOfPlaceholder() throws {
        let prompt = "Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed."
        let synthetic = try JSONDecoder().decode(
            OpenCodePart.self,
            from: Data(#"{"id":"part_synthetic","messageID":"msg_1","sessionID":"ses_1","type":"text","text":"Continue if you have next steps, or stop and ask for clarification if you are unsure how to proceed.","synthetic":true}"#.utf8)
        )
        var userMessage = message(id: "msg_1", role: "user", text: "", sessionID: "ses_1")
        userMessage.parts = [synthetic]

        XCTAssertEqual(ChatPreviousUserContextPolicy.displayText(for: userMessage), prompt)
    }

    func testTranscriptWindowRendersOnlyRequestedSuffixWhileCountingHiddenRows() {
        let messages = (0..<1_500).map { index in
            message(
                id: String(format: "msg_%04d", index),
                role: "assistant",
                text: "Visible \(index)",
                sessionID: "ses_test"
            )
        }
        var requestedSuffixes: [Int] = []

        let window = OpenCodeChatTranscriptWindowing.window(
            totalCount: messages.count,
            requestedCount: 50,
            batchSize: 50,
            loadSuffix: { count in
                requestedSuffixes.append(count)
                return Array(messages.suffix(count))
            },
            containsMessageID: { id in messages.contains { $0.id == id } },
            hasDisplayableContent: { !$0.isEmpty }
        )

        XCTAssertEqual(requestedSuffixes, [50, 1_500])
        XCTAssertEqual(window.messages.count, 50)
        XCTAssertEqual(window.messages.first?.id, "msg_1450")
        XCTAssertEqual(window.hiddenMessageCount, 1_450)
    }

    func testFullyLoadedShortTranscriptHasNoHistoryControlEvenWithLongAnswer() {
        let messages = [
            message(id: "user", role: "user", text: "Explain", sessionID: "ses_test"),
            message(id: "answer", role: "assistant", text: String(repeating: "Long answer. ", count: 2_000), sessionID: "ses_test")
        ]
        let window = renderableTranscriptWindow(messages)

        XCTAssertEqual(window.messages, messages)
        XCTAssertEqual(window.hiddenMessageCount, 0)
        XCTAssertFalse(OpenCodeChatTranscriptWindow.showsHistoryControl(hiddenMessageCount: window.hiddenMessageCount, hasMoreHistory: false))
        XCTAssertTrue(OpenCodeChatTranscriptWindow.showsHistoryControl(hiddenMessageCount: window.hiddenMessageCount, hasMoreHistory: true))
    }

    func testNonDisplayableLeadingMessagesDoNotOfferHistory() throws {
        let hidden = try (0..<48).map { index -> OpenCodeMessageEnvelope in
            var envelope = emptyMessage(id: "hidden_\(index)", role: index % 4 == 0 ? "user" : "assistant", sessionID: "ses_test")
            switch index % 4 {
            case 0:
                envelope.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"text","text":"Internal prompt","synthetic":true}"#.utf8))]
            case 1:
                envelope.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"step-start"}"#.utf8))]
            case 2:
                envelope.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"text","text":"   "}"#.utf8))]
            default:
                break // A tombstoned message whose parts have been removed.
            }
            return envelope
        }
        let recent = (0..<12).map {
            message(id: "recent_\($0)", role: "assistant", text: "Answer \($0)", sessionID: "ses_test")
        }
        let window = renderableTranscriptWindow(hidden + recent)

        XCTAssertEqual(window.messages, recent)
        XCTAssertEqual(window.hiddenMessageCount, 0)
        XCTAssertFalse(OpenCodeChatTranscriptWindow.showsHistoryControl(hiddenMessageCount: window.hiddenMessageCount, hasMoreHistory: false))
    }

    func testHistoryRevealSkipsNonDisplayableGapAndKeepsOldUserAndToolReachable() throws {
        let user = message(id: "old_user", role: "user", text: "Original request", sessionID: "ses_test")
        var tool = emptyMessage(id: "old_tool", role: "assistant", sessionID: "ses_test")
        tool.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/tmp"}}"#.utf8))]
        let gap = (0..<36).map { emptyMessage(id: "empty_\($0)", role: "assistant", sessionID: "ses_test") }
        let recent = (0..<12).map { message(id: "recent_\($0)", role: "assistant", text: "Answer", sessionID: "ses_test") }
        let messages = [user, tool] + gap + recent
        let initial = renderableTranscriptWindow(messages)
        XCTAssertEqual(initial.messages, recent)
        XCTAssertEqual(initial.hiddenMessageCount, 2)
        XCTAssertTrue(OpenCodeChatTranscriptWindow.showsHistoryControl(hiddenMessageCount: initial.hiddenMessageCount, hasMoreHistory: false))

        let next = renderableTranscriptWindow(messages, requestedCount: initial.nextRequestedMessageCount)
        XCTAssertTrue(next.messages.contains { $0.id == tool.id })
        XCTAssertEqual(next.hiddenMessageCount, 1)
        let all = renderableTranscriptWindow(messages, requestedCount: next.nextRequestedMessageCount)
        XCTAssertEqual(all.messages, messages)
        XCTAssertEqual(all.messages.filter { $0.id == user.id }.count, 1)
        XCTAssertEqual(all.hiddenMessageCount, 0)
    }

    private func renderableTranscriptWindow(
        _ messages: [OpenCodeMessageEnvelope],
        requestedCount: Int = 12
    ) -> OpenCodeChatTranscriptWindow {
        OpenCodeChatTranscriptWindowing.window(from: messages, requestedCount: requestedCount, batchSize: 12) {
            $0.contains {
                MessageBubbleMessageVisibilityPolicy.shouldDisplay($0, showsToolCalls: true, showsReasoningBlocks: true)
            }
        }
    }

    func testTranscriptWindowExpandsWhenLatestWindowHasNoDisplayableRows() {
        let sessionID = "ses_test"
        let visible = (0..<60).map { index in
            message(id: String(format: "msg_visible_%02d", index), role: "assistant", text: "Visible \(index)", sessionID: sessionID)
        }
        let hidden = (0..<50).map { index in
            emptyMessage(id: String(format: "msg_hidden_%02d", index), role: "assistant", sessionID: sessionID)
        }
        let messages = visible + hidden

        let window = OpenCodeChatTranscriptWindowing.window(
            from: messages,
            requestedCount: 50,
            batchSize: 50
        ) { messages in
            messages.contains { message in
                message.parts.contains { part in
                    part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
            }
        }

        XCTAssertEqual(window.messages.count, 100)
        XCTAssertEqual(window.hiddenMessageCount, 10)
        XCTAssertTrue(window.messages.contains { $0.id == "msg_visible_10" })
        XCTAssertTrue(window.messages.contains { $0.id == "msg_hidden_49" })
    }

    func testTranscriptWindowExpandsToAllWhenNoMessagesAreDisplayable() {
        let messages = (0..<60).map { index in
            emptyMessage(id: String(format: "msg_hidden_%02d", index), role: "assistant", sessionID: "ses_test")
        }

        let window = OpenCodeChatTranscriptWindowing.window(
            from: messages,
            requestedCount: 50,
            batchSize: 50,
            hasDisplayableContent: { _ in false }
        )

        XCTAssertEqual(window.messages.count, 60)
        XCTAssertEqual(window.hiddenMessageCount, 0)
    }

    func testTranscriptWindowKeepsAssistantChildrenLazyWithoutTheirParent() {
        let sessionID = "ses_test"
        let parent = message(id: "msg_parent", role: "user", text: "Start", sessionID: sessionID)
        let children = (0..<60).map { index in
            message(
                id: String(format: "msg_child_%02d", index),
                role: "assistant",
                text: "Child \(index)",
                sessionID: sessionID,
                parentID: parent.id
            )
        }
        let messages = [parent] + children

        let window = OpenCodeChatTranscriptWindowing.window(
            from: messages,
            requestedCount: 50,
            batchSize: 10
        ) { messages in
            messages.contains { message in
                message.parts.contains { part in
                    part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                }
            }
        }

        XCTAssertEqual(window.messages.first?.id, "msg_child_10")
        XCTAssertEqual(window.messages.count, 50)
        XCTAssertEqual(window.hiddenMessageCount, 11)
    }

    func testSyncStateFindsLatestHiddenUserMessageBeforeVisibleSuffix() {
        let sessionID = "ses_test"
        let messages = [
            message(id: "msg_01", role: "user", text: "First prompt", sessionID: sessionID),
            message(id: "msg_02", role: "assistant", text: "First answer", sessionID: sessionID),
            message(id: "msg_03", role: "user", text: "Latest prompt", sessionID: sessionID),
            message(id: "msg_04", role: "assistant", text: "Working", sessionID: sessionID),
            message(id: "msg_05", role: "assistant", text: "Done", sessionID: sessionID),
        ]
        var state = OpenCodeDirectorySyncState()
        state.replaceMessages(messages, forSessionID: sessionID)

        let hiddenUser = state.latestUserMessageEnvelope(
            beforeSuffixCount: 2,
            forSessionID: sessionID
        )

        XCTAssertEqual(hiddenUser?.id, "msg_03")
        XCTAssertEqual(hiddenUser?.parts.first?.text, "Latest prompt")
        XCTAssertNil(state.latestUserMessageEnvelope(beforeSuffixCount: 5, forSessionID: sessionID))
    }

    func testDirectorySnapshotUsesReducerAppliedOffscreenTranscript() {
        let sessionID = "ses_live"
        let session = OpenCodeSession(
            id: sessionID,
            title: "Live",
            workspaceID: nil,
            directory: "/tmp/live",
            projectID: "project",
            parentID: nil
        )
        let registry = DirectoryStoreRegistry()
        let store = registry.store(for: session.directory)
        store.sessions = [session]
        store.applyCanonicalMessages(
            [message(id: "msg_assistant", role: "assistant", text: "Hello", sessionID: sessionID)],
            forSessionID: sessionID
        )
        let coordinator = EventSyncCoordinator()
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: store.sessions,
            selectedSession: nil,
            sessionStatuses: [:],
            syncState: store.syncState,
            messages: [],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents(
            [.messagePartDelta(
                sessionID: sessionID,
                messageID: "msg_assistant",
                partID: "part_msg_assistant",
                field: "text",
                delta: " world"
            )],
            to: state
        )
        store.applyReducedEventState(application.state, scopedSessions: application.state.sessions)

        XCTAssertEqual(
            registry.snapshot(forSessionID: sessionID)?.messages.first?.parts.first?.text,
            "Hello world"
        )
    }

    private func message(id: String, role: String, text: String, sessionID: String, parentID: String? = nil) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil, parentID: parentID),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text)
            ]
        )
    }

    private func emptyMessage(id: String, role: String, sessionID: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: []
        )
    }
}

private final class V2ProjectionFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Session.Message.Assistant encoded shape at 41cb354c, including interleaved content.
        let body = #"""
        {"data":{"id":"msg_assistant","type":"assistant","agent":"build","model":{"providerID":"provider","id":"model"},"time":{"created":1000},"content":[
          {"type":"text","text":"First"},
          {"type":"reasoning","text":"Thought","time":{"created":1050}},
          {"type":"tool","id":"call_read","name":"read","time":{"created":1100,"ran":1150},"state":{"status":"running","input":{"filePath":"README.md","customFlag":true},"metadata":{"description":"ephemeral progress"}}},
          {"type":"text","text":"Hello"}
        ]}}
        """#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
