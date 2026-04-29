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
        MessageComposer(text: $text, isAccessoryMenuOpen: $isAccessoryMenuOpen, commands: OpenCodePreviewData.commands, attachmentCount: OpenCodePreviewData.composerAttachments.count, isBusy: false, canFork: true, onInputFrameChange: { _ in }, onFocusChange: { _ in }, onSend: {}, onStop: {}, onSelectCommand: { _ in }, onCompact: {}, onOpenFork: {}, onAddAttachments: { _ in })
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
        text: "# Release Notes\nAdded **previews** for the sidebar, session list, and chat building blocks.\n\n> Block quotes now render as distinct quoted panels.\n> They preserve *inline* formatting across multiple quoted lines.\n\n## Markdown Coverage\nHeadings now render as block elements while preserving *inline* formatting.\n\n- Unordered list item with **bold** text\n- Another bullet item\n\n1. Ordered item\n2. Ordered item with *emphasis*\n\n- [x] Completed checkbox\n- [ ] Pending checkbox\n\n| Feature | Status | Notes |\n| --- | --- | --- |\n| Headings | Done | H1-H3 |\n| Tables | Added | Inline **markdown** works |\n\n```js\nconst foo = 0\nconst message = `value: ${foo}`\n```\n\n```diff\n- let oldValue = false\n+ let newValue = true\n```\n\n### Next\nAdd links.",
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
    ActivityRow(style: ActivityStyle(title: "Shell", subtitle: "Build for simulator", icon: "terminal.fill", tint: .green, isRunning: false, showsDisclosure: true, shimmerTitle: false))
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
            MessageBubble(message: OpenCodePreviewData.userMessage, detailedMessage: nil, currentSessionID: OpenCodePreviewData.primarySession.id, isStreamingMessage: false, animatesStreamingText: true, reserveEntryFromComposer: false, animateEntryFromComposer: false, resolveTaskSessionID: { _, _ in nil }, onSelectPart: { _ in }, onOpenTaskSession: { _ in }, onForkMessage: { _ in }, onInspectDebugMessage: { _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Assistant Message Bubble") {
            MessageBubble(message: OpenCodePreviewData.assistantMessage, detailedMessage: OpenCodePreviewData.assistantMessage, currentSessionID: OpenCodePreviewData.primarySession.id, isStreamingMessage: true, animatesStreamingText: true, reserveEntryFromComposer: false, animateEntryFromComposer: false, resolveTaskSessionID: { _, _ in OpenCodePreviewData.secondarySession.id }, onSelectPart: { _ in }, onOpenTaskSession: { _ in }, onForkMessage: { _ in }, onInspectDebugMessage: { _ in })
        .padding()
        .background(OpenCodePlatformColor.groupedBackground)
}

#Preview("Message Composer") {
    MessageComposerPreviewHost()
}
#endif
