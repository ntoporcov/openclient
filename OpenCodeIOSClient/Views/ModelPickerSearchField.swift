#if canImport(UIKit)
import SwiftUI
import UIKit

struct ModelPickerSearchField: UIViewRepresentable {
    @Binding var text: String
    let isActive: Bool
    let accessibilityIdentifier: String
    let onMove: (Int) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> ModelPickerSearchTextField {
        let field = ModelPickerSearchTextField()
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        configure(field, coordinator: context.coordinator)
        return field
    }

    func updateUIView(_ field: ModelPickerSearchTextField, context: Context) {
        configure(field, coordinator: context.coordinator)
    }

    private func configure(_ field: ModelPickerSearchTextField, coordinator: Coordinator) {
        coordinator.text = $text
        field.onMove = onMove
        field.onSubmit = onSubmit
        field.accessibilityIdentifier = accessibilityIdentifier
        field.updateUITextFromBinding(text)
        field.setActive(isActive)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ModelPickerSearchTextField, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        return CGSize(width: proposal.width ?? max(0, intrinsic.width), height: intrinsic.height)
    }

    static func dismantleUIView(_ field: ModelPickerSearchTextField, coordinator: Coordinator) {
        field.setActive(false)
        field.delegate = nil
        field.removeTarget(coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.onMove = nil
        field.onSubmit = nil
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ field: UITextField) {
            let value = field.text ?? ""
            if text.wrappedValue != value { text.wrappedValue = value }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            if let field = textField as? ModelPickerSearchTextField {
                field.submitSearchReturn()
            }
            return false
        }
    }
}

/// Callbacks and activation are internal so tests exercise the real, final UIKit field.
/// Submission (including empty results) is the caller's decision; the field retains focus.
final class ModelPickerSearchTextField: UISearchTextField {
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?

    private static let focusOwners = NSMapTable<UIWindow, ModelPickerSearchTextField>.weakToWeakObjects()
    private var isActive = false
    private var requestedFocus = false
    private var focusToken: UUID?
    private var focusTask: Task<Void, Never>?
    private weak var focusWindow: UIWindow?
    private weak var initialFirstResponder: UIView?
    private var forwardingHardwarePress = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        placeholder = String(localized: "Search models")
        accessibilityTraits.insert(.searchField)
        returnKeyType = .search
        enablesReturnKeyAutomatically = false
        autocorrectionType = .no
        autocapitalizationType = .none
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: CGSize {
        let native = super.intrinsicContentSize
        return CGSize(width: native.width, height: max(36, native.height, ceil(font?.lineHeight ?? 0) + 14))
    }

    func updateUITextFromBinding(_ value: String) {
        guard text != value, markedTextRange == nil else { return }
        text = value
    }

    /// An activation gets one bounded focus request, never another on ordinary view updates.
    func setActive(_ active: Bool) {
        if !active {
            isActive = false
            cancelFocusRequest()
            if isFirstResponder { resignFirstResponder() }
            return
        }
        guard !isActive else { return }
        isActive = true
        requestedFocus = false
        requestFocusIfAttached()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        cancelFocusRequest()
        if window == nil {
            if isFirstResponder { resignFirstResponder() }
        } else {
            requestFocusIfAttached()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            requestedFocus = true
            cancelFocusRequest()
        }
        return became
    }

    private func requestFocusIfAttached() {
        guard isActive, !requestedFocus, let window else { return }
        requestedFocus = true
        Self.focusOwners.object(forKey: window)?.cancelFocusRequest()
        Self.focusOwners.setObject(self, forKey: window)
        focusWindow = window
        func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let responder = firstResponder(in: child) { return responder }
            }
            return nil
        }
        initialFirstResponder = firstResponder(in: window)
        let token = UUID()
        focusToken = token
        focusTask = Task { @MainActor [weak self] in
            // Attachment may precede the popover's first layout/key-window transition.
            for _ in 0..<6 {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
                guard !Task.isCancelled, self?.attemptFocus(token: token) == false else { return }
            }
            if self?.focusToken == token { self?.cancelFocusRequest() }
        }
    }

    private func attemptFocus(token: UUID) -> Bool {
        guard focusToken == token, isActive, let window, window === focusWindow,
              Self.focusOwners.object(forKey: window) === self else { return true }
        // Transfer from the activation's responder, but respect a later user focus change.
        func hasOtherResponder(_ view: UIView) -> Bool {
            // Text controls can expose an internal editor as first responder too.
            if view === self || view === initialFirstResponder { return false }
            return view.isFirstResponder || view.subviews.contains(where: hasOtherResponder)
        }
        if hasOtherResponder(window) {
            cancelFocusRequest()
            return true
        }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return false }
            ancestor = view.superview
        }
        guard window.isKeyWindow, bounds.width > 0, bounds.height > 0 else { return false }
        return becomeFirstResponder()
    }

    private func cancelFocusRequest() {
        focusToken = nil
        focusTask?.cancel()
        focusTask = nil
        if let focusWindow, Self.focusOwners.object(forKey: focusWindow) === self {
            Self.focusOwners.removeObject(forKey: focusWindow)
        }
        focusWindow = nil
        initialFirstResponder = nil
    }

    private var handlesPickerKeys: Bool {
        guard isActive, isFirstResponder, markedTextRange == nil, window?.isKeyWindow == true else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return false }
            ancestor = view.superview
        }
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let native = super.keyCommands ?? []
        guard handlesPickerKeys else { return native }
        let commands = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"].map {
            let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(handlePickerCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands + native
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handlePickerCommand(_:)) {
            guard handlesPickerKeys, let command = sender as? UIKeyCommand else { return false }
            return command.modifierFlags.intersection([.shift, .control, .alternate, .command]).isEmpty
                && isPickerInput(command.input)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    private func isPickerInput(_ input: String?) -> Bool {
        [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"].contains { $0 == input }
    }

    @objc private func handlePickerCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        handleKeyboardInput(input, modifiers: command.modifierFlags)
    }

    @discardableResult
    func handleKeyboardInput(_ input: String, modifiers: UIKeyModifierFlags) -> Bool {
        guard handlesPickerKeys,
              modifiers.intersection([.shift, .control, .alternate, .command]).isEmpty else { return false }
        switch input {
        case UIKeyCommand.inputUpArrow: onMove?(-1)
        case UIKeyCommand.inputDownArrow: onMove?(1)
        case "\r", "\n": onSubmit?()
        default: return false
        }
        return true
    }

    func submitSearchReturn() {
        guard !forwardingHardwarePress else { return }
        handleKeyboardInput("\n", modifiers: [])
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = presses
        for press in presses {
            guard let key = press.key else { continue }
            let input: String
            switch key.keyCode {
            case .keyboardUpArrow: input = UIKeyCommand.inputUpArrow
            case .keyboardDownArrow: input = UIKeyCommand.inputDownArrow
            case .keyboardReturnOrEnter, .keypadEnter: input = "\r"
            default: input = key.charactersIgnoringModifiers
            }
            if handleKeyboardInput(input, modifiers: key.modifierFlags) { unhandled.remove(press) }
        }
        // Consumed hardware Return never enters UITextField's software-return delegate path.
        if !unhandled.isEmpty {
            forwardingHardwarePress = true
            defer { forwardingHardwarePress = false }
            super.pressesBegan(unhandled, with: event)
        }
    }
}
#endif
