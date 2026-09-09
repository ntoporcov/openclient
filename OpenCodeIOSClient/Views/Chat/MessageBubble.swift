import SwiftUI

private enum MessageBubbleSpacing {
    static let part: CGFloat = 10
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct MessageBubbleActivityBudgetProjection: Equatable {
    let retainedIndices: Set<Int>
    let firstHiddenIndex: Int?
    let hiddenCount: Int
}

enum MessageBubbleActivityBudget {
    static func project(protectedEntries: [Bool], limit: Int) -> MessageBubbleActivityBudgetProjection {
        let budgetableIndices = protectedEntries.indices.filter { !protectedEntries[$0] }
        let retainedBudgetableIndices = Set(budgetableIndices.suffix(max(0, limit)))
        let retainedIndices = Set(protectedEntries.indices.filter { protectedEntries[$0] }).union(retainedBudgetableIndices)
        let hiddenIndices = protectedEntries.indices.filter { !retainedIndices.contains($0) }
        return MessageBubbleActivityBudgetProjection(
            retainedIndices: retainedIndices,
            firstHiddenIndex: hiddenIndices.first,
            hiddenCount: hiddenIndices.count
        )
    }
}

enum MessageBubbleUserPartPolicy {
    static func shouldDisplay(_ part: OpenCodePart, at index: Int, in parts: [OpenCodePart]) -> Bool {
        if part.type == "agent" { return false }
        guard part.type == "text" else { return true }

        return index == parts.firstIndex { candidate in
            candidate.type == "text" && candidate.synthetic != true
        }
    }
}

enum MessageBubblePartVisibilityPolicy {
    static func renderableText(for part: OpenCodePart, isUser: Bool) -> String? {
        guard isUser || part.type == "text" || part.type == "reasoning",
              let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    static func shouldDisplay(
        _ part: OpenCodePart,
        showsToolCalls: Bool,
        showsReasoningBlocks: Bool
    ) -> Bool {
        if !showsToolCalls, OpenCodeToolActivityPolicy.isToolCall(part) { return false }
        if !showsReasoningBlocks, isReasoningPart(part) { return false }
        return true
    }

    static func isReasoningPart(_ part: OpenCodePart) -> Bool {
        if part.type == "reasoning" { return true }
        return part.type == "text" && (part.reason?.lowercased().contains("reasoning") == true)
    }
}

enum MessageBubbleMessageVisibilityPolicy {
    static func shouldDisplay(
        _ message: OpenCodeMessageEnvelope,
        showsToolCalls: Bool,
        showsReasoningBlocks: Bool
    ) -> Bool {
        if message.info.error != nil { return true }

        return message.parts.enumerated().contains { index, part in
            if (message.info.role ?? "").lowercased() == "user",
               !MessageBubbleUserPartPolicy.shouldDisplay(part, at: index, in: message.parts) {
                return false
            }
            guard MessageBubblePartVisibilityPolicy.shouldDisplay(
                part,
                showsToolCalls: showsToolCalls,
                showsReasoningBlocks: showsReasoningBlocks
            ) else { return false }
            if MessageBubblePartVisibilityPolicy.renderableText(
                for: part,
                isUser: (message.info.role ?? "").lowercased() == "user"
            ) != nil { return true }
            if part.type == "file", part.url != nil { return true }
            return OpenCodeToolActivityPolicy.isToolCall(part)
        }
    }
}

enum MessageBubbleDisplayIdentity {
    static func partID(index: Int, part: OpenCodePart) -> String {
        if let id = part.id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return "part-\(id)"
        }
        return "part-\(index)-\(part.type)"
    }

    static func contextID(messageID: String, firstIndex: Int, firstPart: OpenCodePart) -> String {
        "context-\(messageID)-\(partID(index: firstIndex, part: firstPart))"
    }
}

enum MessageBubbleTaskNavigation {
    static func sessionID(
        for part: OpenCodePart,
        currentSessionID: String,
        resolveLegacyTask: (OpenCodePart, String) -> String?
    ) -> String? {
        switch OpenCodeToolActivityPolicy.toolName(for: part) {
        case "subagent":
            // V2 supplies explicit child identity; never guess from output or similar titles.
            guard let id = part.state?.metadata?.sessionId, !id.isEmpty, id != currentSessionID else { return nil }
            return id
        case "task":
            return resolveLegacyTask(part, currentSessionID)
        default:
            return nil
        }
    }
}

struct MessageBubble: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    let message: OpenCodeMessageEnvelope
    let detailedMessage: OpenCodeMessageEnvelope?
    let currentSessionID: String?
    let isStreamingMessage: Bool
    let animatesStreamingText: Bool
    let showsToolCalls: Bool
    let hidesReasoningBlocks: Bool
    let reserveEntryFromComposer: Bool
    let animateEntryFromComposer: Bool
    let expandedReasoningPartIDs: Set<String>
    let expandedContextGroupIDs: Set<String>
    let showsAllActivity: Bool
    var tableMaximumWidth: CGFloat? = nil
    var allowsForkMessage: Bool = true
    let resolveTaskSessionID: (OpenCodePart, String) -> String?
    let onSelectPart: (OpenCodePart) -> Void
    let onOpenTaskSession: (String) -> Void
    let onForkMessage: (OpenCodeMessageEnvelope) -> Void
    let onInspectDebugMessage: (OpenCodeMessageEnvelope) -> Void
    let onEntryAnimationStarted: (String) -> Void
    let onToggleReasoningPart: (String) -> Void
    let onToggleContextGroup: (String) -> Void
    let onShowEarlierActivity: () -> Void
    let onOpenVisualHTML: (OpenClientVisualHTMLPayload) -> Void
    let imageContent: OpenClientImageContentCoordinator?
    let imageLoadingStore: OpenClientImageLoadingStore
    let videoStreams: OpenClientVideoStreamCoordinator?
    let videoPlaybackStore: OpenClientVideoPlaybackStore
    var onAnswerTextTap: () -> Void = {}
    var onEntryAnimationCompleted: (String) -> Void = { _ in }
    var onEntryAnimationCancelled: (String) -> Void = { _ in }
    #if DEBUG
    var entryReduceMotionOverride: Bool? = nil
    #endif

    private var reduceMotion: Bool {
        #if DEBUG
        if let entryReduceMotionOverride { return entryReduceMotionOverride }
        #endif
        #if DEBUG && canImport(UIKit)
        if TranscriptContinuityDiagnostics.enabled, TranscriptContinuityDiagnostics.reducesMotion { return true }
        #endif
        return systemReduceMotion
    }

    @State private var entryAnimationStartDate: Date?
    @State private var entryAnimationMessageID: String?
    @State private var hasRunEntryAnimation = false
    @State private var hasFinishedEntryAnimation = false
    @State private var entryAnimationStartTask: Task<Void, Never>?
    @State private var entryAnimationTask: Task<Void, Never>?
    @State private var displayEntryCache = MessageBubbleDisplayEntryCache()

    private static let outgoingEntryStartOffset = CGSize(width: 0, height: 600)

    private var effectiveMessage: OpenCodeMessageEnvelope {
        detailedMessage ?? message
    }

    private var isUser: Bool {
        (effectiveMessage.info.role ?? "").lowercased() == "user"
    }

    private var bubbleColor: Color {
        isUser ? .blue : .clear
    }

    private var bubbleShape: MessageBubbleShape {
        MessageBubbleShape(isOutgoing: isUser, cornerRadius: isUser ? 22 : 18)
    }

    private var userBubbleMaximumWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        520
        #else
        horizontalSizeClass == .regular ? 500 : 320
        #endif
    }

    private var fullDisplayEntries: [DisplayEntry] {
        let parts = effectiveMessage.parts
        let key = MessageBubbleDisplayEntryCacheKey(
            messageID: effectiveMessage.id,
            isUser: isUser,
            showsToolCalls: showsToolCalls,
            hidesReasoningBlocks: hidesReasoningBlocks,
            parts: parts.map(displayEntryCachePartKey(for:))
        )
        let plan = displayEntryCache.plan(for: key) {
            makeDisplayEntryPlan(from: parts)
        }
        return materializeDisplayEntryPlan(plan, parts: parts)
    }

    private var displayEntries: [DisplayEntry] {
        let entries = fullDisplayEntries
        let retainedHTMLPartIDs = retainedVisualHTMLPartIDs
        guard !isUser, !showsAllActivity, !isStreamingMessage else {
            return entries
        }

        let projection = MessageBubbleActivityBudget.project(
            protectedEntries: entries.map {
                isProtectedFromActivityBudget($0, retainedVisualHTMLPartIDs: retainedHTMLPartIDs)
            },
            limit: 12
        )
        guard projection.hiddenCount > 0 else { return entries }

        var result: [DisplayEntry] = []
        for (index, entry) in entries.enumerated() {
            if index == projection.firstHiddenIndex {
                result.append(.earlierActivity(hiddenCount: projection.hiddenCount))
            }
            if projection.retainedIndices.contains(index) {
                result.append(entry)
            }
        }
        return result
    }

    private var renderedDisplayEntries: [DisplayEntry] {
        guard !isUser else { return displayEntries }
        var result: [DisplayEntry] = []
        for entry in displayEntries {
            if case let .part(indexed) = entry,
               indexed.part.type == "text", !isReasoningPart(indexed.part),
               !isStreamingMessage || indexed.part.time?.end != nil {
                if case let .answer(parts) = result.last {
                    result[result.count - 1] = .answer(parts + [indexed])
                } else {
                    result.append(.answer([indexed]))
                }
            } else {
                // Preserve the position of tools, reasoning, and attachments between answers.
                result.append(entry)
            }
        }
        return result
    }

    var body: some View {
        animatedEntryContent
            .onAppear {
                runEntryAnimationIfNeeded()
                scheduleReservedEntryAnimationIfNeeded()
            }
            .onChange(of: reserveEntryFromComposer) { _, _ in
                scheduleReservedEntryAnimationIfNeeded()
                resetEntryAnimationIfInactive()
            }
            .onChange(of: animateEntryFromComposer) { _, _ in
                runEntryAnimationIfNeeded()
                scheduleReservedEntryAnimationIfNeeded()
                resetEntryAnimationIfInactive()
            }
            .onDisappear {
                finishEntryAnimation()
            }
            .onChange(of: reduceMotion) { _, reduced in
                guard reduced else { return }
                if hasRunEntryAnimation {
                    finishEntryAnimation(completed: true)
                } else {
                    scheduleReservedEntryAnimationIfNeeded()
                }
            }
    }

    private var baseContent: some View {
        HStack(alignment: .center, spacing: 0) {
            if isUser {
                Spacer(minLength: 44)
            }

            messageContent
                .frame(maxWidth: isUser ? nil : .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var animatedEntryContent: some View {
        if let entryAnimationStartDate, isUser, hasRunEntryAnimation, !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let progress = entryAnimationProgress(at: timeline.date, startDate: entryAnimationStartDate)
                baseContent
                    .offset(
                        x: Self.outgoingEntryStartOffset.width * (1 - progress),
                        y: Self.outgoingEntryStartOffset.height * (1 - progress)
                    )
                    .opacity(0.72 + 0.28 * progress)
                    .scaleEffect(0.94 + 0.06 * progress, anchor: .bottomTrailing)
                    .onChange(of: progress) { _, progress in
                        if progress >= 1 { finishEntryAnimation(completed: true) }
                    }
                    #if DEBUG && canImport(UIKit)
                    .onChange(of: progress, initial: true) { _, progress in
                        TranscriptContinuityDiagnostics.frame(progress)
                    }
                    #endif
            }
        } else if isUser, reserveEntryFromComposer, !hasRunEntryAnimation, !hasFinishedEntryAnimation, !reduceMotion {
            baseContent
                .offset(Self.outgoingEntryStartOffset)
                .opacity(0.72)
                .scaleEffect(0.94, anchor: .bottomTrailing)
        } else {
            baseContent
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if isUser {
            messageParts.contextMenu { messageContextMenu }
        } else {
            messageParts
        }
    }

    private var messageParts: some View {
        let retainedHTMLPartIDs = retainedVisualHTMLPartIDs
        return VStack(alignment: isUser ? .trailing : .leading, spacing: MessageBubbleSpacing.part) {
            ForEach(renderedDisplayEntries, id: \.id) { entry in
                switch entry {
                case let .answer(parts):
                    let textParts = parts.compactMap { renderableText(for: $0.part) }
                    VStack(alignment: .leading, spacing: MessageBubbleSpacing.part) {
                        ResponseTextContent(
                            messageID: effectiveMessage.id,
                            markdownParts: textParts,
                            onTextTap: onAnswerTextTap
                        )
#if canImport(LinkPresentation)
                        let urls = MessageLinkExtractor.urls(in: textParts.joined(separator: "\n\n"))
                        if !urls.isEmpty {
                            OpenClientMessageLinkPreviews(urls: urls, alignment: .leading)
                        }
#endif
                    }
                case let .part(indexed):
                    revealWrappedPartView(
                        indexed.part,
                        index: indexed.index,
                        retainedVisualHTMLPartIDs: retainedHTMLPartIDs
                    )
                        .modifier(ToolCallEntryModifier(
                            isEnabled: shouldAnimateToolEntry(indexed.part),
                            entryID: "\(effectiveMessage.id):\(entry.id)"
                        ))
                        .transition(.identity)
                case let .context(group):
                    revealWrappedContextGroupView(group)
                        .modifier(ToolCallEntryModifier(
                            isEnabled: isStreamingMessage && !isUser,
                            entryID: "\(effectiveMessage.id):\(entry.id)"
                        ))
                        .transition(.identity)
                case let .earlierActivity(hiddenCount):
                    Button(action: onShowEarlierActivity) {
                        Label("Show earlier activity", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue("\(hiddenCount) hidden items")
                    .accessibilityIdentifier("chat.showEarlierActivity.\(effectiveMessage.id)")
                }
            }

            if let error = effectiveMessage.info.error?.displayMessage {
                ErrorMessageCard(message: error, title: effectiveMessage.info.error?.name)
                    .transition(.identity)
            }

        }
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

        if isUser, let copiedText = effectiveMessage.copiedTextContent() {
            Button {
                OpenCodeClipboard.copy(copiedText)
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }

        if isUser, allowsForkMessage {
            Divider()

            Button {
                onForkMessage(effectiveMessage)
            } label: {
                Label("Fork", systemImage: "arrow.triangle.branch")
            }
        }
    }

    private var agentLabel: String {
        effectiveMessage.info.agent?.nilIfEmpty ?? String(localized: "Default")
    }

    private var modelLabel: String {
        guard let model = effectiveMessage.info.model else { return String(localized: "Default") }
        return "\(model.providerID)/\(model.modelID)"
    }

    private var reasoningLabel: String {
        if let variant = effectiveMessage.info.model?.variant?.nilIfEmpty {
            return formattedReasoningVariant(variant)
        }

        let reasoningParts = effectiveMessage.parts.filter { $0.type == "reasoning" && ($0.text?.nilIfEmpty != nil) }
        guard !reasoningParts.isEmpty else { return String(localized: "None") }
        if reasoningParts.count == 1 { return String(localized: "1 block") }
        return String(localized: "\(reasoningParts.count) blocks")
    }

    private func formattedReasoningVariant(_ variant: String) -> String {
        variant.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func runEntryAnimationIfNeeded() {
        guard animateEntryFromComposer else { return }
        startEntryAnimationIfNeeded()
    }

    private func scheduleReservedEntryAnimationIfNeeded() {
        guard reserveEntryFromComposer, isUser, !hasRunEntryAnimation, !hasFinishedEntryAnimation else { return }
        if entryAnimationMessageID == nil { entryAnimationMessageID = effectiveMessage.id }
        if reduceMotion {
            startEntryAnimationIfNeeded()
            return
        }
        guard entryAnimationStartTask == nil else { return }

        entryAnimationStartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            startEntryAnimationIfNeeded()
        }
    }

    private func startEntryAnimationIfNeeded() {
        guard isUser, !hasRunEntryAnimation, !hasFinishedEntryAnimation else { return }
        guard reserveEntryFromComposer || animateEntryFromComposer else { return }

        hasRunEntryAnimation = true
        let messageID = entryAnimationMessageID ?? effectiveMessage.id
        entryAnimationMessageID = messageID
        #if DEBUG && canImport(UIKit)
        TranscriptContinuityDiagnostics.started(messageID)
        #endif
        onEntryAnimationStarted(messageID)
        if reduceMotion {
            finishEntryAnimation(completed: true)
            return
        }
        entryAnimationStartTask?.cancel()
        entryAnimationStartTask = nil
        entryAnimationStartDate = Date()

        entryAnimationTask?.cancel()
        entryAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            finishEntryAnimation(completed: true)
        }
    }

    private func entryAnimationProgress(at date: Date, startDate: Date) -> CGFloat {
        let elapsed = max(0, date.timeIntervalSince(startDate))
        let duration = 0.48
        let linear = min(1, elapsed / duration)
        return CGFloat(1 - pow(1 - linear, 3))
    }

    private func resetEntryAnimationIfInactive() {
        guard !reserveEntryFromComposer, !animateEntryFromComposer else { return }
        guard entryAnimationStartDate == nil else { return }
        finishEntryAnimation()
    }

    private func finishEntryAnimation(completed: Bool = false) {
        entryAnimationStartTask?.cancel()
        entryAnimationStartTask = nil
        entryAnimationTask?.cancel()
        entryAnimationTask = nil
        entryAnimationStartDate = nil
        guard !hasFinishedEntryAnimation,
              hasRunEntryAnimation || reserveEntryFromComposer || animateEntryFromComposer else { return }
        hasFinishedEntryAnimation = true
        let messageID = entryAnimationMessageID ?? effectiveMessage.id
        if completed {
            #if DEBUG && canImport(UIKit)
            TranscriptContinuityDiagnostics.entryCompleted(messageID, reduced: reduceMotion)
            #endif
            onEntryAnimationCompleted(messageID)
        } else {
            onEntryAnimationCancelled(messageID)
        }
    }

    @ViewBuilder
    private func revealWrappedPartView(
        _ part: OpenCodePart,
        index: Int,
        retainedVisualHTMLPartIDs: Set<String>
    ) -> some View {
        partView(
            part,
            index: index,
            isActiveRevealPart: isActiveRevealPart(at: index, part: part),
            retainedVisualHTMLPartIDs: retainedVisualHTMLPartIDs
        )
    }

    @ViewBuilder
    private func revealWrappedContextGroupView(_ group: ContextGroup) -> some View {
        contextGroupView(group, isActiveRevealPart: false)
    }

    @ViewBuilder
    private func partView(
        _ part: OpenCodePart,
        index: Int,
        isActiveRevealPart: Bool,
        retainedVisualHTMLPartIDs: Set<String>
    ) -> some View {
        if hidesReasoningBlocks, textStyle(for: part) == .reasoning {
            EmptyView()
        } else if let attachment = attachment(for: part) {
            AttachmentBubblePart(attachment: attachment, isUser: isUser)
        } else if let imageActivity = OpenClientVisualImageActivity(
            part: part,
            sessionID: currentSessionID,
            messageID: effectiveMessage.id
        ) {
            OpenClientVisualImageView(
                activity: imageActivity,
                loading: imageLoadingStore.controller(for: imageActivity),
                coordinator: imageContent
            )
        } else if let videoActivity = OpenClientVisualVideoActivity(
            part: part,
            sessionID: currentSessionID,
            messageID: effectiveMessage.id
        ) {
            OpenClientVisualVideoView(
                activity: videoActivity,
                playback: videoPlaybackStore.controller(for: videoActivity),
                coordinator: videoStreams
            )
        } else if let mapActivity = OpenClientVisualMapActivity(part: part) {
            OpenClientVisualMapView(activity: mapActivity)
        } else if let chartActivity = OpenClientVisualChartActivity(part: part) {
            OpenClientVisualChartView(activity: chartActivity)
        } else if shouldRenderVisualHTML(
            part: part,
            index: index,
            retainedVisualHTMLPartIDs: retainedVisualHTMLPartIDs
        ), let htmlActivity = OpenClientVisualHTMLActivity(part: part) {
            OpenClientVisualHTMLView(activity: htmlActivity, onOpen: onOpenVisualHTML)
        } else if let activity = activityStyle(for: part) {
            let content = Button {
                handleActivityTap(for: part)
            } label: {
                ActivityRow(
                    style: activity,
                    reservesSubtitleSpace: toolName(for: part) == "todowrite"
                )
            }
            .buttonStyle(.plain)

            if isUser {
                bubbleWrapped(content)
            } else {
                content
            }
        } else if let text = renderableText(for: part), shouldRenderText(for: part) {
            if textStyle(for: part) == .reasoning {
                let entryID = reasoningPartID(part: part, index: index)
                let content = ReasoningBlock(
                    text: text,
                    isExpanded: isReasoningExpanded(part: part, index: index),
                    isRunning: isReasoningRunning(part),
                    isActiveRevealPart: isActiveRevealPart,
                    onToggle: { toggleReasoning(part: part, index: index) }
                )
                .modifier(ReasoningBlockEntryModifier(
                    isEnabled: isStreamingMessage && !isUser,
                    entryID: "reasoning:\(entryID)"
                ))

                if isUser {
                    bubbleWrapped(content)
                } else {
                    content
                }
            } else {
                let isStreamingText = isStreamingTextPart(part, index: index)
                let markdown = MarkdownMessageText(
                    text: text,
                    isUser: isUser,
                    style: textStyle(for: part),
                    isStreaming: isStreamingText,
                    animatesStreamingText: animatesStreamingText,
                    streamingAnimationID: "\(effectiveMessage.id):\(part.id ?? "part-\(index)")",
                    tableMaximumWidth: tableMaximumWidth
                )
                let urls = isStreamingText ? [] : MessageLinkExtractor.urls(in: text)

                if isUser {
                    VStack(alignment: .trailing, spacing: MessageBubbleSpacing.part) {
                        bubbleWrapped(markdown)
#if canImport(LinkPresentation)
                        if !urls.isEmpty {
                            OpenClientMessageLinkPreviews(urls: urls, alignment: .trailing)
                        }
#endif
                    }
                } else {
                    VStack(alignment: .leading, spacing: MessageBubbleSpacing.part) {
                        markdown
#if canImport(LinkPresentation)
                        if !urls.isEmpty {
                            OpenClientMessageLinkPreviews(urls: urls, alignment: .leading)
                        }
#endif
                    }
                }
            }
        } else if shouldShowUnknownStreamingPartPlaceholder(part) {
            ActivityRow(style: unknownStreamingPartStyle)
        }
    }

    private func shouldRenderText(for part: OpenCodePart) -> Bool {
        isUser || part.type == "text" || part.type == "reasoning"
    }

    private func shouldShowUnknownStreamingPartPlaceholder(_ part: OpenCodePart) -> Bool {
        guard isStreamingMessage, !isUser else { return false }
        return !knownSilentStreamingPartTypes.contains(part.type)
    }

    private func shouldAnimateToolEntry(_ part: OpenCodePart) -> Bool {
        guard isStreamingMessage, !isUser else { return false }
        return activityStyle(for: part) != nil
            || OpenClientVisualMapActivity(part: part) != nil
            || OpenClientVisualChartActivity(part: part) != nil
            || OpenClientVisualHTMLActivity(part: part) != nil
            || OpenClientVisualImageActivity(part: part) != nil
            || OpenClientVisualVideoActivity(part: part) != nil
    }

    private var unknownStreamingPartStyle: ActivityStyle {
        ActivityStyle(
            title: .localized("Thinking"),
            subtitle: nil,
            icon: "sparkles",
            tint: .secondary,
            isRunning: true,
            showsDisclosure: false,
            shimmerTitle: false
        )
    }

    private var knownSilentStreamingPartTypes: Set<String> {
        ["", "text", "reasoning", "step-start", "step-finish"]
    }

    private func isStreamingTextPart(_ part: OpenCodePart, index: Int) -> Bool {
        guard isStreamingMessage, !isUser, textStyle(for: part) == .standard else {
            return false
        }

        return index == latestRenderableStandardTextPartIndex
            && index == latestVisiblePartIndex
    }

    private func isActiveRevealPart(at index: Int, part: OpenCodePart) -> Bool {
        isStreamingTextPart(part, index: index)
    }

    private var latestRenderableStandardTextPartIndex: Int? {
        effectiveMessage.parts.indices.last { index in
            let part = effectiveMessage.parts[index]
            return textStyle(for: part) == .standard && renderableText(for: part) != nil
        }
    }

    private var latestVisiblePartIndex: Int? {
        effectiveMessage.parts.indices.last { index in
            let part = effectiveMessage.parts[index]
            if hidesReasoningBlocks, textStyle(for: part) == .reasoning {
                return false
            }
            return shouldIncludePartInDisplayPlan(part)
        }
    }

    private func contextGroupView(_ group: ContextGroup, isActiveRevealPart: Bool) -> some View {
        let isExpanded = expandedContextGroupIDs.contains(group.id)
        let summary = contextSummary(for: group.parts)
        let running = isStreamingMessage || group.parts.contains { isRunning($0.part) }
        let title: ActivityText = running
            ? .localized(LocalizedStringResource("Exploring"))
            : .localized(LocalizedStringResource("Explored"))
        let subtitle = contextSummaryText(summary)

        return VStack(alignment: .leading, spacing: MessageBubbleSpacing.part) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    onToggleContextGroup(group.id)
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
                VStack(alignment: .leading, spacing: MessageBubbleSpacing.part) {
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
            .padding(.leading, 8)
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: isExpanded)
    }

    private func bubbleWrapped<Content: View>(_ content: Content) -> some View {
        content
            .padding(.leading, 14)
            .padding(.trailing, isUser ? 22 : 14)
            .padding(.vertical, 10)
            .background {
                bubbleShape.fill(bubbleColor)
            }
            .frame(maxWidth: userBubbleMaximumWidth, alignment: .trailing)
    }

    private func renderableText(for part: OpenCodePart) -> String? {
        MessageBubblePartVisibilityPolicy.renderableText(for: part, isUser: isUser)
    }

    private func todoWriteTitle(for part: OpenCodePart, running: Bool) -> ActivityText {
        if running {
            return .localized("Updating Todos")
        }

        if let count = todoWriteTodos(for: part)?.count, count > 0 {
            return count == 1
                ? .localized(LocalizedStringResource("1 task"))
                : .localized(LocalizedStringResource("\(count) tasks"))
        }

        let title = part.state?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty {
            switch title.lowercased() {
            case "todo", "todos", "todowrite", "todo update":
                return .localized(LocalizedStringResource("Tasks"))
            default:
                break
            }
            return .verbatim(title)
        }

        return .localized("Todo Update")
    }

    private func todoWriteSubtitle(for part: OpenCodePart) -> ActivityText? {
        guard let todos = todoWriteTodos(for: part), !todos.isEmpty else {
            guard let status = part.state?.status?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return .verbatim(status)
        }

        let completed = todos.filter { $0.isComplete }.count
        let inProgress = todos.filter { $0.isInProgress }.count
        let pending = todos.count - completed - inProgress

        var segments: [String] = []
        if completed > 0 {
            segments.append(String(localized: "\(completed) completed"))
        }
        if inProgress > 0 {
            segments.append(String(localized: "\(inProgress) in progress"))
        }
        if pending > 0 {
            segments.append(String(localized: "\(pending) pending"))
        }

        guard !segments.isEmpty else { return nil }
        return .verbatim(segments.formatted())
    }

    private func todoWriteTodos(for part: OpenCodePart) -> [OpenCodeTodo]? {
        guard let output = part.state?.output,
              let data = output.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode([OpenCodeTodo].self, from: data)
    }

    private func textStyle(for part: OpenCodePart) -> MarkdownMessageText.Style {
        if !isUser, isReasoningPart(part) {
            return .reasoning
        }
        return .standard
    }

    private func isReasoningPart(_ part: OpenCodePart) -> Bool {
        MessageBubblePartVisibilityPolicy.isReasoningPart(part)
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
        if let partID = part.id {
            return "\(effectiveMessage.id)-reasoning-\(partID)"
        }

        return "\(effectiveMessage.id)-reasoning-\(index)"
    }

    private func isReasoningExpanded(part: OpenCodePart, index: Int) -> Bool {
        expandedReasoningPartIDs.contains(reasoningPartID(part: part, index: index))
    }

    private func toggleReasoning(part: OpenCodePart, index: Int) {
        onToggleReasoningPart(reasoningPartID(part: part, index: index))
    }

    private func isReasoningRunning(_ part: OpenCodePart) -> Bool {
        isRunning(part) || isStreamingMessage
    }

    private func isProtectedFromActivityBudget(
        _ entry: DisplayEntry,
        retainedVisualHTMLPartIDs: Set<String>
    ) -> Bool {
        switch entry {
        case .answer:
            return true
        case let .part(indexed):
            let part = indexed.part
            if attachment(for: part) != nil { return true }
            if OpenClientVisualImageActivity(part: part) != nil { return true }
            if OpenClientVisualVideoActivity(part: part) != nil { return true }
            if OpenClientVisualMapActivity(part: part) != nil { return true }
            if OpenClientVisualChartActivity(part: part) != nil { return true }
            if isVisualHTMLPart(part),
               shouldRenderVisualHTML(
                   part: part,
                   index: indexed.index,
                   retainedVisualHTMLPartIDs: retainedVisualHTMLPartIDs
               ) {
                return isRunning(part)
            }
            if activityStyle(for: part) != nil { return isRunning(part) }
            guard renderableText(for: part) != nil else {
                return shouldShowUnknownStreamingPartPlaceholder(part)
            }
            if textStyle(for: part) == .standard { return true }
            return isReasoningRunning(part) || isReasoningExpanded(part: part, index: indexed.index)
        case let .context(group):
            return expandedContextGroupIDs.contains(group.id) || group.parts.contains { isRunning($0.part) }
        case .earlierActivity:
            return true
        }
    }

    private func displayEntryCachePartKey(for part: OpenCodePart) -> MessageBubbleDisplayEntryCacheKey.PartKey {
        MessageBubbleDisplayEntryCacheKey.PartKey(
            id: part.id,
            type: part.type,
            toolName: toolName(for: part),
            hasRenderableText: renderableText(for: part) != nil,
            synthetic: part.synthetic
        )
    }

    private func makeDisplayEntryPlan(from parts: [OpenCodePart]) -> [MessageBubbleDisplayEntryPlan] {
        var result: [MessageBubbleDisplayEntryPlan] = []
        var contextIndices: [Int] = []

        func flushContextParts() {
            guard !contextIndices.isEmpty else { return }
            let firstIndex = contextIndices[0]
            let id = MessageBubbleDisplayIdentity.contextID(
                messageID: effectiveMessage.id,
                firstIndex: firstIndex,
                firstPart: parts[firstIndex]
            )
            result.append(.context(id: id, indices: contextIndices))
            contextIndices.removeAll(keepingCapacity: true)
        }

        for (index, part) in parts.enumerated() {
            if isUser, !MessageBubbleUserPartPolicy.shouldDisplay(part, at: index, in: parts) {
                continue
            }
            guard shouldIncludePartInDisplayPlan(part) else { continue }

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

    private func shouldIncludePartInDisplayPlan(_ part: OpenCodePart) -> Bool {
        guard MessageBubblePartVisibilityPolicy.shouldDisplay(
            part,
            showsToolCalls: showsToolCalls,
            showsReasoningBlocks: !hidesReasoningBlocks
        ) else { return false }
        if renderableText(for: part) != nil { return true }
        if activityStyle(for: part) != nil { return true }
        if shouldShowUnknownStreamingPartPlaceholder(part) { return true }
        return false
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
        MessageBubbleDisplayIdentity.partID(index: index, part: part)
    }

    private var retainedVisualHTMLPartIDs: Set<String> {
        let visualIDs: [String] = effectiveMessage.parts.enumerated().compactMap { item -> String? in
            let (index, part) = item
            guard isVisualHTMLPart(part) else { return nil }
            return displayEntryPartID(index: index, part: part)
        }
        return Set(visualIDs.suffix(2))
    }

    private func isVisualHTMLPart(_ part: OpenCodePart) -> Bool {
        part.type == "tool"
            && part.tool == "openclient_execute_tool"
            && part.state?.input?.toolID == OpenClientVisualHTMLContract.toolID
    }

    private func shouldRenderVisualHTML(
        part: OpenCodePart,
        index: Int,
        retainedVisualHTMLPartIDs: Set<String>
    ) -> Bool {
        retainedVisualHTMLPartIDs.contains(displayEntryPartID(index: index, part: part))
    }

    private func shouldGroupInContext(_ part: OpenCodePart) -> Bool {
        !isUser && renderableText(for: part) == nil && contextGroupTools.contains(toolName(for: part))
    }

    private func handleActivityTap(for part: OpenCodePart) {
        if let currentSessionID,
           let sessionID = resolveTaskSessionID(for: part, currentSessionID: currentSessionID) {
            onOpenTaskSession(sessionID)
            return
        }

        onSelectPart(part)
    }

    private func activityStyle(for part: OpenCodePart) -> ActivityStyle? {
        let tool = toolName(for: part)
        let running = OpenCodeToolActivityPolicy.isRunning(part)
        let appearance = OpenCodeToolActivityAppearance.resolve(tool)

        switch tool {
        case "", "agent", "step-start", "step-finish", "reasoning", "text":
            return nil
        case "todowrite":
            return ActivityStyle(
                title: todoWriteTitle(for: part, running: running),
                subtitle: todoWriteSubtitle(for: part),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "bash":
            return ActivityStyle(
                title: .localized("Shell"),
                subtitle: running ? nil : verbatimActivityText(firstNonEmpty(part.state?.input?.description, toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "read":
            return ActivityStyle(
                title: .localized("Read"),
                subtitle: verbatimActivityText(firstNonEmpty(filename(from: part.state?.input?.filePath), filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "list":
            return ActivityStyle(
                title: .localized("List"),
                subtitle: verbatimActivityText(firstNonEmpty(filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "glob":
            return ActivityStyle(
                title: .localized("Glob"),
                subtitle: verbatimActivityText(firstNonEmpty(part.state?.input?.pattern, filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "grep":
            return ActivityStyle(
                title: .localized("Grep"),
                subtitle: verbatimActivityText(firstNonEmpty(part.state?.input?.pattern, filename(from: part.state?.input?.path), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "webfetch":
            return ActivityStyle(
                title: .localized("Webfetch"),
                subtitle: running ? nil : verbatimActivityText(firstNonEmpty(part.state?.input?.url, toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "websearch":
            return ActivityStyle(
                title: .localized("Web Search"),
                subtitle: verbatimActivityText(firstNonEmpty(part.state?.input?.query, toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "codesearch":
            return ActivityStyle(
                title: .localized("Code Search"),
                subtitle: verbatimActivityText(firstNonEmpty(part.state?.input?.query, toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "task", "subagent":
            let agent = taskAgentTitle(for: part)
            let subtitle = firstNonEmpty(part.state?.input?.description, resolveTaskSessionID(for: part, currentSessionID: currentSessionID ?? ""), toolSubtitle(for: part, fallback: nil))
            return ActivityStyle(
                title: agent,
                subtitle: verbatimActivityText(subtitle),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "edit":
            return ActivityStyle(
                title: .localized("Edit"),
                subtitle: verbatimActivityText(firstNonEmpty(filename(from: part.state?.input?.filePath), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "write":
            return ActivityStyle(
                title: .localized("Write"),
                subtitle: verbatimActivityText(firstNonEmpty(filename(from: part.state?.input?.filePath), toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "apply_patch":
            let count = part.state?.metadata?.files?.count
            let fileSummary = count.map {
                $0 == 1 ? ActivityText.localized("1 file") : ActivityText.localized("\($0) files")
            }
            return ActivityStyle(
                title: .localized("Patch"),
                subtitle: fileSummary ?? verbatimActivityText(toolSubtitle(for: part, fallback: nil)),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "question":
            return ActivityStyle(
                title: .localized("Questions"),
                subtitle: verbatimActivityText(toolSubtitle(for: part, fallback: nil)),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "skill":
            return ActivityStyle(
                title: part.state?.input?.name?.nilIfEmpty.map(ActivityText.verbatim) ?? .localized("Skill"),
                subtitle: verbatimActivityText(toolSubtitle(for: part, fallback: nil)),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        case "mcp":
            return ActivityStyle(
                title: part.state?.title?.nilIfEmpty.map(ActivityText.verbatim) ?? .localized("MCP"),
                subtitle: verbatimActivityText(toolSubtitle(for: part, fallback: nil)),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        default:
            let title = firstNonEmpty(part.state?.title, displayTitle(for: tool, fallback: part.type))
            return ActivityStyle(
                title: title.map(ActivityText.verbatim) ?? .localized("Tool"),
                subtitle: verbatimActivityText(firstNonEmpty(part.state?.input?.description, toolSubtitle(for: part, fallback: nil))),
                icon: appearance.icon,
                tint: appearance.tint,
                isRunning: running,
                showsDisclosure: true,
                shimmerTitle: false
            )
        }
    }

    private func toolName(for part: OpenCodePart) -> String {
        OpenCodeToolActivityPolicy.toolName(for: part)
    }

    private func filename(from path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    private func taskAgentTitle(for part: OpenCodePart) -> ActivityText {
        let trimmed = part.state?.input?.subagentType?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        guard let first = trimmed.first else {
            return .localized("Agent")
        }

        let value = String(first).uppercased() + String(trimmed.dropFirst())
        return .localized("\(value) Agent")
    }

    private func resolveTaskSessionID(for part: OpenCodePart, currentSessionID: String) -> String? {
        MessageBubbleTaskNavigation.sessionID(
            for: part, currentSessionID: currentSessionID, resolveLegacyTask: resolveTaskSessionID
        )
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

    private func contextSummaryText(_ summary: ContextSummary) -> ActivityText? {
        var items: [String] = []
        if summary.reads > 0 {
            items.append(summary.reads == 1 ? String(localized: "1 read") : String(localized: "\(summary.reads) reads"))
        }
        if summary.searches > 0 {
            items.append(summary.searches == 1 ? String(localized: "1 search") : String(localized: "\(summary.searches) searches"))
        }
        if summary.lists > 0 {
            items.append(summary.lists == 1 ? String(localized: "1 list") : String(localized: "\(summary.lists) lists"))
        }
        return items.isEmpty ? nil : .verbatim(items.formatted())
    }

    private func verbatimActivityText(_ value: String?) -> ActivityText? {
        value.map(ActivityText.verbatim)
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
                return String(localized: "Completed")
            case "error", "failed":
                return String(localized: "Error")
            case "running", "pending", "in_progress":
                return String(localized: "Running")
            default:
                return status.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        if let reason = part.reason {
            switch reason.lowercased() {
            case "stop", "finish", "finished", "complete", "completed":
                return String(localized: "Completed")
            case "start", "started", "running":
                return String(localized: "Running")
            default:
                return reason.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }

        return fallback
    }

    private func isRunning(_ part: OpenCodePart) -> Bool {
        OpenCodeToolActivityPolicy.isRunning(part)
    }
}

private let contextGroupTools: Set<String> = ["read", "glob", "grep", "list"]

private struct IndexedPart: Identifiable {
    let index: Int
    let part: OpenCodePart

    var id: String {
        MessageBubbleDisplayIdentity.partID(index: index, part: part)
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

private struct MessageBubbleShape: Shape {
    let isOutgoing: Bool
    let cornerRadius: CGFloat

    private let tailWidth: CGFloat = 11
    private let tailHeight: CGFloat = 13

    func path(in rect: CGRect) -> Path {
        guard isOutgoing else {
            return Path(roundedRect: rect, cornerRadius: cornerRadius)
        }

        let bubbleMaxX = rect.maxX - tailWidth
        let minX = rect.minX
        let maxY = rect.maxY
        let radius = min(cornerRadius, rect.height / 2, (rect.width - tailWidth) / 2)
        let tailStartY = maxY - tailHeight - 3
        let tailTip = CGPoint(x: rect.maxX - 1, y: maxY - 1)
        let tailReturn = CGPoint(x: bubbleMaxX - 14, y: maxY)

        var path = Path()
        path.move(to: CGPoint(x: minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: bubbleMaxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bubbleMaxX, y: rect.minY + radius),
            control: CGPoint(x: bubbleMaxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: bubbleMaxX, y: tailStartY))
        path.addCurve(
            to: tailTip,
            control1: CGPoint(x: bubbleMaxX + 0.5, y: maxY - 11),
            control2: CGPoint(x: bubbleMaxX + 8.5, y: maxY - 5.5)
        )
        path.addCurve(
            to: tailReturn,
            control1: CGPoint(x: bubbleMaxX + 5, y: maxY + 1),
            control2: CGPoint(x: bubbleMaxX - 4, y: maxY + 1)
        )
        path.addLine(to: CGPoint(x: minX + radius, y: maxY))
        path.addQuadCurve(
            to: CGPoint(x: minX, y: maxY - radius),
            control: CGPoint(x: minX, y: maxY)
        )
        path.addLine(to: CGPoint(x: minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: minX + radius, y: rect.minY),
            control: CGPoint(x: minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct MessageBubbleDisplayEntryCacheKey: Equatable {
    struct PartKey: Equatable {
        let id: String?
        let type: String
        let toolName: String
        let hasRenderableText: Bool
        let synthetic: Bool?
    }

    let messageID: String
    let isUser: Bool
    let showsToolCalls: Bool
    let hidesReasoningBlocks: Bool
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
    case answer([IndexedPart])
    case context(ContextGroup)
    case earlierActivity(hiddenCount: Int)

    var id: String {
        switch self {
        case let .answer(parts):
            return "answer-\(parts.first?.id ?? "")"
        case let .part(indexed):
            return indexed.id
        case let .context(group):
            return group.id
        case .earlierActivity:
            return "earlier-activity"
        }
    }
}

private struct ToolCallEntryModifier: ViewModifier {
    let isEnabled: Bool
    let entryID: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible: Bool

    @MainActor
    init(isEnabled: Bool, entryID: String) {
        self.isEnabled = isEnabled
        self.entryID = entryID
        _isVisible = State(initialValue: !isEnabled || ChatEntryAnimationRegistry.shared.hasSeen(entryID))
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || !isEnabled ? 1 : 0)
            .scaleEffect(isVisible || !isEnabled ? 1 : 0.96, anchor: .topLeading)
            .offset(y: isVisible || !isEnabled ? 0 : 10)
            .onAppear {
                guard isEnabled else {
                    isVisible = true
                    return
                }

                let shouldAnimate = ChatEntryAnimationRegistry.shared.markSeen(entryID)
                guard shouldAnimate, !reduceMotion else {
                    isVisible = true
                    return
                }

                withAnimation(.snappy(duration: 0.38, extraBounce: 0.12)) {
                    isVisible = true
                }
            }
            .onChange(of: reduceMotion) { _, reduceMotion in
                guard reduceMotion else { return }
                isVisible = true
            }
    }
}

@MainActor
private final class ChatEntryAnimationRegistry {
    static let shared = ChatEntryAnimationRegistry()

    private var seenIDs: Set<String> = []
    private var insertionOrder: [String] = []

    func hasSeen(_ id: String) -> Bool {
        seenIDs.contains(id)
    }

    func markSeen(_ id: String) -> Bool {
        guard seenIDs.insert(id).inserted else { return false }
        insertionOrder.append(id)
        if insertionOrder.count > 800 {
            let expired = Array(insertionOrder.prefix(200))
            seenIDs.subtract(expired)
            insertionOrder.removeFirst(expired.count)
        }
        return true
    }
}

private struct ReasoningBlockEntryModifier: ViewModifier {
    let isEnabled: Bool
    let entryID: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible: Bool

    @MainActor
    init(isEnabled: Bool, entryID: String) {
        self.isEnabled = isEnabled
        self.entryID = entryID
        _isVisible = State(initialValue: !isEnabled || ChatEntryAnimationRegistry.shared.hasSeen(entryID))
    }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible || !isEnabled ? 1 : 0)
            .scaleEffect(isVisible || !isEnabled ? 1 : 0.975, anchor: .topLeading)
            .offset(y: isVisible || !isEnabled ? 0 : 8)
            .onAppear {
                guard isEnabled else {
                    isVisible = true
                    return
                }

                let shouldAnimate = ChatEntryAnimationRegistry.shared.markSeen(entryID)
                guard shouldAnimate, !reduceMotion else {
                    isVisible = true
                    return
                }

                withAnimation(.snappy(duration: 0.34, extraBounce: 0.08)) {
                    isVisible = true
                }
            }
            .onChange(of: reduceMotion) { _, reduceMotion in
                guard reduceMotion else { return }
                isVisible = true
            }
    }
}

struct StreamingTurnBottomGradient: View {
    @Environment(\.colorScheme) private var colorScheme
    private let height: CGFloat = 52
    private let visualWidth: CGFloat = 4096

    var body: some View {
        let background = OpenCodePlatformColor.chatCanvasBackground(for: colorScheme)
        LinearGradient(
            stops: [
                .init(color: background.opacity(0), location: 0),
                .init(color: background.opacity(0.78), location: 0.48),
                .init(color: background.opacity(0.98), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .frame(width: visualWidth)
    }
}

enum OpenCodeActivityTint {
    private static let fallbackPalette: [Color] = [
        agentAsk,
        agentBuild,
        agentDocs,
        agentPlan,
        Color(hue: 0.53, saturation: 0.34, brightness: 0.88),
        Color(hue: 0.36, saturation: 0.34, brightness: 0.86),
        Color(hue: 0.10, saturation: 0.38, brightness: 0.92),
        Color(hue: 0.56, saturation: 0.34, brightness: 0.88),
        Color(hue: 0.09, saturation: 0.34, brightness: 0.90),
        Color(hue: 0.39, saturation: 0.32, brightness: 0.86),
        Color(hue: 0.98, saturation: 0.34, brightness: 0.88),
        Color(hue: 0.11, saturation: 0.38, brightness: 0.92)
    ]

    private static let agentAsk = Color(hue: 0.59, saturation: 0.36, brightness: 0.92)
    private static let agentBuild = Color(hue: 0.08, saturation: 0.38, brightness: 0.94)
    private static let agentDocs = Color(hue: 0.12, saturation: 0.38, brightness: 0.92)
    private static let agentPlan = Color(hue: 0.53, saturation: 0.34, brightness: 0.90)

    static func color(forAgent agent: String?) -> Color {
        guard let normalized = agent?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !normalized.isEmpty else {
            return agentBuild
        }

        switch normalized {
        case "ask":
            return agentAsk
        case "build":
            return agentBuild
        case "docs":
            return agentDocs
        case "plan", "planner":
            return agentPlan
        default:
            return fallbackPalette[stableIndex(for: normalized, count: fallbackPalette.count)]
        }
    }

    private static func stableIndex(for value: String, count: Int) -> Int {
        var hash: UInt32 = 0
        for scalar in value.unicodeScalars {
            hash = hash &* 31 &+ UInt32(scalar.value)
        }
        return Int(hash % UInt32(count))
    }
}

private struct ContextToolGroupCard: View {
    let style: ActivityStyle
    let expanded: Bool

    var body: some View {
        ActivityRow(
            style: ActivityStyle(
                title: style.title,
                subtitle: style.subtitle,
                icon: style.icon,
                tint: style.tint,
                isRunning: style.isRunning,
                showsDisclosure: false,
                shimmerTitle: style.shimmerTitle
            ),
            trailingAccessoryInset: 14
        )
        .overlay(alignment: .trailing) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 12)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.55))
                    .offset(x: 6, y: 8)

                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.8))
                    .offset(x: 3, y: 4)
            }
        }
        .padding(.trailing, 6)
        .padding(.bottom, 0)
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

    private var displayTitle: String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))

                if let displayTitle {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Text("Error")
                        .font(.subheadline.weight(.semibold))
                }
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
