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

    func testTranscriptWindowLoadsOnlyRequestedSuffixForLongSession() {
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

        XCTAssertEqual(requestedSuffixes, [50])
        XCTAssertEqual(window.messages.count, 50)
        XCTAssertEqual(window.messages.first?.id, "msg_1450")
        XCTAssertEqual(window.hiddenMessageCount, 1_450)
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
