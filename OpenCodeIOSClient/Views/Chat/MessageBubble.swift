import SwiftUI

struct MessageBubble: View {
    let message: OpenCodeMessageEnvelope
    let detailedMessage: OpenCodeMessageEnvelope?
    let isStreamingMessage: Bool
    let onSelectPart: (OpenCodePart) -> Void

    @State private var expandedReasoningPartIDs: Set<String> = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(effectiveMessage.parts.enumerated()), id: \.offset) { entry in
                let index = entry.offset
                let part = entry.element
                partView(part, index: index)
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func partView(_ part: OpenCodePart, index: Int) -> some View {
        if let attachment = attachment(for: part) {
            AttachmentBubblePart(attachment: attachment, isUser: isUser)
        } else if let text = renderableText(for: part) {
            if textStyle(for: part) == .reasoning {
                let content =
                    ReasoningBlock(
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
                let content = MarkdownMessageText(text: text, isUser: isUser, style: textStyle(for: part))

                if isUser {
                    bubbleWrapped(content)
                } else {
                    content
                }
            }
        } else if let activity = activityStyle(for: part, parts: effectiveMessage.parts, index: index) {
            let content =
                Button {
                    onSelectPart(part)
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

    private func bubbleWrapped<Content: View>(_ content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                bubbleColor.clipShape(bubbleShape)
            }
            .frame(maxWidth: 320, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func renderableText(for part: OpenCodePart) -> String? {
        guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
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

    private func isReasoningRunning(_ part: OpenCodePart) -> Bool {
        isRunning(part) || isStreamingMessage
    }

    private func activityStyle(for part: OpenCodePart, parts: [OpenCodePart], index: Int) -> ActivityStyle? {
        let preview = activityPreview(for: part) ?? relatedPreview(for: parts, around: index)

        switch part.type {
        case "step-start", "step-finish", "reasoning", "text":
            return nil
        case "tool":
            let title = part.state?.title ?? inferredToolTitle(from: preview)
            let subtitle = toolPreview(for: part) ?? preview ?? toolSubtitle(for: part)
            let icon = inferredToolIcon(from: part.tool ?? preview)
            let tint = inferredToolTint(from: part.tool ?? preview)
            return ActivityStyle(title: title, subtitle: subtitle, icon: icon, tint: tint, isRunning: isRunning(part))
        case "bash":
            return ActivityStyle(title: preview ?? "Shell Command", subtitle: toolSubtitle(for: part, fallback: "Command"), icon: "terminal.fill", tint: .green, isRunning: isRunning(part))
        case "read":
            return ActivityStyle(title: preview ?? "Read File", subtitle: toolSubtitle(for: part, fallback: "File read"), icon: "doc.text.magnifyingglass", tint: .blue, isRunning: isRunning(part))
        case "write":
            return ActivityStyle(title: preview ?? "Write File", subtitle: toolSubtitle(for: part, fallback: "File write"), icon: "square.and.pencil", tint: .orange, isRunning: isRunning(part))
        case "grep":
            return ActivityStyle(title: preview ?? "Search Content", subtitle: toolSubtitle(for: part, fallback: "Content search"), icon: "line.3.horizontal.decrease.circle", tint: .mint, isRunning: isRunning(part))
        case "glob":
            return ActivityStyle(title: preview ?? "Find Files", subtitle: toolSubtitle(for: part, fallback: "File search"), icon: "folder.badge.questionmark", tint: .teal, isRunning: isRunning(part))
        case "bash_output", "command":
            return ActivityStyle(title: preview ?? "Command Output", subtitle: toolSubtitle(for: part, fallback: "Output"), icon: "chevron.left.forwardslash.chevron.right", tint: .gray, isRunning: isRunning(part))
        case "task":
            return ActivityStyle(title: preview ?? "Subtask", subtitle: toolSubtitle(for: part, fallback: "Delegated work"), icon: "square.stack.3d.up", tint: .purple, isRunning: isRunning(part))
        case "mcp":
            return ActivityStyle(title: preview ?? "MCP Call", subtitle: toolSubtitle(for: part, fallback: "Tool bridge"), icon: "point.3.connected.trianglepath.dotted", tint: .pink, isRunning: isRunning(part))
        default:
            return ActivityStyle(title: preview ?? part.type.replacingOccurrences(of: "-", with: " ").capitalized, subtitle: toolSubtitle(for: part, fallback: part.type.replacingOccurrences(of: "-", with: " ")), icon: "wrench.and.screwdriver.fill", tint: .secondary, isRunning: isRunning(part))
        }
    }

    private func relatedPreview(for parts: [OpenCodePart], around index: Int) -> String? {
        for candidate in parts.dropFirst(index + 1) {
            if let preview = activityPreview(for: candidate) {
                return preview
            }
        }

        for candidate in parts.prefix(index).reversed() {
            if let preview = activityPreview(for: candidate) {
                return preview
            }
        }

        return nil
    }

    private func activityPreview(for part: OpenCodePart) -> String? {
        if let preview = toolPreview(for: part) {
            return preview
        }

        guard let raw = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let firstLine = raw.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
        guard !firstLine.isEmpty else { return nil }

        if ["bash", "command", "bash_output", "read", "write", "glob", "grep"].contains(part.type) {
            return firstLine
        }

        return String(firstLine.prefix(60))
    }

    private func toolPreview(for part: OpenCodePart) -> String? {
        if let command = part.state?.input?.command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty { return command }
        if let path = part.state?.input?.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty { return path }
        if let query = part.state?.input?.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty { return query }
        if let pattern = part.state?.input?.pattern?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty { return pattern }
        if let url = part.state?.input?.url?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty { return url }
        if let description = part.state?.input?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty { return description }
        return nil
    }

    private func inferredToolTitle(from preview: String?) -> String {
        let lowercased = preview?.lowercased() ?? ""
        if lowercased.contains("read") || lowercased.contains("file") { return "File Activity" }
        if lowercased.contains("write") || lowercased.contains("patch") || lowercased.contains("edit") { return "Edit Activity" }
        if lowercased.contains("search") || lowercased.contains("grep") || lowercased.contains("glob") || lowercased.contains("find") { return "Search Activity" }
        if lowercased.contains("http") || lowercased.contains("fetch") || lowercased.contains("github") { return "Web Activity" }
        if lowercased.contains("npm") || lowercased.contains("git") || lowercased.contains("xcodebuild") || lowercased.contains("curl") { return "Command Activity" }
        return "Tool Activity"
    }

    private func inferredToolIcon(from preview: String?) -> String {
        let lowercased = preview?.lowercased() ?? ""
        if lowercased.contains("read") || lowercased.contains("file") { return "doc.text.magnifyingglass" }
        if lowercased.contains("write") || lowercased.contains("patch") || lowercased.contains("edit") { return "square.and.pencil" }
        if lowercased.contains("search") || lowercased.contains("grep") || lowercased.contains("glob") || lowercased.contains("find") { return "line.3.horizontal.decrease.circle" }
        if lowercased.contains("http") || lowercased.contains("fetch") || lowercased.contains("github") { return "network" }
        if lowercased.contains("npm") || lowercased.contains("git") || lowercased.contains("xcodebuild") || lowercased.contains("curl") { return "terminal.fill" }
        return "hammer.fill"
    }

    private func inferredToolTint(from preview: String?) -> Color {
        let lowercased = preview?.lowercased() ?? ""
        if lowercased.contains("read") || lowercased.contains("file") { return .blue }
        if lowercased.contains("write") || lowercased.contains("patch") || lowercased.contains("edit") { return .orange }
        if lowercased.contains("search") || lowercased.contains("grep") || lowercased.contains("glob") || lowercased.contains("find") { return .mint }
        if lowercased.contains("http") || lowercased.contains("fetch") || lowercased.contains("github") { return .teal }
        if lowercased.contains("npm") || lowercased.contains("git") || lowercased.contains("xcodebuild") || lowercased.contains("curl") { return .green }
        return .indigo
    }

    private func toolSubtitle(for part: OpenCodePart, fallback: String = "Running tool") -> String {
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
