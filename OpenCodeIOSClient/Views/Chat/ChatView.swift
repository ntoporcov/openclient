import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatView: View {
    @ObservedObject var viewModel: AppViewModel
    let session: OpenCodeSession

    @Namespace private var toolbarGlassNamespace
    @State private var keyboardHeight: CGFloat = 0
    @State private var copiedDebugLog = false
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var showingTodoInspector = false
    @State private var visibleMessageCount = 80
    @State private var hasLoadedInitialWindow = false
    @State private var hasSnappedInitially = false
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var keyboardScrollTask: Task<Void, Never>?

    private let messageWindowSize = 10

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if hiddenMessageCount > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    visibleMessageCount = min(viewModel.messages.count, visibleMessageCount + messageWindowSize)
                                }
                            } label: {
                                Text("View older messages (\(hiddenMessageCount))")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.blue)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 4)
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
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        }

                        if shouldShowThinking {
                            ThinkingRow()
                                .id("thinking-row")
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, messageBottomPadding)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: .systemGroupedBackground))
                .accessibilityIdentifier("chat.scroll")
                .safeAreaInset(edge: .bottom) {
                    composerStack
                }
                .onAppear {
                    if !hasLoadedInitialWindow {
                        visibleMessageCount = min(viewModel.messages.count, messageWindowSize)
                        hasLoadedInitialWindow = true
                    }
                    scrollToBottom(with: proxy, animated: false)
                }
                .onChange(of: viewModel.messages.count) { _, count in
                    if !hasLoadedInitialWindow {
                        visibleMessageCount = min(count, messageWindowSize)
                        return
                    }

                    visibleMessageCount = min(count, max(visibleMessageCount, messageWindowSize))
                }
                .onChange(of: visibleMessageCount) { _, _ in
                    if !hasSnappedInitially {
                        scrollToBottom(with: proxy, animated: false)
                        hasSnappedInitially = true
                    }
                }
                .onChange(of: displayedMessages.last?.id) { _, _ in
                    scrollToBottom(with: proxy, animated: hasSnappedInitially)
                }
                .onChange(of: messageContentVersion) { _, _ in
                    scrollToBottom(with: proxy, animated: hasSnappedInitially)
                }
                .onChange(of: shouldShowThinking) { _, _ in
                    scrollToBottom(with: proxy, animated: hasSnappedInitially)
                }
                .onChange(of: keyboardHeight) { _, newValue in
                    keyboardScrollTask?.cancel()
                    guard newValue > 0 else { return }

                    scrollToBottom(with: proxy, animated: true)
                    keyboardScrollTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        guard !Task.isCancelled else { return }
                        scrollToBottom(with: proxy, animated: false)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    keyboardHeight = keyboardHeight(from: notification, geometry: geometry)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardScrollTask?.cancel()
                    keyboardHeight = 0
                }
            }
        }
        .navigationTitle(session.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private var composerStack: some View {
        VStack(spacing: 6) {
            if viewModel.todos.contains(where: { !$0.isComplete }) {
                TodoStrip(todos: viewModel.todos) {
                    showingTodoInspector = true
                }
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
                MessageComposer(
                    text: $viewModel.draftMessage,
                    isSending: viewModel.isLoading,
                    onSend: {
                        Task { await viewModel.sendCurrentMessage() }
                    }
                )
                .id(viewModel.composerResetToken)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.clear)
            }
        }
    }

    private func scrollToBottom(with proxy: ScrollViewProxy, animated: Bool) {
        let action = {
            if shouldShowThinking {
                proxy.scrollTo("thinking-row", anchor: .bottom)
            } else if let lastMessageID = displayedMessages.last?.id {
                proxy.scrollTo(lastMessageID, anchor: .bottom)
            }
        }

        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    private func keyboardHeight(from notification: Notification, geometry: GeometryProxy) -> CGFloat {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return 0
        }

        let overlap = geometry.frame(in: .global).maxY - value.minY
        return max(0, overlap)
    }

    private var messageBottomPadding: CGFloat { 96 }

    private var messageContentVersion: String {
        displayedMessages.map { message in
            let text = message.parts.compactMap { $0.text }.joined(separator: "|")
            return "\(message.id):\(text)"
        }.joined(separator: "||")
    }

    private var displayedMessages: ArraySlice<OpenCodeMessageEnvelope> {
        viewModel.messages.suffix(visibleMessageCount)
    }

    private var hiddenMessageCount: Int {
        max(0, viewModel.messages.count - displayedMessages.count)
    }

    private var shouldShowThinking: Bool {
        guard viewModel.sessionStatuses[session.id] == "busy" else { return false }
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
        guard viewModel.sessionStatuses[session.id] == "busy" else { return false }
        guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
        return displayedMessages.last?.id == message.id
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            AgentToolbarMenu(viewModel: viewModel, session: session, glassNamespace: toolbarGlassNamespace)
        }

        if #available(iOS 26.0, *) {
            ToolbarSpacer(.flexible, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            ModelToolbarMenu(viewModel: viewModel, session: session, glassNamespace: toolbarGlassNamespace)
        }
    }
}
