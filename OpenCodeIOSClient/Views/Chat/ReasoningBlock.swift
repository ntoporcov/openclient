import SwiftUI

enum TimelineContextLabel {
    static func filePath(text: String, description: String?) -> String? {
        for value in [description, text].compactMap({ $0 }) {
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? ""
            for prefix in ["Instructions from: ", "Loaded file: ", "Loaded "] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("./") || path.hasPrefix("../")
                    || (!path.contains(" ") && !(path as NSString).pathExtension.isEmpty) {
                    return path
                }
            }
        }
        return nil
    }
}

struct TimelineContextBlock: View {
    let kind: OpenCodeTimelineContextType
    let text: String
    var model: OpenCodeMessageModelReference? = nil
    var contextDescription: String? = nil
    @State private var isExpanded = false

    private var title: LocalizedStringResource {
        switch kind {
        case .synthetic, .system: "Context"
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

    private var tint: Color {
        switch kind {
        case .synthetic: .purple
        case .system: .indigo
        case .skill: .teal
        case .agentSwitched: .orange
        case .modelSwitched: .blue
        case .locationSwitched: .green
        }
    }

    private var cardTitle: ActivityText {
        if kind == .modelSwitched { return .verbatim(model?.modelID ?? text) }
        if (kind == .synthetic || kind == .system),
           let path = TimelineContextLabel.filePath(text: text, description: contextDescription) {
            return .verbatim(path)
        }
        return .localized(title)
    }

    var body: some View {
        Button { isExpanded = true } label: {
            ActivityRow(
                style: ActivityStyle(title: cardTitle, subtitle: nil, icon: icon, tint: tint,
                                     isRunning: false, showsDisclosure: true, shimmerTitle: false),
                providerID: kind == .modelSwitched ? model?.providerID : nil,
                titleLineLimit: 1,
                titleTruncationMode: .head
            )
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
