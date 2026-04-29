import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

fileprivate enum AppleIntelligenceInstructionTab: String, CaseIterable, Identifiable {
    case user
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user:
            return "User Prompt"
        case .system:
            return "System Prompt"
        }
    }
}

private struct MessageDebugPayload: Identifiable {
    let id: String
    let title: String
    let json: String

    init?(message: OpenCodeMessageEnvelope) {
        guard let json = message.debugJSONString() else { return nil }
        self.id = message.id
        self.title = message.info.id
        self.json = json
    }
}

private struct CompactionSummaryPayload: Identifiable {
    let id: String
    let title: String
    let summary: String
}

private struct CompactionDisplayItem: Identifiable {
    let boundaryMessage: OpenCodeMessageEnvelope
    let summaryMessage: OpenCodeMessageEnvelope?

    var id: String { "compaction-\(boundaryMessage.id)" }

    var summaryText: String? {
        summaryMessage?.parts
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .nilIfEmpty
    }

    var payload: CompactionSummaryPayload? {
        guard let summaryText else { return nil }
        return CompactionSummaryPayload(id: id, title: "Compacted Context", summary: summaryText)
    }
}

private enum ChatDisplayItem: Identifiable {
    case message(OpenCodeMessageEnvelope)
    case compaction(CompactionDisplayItem)

    var id: String {
        switch self {
        case let .message(message):
            return message.id
        case let .compaction(item):
            return item.id
        }
    }
}

private struct PendingOutgoingSend {
    let text: String
    let attachments: [OpenCodeComposerAttachment]
    let shouldAnimateBubble: Bool
    let messageID: String?
    let partID: String?
}

private struct ReadingModeScrollRequest: Equatable {
    let id = UUID()
    let messageID: String
}

private final class ChatViewTaskStore {
    var autoScrollTask: Task<Void, Never>?
}

private struct MessageComposerSnapshot: Equatable {
    let textValue: String
    let isAccessoryMenuOpenValue: Bool
    let commands: [OpenCodeCommand]
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let actionSignature: String
}

private struct EquatableMessageComposerHost: View, Equatable {
    let text: Binding<String>
    let isAccessoryMenuOpen: Binding<Bool>
    let snapshot: MessageComposerSnapshot
    let commands: [OpenCodeCommand]
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let actionSignature: String
    let onInputFrameChange: (CGRect) -> Void
    let onFocusChange: (Bool) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSelectCommand: (OpenCodeCommand) -> Void
    let onOpenFork: () -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void

    nonisolated static func == (lhs: EquatableMessageComposerHost, rhs: EquatableMessageComposerHost) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        MessageComposer(
            text: text,
            isAccessoryMenuOpen: isAccessoryMenuOpen,
            commands: commands,
            attachmentCount: attachmentCount,
            isBusy: isBusy,
            canFork: canFork,
            onInputFrameChange: onInputFrameChange,
            onFocusChange: onFocusChange,
            onSend: onSend,
            onStop: onStop,
            onSelectCommand: onSelectCommand,
            onOpenFork: onOpenFork,
            onAddAttachments: onAddAttachments
        )
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: AppViewModel
    let sessionID: String

    @Namespace private var toolbarGlassNamespace
    @State private var copiedDebugLog = false
    @State private var selectedMessageDebugPayload: MessageDebugPayload?
    @State private var selectedCompactionSummary: CompactionSummaryPayload?
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var showingTodoInspector = false
    @State private var visibleMessageCount = 80
    @State private var hasLoadedInitialWindow = false
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var taskStore = ChatViewTaskStore()
    @State private var isComposerInputFocused = false
    @State private var shouldSnapOnNextMessage = false
    @State private var shouldDelayNextUserInsertScroll = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var isComposerMenuOpen = false
    @State private var copiedTranscript = false
    @State private var pendingOutgoingSend: PendingOutgoingSend?
    @State private var pendingOutgoingSendTask: Task<Void, Never>?
    @State private var outgoingEntryResetTask: Task<Void, Never>?
    @State private var thinkingRowRevealTask: Task<Void, Never>?
    @State private var isThinkingRowRevealAllowed = true
    @State private var preparingOutgoingMessageID: String?
    @State private var animatingOutgoingMessageID: String?
    @State private var readingModeScrollRequest: ReadingModeScrollRequest?
    @State private var isSendReadingModeActive = false
    @State private var animatedReadingModeBottomSpacerHeight: CGFloat = 0
    @State private var jumpToLatestRequest = 0
    @State private var listViewportHeight: CGFloat = 0
    @State private var bottomAnchorFrame: CGRect = .zero
    @State private var needsInitialBottomSnap = true
    @State private var hasCompletedInitialHydrationSnap = false
    @State private var composerOverlayHeight: CGFloat = 0
    @State private var shouldFollowComposerAffordanceChange = false
    @State private var affordanceScrollTask: Task<Void, Never>?
    @State private var needsInitialComposerHeightSnap = true
    @State private var contentRevealTask: Task<Void, Never>?
    @State private var isChatContentVisible = false
    @State private var loadingIndicatorTask: Task<Void, Never>?
    @State private var shouldShowLoadingIndicator = false
    @State private var chatContentOffsetY: CGFloat = 14
    @State private var isScrollGeometryAtBottom = true
    @State private var isRefreshingChatData = false
    @State private var bottomPullDistance: CGFloat = 0
    @State private var bottomPullStartedAtBottom = false
    @State private var bottomPullIsTracking = false
    @State private var hasFiredBottomPullHaptic = false

    @State private var selectedInstructionTab: AppleIntelligenceInstructionTab = .user

    private let messageWindowSize = 10
    private let bottomRefreshThreshold: CGFloat = 72
    private let bottomRefreshIndicatorHeight: CGFloat = 34
    private var todoIDs: String {
        viewModel.todos.map { $0.id }.joined(separator: "|")
    }

    private var permissionIDs: String {
        viewModel.permissions(for: sessionID).map { $0.id }.joined(separator: "|")
    }

    private var questionIDs: String {
        viewModel.questions(for: sessionID).map { $0.id }.joined(separator: "|")
    }

    private var listAnimationSignature: String {
        displayedChatItems
            .map(\.id)
            .joined(separator: "|")
    }

    private var liveSession: OpenCodeSession {
        if let selected = viewModel.selectedSession, selected.id == sessionID {
            return selected
        }

        return viewModel.session(matching: sessionID) ?? OpenCodeSession(
            id: sessionID,
            title: "Session",
            workspaceID: nil,
            directory: nil,
            projectID: nil,
            parentID: nil
        )
    }

    private var isSessionBusy: Bool {
        viewModel.sessionStatuses[liveSession.id] == "busy"
    }

    private var isComposerBusy: Bool {
        isSessionBusy || pendingOutgoingSend != nil
    }

    private var composerActionSignature: String {
        [
            liveSession.id,
            liveSession.directory ?? "",
            liveSession.workspaceID ?? "",
            liveSession.projectID ?? "",
            liveSession.parentID ?? ""
        ].joined(separator: "|")
    }

    private var streamingFollowSignature: String {
        [
            displayedMessages.last?.id ?? "none",
            String(displayedMessages.last?.parts.count ?? 0),
            String(lastDisplayedMessageTextLength),
            shouldShowThinking ? "thinking" : "idle"
        ].joined(separator: "|")
    }

    private var isChildSession: Bool {
        liveSession.parentID != nil
    }

    private var parentSession: OpenCodeSession? {
        viewModel.parentSession(for: liveSession)
    }

    private var childSessionTitle: String {
        viewModel.childSessionTitle(for: liveSession)
    }

    private var parentSessionTitle: String {
        viewModel.parentSessionTitle(for: liveSession)
    }

    private var isLoadingSelectedSession: Bool {
        viewModel.selectedSession?.id == sessionID && viewModel.directoryState.isLoadingSelectedSession && viewModel.messages.isEmpty
    }

    private var shouldAnimateInitialChatReveal: Bool {
        viewModel.messages.isEmpty
    }

    private var shouldShowChatLoadingOverlay: Bool {
        isLoadingSelectedSession || !isChatContentVisible
    }

    private var shouldShowJumpToLatestButton: Bool {
        if isSendReadingModeActive, !hasReadingModeOverflowContent {
            return false
        }

        return hasLoadedInitialWindow && !isScrollGeometryAtBottom && !shouldShowChatLoadingOverlay
    }

    private var hasReadingModeOverflowContent: Bool {
        guard isSendReadingModeActive,
              let messageID = readingModeScrollRequest?.messageID,
              let messageIndex = displayedMessages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        let messagesAfterSend = displayedMessages.suffix(from: displayedMessages.index(after: messageIndex))
        let textCount = messagesAfterSend.reduce(0) { partialResult, message in
            guard (message.info.role ?? "").lowercased() == "assistant" else { return partialResult }
            return partialResult + message.parts.reduce(0) { partResult, part in
                partResult + (part.text?.count ?? 0) + (activityStyleCandidate(part) ? 180 : 0)
            }
        }

        return textCount > estimatedReadingModeViewportCharacterCapacity
    }

    private var estimatedReadingModeViewportCharacterCapacity: Int {
        let usableHeight = max(240, listViewportHeight - composerOverlayHeight - 96)
        let estimatedLineCount = max(8, Int(usableHeight / 22))
        return estimatedLineCount * 42
    }

    private func activityStyleCandidate(_ part: OpenCodePart) -> Bool {
        !["", "step-start", "step-finish", "reasoning", "text"].contains(part.type)
    }

    private var jumpToLatestButton: some View {
        VStack {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button {
                    viewModel.flushBufferedTranscript(reason: "jump to latest")
                    isSendReadingModeActive = false
                    jumpToLatestRequest += 1
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(.thinMaterial, in: Circle())
                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                .accessibilityLabel("Jump to latest")
                Spacer(minLength: 0)
            }
            .padding(.bottom, max(16, composerOverlayHeight + 12))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .animation(.easeOut(duration: 0.16), value: shouldShowJumpToLatestButton)
    }

    private var chatLoadingOverlay: some View {
        VStack {
            if shouldShowLoadingIndicator {
                ProgressView()
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(OpenCodePlatformColor.groupedBackground)
        .allowsHitTesting(false)
    }

    var body: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    List {
                        if hiddenMessageCount > 0 {
                            Button {
                                visibleMessageCount = min(viewModel.messages.count, visibleMessageCount + messageWindowSize)
                            } label: {
                                Text("View older messages (\(hiddenMessageCount))")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(OpenCodePlatformColor.secondaryGroupedBackground, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 4)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 0, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }

                        ForEach(displayedChatItems) { item in
                            chatRow(for: item)
                        }

                        if shouldShowThinking {
                            thinkingRowListItem
                        }

                    bottomAnchorListItem
                    }
                    .listStyle(.plain)
                    .chatScrollBottomTracking($isScrollGeometryAtBottom)
                    .simultaneousGesture(bottomOverscrollRefreshGesture)
                    .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: listAnimationSignature)
                    .scrollContentBackground(.hidden)
                    .opencodeInteractiveKeyboardDismiss()
                    .background(OpenCodePlatformColor.groupedBackground)
                    .accessibilityIdentifier("chat.scroll")
                    .opacity(isChatContentVisible ? 1 : 0)
                    .offset(y: chatContentOffsetY)
                    .overlay {
                        if shouldShowChatLoadingOverlay {
                            chatLoadingOverlay
                        }
                    }
                    .animation(.easeOut(duration: 0.18), value: isChatContentVisible)
                    .animation(.easeOut(duration: 0.18), value: chatContentOffsetY)
                    .onAppear {
                        listViewportHeight = geometry.size.height
                        needsInitialBottomSnap = true
                        needsInitialComposerHeightSnap = true
                        hasCompletedInitialHydrationSnap = false
                        isChatContentVisible = !shouldAnimateInitialChatReveal
                        chatContentOffsetY = shouldAnimateInitialChatReveal ? 14 : 0
                        shouldShowLoadingIndicator = false
                        if !hasLoadedInitialWindow {
                            visibleMessageCount = messageWindowSize
                            hasLoadedInitialWindow = true
                        }
                        updateChatContentVisibility()
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onChange(of: bottomAnchorFrame) { _, frame in
                        guard needsInitialBottomSnap, frame != .zero else { return }
                        needsInitialBottomSnap = false
                        scheduleScrollToBottom(with: proxy, delayMS: 80)
                    }
                    .onChange(of: geometry.size.height) { _, height in
                        listViewportHeight = height
                        updateReadingModeBottomSpacerHeight(animated: false)
                        if isSendReadingModeActive, let request = readingModeScrollRequest {
                            scheduleReadingModeScroll(to: request.messageID, with: proxy)
                            return
                        }
                        guard isScrollGeometryAtBottom, !isSendReadingModeActive else { return }
                        scheduleScrollToBottom(with: proxy, delayMS: 20)
                    }
                    .onChange(of: composerOverlayHeight) { oldHeight, newHeight in
                        guard newHeight > 0, abs(newHeight - oldHeight) > 1 else { return }
                        updateReadingModeBottomSpacerHeight(animated: false)
                        if needsInitialComposerHeightSnap, !viewModel.messages.isEmpty {
                            needsInitialComposerHeightSnap = false
                            scheduleComposerAffordanceFollow(with: proxy, delayMS: 60)
                            return
                        }
                        guard !isSendReadingModeActive, shouldFollowComposerAffordanceChange || isScrollGeometryAtBottom else { return }
                        shouldFollowComposerAffordanceChange = false
                        scheduleComposerAffordanceFollow(with: proxy, delayMS: 20)
                    }
                    .onChange(of: viewModel.messages.count) { oldCount, count in
                        if !hasLoadedInitialWindow {
                            visibleMessageCount = messageWindowSize
                            return
                        }

                        visibleMessageCount = min(count, max(visibleMessageCount, messageWindowSize))
                        if count == 0 {
                            visibleMessageCount = messageWindowSize
                        }

                        if count > 0, !hasCompletedInitialHydrationSnap {
                            hasCompletedInitialHydrationSnap = true
                            scheduleScrollToBottom(with: proxy, delayMS: 120)
                            scheduleChatContentReveal(delayMS: 180)
                        }

                        guard count > oldCount else { return }

                        if isSendReadingModeActive, let request = readingModeScrollRequest {
                            scheduleReadingModeScroll(to: request.messageID, with: proxy)
                            updateChatContentVisibility()
                            return
                        }

                        if !isSendReadingModeActive, shouldSnapOnNextMessage || isScrollGeometryAtBottom {
                            shouldSnapOnNextMessage = false
                            let delay = shouldDelayNextUserInsertScroll ? 180 : 10
                            shouldDelayNextUserInsertScroll = false
                            scheduleScrollToBottom(with: proxy, delayMS: delay)
                        }

                        updateChatContentVisibility()
                    }
                    .onChange(of: streamingFollowSignature) { _, _ in
                        guard hasLoadedInitialWindow, isScrollGeometryAtBottom, !isComposerInputFocused, !isSendReadingModeActive else { return }
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onChange(of: jumpToLatestRequest) { _, _ in
                        scrollToBottom(with: proxy, animated: true)
                    }
                    .onChange(of: isLoadingSelectedSession) { _, _ in
                        updateChatContentVisibility()
                    }
                    .onChange(of: isReadingModeStreamActive) { _, isActive in
                        updateReadingModeBottomSpacerHeight(animated: !isActive)
                        if !isActive {
                            retireSendReadingModeAfterStream()
                        }
                    }
                    .onPreferenceChange(ChatBottomAnchorFramePreferenceKey.self) { frame in
                        guard needsInitialBottomSnap, bottomAnchorFrame != frame else { return }
                        bottomAnchorFrame = frame
                    }
#if canImport(UIKit)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                        guard keyboardWillShow(from: notification), isScrollGeometryAtBottom, !isSendReadingModeActive else { return }
                        scheduleComposerAffordanceFollow(with: proxy, delayMS: 20)
                    }
#endif
                }
            }

            if shouldShowJumpToLatestButton {
                jumpToLatestButton
            }
        }
        .coordinateSpace(name: "chat-view-space")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composerOverlay
        }
        .navigationTitle(isChildSession ? childSessionTitle : (liveSession.title ?? "Session"))
        .opencodeInlineNavigationTitle()
        .onAppear {
            viewModel.activeChatSessionID = sessionID
        }
        .onDisappear {
            viewModel.setComposerStreamingFocus(false)
            taskStore.autoScrollTask?.cancel()
            contentRevealTask?.cancel()
            loadingIndicatorTask?.cancel()
            pendingOutgoingSendTask?.cancel()
            outgoingEntryResetTask?.cancel()
            thinkingRowRevealTask?.cancel()
            if viewModel.activeChatSessionID == sessionID {
                viewModel.activeChatSessionID = nil
            }
        }
        .toolbar { chatToolbar }
#if DEBUG
        .sheet(isPresented: $viewModel.isShowingDebugProbe) {
            ChatDebugProbeSheet(viewModel: viewModel, copiedDebugLog: $copiedDebugLog)
        }
#endif
        .sheet(item: $selectedActivityDetail) { detail in
            NavigationStack {
                ActivityDetailView(viewModel: viewModel, detail: detail)
            }
        }
        .sheet(item: $selectedMessageDebugPayload) { payload in
            NavigationStack {
                MessageDebugSheet(payload: payload)
            }
        }
        .sheet(item: $selectedCompactionSummary) { payload in
            NavigationStack {
                CompactionSummarySheet(payload: payload)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingTodoInspector) {
            NavigationStack {
                TodoInspectorView(viewModel: viewModel)
            }
        }
        .sheet(item: $selectedAttachmentPreview) { attachment in
            NavigationStack {
                AttachmentPreviewSheet(attachment: attachment)
            }
        }
        .sheet(isPresented: $viewModel.isShowingAppleIntelligenceInstructionsSheet) {
            NavigationStack {
                AppleIntelligenceInstructionsSheet(
                    userInstructions: $viewModel.appleIntelligenceUserInstructions,
                    systemInstructions: $viewModel.appleIntelligenceSystemInstructions,
                    selectedTab: $selectedInstructionTab,
                    defaultUserInstructions: viewModel.defaultAppleIntelligenceUserInstructions,
                    defaultSystemInstructions: viewModel.defaultAppleIntelligenceSystemInstructions,
                    onDone: {
                        viewModel.isShowingAppleIntelligenceInstructionsSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingForkSessionSheet) {
            NavigationStack {
                ForkSessionSheet(viewModel: viewModel, sessionID: sessionID)
            }
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if composerAccessoryExpansion.isExpanded || isComposerMenuOpen {
                GeometryReader { geometry in
                    let protectedWidth: CGFloat = isComposerMenuOpen ? 276 : 0
                    let protectedHeight: CGFloat = isComposerMenuOpen ? 252 : 0

                    VStack(spacing: 0) {
                        Color.black.opacity(0.001)
                            .frame(height: max(0, geometry.size.height - protectedHeight))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissComposerOverlays()
                            }

                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: protectedWidth)

                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    dismissComposerOverlays()
                                }
                        }
                        .frame(height: protectedHeight)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .onChange(of: accessoryPresenceSignature) { _, _ in
            shouldFollowComposerAffordanceChange = isScrollGeometryAtBottom
            if viewModel.draftAttachments.isEmpty || viewModel.todos.allSatisfy(\.isComplete) {
                composerAccessoryExpansion = .collapsed
            }
        }
        .onChange(of: viewModel.messages.count) { _, _ in
            copiedTranscript = false
        }
    }

    private var draftTextBinding: Binding<String> {
        Binding(
            get: { viewModel.draftMessage },
            set: { newValue in
                viewModel.setDraftMessage(newValue, forSessionID: sessionID)
            }
        )
    }

    private var composerStack: some View {
        VStack(spacing: 6) {
            if viewModel.todos.contains(where: { !$0.isComplete }) || !viewModel.draftAttachments.isEmpty {
                ComposerAccessoryArea(
                    todos: viewModel.todos,
                    attachments: viewModel.draftAttachments,
                    expansion: $composerAccessoryExpansion,
                    onTapTodo: {
                        showingTodoInspector = true
                    },
                    onTapAttachment: { attachment in
                        selectedAttachmentPreview = attachment
                    },
                    onRemoveAttachment: { attachment in
                        viewModel.removeDraftAttachment(attachment)
                    }
                )
                .padding(.horizontal, 16)
            }

            let permissions = viewModel.permissions(for: sessionID)
            let questions = viewModel.questions(for: sessionID)

            if !permissions.isEmpty {
                PermissionActionStack(
                    permissions: permissions,
                    onDismiss: { permission in
                        viewModel.dismissPermission(permission)
                    },
                    onRespond: { permission, response in
                        Task { await viewModel.respondToPermission(permission, response: response) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if !questions.isEmpty {
                QuestionPanel(
                    requests: questions,
                    answers: $questionAnswers,
                    customAnswers: $questionCustomAnswers,
                    onDismiss: { request in
                        Task { await viewModel.dismissQuestion(request) }
                    },
                    onSubmit: { request, answers in
                        Task { await viewModel.respondToQuestion(request, answers: answers) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                let isBusy = isComposerBusy
                if isChildSession {
                    childSessionComposerNotice
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                } else {
                    activeMessageComposer(isBusy: isBusy)
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func activeMessageComposer(isBusy: Bool) -> some View {
        let canFork = !viewModel.forkableMessages.isEmpty
        let commands = viewModel.commands(canFork: canFork)
        let snapshot = MessageComposerSnapshot(
            textValue: viewModel.draftMessage,
            isAccessoryMenuOpenValue: isComposerMenuOpen,
            commands: commands,
            attachmentCount: viewModel.draftAttachments.count,
            isBusy: isBusy,
            canFork: canFork,
            actionSignature: composerActionSignature
        )

        let composer = EquatableMessageComposerHost(
            text: draftTextBinding,
            isAccessoryMenuOpen: $isComposerMenuOpen,
            snapshot: snapshot,
            commands: commands,
            attachmentCount: snapshot.attachmentCount,
            isBusy: isBusy,
            canFork: canFork,
            actionSignature: snapshot.actionSignature,
            onInputFrameChange: { _ in },
            onFocusChange: { isFocused in
                isComposerInputFocused = isFocused
                viewModel.setComposerStreamingFocus(isFocused)
            },
            onSend: {
                startOutgoingBubbleAnimationAndSend()
            },
            onStop: {
                stopComposerAction()
            },
            onSelectCommand: { command in
                viewModel.flushBufferedTranscript(reason: "command action")
                if viewModel.isForkClientCommand(command) {
                    viewModel.draftMessage = ""
                    viewModel.clearPersistedMessageDraft(forSessionID: sessionID)
                    viewModel.presentForkSessionSheet()
                    return
                }
                guard viewModel.reserveUserPromptIfAllowed() else { return }
                shouldSnapOnNextMessage = true
                Task { await viewModel.sendCommand(command, sessionID: sessionID, userVisible: true, meterPrompt: false) }
            },
            onOpenFork: {
                viewModel.presentForkSessionSheet()
            },
            onAddAttachments: { attachments in
                viewModel.addDraftAttachments(attachments)
            }
        )

        composer
            .equatable()
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.clear)
    }

    private var childSessionComposerNotice: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 4) {
                Text("Subagent sessions cannot be prompted.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Return to the main session to continue the conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Back") {
                guard let parentSession else { return }
                Task { await viewModel.selectSession(parentSession) }
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
        .padding(12)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var composerOverlay: some View {
        measuredComposerStack
            .background(Color.clear)
    }

    private var bottomAnchorListItem: some View {
        VStack(spacing: 8) {
            if shouldShowBottomRefreshIndicator {
                bottomRefreshIndicator
            }
        }
        .frame(maxWidth: .infinity)
            .frame(height: messageBottomPadding + readingModeBottomSpacerHeight + bottomRefreshIndicatorHeight * bottomPullProgress)
            .background {
                GeometryReader { anchorGeometry in
                    Color.clear
                        .preference(key: ChatBottomAnchorFramePreferenceKey.self, value: anchorGeometry.frame(in: .named("chat-view-space")))
                }
            }
            .id("chat-bottom-anchor")
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private var shouldShowBottomRefreshIndicator: Bool {
        isRefreshingChatData || bottomPullDistance > 1
    }

    private var bottomPullProgress: CGFloat {
        if isRefreshingChatData { return 1 }
        return min(1, bottomPullDistance / bottomRefreshThreshold)
    }

    private var bottomRefreshIndicator: some View {
        Group {
            if isRefreshingChatData {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(bottomPullProgress >= 1 ? .blue : .secondary)
            }
        }
        .frame(width: 28, height: 28)
        .scaleEffect(0.55 + 0.45 * bottomPullProgress)
        .opacity(0.25 + 0.75 * bottomPullProgress)
        .animation(.snappy(duration: 0.18, extraBounce: 0.02), value: bottomPullProgress)
        .animation(.easeOut(duration: 0.12), value: isRefreshingChatData)
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
    }

    private var measuredComposerStack: some View {
        composerStack
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: ComposerOverlayHeightPreferenceKey.self, value: geometry.size.height)
                }
            }
            .onPreferenceChange(ComposerOverlayHeightPreferenceKey.self) { height in
                guard abs(composerOverlayHeight - height) > 0.5 else { return }
                composerOverlayHeight = height
            }
    }

    private func scheduleScrollToBottom(with proxy: ScrollViewProxy, delayMS: Int = 10) {
        scheduleScrollToBottom(with: proxy, delayMS: delayMS, animated: false)
    }

    private func scheduleScrollToBottom(with proxy: ScrollViewProxy, delayMS: Int = 10, animated: Bool) {
        taskStore.autoScrollTask?.cancel()
        taskStore.autoScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMS))
            guard !Task.isCancelled else { return }
            scrollToBottom(with: proxy, animated: animated)
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
    }

    private func scheduleReadingModeScroll(to messageID: String, with proxy: ScrollViewProxy) {
        taskStore.autoScrollTask?.cancel()
        taskStore.autoScrollTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, isSendReadingModeActive else { return }
            scrollToMessage(messageID, with: proxy, anchor: .top, animated: true)

            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled, isSendReadingModeActive else { return }
            scrollToMessage(messageID, with: proxy, anchor: .top, animated: true)
        }
    }

    private func scrollToMessage(_ messageID: String, with proxy: ScrollViewProxy, anchor: UnitPoint, animated: Bool) {
        if animated {
            withAnimation(.easeInOut(duration: 0.30)) {
                proxy.scrollTo(messageID, anchor: anchor)
            }
        } else {
            proxy.scrollTo(messageID, anchor: anchor)
        }
    }

    private func scheduleComposerAffordanceFollow(with proxy: ScrollViewProxy, delayMS: Int) {
        affordanceScrollTask?.cancel()
        affordanceScrollTask = Task { @MainActor in
            scheduleScrollToBottom(with: proxy, delayMS: delayMS)
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            scheduleScrollToBottom(with: proxy, delayMS: 0)
        }
    }

    private var bottomOverscrollRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                if !bottomPullIsTracking {
                    bottomPullIsTracking = true
                    bottomPullStartedAtBottom = isScrollGeometryAtBottom && !isRefreshingChatData
                    hasFiredBottomPullHaptic = false
                }

                guard bottomPullStartedAtBottom else { return }

                let distance = max(0, -value.translation.height)
                bottomPullDistance = distance

                if distance >= bottomRefreshThreshold, !hasFiredBottomPullHaptic {
                    hasFiredBottomPullHaptic = true
                    OpenCodeHaptics.impact(.crisp)
                } else if distance < bottomRefreshThreshold * 0.65 {
                    hasFiredBottomPullHaptic = false
                }
            }
            .onEnded { _ in
                let shouldRefresh = bottomPullStartedAtBottom && bottomPullDistance >= bottomRefreshThreshold && !isRefreshingChatData
                bottomPullIsTracking = false
                bottomPullStartedAtBottom = false
                hasFiredBottomPullHaptic = false

                if shouldRefresh {
                    Task { @MainActor in
                        await refreshChatDataFromBottomOverscroll()
                    }
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0.02)) {
                        bottomPullDistance = 0
                    }
                }
            }
    }

    @MainActor
    private func refreshChatDataFromBottomOverscroll() async {
        guard !isRefreshingChatData else { return }
        withAnimation(.snappy(duration: 0.18, extraBounce: 0.02)) {
            bottomPullDistance = bottomRefreshThreshold
            isRefreshingChatData = true
        }
        defer {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                isRefreshingChatData = false
                bottomPullDistance = 0
            }
        }
        await viewModel.refreshChatData(for: sessionID)
    }

    private var messageBottomPadding: CGFloat { 20 }

    private var readingModeBottomSpacerHeight: CGFloat {
        animatedReadingModeBottomSpacerHeight
    }

    private var targetReadingModeBottomSpacerHeight: CGFloat {
        guard isSendReadingModeActive, isReadingModeStreamActive else { return 0 }
        return max(0, listViewportHeight - composerOverlayHeight - 140)
    }

    private var isReadingModeStreamActive: Bool {
        pendingOutgoingSend != nil || isSessionBusy || preparingOutgoingMessageID != nil || animatingOutgoingMessageID != nil
    }

    private func updateReadingModeBottomSpacerHeight(animated: Bool) {
        let targetHeight = targetReadingModeBottomSpacerHeight
        guard abs(animatedReadingModeBottomSpacerHeight - targetHeight) > 0.5 else { return }

        if animated {
            withAnimation(.easeInOut(duration: 0.38)) {
                animatedReadingModeBottomSpacerHeight = targetHeight
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                animatedReadingModeBottomSpacerHeight = targetHeight
            }
        }
    }

    private func retireSendReadingModeAfterStream() {
        guard isSendReadingModeActive, !isReadingModeStreamActive else { return }

        isSendReadingModeActive = false
        readingModeScrollRequest = nil
        taskStore.autoScrollTask?.cancel()
    }

    private var displayedMessages: ArraySlice<OpenCodeMessageEnvelope> {
        viewModel.messages.suffix(visibleMessageCount)
    }

    private var displayedChatItems: [ChatDisplayItem] {
        makeDisplayItems(from: Array(displayedMessages))
    }

    private var hiddenMessageCount: Int {
        max(0, viewModel.messages.count - displayedMessages.count)
    }

    private var lastDisplayedMessageTextLength: Int {
        displayedMessages.last?.parts.reduce(0) { partialResult, part in
            partialResult + (part.text?.count ?? 0)
        } ?? 0
    }

    private var accessoryPresenceSignature: String {
        [
            viewModel.draftAttachments.map(\.id).joined(separator: "|"),
            viewModel.todos.filter { !$0.isComplete }.map(\.id).joined(separator: "|")
        ].joined(separator: "#")
    }

    private func dismissComposerOverlays() {
        withAnimation(opencodeSelectionAnimation) {
            composerAccessoryExpansion = .collapsed
            isComposerMenuOpen = false
        }
    }

    private var thinkingRowListItem: some View {
        ThinkingRow(animateEntry: isSendReadingModeActive)
            .transition(.identity)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private func chatRow(for item: ChatDisplayItem) -> some View {
        switch item {
        case let .message(message):
            messageRow(for: message)
        case let .compaction(compaction):
            compactionRow(for: compaction)
        }
    }

    private func messageRow(for message: OpenCodeMessageEnvelope) -> some View {
        MessageBubble(
            message: message,
            detailedMessage: viewModel.toolMessageDetails[message.id],
            currentSessionID: sessionID,
            isStreamingMessage: isStreamingMessage(message),
            animatesStreamingText: !isComposerInputFocused,
            reserveEntryFromComposer: message.id == preparingOutgoingMessageID,
            animateEntryFromComposer: message.id == animatingOutgoingMessageID,
            resolveTaskSessionID: { part, currentSessionID in
                viewModel.resolveTaskSessionID(from: part, currentSessionID: currentSessionID)
            }
        ) { part in
            selectedActivityDetail = ActivityDetail(message: message, part: part)
        } onOpenTaskSession: { taskSessionID in
            Task { await viewModel.openSession(sessionID: taskSessionID) }
        } onForkMessage: { forkMessage in
            Task { await viewModel.forkSelectedSession(from: forkMessage.id) }
        } onInspectDebugMessage: { debugMessage in
            selectedMessageDebugPayload = MessageDebugPayload(message: debugMessage)
        }
        .transition(message.id == readingModeScrollRequest?.messageID ? .identity : .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .id(message.id)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func compactionRow(for compaction: CompactionDisplayItem) -> some View {
        Button {
            selectedCompactionSummary = compaction.payload
        } label: {
            CompactionBoundaryRow(hasSummary: compaction.summaryText != nil)
        }
        .buttonStyle(.plain)
        .disabled(compaction.summaryText == nil)
        .id(compaction.id)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func makeDisplayItems(from messages: [OpenCodeMessageEnvelope]) -> [ChatDisplayItem] {
        var result: [ChatDisplayItem] = []

        for (index, message) in messages.enumerated() {
            if message.info.isCompactionSummary {
                continue
            }

            if message.parts.contains(where: \.isCompaction) {
                let summary = compactionSummary(for: message, at: index, in: messages)
                result.append(.compaction(CompactionDisplayItem(boundaryMessage: message, summaryMessage: summary)))
                continue
            }

            result.append(.message(message))
        }

        return result
    }

    private func compactionSummary(for boundary: OpenCodeMessageEnvelope, at index: Int, in messages: [OpenCodeMessageEnvelope]) -> OpenCodeMessageEnvelope? {
        if let paired = messages.first(where: { $0.info.isCompactionSummary && $0.info.parentID == boundary.id }) {
            return paired
        }

        return messages.dropFirst(index + 1).first { message in
            message.info.isCompactionSummary
        }
    }

    private func updateChatContentVisibility() {
        if isLoadingSelectedSession {
            contentRevealTask?.cancel()
            isChatContentVisible = !shouldAnimateInitialChatReveal
            chatContentOffsetY = shouldAnimateInitialChatReveal ? 14 : 0
            scheduleLoadingIndicatorReveal()
            return
        }

        if viewModel.messages.isEmpty {
            contentRevealTask?.cancel()
            loadingIndicatorTask?.cancel()
            shouldShowLoadingIndicator = false
            isChatContentVisible = true
            chatContentOffsetY = 0
            return
        }

        guard hasCompletedInitialHydrationSnap else {
            loadingIndicatorTask?.cancel()
            shouldShowLoadingIndicator = false
            isChatContentVisible = !shouldAnimateInitialChatReveal
            chatContentOffsetY = shouldAnimateInitialChatReveal ? 14 : 0
            return
        }

        guard shouldAnimateInitialChatReveal else {
            contentRevealTask?.cancel()
            loadingIndicatorTask?.cancel()
            shouldShowLoadingIndicator = false
            isChatContentVisible = true
            chatContentOffsetY = 0
            return
        }

        scheduleChatContentReveal(delayMS: 120)
    }

    private func scheduleChatContentReveal(delayMS: Int) {
        guard !isLoadingSelectedSession else { return }
        contentRevealTask?.cancel()
        loadingIndicatorTask?.cancel()
        shouldShowLoadingIndicator = false
        contentRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMS))
            guard !Task.isCancelled, !isLoadingSelectedSession else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                isChatContentVisible = true
                chatContentOffsetY = 0
            }
        }
    }

    private func scheduleLoadingIndicatorReveal() {
        loadingIndicatorTask?.cancel()
        shouldShowLoadingIndicator = false
        loadingIndicatorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, isLoadingSelectedSession, !isChatContentVisible else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                shouldShowLoadingIndicator = true
            }
        }
    }

    private func startOutgoingBubbleAnimationAndSend() {
        let draftText = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftAttachments = viewModel.draftAttachments
        let hasAttachments = !draftAttachments.isEmpty

        guard !draftText.isEmpty || hasAttachments else { return }
        viewModel.flushBufferedTranscript(reason: "send action")

        if !hasAttachments,
           (viewModel.shouldOpenForkSheet(forSlashInput: draftText) || viewModel.slashCommandInput(from: draftText).map({ viewModel.isForkClientCommand($0.command) }) == true) {
            viewModel.draftMessage = ""
            viewModel.clearPersistedMessageDraft(forSessionID: sessionID)
            viewModel.composerResetToken = UUID()
            viewModel.presentForkSessionSheet()
            return
        }

        guard viewModel.reserveUserPromptIfAllowed() else { return }

        OpenCodeHaptics.impact(.strong)
        viewModel.markChatBreadcrumb("send tapped", sessionID: sessionID)

        enterSendReadingMode()

        let shouldAnimateBubble = !draftText.isEmpty && !hasAttachments
        let preparedIDs = viewModel.insertOptimisticUserMessage(draftText, attachments: draftAttachments, in: liveSession, animated: false)
        preparingOutgoingMessageID = shouldAnimateBubble ? preparedIDs.messageID : nil
        readingModeScrollRequest = ReadingModeScrollRequest(messageID: preparedIDs.messageID)
        scheduleThinkingRowReveal(delayMS: shouldAnimateBubble ? 620 : 360)

        let pendingSend = PendingOutgoingSend(
            text: draftText,
            attachments: draftAttachments,
            shouldAnimateBubble: shouldAnimateBubble,
            messageID: preparedIDs.messageID,
            partID: preparedIDs.partID
        )

        pendingOutgoingSendTask?.cancel()
        pendingOutgoingSend = pendingSend
        updateReadingModeBottomSpacerHeight(animated: false)
        viewModel.draftMessage = ""
        viewModel.clearDraftAttachments()
        viewModel.clearPersistedMessageDraft(forSessionID: sessionID)
        viewModel.composerResetToken = UUID()

        if shouldAnimateBubble {
            scheduleOutgoingEntryAnimation(messageID: preparedIDs.messageID)

            pendingOutgoingSendTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled, viewModel.activeChatSessionID == sessionID else { return }

                pendingOutgoingSend = nil
                await viewModel.sendMessage(
                    pendingSend.text,
                    attachments: pendingSend.attachments,
                    in: liveSession,
                    userVisible: true,
                    messageID: pendingSend.messageID,
                    partID: pendingSend.partID,
                    appendOptimisticMessage: false,
                    meterPrompt: false
                )
            }
            return
        }

        pendingOutgoingSendTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, viewModel.activeChatSessionID == sessionID else { return }

            pendingOutgoingSend = nil
            await viewModel.sendMessage(
                pendingSend.text,
                attachments: pendingSend.attachments,
                in: liveSession,
                userVisible: true,
                messageID: pendingSend.messageID,
                partID: pendingSend.partID,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
        }
    }

    private func enterSendReadingMode() {
        shouldSnapOnNextMessage = false
        shouldDelayNextUserInsertScroll = false
        isSendReadingModeActive = true
        isComposerInputFocused = false
        viewModel.setComposerStreamingFocus(false)
        dismissKeyboardForReadingMode()
    }

    private func scheduleOutgoingEntryAnimation(messageID: String) {
        outgoingEntryResetTask?.cancel()
        animatingOutgoingMessageID = nil

        outgoingEntryResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(340))
            guard !Task.isCancelled else { return }
            animatingOutgoingMessageID = messageID

            try? await Task.sleep(for: .milliseconds(620))
            guard !Task.isCancelled else { return }
            animatingOutgoingMessageID = nil
            if preparingOutgoingMessageID == messageID {
                preparingOutgoingMessageID = nil
            }
        }
    }

    private func scheduleThinkingRowReveal(delayMS: Int) {
        thinkingRowRevealTask?.cancel()
        isThinkingRowRevealAllowed = false

        thinkingRowRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(delayMS))
            guard !Task.isCancelled else { return }
            isThinkingRowRevealAllowed = true
        }
    }

    private func stopComposerAction() {
        viewModel.flushBufferedTranscript(reason: "stop action")

        if let pendingSend = pendingOutgoingSend {
            pendingOutgoingSendTask?.cancel()
            pendingOutgoingSendTask = nil
            pendingOutgoingSend = nil
            if pendingSend.shouldAnimateBubble {
                if let messageID = pendingSend.messageID {
                    viewModel.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
                }
                outgoingEntryResetTask?.cancel()
                thinkingRowRevealTask?.cancel()
                isThinkingRowRevealAllowed = true
                preparingOutgoingMessageID = nil
                animatingOutgoingMessageID = nil
            }
            viewModel.draftMessage = pendingSend.text
            viewModel.addDraftAttachments(pendingSend.attachments)
            viewModel.persistCurrentMessageDraft(forSessionID: sessionID)
            return
        }

        Task { await viewModel.stopCurrentSession() }
    }

#if canImport(UIKit)
    private func dismissKeyboardForReadingMode() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func keyboardWillShow(from notification: Notification) -> Bool {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        return frame.minY < UIScreen.main.bounds.height
    }
#else
    private func dismissKeyboardForReadingMode() {}
#endif

    private var shouldShowThinking: Bool {
        if pendingOutgoingSend != nil {
            return isThinkingRowRevealAllowed
        }

        guard isSessionBusy else { return false }
        guard isThinkingRowRevealAllowed else { return false }
        guard let lastUserIndex = displayedMessages.lastIndex(where: { ($0.info.role ?? "").lowercased() == "user" }) else {
            return false
        }

        let assistantTextAfterUser = displayedMessages
            .suffix(from: displayedMessages.index(after: lastUserIndex))
            .contains { message in
                guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
                return message.parts.contains { part in
                    guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                    return !text.isEmpty
                }
            }

        return !assistantTextAfterUser
    }

    private func isStreamingMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
        guard isSessionBusy else { return false }
        guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
        return displayedMessages.last?.id == message.id
    }

    private func shouldAnimateListInsertion(_ message: OpenCodeMessageEnvelope) -> Bool {
        if message.id == readingModeScrollRequest?.messageID {
            return false
        }

        guard (message.info.role ?? "").lowercased() == "assistant" else { return true }
        return message.parts.contains { part in
            if part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }

            return !["", "step-start", "step-finish", "reasoning", "text"].contains(part.type)
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if viewModel.isUsingAppleIntelligence {
            ToolbarItem(placement: .opencodeLeading) {
                Button("Home") {
                    viewModel.leaveAppleIntelligenceSession()
                }
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    OpenCodeClipboard.copy(appleIntelligenceTranscript())
                    copiedTranscript = true
                } label: {
                    Image(systemName: copiedTranscript ? "checkmark.doc" : "doc.on.doc")
                }
                .accessibilityLabel(copiedTranscript ? "Copied Transcript" : "Copy Transcript")
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    viewModel.isShowingAppleIntelligenceInstructionsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Model Instructions")
            }
        } else {
            if isChildSession {
                ToolbarItem(placement: .opencodeLeading) {
                    if let parentSession {
                        Button("Back") {
                            Task { await viewModel.selectSession(parentSession) }
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(parentSessionTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(childSessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 220)
                }
            }

            ToolbarItem(placement: .opencodeTrailing) {
                AgentToolbarMenu(viewModel: viewModel, session: liveSession, glassNamespace: toolbarGlassNamespace)
            }

            #if !os(macOS)
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .topBarTrailing)
            }
            #endif

            ToolbarItem(placement: .opencodeTrailing) {
                ModelToolbarMenu(viewModel: viewModel, session: liveSession, glassNamespace: toolbarGlassNamespace)
            }
        }
    }

    private func appleIntelligenceTranscript() -> String {
        viewModel.messages.map { message in
            let role = (message.info.role ?? "assistant").lowercased()
            let text = message.parts
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            if !text.isEmpty {
                return "\(role):\n\(text)"
            }

            let partSummary = message.parts.map { part in
                let filename = part.filename ?? part.type
                return "[\(filename)]"
            }.joined(separator: " ")
            return "\(role):\n\(partSummary)"
        }.joined(separator: "\n\n")
    }
}

private struct CompactionBoundaryRow: View {
    let hasSummary: Bool

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)

            HStack(spacing: 8) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 12, weight: .semibold))
                Text(hasSummary ? "Session compacted" : "Compacting session")
                    .font(.caption.weight(.semibold))
                if hasSummary {
                    Text("View context")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(hasSummary ? "Session compacted. View context." : "Compacting session")
    }
}

private struct CompactionSummarySheet: View {
    let payload: CompactionSummaryPayload

    @State private var copiedSummary = false

    var body: some View {
        ScrollView {
            MarkdownMessageText(text: payload.summary, isUser: false, style: .standard, isStreaming: false, animatesStreamingText: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(payload.title)
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button(copiedSummary ? "Copied" : "Copy") {
                    OpenCodeClipboard.copy(payload.summary)
                    copiedSummary = true
                }
            }
        }
    }
}

private struct MessageDebugSheet: View {
    let payload: MessageDebugPayload

    @State private var copiedJSON = false

    var body: some View {
        ScrollView {
            Text(payload.json)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .navigationTitle("Message JSON")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button(copiedJSON ? "Copied" : "Copy") {
                    OpenCodeClipboard.copy(payload.json)
                    copiedJSON = true
                }
            }
        }
    }
}

private struct AppleIntelligenceInstructionsSheet: View {
    @Binding var userInstructions: String
    @Binding var systemInstructions: String
    @Binding var selectedTab: AppleIntelligenceInstructionTab

    let defaultUserInstructions: String
    let defaultSystemInstructions: String
    let onDone: () -> Void

    var body: some View {
        Form {
            Picker("Prompt", selection: $selectedTab) {
                ForEach(AppleIntelligenceInstructionTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Section(selectedTab.title) {
                TextEditor(text: activeBinding)
                    .frame(minHeight: 280)
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                Text("These prompts apply to the second execution round after intent inference.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear Current Tab", role: .destructive) {
                    activeBinding.wrappedValue = ""
                }

                Button("Reset Current Tab") {
                    switch selectedTab {
                    case .user:
                        userInstructions = defaultUserInstructions
                    case .system:
                        systemInstructions = defaultSystemInstructions
                    }
                }
            }
        }
        .navigationTitle("Model Instructions")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeLeading) {
                Button("Done") {
                    onDone()
                }
            }
        }
        .presentationDetents([.large])
    }

    private var activeBinding: Binding<String> {
        switch selectedTab {
        case .user:
            return $userInstructions
        case .system:
            return $systemInstructions
        }
    }
}

private struct ChatSkeletonRow: View {
    let isLeading: Bool

    var body: some View {
        HStack {
            if isLeading {
                bubble
                Spacer(minLength: 36)
            } else {
                Spacer(minLength: 36)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.9))
                .frame(width: isLeading ? 180 : 150, height: 12)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.9))
                .frame(width: isLeading ? 220 : 190, height: 12)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.7))
                .frame(width: isLeading ? 140 : 110, height: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .redacted(reason: .placeholder)
    }
}

private struct ChatBottomAnchorFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct ComposerOverlayHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private extension View {
    @ViewBuilder
    func chatScrollBottomTracking(_ isAtBottom: Binding<Bool>) -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 80
            } action: { _, newValue in
                guard isAtBottom.wrappedValue != newValue else { return }
                isAtBottom.wrappedValue = newValue
            }
        } else {
            self
        }
#else
            self
#endif
    }
}
