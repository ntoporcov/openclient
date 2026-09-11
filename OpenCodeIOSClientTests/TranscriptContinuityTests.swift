import SwiftUI
import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class TranscriptContinuityTests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
    func testOldChatIsHiddenWhenSelectionChangesBeforeShellRouteReplacement() async throws {
        let model = AppViewModel()
        model.backendMode = .cachedServer
        let first = OpenCodeSession(id: "old-presentation", title: "First", workspaceID: nil,
            directory: "/tmp/presentation", projectID: "project", parentID: nil)
        let second = OpenCodeSession(id: "new-presentation", title: "Second", workspaceID: nil,
            directory: first.directory, projectID: first.projectID, parentID: nil)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "Previous transcript",
            messageID: "previous-message", sessionID: first.id, partID: "previous-part")
        model.selectedDirectory = first.directory
        model.allSessions = [first, second]
        model.selectedSession = first
        model.directoryStore.applyCanonicalMessages([message], forSessionID: first.id)
        model.chatStore.beginSelectingSession(sessionID: first.id, cachedMessages: [message])
        model.chatStore.finishLoadingSelectedSession()
        let controller = UIHostingController(rootView: NavigationStack {
            ChatView(chatFacade: model.chatFacade, browser: BrowserStore(), sessionID: first.id)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func transcript(in view: UIView) -> ChatTranscriptCollection? {
            if let collection = view as? ChatTranscriptCollection { return collection }
            return view.subviews.lazy.compactMap { transcript(in: $0) }.first
        }
        for _ in 0..<50 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            if transcript(in: controller.view)?.alpha == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let outgoing = try XCTUnwrap(transcript(in: controller.view))
        XCTAssertEqual(outgoing.alpha, 1)

        // Keep the hosting root on A while canonical selection moves to B.
        model.selectedSession = second
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(outgoing.window, "A cached old route must not show A while the shell prepares B")
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: first.id), [message])
    }

    func testIPhoneChatRouteDoesNotKeepPreviousTranscriptForNavigationFade() async throws {
        let state = ChatRouteTransitionTestState()
        let outgoing = ChatRouteTransitionProbeView()
        let incoming = ChatRouteTransitionProbeView()
        let outgoingAttached = expectation(description: "Outgoing chat mounted")
        let incomingAttached = expectation(description: "Incoming chat mounted")
        outgoing.onAttach = { outgoingAttached.fulfill() }
        incoming.onAttach = { incomingAttached.fulfill() }
        let controller = UIHostingController(rootView: ChatRouteTransitionTestView(
            state: state, outgoing: outgoing, incoming: incoming))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        await fulfillment(of: [outgoingAttached], timeout: 2)
        XCTAssertNotNil(outgoing.window)

        withAnimation(.linear(duration: 5)) {
            state.route = AppShellChatRoute(sessionID: "second", presentationRequest: 0)
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await fulfillment(of: [incomingAttached], timeout: 2)
        controller.view.layoutIfNeeded()

        XCTAssertNotNil(incoming.window)
        XCTAssertNil(outgoing.window, "Only the new transcript should own the entry fade")
    }
    #endif

    func testThinkingGateScopesCompletionAndCancellationWithoutRestartingExistingIndicator() {
        var root = ChatThinkingEntryGate()
        var window = ChatThinkingEntryGate()
        root.begin(messageID: "a", contextID: "root", alreadyVisible: false)
        window.begin(messageID: "a", contextID: "window", alreadyVisible: false)
        XCTAssertTrue(root.blocksThinking(in: "root"))
        XCTAssertTrue(root.reservesTail(in: "root"))
        root.release(messageID: "old", contextID: "root")
        root.release(messageID: "a", contextID: "window")
        XCTAssertTrue(root.blocksThinking(in: "root"))
        root.release(messageID: "a", contextID: "root")
        XCTAssertFalse(root.blocksThinking(in: "root"))
        XCTAssertTrue(window.blocksThinking(in: "window"))
        root.begin(messageID: "b", contextID: "root", alreadyVisible: true)
        XCTAssertFalse(root.blocksThinking(in: "root"))
        XCTAssertFalse(root.reservesTail(in: "root"))
        root.begin(messageID: "c", contextID: "root", alreadyVisible: false)
        root.release(messageID: "a", contextID: "root")
        XCTAssertTrue(root.blocksThinking(in: "root"))
        root.cancel()
        root.release(messageID: "c", contextID: "root")
        XCTAssertTrue(root.blocksThinking(in: "root"), "Stop cannot be undone by an old callback")
        XCTAssertFalse(root.reservesTail(in: "root"))
        XCTAssertFalse(root.blocksThinking(in: "other"))
        root = ChatThinkingEntryGate()
        root.begin(messageID: "d", contextID: "other", alreadyVisible: false)
        root.release(messageID: "c", contextID: "root")
        XCTAssertTrue(root.blocksThinking(in: "other"))
        root.release(messageID: "d", contextID: "other")
        XCTAssertFalse(root.blocksThinking(in: "other"))
    }

    func testOutgoingCompletionIsOneShotAcrossCanonicalReplacementAndReduceMotion() async throws {
        for reduced in [false, true] {
            var callbacks: [String] = []
            let message = OpenCodeMessageEnvelope.local(role: "user", text: "Outgoing", messageID: "outgoing", sessionID: "session")
            func bubble(_ message: OpenCodeMessageEnvelope, reserved: Bool) -> some View {
                outgoingBubble(message, reserved: reserved, reduced: reduced) { callbacks.append($0) }
                    .transaction { $0.animation = nil }
            }
            let host = UIHostingController(rootView: bubble(message, reserved: true))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(90))
            if reduced {
                XCTAssertEqual(callbacks, ["start:outgoing", "complete:outgoing"], "No 120ms or 560ms wait with Reduce Motion")
            } else { XCTAssertFalse(callbacks.contains("complete:outgoing")) }
            try await Task.sleep(for: .milliseconds(140))
            if !reduced { XCTAssertEqual(callbacks, ["start:outgoing"]) }
            let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Canonical outgoing", messageID: "outgoing", sessionID: "session", partID: "server-part")
            host.rootView = bubble(canonical, reserved: false)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(callbacks, ["start:outgoing", "complete:outgoing"])
            host.rootView = bubble(canonical, reserved: true)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(callbacks, ["start:outgoing", "complete:outgoing"], "Same-ID replacement and flag changes never replay completion")
            window.isHidden = true
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(callbacks, ["start:outgoing", "complete:outgoing"])
        }
    }

    func testUnmountCancelsRatherThanCompletesAndHistoricalRowsDoNotSignalEntry() async throws {
        for (reserved, delay) in [(false, 200), (true, 40), (true, 240)] {
            var callbacks: [String] = []
            let message = OpenCodeMessageEnvelope.local(role: "user", text: "Outgoing", messageID: "outgoing", sessionID: "session")
            let host = UIHostingController(rootView: AnyView(outgoingBubble(message, reserved: reserved, reduced: false) { callbacks.append($0) }))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(delay))
            host.rootView = AnyView(Color.clear)
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertFalse(callbacks.contains("complete:outgoing"), "Unmount is not successful entry completion")
            XCTAssertEqual(callbacks.filter { $0 == "cancel:outgoing" }.count, reserved ? 1 : 0)
            if !reserved { XCTAssertTrue(callbacks.isEmpty) }
        }
    }

    private func outgoingBubble(_ message: OpenCodeMessageEnvelope, reserved: Bool, reduced: Bool,
                                callback: @escaping (String) -> Void) -> MessageBubble {
        MessageBubble(message: message, detailedMessage: nil, currentSessionID: "session", isStreamingMessage: false,
            animatesStreamingText: false, showsToolCalls: true, hidesReasoningBlocks: false,
            reserveEntryFromComposer: reserved, animateEntryFromComposer: false, expandedReasoningPartIDs: [],
            expandedContextGroupIDs: [], showsAllActivity: false, resolveTaskSessionID: { _, _ in nil },
            onSelectPart: { _ in }, onOpenTaskSession: { _ in }, onForkMessage: { _ in }, onInspectDebugMessage: { _ in },
            onEntryAnimationStarted: { callback("start:\($0)") }, onToggleReasoningPart: { _ in },
            onToggleContextGroup: { _ in }, onShowEarlierActivity: {}, onOpenVisualHTML: { _ in },
            imageContent: nil, imageLoadingStore: OpenClientImageLoadingStore(), videoStreams: nil,
            videoPlaybackStore: OpenClientVideoPlaybackStore(), onEntryAnimationCompleted: { callback("complete:\($0)") },
            onEntryAnimationCancelled: { callback("cancel:\($0)") }, entryReduceMotionOverride: reduced)
    }

    func testThinkingEntryClockAndReduceMotionPolicy() {
        XCTAssertEqual(ThinkingEntryMotion.progress(elapsed: 0, animateEntry: true, reduceMotion: false), 0)
        let intermediate = ThinkingEntryMotion.progress(elapsed: 0.08, animateEntry: true, reduceMotion: false)
        XCTAssertGreaterThan(intermediate, 0)
        XCTAssertLessThan(intermediate, 1)
        for elapsed in [0.0, 0.08, 0.32, 100] {
            XCTAssertEqual(ThinkingEntryMotion.progress(elapsed: elapsed, animateEntry: false, reduceMotion: false), 1)
            XCTAssertEqual(ThinkingEntryMotion.progress(elapsed: elapsed, animateEntry: true, reduceMotion: true), 1)
        }
        XCTAssertEqual(ThinkingEntryMotion.progress(elapsed: 0.32, animateEntry: true, reduceMotion: false), 1)
    }

    func testThinkingEntryDrawsIntermediateFrameUnderDisabledParentAnimationAndDoesNotReplay() async throws {
        setenv("OPENCLIENT_TRANSCRIPT_CONTINUITY", "1", 1)
        defer { unsetenv("OPENCLIENT_TRANSCRIPT_CONTINUITY") }
        TranscriptContinuityDiagnostics.thinkingProgress = []
        let host = UIHostingController(rootView: ThinkingRow(animateEntry: true).transaction { $0.animation = nil })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 140))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(70))
        func capture(_ name: String) -> Data? {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            return image.pngData()
        }
        let intermediate = capture("thinking-entry-intermediate")
        XCTAssertTrue(TranscriptContinuityDiagnostics.thinkingProgress.contains { $0 > 0 && $0 < 1 })
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(TranscriptContinuityDiagnostics.thinkingProgress.last, 1)
        XCTAssertNotEqual(intermediate, capture("thinking-entry-final"))
        TranscriptContinuityDiagnostics.thinkingProgress = []
        host.rootView = ThinkingRow(animateEntry: true, tint: .green, title: "Working").transaction { $0.animation = nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(TranscriptContinuityDiagnostics.thinkingProgress.contains { $0 < 1 }, "Tint/title updates retain the entry clock")
    }

    func testUniqueIDDiffsApplyWithValidOldAndNewOffsets() throws {
        let permutations = [[], ["a"], ["a", "b"], ["b", "a"], ["a", "caption", "b"], ["chunk1", "chunk2"], ["answer", "caption"]]
        for old in permutations {
            for new in permutations {
                let diff = try XCTUnwrap(ChatTranscriptContinuity.difference(from: old, to: new))
                XCTAssertEqual(old.applying(diff), new)
                var removals = 0
                var inserts = 0
                for change in diff {
                    switch change {
                    case let .remove(index, id, _):
                        XCTAssertTrue(old.indices.contains(index))
                        XCTAssertEqual(old[index], id)
                        removals += 1
                    case let .insert(index, id, _):
                        XCTAssertTrue(new.indices.contains(index))
                        XCTAssertEqual(new[index], id)
                        inserts += 1
                    }
                }
                XCTAssertEqual(old.count - removals + inserts, new.count)
            }
        }
        XCTAssertNil(ChatTranscriptContinuity.difference(from: ["a"], to: ["a", "a"]))
        XCTAssertNil(ChatTranscriptContinuity.difference(from: ["a", "a"], to: ["a"]))
    }

    func testFreshEntryIsPresentationOwnedAndStartedOnlyOnce() {
        let reserved = ChatOutgoingEntry.presentation(messageID: "new", preparingID: "new", animatingID: nil, startedIDs: [])
        XCTAssertTrue(reserved.reserves)
        XCTAssertFalse(reserved.animates)
        XCTAssertEqual(ChatOutgoingEntry.presentation(messageID: "historical", preparingID: "new", animatingID: "new", startedIDs: []), ChatOutgoingEntry())
        XCTAssertTrue(ChatOutgoingEntry.presentation(messageID: "new", preparingID: "new", animatingID: "new", startedIDs: []).animates)
        XCTAssertEqual(ChatOutgoingEntry.presentation(messageID: "new", preparingID: "new", animatingID: "new", startedIDs: ["new"]), ChatOutgoingEntry())
    }

    func testProjectedWindowDoesNotContractOnCanonicalConfirmationOrRecoveryRemoval() {
        let history = (0..<20).map { OpenCodeMessageEnvelope.local(role: $0 == 0 ? "user" : "assistant", text: "history", messageID: "h\($0)", sessionID: "s") }
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "new", messageID: "new", sessionID: "s")
        let recovery = ChatStore.SubmissionRecovery(sessionID: "s", message: local, phase: .submitting, precedingMessageIDs: history.map(\.id))
        let projected = SubmissionTranscriptPresentation.messages(canonical: history, recoveries: [recovery])
        let confirmed = SubmissionTranscriptPresentation.messages(canonical: history + [local], recoveries: [recovery])
        let cleared = SubmissionTranscriptPresentation.messages(canonical: history + [local], recoveries: [])
        for additional in [0, 12, 40] {
            let windows = [projected, confirmed, cleared].map { messages in
                Array(messages.suffix(ChatTranscriptContinuity.requestedCount(messages: messages, additional: additional, initial: 12, fallback: 12))).map(\.id)
            }
            XCTAssertEqual(windows[0], windows[1])
            XCTAssertEqual(windows[1], windows[2])
        }
    }

    func testInitialBottomRequestWaitsForUsableViewportWithoutAnotherDataUpdate() async throws {
        let harness = ChatTranscriptContinuityHarness()
        let collection = harness.collectionView
        collection.frame = .zero
        let ids = (1...5).flatMap { ["turn-\($0)-user", "turn-\($0)-assistant"] }
        harness.update(ids: ids)
        await Task.yield()

        let controller = UIViewController()
        controller.view.addSubview(collection)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        collection.frame = window.bounds
        await settle(harness)

        let bottom = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
        XCTAssertGreaterThan(bottom, 140)
        XCTAssertEqual(collection.contentOffset.y, bottom, accuracy: 2,
            "A zero-sized initial update must not consume the only bottom request")
        XCTAssertNotNil(harness.cell(id: ids.last!))
        XCTAssertEqual(harness.appliedIDs, ids)

        collection.delegate?.scrollViewWillBeginDragging?(collection)
        collection.contentOffset.y = 0
        collection.delegate?.scrollViewDidScroll?(collection)
        collection.delegate?.scrollViewDidEndDragging?(collection, willDecelerate: false)
        collection.frame.size.height = 500
        await settle(harness)
        XCTAssertEqual(collection.contentOffset.y, 0, accuracy: 2,
            "Later viewport layouts must not override deliberate history scrolling")
    }

    func testInitialRevealWaitsForContentViewportAndSettledBottom() async {
        let harness = ChatTranscriptContinuityHarness()
        let collection = harness.collectionView
        collection.frame = .zero
        harness.update(ids: [], hasInitialContent: false)
        harness.prepareInitialReveal()
        XCTAssertEqual(collection.alpha, 0)

        let controller = UIViewController()
        controller.view.addSubview(collection)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        collection.frame = window.bounds
        await settle(harness)
        XCTAssertTrue(harness.awaitsInitialReveal)
        XCTAssertEqual(collection.alpha, 0, "An empty hydration placeholder must not consume the reveal")

        harness.update(ids: (0..<12).map { "row-\($0)" }, revision: 40)
        harness.updateBottomInset(120)
        await settle(harness)
        XCTAssertFalse(harness.awaitsInitialReveal)
        XCTAssertEqual(collection.alpha, 1)
        let bottom = collection.contentSize.height - collection.bounds.height + collection.adjustedContentInset.bottom
        XCTAssertEqual(collection.contentOffset.y, bottom, accuracy: 2)

        collection.delegate?.scrollViewWillBeginDragging?(collection)
        collection.contentOffset.y = 0
        collection.delegate?.scrollViewDidScroll?(collection)
        collection.delegate?.scrollViewDidEndDragging?(collection, willDecelerate: false)
        collection.frame.size.height = 500
        await settle(harness)
        XCTAssertEqual(collection.alpha, 1)
        XCTAssertEqual(collection.contentOffset.y, 0, accuracy: 2)
    }

    func testInitialRevealAllowsLoadedEmptySession() async {
        let harness = ChatTranscriptContinuityHarness()
        harness.update(ids: [], hasInitialContent: false)
        harness.prepareInitialReveal()
        let controller = UIViewController()
        controller.view.addSubview(harness.collectionView)
        let window = UIWindow(frame: harness.collectionView.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        harness.update(ids: [], hasInitialContent: true)
        await settle(harness)
        XCTAssertFalse(harness.awaitsInitialReveal)
        XCTAssertEqual(harness.collectionView.alpha, 1)
    }

    func testInitialMeasurementCoalescesStreamingUntilFadeCompletes() async {
        let harness = ChatTranscriptContinuityHarness()
        harness.update(ids: ["first"], streaming: true)
        harness.prepareInitialReveal()
        let controller = UIViewController()
        controller.view.addSubview(harness.collectionView)
        let window = UIWindow(frame: harness.collectionView.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        harness.sampleInitialLayout()
        harness.update(ids: ["first", "next"], streaming: true)
        harness.update(ids: ["first", "latest"], streaming: true)
        XCTAssertEqual(harness.appliedIDs, ["first"])
        await settle(harness)
        await settle(harness)
        XCTAssertFalse(harness.awaitsInitialReveal)
        XCTAssertEqual(harness.appliedIDs, ["first", "latest"])
        XCTAssertEqual(harness.collectionView.alpha, 1)
    }

    func testDetachedInitialPresentationDefersQueuedRowsUntilReattached() async {
        let harness = ChatTranscriptContinuityHarness()
        harness.update(ids: ["first"])
        harness.prepareInitialReveal()
        let controller = UIViewController()
        controller.view.addSubview(harness.collectionView)
        let window = UIWindow(frame: harness.collectionView.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        harness.sampleInitialLayout()
        harness.update(ids: ["first", "queued"])
        XCTAssertEqual(harness.appliedIDs, ["first"])
        harness.sampleInitialLayout()
        harness.collectionView.removeFromSuperview()
        await settle(harness)
        await settle(harness)
        XCTAssertEqual(harness.appliedIDs, ["first"], "An outgoing fade must not rebuild its queued transcript")
        controller.view.addSubview(harness.collectionView)
        await settle(harness)
        XCTAssertEqual(harness.appliedIDs, ["first", "queued"], "Temporary detach must not lose the newest presentation")
    }

    func testHostingCellsSurviveCanonicalContentCaptionAndChunkReplacement() async throws {
        for pinned in [false, true] {
            let harness = ChatTranscriptContinuityHarness()
            let controller = UIViewController()
            controller.view.addSubview(harness.collectionView)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let original = ["history", "user", "chunk1", "chunk2"]
            harness.update(ids: original, streaming: true)
            await settle(harness)
            harness.pinned = pinned
            let history = try XCTUnwrap(harness.cell(id: "history"))
            let user = try XCTUnwrap(harness.cell(id: "user"))
            let userLifetime = try XCTUnwrap(harness.lifetimes["user"])
            let reloads = harness.collectionView.reloadCount
            let oldY = history.frame.minY - harness.collectionView.contentOffset.y
            harness.update(ids: original, revision: 1, streaming: true)
            await settle(harness)
            XCTAssertTrue(harness.cell(id: "user") === user, "Canonical content must not reuse the user cell")
            XCTAssertEqual(harness.lifetimes["user"], userLifetime, "SwiftUI state must survive in-place canonical replacement")
            harness.update(ids: ["history", "user", "answer", "caption"])
            await settle(harness)
            XCTAssertTrue(harness.cell(id: "history") === history)
            XCTAssertTrue(harness.cell(id: "user") === user)
            XCTAssertEqual(harness.lifetimes["user"], userLifetime)
            XCTAssertEqual(harness.collectionView.reloadCount, reloads)
            XCTAssertEqual(harness.collectionView.itemReloadCount, 0)
            XCTAssertEqual(harness.collectionView.numberOfItems(inSection: 0), 4)
            XCTAssertEqual(history.frame.minY - harness.collectionView.contentOffset.y, oldY, accuracy: 2)
            let screenshot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            })
            screenshot.name = "continuity-hosting-pinned-\(pinned)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testBatchCoalescesLatestPresentationAndRejectsDuplicateIDs() async {
        let harness = ChatTranscriptContinuityHarness()
        let controller = UIViewController()
        controller.view.addSubview(harness.collectionView)
        let window = UIWindow(frame: harness.collectionView.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        harness.update(ids: ["a", "b", "c"])
        await settle(harness)
        let reloads = harness.collectionView.reloadCount
        harness.collectionView.duringBatch = {
            harness.update(ids: ["reentrant", "a", "b"])
            harness.update(ids: ["reentrant-latest", "a", "b"])
        }
        harness.update(ids: ["a", "insert", "b", "c"])
        harness.update(ids: ["c", "a", "b"])
        harness.update(ids: ["a", "b", "latest"])
        await settle(harness)
        XCTAssertEqual(harness.appliedIDs, ["a", "b", "latest"])
        XCTAssertEqual(harness.collectionView.numberOfItems(inSection: 0), 3)
        let batches = harness.collectionView.batchCount
        harness.update(ids: ["a", "a"])
        await settle(harness)
        XCTAssertEqual(harness.appliedIDs, ["a", "b", "latest"])
        XCTAssertEqual(harness.collectionView.batchCount, batches)
        XCTAssertEqual(harness.collectionView.reloadCount, reloads)
    }

    func testScrolledHistoryAnchorAndPinnedTailWithHeightChanges() async throws {
        for pinned in [false, true] {
            let harness = ChatTranscriptContinuityHarness()
            let controller = UIViewController()
            controller.view.addSubview(harness.collectionView)
            let window = UIWindow(frame: harness.collectionView.frame)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let ids = (0..<30).map { "row-\($0)" }
            harness.update(ids: ids)
            await settle(harness)
            if !pinned { harness.collectionView.contentOffset.y = 800 }
            harness.pinned = pinned
            await settle(harness)
            let anchorID = pinned ? "row-28" : "row-12"
            let anchor = try XCTUnwrap(harness.cell(id: anchorID))
            let oldY = anchor.frame.minY - harness.collectionView.contentOffset.y
            let reloads = harness.collectionView.reloadCount
            harness.update(ids: ["inserted-history"] + ids + ["caption"])
            await settle(harness)
            XCTAssertTrue(harness.cell(id: anchorID) === anchor)
            let newY = anchor.frame.minY - harness.collectionView.contentOffset.y
            if pinned {
                let bottom = harness.collectionView.contentSize.height - harness.collectionView.bounds.height
                XCTAssertEqual(harness.collectionView.contentOffset.y, bottom, accuracy: 2)
            } else {
                XCTAssertEqual(newY, oldY, accuracy: 2)
            }
            XCTAssertEqual(harness.collectionView.reloadCount, reloads)
            let measurement = XCTAttachment(string: "pinned=\(pinned) anchorY=\(oldY)->\(newY) offset=\(harness.collectionView.contentOffset.y) height=\(harness.collectionView.contentSize.height) reloadDelta=\(harness.collectionView.reloadCount - reloads)")
            measurement.name = "continuity-scroll-measurement"
            measurement.lifetime = .keepAlways
            add(measurement)
        }
    }

    func testUserDragDuringHeldBatchCompletionSupersedesCapturedScrollPosition() async throws {
        for pinned in [false, true] {
            for userGesture in [false, true] {
                let harness = ChatTranscriptContinuityHarness()
                let collection = harness.collectionView
                let controller = UIViewController()
                controller.view.addSubview(collection)
                let window = UIWindow(frame: collection.frame)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                let ids = (0..<30).map { "row-\($0)" }
                harness.update(ids: ids)
                await settle(harness)
                if !pinned { collection.contentOffset.y = 400 }
                harness.pinned = pinned
                await settle(harness)
                let originalOffset = collection.contentOffset.y
                let reloads = collection.reloadCount
                collection.holdsBatchCompletion = true
                let inserted = ids + ["caption"]
                harness.update(ids: inserted)
                await settle(harness)
                let complete = try XCTUnwrap(collection.heldBatchCompletion)
                collection.heldBatchCompletion = nil
                collection.holdsBatchCompletion = false

                if userGesture { collection.delegate?.scrollViewWillBeginDragging?(collection) }
                collection.contentOffset.y = 800
                collection.delegate?.scrollViewDidScroll?(collection)
                if userGesture { collection.delegate?.scrollViewDidEndDragging?(collection, willDecelerate: false) }
                XCTAssertFalse(collection.isDragging)
                XCTAssertFalse(collection.isDecelerating)
                XCTAssertEqual(harness.pinned, pinned, "Bottom publication remains deferred while the batch is held")
                let chosenOffset = collection.contentOffset.y

                // Keep a complete presentation queued while testing the stale completion.
                let latest = inserted + ["queued-tail"]
                harness.update(ids: latest, revision: 1)
                XCTAssertEqual(harness.appliedIDs, inserted)
                complete()
                await settle(harness)
                XCTAssertEqual(harness.appliedIDs, latest)
                let expectedOffset = userGesture ? chosenOffset : (pinned ? collection.contentSize.height - collection.bounds.height : originalOffset)
                XCTAssertEqual(collection.contentOffset.y, expectedOffset, accuracy: 2,
                    "pinned=\(pinned), userGesture=\(userGesture)")
                XCTAssertEqual(harness.pinned, userGesture ? false : pinned)
                XCTAssertEqual(collection.reloadCount, reloads)
                let measurement = XCTAttachment(string: "initialPinned=\(pinned) userGesture=\(userGesture) chosenOffset=\(chosenOffset) finalOffset=\(collection.contentOffset.y) expectedOffset=\(expectedOffset) finalPinned=\(harness.pinned) queuedRows=\(harness.appliedIDs.count)")
                measurement.name = "continuity-held-batch-drag"
                measurement.lifetime = .keepAlways
                add(measurement)
            }
        }
    }

    private func settle(_ harness: ChatTranscriptContinuityHarness) async {
        for _ in 0..<12 {
            harness.collectionView.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class ChatRouteTransitionTestState: ObservableObject {
    @Published var route = AppShellChatRoute(sessionID: "first", presentationRequest: 0)
}

private struct ChatRouteTransitionTestView: View {
    @ObservedObject var state: ChatRouteTransitionTestState
    let outgoing: UIView
    let incoming: UIView

    var body: some View {
        ZStack {
            ChatRouteView(route: state.route) { id, _ in
                ChatRouteTransitionProbe(view: id == "first" ? outgoing : incoming)
            }
            .equatable()
        }
    }
}

private struct ChatRouteTransitionProbe: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ view: UIView, context: Context) {}
}

private final class ChatRouteTransitionProbeView: UIView {
    var onAttach: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            let callback = onAttach
            onAttach = nil
            callback?()
        }
    }
}
