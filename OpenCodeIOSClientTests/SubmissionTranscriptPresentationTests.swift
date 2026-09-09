import XCTest
import SwiftUI
import Combine
@testable import OpenClient

@MainActor
final class SubmissionTranscriptPresentationTests: XCTestCase {
    private func message(_ id: String, role: String = "user") -> OpenCodeMessageEnvelope {
        .local(role: role, text: id, messageID: id, sessionID: "session")
    }

    func testBridgeWaitsForUsableTextAndEveryAttachmentButNotTextEquality() throws {
        let store = ChatStore()
        let file = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "Server text plus local suffix", attachments: [file], messageID: "local", sessionID: "session")
        XCTAssertTrue(store.beginV2Prompt(local, sessionID: "session", attachments: [file]))
        XCTAssertTrue(store.confirmCanonicalSubmission(local.info))
        let bridge = try XCTUnwrap(store.submissionRecoveries[local.id])
        let text = OpenCodeMessageEnvelope.local(role: "user", text: "Server text", messageID: "local", sessionID: "session")
        var header = text
        header.parts = []
        var empty = text
        empty.parts[0].text = " \n "
        var synthetic = text
        synthetic.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"text","text":"synthetic","synthetic":true}"#.utf8))]
        var unmaterialized = local
        unmaterialized.parts = text.parts + [try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"file","filename":"note.txt","mime":"text/plain"}"#.utf8))]
        for canonical in [header, empty, synthetic, text, unmaterialized] {
            XCTAssertFalse(bridge.canBeReplaced(by: canonical))
            XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [canonical], recoveries: [bridge, bridge]), [local])
            store.retireSubmissionPresentations(in: [canonical], sessionID: "session")
            XCTAssertNotNil(store.submissionRecoveries[local.id])
        }
        var complete = text
        complete.parts += local.parts.filter { $0.type == "file" }
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [complete], recoveries: [bridge]), [complete])
        store.applyCanonicalMessages([complete], forSessionID: "session", isActiveSession: true)
        store.retireSubmissionPresentations(in: [complete], sessionID: "session")
        XCTAssertNil(store.submissionRecoveries[local.id])
        XCTAssertEqual(store.messages, [complete])
    }

    func testCompleteInventoryMayOmitAttachmentButHeaderReadCannotRetireBridge() throws {
        let store = ChatStore()
        let file = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "Original", attachments: [file], messageID: "local", sessionID: "session")
        XCTAssertTrue(store.beginV2Prompt(local, sessionID: "session", attachments: [file]))
        XCTAssertTrue(store.confirmCanonicalSubmission(local.info))
        let header = OpenCodeMessageEnvelope(info: local.info, parts: [])
        store.retireSubmissionPresentations(in: [header], sessionID: "session", completeInventory: true)
        XCTAssertNotNil(store.submissionRecoveries[local.id])
        let canonical = message("local")
        store.applyCanonicalMessages([canonical], forSessionID: "session", isActiveSession: true)
        store.retireSubmissionPresentations(in: [canonical], sessionID: "session", completeInventory: true)
        XCTAssertNil(store.submissionRecoveries[local.id])
        XCTAssertEqual(store.messages, [canonical])
    }

    func testStagingTransferHasNoSynchronousPublicationGapAndFailedStartLeavesNoGhost() {
        for legacy in [false, true] {
            let store = ChatStore()
            let connection = UUID()
            store.selectSubmissionOwner("owner", connectionID: connection)
            let local = message("local")
            store.stageSubmissionPresentation(local, sessionID: "session", canonical: [], attachments: [], agentMentions: [])
            var snapshots: [[String]] = []
            let subscription = store.$stagedSubmissionPresentations.dropFirst().sink { staged in
                let inputs = staged.merging(store.submissionRecoveries) { _, recovery in recovery }
                snapshots.append(inputs.values.map(\.id))
            }
            if legacy {
                XCTAssertTrue(store.beginPromptAdmission(.init(sessionID: "session", messageID: "local", text: "local", scope: .init()), connectionID: connection))
            } else { XCTAssertTrue(store.beginV2Prompt(local, sessionID: "session")) }
            XCTAssertEqual(snapshots, [["local"]])
            withExtendedLifetime(subscription) {}
            store.stageSubmissionPresentation(message("not-started"), sessionID: "session", canonical: [], attachments: [], agentMentions: [])
            store.discardStagedSubmissionPresentation(messageID: "not-started")
            XCTAssertEqual(store.recoveryInputs(sessionID: "session").map(\.id), ["local"])
        }
    }

    func testDefiniteCancellationAndRejectionCleanupCannotBeResurrectedByTaskDefer() {
        for phase in [ChatStore.PromptAdmission.Phase.cancelled, .rejected] {
            let store = ChatStore()
            let connection = UUID()
            store.selectSubmissionOwner("owner", connectionID: connection)
            let local = message("local")
            store.stageSubmissionPresentation(local, sessionID: "session", canonical: [], attachments: [], agentMentions: [])
            XCTAssertTrue(store.beginPromptAdmission(.init(sessionID: "session", messageID: "local", text: "local", scope: .init()), connectionID: connection))
            store.applyPromptAdmission(phase, messageID: "local", connectionID: connection)
            store.discardStagedSubmissionPresentation(messageID: "local")
            XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertTrue(store.confirmCanonicalSubmission(local.info), "Late canonical evidence still wins without resurrecting local presentation")
            XCTAssertEqual(store.promptAdmissionPhase(messageID: "local", sessionID: "session", connectionID: connection), .admitted)
            XCTAssertEqual(store.canonicalSubmissionSessions[local.id], "session")
            XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
        }
    }

    func testUnknownInputStaysAtCapturePositionBeforeLaterCanonicalTurns() throws {
        let store = ChatStore()
        let previous = message("previous", role: "assistant")
        store.applyCanonicalMessages([previous], forSessionID: "session", isActiveSession: true)
        XCTAssertTrue(store.beginV2Prompt(message("local"), sessionID: "session"))
        store.markSubmissionUncertain(messageID: "local", sessionID: "session")
        let input = try XCTUnwrap(store.submissionRecoveries["local"])
        XCTAssertEqual(input.precedingMessageIDs, ["previous"])
        for count in 1...5 {
            let canonical = [message("older"), previous] + (1...count).map { message("later\($0)") }
            let rendered = SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: [input])
            XCTAssertEqual(Array(rendered.prefix(4)).map(\.id), ["older", "previous", "local", "later1"])
            XCTAssertEqual(rendered.filter { $0.id != "local" }, canonical)
        }
        XCTAssertEqual(store.messages, [previous])
        XCTAssertEqual(store.cachedMessagesBySessionID["session"], [previous])
        XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)
        XCTAssertTrue(store.isV2PromptInFlight(sessionID: "session"))
    }

    func testExactCanonicalReplacesOnceAtServerOrder() {
        let store = ChatStore()
        let local = message("local")
        XCTAssertTrue(store.beginV2Prompt(local, sessionID: "session"))
        let recovery = store.recoveryInputs(sessionID: "session")
        let canonical = [message("later"), local, message("answer", role: "assistant")]
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: recovery), canonical)
        store.beginV2TranscriptHydration(sessionID: "session")
        store.applyInitialV2Transcript(canonical, olderCursor: nil, sessionID: "session")
        XCTAssertEqual(store.recoveryInputs(sessionID: "session").count, 1, "Store hydration precedes the directory commit")
        store.retireSubmissionPresentations(in: canonical, sessionID: "session", completeInventory: true)
        XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: store.messages, recoveries: store.recoveryInputs(sessionID: "session")), canonical)
    }

    func testElapsedDecorationDoesNotChangeLedgerOrAdmissionAndSurvivesOwnerReconnect() throws {
        let store = ChatStore()
        let connection = UUID()
        store.selectSubmissionOwner("legacy-owner", connectionID: connection)
        let request = BackendSubmission(sessionID: "session", messageID: "local", text: "local", scope: .init(directory: "/project"))
        XCTAssertTrue(store.beginPromptAdmission(request, connectionID: connection))
        let input = try XCTUnwrap(store.submissionRecoveries["local"])
        let ledger = store.promptAdmissions
        XCTAssertEqual(SubmissionTranscriptPresentation.progress(submittedAt: input.submittedAt, now: input.submittedAt), 0.08, accuracy: 0.0001)
        let end = SubmissionTranscriptPresentation.progress(submittedAt: input.submittedAt, now: input.submittedAt.addingTimeInterval(3.5))
        XCTAssertEqual(end, 0.94, accuracy: 0.0001)
        XCTAssertEqual(end, SubmissionTranscriptPresentation.progress(submittedAt: input.submittedAt, now: input.submittedAt.addingTimeInterval(200)))
        XCTAssertEqual(store.promptAdmissions, ledger)
        XCTAssertEqual(store.submissionRecoveries["local"], input)
        XCTAssertTrue(store.hasPendingPromptAdmission(sessionID: "session", connectionID: connection))
        store.selectSubmissionOwner("legacy-owner", connectionID: UUID())
        XCTAssertEqual(store.submissionRecoveries["local"]?.submittedAt, input.submittedAt)
        store.selectSubmissionOwner("other-owner")
        XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
        store.selectSubmissionOwner("legacy-owner")
        XCTAssertEqual(store.submissionRecoveries["local"]?.submittedAt, input.submittedAt)
        XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)
    }

    func testIndependentWindowProjectionsKeepCanonicalOrderAndAttachmentParts() {
        let file = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        let mention = OpenCodeAgentMention(name: "build", content: "@build", start: 0, end: 6)
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "@build hello", agentMentions: [mention], attachments: [file], messageID: "local", sessionID: "session")
        let input = ChatStore.SubmissionRecovery(sessionID: "session", message: local, phase: .uncertain, attachments: [file], agentMentions: [mention], precedingMessageIDs: ["previous"])
        let canonical = [message("previous"), message("later")]
        let root = SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: [input])
        let otherWindow = SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: [])
        XCTAssertEqual(root.map(\.id), ["previous", "local", "later"])
        XCTAssertEqual(otherWindow, canonical)
        XCTAssertEqual(root[1], local)
        XCTAssertTrue(root[1].parts.contains { $0.type == "file" && $0.filename == "note.txt" })
        XCTAssertTrue(MessageBubbleMessageVisibilityPolicy.shouldDisplay(root[1], showsToolCalls: false, showsReasoningBlocks: false))
        XCTAssertEqual(input.submittedAt, .distantPast)
    }

    func testMissingAnchorNeverAppendsUnknownInputToBottom() {
        let local = message("local")
        let input = ChatStore.SubmissionRecovery(sessionID: "session", message: local, phase: .admitted, pendingStatusUnknown: true, precedingMessageIDs: ["removed"])
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [message("later")], recoveries: [input]).map(\.id), ["local", "later"])
    }

    func testStagingIsImmediatelyVisibleWithoutAdmissionAndBeginKeepsOriginalClockAndAnchor() throws {
        for legacy in [false, true] {
            let store = ChatStore()
            let connection = UUID()
            store.selectSubmissionOwner(legacy ? "legacy" : "v2", connectionID: connection)
            let local = message("local")
            let start = Date(timeIntervalSince1970: 100)
            store.stageSubmissionPresentation(local, sessionID: "session", canonical: [message("previous")],
                attachments: [], agentMentions: [], submittedAt: start)
            XCTAssertEqual(store.recoveryInputs(sessionID: "session").map(\.message), [local])
            XCTAssertTrue(store.submissionRecoveries.isEmpty)
            XCTAssertTrue(store.promptAdmissions.isEmpty)
            XCTAssertFalse(store.hasPendingPromptAdmission(sessionID: "session", connectionID: connection))
            XCTAssertFalse(store.isV2PromptInFlight(sessionID: "session"))
            XCTAssertTrue(store.messages.isEmpty)
            XCTAssertTrue(store.cachedMessagesBySessionID.isEmpty)
            if legacy {
                XCTAssertTrue(store.beginPromptAdmission(.init(sessionID: "session", messageID: "local", text: "local", scope: .init(directory: "/project")), connectionID: connection))
            } else {
                XCTAssertTrue(store.beginV2Prompt(local, sessionID: "session"))
            }
            let recovery = try XCTUnwrap(store.submissionRecoveries["local"])
            XCTAssertEqual(recovery.submittedAt, start)
            XCTAssertEqual(recovery.precedingMessageIDs, ["previous"])
            XCTAssertTrue(store.stagedSubmissionPresentations.isEmpty)
            store.discardStagedSubmissionPresentation(messageID: "local")
            XCTAssertEqual(store.recoveryInputs(sessionID: "session").count, 1)
        }
    }

    func testHiddenHistoryRevealsAnchoredInputWithoutMovingItToLatestTurn() {
        let canonical = (0..<100).map { message("canonical-\($0)") }
        let local = message("local")
        let input = ChatStore.SubmissionRecovery(sessionID: "session", message: local, phase: .uncertain,
            precedingMessageIDs: Array(canonical.prefix(20)).map(\.id))
        let projected = SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: [input])
        let latest = OpenCodeChatTranscriptWindowing.window(from: projected, requestedCount: 10, batchSize: 10) { !$0.isEmpty }
        XCTAssertFalse(latest.messages.contains { $0.id == local.id })
        XCTAssertEqual(latest.hiddenMessageCount, 91)
        let revealed = OpenCodeChatTranscriptWindowing.window(from: projected, requestedCount: 100, batchSize: 10) { !$0.isEmpty }
        let ids = revealed.messages.map(\.id)
        XCTAssertEqual(Array(ids[18...20]), ["canonical-19", "local", "canonical-20"])
        XCTAssertEqual(revealed.messages.last?.id, "canonical-99")
    }

    func testWrongRoleOrSessionCannotReplaceLocalPresentation() {
        let local = message("local")
        let input = ChatStore.SubmissionRecovery(sessionID: "session", message: local, phase: .uncertain)
        let assistant = message("local", role: "assistant")
        let foreign = OpenCodeMessageEnvelope.local(role: "user", text: "foreign", messageID: "local", sessionID: "other")
        for invalid in [assistant, foreign] {
            XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [invalid], recoveries: [input]), [local])
        }
    }

    func testQueuedSubmissionsKeepCaptureOrderAsEachBecomesCanonical() throws {
        for legacy in [false, true] {
            for staged in [false, true] {
                let store = ChatStore()
                let connection = UUID()
                store.selectSubmissionOwner(legacy ? "legacy" : "v2", connectionID: connection)
                let previous = message("p")
                let a = message("a")
                let b = message("b")
                store.applyCanonicalMessages([previous], forSessionID: "session", isActiveSession: true)
                for (index, input) in [a, b].enumerated() {
                    if staged {
                        store.stageSubmissionPresentation(input, sessionID: "session", canonical: [previous],
                            attachments: [], agentMentions: [], submittedAt: Date(timeIntervalSince1970: Double(index)))
                    }
                    if legacy {
                        XCTAssertTrue(store.beginPromptAdmission(.init(sessionID: "session", messageID: input.id,
                            text: input.id, scope: .init(directory: "/project")), connectionID: connection))
                        store.applyPromptAdmission(.admitted, messageID: input.id, connectionID: connection)
                    } else {
                        XCTAssertTrue(store.beginV2Prompt(input, sessionID: "session"))
                        XCTAssertTrue(store.confirmSubmissionAdmission(messageID: input.id, sessionID: "session"))
                    }
                }
                let bRecovery = try XCTUnwrap(store.submissionRecoveries[b.id])
                XCTAssertEqual(bRecovery.precedingMessageIDs, [previous.id, a.id])
                XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [previous],
                    recoveries: store.recoveryInputs(sessionID: "session")).map(\.id), ["p", "a", "b"])
                XCTAssertEqual(store.messages, [previous])
                XCTAssertEqual(store.cachedMessagesBySessionID["session"], [previous])
                XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)

                XCTAssertTrue(store.confirmCanonicalSubmission(a.info))
                XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [previous, a],
                    recoveries: store.recoveryInputs(sessionID: "session")).map(\.id), ["p", "a", "b"])
                XCTAssertEqual(store.submissionRecoveries[b.id], bRecovery, "Promotion must not recapture B's clock or anchors")
                XCTAssertNil(store.canonicalSubmissionSessions[b.id])

                XCTAssertTrue(store.confirmCanonicalSubmission(b.info))
                XCTAssertEqual(store.recoveryInputs(sessionID: "session").count, 2, "Headers admit but do not retire presentation")
                store.applyCanonicalMessages([previous, a, b], forSessionID: "session", isActiveSession: true)
                store.retireSubmissionPresentations(in: [previous, a, b], sessionID: "session")
                XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
                XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [previous, a, b],
                    recoveries: store.recoveryInputs(sessionID: "session")), [previous, a, b])
            }
        }
    }

    func testLocalAnchorRemovalFallsBackWithoutDuplicatesOrCanonicalReordering() {
        let p = message("p")
        let a = message("a")
        let b = message("b")
        let later = message("later")
        let first = ChatStore.SubmissionRecovery(sessionID: "session", message: a, phase: .admitted,
            precedingMessageIDs: [p.id])
        let second = ChatStore.SubmissionRecovery(sessionID: "session", message: b, phase: .admitted,
            precedingMessageIDs: [p.id, a.id])
        for canonical in [[p, later], [later], []] {
            let projected = SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: [second, first])
            XCTAssertEqual(projected.filter { $0.id != a.id && $0.id != b.id }, canonical)
            XCTAssertEqual(projected.filter { $0.id == a.id || $0.id == b.id }.map(\.id), [a.id, b.id])
            XCTAssertEqual(Set(projected.map(\.id)).count, projected.count)
        }
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [p, later], recoveries: [second]), [p, b, later])
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [later], recoveries: [second]), [b, later])
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [p, b, a], recoveries: [second, first]), [p, b, a])
    }

    func testCaptureAndProjectionUseSubmittedAtThenIDForTies() {
        let store = ChatStore()
        let p = message("p")
        for (id, date) in [("a", 100.0), ("b", 100.0), ("c", 200.0)] {
            store.stageSubmissionPresentation(message(id), sessionID: "session", canonical: [p],
                attachments: [], agentMentions: [], submittedAt: Date(timeIntervalSince1970: date))
        }
        let inputs = store.recoveryInputs(sessionID: "session")
        XCTAssertEqual(inputs.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(inputs.last?.precedingMessageIDs, ["p", "a", "b"])
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [p], recoveries: inputs.reversed()).map(\.id), ["p", "a", "b", "c"])
        XCTAssertTrue(store.submissionRecoveries.isEmpty)
        XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)
    }

    func testDisconnectAndProfileSwitchDoNotCaptureForeignLocalAnchors() throws {
        let store = ChatStore()
        store.selectSubmissionOwner("server:legacy")
        XCTAssertTrue(store.beginV2Prompt(message("legacy-a"), sessionID: "session"))
        store.confirmSubmissionAdmission(messageID: "legacy-a", sessionID: "session")
        store.stageSubmissionPresentation(message("discarded-stage"), sessionID: "session", canonical: [],
            attachments: [], agentMentions: [])
        store.selectSubmissionOwner(nil)
        XCTAssertTrue(store.recoveryInputs(sessionID: "session").isEmpty)
        store.selectSubmissionOwner("server:v2")
        let foreignSession = OpenCodeMessageEnvelope.local(role: "user", text: "foreign", messageID: "other-session", sessionID: "other")
        XCTAssertTrue(store.beginV2Prompt(foreignSession, sessionID: "other"))
        let p = message("p")
        store.stageSubmissionPresentation(message("v2-b"), sessionID: "session", canonical: [p],
            attachments: [], agentMentions: [])
        XCTAssertEqual(store.recoveryInputs(sessionID: "session").first?.precedingMessageIDs, [p.id])
        XCTAssertTrue(store.beginV2Prompt(message("v2-b"), sessionID: "session"))
        store.confirmSubmissionAdmission(messageID: "v2-b", sessionID: "session")
        store.selectSubmissionOwner(nil)
        store.selectSubmissionOwner("server:legacy")
        store.stageSubmissionPresentation(message("legacy-b"), sessionID: "session", canonical: [p],
            attachments: [], agentMentions: [])
        let restored = try XCTUnwrap(store.stagedSubmissionPresentations["legacy-b"])
        XCTAssertEqual(restored.precedingMessageIDs, [p.id, "legacy-a"])
        XCTAssertEqual(SubmissionTranscriptPresentation.messages(canonical: [p],
            recoveries: store.recoveryInputs(sessionID: "session")).map(\.id), ["legacy-a", "p", "legacy-b"])
        XCTAssertTrue(store.cachedMessagesBySessionID.isEmpty)
        XCTAssertTrue(store.canonicalSubmissionSessions.isEmpty)
    }

    func testStatusDelayAndFastAdmissionNeverReserveRowHeight() {
        let start = Date(timeIntervalSince1970: 100)
        var input = ChatStore.SubmissionRecovery(sessionID: "session", message: message("local"), phase: .submitting, submittedAt: start)
        for age in [0.0, 1.49] {
            XCTAssertFalse(SubmissionTranscriptPresentation.showsStatus(input: input, now: start.addingTimeInterval(age)))
            let host = UIHostingController(rootView: SubmissionRecoveryStatus(input: input, now: start.addingTimeInterval(age), showDetails: {}))
            XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 440, height: 1000)).height, 0, accuracy: 0.01)
        }
        XCTAssertTrue(SubmissionTranscriptPresentation.showsStatus(input: input, now: start.addingTimeInterval(1.5)))
        let shown = UIHostingController(rootView: SubmissionRecoveryStatus(input: input, now: start.addingTimeInterval(1.5), showDetails: {}))
        XCTAssertGreaterThan(shown.sizeThatFits(in: CGSize(width: 440, height: 1000)).height, 20)
        input.phase = .admitted
        for age in [0.1, 1.5, 20, 1000] {
            XCTAssertFalse(SubmissionTranscriptPresentation.showsStatus(input: input, now: start.addingTimeInterval(age)))
            let host = UIHostingController(rootView: SubmissionRecoveryStatus(input: input, now: start.addingTimeInterval(age), showDetails: {}))
            XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 440, height: 1000)).height, 0, accuracy: 0.01)
        }
        XCTAssertTrue(SubmissionTranscriptPresentation.statusUpdates(input: input).isEmpty)
        let admittedTimeline = UIHostingController(rootView: SubmissionRecoveryView(input: input, checkStatus: { _ in }))
        XCTAssertEqual(admittedTimeline.sizeThatFits(in: CGSize(width: 440, height: 1000)).height, 0, accuracy: 0.01)
        input.phase = .submitting
        input.submittedAt = Date().addingTimeInterval(60)
        let waitingTimeline = UIHostingController(rootView: SubmissionRecoveryView(input: input, checkStatus: { _ in }))
        XCTAssertEqual(waitingTimeline.sizeThatFits(in: CGSize(width: 440, height: 1000)).height, 0, accuracy: 0.01)
    }

    func testStatusClockSurvivesPhaseChangesAndReduceMotionStillWaits() {
        let start = Date(timeIntervalSince1970: 100)
        var input = ChatStore.SubmissionRecovery(sessionID: "session", message: message("local"), phase: .submitting, submittedAt: start)
        let updates = SubmissionTranscriptPresentation.statusUpdates(input: input)
        XCTAssertEqual(updates.count, 61)
        XCTAssertEqual(updates.first, start.addingTimeInterval(1.5))
        XCTAssertEqual(updates.last, start.addingTimeInterval(3.5))
        XCTAssertEqual(SubmissionStatusSchedule(dates: [start.addingTimeInterval(1.5)]).entries(from: start, mode: .normal),
            [start, start.addingTimeInterval(1.5)])
        XCTAssertEqual(SubmissionStatusSchedule(dates: updates).entries(from: start.addingTimeInterval(10), mode: .normal),
            [start.addingTimeInterval(10)])
        XCTAssertEqual(SubmissionTranscriptPresentation.progress(submittedAt: start, now: start.addingTimeInterval(1.5)), 0.08, accuracy: 0.001)
        XCTAssertGreaterThan(SubmissionTranscriptPresentation.progress(submittedAt: start, now: start.addingTimeInterval(2.5)), 0.8)
        XCTAssertEqual(SubmissionTranscriptPresentation.progress(submittedAt: start, now: start.addingTimeInterval(100)), 0.94, accuracy: 0.001)
        for phase in [ChatStore.SubmissionRecovery.Phase.submitting, .uncertain, .cancelled, .admitted] {
            input.phase = phase
            input.pendingStatusUnknown = phase == .admitted
            XCTAssertFalse(SubmissionTranscriptPresentation.showsStatus(input: input, now: start.addingTimeInterval(1.49)))
            XCTAssertTrue(SubmissionTranscriptPresentation.showsStatus(input: input, now: start.addingTimeInterval(1.5)))
            XCTAssertEqual(SubmissionTranscriptPresentation.statusUpdates(input: input), updates)
            XCTAssertEqual(SubmissionTranscriptPresentation.statusProgress(input: input, now: start.addingTimeInterval(1.5), reduceMotion: true), 0.94)
            XCTAssertEqual(SubmissionTranscriptPresentation.statusProgress(input: input, now: start.addingTimeInterval(3.5), reduceMotion: true), 0.94)
            XCTAssertEqual(input.submittedAt, start)
        }
    }

    func testThinkingEligibilityStartsWithoutHTTPOrCanonicalInputAndVisibleAnswerReplacesIt() {
        let user = message("pending")
        let answer = message("answer", role: "assistant")
        for messages in [[], [message("old", role: "assistant")], [user]] {
            XCTAssertTrue(ChatThinkingPresentation.shouldShow(messages: messages, pendingMessageID: user.id,
                isBusy: false, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil))
        }
        for showsDetails in [false, true] {
            XCTAssertFalse(ChatThinkingPresentation.shouldShow(messages: [user, answer], pendingMessageID: user.id,
                isBusy: true, showsToolCalls: showsDetails, showsReasoningBlocks: showsDetails, runningToolName: nil))
        }
        XCTAssertFalse(ChatThinkingPresentation.shouldShow(messages: [user], pendingMessageID: nil,
            isBusy: false, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil), "Stopped, failed, and navigated-away attempts do not create thinking")
        XCTAssertTrue(ChatThinkingPresentation.shouldShow(messages: [user], pendingMessageID: nil,
            isBusy: true, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil))
    }

    func testThinkingToolAndReasoningVisibilityMatrix() throws {
        let user = message("user")
        for status in ["pending", "running", "completed"] {
            let tool = try JSONDecoder().decode(OpenCodePart.self, from: Data("""
                {"id":"tool","type":"tool","tool":"bash","state":{"status":"\(status)","input":{"command":"true"},"output":"ok"}}
                """.utf8))
            for textKind in ["none", "text", "reasoning"] {
                var assistant = message("assistant", role: "assistant")
                assistant.parts = [tool]
                if textKind != "none" {
                    assistant.parts.append(try JSONDecoder().decode(OpenCodePart.self,
                        from: Data("{\"type\":\"\(textKind)\",\"text\":\"Visible content\"}".utf8)))
                }
                for tools in [false, true] {
                    for reasoning in [false, true] {
                        for pending in [false, true] {
                            for busy in [false, true] {
                                let messages = [user, assistant]
                                let pendingID = pending ? user.id : nil
                                let name = ChatThinkingPresentation.summaryToolName(messages: messages,
                                    pendingMessageID: pendingID, isBusy: busy, showsToolCalls: tools)
                                let hiddenRunning = busy && !tools && status != "completed"
                                XCTAssertEqual(name, hiddenRunning ? "bash" : nil)
                                let represented = tools || textKind == "text" || (textKind == "reasoning" && reasoning)
                                XCTAssertEqual(ChatThinkingPresentation.shouldShow(messages: messages,
                                    pendingMessageID: pendingID, isBusy: busy, showsToolCalls: tools,
                                    showsReasoningBlocks: reasoning, runningToolName: name),
                                    (pending || busy) && (hiddenRunning || !represented),
                                    "\(status) \(textKind) tools=\(tools) reasoning=\(reasoning) pending=\(pending) busy=\(busy)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testOldRunningToolCannotColorLatestPendingTurn() throws {
        var old = message("old-tool", role: "assistant")
        old.parts = [try JSONDecoder().decode(OpenCodePart.self,
            from: Data(#"{"type":"tool","tool":"bash","state":{"status":"running"}}"#.utf8))]
        let a = message("a")
        let b = message("b")
        for messages in [[a, old], [a, old, b]] {
            for tools in [false, true] {
                XCTAssertNil(ChatThinkingPresentation.summaryToolName(messages: messages, pendingMessageID: b.id,
                    isBusy: true, showsToolCalls: tools))
                XCTAssertTrue(ChatThinkingPresentation.shouldShow(messages: messages, pendingMessageID: b.id,
                    isBusy: true, showsToolCalls: tools, showsReasoningBlocks: false, runningToolName: "bash"))
            }
        }
    }

    func testThinkingUsesExistingDisplayableContentPolicy() throws {
        let user = message("user")
        for (json, visible) in [
            (#"{"type":"file","url":"https://fixture.invalid/note.txt"}"#, true),
            (#"{"type":"file","filename":"note.txt"}"#, false),
            (#"{"type":"text","text":"  "}"#, false),
            (#"{"type":"step-start"}"#, false)
        ] {
            var assistant = message("assistant", role: "assistant")
            assistant.parts = [try JSONDecoder().decode(OpenCodePart.self, from: Data(json.utf8))]
            XCTAssertEqual(ChatThinkingPresentation.shouldShow(messages: [user, assistant], pendingMessageID: user.id,
                isBusy: true, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil), !visible)
        }
    }

    func testHeldHTTPSubmissionExposesImmediateBubbleAndThinkingForRootAndWindow() async throws {
        for profile in [OpenCodeAPIProfile.legacy, .v2] {
            for window in [false, true] {
                let model = AppViewModel()
                model.config = .init(baseURL: "https://submission-presentation.invalid", apiPreference: profile == .legacy ? .legacy : .v2)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [SubmissionPresentationURLProtocol.self]
                let adapter = OpenCodeBackendAdapter(client: .init(config: model.config, session: URLSession(configuration: configuration)), profile: profile)
                model.backendConnection = BackendConnection(descriptor: .init(id: "presentation", name: "Presentation", version: "1"),
                    capabilities: [.interactions], projects: adapter, sessions: adapter, chat: adapter, models: adapter,
                    events: OpenCodeBackendEventSource(client: adapter.client, profile: profile, manager: model.eventManager))
                if profile == .legacy { model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true) }
                else { model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true) }
                model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
                model.commerceFacade.debugEntitlementOverride = .unlocked
                model.directoryStoreRegistry.activate("/repo")
                let session = OpenCodeSession(id: "session", title: "Session", workspaceID: nil, directory: "/repo", projectID: "project", parentID: nil)
                model.directoryStore.insertV2Session(session)
                _ = model.beginSessionNavigation(session)
                model.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])
                model.chatStore.finishLoadingSelectedSession()
                let facade = window ? ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                    connection: model.backendConnection!, session: session, owner: model.directoryStore)) : model.chatFacade
                let posted = expectation(description: "POST held before receipt: \(profile), window=\(window)")
                var release: CheckedContinuation<Void, Never>?
                var returned = false
                SubmissionPresentationURLProtocol.handler = { request in
                    if request.httpMethod == "POST" {
                        await withCheckedContinuation { release = $0; posted.fulfill() }
                        return (408, "{}")
                    }
                    return (200, "[]")
                }
                let task = Task {
                    if profile == .legacy {
                        _ = await facade.sendMessage("pending", in: session, userVisible: true, messageID: "pending", meterPrompt: false)
                    } else {
                        _ = await facade.sendV2TextPrompt("pending", in: session, messageID: "pending")
                    }
                    returned = true
                }
                await fulfillment(of: [posted], timeout: 5)
                XCTAssertFalse(returned)
                let input = try XCTUnwrap(facade.recoveryInputs(sessionID: session.id).first)
                let projected = SubmissionTranscriptPresentation.messages(canonical: facade.presentationMessages, recoveries: [input])
                XCTAssertEqual(projected.first?.id, "pending")
                XCTAssertEqual(input.phase, .submitting)
                XCTAssertTrue(ChatThinkingPresentation.shouldShow(messages: projected, pendingMessageID: input.id,
                    isBusy: false, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil))
                XCTAssertTrue(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
                release?.resume()
                await task.value
                XCTAssertTrue(returned)
                facade.windowContext?.close()
                model.stopEventStream()
                SubmissionPresentationURLProtocol.handler = nil
            }
        }
    }
}

private final class SubmissionPresentationURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: SubmissionPresentationURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = Delivery(loader: self)
        let request = request
        Task { @MainActor in
            guard let handler = Self.handler else { return }
            let (status, body) = await handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
            delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
        }
    }
    override func stopLoading() {}
}
