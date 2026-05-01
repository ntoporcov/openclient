import SwiftUI

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct MessageBubble: View {
    let message: OpenCodeMessageEnvelope
    let detailedMessage: OpenCodeMessageEnvelope?
    let currentSessionID: String?
    let isStreamingMessage: Bool
    let animatesStreamingText: Bool
    let reserveEntryFromComposer: Bool
    let animateEntryFromComposer: Bool
    let resolveTaskSessionID: (OpenCodePart, String) -> String?
    let onSelectPart: (OpenCodePart) -> Void
    let onOpenTaskSession: (String) -> Void
    let onForkMessage: (OpenCodeMessageEnvelope) -> Void
    let onInspectDebugMessage: (OpenCodeMessageEnvelope) -> Void

    @State private var expandedReasoningPartIDs: Set<String> = []
    @State private var expandedContextGroupIDs: Set<String> = []
    @State private var entryOffset: CGSize = .zero
    @State private var entryOpacity: Double = 1
    @State private var entryScale: CGFloat = 1
    @State private var hasRunEntryAnimation = false
    @State private var entryAnimationTask: Task<Void, Never>?
    @State private var displayEntryCache = MessageBubbleDisplayEntryCache()

    private var effectiveMessage: OpenCodeMessageEnvelope {
        detailedMessage ?? message
    }

    private var isUser: Bool {
        (effectiveMessage.info.role ?? "").lowercased() == "user"
    }

    private var bubbleColor: Color {
        isUser ? .blue : .clear
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isUser ? 22 : 18, style: .continuous)
    }

    private var displayEntries: [DisplayEntry] {
        let parts = effectiveMessage.parts
        let key = MessageBubbleDisplayEntryCacheKey(
            messageID: effectiveMessage.id,
            isUser: isUser,
            parts: parts.map(displayEntryCachePartKey(for:))
        )
        let plan = displayEntryCache.plan(for: key) {
            makeDisplayEntryPlan(from: parts)
        }
        return materializeDisplayEntryPlan(plan, parts: parts)
    }

    private var entryStartOffset: CGSize {
        CGSize(width: 0, height: 900)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if isUser {
                Spacer(minLength: 44)
            }

            messageContent

            if !isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .offset(entryOffset)
        .opacity(entryOpacity)
        .scaleEffect(entryScale, anchor: .bottomTrailing)
        .onAppear {
            prepareEntryAnimationIfNeeded()
            runEntryAnimationIfNeeded()
        }
        .onChange(of: reserveEntryFromComposer) { _, _ in
            prepareEntryAnimationIfNeeded()
        }
        .onChange(of: animateEntryFromComposer) { _, _ in
            runEntryAnimationIfNeeded()
        }
        .onDisappear {
            entryAnimationTask?.cancel()
            entryAnimationTask = nil
        }
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(displayEntries, id: \.id) { entry in
                switch entry {
                case let .part(indexed):
                    partView(indexed.part, index: indexed.index)
                        .transition(.identity)
                case let .context(group):
                    contextGroupView(group)
                        .transition(.identity)
                }
            }

            if let error = effectiveMessage.info.error?.displayMessage {
                ErrorMessageCard(message: error, title: effectiveMessage.info.error?.name)
                    .transition(.identity)
            }
        }
        .contextMenu { messageContextMenu }
    }

    @ViewBuilder
    private var messageContextMenu: some View {
        Button {} label: {
            Label("Agent: \(agentLabel)", systemImage: "person.crop.circle")
        }
        .disabled(true)

        Button {} label: {
            Label("Model: \(modelLabel)", systemImage: "cpu")
        }
        .disabled(true)

        Button {} label: {
            Label("Reasoning: \(reasoningLabel)", systemImage: "brain.head.profile")
        }
        .disabled(true)

        Divider()

        Button {
            onInspectDebugMessage(effectiveMessage)
        } label: {
            Label("Debug JSON", systemImage: "curlybraces")
        }

        if let copiedText = effectiveMessage.copiedTextContent() {
            Button {
                OpenCodeClipboard.copy(copiedText)
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }

        if isUser {
            Divider()

            Button {
                onForkMessage(effectiveMessage)
            } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
            }
        }
    }

    private var agentLabel: String {
        effectiveMessage.info.agent?.nilIfEmpty ?? "Default"
    }

    private var modelLabel: String {
        guard let model = effectiveMessage.info.model else { return "Default" }
        return "\(model.providerID)/\(model.modelID)"
    }

    private var reasoningLabel: String {
        if let variant = effectiveMessage.info.model?.variant?.nilIfEmpty {
            return formattedReasoningVariant(variant)
        }

        let reasoningParts = effectiveMessage.parts.filter { $0.type == "reasoning" && ($0.text?.nilIfEmpty != nil) }
        guard !reasoningParts.isEmpty else { return "None" }
        return reasoningParts.count == 1 ? "1 block" : "\(reasoningParts.count) blocks"
    }

    private func formattedReasoningVariant(_ variant: String) -> String {
        variant.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func runEntryAnimationIfNeeded() {
        guard animateEntryFromComposer, isUser, !hasRunEntryAnimation else { return }

        hasRunEntryAnimation = true
        var transaction = Transaction()
        transaction.animation = nil

        withTransaction(transaction) {
            entryOffset = entryStartOffset
            entryOpacity = 0.94
            entryScale = 0.985
        }

        entryAnimationTask?.cancel()
        entryAnimationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.48, dampingFraction: 0.84)) {
                entryOffset = .zero
                entryOpacity = 1
                entryScale = 1
            }
            entryAnimationTask = nil
        }
    }

    private func prepareEntryAnimationIfNeeded() {
        guard reserveEntryFromComposer, isUser, !hasRunEntryAnimation else { return }

        var transaction = Transaction()
        transaction.animation = nil

        withTransaction(transaction) {
            entryOffset = entryStartOffset
            entryOpacity = 0.001
            entryScale = 0.985
        }
    }

    @ViewBuilder
    private func partView(_ part: OpenCodePart, index: Int) -> some View {
        if let attachment = attachment(for: part) {
            AttachmentBubblePart(attachment: attachment, isUser: isUser)
        } else if let text = renderableText(for: part) {
            if textStyle(for: part) == .reasoning {
                let content = ReasoningBlock(
                    text: text,
                    isExpanded: isReasoningExpanded(part: part, index: index),
                    isRunning: isReasoningRunning(part),
                    onToggle: { toggleReasoning(part: part, index: index) }
                )

                if isUser {
                    bubbleWrapped(content)
                } else {
                    content
                }
            } else {
                let content = MarkdownMessageText(text: text, isUser: isUser, style: textStyle(for: part), isStreaming: isStreamingMessage, animatesStreamingText: animatesStreamingText)

                if isUser {
                    bubbleWrapped(content)
                } else {
                    content
                }
            }
        } else if let activity = activityStyle(for: part) {
            let content = Button {
                handleActivityTap(for: part)
            } label: {
                ActivityRow(style: activity)
            }
            .buttonStyle(.plain)

            if isUser {
                bubbleWrapped(content)
            } else {
                content
            }
        }
    }

    private func contextGroupView(_ group: ContextGroup) -> some View {
        let isExpanded = expandedContextGroupIDs.contains(group.id)
        let summary = contextSummary(for: group.parts)
        let running = isStreamingMessage || group.parts.contains { isRunning($0.part) }
        let title = running ? "Exploring" : "Explored"
        let subtitle = contextSummaryText(summary)

        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    toggleContextGroup(group.id)
                }
            } label: {
                ContextToolGroupCard(
                    style: ActivityStyle(
                        title: title,
                        subtitle: subtitle,
                        icon: "square.stack.3d.up.fill",
                        tint: .teal,
                        isRunning: running,
                        showsDisclosure: true,
                        shimmerTitle: false
                    ),
                    expanded: isExpanded
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(group.parts, id: \.id) { indexed in
                        if let style = activityStyle(for: indexed.part) {
                            Button {
                                handleActivityTap(for: indexed.part)
                            } label: {
                                ActivityRow(style: style, compact: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.leading, 10)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isExpanded)
    }

    private func bubbleWrapped<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                bubbleColor.clipShape(bubbleShape)
            }
            .frame(maxWidth: 320, alignment: .trailing)
    }

    private func renderableText(for part: OpenCodePart) -> String? {
        guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private func todoWriteTitle(for part: OpenCodePart, running: Bool) -> String {
        if running {
            return "Updating Todos"
        }

        let title = part.state?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            return title
        }

        return "Todo Update"
    }

    private func todoWriteSubtitle(for part: OpenCodePart) -> String? {
        guard let todos = todoWriteTodos(for: part), !todos.isEmpty else {
            return part.state?.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let completed = todos.filter { $0.isComplete }.count
        let inProgress = todos.filter { $0.isInProgress }.count
        let pending = todos.count - completed - inProgress

        var segments: [String] = []
        if completed > 0 {
            segments.append("\(completed) completed")
        }
        if inProgress > 0 {
            segments.append("\(inProgress) in progress")
        }
        if pending > 0 {
            segments.append("\(pending) pending")
        }

        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: " · ")
    }

    private func todoWriteTodos(for part: OpenCodePart) -> [OpenCodeTodo]? {
        guard let output = part.state?.output,
              let data = output.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode([OpenCodeTodo].self, from: data)
    }

    private func textStyle(for part: OpenCodePart) -> MarkdownMessageText.Style {
        if !isUser, part.type == "reasoning" {
            return .reasoning
        }
        return .standard
    }

    private func attachment(for part: OpenCodePart) -> OpenCodeComposerAttachment? {
        guard part.type == "file",
              let filename = part.filename,
              let mime = part.mime,
              let url = part.url else {
            return nil
        }

        return OpenCodeComposerAttachment(
            id: part.id ?? "\(effectiveMessage.id)-\(filename)",
            kind: mime.lowercased().hasPrefix("image/") ? .image : .file,
            filename: filename,
            mime: mime,
            dataURL: url
        )
    }

    private func reasoningPartID(part: OpenCodePart, index: Int) -> String {
        part.id ?? "\(effectiveMessage.id)-reasoning-\(index)"
    }

    private func isReasoningExpanded(part: OpenCodePart, index: Int) -> Bool {
        expandedReasoningPartIDs.contains(reasoningPartID(part: part, index: index))
    }

    private func toggleReasoning(part: OpenCodePart, index: Int) {
        let id = reasoningPartID(part: part, index: index)
        if expandedReasoningPartIDs.contains(id) {
            expandedReasoningPartIDs.remove(id)
        } else {
            expandedReasoningPartIDs.insert(id)
        }
    }

    private func toggleContextGroup(_ id: String) {
        if expandedContextGroupIDs.contains(id) {
            expandedContextGroupIDs.remove(id)
        } else {
            expandedContextGroupIDs.insert(id)
        }
    }

    private func isReasoningRunning(_ part: OpenCodePart) -> Bool {
        isRunning(part) || isStreamingMessage
    }

    private func displayEntryCachePartKey(for part: OpenCodePart) -> MessageBubbleDisplayEntryCacheKey.PartKey {
        MessageBubbleDisplayEntryCacheKey.PartKey(
            id: part.id,
            type: part.type,
            toolName: toolName(for: part),
            hasRenderableText: renderableText(for: part) != nil
        )
    }

    private func makeDisplayEntryPlan(from parts: [OpenCodePart]) -> [MessageBubbleDisplayEntryPlan] {
        var result: [MessageBubbleDisplayEntryPlan] = []
        var contextIndices: [Int] = []

        func flushContextParts() {
            guard !contextIndices.isEmpty else { return }
            let firstIndex = contextIndices[0]
            let firstID = displayEntryPartID(index: firstIndex, part: parts[firstIndex])
            result.append(.context(id: "context-\(effectiveMessage.id)-\(firstID)", indices: contextIndices))
            contextIndices.removeAll(keepingCapacity: true)
        }

        for (index, part) in parts.enumerated() {
            if shouldGroupInContext(part) {
                contextIndices.append(index)
            } else {
                flushContextParts()
                result.append(.part(index: index))
            }
        }

        flushContextParts()
        return result
    }

    private func materializeDisplayEntryPlan(_ plan: [MessageBubbleDisplayEntryPlan], parts: [OpenCodePart]) -> [DisplayEntry] {
        plan.compactMap { entry in
            switch entry {
            case let .part(index):
                guard parts.indices.contains(index) else { return nil }
                return .part(IndexedPart(index: index, part: parts[index]))
            case let .context(id, indices):
                let indexedParts = indices.compactMap { index -> IndexedPart? in
                    guard parts.indices.contains(index) else { return nil }
                    return IndexedPart(index: index, part: parts[index])
                }
                guard !indexedParts.isEmpty else { return nil }
                return .context(ContextGroup(id: id, parts: indexedParts))
            }
        }
    }

    private func displayEntryPartID(index: Int, part: OpenCodePart) -> String {
        "part-\(index)-\(part.id ?? part.type)"
    }

    private func shouldGroupInContext(_ part: OpenCodePart) -> Bool {
        !isUser && renderableText(for: part) == nil && contextGroupTools.contains(toolName(for: part))
    }

    private func handleActivityTap(for part: OpenCodePart) {
        if toolName(for: part) == "task",
           let currentSessionID,
           let sessionID = resolveTaskSessionID(for: part, currentSessionID: currentSessionID) {
            onOpenTaskSession(sessionID)
            return
        }

        onSelectPart(part)
    }

    private func activityStyle(for part: OpenCodePart) -> ActivityStyle? {
        let tool = toolName(for: part)
        let running = isRunning(part)

        switch tool {
        case "", "step-start", "step-finish", "reasoning", "text":
            return nil
        case "todowrite":
            return ActivityStyle(
                title: todoWriteTitle(for: part, running: running),
                subtitle: todoWriteSubtitle(for: part),
                icon: "checklist",
                tint: .blue,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: running
            )
        case "bash":
            return ActivityStyle(
                title: "Shell",
                subtitle: running ? nil : firstNonEmpty(part.state?.input?.description, toolSubtitle(for: part, fallback: nil)),
                icon: "terminal.fill",
                tint: .green,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: running
            )
        case "read":
            return ActivityStyle(
                title: "Read",
                subtitle: firstNonEmpty(filename(from: part.state?.input?.filePath), filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil)),
                icon: "eyeglasses",
                tint: .blue,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "list":
            return ActivityStyle(
                title: "List",
                subtitle: firstNonEmpty(filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil)),
                icon: "list.bullet",
                tint: .indigo,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "glob":
            return ActivityStyle(
                title: "Glob",
                subtitle: firstNonEmpty(part.state?.input?.pattern, filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil)),
                icon: "magnifyingglass",
                tint: .teal,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "grep":
            return ActivityStyle(
                title: "Grep",
                subtitle: firstNonEmpty(part.state?.input?.pattern, filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil)),
                icon: "magnifyingglass.circle",
                tint: .mint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "webfetch":
            return ActivityStyle(
                title: "Webfetch",
                subtitle: running ? nil : firstNonEmpty(part.state?.input?.url, toolSubtitle(for: part, fallback: nil)),
                icon: "network",
                tint: .teal,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: running
            )
        case "websearch":
            return ActivityStyle(
                title: "Web Search",
                subtitle: firstNonEmpty(part.state?.input?.query, toolSubtitle(for: part, fallback: nil)),
                icon: "globe",
                tint: .teal,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "codesearch":
            return ActivityStyle(
                title: "Code Search",
                subtitle: firstNonEmpty(part.state?.input?.query, toolSubtitle(for: part, fallback: nil)),
                icon: "chevron.left.forwardslash.chevron.right",
                tint: .purple,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "task":
            let agent = taskAgentTitle(for: part)
            let subtitle = firstNonEmpty(part.state?.input?.description, resolveTaskSessionID(for: part, currentSessionID: currentSessionID ?? ""), toolSubtitle(for: part, fallback: nil))
            return ActivityStyle(
                title: agent,
                subtitle: subtitle,
                icon: "square.stack.3d.up.fill",
                tint: .purple,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "edit":
            return ActivityStyle(
                title: "Edit",
                subtitle: firstNonEmpty(filename(from: part.state?.input?.filePath), toolSubtitle(for: part, fallback: nil)),
                icon: "square.and.pencil",
                tint: .orange,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "write":
            return ActivityStyle(
                title: "Write",
                subtitle: firstNonEmpty(filename(from: part.state?.input?.filePath), toolSubtitle(for: part, fallback: nil)),
                icon: "square.and.pencil",
                tint: .orange,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "apply_patch":
            let count = part.state?.metadata?.files?.count
            let fileSummary = count.map { $0 == 1 ? "1 file" : "\($0) files" }
            return ActivityStyle(
                title: "Patch",
                subtitle: firstNonEmpty(fileSummary, toolSubtitle(for: part, fallback: nil)),
                icon: "hammer.fill",
                tint: .orange,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "question":
            return ActivityStyle(
                title: "Questions",
                subtitle: toolSubtitle(for: part, fallback: nil),
                icon: "questionmark.bubble",
                tint: .blue,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "skill":
            return ActivityStyle(
                title: firstNonEmpty(part.state?.input?.name, "Skill") ?? "Skill",
                subtitle: toolSubtitle(for: part, fallback: nil),
                icon: "brain",
                tint: .indigo,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "mcp":
            return ActivityStyle(
                title: firstNonEmpty(part.state?.title, "MCP") ?? "MCP",
                subtitle: toolSubtitle(for: part, fallback: nil),
                icon: "point.3.connected.trianglepath.dotted",
                tint: .pink,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        default:
            let title = firstNonEmpty(part.state?.title, displayTitle(for: tool, fallback: part.type)) ?? "Tool"
            return ActivityStyle(
                title: title,
                subtitle: firstNonEmpty(part.state?.input?.description, toolSubtitle(for: part, fallback: nil)),
                icon: "wrench.and.screwdriver.fill",
                tint: .secondary,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        }
    }

    private func toolName(for part: OpenCodePart) -> String {
        if part.type == "tool" {
            return part.tool ?? ""
        }
        return part.tool ?? part.type
    }

    private func filename(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    private func taskAgentTitle(for part: OpenCodePart) -> String {
        let trimmed = part.state?.input?.subagentType?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else {
            return "Agent"
        }

        let value = String(first).uppercased() + String(trimmed.dropFirst())
        return "\(value) Agent"
    }

    private func resolveTaskSessionID(for part: OpenCodePart, currentSessionID: String) -> String? {
        resolveTaskSessionID(part, currentSessionID)
    }

    private func displayTitle(for tool: String, fallback: String) -> String {
        let value = firstNonEmpty(tool, fallback) ?? "tool"
        return value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }

    private func contextSummary(for parts: [IndexedPart]) -> ContextSummary {
        parts.reduce(into: ContextSummary()) { summary, indexed in
            switch toolName(for: indexed.part) {
            case "read":
                summary.reads += 1
            case "glob", "grep":
                summary.searches += 1
            case "list":
                summary.lists += 1
            default:
                break
            }
        }
    }

    private func contextSummaryText(_ summary: ContextSummary) -> String? {
        var items: [String] = []
        if summary.reads > 0 {
            items.append(summary.reads == 1 ? "1 read" : "\(summary.reads) reads")
        }
        if summary.searches > 0 {
            items.append(summary.searches == 1 ? "1 search" : "\(summary.searches) searches")
        }
        if summary.lists > 0 {
            items.append(summary.lists == 1 ? "1 list" : "\(summary.lists) lists")
        }
        return items.isEmpty ? nil : items.joined(separator: ", ")
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !trimmed.isEmpty
        } ?? nil
    }

    private func toolSubtitle(for part: OpenCodePart, fallback: String?) -> String? {
        if let status = part.state?.status?.lowercased() {
            switch status {
            case "completed", "complete", "success":
                return "Completed"
            case "error", "failed":
                return "Error"
            case "running", "pending", "in_progress":
                return "Running"
            default:
                return status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        if let reason = part.reason {
            switch reason.lowercased() {
            case "stop", "finish", "finished", "complete", "completed":
                return "Completed"
            case "start", "started", "running":
                return "Running"
            default:
                return reason.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }

        return fallback
    }

    private func isRunning(_ part: OpenCodePart) -> Bool {
        if let status = part.state?.status?.lowercased() {
            return status == "running" || status == "pending" || status == "in_progress"
        }
        guard let reason = part.reason?.lowercased() else { return false }
        return reason == "start" || reason == "started" || reason == "running"
    }
}

private let contextGroupTools: Set<String> = ["read", "glob", "grep", "list"]

private struct IndexedPart: Identifiable {
    let index: Int
    let part: OpenCodePart

    var id: String {
        "part-\(index)-\(part.id ?? part.type)"
    }
}

private struct ContextGroup {
    let id: String
    let parts: [IndexedPart]
}

private struct ContextSummary {
    var reads = 0
    var searches = 0
    var lists = 0
}

private struct MessageBubbleDisplayEntryCacheKey: Equatable {
    struct PartKey: Equatable {
        let id: String?
        let type: String
        let toolName: String
        let hasRenderableText: Bool
    }

    let messageID: String
    let isUser: Bool
    let parts: [PartKey]
}

private enum MessageBubbleDisplayEntryPlan {
    case part(index: Int)
    case context(id: String, indices: [Int])
}

private final class MessageBubbleDisplayEntryCache {
    private var lastKey: MessageBubbleDisplayEntryCacheKey?
    private var lastPlan: [MessageBubbleDisplayEntryPlan] = []

    func plan(for key: MessageBubbleDisplayEntryCacheKey, build: () -> [MessageBubbleDisplayEntryPlan]) -> [MessageBubbleDisplayEntryPlan] {
        if key == lastKey {
            return lastPlan
        }

        let plan = build()
        lastKey = key
        lastPlan = plan
        return plan
    }
}

private enum DisplayEntry: Identifiable {
    case part(IndexedPart)
    case context(ContextGroup)

    var id: String {
        switch self {
        case let .part(indexed):
            return indexed.id
        case let .context(group):
            return group.id
        }
    }
}

private struct ContextToolGroupCard: View {
    let style: ActivityStyle
    let expanded: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.55))
                .offset(x: 6, y: 8)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.8))
                .offset(x: 3, y: 4)

            ActivityRow(
                style: ActivityStyle(
                    title: style.title,
                    subtitle: style.subtitle,
                    icon: style.icon,
                    tint: style.tint,
                    isRunning: style.isRunning,
                    showsDisclosure: true,
                    shimmerTitle: style.shimmerTitle
                )
            )
            .overlay(alignment: .trailing) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 12)
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 8)
    }
}

private struct AttachmentBubblePart: View {
    let attachment: OpenCodeComposerAttachment
    let isUser: Bool

    var body: some View {
        HStack {
            if attachment.isImage {
                AttachmentThumbnail(attachment: attachment)
                    .frame(width: 220, height: 220)
                    .background(OpenCodePlatformColor.secondaryGroupedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                AttachmentCard(attachment: attachment, allowsRemoval: false, onTap: {}, onRemove: {})
            }
            if !isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}

private struct ErrorMessageCard: View {
    let message: String
    let title: String?

    private var displayTitle: String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return "Error" }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))

                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.red)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.red.opacity(0.28), lineWidth: 1)
        }
    }
}
