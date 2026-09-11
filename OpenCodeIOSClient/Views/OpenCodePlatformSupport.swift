import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum OpenCodePlatformColor {
    static var groupedBackground: Color {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        Color(nsColor: .windowBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
#else
        Color(.systemBackground)
#endif
    }

    static var secondaryGroupedBackground: Color {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        Color(nsColor: .controlBackgroundColor)
#elseif canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
#else
        Color.secondary.opacity(0.12)
#endif
    }

    static func chatCanvasBackground(for colorScheme: ColorScheme) -> Color {
#if targetEnvironment(macCatalyst)
        colorScheme == .dark ? .black : .white
#else
        groupedBackground
#endif
    }
}

enum OpenCodeClipboard {
    static func copy(_ string: String) {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string = string
#endif
    }
}

enum OpenCodeHaptics {
    @MainActor
    struct StreamFeedback {
        var now: () -> Date = Date.init
        var impact: () -> Void = { OpenCodeHaptics.impact(.crisp) }
        var interval: () -> TimeInterval = {
            if Double.random(in: 0 ... 1) < 0.18 {
                return Double.random(in: 0.12 ... 0.18)
            }
            return Double.random(in: 0.045 ... 0.085)
        }

        func emit(nextAllowedAt: inout Date) {
            let time = now()
            guard time >= nextAllowedAt else { return }
            impact()
            nextAllowedAt = time.addingTimeInterval(interval())
        }
    }

    enum ImpactStyle {
        case crisp
        case soft
        case strong
    }

    @MainActor
    static func impact(_ style: ImpactStyle) {
#if canImport(UIKit)
        let generator: UIImpactFeedbackGenerator
        switch style {
        case .crisp:
            generator = UIImpactFeedbackGenerator(style: .rigid)
        case .soft:
            generator = UIImpactFeedbackGenerator(style: .soft)
        case .strong:
            generator = UIImpactFeedbackGenerator(style: .heavy)
        }
        generator.prepare()
        generator.impactOccurred()
#endif
    }
}

@MainActor
final class OpenClientCommandHoldMonitor {
    static let shared = OpenClientCommandHoldMonitor()

    private var monitoringTask: Task<Void, Never>?

    func monitor(onHold: @escaping () -> Void, onRelease: @escaping () -> Void) {
        guard monitoringTask == nil else { return }

#if targetEnvironment(macCatalyst)
        monitoringTask = Task { @MainActor [weak self] in
            var elapsedMilliseconds = 0
            var revealed = false

            while Self.isCommandPressed {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled else { return }
                elapsedMilliseconds += 25
                if !revealed, elapsedMilliseconds >= 225 {
                    revealed = true
                    onHold()
                }
            }

            onRelease()
            self?.monitoringTask = nil
        }
#else
        onRelease()
#endif
    }

#if targetEnvironment(macCatalyst)
    private static var isCommandPressed: Bool {
        CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    }
#endif
}

extension View {
    @ViewBuilder
    func opencodeInlineNavigationTitle() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeLargeNavigationTitle() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        navigationBarTitleDisplayMode(.large)
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeURLKeyboardType() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        keyboardType(.URL)
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeDisableTextAutocapitalization() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        textInputAutocapitalization(.never)
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeInteractiveKeyboardDismiss() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        scrollDismissesKeyboard(.interactively)
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeGroupedListStyle() -> some View {
#if os(macOS)
        listStyle(.inset)
#else
        listStyle(.insetGrouped)
#endif
    }

    @ViewBuilder
    func opencodeSoftScrollEdgeEffect() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macCatalyst 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeSearchTabSelectionActivation(isEnabled: Bool = true) -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macCatalyst 26.0, *), isEnabled {
            tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func opencodeDismissesSheetsOnBackgroundTap() -> some View {
#if canImport(UIKit)
        background {
            OpenCodeSheetBackgroundDismissInstaller()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
#else
        self
#endif
    }
}

#if canImport(UIKit)
private struct OpenCodeSheetBackgroundDismissInstaller: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.coordinator = context.coordinator
        context.coordinator.install(in: view.window)
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(in: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var installedWindow: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        func install(in window: UIWindow?) {
            guard let window, installedWindow !== window else { return }
            uninstall()

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissPresentedSheet))
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer {
                installedWindow?.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedWindow = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let presentation = dismissibleSheetPresentation() else { return false }
            let location = touch.location(in: presentation.presentedView)
            return !presentation.presentedView.bounds.contains(location)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func dismissPresentedSheet() {
            dismissibleSheetPresentation()?.controller.dismiss(animated: true)
        }

        private func dismissibleSheetPresentation() -> (controller: UIViewController, presentedView: UIView)? {
            guard let window = installedWindow,
                  var controller = window.rootViewController else { return nil }

            while let presented = controller.presentedViewController {
                controller = presented
            }

            let controllerName = NSStringFromClass(type(of: controller))
            guard controller.presentingViewController != nil,
                  !controllerName.localizedCaseInsensitiveContains("contextmenu"),
                  !controller.isModalInPresentation,
                  let presentationController = controller.presentationController,
                  presentationController is UISheetPresentationController,
                  let presentedView = presentationController.presentedView else {
                return nil
            }
            return (controller, presentedView)
        }
    }
}
#endif

extension ToolbarItemPlacement {
    static var opencodeLeading: ToolbarItemPlacement {
#if os(macOS)
        .automatic
#else
        .topBarLeading
#endif
    }

    static var opencodeTrailing: ToolbarItemPlacement {
#if os(macOS)
        .automatic
#else
        .topBarTrailing
#endif
    }
}
