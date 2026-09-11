import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#if DEBUG
import os
private let sessionSelectionLog = OSLog(subsystem: "com.ntoporcov.openclient", category: "SessionSelection")
#endif

// Observe the cell's input without recognizing a gesture or delaying its Button/scroll view.
private final class SessionSelectionPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var surface: SessionSelectionSurfaceView?
    private var pressOrigin: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let surface, let touch = touches.first else { state = .failed; return }
        guard touch.type != .indirectPointer || event.buttonMask == .primary else { state = .failed; return }
        pressOrigin = touch.location(in: surface)
        surface.beginNativePress(inputTimestamp: touch.timestamp)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let surface, let origin = pressOrigin, let touch = touches.first else { return }
        let point = touch.location(in: surface)
        if !surface.bounds.contains(point) || hypot(point.x - origin.x, point.y - origin.y) > 8 {
            surface.endNativePress()
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        surface?.endNativePress()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        surface?.endNativePress()
        state = .failed
    }

    override func reset() {
        surface?.endNativePress()
        pressOrigin = nil
        super.reset()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let surface, surface.window != nil, !surface.isHidden else { return false }
        return surface.bounds.contains(touch.location(in: surface))
    }
}

final class SessionSelectionSurfaceView: UIView {
    private var observation: AnyCancellable?
    private weak var feedback: SessionSelectionFeedback?
    private var sessionID = ""
    private var optimisticID: String?
    private var canonicalSelection = false
    private var pressRecognizer: SessionSelectionPressRecognizer?
    private var pressedSessionID: String?
    private(set) var showsSelection = false
    var selectedFill = UIColor.clear
    var normalFill = UIColor.clear
    var selectedBorder = UIColor.clear
    var normalBorder = UIColor.clear
    var selectedBorderWidth: CGFloat = 1.4

    func bind(sessionID: String, canonicalSelection: Bool, feedback: SessionSelectionFeedback) {
        if observation == nil {
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
                (view: SessionSelectionSurfaceView, _: UITraitCollection) in view.updateSelection()
            }
        }
        self.canonicalSelection = canonicalSelection
        if self.feedback !== feedback || self.sessionID != sessionID {
            endNativePress()
            self.feedback = feedback
            self.sessionID = sessionID
            observation = feedback.$sessionID.sink { [weak self] id in
                guard let self else { return }
                self.optimisticID = id
                self.updateSelection()
            }
        }
        updateSelection()
        installPressObservation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            endNativePress()
            if let pressRecognizer { pressRecognizer.view?.removeGestureRecognizer(pressRecognizer) }
            pressRecognizer = nil
        } else {
            installPressObservation()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installPressObservation()
    }

    private func installPressObservation() {
        guard window != nil, feedback != nil else { return }
        var ancestor = superview
        while let candidate = ancestor {
            if candidate is UICollectionViewCell || candidate is UITableViewCell {
                guard pressRecognizer?.view !== candidate else { return }
                if let pressRecognizer { pressRecognizer.view?.removeGestureRecognizer(pressRecognizer) }
                let recognizer = SessionSelectionPressRecognizer()
                recognizer.name = "openclient.selectionFeedback"
                recognizer.surface = self
                recognizer.delegate = recognizer
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                candidate.addGestureRecognizer(recognizer)
                pressRecognizer = recognizer
                return
            }
            ancestor = candidate.superview
        }
    }

    func beginNativePress(inputTimestamp: TimeInterval? = nil) {
        guard let feedback else { return }
        pressedSessionID = sessionID
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        os_signpost(.begin, log: sessionSelectionLog, name: "Press To Layer Commit",
            "inputAgeMS=%.2f", inputTimestamp.map { (started - $0) * 1_000 } ?? 0)
        #endif
        feedback.press(sessionID)
        #if DEBUG
        os_signpost(.end, log: sessionSelectionLog, name: "Press To Layer Commit")
        #endif
    }

    func endNativePress() {
        guard let pressedSessionID else { return }
        self.pressedSessionID = nil
        feedback?.releaseAfterActivation(pressedSessionID)
    }

    private func updateSelection() {
        showsSelection = optimisticID.map { $0 == sessionID } ?? canonicalSelection
        // Commit the decoration without waiting for SwiftUI to rebuild or measure the row.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = (showsSelection ? selectedFill : normalFill).resolvedColor(with: traitCollection).cgColor
        layer.borderColor = (showsSelection ? selectedBorder : normalBorder).resolvedColor(with: traitCollection).cgColor
        layer.borderWidth = showsSelection ? selectedBorderWidth : 1
        CATransaction.commit()
    }

}

private struct NativeSessionSelectionSurface: UIViewRepresentable {
    let feedback: SessionSelectionFeedback
    let sessionID: String
    let isSelected: Bool
    let cornerRadius: CGFloat
    let selectedFill: Color
    let normalFill: Color
    let selectedBorder: Color
    let normalBorder: Color
    let selectedBorderWidth: CGFloat

    func makeUIView(context: Context) -> SessionSelectionSurfaceView {
        let view = SessionSelectionSurfaceView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.layer.cornerCurve = .continuous
        return view
    }

    func updateUIView(_ view: SessionSelectionSurfaceView, context: Context) {
        view.layer.cornerRadius = cornerRadius
        view.selectedFill = UIColor(selectedFill)
        view.normalFill = UIColor(normalFill)
        view.selectedBorder = UIColor(selectedBorder)
        view.normalBorder = UIColor(normalBorder)
        view.selectedBorderWidth = selectedBorderWidth
        view.bind(sessionID: sessionID, canonicalSelection: isSelected, feedback: feedback)
    }
}
#endif

struct SessionSelectionSurface: View {
    let feedback: SessionSelectionFeedback?
    let sessionID: String
    let isSelected: Bool
    let cornerRadius: CGFloat
    let selectedFill: Color
    let normalFill: Color
    let selectedBorder: Color
    let normalBorder: Color
    let selectedBorderWidth: CGFloat

    var body: some View {
        #if canImport(UIKit)
        if let feedback {
            NativeSessionSelectionSurface(feedback: feedback, sessionID: sessionID,
                isSelected: isSelected, cornerRadius: cornerRadius,
                selectedFill: selectedFill, normalFill: normalFill,
                selectedBorder: selectedBorder, normalBorder: normalBorder,
                selectedBorderWidth: selectedBorderWidth)
        } else {
            swiftUISurface
        }
        #else
        swiftUISurface
        #endif
    }

    private var swiftUISurface: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isSelected ? selectedFill : normalFill)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isSelected ? selectedBorder : normalBorder,
                        lineWidth: isSelected ? selectedBorderWidth : 1)
            }
    }
}

struct SessionRow: View, Equatable {
    enum Style: Equatable {
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
    var displayTitle: String? = nil
    var shimmersTitle = false
    var selectionFeedback: SessionSelectionFeedback?

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
            && lhs.displayTitle == rhs.displayTitle
            && lhs.shimmersTitle == rhs.shimmersTitle
            && lhs.selectionFeedback === rhs.selectionFeedback
    }

    private var titleText: String {
        displayTitle ?? session.displayTitle()
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
        .padding(.horizontal, style == .compact ? 10 : 14)
        .padding(.vertical, style == .compact ? 8 : 12)
        .background {
            SessionSelectionSurface(feedback: selectionFeedback, sessionID: session.id,
                isSelected: isSelected, cornerRadius: style == .compact ? 14 : 18,
                selectedFill: Color.blue.opacity(0.10), normalFill: OpenCodePlatformColor.secondaryGroupedBackground,
                selectedBorder: Color.blue.opacity(0.28), normalBorder: Color.primary.opacity(0.06),
                selectedBorderWidth: 1.4)
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
            SessionAvatar(title: titleText)

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
                        SessionRelativeTimeText(date: date)
                    }
                }

                Text(preview?.text ?? String(localized: "No messages yet"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private var compactContent: some View {
        HStack(spacing: 10) {
            SessionAvatar(title: titleText, size: 30)

            ShimmeringSessionTitle(text: titleText, active: shimmersTitle, font: .subheadline.weight(.medium), lineLimit: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if showsPinnedBadge {
                    compactIndicator(systemName: "pin.fill", color: .secondary)
                }
                if isBusy {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 7, height: 7)
                }
                if hasLiveActivity {
                    compactIndicator(systemName: "waveform", color: .indigo)
                }
                if hasDraft {
                    compactIndicator(systemName: "pencil", color: .secondary)
                }
                if hasPermissionRequest {
                    compactIndicator(systemName: "hand.raised.fill", color: .orange)
                }
            }
        }
    }

    private func compactIndicator(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private var titleLine: some View {
        Group {
            ShimmeringSessionTitle(text: titleText, active: shimmersTitle, font: .body.weight(.medium), lineLimit: 1)

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

}

private struct ShimmeringSessionTitle: View {
    @Environment(\.scenePhase) private var scenePhase

    let text: String
    let active: Bool
    let font: Font
    let lineLimit: Int
    var alignment: TextAlignment = .leading

    @State private var phase: CGFloat = -1

    private var isAnimating: Bool {
        active && scenePhase == .active
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(isAnimating ? Color.primary.opacity(0.72) : Color.primary)
            .lineLimit(lineLimit)
            .multilineTextAlignment(alignment)
            .overlay {
                if isAnimating {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.85), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: max(geometry.size.width * 0.8, 36))
                        .offset(x: geometry.size.width * phase)
                        .blendMode(.plusLighter)
                    }
                    .mask(
                        Text(text)
                            .font(font)
                            .lineLimit(lineLimit)
                            .multilineTextAlignment(alignment)
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear { updateAnimation(active: isAnimating) }
            .onChange(of: active) { _, _ in updateAnimation(active: isAnimating) }
            .onChange(of: scenePhase) { _, _ in updateAnimation(active: isAnimating) }
    }

    private func updateAnimation(active: Bool) {
        guard active else {
            phase = -1
            return
        }
        phase = -1
        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
            phase = 1.35
        }
    }
}
