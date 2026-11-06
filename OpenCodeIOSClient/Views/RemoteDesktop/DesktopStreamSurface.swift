import SwiftUI
import RoyalVNCKit

#if canImport(UIKit)
import UIKit

struct DesktopStreamSurface: UIViewRepresentable {
    let frame: CGImage
    let session: OpenClientNativeDesktopSession
    let clickEnabled: Bool
    @Binding var keyboardVisible: Bool

    func makeUIView(context: Context) -> DesktopScrollSurface {
        DesktopScrollSurface()
    }

    func updateUIView(_ view: DesktopScrollSurface, context: Context) {
        view.session = session
        view.keyboardChanged = { keyboardVisible = $0 }
        view.setFrame(frame)
        view.setClickEnabled(clickEnabled)
        if keyboardVisible && !view.isFirstResponder { view.becomeFirstResponder() }
        if !keyboardVisible && view.isFirstResponder { _ = view.resignFirstResponder() }
    }

    static func dismantleUIView(_ view: DesktopScrollSurface, coordinator: ()) {
        view.cancelInteraction()
        view.keyboardChanged = nil
        _ = view.resignFirstResponder()
    }
}

/// UIKit owns zoom geometry and maps pointer gestures into framebuffer coordinates.
final class DesktopScrollSurface: UIScrollView, UIScrollViewDelegate, UIKeyInput, UIGestureRecognizerDelegate {
    let image = UIImageView()
    lazy var click = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    lazy var doubleClick = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    lazy var pointerDrag = UILongPressGestureRecognizer(target: self, action: #selector(holdAndDrag(_:)))
    lazy var remoteScroll = UIPanGestureRecognizer(target: self, action: #selector(scrollRemote(_:)))
    private lazy var touchFeedback = UILongPressGestureRecognizer(target: self, action: #selector(showTouchFeedback(_:)))
    let feedback = DesktopGestureFeedback()
    private var scrollAnchor: (UInt16, UInt16)?
    private var scrollRemainder = CGPoint.zero
    weak var session: OpenClientNativeDesktopSession? {
        didSet { pointerInput = session }
    }
    weak var pointerInput: (any DesktopPointerInput)?
    private var dragPoint: (x: UInt16, y: UInt16)?
    private var holdOrigin: CGPoint?
    var keyboardChanged: ((Bool) -> Void)?
    private var pixelSize = CGSize.zero
    private var lastBounds = CGSize.zero
    private var viewportCenter: CGPoint?
    private var updatingGeometry = false
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        // UIScrollView creates its pinch recognizer only when zoom is enabled.
        maximumZoomScale = 6
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        if #available(iOS 26.0, *) {
            topEdgeEffect.isHidden = true
            bottomEdgeEffect.isHidden = true
        }
        addSubview(image)
        layer.addSublayer(feedback.layer)
        touchFeedback.minimumPressDuration = 0
        touchFeedback.allowableMovement = .greatestFiniteMagnitude
        touchFeedback.cancelsTouchesInView = false
        touchFeedback.delegate = self
        addGestureRecognizer(touchFeedback)
        remoteScroll.maximumNumberOfTouches = 1
        remoteScroll.delegate = self
        addGestureRecognizer(remoteScroll)
        doubleClick.numberOfTapsRequired = 2
        click.delegate = self
        doubleClick.delegate = self
        pointerDrag.minimumPressDuration = 0.35
        pointerDrag.allowableMovement = 12
        pointerDrag.delegate = self
        addGestureRecognizer(pointerDrag)
        addGestureRecognizer(doubleClick)
        addGestureRecognizer(click)
        // The first click is immediate. The simultaneous double-tap recognizer
        // supplies only the second click, without a failure dependency/delay.
        click.require(toFail: pointerDrag)
        doubleClick.require(toFail: pointerDrag)
        remoteScroll.require(toFail: pointerDrag)
        click.require(toFail: remoteScroll)
        doubleClick.require(toFail: remoteScroll)
        click.require(toFail: panGestureRecognizer)
        doubleClick.require(toFail: panGestureRecognizer)
        if let pinchGestureRecognizer {
            click.require(toFail: pinchGestureRecognizer)
            doubleClick.require(toFail: pinchGestureRecognizer)
        }
        accessibilityIdentifier = "remote-desktop.canvas"
        accessibilityLabel = String(localized: "Remote Desktop")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setClickEnabled(_ enabled: Bool) {
        if !enabled { cancelInteraction() }
        click.isEnabled = enabled
        doubleClick.isEnabled = enabled
        pointerDrag.isEnabled = enabled
        remoteScroll.isEnabled = enabled
        touchFeedback.isEnabled = enabled
        panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
        panGestureRecognizer.isEnabled = true
        pinchGestureRecognizer?.isEnabled = true
    }

    func setFrame(_ frame: CGImage) {
        image.image = UIImage(cgImage: frame)
        let size = CGSize(width: frame.width, height: frame.height)
        if pixelSize != size {
            cancelInteraction()
            pixelSize = size
            lastBounds = .zero
            viewportCenter = nil
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        let resized = lastBounds != bounds.size
        updatingGeometry = true
        defer { updatingGeometry = false; rememberCenter() }
        super.layoutSubviews()
        guard pixelSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        if resized {
            cancelInteraction()
            let previousCenter = viewportCenter
            let previousZoom = zoomScale
            let initial = lastBounds == .zero
            lastBounds = bounds.size
            if initial {
                minimumZoomScale = 0.01
                maximumZoomScale = 10
                zoomScale = 1
                image.frame = CGRect(origin: .zero, size: pixelSize)
                contentSize = pixelSize
            }
            let fit = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 6, previousZoom, 1)
            zoomScale = initial ? fit : max(fit, previousZoom)
            centerImage()
            if let previousCenter, !initial {
                let target = image.convert(previousCenter, to: self)
                contentOffset = CGPoint(
                    x: max(0, min(contentSize.width - bounds.width, target.x - bounds.width / 2)),
                    y: max(0, min(contentSize.height - bounds.height, target.y - bounds.height / 2)))
            }
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelInteraction() }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { cancelInteraction() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage(); rememberCenter() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { rememberCenter() }
    private func rememberCenter() {
        guard !updatingGeometry, lastBounds == bounds.size, pixelSize.width > 0 else { return }
        viewportCenter = image.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self)
    }
    private func centerImage() {
        image.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                               y: max(contentSize.height, bounds.height) / 2)
    }
    @objc private func tap(_ gesture: UITapGestureRecognizer) {
        guard let (x, y) = pointerCoordinates(at: gesture.location(in: self)) else { return }
        pointerInput?.pointer(x: x, y: y, down: true)
        pointerInput?.pointer(x: x, y: y, down: false)
    }

    @objc private func holdAndDrag(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard gesture.numberOfTouches == 1,
                  beginPointerHold(at: gesture.location(in: self)) else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            feedback.setRightClick(true)
        case .changed:
            guard gesture.numberOfTouches == 1 else { endPointerDrag(); return }
            updatePointerHold(at: gesture.location(in: self))
        case .ended:
            finishPointerHold(at: gesture.location(in: self))
        case .cancelled, .failed:
            endPointerDrag()
        default: break
        }
    }

    @discardableResult
    func beginPointerHold(at location: CGPoint) -> Bool {
        guard pointerDrag.isEnabled, pointerCoordinates(at: location) != nil else { return false }
        endPointerDrag()
        holdOrigin = location
        return true
    }

    func updatePointerHold(at location: CGPoint) {
        if let origin = holdOrigin {
            // Defer mouse-down until deliberate movement, preserving existing
            // desktop selection when the intent is a stationary right-click.
            guard hypot(location.x - origin.x, location.y - origin.y) >= 8 else { return }
            guard beginPointerDrag(at: origin) else { endPointerDrag(); return }
        }
        continuePointerDrag(at: location)
    }

    func finishPointerHold(at location: CGPoint) {
        updatePointerHold(at: location)
        if let origin = holdOrigin, let point = pointerCoordinates(at: origin) {
            holdOrigin = nil
            pointerInput?.secondaryClick(x: point.0, y: point.1)
        }
        endPointerDrag()
    }

    @discardableResult
    func beginPointerDrag(at location: CGPoint) -> Bool {
        guard pointerDrag.isEnabled, let point = pointerCoordinates(at: location) else { return false }
        endPointerDrag()
        endRemoteScroll()
        feedback.setRightClick(false)
        dragPoint = point
        pointerInput?.pointer(x: point.0, y: point.1, down: true)
        return true
    }

    func continuePointerDrag(at location: CGPoint) {
        guard dragPoint != nil, pixelSize.width > 0, pixelSize.height > 0 else { return }
        let point = image.convert(location, from: self)
        guard point.x.isFinite, point.y.isFinite else { return }
        let x = UInt16(clamping: Int(max(0, min(pixelSize.width - 1, point.x))))
        let y = UInt16(clamping: Int(max(0, min(pixelSize.height - 1, point.y))))
        dragPoint = (x, y)
        pointerInput?.pointer(x: x, y: y, down: true)
    }

    func endPointerDrag() {
        holdOrigin = nil
        guard let point = dragPoint else { return }
        dragPoint = nil
        pointerInput?.pointer(x: point.x, y: point.y, down: false)
    }

    func cancelInteraction() {
        endPointerDrag()
        endRemoteScroll()
        feedback.cancel()
    }

    @objc private func showTouchFeedback(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            guard gesture.numberOfTouches == 1, pointerCoordinates(at: location) != nil else { return }
            feedback.begin(at: location)
        case .changed:
            guard gesture.numberOfTouches == 1 else { feedback.cancel(); return }
            feedback.move(to: location)
        case .ended:
            feedback.move(to: location)
            feedback.finish()
        case .cancelled, .failed:
            feedback.cancel()
        default: break
        }
    }

    @objc private func scrollRemote(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let translation = gesture.translation(in: self)
            let location = gesture.location(in: self)
            guard beginRemoteScroll(at: CGPoint(x: location.x - translation.x, y: location.y - translation.y)) else { return }
            updateRemoteScroll(by: translation)
            gesture.setTranslation(.zero, in: self)
        case .changed:
            guard gesture.numberOfTouches == 1 else { endRemoteScroll(); return }
            updateRemoteScroll(by: gesture.translation(in: self))
            gesture.setTranslation(.zero, in: self)
        case .ended:
            updateRemoteScroll(by: gesture.translation(in: self))
            endRemoteScroll()
        case .cancelled, .failed:
            endRemoteScroll()
        default: break
        }
    }

    @discardableResult
    func beginRemoteScroll(at location: CGPoint) -> Bool {
        guard remoteScroll.isEnabled, dragPoint == nil, holdOrigin == nil,
              let point = pointerCoordinates(at: location) else { return false }
        scrollAnchor = point
        scrollRemainder = .zero
        return true
    }

    func updateRemoteScroll(by delta: CGPoint) {
        guard let point = scrollAnchor, delta.x.isFinite, delta.y.isFinite else { return }
        let pointsPerTick: CGFloat = 0.8
        let maximumDelta = pointsPerTick * 80
        scrollRemainder.x = max(-maximumDelta, min(maximumDelta, scrollRemainder.x - delta.x))
        scrollRemainder.y = max(-maximumDelta, min(maximumDelta, scrollRemainder.y - delta.y))
        let horizontal = Int(scrollRemainder.x / pointsPerTick)
        let vertical = Int(scrollRemainder.y / pointsPerTick)
        scrollRemainder.x -= CGFloat(horizontal) * pointsPerTick
        scrollRemainder.y -= CGFloat(vertical) * pointsPerTick
        if horizontal != 0 || vertical != 0 {
            pointerInput?.scroll(x: point.0, y: point.1, horizontal: horizontal, vertical: vertical)
        }
    }

    func endRemoteScroll() {
        scrollAnchor = nil
        scrollRemainder = .zero
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === touchFeedback || other === touchFeedback { return true }
        if (gestureRecognizer === click && other === doubleClick)
            || (gestureRecognizer === doubleClick && other === click) { return true }
        // A second finger can take over navigation, even after mouse-down.
        let navigation = [panGestureRecognizer, pinchGestureRecognizer].compactMap { $0 }
        let remote = [pointerDrag, remoteScroll]
        return (remote.contains(where: { $0 === gestureRecognizer }) && navigation.contains(where: { $0 === other }))
            || (remote.contains(where: { $0 === other }) && navigation.contains(where: { $0 === gestureRecognizer }))
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelInteraction() }
        super.willMove(toWindow: newWindow)
    }

    func pointerCoordinates(at location: CGPoint) -> (UInt16, UInt16)? {
        let point = image.convert(location, from: self)
        guard image.bounds.contains(point) else { return nil }
        let x = UInt16(clamping: Int(point.x))
        let y = UInt16(clamping: Int(point.y))
        return (x, y)
    }
    func insertText(_ text: String) {
        if text == "\n" { session?.key(.return) }
        else { session?.type(text) }
    }
    func deleteBackward() { session?.key(.delete) }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.keyboardChanged?(false) } }
        return resigned
    }
}

#if DEBUG
@MainActor
final class DesktopPointerFixtureState: ObservableObject, DesktopPointerInput {
    @Published var downs = 0
    @Published var ups = 0
    @Published var moves = 0
    @Published var secondaryClicks = 0
    @Published var verticalScroll = 0
    @Published var horizontalScroll = 0
    private var held = false

    func pointer(x: UInt16, y: UInt16, down: Bool) {
        if down {
            if held { moves += 1 } else { downs += 1 }
        } else { ups += 1 }
        held = down
    }

    func secondaryClick(x: UInt16, y: UInt16) { secondaryClicks += 1 }
    func scroll(x: UInt16, y: UInt16, horizontal: Int, vertical: Int) {
        horizontalScroll += horizontal
        verticalScroll += vertical
    }
}

struct DesktopPointerFixture: View {
    @StateObject private var input = DesktopPointerFixtureState()
    @State private var closeCount = 0

    var body: some View {
        NavigationStack {
            VStack {
                DesktopPointerFixtureSurface(input: input)
                    .aspectRatio(2, contentMode: .fit)
                    .overlay(alignment: .top) {
                        DesktopTopControls(dismiss: { closeCount += 1 }) {
                            Menu { Button(action: {}) { Text(verbatim: "Fixture") } } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                Text(verbatim: "\(input.downs)|\(input.ups)|\(input.moves)|\(input.secondaryClicks)")
                    .accessibilityIdentifier("desktop.pointer.events")
                Text(verbatim: "\(closeCount)").accessibilityIdentifier("desktop.pointer.close-count")
                Text(verbatim: "\(input.horizontalScroll)|\(input.verticalScroll)")
                    .accessibilityIdentifier("desktop.pointer.scroll")
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

private struct DesktopPointerFixtureSurface: UIViewRepresentable {
    let input: DesktopPointerFixtureState

    func makeUIView(context: Context) -> DesktopScrollSurface {
        let surface = DesktopScrollSurface()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300)).image { context in
            UIColor.darkGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
        }
        surface.setFrame(image.cgImage!)
        surface.isAccessibilityElement = true
        return surface
    }

    func updateUIView(_ view: DesktopScrollSurface, context: Context) {
        view.pointerInput = input
        view.setClickEnabled(true)
    }
}
#endif

/// SwiftUI owns modal presentation; this visible controller applies orientation
/// after the cover has appeared, rather than presenting from a toolbar background.
struct DesktopLandscapeContainer<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder let content: () -> Content
    func makeUIViewController(context: Context) -> LandscapeHost {
        LandscapeHost(rootView: content())
    }
    func updateUIViewController(_ controller: LandscapeHost, context: Context) {
        controller.rootView = content()
    }
    static func dismantleUIViewController(_ controller: LandscapeHost, coordinator: ()) {
        controller.restoreOrientation()
    }

    final class LandscapeHost: UIHostingController<Content> {
        private weak var owningScene: UIWindowScene?
        private var original: UIInterfaceOrientation?
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            traitCollection.userInterfaceIdiom == .phone ? .landscape : .all
        }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
            traitCollection.userInterfaceIdiom == .phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard traitCollection.userInterfaceIdiom == .phone,
                  let scene = view.window?.windowScene else { return }
            if owningScene == nil {
                owningScene = scene
                original = scene.effectiveGeometry.interfaceOrientation
            }
            setNeedsUpdateOfSupportedInterfaceOrientations()
            parent?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }

        func restoreOrientation() {
            guard let scene = owningScene, let original else { return }
            let mask: UIInterfaceOrientationMask = switch original {
            case .portrait: .portrait
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: .all
            }
            DispatchQueue.main.async {
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
            }
        }
    }
}
#endif

struct DesktopFunctionRow: View {
    let session: OpenClientNativeDesktopSession
    @State private var control = false
    @State private var option = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                #if canImport(UIKit)
                DesktopKeyboardButton(title: String(localized: "paste")) {
                    if let text = UIPasteboard.general.string { session.type(text) }
                }
                #endif
                DesktopKeyboardButton(title: String(localized: "esc")) { session.key(.escape) }
                DesktopKeyboardButton(title: String(localized: "tab")) { session.key(.tab) }
                DesktopKeyboardButton(title: String(localized: "ctrl"), isActive: control) {
                    control.toggle(); session.modifier(.control, pressed: control)
                }
                DesktopKeyboardButton(title: String(localized: "alt"), isActive: option) {
                    option.toggle(); session.modifier(.option, pressed: option)
                }
                DesktopKeyboardButton(title: "/") { session.type("/") }
                DesktopKeyboardButton(title: "|") { session.type("|") }
                DesktopKeyboardButton(title: "~") { session.type("~") }
                DesktopKeyboardButton(title: "-") { session.type("-") }
                DesktopKeyboardButton(title: "^C") {
                    session.modifier(.control, pressed: true)
                    session.type("c")
                    session.modifier(.control, pressed: control)
                }
                DesktopKeyboardButton(title: "←") { session.key(.leftArrow) }
                DesktopKeyboardButton(title: "↓") { session.key(.downArrow) }
                DesktopKeyboardButton(title: "↑") { session.key(.upArrow) }
                DesktopKeyboardButton(title: "→") { session.key(.rightArrow) }
                DesktopKeyboardButton(title: "⌫") { session.key(.delete) }
                DesktopKeyboardButton(title: "↵") { session.key(.return) }
            }
            .padding(.horizontal).padding(.vertical, 6)
        }
        .onDisappear {
            session.modifier(.control, pressed: false)
            session.modifier(.option, pressed: false)
            control = false
            option = false
        }
    }
}
