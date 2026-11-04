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
        view.keyboardChanged = nil
        _ = view.resignFirstResponder()
    }
}

/// UIKit owns zoom geometry and converts taps back into unscaled framebuffer coordinates.
final class DesktopScrollSurface: UIScrollView, UIScrollViewDelegate, UIKeyInput {
    let image = UIImageView()
    lazy var click = UITapGestureRecognizer(target: self, action: #selector(tap(_:)))
    weak var session: OpenClientNativeDesktopSession?
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
        addGestureRecognizer(click)
        click.require(toFail: panGestureRecognizer)
        if let pinchGestureRecognizer { click.require(toFail: pinchGestureRecognizer) }
        accessibilityIdentifier = "remote-desktop.canvas"
        accessibilityLabel = String(localized: "Remote Desktop")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setClickEnabled(_ enabled: Bool) {
        click.isEnabled = enabled
        panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
        panGestureRecognizer.isEnabled = true
        pinchGestureRecognizer?.isEnabled = true
    }

    func setFrame(_ frame: CGImage) {
        image.image = UIImage(cgImage: frame)
        let size = CGSize(width: frame.width, height: frame.height)
        if pixelSize != size {
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
        session?.pointer(x: x, y: y, down: true)
        session?.pointer(x: x, y: y, down: false)
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

/// A real full-screen controller owns the orientation mask. Requesting geometry
/// from a SwiftUI background alone does not constrain its presenting controller.
struct DesktopFullscreenPresenter<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeUIViewController(context: Context) -> Presenter { Presenter() }
    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.content = content
        controller.wantsPresentation = isPresented
        controller.updatePresentation()
    }
    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.wantsPresentation = false
        controller.updatePresentation()
    }

    final class Presenter: UIViewController {
        var content: (() -> Content)?
        var wantsPresentation = false
        private var host: LandscapeHost?
        private var transitioning = false
        private var original: UIInterfaceOrientation?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            updatePresentation()
        }

        func updatePresentation() {
            guard !transitioning else { return }
            if wantsPresentation, host == nil, view.window != nil, let content {
                original = view.window?.windowScene?.effectiveGeometry.interfaceOrientation
                let host = LandscapeHost(rootView: content())
                host.modalPresentationStyle = .fullScreen
                self.host = host
                transitioning = true
                present(host, animated: true) { [weak self] in
                    self?.transitioning = false
                    self?.updatePresentation()
                }
            } else if !wantsPresentation, let host {
                transitioning = true
                let scene = view.window?.windowScene
                host.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    self.host = nil
                    transitioning = false
                    if let original, scene?.traitCollection.userInterfaceIdiom == .phone {
                        let mask: UIInterfaceOrientationMask = switch original {
                        case .portrait: .portrait
                        case .portraitUpsideDown: .portraitUpsideDown
                        case .landscapeLeft: .landscapeLeft
                        case .landscapeRight: .landscapeRight
                        default: .all
                        }
                        scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
                    }
                    updatePresentation()
                }
            } else if wantsPresentation, let host, let content {
                // Preserve SwiftUI identity while forwarding environment changes
                // (notably scene backgrounding) from the presenting app scene.
                host.rootView = content()
            }
        }
    }

    final class LandscapeHost: UIHostingController<Content> {
        override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
            traitCollection.userInterfaceIdiom == .phone ? .landscape : .all
        }
        override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
            traitCollection.userInterfaceIdiom == .phone ? .landscapeRight : super.preferredInterfaceOrientationForPresentation
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard traitCollection.userInterfaceIdiom == .phone else { return }
            setNeedsUpdateOfSupportedInterfaceOrientations()
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
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
