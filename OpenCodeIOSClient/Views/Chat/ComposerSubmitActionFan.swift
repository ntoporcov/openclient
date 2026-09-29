import SwiftUI

struct ComposerSubmitFanLifecycle: ViewModifier {
    @Binding var isExpanded: Bool
    let blocksNewInput: Bool
    let contextID: String
    let hasSideQuestion: Bool
    let showsSendButton: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: blocksNewInput) { _, _ in isExpanded = false }
            .onChange(of: contextID) { _, _ in isExpanded = false }
            .onChange(of: hasSideQuestion) { _, _ in isExpanded = false }
            .onChange(of: showsSendButton) { _, visible in
                if !visible { isExpanded = false }
            }
            .onDisappear { isExpanded = false }
    }
}

enum ComposerSubmitAction: String, Identifiable {
    case submit, queue, steer, sideQuestion

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .submit: "Submit"
        case .queue: "Queue"
        case .steer: "Steer"
        case .sideQuestion: "Side Question"
        }
    }
    var symbol: String {
        switch self {
        case .submit: "arrow.up"
        case .queue: OpenCodePromptDelivery.queue.symbolName
        case .steer: OpenCodePromptDelivery.steer.symbolName
        case .sideQuestion: SideQuestionAppearance.symbolName
        }
    }
}

struct ComposerSubmitFanAnchor {
    let bounds: Anchor<CGRect>
    let sourceSize: CGFloat
    let sourceSymbol: String
    let actions: [ComposerSubmitAction]
    let dragLocation: CGPoint?
    let releaseID: Int
    let dismiss: @MainActor () -> Void
    let perform: @MainActor (ComposerSubmitAction) -> Void
}

struct ComposerSubmitFanPreference: PreferenceKey {
    static var defaultValue: ComposerSubmitFanAnchor? { nil }
    static func reduce(value: inout ComposerSubmitFanAnchor?, nextValue: () -> ComposerSubmitFanAnchor?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Host above the entire chat pane so fan buttons can receive taps over the
    /// composer/Stop button, rather than overflowing a small button's hit region.
    func composerSubmitActionFan() -> some View {
        overlayPreferenceValue(ComposerSubmitFanPreference.self) { anchor in
            if let anchor {
                GeometryReader { geometry in
                    ComposerSubmitActionFan(
                        anchor: anchor,
                        origin: CGPoint(x: geometry[anchor.bounds].midX, y: geometry[anchor.bounds].midY),
                        availableSize: geometry.size,
                        globalOffset: geometry.frame(in: .global).origin
                    )
                }
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
    }
}

private struct ComposerSubmitActionFan: View {
    let anchor: ComposerSubmitFanAnchor
    let origin: CGPoint
    let availableSize: CGSize
    let globalOffset: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var isExpanded = false
    @State private var isClosing = false

    private var dragPoint: CGPoint? {
        anchor.dragLocation.map { CGPoint(x: $0.x - globalOffset.x, y: $0.y - globalOffset.y) }
    }

    private var highlightedAction: ComposerSubmitAction? {
        guard !isClosing, let dragPoint else { return nil }
        return ComposerSubmitFanLayout(actions: anchor.actions, origin: origin,
            availableSize: availableSize, isRTL: layoutDirection == .rightToLeft).action(at: dragPoint)
    }

    var body: some View {
        ZStack {
            Button(action: dismiss) {
                ComposerSubmitFanScrim(origin: origin, isExpanded: isExpanded)
                    .ignoresSafeArea(.all, edges: .bottom)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Submit Options")
            .accessibilityIdentifier("chat.send.options.dismiss")

            ComposerSubmitFanButtons(
                actions: anchor.actions, origin: origin, availableSize: availableSize,
                sourceSize: anchor.sourceSize, sourceSymbol: anchor.sourceSymbol, isExpanded: isExpanded,
                highlightedAction: highlightedAction,
                dismiss: dismiss,
                perform: { action in
                    // Actions run immediately, not as a mode selection for a later tap.
                    anchor.dismiss()
                    anchor.perform(action)
                }
            )
        }
        .disabled(isClosing)
        .onChange(of: highlightedAction) { _, action in
            if action != nil { OpenCodeHaptics.impact(.soft) }
        }
        .onChange(of: anchor.releaseID) { _, _ in
            guard !isClosing else { return }
            if let action = highlightedAction {
                isClosing = true
                anchor.dismiss()
                anchor.perform(action)
            } else if let dragPoint, hypot(dragPoint.x - origin.x, dragPoint.y - origin.y) > 32 {
                dismiss()
            }
        }
        .task {
            // Present the collapsed glass geometry before moving it outward.
            // Expanding in onAppear can coalesce both layouts into one frame.
            do { try await Task.sleep(for: .milliseconds(35)) } catch { return }
            guard !isClosing else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
                isExpanded = true
            }
        }
    }

    private func dismiss() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0), completionCriteria: .removed) {
            isExpanded = false
        } completion: {
            anchor.dismiss()
        }
    }
}

private struct ComposerSubmitFanScrim: View {
    let origin: CGPoint
    let isExpanded: Bool

    var body: some View {
        ZStack {
            Color.clear
            GeometryReader { geometry in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask {
                        RadialGradient(
                            stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                            center: UnitPoint(x: origin.x / max(1, geometry.size.width), y: origin.y / max(1, geometry.size.height)),
                            startRadius: 0,
                            endRadius: 340
                        )
                    }
                    .opacity(isExpanded ? 0.7 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
}

private struct ComposerSubmitFanButtons: View {
    let actions: [ComposerSubmitAction]
    let origin: CGPoint
    let availableSize: CGSize
    let sourceSize: CGFloat
    let sourceSymbol: String
    let isExpanded: Bool
    let highlightedAction: ComposerSubmitAction?
    let dismiss: () -> Void
    let perform: (ComposerSubmitAction) -> Void
    @Environment(\.layoutDirection) private var layoutDirection
    @Namespace private var glassNamespace

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // Only merge while converging on Send, not at resting positions.
            GlassEffectContainer(spacing: 2) {
                ComposerSubmitFanContents(
                    actions: actions, origin: origin, availableSize: availableSize,
                    sourceSize: sourceSize, sourceSymbol: sourceSymbol, isExpanded: isExpanded,
                    highlightedAction: highlightedAction,
                    isRTL: layoutDirection == .rightToLeft, glassNamespace: glassNamespace,
                    dismiss: dismiss, perform: perform
                )
            }
        } else {
            ComposerSubmitFanContents(
                actions: actions, origin: origin, availableSize: availableSize,
                sourceSize: sourceSize, sourceSymbol: sourceSymbol, isExpanded: isExpanded,
                highlightedAction: highlightedAction,
                isRTL: layoutDirection == .rightToLeft, glassNamespace: glassNamespace,
                dismiss: dismiss, perform: perform
            )
        }
    }
}

private struct ComposerSubmitFanContents: View {
    let actions: [ComposerSubmitAction]
    let origin: CGPoint
    let availableSize: CGSize
    let sourceSize: CGFloat
    let sourceSymbol: String
    let isExpanded: Bool
    let highlightedAction: ComposerSubmitAction?
    let isRTL: Bool
    let glassNamespace: Namespace.ID
    let dismiss: () -> Void
    let perform: (ComposerSubmitAction) -> Void
    @Environment(\.appAccentForeground) private var accentForeground
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(actions) { action in
                ComposerSubmitFanOption(
                    action: action, glassNamespace: glassNamespace,
                    isExpanded: isExpanded, sourceSize: sourceSize,
                    isHighlighted: highlightedAction == action,
                    perform: { perform(action) }
                )
                .position(isExpanded ? ComposerSubmitFanLayout(actions: actions, origin: origin,
                    availableSize: availableSize, isRTL: isRTL).position(for: action) : origin)
                // Keep the glass circle, not the full label, on the arc.
                .offset(x: isRTL ? 58 : -58)
                .animation(optionAnimation(for: action), value: isExpanded)
                .allowsHitTesting(isExpanded)
                .accessibilityHidden(!isExpanded)
            }

            Button(action: dismiss) {
                ZStack {
                    Image(systemName: sourceSymbol)
                        .opacity(isExpanded ? 0 : 1)
                    Image(systemName: "xmark")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .opacity(isExpanded ? 1 : 0)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accentForeground)
                .frame(width: sourceSize, height: sourceSize)
            }
            .opencodeAccentActionGlass(size: sourceSize, in: Circle())
            .opencodeToolbarGlassID("submit-origin", in: glassNamespace)
            .opencodeMatchedGlassTransition()
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss Submit Options")
            .accessibilityIdentifier("chat.send.options.close")
            .keyboardShortcut(.cancelAction)
            .position(origin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func optionAnimation(for action: ComposerSubmitAction) -> Animation? {
        guard !reduceMotion else { return nil }
        guard isExpanded else { return .spring(duration: 0.18, bounce: 0) }
        let index = actions.firstIndex(of: action) ?? 0
        return .spring(duration: 0.32, bounce: 0.15).delay(Double(index) * 0.075)
    }

}

private struct ComposerSubmitFanLayout {
    let actions: [ComposerSubmitAction]
    let origin: CGPoint
    let availableSize: CGSize
    let isRTL: Bool

    func action(at point: CGPoint) -> ComposerSubmitAction? {
        actions.filter { action in
            let center = position(for: action)
            let bounds = CGRect(x: center.x - (isRTL ? 26 : 142), y: center.y - 26, width: 168, height: 52)
            return bounds.contains(point)
        }.min { lhs, rhs in
            let a = position(for: lhs)
            let b = position(for: rhs)
            return hypot(point.x - a.x, point.y - a.y) < hypot(point.x - b.x, point.y - b.y)
        }
    }

    func position(for action: ComposerSubmitAction) -> CGPoint {
        let index = actions.firstIndex(of: action) ?? 0
        // Lay out circle centers on one arc around Send. Constrain the radius
        // as a whole rather than clamping points and distorting the circle.
        let inwardSpace = isRTL ? availableSize.width - origin.x : origin.x
        let preferredRadius: CGFloat = actions.count == 3 ? 124 : 88
        let radius = max(0, min(preferredRadius, inwardSpace - 142, origin.y - 26))
        // Equal angular spacing gives the streaming actions equal separation.
        // The radius also keeps leading captions clear of neighboring circles.
        let angles: [CGFloat] = actions.count == 3 ? [10, 45, 80] : [20, 90]
        let angle = angles[min(index, angles.count - 1)] * .pi / 180
        return CGPoint(
            x: origin.x + (isRTL ? 1 : -1) * radius * cos(angle),
            y: origin.y - radius * sin(angle)
        )
    }
}

private struct ComposerSubmitFanOption: View {
    let action: ComposerSubmitAction
    let glassNamespace: Namespace.ID
    let isExpanded: Bool
    let sourceSize: CGFloat
    let isHighlighted: Bool
    let perform: () -> Void
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        Button(action: perform) {
            HStack(alignment: .top, spacing: 8) {
                Text(action.title)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 108, alignment: .trailing)
                    .opacity(isExpanded ? 1 : 0)
                Image(systemName: action.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .opacity(isExpanded ? 1 : 0)
                    .opencodeActionGlass(tint: accentColor.opacity(isHighlighted ? 0.45 : 0.15), size: isExpanded ? 52 : sourceSize, in: Circle())
                    .overlay {
                        if isHighlighted { Circle().strokeBorder(accentColor, lineWidth: 2) }
                    }
                    .opencodeToolbarGlassID(action.id, in: glassNamespace)
                    .opencodeMatchedGlassTransition()
                    .frame(width: 52, height: 52)
            }
            .frame(width: 168, height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(action.title))
        .accessibilityIdentifier("chat.send.\(action.rawValue)")
    }
}
