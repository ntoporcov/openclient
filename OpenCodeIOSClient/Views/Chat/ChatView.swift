import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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

private struct PendingOutgoingSend {
    let text: String
    let attachments: [OpenCodeComposerAttachment]
    let shouldAnimateBubble: Bool
    let messageID: String?
    let partID: String?
}

struct ChatView: View {
    @ObservedObject var viewModel: AppViewModel
    let sessionID: String

    @Namespace private var toolbarGlassNamespace
    @State private var copiedDebugLog = false
    @State private var selectedMessageDebugPayload: MessageDebugPayload?
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var showingTodoInspector = false
    @State private var visibleMessageCount = 80
    @State private var hasLoadedInitialWindow = false
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var shouldSnapOnNextMessage = false
    @State private var shouldDelayNextUserInsertScroll = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var isComposerMenuOpen = false
    @State private var copiedTranscript = false
    @State private var pendingOutgoingSend: PendingOutgoingSend?
    @State private var pendingOutgoingSendTask: Task<Void, Never>?
    @State private var outgoingEntryResetTask: Task<Void, Never>?
    @State private var animatingOutgoingMessageID: String?
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
        displayedMessages
            .filter(shouldAnimateListInsertion)
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

                        ForEach(displayedMessages) { message in
                            messageRow(for: message)
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
                        guard isScrollGeometryAtBottom else { return }
                        scheduleScrollToBottom(with: proxy, delayMS: 20)
                    }
                    .onChange(of: composerOverlayHeight) { oldHeight, newHeight in
                        guard newHeight > 0, abs(newHeight - oldHeight) > 1 else { return }
                        if needsInitialComposerHeightSnap, !viewModel.messages.isEmpty {
                            needsInitialComposerHeightSnap = false
                            scheduleComposerAffordanceFollow(with: proxy, delayMS: 60)
                            return
                        }
                        guard shouldFollowComposerAffordanceChange || isScrollGeometryAtBottom else { return }
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

                        if shouldSnapOnNextMessage || isScrollGeometryAtBottom {
                            shouldSnapOnNextMessage = false
                            let delay = shouldDelayNextUserInsertScroll ? 180 : 10
                            shouldDelayNextUserInsertScroll = false
                            scheduleScrollToBottom(with: proxy, delayMS: delay)
                        }

                        updateChatContentVisibility()
                    }
                    .onChange(of: streamingFollowSignature) { _, _ in
                        guard hasLoadedInitialWindow, isScrollGeometryAtBottom else { return }
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onChange(of: isLoadingSelectedSession) { _, _ in
                        updateChatContentVisibility()
                    }
                    .onPreferenceChange(ChatBottomAnchorFramePreferenceKey.self) { frame in
                        bottomAnchorFrame = frame
                    }
#if canImport(UIKit)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                        guard keyboardWillShow(from: notification), isScrollGeometryAtBottom else { return }
                        scheduleComposerAffordanceFollow(with: proxy, delayMS: 20)
                    }
#endif
                }
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
            contentRevealTask?.cancel()
            loadingIndicatorTask?.cancel()
            pendingOutgoingSendTask?.cancel()
            outgoingEntryResetTask?.cancel()
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

    private func activeMessageComposer(isBusy: Bool) -> some View {
        MessageComposer(
            text: draftTextBinding,
            isAccessoryMenuOpen: $isComposerMenuOpen,
            commands: viewModel.commands,
            attachmentCount: viewModel.draftAttachments.count,
            isBusy: isBusy,
            canFork: !viewModel.forkableMessages.isEmpty,
            onInputFrameChange: { _ in },
            onSend: {
                startOutgoingBubbleAnimationAndSend()
            },
            onStop: {
                stopComposerAction()
            },
            onSelectCommand: { command in
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
            .frame(height: messageBottomPadding + bottomRefreshIndicatorHeight * bottomPullProgress)
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
                composerOverlayHeight = height
            }
    }

    private func scheduleScrollToBottom(with proxy: ScrollViewProxy, delayMS: Int = 10) {
        scheduleScrollToBottom(with: proxy, delayMS: delayMS, animated: false)
    }

    private func scheduleScrollToBottom(with proxy: ScrollViewProxy, delayMS: Int = 10, animated: Bool) {
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor in
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

    private var displayedMessages: ArraySlice<OpenCodeMessageEnvelope> {
        viewModel.messages.suffix(visibleMessageCount)
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
        ThinkingRow()
            .transition(.identity)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func messageRow(for message: OpenCodeMessageEnvelope) -> some View {
        MessageBubble(
            message: message,
            detailedMessage: viewModel.toolMessageDetails[message.id],
            currentSessionID: sessionID,
            isStreamingMessage: isStreamingMessage(message),
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
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .id(message.id)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
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

        shouldSnapOnNextMessage = true
        shouldDelayNextUserInsertScroll = true

        let shouldAnimateBubble = !draftText.isEmpty && !hasAttachments
        let preparedIDs = shouldAnimateBubble
            ? viewModel.insertOptimisticUserMessage(draftText, attachments: draftAttachments, in: liveSession)
            : nil

        let pendingSend = PendingOutgoingSend(
            text: draftText,
            attachments: draftAttachments,
            shouldAnimateBubble: shouldAnimateBubble,
            messageID: preparedIDs?.messageID,
            partID: preparedIDs?.partID
        )

        pendingOutgoingSendTask?.cancel()
        pendingOutgoingSend = pendingSend
        viewModel.draftMessage = ""
        viewModel.clearDraftAttachments()
        viewModel.clearPersistedMessageDraft(forSessionID: sessionID)
        viewModel.composerResetToken = UUID()

        if shouldAnimateBubble {
            animatingOutgoingMessageID = preparedIDs?.messageID
            outgoingEntryResetTask?.cancel()
            outgoingEntryResetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled else { return }
                animatingOutgoingMessageID = nil
            }

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

            viewModel.draftMessage = pendingSend.text
            viewModel.addDraftAttachments(pendingSend.attachments)
            viewModel.persistCurrentMessageDraft(forSessionID: sessionID)
            pendingOutgoingSend = nil
            await viewModel.sendCurrentMessage(meterPrompt: false)
        }
    }

    private func stopComposerAction() {
        if let pendingSend = pendingOutgoingSend {
            pendingOutgoingSendTask?.cancel()
            pendingOutgoingSendTask = nil
            pendingOutgoingSend = nil
            if pendingSend.shouldAnimateBubble {
                if let messageID = pendingSend.messageID {
                    viewModel.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
                }
                outgoingEntryResetTask?.cancel()
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
    private func keyboardWillShow(from notification: Notification) -> Bool {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return false }
        return frame.minY < UIScreen.main.bounds.height
    }
#endif

    private var shouldShowThinking: Bool {
        if pendingOutgoingSend != nil {
            return true
        }

        guard isSessionBusy else { return false }
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
