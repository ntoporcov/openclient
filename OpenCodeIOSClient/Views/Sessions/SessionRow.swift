import SwiftUI

struct SessionRow: View, Equatable {
    enum Style {
        case regular
        case compact
    }

    let session: OpenCodeSession
    var isSelected = false
    var showsPinnedBadge = false
    var workspaceOverline: String?
    var style: Style = .regular
    var preview: SessionPreview?
    var isBusy = false
    var hasLiveActivity = false
    var hasDraft = false
    var hasPermissionRequest = false

    nonisolated static func == (lhs: SessionRow, rhs: SessionRow) -> Bool {
        lhs.session == rhs.session
            && lhs.isSelected == rhs.isSelected
            && lhs.showsPinnedBadge == rhs.showsPinnedBadge
            && lhs.workspaceOverline == rhs.workspaceOverline
            && lhs.style == rhs.style
            && lhs.preview == rhs.preview
            && lhs.isBusy == rhs.isBusy
            && lhs.hasLiveActivity == rhs.hasLiveActivity
            && lhs.hasDraft == rhs.hasDraft
            && lhs.hasPermissionRequest == rhs.hasPermissionRequest
    }

    var body: some View {
        Group {
            switch style {
            case .regular:
                regularContent
            case .compact:
                compactContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(rowBorder, lineWidth: isSelected ? 1.4 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: hasLiveActivity)
        .animation(opencodeSelectionAnimation, value: hasDraft)
        .animation(opencodeSelectionAnimation, value: hasPermissionRequest)
    }

    private var regularContent: some View {
        HStack(spacing: 12) {
            SessionAvatar(title: session.title ?? "Untitled Session")

            VStack(alignment: .leading, spacing: 3) {
                if let workspaceOverline, !workspaceOverline.isEmpty {
                    Text(workspaceOverline)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    titleLine

                    Spacer(minLength: 8)

                    if let date = preview?.date {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(preview?.text ?? "No messages yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if isBusy {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                    }

                    if hasLiveActivity {
                        badgeIcon(systemName: "waveform", foreground: .indigo, background: Color.indigo.opacity(0.12))
                    }

                    if hasDraft {
                        badgeIcon(systemName: "pencil", foreground: .secondary, background: Color.gray.opacity(0.12))
                    }

                    if hasPermissionRequest {
                        badgeIcon(systemName: "hand.raised.fill", foreground: .orange, background: Color.orange.opacity(0.12))
                    }
                }
            }

            SessionAvatar(title: session.title ?? "Untitled Session")
                .frame(maxWidth: .infinity)

            Text(session.title ?? "Untitled Session")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var titleLine: some View {
        Group {
            Text(session.title ?? "Untitled Session")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if isBusy {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 8, height: 8)
            }

            if hasLiveActivity {
                badgeIcon(systemName: "waveform", foreground: .indigo, background: Color.indigo.opacity(0.12))
            }

            if hasDraft {
                badgeIcon(systemName: "pencil", foreground: .secondary, background: Color.gray.opacity(0.12))
            }

            if hasPermissionRequest {
                badgeIcon(systemName: "hand.raised.fill", foreground: .orange, background: Color.orange.opacity(0.12))
            }
        }
    }

    private func badgeIcon(systemName: String, foreground: Color, background: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private var rowBackground: Color {
        isSelected ? Color.blue.opacity(0.10) : OpenCodePlatformColor.secondaryGroupedBackground
    }

    private var rowBorder: Color {
        isSelected ? Color.blue.opacity(0.28) : Color.primary.opacity(0.06)
    }
}
