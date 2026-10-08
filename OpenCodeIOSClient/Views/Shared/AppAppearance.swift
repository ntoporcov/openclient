import SwiftUI

extension AppAccentColor {
    func color(in colorScheme: ColorScheme) -> Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: Color(.sRGB, red: 0.94, green: 0.16, blue: 0.57, opacity: 1) // Hot pink, rather than the system's coral pink.
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .teal: .teal
        case .clear: .primary
        case .inverted: colorScheme == .dark ? .white : .black
        }
    }

    func foreground(in colorScheme: ColorScheme) -> Color {
        if self == .clear { return .primary }
        return self == .inverted && colorScheme == .dark ? .black : .white
    }

    func systemColor(in colorScheme: ColorScheme) -> Color {
        self == .clear || self == .inverted ? .blue : color(in: colorScheme)
    }
}

extension EnvironmentValues {
    @Entry var chatBubbleStyle: ChatBubbleStyle = .glass
    @Entry var chatLineHeight: ChatLineHeight = .tight
    // Keep palette colors independent of navigation and control tint overrides.
    @Entry var appAccentColor: Color = .blue
    @Entry var appAccentForeground: Color = .white
    @Entry var appSystemAccentColor: Color = .blue
    @Entry var appAccentIsClear = false
    @Entry var appUsesSystemControlColors = false
}

struct AppAppearanceModifier: ViewModifier {
    @ObservedObject var store: AppCustomizationStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            // Ordinary controls (including navigation/toolbars) stay neutral.
            // Filled actions use the independent appAccentColor environment value.
            .tint(.primary)
            .accentColor(store.accentColor.systemColor(in: colorScheme))
            .environment(\.appAccentColor, store.accentColor.color(in: colorScheme))
            .environment(\.appAccentForeground, store.accentColor.foreground(in: colorScheme))
            .environment(\.appSystemAccentColor, store.accentColor.systemColor(in: colorScheme))
            .environment(\.appAccentIsClear, store.accentColor == .clear)
            .environment(\.appUsesSystemControlColors, store.accentColor == .clear || store.accentColor == .inverted)
            .toggleStyle(AppAccentToggleStyle())
            .environment(\.chatBubbleStyle, store.chatBubbleStyle)
            .environment(\.chatLineHeight, store.chatLineHeight)
    }
}

/// Scope only this scene's shell. Dedicated chat windows inject their own store.
struct ConnectionAppearanceScopeModifier: ViewModifier {
    @ObservedObject var facade: ConnectionFacade

    func body(content: Content) -> some View {
        content.modifier(AppAppearanceModifier(store: facade.shellAppearanceStore))
    }
}

private struct AppAccentToggleStyle: ToggleStyle {
    @Environment(\.appSystemAccentColor) private var systemAccent
    @Environment(\.appUsesSystemControlColors) private var usesSystemColors
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.automatic)
            .tint(usesSystemColors ? nil : systemAccent)
    }
}

/// Resolve label contrast at the filled action, independently of control tint.
struct AppAccentForegroundStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> Color {
        environment.appAccentForeground
    }
}

struct AppAccentActionModifier: ViewModifier {
    @Environment(\.appAccentColor) private var accent
    @Environment(\.appAccentIsClear) private var isClear

    func body(content: Content) -> some View {
        content
            .tint(isClear ? Color.primary.opacity(0.08) : accent)
            .foregroundStyle(AppAccentForegroundStyle())
    }
}

struct AppAccentActionGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.appAccentColor) private var accent
    @Environment(\.appAccentIsClear) private var isClear
    let size: CGFloat
    let shape: S

    func body(content: Content) -> some View {
        content.opencodeActionGlass(clear: !isClear, tint: isClear ? nil : accent.opacity(0.82), size: size, in: shape)
    }
}

extension View {
    func opencodeAccentActionGlass<S: Shape>(size: CGFloat, in shape: S) -> some View {
        modifier(AppAccentActionGlassModifier(size: size, shape: shape))
    }
}

/// Shared by the transcript and the live appearance preview.
struct ChatBubbleBackground: View {
    @Environment(\.appAccentColor) private var appAccentColor
    @Environment(\.appAccentIsClear) private var isClear
    @Environment(\.chatBubbleStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = MessageBubbleShape(isOutgoing: true, cornerRadius: 22)
        if style == .solid || reduceTransparency {
            shape.fill(isClear ? OpenCodePlatformColor.secondaryGroupedBackground : appAccentColor)
        } else {
            if #available(iOS 26.0, macOS 26.0, *) {
                shape.fill(isClear ? Color.clear : appAccentColor.opacity(0.35))
                    .glassEffect(isClear ? .regular : .regular.tint(appAccentColor.opacity(0.8)), in: shape)
            } else {
                shape.fill(.regularMaterial)
                    .overlay { shape.fill(isClear ? Color.clear : appAccentColor.opacity(0.8)) }
            }
        }
    }
}
