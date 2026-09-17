import SwiftUI
import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class ComposerKeyboardTests: XCTestCase {
    func testSuggestionArrowsAndTabArePriorityCommandsOnlyWhileMenuIsOpenAndCopiesKeepFocus() throws {
        let editor = makeEditor()
        let window = try showEditor(editor)
        defer { window.isHidden = true }
        editor.hasSuggestionMenu = true
        var offsets: [Int] = []
        var completions = 0
        editor.onMoveSuggestion = { offsets.append($0); return true }
        editor.onCompleteSuggestion = { completions += 1; return true }
        editor.onCommitSuggestion = { XCTFail("Tab must not execute a suggestion"); return true }
        editor.onSubmit = { XCTFail("Tab must not send") }
        let up = try command(UIKeyCommand.inputUpArrow, in: editor)
        let down = try command(UIKeyCommand.inputDownArrow, in: editor)
        let tab = try command("\t", in: editor)

        for key in [up, down, tab] {
            XCTAssertTrue(key.wantsPriorityOverSystemBehavior)
            try dispatch(key, to: editor)
            try dispatch(XCTUnwrap(key.copy() as? UIKeyCommand), to: editor)
        }
        XCTAssertEqual(offsets, [-1, -1, 1, 1])
        XCTAssertEqual(completions, 2)
        XCTAssertTrue(editor.handleKeyboardInput("\t", modifiers: []))
        XCTAssertEqual(completions, 3)

        editor.hasSuggestionMenu = false
        for key in [up, down, tab] {
            let action = try XCTUnwrap(key.action)
            XCTAssertFalse(editor.keyCommands?.contains { $0.action == action } ?? false)
            XCTAssertFalse(editor.canPerformAction(action, withSender: key))
        }
        for input in ["\r", "\n"] {
            XCTAssertFalse(try command(input, in: editor).wantsPriorityOverSystemBehavior)
        }
        XCTAssertTrue(editor.isFirstResponder)
    }

    func testReturnAndEnterCommitBeforeSendEvenWhenSubmissionIsDisabled() throws {
        let editor = makeEditor()
        let window = try showEditor(editor)
        defer { window.isHidden = true }
        editor.hasSuggestionMenu = true
        var commits = 0
        editor.onCommitSuggestion = { commits += 1; return true }
        editor.onSubmit = { XCTFail("Accepting a suggestion must not also send") }

        for canSubmit in [false, true] {
            editor.canSubmit = canSubmit
            for input in ["\r", "\n"] {
                let key = try command(input, in: editor)
                XCTAssertTrue(key.wantsPriorityOverSystemBehavior)
                try dispatch(key, to: editor)
                try dispatch(XCTUnwrap(key.copy() as? UIKeyCommand), to: editor)
            }
        }
        XCTAssertEqual(commits, 8)
    }

    func testNoMenuReturnSendsOnlyAfterCommitDeclinesAndRespectsCanSubmit() throws {
        let editor = makeEditor()
        let window = try showEditor(editor)
        defer { window.isHidden = true }
        var calls: [String] = []
        editor.onCommitSuggestion = { calls.append("commit"); return false }
        editor.onSubmit = { calls.append("send") }

        for input in ["\r", "\n"] {
            editor.canSubmit = true
            calls = []
            try dispatch(command(input, in: editor), to: editor)
            XCTAssertEqual(calls, ["commit", "send"])

            editor.canSubmit = false
            calls = []
            XCTAssertTrue(editor.handleKeyboardInput(input, modifiers: []))
            XCTAssertEqual(calls, ["commit"])
        }

        editor.onCommitSuggestion = nil
        editor.canSubmit = true
        calls = []
        try dispatch(command("\r", in: editor), to: editor)
        XCTAssertEqual(calls, ["send"])
    }

    func testModifiedAndUnrelatedKeysFallThroughWithoutInvokingCallbacks() {
        let editor = makeEditor()
        editor.hasSuggestionMenu = true
        editor.canSubmit = true
        editor.onMoveSuggestion = { _ in XCTFail("Modified arrow moved selection"); return true }
        editor.onCommitSuggestion = { XCTFail("Modified Return committed selection"); return true }
        editor.onCompleteSuggestion = { XCTFail("Modified Tab completed selection"); return true }
        editor.onSubmit = { XCTFail("Modified key sent a message") }

        let modifiers: [UIKeyModifierFlags] = [.shift, .control, .alternate, .command, [.command, .shift]]
        for modifier in modifiers {
            for input in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, "\r", "\n", "\t"] {
                XCTAssertFalse(editor.handleKeyboardInput(input, modifiers: modifier), "\(input), \(modifier)")
            }
        }
        for input in ["a", UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
            XCTAssertFalse(editor.handleKeyboardInput(input, modifiers: []))
        }

        editor.hasSuggestionMenu = false
        editor.onCompleteSuggestion = { false }
        XCTAssertFalse(editor.handleKeyboardInput("\t", modifiers: []))
        editor.onCompleteSuggestion = nil
        XCTAssertFalse(editor.handleKeyboardInput("\t", modifiers: []))
        editor.onMoveSuggestion = { _ in false }
        XCTAssertFalse(editor.handleKeyboardInput(UIKeyCommand.inputUpArrow, modifiers: []))
        editor.onMoveSuggestion = nil
        XCTAssertFalse(editor.handleKeyboardInput(UIKeyCommand.inputDownArrow, modifiers: []))
    }

    func testShiftReturnUsesExistingNewlineActionWithoutCommittingOrSending() throws {
        let editor = makeEditor()
        let window = try showEditor(editor)
        defer { window.isHidden = true }
        editor.hasSuggestionMenu = true
        editor.canSubmit = true
        editor.text = "draft"
        editor.selectedRange = NSRange(location: 5, length: 0)
        editor.onCommitSuggestion = { XCTFail("Shift-Return committed a suggestion"); return true }
        editor.onSubmit = { XCTFail("Shift-Return sent the draft") }

        XCTAssertFalse(editor.handleKeyboardInput("\r", modifiers: .shift))
        let newline = try command("\r", modifiers: .shift, in: editor)
        try dispatch(newline, to: editor)
        XCTAssertEqual(editor.text, "draft\n")
        try dispatch(XCTUnwrap(newline.copy() as? UIKeyCommand), to: editor)
        XCTAssertEqual(editor.text, "draft\n\n")
    }

    func testMarkedTextSuppressesCommandsAndSharedHandlerUntilCompositionEnds() throws {
        let editor = makeEditor()
        let window = try showEditor(editor)
        defer { window.isHidden = true }
        editor.hasSuggestionMenu = true
        editor.canSubmit = true
        let keys = try [
            command(UIKeyCommand.inputUpArrow, in: editor),
            command(UIKeyCommand.inputDownArrow, in: editor),
            command("\r", in: editor),
            command("\n", in: editor),
            command("\t", in: editor),
            command("\r", modifiers: .shift, in: editor),
        ]
        var calls: [String] = []
        editor.onMoveSuggestion = { _ in calls.append("move"); return true }
        editor.onCommitSuggestion = { calls.append("commit"); return true }
        editor.onCompleteSuggestion = { calls.append("complete"); return true }
        editor.onSubmit = { calls.append("send") }
        editor.setMarkedText("composing", selectedRange: NSRange(location: 9, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        let markedText = editor.text

        for key in keys {
            let action = try XCTUnwrap(key.action)
            XCTAssertFalse(editor.keyCommands?.contains { $0.action == action } ?? false)
            XCTAssertFalse(editor.canPerformAction(action, withSender: key))
            XCTAssertFalse(editor.handleKeyboardInput(try XCTUnwrap(key.input), modifiers: key.modifierFlags))
            // Even a previously registered command delivered during composition must be harmless.
            _ = editor.perform(action, with: try XCTUnwrap(key.copy() as? UIKeyCommand))
        }
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(editor.text, markedText)
        XCTAssertTrue(editor.isFirstResponder)

        editor.unmarkText()
        XCTAssertNil(editor.markedTextRange)
        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try dispatch(command("\r", in: editor), to: editor)
        try dispatch(command("\t", in: editor), to: editor)
        XCTAssertEqual(calls, ["move", "commit", "complete"])
    }

    func testHostedSlashMenuSelectsRankedCommandResetsQueryAndConsumesEmptyResults() async throws {
        let draft = MessageComposerDraftStore(text: "/re")
        var selected: [String] = []
        var sends = 0
        let host = UIHostingController(rootView: ComposerKeyboardFixture(
            draftStore: draft,
            commands: ["review", "read-file", "read"].map {
                OpenCodeCommand(name: $0, description: nil, agent: nil, model: nil,
                    source: nil, template: "", subtask: nil, hints: [])
            },
            onSend: { sends += 1 },
            onSelectCommand: { selected.append($0.name) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertTrue(editor.hasSuggestionMenu)
        XCTAssertTrue(editor.canSubmit)

        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try await settle(host)
        try dispatch(command("\r", in: editor), to: editor)
        XCTAssertEqual(selected, ["read-file"], "Arrow selection must reach the real command callback")
        XCTAssertEqual(sends, 0)

        // The selected ID still matches the new query, but a query change must reset to rank one.
        draft.text = "/read"
        try await settle(host)
        XCTAssertEqual(editor.text, "/read")
        try dispatch(command("\n", in: editor), to: editor)
        XCTAssertEqual(selected, ["read-file", "read"])
        XCTAssertEqual(sends, 0)

        draft.text = "/no-matching-command"
        try await settle(host)
        XCTAssertTrue(editor.hasSuggestionMenu)
        XCTAssertTrue(editor.canSubmit)
        let emptyMenuSelection = editor.selectedRange
        XCTAssertTrue(editor.handleKeyboardInput("\t", modifiers: []))
        try dispatch(command("\t", in: editor), to: editor)
        try await settle(host)
        XCTAssertEqual(draft.text, "/no-matching-command")
        XCTAssertEqual(editor.text, draft.text)
        XCTAssertEqual(editor.selectedRange, emptyMenuSelection)
        XCTAssertTrue(editor.hasSuggestionMenu)
        XCTAssertEqual(selected, ["read-file", "read"])
        XCTAssertEqual(sends, 0, "An empty menu must consume Tab without executing or sending")
        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try dispatch(command("\r", in: editor), to: editor)
        XCTAssertEqual(selected, ["read-file", "read"])
        XCTAssertEqual(draft.text, "/no-matching-command")
        XCTAssertEqual(sends, 0, "An open menu with no matches must consume Return")

        draft.text = "ordinary message"
        try await settle(host)
        XCTAssertFalse(editor.hasSuggestionMenu)
        XCTAssertFalse(editor.handleKeyboardInput(UIKeyCommand.inputDownArrow, modifiers: []))
        XCTAssertFalse(editor.handleKeyboardInput("\t", modifiers: []))
        try dispatch(command("\r", in: editor), to: editor)
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(selected, ["read-file", "read"])
    }

    func testHostedSlashTabCompletesWithoutExecutingAndArgumentsThenSendNormally() async throws {
        let draft = MessageComposerDraftStore(text: "/re")
        var selected: [String] = []
        var sent: [String] = []
        var changedText: [String] = []
        let host = UIHostingController(rootView: ComposerKeyboardFixture(
            draftStore: draft,
            commands: ["read", "read-file", "review"].map {
                OpenCodeCommand(name: $0, description: nil, agent: nil, model: nil,
                    source: nil, template: "", subtask: nil, hints: [])
            },
            onSend: { sent.append(draft.text) },
            onSelectCommand: { selected.append($0.name) },
            onTextChange: { changedText.append($0) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: draft.text.utf16.count, length: 0)
        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try await settle(host)
        let tab = try command("\t", in: editor)
        try dispatch(XCTUnwrap(tab.copy() as? UIKeyCommand), to: editor)
        try await settle(host)

        XCTAssertEqual(draft.text, "/read-file ")
        XCTAssertEqual(editor.text, draft.text)
        XCTAssertEqual(changedText, ["/read-file "])
        XCTAssertEqual(editor.selectedRange, NSRange(location: "/read-file ".utf16.count, length: 0))
        XCTAssertTrue(selected.isEmpty)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertFalse(editor.hasSuggestionMenu, "The trailing space must close the slash menu")
        XCTAssertFalse(editor.handleKeyboardInput("\t", modifiers: []))
        XCTAssertTrue(editor.isFirstResponder)

        // Use the resulting caret and the real text-view delegate, not a replacement draft value.
        editor.insertText("README.md")
        try await settle(host)
        XCTAssertEqual(draft.text, "/read-file README.md")
        XCTAssertEqual(editor.text, draft.text)
        XCTAssertFalse(editor.hasSuggestionMenu)
        try dispatch(command("\r", in: editor), to: editor)
        XCTAssertEqual(sent, ["/read-file README.md"])
        XCTAssertTrue(selected.isEmpty)
    }

    func testHostedAgentTabCompletesMentionWithUTF16MetadataAndCaretAtEnd() async throws {
        let prefix = "\u{1F680} Please "
        let draft = MessageComposerDraftStore(text: prefix + "@")
        var changedText: [String] = []
        var changedMentions: [[OpenCodeAgentMention]] = []
        let host = UIHostingController(rootView: ComposerKeyboardFixture(
            draftStore: draft,
            agents: ["plan", "review"].map {
                OpenCodeAgent(name: $0, description: nil, mode: "subagent", hidden: nil, model: nil, variant: nil)
            },
            onSend: { XCTFail("Tab mention completion must not send") },
            onSelectCommand: { _ in XCTFail("Tab mention completion must not execute a command") },
            onTextChange: { changedText.append($0) },
            onAgentMentionsChange: { changedMentions.append($0) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: draft.text.utf16.count, length: 0)
        XCTAssertTrue(editor.hasSuggestionMenu)
        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try await settle(host)
        try dispatch(command("\t", in: editor), to: editor)
        try await settle(host)

        let expectedText = prefix + "@review "
        let mention = OpenCodeAgentMention(name: "review", content: "@review", start: 10, end: 17)
        XCTAssertEqual(draft.text, expectedText)
        XCTAssertEqual(editor.text, expectedText)
        XCTAssertEqual(draft.agentMentions, [mention])
        XCTAssertEqual(changedText, [expectedText])
        XCTAssertEqual(changedMentions, [[mention]])
        XCTAssertEqual(editor.selectedRange, NSRange(location: expectedText.utf16.count, length: 0))
        XCTAssertFalse(editor.hasSuggestionMenu)
        XCTAssertTrue(editor.isFirstResponder)
    }

    func testHostedQueryChangePreservesArrowSelectionBeforeContextSynchronization() async throws {
        let draft = MessageComposerDraftStore(text: "/re")
        var selected: [String] = []
        var sends = 0
        let host = UIHostingController(rootView: ComposerKeyboardFixture(
            draftStore: draft,
            commands: ["read", "read-file", "review"].map {
                OpenCodeCommand(name: $0, description: nil, agent: nil, model: nil,
                    source: nil, template: "", subtask: nil, hints: [])
            },
            onSend: { sends += 1 },
            onSelectCommand: { selected.append($0.name) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertTrue(editor.hasSuggestionMenu)
        let down = try command(UIKeyCommand.inputDownArrow, in: editor)

        // Do not yield: the existing callback sees the new draft before onChange synchronizes it.
        draft.text = "/read"
        try dispatch(down, to: editor)
        try await settle(host)
        XCTAssertEqual(editor.text, "/read")
        try dispatch(command("\r", in: editor), to: editor)

        XCTAssertEqual(selected, ["read-file"], "Context synchronization must not reset the new keyboard selection to read")
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(editor.isFirstResponder)
    }

    func testHostedAgentMenuInsertsSelectedMentionAndMetadataWithoutSending() async throws {
        let draft = MessageComposerDraftStore(text: "Please @")
        var changedText: [String] = []
        var changedMentions: [[OpenCodeAgentMention]] = []
        var sends = 0
        let host = UIHostingController(rootView: ComposerKeyboardFixture(
            draftStore: draft,
            agents: ["plan", "review"].map {
                OpenCodeAgent(name: $0, description: nil, mode: "subagent", hidden: nil, model: nil, variant: nil)
            },
            onSend: { sends += 1 },
            onSelectCommand: { _ in XCTFail("Agent selection invoked a slash command") },
            onTextChange: { changedText.append($0) },
            onAgentMentionsChange: { changedMentions.append($0) }
        ))
        let window = try show(host)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settle(host)
        let editor = try XCTUnwrap(findEditor(in: host.view))
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertTrue(editor.hasSuggestionMenu)
        try dispatch(command(UIKeyCommand.inputDownArrow, in: editor), to: editor)
        try await settle(host)
        let enter = try command("\r", in: editor)
        try dispatch(XCTUnwrap(enter.copy() as? UIKeyCommand), to: editor)
        try await settle(host)

        let mention = OpenCodeAgentMention(name: "review", content: "@review", start: 7, end: 14)
        XCTAssertEqual(draft.text, "Please @review ")
        XCTAssertEqual(editor.text, draft.text)
        XCTAssertEqual(draft.agentMentions, [mention])
        XCTAssertEqual(changedText, ["Please @review "])
        XCTAssertEqual(changedMentions, [[mention]])
        XCTAssertEqual(sends, 0)
        XCTAssertFalse(editor.hasSuggestionMenu)
        XCTAssertTrue(editor.isFirstResponder)
    }

    private func makeEditor() -> ComposerPlaceholderTextView {
        ComposerPlaceholderTextView(frame: CGRect(x: 0, y: 100, width: 300, height: 100), textContainer: nil)
    }

    private func showEditor(_ editor: ComposerPlaceholderTextView) throws -> UIWindow {
        let root = UIViewController()
        root.view.addSubview(editor)
        let window = try show(root)
        XCTAssertTrue(editor.becomeFirstResponder())
        return window
    }

    private func show(_ root: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return window
    }

    private func command(_ input: String, modifiers: UIKeyModifierFlags = [],
                         in editor: ComposerPlaceholderTextView) throws -> UIKeyCommand {
        try XCTUnwrap(editor.keyCommands?.first { $0.input == input && $0.modifierFlags == modifiers })
    }

    private func dispatch(_ command: UIKeyCommand, to editor: ComposerPlaceholderTextView) throws {
        let action = try XCTUnwrap(command.action)
        XCTAssertTrue(editor.canPerformAction(action, withSender: command))
        let target = try XCTUnwrap(editor.target(forAction: action, withSender: command) as? NSObject)
        XCTAssertTrue(target === editor)
        _ = target.perform(action, with: command)
        XCTAssertTrue(editor.isFirstResponder, "Keyboard suggestion handling must keep editor focus")
    }

    private func findEditor(in view: UIView) -> ComposerPlaceholderTextView? {
        if let editor = view as? ComposerPlaceholderTextView { return editor }
        return view.subviews.lazy.compactMap { self.findEditor(in: $0) }.first
    }

    private func settle(_ host: UIViewController) async throws {
        // Allow both the representable update and the suggestion-context onChange to render.
        for _ in 0..<2 {
            try await Task.sleep(for: .milliseconds(50))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
    }
}

@MainActor
private struct ComposerKeyboardFixture: View {
    let draftStore: MessageComposerDraftStore
    var commands: [OpenCodeCommand] = []
    var agents: [OpenCodeAgent] = []
    var onSend: () -> Void = {}
    var onSelectCommand: (OpenCodeCommand) -> Void = { _ in }
    var onTextChange: (String) -> Void = { _ in }
    var onAgentMentionsChange: ([OpenCodeAgentMention]) -> Void = { _ in }
    @Namespace private var glassNamespace

    var body: some View {
        MessageComposer(
            draftStore: draftStore,
            isAccessoryMenuOpen: .constant(false),
            commands: commands,
            mentionableAgents: agents,
            pinnedCommands: [],
            pinnedCommandNames: [],
            attachmentCount: 0,
            isBusy: false,
            canFork: false,
            forkableMessages: [],
            mcpServers: [],
            connectedMCPServerCount: 0,
            isLoadingMCP: false,
            togglingMCPServerNames: [],
            mcpErrorMessage: nil,
            onFocusChange: { _ in },
            onTextChange: onTextChange,
            onAgentMentionsChange: onAgentMentionsChange,
            onHeightChange: { _ in },
            onSend: onSend,
            onStop: {},
            onSelectCommand: onSelectCommand,
            onPinCommand: { _ in },
            onUnpinCommand: { _ in },
            onCompact: {},
            onForkMessage: { _ in },
            onLoadMCP: {},
            onToggleMCP: { _ in },
            onAddAttachments: { _ in },
            onOpenBrowser: nil,
            glassNamespace: glassNamespace
        )
        .transaction { $0.disablesAnimations = true }
    }
}
