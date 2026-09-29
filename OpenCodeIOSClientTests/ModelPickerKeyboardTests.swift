#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class ModelPickerKeyboardTests: XCTestCase {
    func testSelectionDefaultsToFirstAndWrapsInBothDirections() {
        var selection = ModelPickerKeyboardSelection()
        let context = ModelPickerKeyboardSelection.Context(query: "", ids: ["a", "b", "c"])
        XCTAssertEqual(selection.selectedID(in: context), "a")
        selection.move(by: -1, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "c")
        selection.move(by: 1, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "a")
        selection.move(by: 4, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "b")
        selection.move(by: -4, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "a")
    }

    func testQueryChangeResetsEvenWhenResultIDsAreUnchanged() {
        var selection = ModelPickerKeyboardSelection()
        let original = ModelPickerKeyboardSelection.Context(query: "sh", ids: ["alpha:shared", "beta:shared"])
        let changed = ModelPickerKeyboardSelection.Context(query: "shared", ids: original.ids)
        selection.move(by: 1, in: original)
        XCTAssertEqual(selection.selectedID(in: original), "beta:shared")
        XCTAssertEqual(selection.selectedID(in: changed), "alpha:shared")
        selection.synchronize(to: changed)
        XCTAssertEqual(selection.selectedID(in: changed), "alpha:shared")
    }

    func testScopeAndReorderedIDsResetSelection() {
        var selection = ModelPickerKeyboardSelection()
        let providers = ModelPickerKeyboardSelection.Context(query: "", ids: ["alpha", "beta"])
        let models = ModelPickerKeyboardSelection.Context(query: "", ids: ["beta:shared", "beta:only", "beta:last"])
        selection.move(by: 1, in: providers)
        XCTAssertEqual(selection.selectedID(in: providers), "beta")
        XCTAssertEqual(selection.selectedID(in: models), "beta:shared")
        selection.synchronize(to: models)
        selection.move(by: 1, in: models)
        XCTAssertEqual(selection.selectedID(in: models), "beta:only")

        let reordered = ModelPickerKeyboardSelection.Context(query: "", ids: models.ids.reversed())
        XCTAssertEqual(selection.selectedID(in: reordered), "beta:last", "Order changes must reset even if the selected ID survives")
        selection.synchronize(to: reordered)
        XCTAssertEqual(selection.selectedID(in: reordered), "beta:last")
        selection.synchronize(to: providers)
        XCTAssertEqual(selection.selectedID(in: providers), "alpha")
    }

    func testEmptyAndSingleResultContextsAreSafe() {
        var selection = ModelPickerKeyboardSelection()
        let single = ModelPickerKeyboardSelection.Context(query: "shared", ids: ["alpha:shared"])
        let empty = ModelPickerKeyboardSelection.Context(query: "missing", ids: [])
        selection.synchronize(to: single)
        for offset in [-1, 0, 1, 10] {
            selection.move(by: offset, in: single)
            XCTAssertEqual(selection.selectedID(in: single), "alpha:shared")
        }
        XCTAssertNil(selection.selectedID(in: empty))
        for offset in [-1, 0, 1] {
            selection.move(by: offset, in: empty)
            selection.synchronize(to: empty)
            XCTAssertNil(selection.selectedID(in: empty))
        }
        selection.synchronize(to: single)
        XCTAssertEqual(selection.selectedID(in: single), "alpha:shared")
    }

    func testDelayedSynchronizationDoesNotEraseFastMovesInNewContext() {
        var selection = ModelPickerKeyboardSelection()
        let original = ModelPickerKeyboardSelection.Context(query: "sh", ids: ["alpha:shared", "beta:shared"])
        let changed = ModelPickerKeyboardSelection.Context(query: "shared", ids: original.ids)
        selection.synchronize(to: original)
        // Keyboard input can arrive before SwiftUI's context onChange runs.
        selection.move(by: 1, in: changed)
        selection.synchronize(to: changed)
        XCTAssertEqual(selection.selectedID(in: changed), "beta:shared")
        selection.move(by: -1, in: changed)
        selection.synchronize(to: changed)
        XCTAssertEqual(selection.selectedID(in: changed), "alpha:shared")
    }

    func testHostedRootEnterPushesProviderAndNewFieldAutofocusesWithoutRootReclaiming() async throws {
        var selected: [OpenCodeModelReference] = []
        let (host, window) = try showPicker { selected.append($0) }
        let rootField = try await focusedField(in: host)
        try press(UIKeyCommand.inputDownArrow, in: rootField)
        try await settle(host)
        try press("\r", in: rootField)
        let providerField = try await focusedField(in: host, excluding: rootField)
        XCTAssertFalse(providerField === rootField)
        XCTAssertTrue(selected.isEmpty, "Root Return navigates, not selects a model")

        // Let navigation finish and outlive the root field's entire focus retry budget.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(window.isKeyWindow)
        XCTAssertTrue(providerField.isFirstResponder)
        XCTAssertFalse(rootField.isFirstResponder)
        XCTAssertFalse(rootField.handleKeyboardInput("\r", modifiers: []))
        try press(UIKeyCommand.inputDownArrow, in: providerField)
        try await settle(host)
        try press("\r", in: providerField)
        try await settle(host)
        XCTAssertEqual(selected, [OpenCodeModelReference(providerID: "beta", modelID: "beta-only")])
        XCTAssertTrue(providerField.isFirstResponder)
        XCTAssertFalse(rootField.isFirstResponder)
    }

    func testHostedGlobalQueryUsesProviderIdentityResetsSelectionAndEmptyReturnIsNoOp() async throws {
        var selected: [OpenCodeModelReference] = []
        let (host, _) = try showPicker { selected.append($0) }
        let field = try await focusedField(in: host)
        try await typeQuery("sh", into: field, host: host)
        try press(UIKeyCommand.inputDownArrow, in: field)
        try await settle(host)
        try press("\r", in: field)
        try await settle(host)
        XCTAssertEqual(selected, [OpenCodeModelReference(providerID: "beta", modelID: "shared")])

        // Both queries match the same IDs; the query itself must reset the highlight.
        field.insertText("ared")
        field.sendActions(for: .editingChanged)
        try await settle(host)
        XCTAssertEqual(field.text, "shared")
        try press("\n", in: field)
        try await settle(host)
        let expected = [
            OpenCodeModelReference(providerID: "beta", modelID: "shared"),
            OpenCodeModelReference(providerID: "alpha", modelID: "shared"),
        ]
        XCTAssertEqual(selected, expected)

        try await typeQuery("no-matching-model", into: field, host: host)
        try press(UIKeyCommand.inputUpArrow, in: field)
        try press(UIKeyCommand.inputDownArrow, in: field)
        try await settle(host)
        try press("\r", in: field)
        XCTAssertEqual(field.delegate?.textFieldShouldReturn?(field), false)
        try await settle(host)
        XCTAssertEqual(selected, expected, "Empty results must consume both hardware and software Return")
        XCTAssertEqual(field.text, "no-matching-model")
        XCTAssertTrue(field.isFirstResponder)
    }

    func testHostedProviderSearchCannotSelectModelsFromAnotherProvider() async throws {
        var selected: [OpenCodeModelReference] = []
        let (host, _) = try showPicker { selected.append($0) }
        let rootField = try await focusedField(in: host)
        try press("\r", in: rootField)
        let field = try await focusedField(in: host, excluding: rootField)

        try await typeQuery("beta-only", into: field, host: host)
        try press("\r", in: field)
        try await settle(host)
        XCTAssertTrue(selected.isEmpty, "Provider search must not fall back to global results")
        try await typeQuery("shared", into: field, host: host)
        XCTAssertEqual(field.delegate?.textFieldShouldReturn?(field), false)
        try await settle(host)
        XCTAssertEqual(selected, [OpenCodeModelReference(providerID: "alpha", modelID: "shared")])
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertFalse(rootField.isFirstResponder)
    }

    private func showPicker(onSelect: @escaping (OpenCodeModelReference) -> Void) throws -> (UIViewController, UIWindow) {
        let sections = ["alpha", "beta"].map { provider in
            ModelPickerSection(id: provider, name: provider.capitalized, models: [
                ModelPickerItem(providerID: provider, modelID: "shared", name: "Shared Model"),
                ModelPickerItem(providerID: provider, modelID: "\(provider)-only", name: "\(provider.capitalized) Only"),
            ])
        }
        let host = UIHostingController(rootView: ModelPickerPopover(
            sections: sections,
            selectedReference: nil,
            accessibilityIdentifierPrefix: "keyboard.models",
            onSelect: onSelect
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        return (host, window)
    }

    private func focusedField(in host: UIViewController, excluding previous: UITextField? = nil) async throws -> ModelPickerSearchTextField {
        var field: ModelPickerSearchTextField?
        try await waitUntil(host) {
            field = self.searchFields(in: host.view).first { $0 !== previous && $0.isFirstResponder }
            return field != nil
        }
        let focused = try XCTUnwrap(field, "The active page must autofocus its own native search field")
        XCTAssertEqual(focused.accessibilityIdentifier, "keyboard.models.search")
        return focused
    }

    private func searchFields(in view: UIView) -> [ModelPickerSearchTextField] {
        if let field = view as? ModelPickerSearchTextField { return [field] }
        return view.subviews.flatMap { searchFields(in: $0) }
    }

    private func press(_ input: String, in field: ModelPickerSearchTextField) throws {
        let command = try XCTUnwrap(field.keyCommands?.first { $0.input == input && $0.modifierFlags.isEmpty })
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        XCTAssertTrue(field.canPerformAction(action, withSender: command))
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: nil, from: command, for: nil))
        if input == UIKeyCommand.inputUpArrow || input == UIKeyCommand.inputDownArrow {
            XCTAssertTrue(field.isFirstResponder, "Arrows must move the highlight without moving text focus")
        }
    }

    private func typeQuery(_ query: String, into field: ModelPickerSearchTextField, host: UIViewController) async throws {
        XCTAssertTrue(field.isFirstResponder)
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        field.insertText(query)
        field.sendActions(for: .editingChanged)
        try await settle(host)
        XCTAssertEqual(field.text, query)
        XCTAssertTrue(field.isFirstResponder)
    }

    private func waitUntil(_ host: UIViewController, predicate: () -> Bool) async throws {
        for _ in 0..<40 {
            await Task.yield()
            host.view.layoutIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(predicate(), "Timed out waiting for picker UI lifecycle")
    }

    private func settle(_ host: UIViewController) async throws {
        // Allow the representable binding update and selection-context onChange to render.
        for _ in 0..<2 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(50))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
    }
}
#endif
