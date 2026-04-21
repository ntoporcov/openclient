import SwiftUI

struct ActivityStyle {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let isRunning: Bool
}

struct ActivityRow: View {
    let style: ActivityStyle

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style.tint)
                .frame(width: 28, height: 28)
                .background(style.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(style.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(style.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if style.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .tint(style.tint)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
