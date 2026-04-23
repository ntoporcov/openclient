import SwiftUI

#if DEBUG
private struct AgentToolbarMenuPreviewHost: View {
    @Namespace private var namespace

    var body: some View {
        AgentToolbarMenu(
            viewModel: AppViewModel.preview(),
            session: OpenCodePreviewData.primarySession,
            glassNamespace: namespace
        )
        .padding()
    }
}

private struct ModelToolbarMenuPreviewHost: View {
    @Namespace private var namespace

    var body: some View {
        ModelToolbarMenu(
            viewModel: AppViewModel.preview(),
            session: OpenCodePreviewData.primarySession,
            glassNamespace: namespace
        )
        .padding()
    }
}

private struct QuestionPanelPreviewHost: View {
    @State private var answers: [String: Set<String>] = [:]
    @State private var customAnswers: [String: String] = [:]

    var body: some View {
        QuestionPanel(
            requests: [OpenCodePreviewData.questionRequest],
            answers: $answers,
            customAnswers: $customAnswers,
            onDismiss: { _ in },
            onSubmit: { _, _ in }
        )
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
    }
}

private struct MessageComposerPreviewHost: View {
    @State private var text = "Can you tighten the vertical rhythm in this screen?"
    @State private var isAccessoryMenuOpen = false

    var body: some View {
        MessageComposer(text: $text, isAccessoryMenuOpen: $isAccessoryMenuOpen, commands: OpenCodePreviewData.commands, attachmentCount: OpenCodePreviewData.composerAttachments.count, isBusy: false, onInputFrameChange: { _ in }, onSend: {}, onStop: {}, onSelectCommand: { _ in }, onAddAttachments: { _ in })
            .padding()
            .background(OpenCodePlatformColor.groupedBackground)
    }
}

#Preview("Chat View") {
    NavigationStack {
        ChatView(viewModel: AppViewModel.preview(), sessionID: OpenCodePreviewData.primarySession.id)
    }
}

#Preview("Agent Toolbar Menu") {
    AgentToolbarMenuPreviewHost()
}

#Preview("Model Toolbar Menu") {
    ModelToolbarMenuPreviewHost()
}

#Preview("Thinking Row") {
    ThinkingRow()
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Todo Card") {
    TodoCard(todo: OpenCodePreviewData.todoActive)
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Todo Strip") {
    TodoStrip(todos: OpenCodePreviewData.todos, onTapCard: {})
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Attachment Strip") {
    AttachmentStrip(attachments: OpenCodePreviewData.composerAttachments, allowsRemoval: true, onTapAttachment: { _ in }, onRemoveAttachment: { _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Todo Inspector") {
    NavigationStack {
        TodoInspectorView(viewModel: AppViewModel.preview())
    }
}

#Preview("Permission Card") {
    PermissionCard(permission: OpenCodePreviewData.permission, onDismiss: { _ in }, onRespond: { _, _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Permission Stack") {
    PermissionActionStack(permissions: [OpenCodePreviewData.permission], onDismiss: { _ in }, onRespond: { _, _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Question Panel") {
    QuestionPanelPreviewHost()
}

#Preview("Markdown Message") {
    MarkdownMessageText(
        text: "Added **previews** for the sidebar, session list, and chat building blocks.",
        isUser: false,
        style: .standard
    )
    .padding()
}

#Preview("Reasoning Block") {
    ReasoningBlock(
        text: "I want the previews to stay fast and local, so they reuse sample state instead of making API calls.",
        isExpanded: true,
        isRunning: true,
        onToggle: {}
    )
    .padding()
    .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Activity Row") {
    ActivityRow(style: ActivityStyle(title: "Build for simulator", subtitle: "Completed", icon: "terminal.fill", tint: .green, isRunning: false))
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Detail Text") {
    DetailTextBlock(text: "xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient build")
        .padding()
}

#Preview("Activity Detail") {
    NavigationStack {
        ActivityDetailView(
            viewModel: AppViewModel.preview(),
            detail: ActivityDetail(message: OpenCodePreviewData.assistantMessage, part: OpenCodePreviewData.assistantMessage.parts[1])
        )
    }
}

#Preview("User Message Bubble") {
    MessageBubble(message: OpenCodePreviewData.userMessage, detailedMessage: nil, isStreamingMessage: false, onSelectPart: { _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Assistant Message Bubble") {
    MessageBubble(message: OpenCodePreviewData.assistantMessage, detailedMessage: OpenCodePreviewData.assistantMessage, isStreamingMessage: true, onSelectPart: { _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Message Composer") {
    MessageComposerPreviewHost()
}
#endif
