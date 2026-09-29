import SwiftUI

struct TimelineContextBlock: View {
    let kind: OpenCodeTimelineContextType
    let text: String
    var contextTitle: String? = nil
    @State private var isExpanded = false

    private var title: LocalizedStringResource {
        switch kind {
        case .synthetic: "Context"
        case .system: "Context updated"
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
        Button { isExpanded = true } label: {
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
                HStack(spacing: 8) {
                    Image(systemName: icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption.weight(.semibold))
                        Text(verbatim: contextTitle ?? String(text.prefix(120)).components(separatedBy: .newlines).first ?? text)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay { Capsule().stroke(Color.secondary.opacity(0.14), lineWidth: 1) }
                .layoutPriority(1)
                Rectangle().fill(Color.secondary.opacity(0.22)).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.context.\(kind.rawValue)")
        .sheet(isPresented: $isExpanded) {
            NavigationStack {
                ScrollView {
                    MarkdownMessageText(text: text, isUser: false, style: .standard)
                        .textSelection(.enabled)
                        .padding(20)
                }
                .navigationTitle(Text(title))
                .opencodeInlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isExpanded = false }
                    }
                }
            }
        }
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
