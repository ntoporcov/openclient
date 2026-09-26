import SwiftUI

struct TimelineContextBlock: View {
    let kind: OpenCodeTimelineContextType
    let text: String
    @State private var isExpanded = false

    private var title: LocalizedStringResource {
        switch kind {
        case .synthetic: "Context"
        case .system: "System"
        case .skill: "Skill"
        case .agentSwitched: "Agent changed"
        case .modelSwitched: "Model changed"
        case .locationSwitched: "Location changed"
        }
    }

    private var icon: String {
        switch kind {
        case .synthetic: "doc.text"
        case .system: "gearshape"
        case .skill: "brain"
        case .agentSwitched: "person.crop.circle"
        case .modelSwitched: "cpu"
        case .locationSwitched: "folder"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    Label { Text(title) } icon: { Image(systemName: icon) }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("chat.context.\(kind.rawValue)")

            if isExpanded {
                MarkdownMessageText(text: text, isUser: false, style: .reasoning)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ReasoningBlock: View {
    let text: String
    let isExpanded: Bool
    let isRunning: Bool
    var isActiveRevealPart = false
    var onRevealCompleted: (() -> Void)? = nil
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Label("Reasoning", systemImage: "brain.head.profile")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if isRunning || isActiveRevealPart {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownMessageText(
                    text: text,
                    isUser: false,
                    style: .reasoning,
                    isStreaming: isRunning || isActiveRevealPart,
                    onStreamingRevealCompleted: onRevealCompleted
                )
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
