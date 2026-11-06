#if canImport(UIKit)
import UIKit

/// Immediate, local gesture feedback. Completion means finger-up, not a remote
/// acknowledgement: RFB has no reliable app-level acknowledgement for input.
@MainActor
final class DesktopGestureFeedback {
    let layer = CALayer()
    private let trail = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var points: [CGPoint] = []
    private(set) var isActive = false

    init() {
        layer.opacity = 0
        trail.fillColor = nil
        trail.strokeColor = UIColor.systemBlue.cgColor
        trail.lineWidth = 3
        trail.lineCap = .round
        trail.lineJoin = .round
        dot.fillColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 1.5
        for child in [trail, dot] {
            child.shadowColor = UIColor.black.cgColor
            child.shadowOpacity = 0.45
            child.shadowRadius = 2
            child.shadowOffset = .zero
            layer.addSublayer(child)
        }
    }

    func begin(at point: CGPoint) {
        cancel()
        isActive = true
        points = [point]
        withoutAnimation {
            layer.opacity = 1
            dot.position = point
            setRightClick(false)
            trail.path = nil
        }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.85
        pulse.toValue = 1.2
        pulse.duration = 0.45
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.add(pulse, forKey: "pulse")
    }

    func move(to point: CGPoint) {
        guard isActive else { return }
        withoutAnimation {
            dot.position = point
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) < 3 { return }
            points.append(point)
            // Bounded tail, in screen points regardless of framebuffer zoom.
            if points.count > 32 { points.removeFirst(points.count - 32) }
            let path = UIBezierPath()
            if let first = points.first { path.move(to: first) }
            for point in points.dropFirst() { path.addLine(to: point) }
            trail.path = path.cgPath
        }
    }

    func setRightClick(_ rightClick: Bool) {
        let path = UIBezierPath(ovalIn: CGRect(x: -6, y: -6, width: 12, height: 12))
        if rightClick { path.append(UIBezierPath(ovalIn: CGRect(x: -11, y: -11, width: 22, height: 22))) }
        withoutAnimation { dot.path = path.cgPath }
    }

    func finish() {
        guard isActive else { return }
        isActive = false
        dot.removeAnimation(forKey: "pulse")
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        let duration = reducedMotion ? 0.15 : 0.4
        withoutAnimation { layer.opacity = 0 }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = duration
        layer.add(fade, forKey: "finish")
        if !reducedMotion {
            let expand = CABasicAnimation(keyPath: "transform.scale")
            expand.fromValue = 1
            expand.toValue = 2.5
            expand.duration = duration
            dot.add(expand, forKey: "finish")
            let widen = CABasicAnimation(keyPath: "lineWidth")
            widen.fromValue = 3
            widen.toValue = 7
            widen.duration = duration
            trail.add(widen, forKey: "finish")
        }
    }

    func cancel() {
        isActive = false
        points.removeAll(keepingCapacity: true)
        layer.removeAllAnimations()
        dot.removeAllAnimations()
        trail.removeAllAnimations()
        withoutAnimation { layer.opacity = 0; trail.path = nil }
    }

    private func withoutAnimation(_ action: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        action()
        CATransaction.commit()
    }
}
#endif
