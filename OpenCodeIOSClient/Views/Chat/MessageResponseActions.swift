import SwiftUI
import Observation

enum AssistantResponseCopy {
    static func markdown(in message: OpenCodeMessageEnvelope) -> String? {
        let text = markdownParts(in: message).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func markdownParts(in message: OpenCodeMessageEnvelope) -> [String] {
        // Copy the answer represented by this row, never reasoning, tools, or errors.
        message.parts
            .filter {
                $0.type == "text" && $0.synthetic != true
                    && !MessageBubblePartVisibilityPolicy.isReasoningPart($0)
            }
            .compactMap(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { $0.trimmingCharacters(in: .newlines) }
    }

    @MainActor
    static func plainText(parts: [String]) -> String {
        parts.map { MarkdownMessageText.plainText(from: $0) }.joined(separator: "\n\n")
    }
}

enum ResponseCompletionTime {
    static func date(message: OpenCodeMessageEnvelope, parts: [OpenCodePart]) -> Date? {
        parts.compactMap { date(timestamp: $0.time?.end) }.max()
            ?? date(timestamp: message.info.time?.completed)
    }

    private static func date(timestamp: Double?) -> Date? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        // Older saved transcripts and demo fixtures can use seconds rather than milliseconds.
        return Date(timeIntervalSince1970: timestamp > 100_000_000_000 ? timestamp / 1_000 : timestamp)
    }
}

@Observable @MainActor
final class ResponseActionsVisibility {
    var tappedMessageID: String?
}

struct AssistantResponseTurn: Identifiable, Hashable, Sendable {
    let id: String
    let messageIDs: [String]
    let anchorMessageID: String
    let markdownParts: [String]
    var markdown: String { markdownParts.joined(separator: "\n\n") }
    let completedAt: Date?
    let message: OpenCodeMessageEnvelope

    static func project(
        messages: [OpenCodeMessageEnvelope],
        displayedMessageIDs: Set<String>,
        isSessionBusy: Bool
    ) -> [AssistantResponseTurn] {
        var turns: [AssistantResponseTurn] = []
        var promptID: String?
        var assistants: [OpenCodeMessageEnvelope] = []

        func appendTurn() {
            guard let first = assistants.first,
                  let anchor = assistants.last(where: { displayedMessageIDs.contains($0.id) }) else { return }
            let answers: [(message: OpenCodeMessageEnvelope, parts: [String])] = assistants.compactMap { message in
                let parts = AssistantResponseCopy.markdownParts(in: message)
                return parts.isEmpty ? nil : (message: message, parts: parts)
            }
            guard let latestAnswer = answers.last else { return }

            let completedAt = assistants.compactMap { message in
                // A tool-only message can end the turn after the last answer text finishes.
                ResponseCompletionTime.date(message: message, parts: [])
                    ?? ResponseCompletionTime.date(message: message, parts: message.parts)
            }.max()
            turns.append(AssistantResponseTurn(
                id: promptID ?? first.id,
                messageIDs: assistants.map(\.id),
                anchorMessageID: anchor.id,
                markdownParts: answers.flatMap(\.parts),
                completedAt: completedAt,
                message: latestAnswer.message
            ))
        }

        for message in messages {
            guard !message.info.isCompactionSummary,
                  !message.parts.contains(where: \.isCompaction) else { continue }

            let role = (message.info.role ?? "").lowercased()
            if role == "user" {
                appendTurn()
                assistants.removeAll(keepingCapacity: true)
                promptID = message.id
                continue
            }
            guard role == "assistant" else { continue }

            // Parent IDs recover turn boundaries when the prompt is outside the loaded window.
            if let parentID = message.info.parentID {
                if let promptID, promptID != parentID {
                    appendTurn()
                    assistants.removeAll(keepingCapacity: true)
                }
                promptID = parentID
            }
            assistants.append(message)
        }

        // Earlier turns have already been closed by a later prompt, even while it is busy.
        if !isSessionBusy {
            appendTurn()
        }
        return turns
    }
}

struct ResponseTurnCaption<Details: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let turn: AssistantResponseTurn
    let visibility: ResponseActionsVisibility
    @ViewBuilder let details: () -> Details

    var body: some View {
        let showsActions = visibility.tappedMessageID.map { turn.messageIDs.contains($0) } ?? false
        Group {
            if showsActions {
                MessageResponseActions(
                    messageID: turn.id,
                    markdown: turn.markdown,
                    completedAt: turn.completedAt,
                    markdownParts: turn.markdownParts,
                    details: details
                )
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 4)))
            } else {
                Color.clear.accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: showsActions ? 44 : 0, alignment: .top)
        .clipped()
        .animation(reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.24), value: showsActions)
    }
}

struct ResponseTextContent: View {
    let messageID: String
    let markdownParts: [String]
    let onTextTap: () -> Void

    var body: some View {
#if canImport(UIKit)
        CompletedResponseText(markdownParts: markdownParts, onTextTap: onTextTap)
            .accessibilityIdentifier("chat.responseText.\(messageID)")
            .accessibilityAction(named: Text("Message Actions"), onTextTap)
#else
        MarkdownMessageText(text: markdownParts.joined(separator: "\n\n"), isUser: false, style: .standard)
            .onTapGesture(perform: onTextTap)
            .accessibilityIdentifier("chat.responseText.\(messageID)")
            .accessibilityAction(named: Text("Message Actions"), onTextTap)
#endif
    }
}

struct MessageResponseActions<Details: View>: View {
    let messageID: String
    let markdown: String?
    var completedAt: Date? = nil
    var markdownParts: [String]? = nil
    @ViewBuilder let details: () -> Details

    @State private var copyFeedbackID: UUID?
    @State private var showsSelection = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if let completedAt {
                Text(completedAt, format: .dateTime.hour().minute())
                    .monospacedDigit()
                    .accessibilityLabel(Text("Completed at \(completedAt.formatted(date: .omitted, time: .shortened))"))
                    .accessibilityIdentifier("chat.responseCompletedAt.\(messageID)")
                    .frame(height: 32)
                    .padding(.trailing, 8)
            }

            if markdown != nil {
                Button {
                    copy(plainText)
                } label: {
                    Label {
                        if copyFeedbackID != nil {
                            Text("Copied")
                        } else {
                            Text("Copy")
                        }
                    } icon: {
                        Image(systemName: copyFeedbackID == nil ? "doc.on.doc" : "checkmark")
                    }
                    .labelStyle(.iconOnly)
                    .modifier(ResponseCaptionControlLabel())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.copyResponse.\(messageID)")
            }

            Menu {
                if let markdown {
                    Button {
                        copy(markdown)
                    } label: {
                        Label("Copy as Markdown", systemImage: "doc.plaintext")
                    }
                    .accessibilityIdentifier("chat.copyResponseMarkdown")

                    Button {
                        showsSelection = true
                    } label: {
                        Label("Select Text", systemImage: "text.cursor")
                    }
                    .accessibilityIdentifier("chat.selectResponseText")

                    Divider()
                }
                details()
            } label: {
                Label("Message Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
                    .modifier(ResponseCaptionControlLabel())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.responseActions.\(messageID)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .textSelection(.disabled)
        .task(id: copyFeedbackID) {
            guard copyFeedbackID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                copyFeedbackID = nil
            } catch {}
        }
        .sheet(isPresented: $showsSelection) {
            ResponseTextSelectionSheet(text: plainText)
        }
    }

    private var plainText: String {
        AssistantResponseCopy.plainText(parts: markdownParts ?? [markdown ?? ""])
    }

    private func copy(_ text: String) {
        OpenCodeClipboard.copy(text)
        copyFeedbackID = UUID()
    }
}

private struct ResponseCaptionControlLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption2.weight(.semibold))
            .frame(width: 28, height: 28)
            .background {
                Circle().fill(.clear)
                    .opencodeGlassSurface(in: Circle())
                    .allowsHitTesting(false)
            }
            .padding(.top, 2)
            .frame(width: 44, height: 44, alignment: .top)
            .contentShape(Rectangle())
    }
}

private struct ResponseTextSelectionSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
#if canImport(UIKit)
                SelectableResponseText(text: text, isScrollEnabled: true)
#else
                ScrollView {
                    Text(verbatim: text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
#endif
            }
            .padding()
            .accessibilityIdentifier("chat.responseSelectionText")
            .navigationTitle("Select Text")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
