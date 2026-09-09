import SwiftUI

enum ActivityText: ExpressibleByStringLiteral {
    case localized(LocalizedStringResource)
    case verbatim(String)

    var text: Text {
        switch self {
        case .localized(let resource):
            Text(resource)
        case .verbatim(let value):
            Text(value)
        }
    }

    init(stringLiteral value: String) {
        self = .verbatim(value)
    }
}

struct ActivityStyle {
    let title: ActivityText
    let subtitle: ActivityText?
    let icon: String
    let tint: Color
    let isRunning: Bool
    let showsDisclosure: Bool
    let shimmerTitle: Bool

    init(
        title: ActivityText,
        subtitle: ActivityText?,
        icon: String,
        tint: Color,
        isRunning: Bool,
        showsDisclosure: Bool,
        shimmerTitle: Bool
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.isRunning = isRunning
        self.showsDisclosure = showsDisclosure
        self.shimmerTitle = shimmerTitle
    }

}

struct OpenCodeToolActivityAppearance {
    let icon: String
    let tint: Color

    static func resolve(_ tool: String) -> OpenCodeToolActivityAppearance {
        switch tool.lowercased() {
        case "todowrite", "todo_write":
            return OpenCodeToolActivityAppearance(icon: "checklist", tint: .blue)
        case "bash", "shell":
            return OpenCodeToolActivityAppearance(icon: "terminal.fill", tint: .green)
        case "read":
            return OpenCodeToolActivityAppearance(icon: "eyeglasses", tint: .blue)
        case "list":
            return OpenCodeToolActivityAppearance(icon: "list.bullet", tint: .indigo)
        case "glob":
            return OpenCodeToolActivityAppearance(icon: "magnifyingglass", tint: .teal)
        case "grep":
            return OpenCodeToolActivityAppearance(icon: "magnifyingglass.circle", tint: .mint)
        case "webfetch", "web_fetch":
            return OpenCodeToolActivityAppearance(icon: "network", tint: .teal)
        case "websearch", "web_search":
            return OpenCodeToolActivityAppearance(icon: "globe", tint: .teal)
        case "codesearch", "code_search":
            return OpenCodeToolActivityAppearance(icon: "chevron.left.forwardslash.chevron.right", tint: .purple)
        case "task", "subagent":
            return OpenCodeToolActivityAppearance(icon: "square.stack.3d.up.fill", tint: .purple)
        case "edit", "write":
            return OpenCodeToolActivityAppearance(icon: "square.and.pencil", tint: .orange)
        case "apply_patch":
            return OpenCodeToolActivityAppearance(icon: "hammer.fill", tint: .orange)
        case "question":
            return OpenCodeToolActivityAppearance(icon: "questionmark.bubble", tint: .blue)
        case "skill":
            return OpenCodeToolActivityAppearance(icon: "brain", tint: .indigo)
        case "mcp":
            return OpenCodeToolActivityAppearance(icon: "point.3.connected.trianglepath.dotted", tint: .pink)
        default:
            return OpenCodeToolActivityAppearance(icon: "wrench.and.screwdriver.fill", tint: .secondary)
        }
    }
}

enum OpenCodeToolActivityPolicy {
    private static let nonToolPartNames: Set<String> = [
        "", "agent", "file", "reasoning", "step-start", "step-finish", "text",
    ]

    static func toolName(for part: OpenCodePart) -> String {
        if part.type == "tool" {
            return part.tool ?? ""
        }
        return part.tool ?? part.type
    }

    static func isToolCall(_ part: OpenCodePart) -> Bool {
        !nonToolPartNames.contains(toolName(for: part).lowercased())
    }

    static func isRunning(_ part: OpenCodePart) -> Bool {
        if let status = part.state?.status?.lowercased() {
            return status == "running" || status == "pending" || status == "in_progress"
        }
        guard let reason = part.reason?.lowercased() else { return false }
        return reason == "start" || reason == "started" || reason == "running"
    }

    static func latestRunningToolName(in message: OpenCodeMessageEnvelope) -> String? {
        message.parts.reversed().first(where: { part in
            isToolCall(part) && isRunning(part)
        }).map { toolName(for: $0) }
    }
}

struct ActivityRow: View {
    let style: ActivityStyle
    var compact: Bool = false
    var trailingAccessoryInset: CGFloat = 0
    var reservesSubtitleSpace = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: compact ? 13 : 14, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                .background(style.tint.opacity(compact ? 0.12 : 0.14), in: RoundedRectangle(cornerRadius: compact ? 7 : 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                ShimmeringText(text: style.title, active: style.shimmerTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = style.subtitle {
                    subtitle.text
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else if reservesSubtitleSpace {
                    Text("Reserved")
                        .font(.caption)
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .layoutPriority(1)

            Spacer()

            if style.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(style.tint)
            } else if style.showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            if trailingAccessoryInset > 0 {
                Color.clear
                    .frame(width: trailingAccessoryInset)
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 8 : 10)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ShimmeringText: View {
    let text: ActivityText
    let active: Bool

    @State private var phase: CGFloat = -1

    var body: some View {
        text.text
            .foregroundStyle(.primary)
            .overlay {
                if active {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.8), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: geometry.size.width * 0.85)
                        .offset(x: geometry.size.width * phase)
                        .blendMode(.plusLighter)
                    }
                    .mask(text.text)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard active else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    phase = 1.3
                }
            }
            .onChange(of: active) { _, isActive in
                if isActive {
                    phase = -1
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        phase = 1.3
                    }
                } else {
                    phase = -1
                }
            }
    }
}
