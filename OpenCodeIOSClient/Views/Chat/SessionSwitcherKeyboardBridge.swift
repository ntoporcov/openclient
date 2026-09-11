import SwiftUI

#if canImport(UIKit)
import UIKit
import os

enum SessionSwitcherDiagnostics {
    private static let logger = Logger(subsystem: "com.ntoporcov.openclient", category: "SessionSwitcher")
    static func log(_ message: String) {
        #if DEBUG
        logger.info("\(message, privacy: .public)")
        #endif
    }
}

private extension UIViewController {
    @objc func openClientCycleSession(_ command: UIKeyCommand) {
        SessionSwitcherKeyboardController.dispatch(command)
    }
}

struct SessionSwitcherKeyboardBridge: UIViewControllerRepresentable {
    let onAdvance: (@escaping () -> Bool) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> SessionSwitcherKeyboardController {
        SessionSwitcherKeyboardController(onAdvance: onAdvance, onCancel: onCancel)
    }

    func updateUIViewController(_ controller: SessionSwitcherKeyboardController, context: Context) {
        controller.onAdvance = onAdvance
        controller.onCancel = onCancel
    }

    static func dismantleUIViewController(_ controller: SessionSwitcherKeyboardController, coordinator: ()) {
        controller.uninstall()
    }
}

final class SessionSwitcherKeyboardController: UIViewController {
    private final class Registration {
        weak var controller: SessionSwitcherKeyboardController?
        init(_ controller: SessionSwitcherKeyboardController) { self.controller = controller }
    }
    private static var registrations: [String: Registration] = [:]
    var onAdvance: (@escaping () -> Bool) -> Void
    var onCancel: () -> Void
    private weak var commandOwner: UIViewController?
    private var command: UIKeyCommand?
    private let registrationID = UUID().uuidString

    init(onAdvance: @escaping (@escaping () -> Bool) -> Void, onCancel: @escaping () -> Void) {
        self.onAdvance = onAdvance
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        SessionSwitcherDiagnostics.log("bridge loadView")
        let view = SessionSwitcherKeyboardAttachmentView()
        view.isUserInteractionEnabled = false
        view.onWindowChanged = { [weak self] in self?.install() }
        self.view = view
    }

    private var isActive: Bool {
        guard let window = viewIfLoaded?.window else { return false }
        return window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
            && window.rootViewController?.presentedViewController == nil
    }

    func install() {
        guard let root = viewIfLoaded?.window?.rootViewController else {
            SessionSwitcherDiagnostics.log("install: no window/root")
            uninstall()
            return
        }
        guard commandOwner !== root else { return }
        uninstall()
        let selector = #selector(UIViewController.openClientCycleSession(_:))
        // A newly mounted chat supersedes its outgoing root-chat command without taking focus.
        for previous in root.keyCommands ?? [] where previous.action == selector {
            root.removeKeyCommand(previous)
        }
        let command = UIKeyCommand(title: String(localized: "Previous Session"), action: selector,
            input: "`", modifierFlags: .command, propertyList: registrationID)
        command.wantsPriorityOverSystemBehavior = true
        Self.registrations[registrationID] = Registration(self)
        root.addKeyCommand(command)
        self.command = command
        commandOwner = root
        SessionSwitcherDiagnostics.log("installed root=\(type(of: root)) owns=\(ownsRegisteredCommand) active=\(isActive) key=\(view.window?.isKeyWindow == true) presented=\(root.presentedViewController.map { String(describing: type(of: $0)) } ?? "none")")
    }

    func uninstall() {
        guard let command else { return }
        if ownsRegisteredCommand { commandOwner?.removeKeyCommand(command) }
        Self.registrations[registrationID] = nil
        self.command = nil
        commandOwner = nil
        onCancel()
    }

    private var ownsRegisteredCommand: Bool {
        commandOwner?.keyCommands?.contains { $0.propertyList as? String == registrationID } == true
    }

    static func dispatch(_ command: UIKeyCommand) {
        SessionSwitcherDiagnostics.log("dispatch registrations=\(registrations.count) token=\(command.propertyList is String)")
        guard let id = command.propertyList as? String,
              let controller = registrations[id]?.controller,
              controller.ownsRegisteredCommand, controller.isActive else {
            SessionSwitcherDiagnostics.log("dispatch rejected: registration, ownership, or active-window guard")
            return
        }
        SessionSwitcherDiagnostics.log("dispatch accepted")
        controller.onAdvance { [weak controller] in controller?.isActive == true }
    }

    static func command(for window: UIWindow?) -> UIKeyCommand? {
        guard let window else { return nil }
        return registrations.values.compactMap(\.controller).first {
            $0.viewIfLoaded?.window === window && $0.ownsRegisteredCommand && $0.isActive
        }?.command
    }

    static func dispatchFromMenu() {
        SessionSwitcherDiagnostics.log("native menu shortcut")
        guard let controller = registrations.values.compactMap(\.controller).first(where: {
            $0.ownsRegisteredCommand && $0.isActive
        }), let command = controller.command else {
            SessionSwitcherDiagnostics.log("menu rejected: no active chat registration")
            return
        }
        dispatch(command)
    }
}

private final class SessionSwitcherKeyboardAttachmentView: UIView {
    var onWindowChanged: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChanged?()
    }
}
#endif
