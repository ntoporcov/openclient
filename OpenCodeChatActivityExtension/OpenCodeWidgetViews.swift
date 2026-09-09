import SwiftUI
import WidgetKit

struct OpenCodeSessionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OpenCodeSessionsWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemLarge:
                largeDashboard
            default:
                mediumCard
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var mediumCard: some View {
        Group {
            if let session = entry.mediumSession {
                Link(destination: openURL(for: session)) {
                    OpenCodeWidgetHeroSessionCard(session: session)
                }
                .buttonStyle(.plain)
            } else {
                OpenCodeWidgetEmptyState(title: entry.title, subtitle: "Open the app to sync sessions.")
            }
        }
        .padding(0)
    }

    private var largeDashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.headline.weight(.semibold))
                    if let serverName = entry.serverName, !serverName.isEmpty {
                        Text(serverName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            if entry.largeSessions.isEmpty {
                OpenCodeWidgetEmptyState(title: "No Sessions", subtitle: "Open the app to sync recent activity.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    ForEach(entry.largeSessions, id: \.entityID) { session in
                        Link(destination: openURL(for: session)) {
                            OpenCodeWidgetSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(0)
    }

    private func openURL(for session: OpenCodeWidgetSessionSnapshot) -> URL {
        OpenCodeWidgetDeepLink.sessionURL(session) ?? URL(string: "openclient://widget")!
    }
}

private struct OpenCodeWidgetHeroSessionCard: View {
    let session: OpenCodeWidgetSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                OpenCodeWidgetAvatar(title: session.title, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.projectLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                OpenCodeWidgetStatusChip(status: session.status)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(session.summaryKind.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(session.summaryText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(4)
                    .lineSpacing(2)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)

            if let updatedAt = session.updatedAt {
                Text(updatedAt, style: .relative)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OpenCodeWidgetSessionRow: View {
    let session: OpenCodeWidgetSessionSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            OpenCodeWidgetAvatar(title: session.title, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(session.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let updatedAt = session.updatedAt {
                    Text(updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            OpenCodeWidgetStatusDot(status: session.status)
                .padding(.top, 5)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

private struct OpenCodeWidgetEmptyState: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OpenCodeWidgetAvatar: View {
    let title: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
            .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
    }

    private var initials: String {
        let words = title.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" }).prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "OC" : letters.joined()
    }

    private var palette: [Color] {
        let palettes: [[Color]] = [
            [.blue, .purple],
            [.pink, .orange],
            [.teal, .blue],
            [.indigo, .mint],
            [.orange, .red],
            [.green, .teal],
        ]
        return palettes[Int(opencodeStableHash(title) % UInt64(palettes.count))]
    }
}

private struct OpenCodeWidgetStatusChip: View {
    let status: OpenCodeWidgetSessionStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.10), in: Capsule())
    }

    private var color: Color { statusColor(status) }
}


private struct OpenCodeWidgetStatusDot: View {
    let status: OpenCodeWidgetSessionStatus

    var body: some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }
}

private func statusColor(_ status: OpenCodeWidgetSessionStatus) -> Color {
    switch status {
    case .needsAction:
        return .orange
    case .working:
        return .green
    case .ready:
        return .blue
    case .watching:
        return .white.opacity(0.7)
    }
}
