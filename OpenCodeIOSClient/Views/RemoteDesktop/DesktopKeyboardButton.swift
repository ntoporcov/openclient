import SwiftUI

/// Shared terminal/desktop key appearance; each input surface owns its semantics.
struct DesktopKeyboardButton: View {
    @Environment(\.appAccentColor) private var accent
    let title: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .frame(height: 38)
                .opencodeConcentricGlassSurface(
                    tint: isActive ? accent.opacity(0.22) : nil,
                    isInteractive: true, minimumCornerRadius: 19, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
