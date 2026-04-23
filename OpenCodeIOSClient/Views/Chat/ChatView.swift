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

struct ChatView: View {
    @ObservedObject var viewModel: AppViewModel
    let sessionID: String

    @Namespace private var toolbarGlassNamespace
    @State private var copiedDebugLog = false
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var showingTodoInspector = false
    @State private var visibleMessageCount = 80
    @State private var hasLoadedInitialWindow = false
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var shouldSnapOnNextMessage = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var isComposerMenuOpen = false
    @State private var copiedTranscript = false
    @State private var outgoingBubbleText: String?
    @State private var outgoingBubbleProgress: CGFloat = 0
    @State private var outgoingBubbleCleanupTask: Task<Void, Never>?
    @State private var composerInputFrame: CGRect = .zero
    @State private var outgoingBubbleStartFrame: CGRect = .zero
    @State private var listViewportHeight: CGFloat = 0
    @State private var bottomAnchorFrame: CGRect = .zero
    @State private var immediateScrollToken = 0
    @State private var needsInitialBottomSnap = true
    @State private var keyboardHeight: CGFloat = 0
    @State private var shouldAdjustForKeyboard = false
    @State private var hasCompletedInitialHydrationSnap = false
    @State private var keyboardAnimationDuration: Double = 0.25
    @State private var composerOverlayHeight: CGFloat = 0
    @State private var shouldFollowComposerAffordanceChange = false
    @State private var affordanceScrollTask: Task<Void, Never>?
    @State private var needsInitialComposerHeightSnap = true

    @State private var selectedInstructionTab: AppleIntelligenceInstructionTab = .user

    private let messageWindowSize = 10
    private var todoIDs: String {
        viewModel.todos.map { $0.id }.joined(separator: "|")
    }

    private var permissionIDs: String {
        viewModel.selectedSessionPermissions.map { $0.id }.joined(separator: "|")
    }

    private var questionIDs: String {
        viewModel.selectedSessionQuestions.map { $0.id }.joined(separator: "|")
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

    private var streamingFollowSignature: String {
        [
            displayedMessages.last?.id ?? "none",
            String(displayedMessages.last?.parts.count ?? 0),
            String(lastDisplayedMessageTextLength),
            shouldShowThinking ? "thinking" : "idle"
        ].joined(separator: "|")
    }

    private var isNearBottom: Bool {
        guard listViewportHeight > 0, bottomAnchorFrame != .zero else { return true }
        return abs(bottomAnchorFrame.minY - listViewportHeight) <= 140
    }

    private var effectiveBottomPadding: CGFloat {
        max(messageBottomPadding, composerOverlayHeight + 12) + (shouldAdjustForKeyboard ? keyboardHeight : 0)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
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
                            MessageBubble(
                                message: message,
                                detailedMessage: viewModel.toolMessageDetails[message.id],
                                isStreamingMessage: isStreamingMessage(message)
                            ) { part in
                                selectedActivityDetail = ActivityDetail(message: message, part: part)
                            }
                            .id(message.id)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }

                        if shouldShowThinking {
                            ThinkingRow()
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }

                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: max(1, effectiveBottomPadding))
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
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .opencodeInteractiveKeyboardDismiss()
                    .background(OpenCodePlatformColor.groupedBackground)
                    .accessibilityIdentifier("chat.scroll")
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .onAppear {
                        listViewportHeight = geometry.size.height
                        needsInitialBottomSnap = true
                        needsInitialComposerHeightSnap = true
                        hasCompletedInitialHydrationSnap = false
                        if !hasLoadedInitialWindow {
                            visibleMessageCount = min(viewModel.messages.count, messageWindowSize)
                            hasLoadedInitialWindow = true
                        }
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onChange(of: bottomAnchorFrame) { _, frame in
                        guard needsInitialBottomSnap, frame != .zero else { return }
                        needsInitialBottomSnap = false
                        scheduleScrollToBottom(with: proxy, delayMS: 80)
                    }
                    .onChange(of: geometry.size.height) { _, height in
                        listViewportHeight = height
                    }
                    .onChange(of: keyboardHeight) { oldHeight, newHeight in
                        if newHeight <= 0 {
                            shouldAdjustForKeyboard = false
                            return
                        }

                        if oldHeight <= 0 {
                            shouldAdjustForKeyboard = isNearBottom
                        }

                        guard newHeight > oldHeight, shouldAdjustForKeyboard else { return }
                        scheduleScrollToBottom(with: proxy, delayMS: 40, animated: true)
                    }
                    .onChange(of: immediateScrollToken) { _, _ in
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onChange(of: composerOverlayHeight) { oldHeight, newHeight in
                        guard newHeight > 0, abs(newHeight - oldHeight) > 1 else { return }
                        if needsInitialComposerHeightSnap, !viewModel.messages.isEmpty {
                            needsInitialComposerHeightSnap = false
                            scheduleScrollToBottom(with: proxy, delayMS: 60)
                            return
                        }
                        guard shouldFollowComposerAffordanceChange || isNearBottom else { return }
                        shouldFollowComposerAffordanceChange = false
                        affordanceScrollTask?.cancel()
                        affordanceScrollTask = Task { @MainActor in
                            scheduleScrollToBottom(with: proxy, delayMS: 20)
                            try? await Task.sleep(for: .milliseconds(140))
                            guard !Task.isCancelled else { return }
                            scheduleScrollToBottom(with: proxy, delayMS: 0)
                        }
                    }
                    .onChange(of: viewModel.messages.count) { oldCount, count in
                        if !hasLoadedInitialWindow {
                            visibleMessageCount = min(count, messageWindowSize)
                            return
                        }

                        visibleMessageCount = min(count, max(visibleMessageCount, messageWindowSize))

                        if count > 0, !hasCompletedInitialHydrationSnap {
                            hasCompletedInitialHydrationSnap = true
                            scheduleScrollToBottom(with: proxy, delayMS: 120)
                        }

                        if count > oldCount, outgoingBubbleText != nil {
                            settleOutgoingBubbleAfterRowInsert()
                        }

                        guard count > oldCount else { return }

                        if shouldSnapOnNextMessage || isNearBottom {
                            shouldSnapOnNextMessage = false
                            scheduleScrollToBottom(with: proxy)
                        }
                    }
                    .onChange(of: streamingFollowSignature) { _, _ in
                        guard hasLoadedInitialWindow, isNearBottom else { return }
                        scheduleScrollToBottom(with: proxy)
                    }
                    .onPreferenceChange(ChatBottomAnchorFramePreferenceKey.self) { frame in
                        bottomAnchorFrame = frame
                    }
#if canImport(UIKit)
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                        keyboardHeight = keyboardHeight(from: notification, containerFrame: geometry.frame(in: .global))
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                        keyboardHeight = 0
                        shouldAdjustForKeyboard = false
                    }
#endif
                }

                composerOverlay
            }
        }
        .coordinateSpace(name: "chat-view-space")
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .navigationTitle(liveSession.title ?? "Session")
        .opencodeInlineNavigationTitle()
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
                    enabledToolIDs: $viewModel.appleIntelligenceEnabledToolIDs,
                    selectedTab: $selectedInstructionTab,
                    defaultUserInstructions: viewModel.defaultAppleIntelligenceUserInstructions,
                    defaultSystemInstructions: viewModel.defaultAppleIntelligenceSystemInstructions,
                    onDone: {
                        viewModel.isShowingAppleIntelligenceInstructionsSheet = false
                    }
                )
            }
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
        .overlay(alignment: .topLeading) {
            GeometryReader { geometry in
                if let outgoingBubbleText, outgoingBubbleStartFrame != .zero {
                    let frame = interpolatedOutgoingBubbleFrame(in: geometry.size, text: outgoingBubbleText)

                    OutgoingSendBubble(text: outgoingBubbleText, frame: frame)
                        .position(x: frame.midX, y: frame.midY)
                        .opacity(1 - outgoingBubbleProgress)
                        .allowsHitTesting(false)
                }
            }
        }
        .onChange(of: accessoryPresenceSignature) { _, _ in
            shouldFollowComposerAffordanceChange = isNearBottom
            if viewModel.draftAttachments.isEmpty || viewModel.todos.allSatisfy(\.isComplete) {
                composerAccessoryExpansion = .collapsed
            }
        }
        .onChange(of: viewModel.messages.count) { _, _ in
            copiedTranscript = false
        }
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

            if !viewModel.selectedSessionPermissions.isEmpty {
                PermissionActionStack(
                    permissions: viewModel.selectedSessionPermissions,
                    onDismiss: { permission in
                        viewModel.dismissPermission(permission)
                    },
                    onRespond: { permission, response in
                        Task { await viewModel.respondToPermission(permission, response: response) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if !viewModel.selectedSessionQuestions.isEmpty {
                QuestionPanel(
                    requests: viewModel.selectedSessionQuestions,
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
                let isBusy = viewModel.sessionStatuses[liveSession.id] == "busy"
                MessageComposer(
                    text: $viewModel.draftMessage,
                    isAccessoryMenuOpen: $isComposerMenuOpen,
                    commands: viewModel.commands,
                    attachmentCount: viewModel.draftAttachments.count,
                    isBusy: isBusy,
                    onInputFrameChange: { frame in
                        composerInputFrame = frame
                    },
                    onSend: {
                        startOutgoingBubbleAnimationAndSend()
                    },
                    onStop: {
                        Task { await viewModel.stopCurrentSession() }
                    },
                    onSelectCommand: { command in
                        shouldSnapOnNextMessage = true
                        Task { await viewModel.sendCommand(command, sessionID: sessionID, userVisible: true) }
                    },
                    onAddAttachments: { attachments in
                        viewModel.addDraftAttachments(attachments)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.clear)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var composerOverlay: some View {
        measuredComposerStack
            .padding(.bottom, keyboardHeight)
            .background(Color.clear)
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
            withAnimation(.easeOut(duration: keyboardAnimationDuration)) {
                proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("chat-bottom-anchor", anchor: .bottom)
        }
    }

    private var messageBottomPadding: CGFloat { 96 }

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

    private func startOutgoingBubbleAnimationAndSend() {
        let draftText = viewModel.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !viewModel.draftAttachments.isEmpty

        guard !draftText.isEmpty || hasAttachments else { return }

        shouldSnapOnNextMessage = true
        immediateScrollToken += 1

        if !draftText.isEmpty && !hasAttachments {
            outgoingBubbleText = draftText
            outgoingBubbleProgress = 0
            outgoingBubbleStartFrame = composerInputFrame == .zero
                ? CGRect(x: 40, y: 600, width: 240, height: 48)
                : composerInputFrame

            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                outgoingBubbleProgress = 1
            }

            outgoingBubbleCleanupTask?.cancel()
            outgoingBubbleCleanupTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                outgoingBubbleText = nil
                outgoingBubbleProgress = 0
                outgoingBubbleStartFrame = .zero
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                await viewModel.sendCurrentMessage()
            }
            return
        }

        Task { await viewModel.sendCurrentMessage() }
    }

    private func settleOutgoingBubbleAfterRowInsert() {
        outgoingBubbleCleanupTask?.cancel()
        outgoingBubbleCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            outgoingBubbleText = nil
            outgoingBubbleProgress = 0
            outgoingBubbleStartFrame = .zero
        }
    }

    private func interpolatedOutgoingBubbleFrame(in containerSize: CGSize, text: String) -> CGRect {
        let start = outgoingBubbleStartFrame
        let end = estimatedOutgoingBubbleTargetFrame(in: containerSize, text: text)

        return CGRect(
            x: lerp(start.minX, end.minX, progress: outgoingBubbleProgress),
            y: lerp(start.minY, end.minY, progress: outgoingBubbleProgress),
            width: lerp(start.width, end.width, progress: outgoingBubbleProgress),
            height: lerp(start.height, end.height, progress: outgoingBubbleProgress)
        )
    }

    private func estimatedOutgoingBubbleTargetFrame(in containerSize: CGSize, text: String) -> CGRect {
        let maxWidth = min(320, containerSize.width - 32)
        let estimatedWidth = min(maxWidth, max(110, min(maxWidth, 34 + (CGFloat(text.count) * 7.0))))
        let estimatedLines = max(1, min(4, ceil((CGFloat(text.count) * 7.0) / max(estimatedWidth - 28, 80))))
        let estimatedHeight = 22 + (estimatedLines * 22)
        let x = containerSize.width - 16 - estimatedWidth
        let y = max(12, outgoingBubbleStartFrame.minY - 104)

        return CGRect(x: x, y: y, width: estimatedWidth, height: estimatedHeight)
    }

    private func lerp(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
        start + ((end - start) * progress)
    }

#if canImport(UIKit)
    private func keyboardHeight(from notification: Notification, containerFrame: CGRect) -> CGFloat {
        if let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
            keyboardAnimationDuration = duration
        }

        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }

        return max(0, containerFrame.maxY - value.minY)
    }
#endif

    private var shouldShowThinking: Bool {
        guard viewModel.sessionStatuses[liveSession.id] == "busy" else { return false }
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
        guard viewModel.sessionStatuses[liveSession.id] == "busy" else { return false }
        guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
        return displayedMessages.last?.id == message.id
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

private struct AppleIntelligenceInstructionsSheet: View {
    @Binding var userInstructions: String
    @Binding var systemInstructions: String
    @Binding var enabledToolIDs: Set<String>
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

            Section("Tools For Next Turn") {
                ForEach(AppleIntelligenceTool.allCases) { tool in
                    Toggle(isOn: binding(for: tool)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.title)
                            Text(tool.summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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

    private func binding(for tool: AppleIntelligenceTool) -> Binding<Bool> {
        Binding(
            get: { enabledToolIDs.contains(tool.id) },
            set: { isEnabled in
                if isEnabled {
                    enabledToolIDs.insert(tool.id)
                } else {
                    enabledToolIDs.remove(tool.id)
                }
            }
        )
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

private struct OutgoingSendBubble: View {
    let text: String
    let frame: CGRect

    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
}
