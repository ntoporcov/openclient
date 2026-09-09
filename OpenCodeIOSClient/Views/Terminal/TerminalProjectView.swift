import SwiftUI

struct TerminalProjectView: View {
    @ObservedObject var facade: TerminalFacade
    let onTerminalChosen: () -> Void

    private var snapshot: TerminalFacade.Snapshot { facade.snapshot }

    var body: some View {
        TerminalListContent(
            facade: facade,
            snapshot: snapshot,
            onTerminalChosen: onTerminalChosen
        )
        .task(id: snapshot.directory) {
            facade.prepareForPresentation()
        }
    }
}

private struct TerminalListContent: View {
    let facade: TerminalFacade
    let snapshot: TerminalFacade.Snapshot
    let onTerminalChosen: () -> Void

    var body: some View {
        Group {
            if snapshot.terminals.isEmpty {
                emptyContent
            } else {
                List {
                    Section("Terminal Sessions") {
                        ForEach(snapshot.terminals) { terminal in
                            Button {
                                facade.selectTerminal(id: terminal.id)
                                onTerminalChosen()
                            } label: {
                                TerminalListRow(
                                    terminal: terminal,
                                    isSelected: snapshot.activeTerminalID == terminal.id,
                                    connectionState: snapshot.connectionState
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(terminal.title)
                            .accessibilityIdentifier("terminal.row")
                            .swipeActions(edge: .trailing) {
                                Button("Close", systemImage: "xmark", role: .destructive) {
                                    facade.closeTerminal(id: terminal.id)
                                }
                            }
                            .contextMenu {
                                Button("Close Terminal", systemImage: "xmark", role: .destructive) {
                                    facade.closeTerminal(id: terminal.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    await facade.refreshTerminals()
                }
                .accessibilityIdentifier("terminal.list")
            }
        }
        .background(OpenCodePlatformColor.groupedBackground)
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label("No Terminal Sessions", systemImage: "terminal")
        } description: {
            if let errorMessage = snapshot.errorMessage {
                Text(errorMessage)
            } else {
                Text("Start a shell in this workspace.")
            }
        } actions: {
            Button("New Terminal") {
                facade.createTerminal()
            }
            .buttonStyle(.borderedProminent)
            .disabled(snapshot.isCreatingTerminal)
            .accessibilityIdentifier("terminal.create.empty")
        }
        .overlay {
            if snapshot.isLoadingTerminals || snapshot.isCreatingTerminal {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial, in: Circle())
            }
        }
    }
}

private struct TerminalListRow: View {
    let terminal: OpenClientTerminalTab
    let isSelected: Bool
    let connectionState: OpenClientTerminalConnectionState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(terminal.info.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    statusText
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var statusText: Text {
        if isSelected {
            switch connectionState {
            case .connecting:
                return Text("Connecting")
            case .connected:
                return Text("Connected")
            case .reconnecting:
                return Text("Reconnecting")
            case .disconnected:
                break
            }
        }
        switch terminal.info.status.lowercased() {
        case "running":
            return Text("Running")
        case "exited":
            return Text("Exited")
        case "completed":
            return Text("Completed")
        case "stopped":
            return Text("Stopped")
        case "error":
            return Text("Error")
        default:
            return Text(verbatim: terminal.info.status.capitalized)
        }
    }

    private var statusColor: SwiftUI.Color {
        if isSelected {
            switch connectionState {
            case .connected:
                return .green
            case .connecting, .reconnecting:
                return .orange
            case .disconnected:
                break
            }
        }
        return terminal.info.status == "running" ? .green : .secondary
    }
}

struct TerminalDetailView: View {
    @ObservedObject var facade: TerminalFacade
    let terminalID: String
    @State private var keyboardDismissalCount = 0
    @State private var pasteInvocationCount = 0

    private var snapshot: TerminalFacade.Snapshot { facade.snapshot }
    private var terminal: OpenClientTerminalTab? {
        snapshot.terminals.first { $0.id == terminalID }
    }

    var body: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            if terminal != nil {
                TerminalHostView(
                    facade: facade,
                    terminalID: terminalID,
                    tabsInset: 0,
                    controlsInset: 52,
                    fontSize: snapshot.fontSize
                )
                .id("\(snapshot.directory ?? ""):\(terminalID)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.keyboard, edges: .bottom)
            } else {
                ContentUnavailableView("Terminal Closed", systemImage: "terminal", description: Text("Return to the terminal list to open another session."))
            }
        }
        .overlay(alignment: .bottom) {
            if terminal != nil {
                TerminalModifierBar(
                    facade: facade,
                    snapshot: snapshot,
                    keyboardDismissalCount: $keyboardDismissalCount,
                    pasteInvocationCount: $pasteInvocationCount
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .navigationTitle(terminal?.title ?? String(localized: "Terminal", comment: "Fallback navigation title when a terminal has no title."))
        .opencodeInlineNavigationTitle()
        .toolbar {
            if terminal != nil {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Close Terminal", systemImage: "xmark", role: .destructive) {
                        facade.closeTerminal(id: terminalID)
                    }
                    .accessibilityIdentifier("terminal.close")
                }
            }
        }
    }
}

private struct TerminalModifierBar: View {
    let facade: TerminalFacade
    let snapshot: TerminalFacade.Snapshot
    @Binding var keyboardDismissalCount: Int
    @Binding var pasteInvocationCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                modifierGlassContainer
            }
            .contentShape(Rectangle())

            Button(action: dismissKeyboard) {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 38, height: 38)
            }
            .opencodeActionGlass(size: 38, in: Circle())
            .accessibilityLabel("Dismiss Keyboard")
            .accessibilityIdentifier("terminal.keyboard.dismiss")
            .accessibilityValue("\(keyboardDismissalCount)")
        }
    }

    @ViewBuilder
    private var modifierGlassContainer: some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 7) {
                modifierRow
            }
        } else {
            modifierRow
        }
#else
        modifierRow
#endif
    }

    private var modifierRow: some View {
        HStack(spacing: 7) {
            modifierButton(String(localized: "paste", comment: "Terminal modifier bar button that pastes clipboard text."), accessibilityIdentifier: "terminal.paste") {
                pasteClipboardText()
            }
            .accessibilityValue("\(pasteInvocationCount)")
            modifierButton(String(localized: "esc", comment: "Terminal Escape key label.")) { facade.sendSpecialKey(.escape) }
            modifierButton(String(localized: "tab", comment: "Terminal Tab key label.")) { facade.sendSpecialKey(.tab) }
            modifierButton(String(localized: "ctrl", comment: "Terminal Control modifier key label."), isActive: snapshot.isControlModifierActive) { facade.toggleControlModifier() }
            modifierButton(String(localized: "alt", comment: "Terminal Alternate modifier key label."), isActive: snapshot.isAltModifierActive) { facade.toggleAltModifier() }
            modifierButton("/") { facade.insertText("/") }
            modifierButton("|") { facade.insertText("|") }
            modifierButton("~") { facade.insertText("~") }
            modifierButton("-") { facade.insertText("-") }
            modifierButton("^C") { facade.sendSpecialKey(.interrupt) }
            modifierButton("←") { facade.sendSpecialKey(.left) }
            modifierButton("↓") { facade.sendSpecialKey(.down) }
            modifierButton("↑") { facade.sendSpecialKey(.up) }
            modifierButton("→") { facade.sendSpecialKey(.right) }
        }
        .padding(.vertical, 2)
    }

    private func modifierButton(
        _ title: String,
        isActive: Bool = false,
        accessibilityIdentifier: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 13)
                .frame(height: 38)
                .opencodeConcentricGlassSurface(
                    tint: isActive ? SwiftUI.Color.accentColor.opacity(0.22) : nil,
                    isInteractive: true,
                    minimumCornerRadius: 19,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier ?? "terminal.modifier.\(title)")
    }

    private func pasteClipboardText() {
        let text: String?
#if canImport(UIKit)
#if DEBUG
        text = ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_PASTE_TEXT"]
            ?? UIPasteboard.general.string
#else
        text = UIPasteboard.general.string
#endif
#else
        text = nil
#endif
        guard let text, !text.isEmpty else { return }
        pasteInvocationCount += 1
        facade.pasteText(text)
    }

    private func dismissKeyboard() {
        keyboardDismissalCount += 1
        facade.dismissKeyboard()
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        DispatchQueue.main.async {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
#endif
    }
}

#if canImport(UIKit) && canImport(GhosttyTerminal) && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import UIKit

private struct TerminalHostView: UIViewRepresentable {
    let facade: TerminalFacade
    let terminalID: String
    let tabsInset: CGFloat
    let controlsInset: CGFloat
    let fontSize: Float

    func makeCoordinator() -> Coordinator {
        Coordinator(facade: facade, terminalID: terminalID, fontSize: fontSize)
    }

    func makeUIView(context: Context) -> OpenCodeGhosttyContainerView {
        let terminal = OpenCodeGhosttyTerminalView(frame: .zero)
        let container = OpenCodeGhosttyContainerView(
            terminal: terminal,
            tabsInset: tabsInset,
            controlsInset: controlsInset,
            fontSize: fontSize,
            onFontSizeChange: { [weak facade, weak coordinator = context.coordinator] fontSize in
                facade?.setFontSize(fontSize)
                coordinator?.fontSizeDidChange()
            }
        )
        terminal.gestureRecognizers?
            .filter { $0 is UIPinchGestureRecognizer }
            .forEach(terminal.removeGestureRecognizer)
        context.coordinator.terminalView = terminal
        terminal.onLayoutReady = { [weak coordinator = context.coordinator] terminal in
            coordinator?.ensurePresentationReady(in: terminal)
        }
        terminal.onSoftwareText = { [weak coordinator = context.coordinator] text in
            coordinator?.sendSoftwareText(text)
        }
        terminal.delegate = context.coordinator
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(context.coordinator.session),
            fontSize: fontSize
        )
        terminal.controller = context.coordinator.controller
        terminal.inputAccessoryItems = []
        terminal.backgroundColor = .clear
        terminal.isOpaque = false
        terminal.isAccessibilityElement = true
        terminal.accessibilityIdentifier = "terminal.viewport"
        terminal.accessibilityLabel = String(localized: "Terminal viewport", comment: "Accessibility label for the interactive terminal output surface.")
        terminal.accessibilityValue = "0.000"
        terminal.setStickyModifierChangeHandler { [weak coordinator = context.coordinator] in
            coordinator?.syncModifierStateFromTerminal()
        }

        facade.attachRenderer(
            rendererID: context.coordinator.rendererID,
            terminalID: terminalID,
            output: { [weak coordinator = context.coordinator] output in
                coordinator?.receive(output)
            },
            input: TerminalFacade.RendererInput(
                insertText: { [weak terminal] text in terminal?.insertText(text) },
                pasteText: { [weak terminal] text in terminal?.pasteText(text) },
                setControlModifier: { [weak coordinator = context.coordinator] isActive in
                    coordinator?.setStickyModifier(.ctrl, active: isActive)
                },
                setAltModifier: { [weak coordinator = context.coordinator] isActive in
                    coordinator?.setStickyModifier(.alt, active: isActive)
                },
                sendSpecialKey: { [weak coordinator = context.coordinator] key in coordinator?.send(key) },
                focus: { [weak terminal] in _ = terminal?.becomeFirstResponder() },
                dismissKeyboard: { [weak terminal] in
                    _ = terminal?.resignFirstResponder()
                    terminal?.window?.endEditing(true)
                }
            )
        )
        return container
    }

    func updateUIView(_ container: OpenCodeGhosttyContainerView, context: Context) {
        context.coordinator.terminalID = terminalID
        container.updateInsets(tabs: tabsInset, controls: controlsInset)
        container.updateFontSize(fontSize)
    }

    static func dismantleUIView(_ container: OpenCodeGhosttyContainerView, coordinator: Coordinator) {
        let terminal = container.terminal
        _ = terminal.resignFirstResponder()
        terminal.onLayoutReady = nil
        terminal.onSoftwareText = nil
        terminal.setStickyModifierChangeHandler(nil)
        terminal.delegate = nil
    }

    @MainActor
    final class OpenCodeGhosttyContainerView: UIView, UIGestureRecognizerDelegate {
        let terminal: OpenCodeGhosttyTerminalView
        private var topConstraint: NSLayoutConstraint!
        private var bottomConstraint: NSLayoutConstraint!
        private var fontSize: Float
        private var lastPinchScale: CGFloat = 1
        private let onFontSizeChange: (Float) -> Void

        init(
            terminal: OpenCodeGhosttyTerminalView,
            tabsInset: CGFloat,
            controlsInset: CGFloat,
            fontSize: Float,
            onFontSizeChange: @escaping (Float) -> Void
        ) {
            self.terminal = terminal
            self.fontSize = fontSize
            self.onFontSizeChange = onFontSizeChange
            super.init(frame: .zero)
            backgroundColor = .clear
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            let focusTap = UITapGestureRecognizer(target: self, action: #selector(refocusTerminal))
            focusTap.cancelsTouchesInView = false
            focusTap.delaysTouchesBegan = false
            focusTap.delaysTouchesEnded = false
            focusTap.delegate = self
            addGestureRecognizer(focusTap)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(resizeTerminalFont(_:)))
            pinch.delegate = self
            addGestureRecognizer(pinch)
            topConstraint = terminal.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor,
                constant: tabsInset
            )
            bottomConstraint = terminal.bottomAnchor.constraint(
                equalTo: keyboardLayoutGuide.topAnchor,
                constant: -controlsInset
            )
            NSLayoutConstraint.activate([
                topConstraint,
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                bottomConstraint
            ])
        }

        required init?(coder: NSCoder) {
            nil
        }

        func updateInsets(tabs: CGFloat, controls: CGFloat) {
            topConstraint.constant = tabs
            bottomConstraint.constant = -controls
        }

        func updateFontSize(_ fontSize: Float) {
            self.fontSize = fontSize
        }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard super.point(inside: point, with: event) else { return false }
            return terminal.frame.contains(point)
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func refocusTerminal() {
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, !terminal.isFirstResponder else { return }
                _ = terminal.becomeFirstResponder()
            }
        }

        @objc private func resizeTerminalFont(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                lastPinchScale = gesture.scale
            case .changed:
                let steps = Int((gesture.scale - lastPinchScale) / 0.1)
                guard steps != 0 else { return }
                lastPinchScale += CGFloat(steps) * 0.1
                var changed = false
                if steps > 0 {
                    for _ in 0 ..< steps where fontSize < 64 {
                        terminal.performBindingAction("increase_font_size:1")
                        fontSize += 1
                        changed = true
                    }
                } else {
                    for _ in 0 ..< abs(steps) where fontSize > 4 {
                        terminal.performBindingAction("decrease_font_size:1")
                        fontSize -= 1
                        changed = true
                    }
                }
                if changed {
                    terminal.fitToSize()
                }
            case .ended, .cancelled, .failed:
                lastPinchScale = 1
                onFontSizeChange(fontSize)
            default:
                break
            }
        }
    }

    @MainActor
    final class OpenCodeGhosttyTerminalView: UITerminalView {
        var onLayoutReady: ((OpenCodeGhosttyTerminalView) -> Void)?
        var onSoftwareText: ((String) -> Void)?
        private var allowsDirectTouchFocus = true
        private var pendingHardwareTextInput = false

        override func didMoveToWindow() {
            if window == nil {
                layer.sublayers?.forEach { $0.removeFromSuperlayer() }
                CATransaction.flush()
            }
            super.didMoveToWindow()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            onLayoutReady?(self)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let shouldDeferFocus = !isFirstResponder && touches.contains { $0.type == .direct }
            if shouldDeferFocus {
                allowsDirectTouchFocus = false
            }
            super.touchesBegan(touches, with: event)
            allowsDirectTouchFocus = true
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: { $0.key != nil }) {
                pendingHardwareTextInput = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.pendingHardwareTextInput = false
                }
            }
            super.pressesBegan(presses, with: event)
        }

        override func insertText(_ text: String) {
            guard !pendingHardwareTextInput else {
                pendingHardwareTextInput = false
                super.insertText(text)
                return
            }
            let hasStickyModifier = stickyActivation(for: .ctrl) != .inactive
                || stickyActivation(for: .alt) != .inactive
                || stickyActivation(for: .command) != .inactive
            let isMultilinePaste = text.count > 1 && text.contains(where: { $0.isNewline })
            guard markedTextRange == nil, !hasStickyModifier, !isMultilinePaste else {
                super.insertText(text)
                return
            }
            onSoftwareText?(text)
        }

        func pasteText(_ text: String) {
            super.insertText(text)
        }

        override func becomeFirstResponder() -> Bool {
            guard allowsDirectTouchFocus else { return false }
            return super.becomeFirstResponder()
        }
    }

    @MainActor
    final class TerminalSelectionViewController: UIViewController {
        var onDone: (() -> Void)?

        private let text: String
        private let anchorRange: NSRange?
        private var copyButton: UIBarButtonItem?
        private lazy var textView: UITextView = {
            let view = UITextView()
            view.isEditable = false
            view.isSelectable = true
            view.alwaysBounceVertical = true
            view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            view.backgroundColor = .clear
            view.textColor = .label
            view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.accessibilityIdentifier = "terminal.selection.text"
            return view
        }()

        init(text: String, anchorRange: NSRange?) {
            self.text = text
            self.anchorRange = anchorRange
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            title = String(localized: "Select Terminal Text", comment: "UIKit sheet title for selecting terminal output text.")
            view.backgroundColor = .systemBackground
            textView.text = text
            view.addSubview(textView)
            NSLayoutConstraint.activate([
                textView.topAnchor.constraint(equalTo: view.topAnchor),
                textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                textView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])

            let doneButton = UIBarButtonItem(
                barButtonSystemItem: .done,
                target: self,
                action: #selector(done)
            )
            doneButton.accessibilityIdentifier = "terminal.selection.done"
            let copyButton = UIBarButtonItem(
                title: String(localized: "Copy", comment: "UIKit toolbar button that copies selected terminal text."),
                style: .plain,
                target: self,
                action: #selector(copySelection)
            )
            copyButton.accessibilityIdentifier = "terminal.selection.copy"
            copyButton.accessibilityValue = "0"
            self.copyButton = copyButton
            navigationItem.rightBarButtonItems = [doneButton, copyButton]
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            _ = textView.becomeFirstResponder()
            let textLength = (textView.text as NSString).length
            if let anchorRange, NSMaxRange(anchorRange) <= textLength {
                textView.selectedRange = anchorRange
                textView.scrollRangeToVisible(anchorRange)
            } else {
                textView.selectAll(nil)
            }
        }

        @objc private func copySelection() {
            let source = textView.text as NSString
            let range = textView.selectedRange
            guard range.length > 0, NSMaxRange(range) <= source.length else { return }
            UIPasteboard.general.string = source.substring(with: range)
            copyButton?.accessibilityValue = "\(range.length)"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        @objc private func done() {
            dismiss(animated: true) { [weak self] in
                self?.onDone?()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject,
        TerminalSurfaceGridResizeDelegate,
        TerminalSurfaceLifecycleDelegate,
        TerminalSurfaceScrollbarDelegate,
        TerminalSurfaceBellDelegate,
        TerminalSurfaceTextSelectionRequestDelegate,
        UIAdaptivePresentationControllerDelegate
    {
        let facade: TerminalFacade
        let rendererID = UUID()
        var terminalID: String
        let controller: TerminalController
        weak var terminalView: OpenCodeGhosttyTerminalView?
        private weak var selectionNavigationController: UINavigationController?
        private var replayOutput: [String] = []
        private var replayOutputStartIndex = 0
        private var replayOutputByteCount = 0
        private var isSurfaceAttached = false
        private var isSurfaceReadyForOutput = false
        private var surfaceAttachmentCount = 0
        private var didRequestInitialFocus = false
        private var desiredControlModifier = false
        private var desiredAltModifier = false
        private var isApplyingModifierState = false
        private var applicationCursorMode = false
        private var cursorModeSequenceTail = ""
        private var receivedOutputByteCount = 0
        private var appliedOutputByteCount = 0
        private var sentInputByteCount = 0
        private var rejectedInputByteCount = 0

        lazy var session = InMemoryTerminalSession(
            write: { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.recordInput(data)
                }
            },
            resize: { [weak self] viewport in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.facade.resize(
                        terminalID: self.terminalID,
                        rows: Int(viewport.rows),
                        columns: Int(viewport.columns)
                    )
                }
            }
        )

        init(facade: TerminalFacade, terminalID: String, fontSize: Float) {
            self.facade = facade
            self.terminalID = terminalID
            let screenshotScene = ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"]
            let isScreenshot = screenshotScene == "terminal" || screenshotScene == "terminal-showcase"
            let configuration = TerminalConfiguration { builder in
                builder.withFontSize(fontSize)
                builder.withFontThicken(true)
                builder.withCursorStyle(.block)
                builder.withCursorStyleBlink(!isScreenshot)
                builder.withBackgroundOpacity(0)
                builder.withWindowPaddingX(4)
                builder.withWindowPaddingY(2)
            }
            let lightTheme = TerminalConfiguration(startingFrom: .alabaster) { builder in
                builder.withBackground("F2F2F7")
                builder.withForeground("1C1C1E")
                builder.withCursorColor("007AFF")
            }
            let darkTheme = TerminalConfiguration(startingFrom: .afterglow) { builder in
                builder.withBackground("000000")
                builder.withForeground("F2F2F7")
                builder.withCursorColor("0A84FF")
            }
            controller = TerminalController(
                configuration: configuration,
                theme: TerminalTheme(light: lightTheme, dark: darkTheme)
            )
        }

        func ensurePresentationReady(in terminal: OpenCodeGhosttyTerminalView) {
            guard !didRequestInitialFocus else { return }
            didRequestInitialFocus = true
            guard ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != "terminal-showcase" else { return }
            DispatchQueue.main.async { [weak terminal] in
                guard let terminal, terminal.window != nil else { return }
                _ = terminal.becomeFirstResponder()
            }
        }

        func receive(_ output: String) {
            let byteCount = output.utf8.count
            receivedOutputByteCount += byteCount
            replayOutput.append(output)
            replayOutputByteCount += byteCount
            while replayOutputByteCount > 2 * 1_024 * 1_024,
                  replayOutputStartIndex < replayOutput.count - 1
            {
                replayOutputByteCount -= replayOutput[replayOutputStartIndex].utf8.count
                replayOutputStartIndex += 1
            }
            if replayOutputStartIndex > 256, replayOutputStartIndex * 2 > replayOutput.count {
                replayOutput.removeFirst(replayOutputStartIndex)
                replayOutputStartIndex = 0
            }
            updateApplicationCursorMode(with: output)
            guard isSurfaceReadyForOutput else {
                scheduleAccessibilityTranscriptUpdate()
                return
            }
            session.receive(output)
            appliedOutputByteCount += output.utf8.count
            scheduleAccessibilityTranscriptUpdate()
        }

        func send(_ key: TerminalFacade.SpecialKey) {
            let bytes: [UInt8] = switch key {
            case .escape:
                desiredAltModifier ? [0x1B, 0x1B] : [0x1B]
            case .tab:
                desiredAltModifier ? [0x1B, 0x09] : [0x09]
            case .interrupt:
                [0x03]
            case .left:
                arrowSequence(finalByte: 0x44)
            case .down:
                arrowSequence(finalByte: 0x42)
            case .up:
                arrowSequence(finalByte: 0x41)
            case .right:
                arrowSequence(finalByte: 0x43)
            }
            if case .interrupt = key {
                terminalView?.resetStickyModifiers()
            } else if desiredControlModifier || desiredAltModifier {
                terminalView?.resetStickyModifiers()
            }
            session.sendInput(Data(bytes))
        }

        func sendSoftwareText(_ text: String) {
            session.sendInput(Data(TerminalFacade.softwareInputBytes(for: text)))
        }

        func fontSizeDidChange() {
            scheduleAccessibilityTranscriptUpdate()
        }

        private func recordInput(_ data: Data) {
            if facade.send(Array(data), terminalID: terminalID, rendererID: rendererID) {
                sentInputByteCount += data.count
            } else {
                rejectedInputByteCount += data.count
            }
            scheduleAccessibilityTranscriptUpdate()
        }

        func setStickyModifier(_ modifier: TerminalPublicStickyModifier, active: Bool) {
            switch modifier {
            case .ctrl:
                desiredControlModifier = active
            case .alt:
                desiredAltModifier = active
            case .command:
                break
            }
            applyDesiredModifierState()
        }

        func syncModifierStateFromTerminal() {
            guard !isApplyingModifierState, let terminalView else { return }
            desiredControlModifier = terminalView.stickyActivation(for: .ctrl) != .inactive
            desiredAltModifier = terminalView.stickyActivation(for: .alt) != .inactive
            facade.syncModifierState(
                control: desiredControlModifier,
                alt: desiredAltModifier
            )
        }

        func terminalDidAttachSurface(_: TerminalSurface) {
            surfaceAttachmentCount += 1
            isSurfaceAttached = true
            isSurfaceReadyForOutput = false
            let attachment = surfaceAttachmentCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self,
                      isSurfaceAttached,
                      surfaceAttachmentCount == attachment else { return }
                isSurfaceReadyForOutput = true
                replayOutput[replayOutputStartIndex...].forEach { text in
                    session.receive(text)
                    appliedOutputByteCount += text.utf8.count
                }
                scheduleAccessibilityTranscriptUpdate()
            }
        }

        func terminalDidDetachSurface() {
            isSurfaceAttached = false
            isSurfaceReadyForOutput = false
        }

        func terminalDidResize(_ size: TerminalGridMetrics) {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                facade.resize(
                    terminalID: terminalID,
                    rows: Int(size.rows),
                    columns: Int(size.columns)
                )
            }
        }

        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) {
            let maximumOffset = scrollbar.total > scrollbar.len ? scrollbar.total - scrollbar.len : 0
            let position = maximumOffset == 0
                ? 1
                : min(1, Double(scrollbar.offset) / Double(maximumOffset))
            terminalView?.accessibilityValue = String(format: "%.3f", position)
            scheduleAccessibilityTranscriptUpdate()
        }

        func terminalDidRingBell() {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }

        func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
            guard selectionNavigationController == nil,
                  let terminalView,
                  let presenter = terminalView.enclosingViewController,
                  presenter.presentedViewController == nil else { return }
            _ = terminalView.resignFirstResponder()

            let selection = TerminalSelectionViewController(
                text: request.text,
                anchorRange: request.anchorRange
            )
            selection.onDone = { [weak self] in
                self?.restoreFocusAfterSelection()
            }
            let navigationController = UINavigationController(rootViewController: selection)
            navigationController.modalPresentationStyle = .pageSheet
            navigationController.sheetPresentationController?.detents = [.medium(), .large()]
            navigationController.sheetPresentationController?.prefersGrabberVisible = true
            navigationController.presentationController?.delegate = self
            selectionNavigationController = navigationController
            presenter.present(navigationController, animated: true)
        }

        func presentationControllerDidDismiss(_: UIPresentationController) {
            restoreFocusAfterSelection()
        }

        private func applyDesiredModifierState() {
            guard let terminalView else { return }
            isApplyingModifierState = true
            terminalView.resetStickyModifiers()
            if desiredControlModifier {
                terminalView.toggleStickyModifier(.ctrl)
            }
            if desiredAltModifier {
                terminalView.toggleStickyModifier(.alt)
            }
            isApplyingModifierState = false
            facade.syncModifierState(
                control: desiredControlModifier,
                alt: desiredAltModifier
            )
        }

        private func restoreFocusAfterSelection() {
            selectionNavigationController = nil
            _ = terminalView?.becomeFirstResponder()
        }

        private func arrowSequence(finalByte: UInt8) -> [UInt8] {
            let modifier = 1
                + (desiredAltModifier ? 2 : 0)
                + (desiredControlModifier ? 4 : 0)
            if modifier > 1 {
                return Array("\u{001B}[1;\(modifier)".utf8) + [finalByte]
            }
            return applicationCursorMode
                ? [0x1B, 0x4F, finalByte]
                : [0x1B, 0x5B, finalByte]
        }

        private func updateApplicationCursorMode(with output: String) {
            let probe = cursorModeSequenceTail + output
            let enabled = probe.range(of: "\u{001B}[?1h", options: .backwards)
            let disabled = probe.range(of: "\u{001B}[?1l", options: .backwards)
            switch (enabled, disabled) {
            case let (.some(enabled), .some(disabled)):
                applicationCursorMode = enabled.lowerBound > disabled.lowerBound
            case (.some, .none):
                applicationCursorMode = true
            case (.none, .some):
                applicationCursorMode = false
            case (.none, .none):
                break
            }
            cursorModeSequenceTail = String(probe.suffix(8))
        }

        private func scheduleAccessibilityTranscriptUpdate() {
#if DEBUG
            guard ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_MODE"] == "1" else { return }
            for delay in [0.15, 0.5, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    let transcript = session.readViewportText() ?? ""
                    let error = facade.snapshot.errorMessage.map { " error=\($0)" } ?? ""
                    let fontSize = facade.snapshot.fontSize
                    terminalView?.accessibilityLabel = "surface=\(isSurfaceAttached ? "attached" : "detached") mounts=\(surfaceAttachmentCount) rx=\(receivedOutputByteCount) applied=\(appliedOutputByteCount) tx=\(sentInputByteCount) rejected=\(rejectedInputByteCount) font=\(fontSize)\(error)\n\(transcript)"
                }
            }
#endif
        }
    }
}

private extension UIView {
    var enclosingViewController: UIViewController? {
        var responder: UIResponder? = self
        while let nextResponder = responder?.next {
            if let viewController = nextResponder as? UIViewController {
                return viewController
            }
            responder = nextResponder
        }
        return nil
    }
}
#else
private struct TerminalHostView: View {
    let facade: TerminalFacade
    let terminalID: String
    let tabsInset: CGFloat
    let controlsInset: CGFloat
    let fontSize: Float

    var body: some View {
        ContentUnavailableView("Unavailable", systemImage: "terminal")
    }
}
#endif
