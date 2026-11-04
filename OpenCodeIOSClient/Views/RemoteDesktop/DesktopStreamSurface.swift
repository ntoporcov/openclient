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
        view.click.isEnabled = clickEnabled
        view.panGestureRecognizer.isEnabled = !clickEnabled
        view.pinchGestureRecognizer?.isEnabled = !clickEnabled
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
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    override var canBecomeFirstResponder: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        addSubview(image)
        addGestureRecognizer(click)
        accessibilityIdentifier = "remote-desktop.canvas"
        accessibilityLabel = String(localized: "Remote Desktop")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFrame(_ frame: CGImage) {
        image.image = UIImage(cgImage: frame)
        let size = CGSize(width: frame.width, height: frame.height)
        if pixelSize != size {
            pixelSize = size
            lastBounds = .zero
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard pixelSize.width > 0, bounds.width > 0, bounds.height > 0 else { return }
        if lastBounds != bounds.size {
            lastBounds = bounds.size
            minimumZoomScale = 0.01
            maximumZoomScale = 10
            zoomScale = 1
            image.frame = CGRect(origin: .zero, size: pixelSize)
            contentSize = pixelSize
            let fit = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
            minimumZoomScale = fit
            maximumZoomScale = max(fit * 6, 1)
            zoomScale = fit
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { image }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }
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

/// Presentation lifetime, independent of authentication or framebuffer arrival.
struct DesktopPresentationOrientation: UIViewRepresentable {
    func makeUIView(context: Context) -> OrientationView { OrientationView() }
    func updateUIView(_ view: OrientationView, context: Context) {}
    static func dismantleUIView(_ view: OrientationView, coordinator: ()) { view.restore() }

    final class OrientationView: UIView {
        private weak var scene: UIWindowScene?
        private var original: UIInterfaceOrientation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let owningScene = window?.windowScene, scene == nil,
                  traitCollection.userInterfaceIdiom == .phone,
                  traitCollection.horizontalSizeClass == .compact else { return }
            scene = owningScene
            original = owningScene.effectiveGeometry.interfaceOrientation
            owningScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }

        func restore() {
            guard let original else { return }
            let mask: UIInterfaceOrientationMask = switch original {
            case .portrait: .portrait
            case .portraitUpsideDown: .portraitUpsideDown
            case .landscapeLeft: .landscapeLeft
            case .landscapeRight: .landscapeRight
            default: .all
            }
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
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
