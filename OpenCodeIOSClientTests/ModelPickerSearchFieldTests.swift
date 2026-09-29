#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class ModelPickerSearchFieldTests: XCTestCase {
    func testCopiedCommandsUseApplicationResponderChainAndKeepFocus() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "model"
        var offsets: [Int] = []
        var submissions = 0
        field.onMove = { offsets.append($0) }
        field.onSubmit = { submissions += 1 }

        for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"] {
            let command = try command(input, in: field)
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
            XCTAssertTrue(command.modifierFlags.isEmpty)
            try dispatch(command, to: field)
            try dispatch(XCTUnwrap(command.copy() as? UIKeyCommand), to: field)
        }
        XCTAssertEqual(offsets, [-1, -1, 1, 1])
        XCTAssertEqual(submissions, 4)
        XCTAssertEqual(field.text, "model")
        XCTAssertTrue(field.isFirstResponder)
    }

    func testSharedPressHandlerAndSoftwareSearchSubmitExactlyOnceIncludingEmptyQuery() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        let coordinator = ModelPickerSearchField.Coordinator(text: .constant(""))
        field.delegate = coordinator
        var calls: [String] = []
        let results: [String] = []
        var selectedModels: [String] = []
        field.onMove = { calls.append("move:\($0)") }
        // An empty result list is intentionally handled by the caller, not by this field.
        field.onSubmit = {
            calls.append("submit")
            if let model = results.first { selectedModels.append(model) }
        }

        XCTAssertTrue(field.handleKeyboardInput(UIKeyCommand.inputUpArrow, modifiers: []))
        XCTAssertTrue(field.handleKeyboardInput(UIKeyCommand.inputDownArrow, modifiers: []))
        for input in ["\r", "\n"] {
            let before = calls.count
            XCTAssertTrue(field.handleKeyboardInput(input, modifiers: []))
            XCTAssertEqual(calls.count, before + 1)
        }
        let before = calls.count
        XCTAssertEqual(field.delegate?.textFieldShouldReturn?(field), false)
        XCTAssertEqual(calls.count, before + 1)
        XCTAssertEqual(calls, ["move:-1", "move:1", "submit", "submit", "submit"])
        XCTAssertTrue(selectedModels.isEmpty)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue((field.text ?? "").isEmpty)
    }

    func testModifiedAndNativeEditingKeysDoNotInvokePickerCallbacks() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        field.onMove = { _ in XCTFail("Modified key moved selection") }
        field.onSubmit = { XCTFail("Modified key submitted") }
        let action = try XCTUnwrap(command("\r", in: field).action)
        let modifierSets: [UIKeyModifierFlags] = [.shift, .control, .alternate, .command, [.alphaShift, .shift], [.numericPad, .command]]
        for modifiers in modifierSets {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"] {
                XCTAssertFalse(field.handleKeyboardInput(input, modifiers: modifiers))
                let modified = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                XCTAssertFalse(field.canPerformAction(action, withSender: modified))
                _ = field.perform(action, with: modified)
            }
        }
        for input in ["a", "\t", UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
            XCTAssertFalse(field.handleKeyboardInput(input, modifiers: []))
        }
        field.insertText("native editing")
        XCTAssertEqual(field.text, "native editing")
        field.selectAll(nil)
        XCTAssertTrue(field.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        field.deleteBackward()
        XCTAssertEqual(field.text, "")
    }

    func testCapsLockAndNumericPadFlagsAllowPickerKeys() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        var offsets: [Int] = []
        var submissions = 0
        field.onMove = { offsets.append($0) }
        field.onSubmit = { submissions += 1 }
        let modifierSets: [UIKeyModifierFlags] = [.alphaShift, .numericPad, [.alphaShift, .numericPad]]
        for modifiers in modifierSets {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"] {
                XCTAssertTrue(field.handleKeyboardInput(input, modifiers: modifiers))
                let action = try XCTUnwrap(command(input, in: field).action)
                let flagged = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                try dispatch(XCTUnwrap(flagged.copy() as? UIKeyCommand), to: field)
            }
        }
        XCTAssertEqual(offsets, Array(repeating: [-1, -1, 1, 1], count: 3).flatMap { $0 })
        XCTAssertEqual(submissions, 12)
        XCTAssertTrue(field.isFirstResponder)
    }

    func testMarkedTextRejectsStaleCommandsAndBindingReplacementWithoutMutatingComposition() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        let keys = try [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n"].map {
            try command($0, in: field)
        }
        field.onMove = { _ in XCTFail("IME moved selection") }
        field.onSubmit = { XCTFail("IME submitted") }
        field.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        let text = field.text
        field.updateUITextFromBinding("stale binding")
        for key in keys {
            let action = try XCTUnwrap(key.action)
            XCTAssertFalse(field.canPerformAction(action, withSender: key))
            XCTAssertFalse(field.keyCommands?.contains { $0.action == action } ?? false)
            XCTAssertFalse(field.handleKeyboardInput(try XCTUnwrap(key.input), modifiers: []))
            _ = field.perform(action, with: try XCTUnwrap(key.copy() as? UIKeyCommand))
        }
        let coordinator = ModelPickerSearchField.Coordinator(text: .constant(""))
        XCTAssertFalse(coordinator.textFieldShouldReturn(field))
        XCTAssertEqual(field.text, text)
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertTrue(field.isFirstResponder)
        field.unmarkText()
        field.updateUITextFromBinding("external query")
        XCTAssertEqual(field.text, "external query")
    }

    func testUnchangedBindingPreservesSelectionAndEditingChangedWritesBinding() throws {
        var text = "models"
        let coordinator = ModelPickerSearchField.Coordinator(text: Binding(get: { text }, set: { text = $0 }))
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        XCTAssertTrue(field.becomeFirstResponder())
        field.updateUITextFromBinding(text)
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: start, to: start)
        field.updateUITextFromBinding(text)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: try XCTUnwrap(field.selectedTextRange).start), 2)
        field.addTarget(coordinator, action: #selector(ModelPickerSearchField.Coordinator.textChanged(_:)), for: .editingChanged)
        field.text = "changed"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(text, "changed")
        field.text = nil
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(text, "")
    }

    func testActiveFieldFocusesAfterAttachmentButNeverRefocusesOnOrdinaryUpdates() async throws {
        let field = ModelPickerSearchTextField()
        field.setActive(true)
        XCTAssertFalse(field.isFirstResponder)
        let window = try show(field)
        defer { window.isHidden = true }
        try await settleFocus()
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(field.resignFirstResponder())
        field.setActive(true)
        field.updateUITextFromBinding("new query")
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
    }

    func testHiddenFocusedFieldCannotNavigateOrSubmit() throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        let keys = try [command(UIKeyCommand.inputDownArrow, in: field), command("\r", in: field)]
        field.onMove = { _ in XCTFail("Hidden page moved selection") }
        field.onSubmit = { XCTFail("Hidden page activated selection") }
        let ancestor = try XCTUnwrap(field.superview)
        for hidden in [true, false] {
            ancestor.isHidden = hidden
            ancestor.alpha = hidden ? 1 : 0
            for key in keys {
                let action = try XCTUnwrap(key.action)
                XCTAssertFalse(field.canPerformAction(action, withSender: key))
                XCTAssertFalse(field.handleKeyboardInput(try XCTUnwrap(key.input), modifiers: []))
                _ = field.perform(action, with: key)
            }
        }
    }

    func testActivationTransfersFocusFromInitialComposerOrRootSearch() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        let frame = CGRect(x: 20, y: 100, width: 280, height: 40)
        let initialResponders: [UIView] = [UITextView(frame: frame), ModelPickerSearchTextField(frame: frame)]
        for initial in initialResponders {
            window.rootViewController?.view.addSubview(initial)
            XCTAssertTrue(initial.becomeFirstResponder())
            field.setActive(true)
            try await settleFocus()
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertFalse(initial.isFirstResponder)
            field.setActive(false)
            initial.removeFromSuperview()
        }
    }

    func testPendingActivationAndDeactivationRespectLaterUserSelectedField() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        let composer = UITextView(frame: CGRect(x: 20, y: 160, width: 280, height: 40))
        window.rootViewController?.view.addSubview(composer)
        XCTAssertTrue(composer.becomeFirstResponder())
        let other = UITextField(frame: CGRect(x: 20, y: 100, width: 280, height: 40))
        window.rootViewController?.view.addSubview(other)
        field.setActive(true)
        XCTAssertTrue(other.becomeFirstResponder())
        try await settleFocus()
        XCTAssertTrue(other.isFirstResponder)
        XCTAssertFalse(field.isFirstResponder)
        field.setActive(false)
        XCTAssertTrue(other.isFirstResponder)
        other.resignFirstResponder()
        field.setActive(true)
        field.setActive(false)
        XCTAssertTrue(other.becomeFirstResponder())
        try await settleFocus()
        XCTAssertTrue(other.isFirstResponder)
    }

    func testFocusRetriesThroughHiddenAndTransparentOpeningAncestors() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        let ancestor = try XCTUnwrap(field.superview)
        for hidden in [true, false] {
            ancestor.isHidden = hidden
            ancestor.alpha = hidden ? 1 : 0
            field.setActive(true)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(field.isFirstResponder)
            ancestor.isHidden = false
            ancestor.alpha = 1
            try await settleFocus()
            XCTAssertTrue(field.isFirstResponder)
            field.setActive(false)
        }
    }

    func testDeactivationRejectsCommandsAndDismantleCancelsPendingFocus() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        XCTAssertTrue(field.becomeFirstResponder())
        let key = try command("\r", in: field)
        let action = try XCTUnwrap(key.action)
        field.onSubmit = { XCTFail("Inactive field submitted") }
        field.setActive(false)
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertFalse(field.canPerformAction(action, withSender: key))
        XCTAssertFalse(field.handleKeyboardInput("\r", modifiers: []))
        _ = field.perform(action, with: key)
        field.setActive(true)
        let coordinator = ModelPickerSearchField.Coordinator(text: .constant(""))
        ModelPickerSearchField.dismantleUIView(field, coordinator: coordinator)
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertNil(field.onSubmit)
        XCTAssertNil(field.onMove)
        XCTAssertNil(field.delegate)
    }

    func testHiddenDetachedAndSupersededFieldsCannotTakePendingFocus() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.setActive(true)
        field.isHidden = true
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
        field.isHidden = false
        field.setActive(false)
        field.setActive(true)
        field.removeFromSuperview()
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)

        field.setActive(false)
        window.rootViewController?.view.addSubview(field)
        field.setActive(true)
        let newer = ModelPickerSearchTextField(frame: CGRect(x: 20, y: 100, width: 280, height: 36))
        newer.setActive(true)
        window.rootViewController?.view.addSubview(newer)
        // Dismiss the newer page before its first attempt. The older request stays cancelled.
        newer.setActive(false)
        newer.removeFromSuperview()
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertFalse(newer.isFirstResponder)
    }

    func testFocusRetriesAreBoundedEvenIfLayoutArrivesLater() async throws {
        let field = ModelPickerSearchTextField()
        let window = try show(field)
        defer { window.isHidden = true }
        field.frame = .zero
        field.setActive(true)
        try await settleFocus()
        field.frame = CGRect(x: 20, y: 40, width: 280, height: 36)
        field.setActive(true)
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
    }

    func testRepresentableRefreshesBindingCallbacksAndIdentifierWithoutRefocusing() async throws {
        var first = "first"
        var second = "second"
        var moves: [Int] = []
        var submissions = 0
        let host = UIHostingController(rootView: ModelPickerSearchField(
            text: Binding(get: { first }, set: { first = $0 }), isActive: true,
            accessibilityIdentifier: "first", onMove: { _ in XCTFail("Stale move") },
            onSubmit: { XCTFail("Stale submit") }
        ))
        let window = try show(host)
        defer { window.isHidden = true }
        try await settleFocus()
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? ModelPickerSearchTextField }.first)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(field.text, "first")
        host.rootView = ModelPickerSearchField(
            text: Binding(get: { second }, set: { second = $0 }), isActive: true,
            accessibilityIdentifier: "second", onMove: { moves.append($0) },
            onSubmit: { submissions += 1 }
        )
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await settleFocus()
        XCTAssertTrue(descendants(host.view).contains { $0 === field })
        XCTAssertEqual(field.text, "second")
        XCTAssertEqual(field.accessibilityIdentifier, "second")
        try dispatch(command(UIKeyCommand.inputDownArrow, in: field), to: field)
        try dispatch(command("\r", in: field), to: field)
        XCTAssertEqual(moves, [1])
        XCTAssertEqual(submissions, 1)
        field.text = "typed"
        field.sendActions(for: .editingChanged)
        XCTAssertEqual(second, "typed")
        XCTAssertEqual(first, "first")
        field.resignFirstResponder()
        host.rootView = ModelPickerSearchField(text: .constant("updated"), isActive: true,
            accessibilityIdentifier: "third", onMove: { _ in }, onSubmit: {})
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await settleFocus()
        XCTAssertFalse(field.isFirstResponder)
    }

    func testNativeConfigurationAndDynamicTypeHeight() {
        let field = ModelPickerSearchTextField()
        XCTAssertEqual(field.placeholder, String(localized: "Search models"))
        XCTAssertEqual(field.returnKeyType, .search)
        XCTAssertEqual(field.autocorrectionType, .no)
        XCTAssertEqual(field.autocapitalizationType, .none)
        XCTAssertFalse(field.enablesReturnKeyAutomatically)
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
        XCTAssertGreaterThanOrEqual(field.intrinsicContentSize.height, 36)
        field.font = .preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThanOrEqual(field.intrinsicContentSize.height, ceil(field.font?.lineHeight ?? 0) + 14)
    }

    private func command(_ input: String, in field: ModelPickerSearchTextField) throws -> UIKeyCommand {
        try XCTUnwrap(field.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
    }

    private func dispatch(_ command: UIKeyCommand, to field: ModelPickerSearchTextField) throws {
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(field.canPerformAction(action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil))
        XCTAssertTrue(field.isFirstResponder)
    }

    private func show(_ field: ModelPickerSearchTextField) throws -> UIWindow {
        let controller = UIViewController()
        field.frame = CGRect(x: 20, y: 40, width: 280, height: 36)
        controller.view.addSubview(field)
        return try show(controller)
    }

    private func show(_ controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        return window
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settleFocus() async throws {
        // Longer than the entire six-attempt focus budget, including cancelled requests.
        try await Task.sleep(for: .milliseconds(400))
    }
}
#endif
