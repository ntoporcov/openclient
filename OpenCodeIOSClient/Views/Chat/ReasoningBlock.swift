import SwiftUI

struct ReasoningBlock: View {
    let text: String
    let isExpanded: Bool
    let isRunning: Bool
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

                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                MarkdownMessageText(text: text, isUser: false, style: .reasoning)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
