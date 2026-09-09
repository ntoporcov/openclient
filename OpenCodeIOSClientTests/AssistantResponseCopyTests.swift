import XCTest
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenClient

@MainActor
final class AssistantResponseCopyTests: XCTestCase {
    func testTurnPlainTextExportParsesEachPartIndependently() {
        XCTAssertEqual(
            AssistantResponseCopy.plainText(parts: ["```swift\n    **literal**", "# **Next answer**"]),
            "    **literal**\n\nNext answer"
        )
    }

    func testMarkdownExcludesReasoningToolsAndSyntheticText() {
        let message = message(parts: [
            part(type: "reasoning", text: "Private reasoning"),
            part(type: "tool", text: "Tool text", state: OpenCodeToolState(
                status: "error", title: "Read file", error: "Tool failed",
                input: nil, output: "Tool output", metadata: nil
            )),
            part(text: "Synthetic context", synthetic: true),
            part(text: "The **answer**.")
        ])

        XCTAssertEqual(AssistantResponseCopy.markdown(in: message), "The **answer**.")
    }

    func testMarkdownExcludesTextMarkedAsReasoning() {
        let message = message(parts: [
            part(text: "Hidden text", reason: "MODEL REASONING"),
            part(text: "Visible answer", reason: "final", synthetic: false)
        ])

        XCTAssertEqual(AssistantResponseCopy.markdown(in: message), "Visible answer")
    }

    func testMarkdownNeverCopiesMessageErrorAsAnswer() {
        let error = OpenCodeSessionErrorPayload(name: "Provider failed", data: nil)
        XCTAssertNil(AssistantResponseCopy.markdown(in: message(parts: [], error: error)))
        XCTAssertEqual(
            AssistantResponseCopy.markdown(in: message(parts: [part(text: "Partial answer")], error: error)),
            "Partial answer"
        )
    }

    func testMarkdownReturnsNilWithoutAnswerParts() {
        for parts in [
            [],
            [part(type: "reasoning", text: "Thinking")],
            [part(type: "tool", text: "Tool output")],
            [part(text: "Generated context", synthetic: true)],
            [part(text: "Thinking", reason: "reasoning")]
        ] {
            XCTAssertNil(AssistantResponseCopy.markdown(in: message(parts: parts)))
        }
    }

    func testMarkdownReturnsNilForMissingEmptyOrWhitespaceOnlyText() {
        let texts: [String?] = [nil, "", " ", "\t\r\n \n"]
        for text in texts {
            XCTAssertNil(AssistantResponseCopy.markdown(in: message(parts: [part(text: text)])))
        }
    }

    func testMarkdownJoinsAnswerPartsInOrderAndPreservesRawMarkdown() {
        let first = "# Heading\n\n  **Bold** and [link](https://example.com)  "
        let second = "```swift\n    let value = `literal`\n```\n\n- [x] Finished"
        let message = message(parts: [
            part(text: "\n\n" + first + "\n"),
            part(text: nil),
            part(text: " \t\n"),
            part(type: "reasoning", text: "Do not include this separator"),
            part(text: "\n" + second + "\n\n", synthetic: false)
        ])

        XCTAssertEqual(AssistantResponseCopy.markdown(in: message), first + "\n\n" + second)
    }

    func testPlainTextPreservesEmptyInputAndParagraphBreaks() {
        for text in ["", "\n", "First line\nsecond line\n\nNext paragraph.\n"] {
            XCTAssertEqual(MarkdownMessageText.plainText(from: text), text)
        }
    }

    func testPlainTextRemovesSupportedHeadingMarkers() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "# **Title**\n\n## Section\n### Detail"),
            "Title\n\nSection\nDetail"
        )
    }

    func testPlainTextRemovesInlineEmphasis() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "**Bold** and *italic*, __strong__ and _emphasis_."),
            "Bold and italic, strong and emphasis."
        )
    }

    func testPlainTextPreservesLiteralMarkdownInsideInlineCode() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "Use `**literal**` and ``a `backtick` b``."),
            "Use **literal** and a `backtick` b."
        )
    }

    func testPlainTextIncludesLinkDestinations() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "Read [the guide](https://example.com/guide?q=swift#copy)."),
            "Read the guide (https://example.com/guide?q=swift#copy)."
        )
    }

    func testPlainTextAddsOneDestinationForLinkWithMultipleStyledRuns() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "[**Bold** and *italic* guide](https://example.com/guide)"),
            "Bold and italic guide (https://example.com/guide)"
        )
    }

    func testPlainTextDoesNotDuplicateDestinationAlreadyUsedAsLinkLabel() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "<https://example.com/path> and [https://example.com](https://example.com)"),
            "https://example.com/path and https://example.com"
        )
    }

    func testPlainTextPreservesCheckboxStatesAndNormalizesMarkers() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "- [ ] **Pending**\n* [x] Done\n+ [X] Also done"),
            "- [ ] Pending\n- [x] Done\n- [x] Also done"
        )
    }

    func testPlainTextPreservesListItemsAndOrderedNumbers() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "* **First**\n+ Second\n- Third\n\n3. *Three*\n10. Ten"),
            "- First\n- Second\n- Third\n\n3. Three\n10. Ten"
        )
    }

    func testPlainTextRemovesQuoteMarkersAndPreservesMultilineContent() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "> **First** line\n> second line\n\nAfter quote"),
            "First line\nsecond line\n\nAfter quote"
        )
    }

    func testPlainTextPreservesFencedCodeIndentationAndLiteralMarkdown() {
        let code = "    let text = \"**not bold**\"\n\n\t// [not a link](https://example.com)\n    return `value`  "
        for fence in ["```", "~~~"] {
            XCTAssertEqual(
                MarkdownMessageText.plainText(from: "Before\n\n\(fence)swift\n\(code)\n\(fence)\n\nAfter"),
                "Before\n\n\(code)\n\nAfter",
                "Fence: \(fence)"
            )
        }
    }

    func testPlainTextPreservesUnclosedFencedCode() {
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "```swift\n    let value = **unfinished**"),
            "    let value = **unfinished**"
        )
    }

    func testPlainTextConvertsTableToTabsAndRetainsCellLinkDestinations() {
        let markdown = """
        | **Name** | Value |
        | :--- | ---: |
        | *Alpha* | `one` |
        | [Guide](https://example.com) | two |

        After table.
        """

        XCTAssertEqual(
            MarkdownMessageText.plainText(from: markdown),
            "Name\tValue\nAlpha\tone\nGuide (https://example.com)\ttwo\n\nAfter table."
        )
    }

    func testPlainTextPreservesEscapedLiteralMarkdown() {
        let markdown = #"\*not italic\* and \_not emphasis\_ and \[not a link\] and \`not code\`."#
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: markdown),
            "*not italic* and _not emphasis_ and [not a link] and `not code`."
        )
    }

    func testPlainTextNormalizesLineSeparatorsWithoutLosingUnicode() {
        let first = "Caf\u{E9} e\u{301}"
        let second = "\u{65E5}\u{672C}\u{8A9E} \u{1F469}\u{200D}\u{1F4BB}"
        let third = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: "**\(first)**\r\n\(second)\r\(third)\u{2028}line\u{2029}paragraph"),
            "\(first)\n\(second)\n\(third)\nline\n\nparagraph"
        )
    }

    func testPlainTextParsesInlineEmphasisBeyondRenderCacheSizeLimit() {
        let content = String(repeating: "long answer ", count: 400) + "final word"
        let markdown = "**\(content)** and *ending* [guide](https://example.com)"
        XCTAssertGreaterThan(markdown.count, 4_000)
        XCTAssertEqual(
            MarkdownMessageText.plainText(from: markdown),
            content + " and ending guide (https://example.com)"
        )
    }

#if canImport(UIKit)
    func testCaptionTapIncludesWhitespaceAndParagraphGaps() {
        let view = UITextView(usingTextLayoutManager: false)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.text = "First line\n\nSecond line"
        view.layoutManager.ensureLayout(for: view.textContainer)

        XCTAssertTrue(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: 300, y: 10), in: view))
        XCTAssertTrue(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: 20, y: 25), in: view))
        XCTAssertFalse(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: -1, y: 10), in: view))
        XCTAssertFalse(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: 321, y: 10), in: view))
        view.text = ""
        XCTAssertFalse(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: 20, y: 10), in: view))
    }

    func testCaptionTapLeavesLinksToNativeInteraction() {
        let view = UITextView(usingTextLayoutManager: false)
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        let text = NSMutableAttributedString(string: "Read the guide", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        let linkRange = NSRange(location: 9, length: 5)
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: linkRange)
        view.attributedText = text
        let glyphs = view.layoutManager.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
        let rect = view.layoutManager.boundingRect(forGlyphRange: glyphs, in: view.textContainer)

        XCTAssertFalse(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: rect.midX, y: rect.midY), in: view))
        XCTAssertTrue(ResponseTextTapTarget.allowsCaption(at: CGPoint(x: 300, y: rect.midY), in: view))
    }

    func testNativeTextIsReadOnlySelectableAndNotScrollableByDefault() throws {
        let host = UIHostingController(rootView: SelectableResponseText(text: "Select this answer."))
        layout(host)
        let textView = try XCTUnwrap(textView(in: host.view))

        XCTAssertEqual(textView.text, "Select this answer.")
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isScrollEnabled)
        XCTAssertEqual(textView.textContainerInset, .zero)
        XCTAssertEqual(textView.textContainer.lineFragmentPadding, 0)
    }

    func testNativeTextPreservesSelectionWhenUnchangedTextIsUpdated() throws {
        let text = "Select this answer."
        let host = UIHostingController(rootView: SelectableResponseText(text: text))
        layout(host)
        let original = try XCTUnwrap(textView(in: host.view))
        let selection = NSRange(location: 7, length: 4)
        original.selectedRange = selection

        // Change a non-text input to prove updateUIView ran without replacing the text.
        host.rootView = SelectableResponseText(text: text, isScrollEnabled: true)
        layout(host)
        let updated = try XCTUnwrap(textView(in: host.view))

        XCTAssertTrue(updated === original)
        XCTAssertTrue(updated.isScrollEnabled)
        XCTAssertEqual(updated.selectedRange, selection)
    }

    func testNativeTextPreservesSelectionOnAppendAndClampsItOnShortening() throws {
        let host = UIHostingController(rootView: SelectableResponseText(text: "First answer"))
        layout(host)
        let original = try XCTUnwrap(textView(in: host.view))
        original.selectedRange = NSRange(location: 6, length: 6)

        host.rootView = SelectableResponseText(text: "First answer continues")
        layout(host)
        XCTAssertTrue(textView(in: host.view) === original)
        XCTAssertEqual(original.text, "First answer continues")
        XCTAssertEqual(original.selectedRange, NSRange(location: 6, length: 6))

        host.rootView = SelectableResponseText(text: "First an")
        layout(host)
        XCTAssertEqual(original.text, "First an")
        XCTAssertEqual(original.selectedRange, NSRange(location: 6, length: 2))

        host.rootView = SelectableResponseText(text: "End")
        layout(host)
        XCTAssertEqual(original.text, "End")
        XCTAssertEqual(original.selectedRange, NSRange(location: 3, length: 0))
    }

    func testNativeTextWrapsToProposedWidthWithoutInnerScrolling() throws {
        let host = UIHostingController(rootView: SelectableResponseText(
            text: String(repeating: "An answer that wraps naturally. ", count: 8)
        ).dynamicTypeSize(.large))
        let wide = layout(host, width: 360)
        let narrow = layout(host, width: 180)
        let textView = try XCTUnwrap(textView(in: host.view))

        XCTAssertGreaterThan(wide.width, 0)
        XCTAssertLessThanOrEqual(wide.width, 360)
        XCTAssertGreaterThan(narrow.width, 0)
        XCTAssertLessThanOrEqual(narrow.width, 180)
        XCTAssertGreaterThan(narrow.height, wide.height)
        XCTAssertLessThanOrEqual(textView.bounds.width, 180)
        XCTAssertFalse(textView.isScrollEnabled)
    }

    func testNativeTextScalesFontAndHeightWithDynamicType() throws {
        let text = "This answer should grow and wrap at accessibility text sizes."
        let host = UIHostingController(rootView: SelectableResponseText(text: text).dynamicTypeSize(.large))
        let standardSize = layout(host, width: 240)
        let original = try XCTUnwrap(textView(in: host.view))
        let standardFont = try XCTUnwrap(original.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)

        host.rootView = SelectableResponseText(text: text).dynamicTypeSize(.accessibility3)
        let accessibleSize = layout(host, width: 240)
        let updated = try XCTUnwrap(textView(in: host.view))
        let accessibleFont = try XCTUnwrap(updated.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let expectedFont = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraLarge)
        )

        XCTAssertTrue(updated === original)
        XCTAssertGreaterThan(accessibleFont.pointSize, standardFont.pointSize)
        XCTAssertEqual(accessibleFont.pointSize, expectedFont.pointSize, accuracy: 0.01)
        XCTAssertGreaterThan(accessibleSize.height, standardSize.height)
        XCTAssertLessThanOrEqual(accessibleSize.width, 240)
        XCTAssertFalse(updated.isScrollEnabled)
    }

    func testNativeEmptyTextRetainsParagraphLineHeight() {
        let host = UIHostingController(rootView: SelectableResponseText(text: "").dynamicTypeSize(.large))
        let size = layout(host)
        let font = UIFont.preferredFont(
            forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
        )
        XCTAssertGreaterThanOrEqual(size.height, font.lineHeight)
    }

    @discardableResult
    private func layout<Content: View>(_ host: UIHostingController<Content>, width: CGFloat = 320) -> CGSize {
        host.loadViewIfNeeded()
        let window: UIWindow
        if let existingWindow = host.view.window {
            window = existingWindow
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 800))
            host.safeAreaRegions = []
            window.rootViewController = host
            // Materialize the representable without replacing the app's root or key window.
            window.isHidden = false
            addTeardownBlock {
                await MainActor.run {
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
        }

        window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        host.view.frame = window.bounds
        window.setNeedsLayout()
        host.view.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        window.frame = CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height))
        host.view.frame = window.bounds
        window.setNeedsLayout()
        host.view.setNeedsLayout()
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()
        return size
    }

    private func textView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for subview in view.subviews {
            if let textView = textView(in: subview) { return textView }
        }
        return nil
    }
#endif

    private func message(parts: [OpenCodePart], error: OpenCodeSessionErrorPayload? = nil) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: "msg_copy", role: "assistant", sessionID: "ses_copy", time: nil,
                agent: nil, model: nil, error: error
            ),
            parts: parts
        )
    }

    private func part(
        type: String = "text",
        text: String?,
        reason: String? = nil,
        synthetic: Bool? = nil,
        state: OpenCodeToolState? = nil
    ) -> OpenCodePart {
        OpenCodePart(
            id: nil, messageID: "msg_copy", sessionID: "ses_copy", type: type,
            mime: nil, filename: nil, url: nil, reason: reason,
            tool: type == "tool" ? "read" : nil, callID: type == "tool" ? "call_copy" : nil,
            state: state, text: text, synthetic: synthetic
        )
    }
}

extension AssistantResponseCopyTests {
#if canImport(UIKit)
    func testCompletedResponseUsesOneTextViewForAllBlocksAndServerParts() throws {
        let parts = [
            "# Heading\n\nFirst paragraph.\n\n- Item\n\n> Quoted passage",
            "```swift\nlet value = 42\n```\n\n| Key | Val |\n| --- | --- |\n| Foo | Bar |\n\nLast paragraph."
        ]
        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts))
        layout(host)
        let views = allTextViews(in: host.view)
        XCTAssertEqual(views.count, 1)
        let native = try XCTUnwrap(views.first)
        let expected = "Heading\n\nFirst paragraph.\n\n\t\u{2022}\tItem\n\nQuoted passage"
            + "\u{2029}let value = 42\n\nKey   Val\nFoo   Bar\n\nLast paragraph."
        XCTAssertEqual(native.text, expected)
        XCTAssertTrue(native.isSelectable)
        XCTAssertFalse(native.isEditable)
        XCTAssertFalse(native.isScrollEnabled)

        let passage = (expected as NSString).range(of: "First paragraph.")
        let end = NSMaxRange((expected as NSString).range(of: "Last paragraph."))
        let selection = NSRange(location: passage.location, length: end - passage.location)
        native.selectedRange = selection
        XCTAssertEqual(native.selectedRange, selection)
        let selectedTextRange = try XCTUnwrap(native.selectedTextRange)
        XCTAssertEqual(native.text(in: selectedTextRange), (expected as NSString).substring(with: selection))
    }

    func testCompletedResponseSelectsVisiblePassageAcrossBlocksAndParts() throws {
        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: [
            "Excluded prefix.\n\n## Selected heading\n\n- **Selected item**",
            "> Selected quote\n\n```swift\nlet value = 42\n```\n\n| Key | Val |\n| --- | --- |\n| Foo | Bar |"
                + "\n\n`literal` and [guide](https://example.com).\n\nExcluded suffix."
        ]))
        layout(host)
        let views = allTextViews(in: host.view)
        XCTAssertEqual(views.count, 1)
        let native = try XCTUnwrap(views.first)
        let passage = "Selected heading\n\n\t\u{2022}\tSelected item"
            + "\u{2029}Selected quote\n\nlet value = 42\n\nKey   Val\nFoo   Bar\n\nliteral and guide."
        let range = try XCTUnwrap(native.text.range(of: passage))
        let selection = NSRange(range, in: native.text)
        native.selectedRange = selection

        XCTAssertEqual(native.selectedRange, selection)
        let selectedRange = try XCTUnwrap(native.selectedTextRange)
        XCTAssertEqual(native.text(in: selectedRange), passage)
    }

    func testCompletedDocumentPreservesFontsAndLinksInNativeText() throws {
        let parts = ["# Heading\n\n**Bold** and *italic* with `inline` and [guide](https://example.com)",
                     "```swift\nlet value = 42\n```"]
        let font = SelectableResponseText.preferredFont(for: .large)
        let document = MarkdownMessageText.selectableDocument(from: parts, baseFont: font, colorScheme: .light)
        func attributes(for text: String) throws -> [NSAttributedString.Key: Any] {
            let range = try XCTUnwrap(document.string.range(of: text))
            return document.attributes(at: NSRange(range, in: document.string).location, effectiveRange: nil)
        }
        for (text, trait) in [
            ("Heading", UIFontDescriptor.SymbolicTraits.traitBold),
            ("Bold", .traitBold), ("italic", .traitItalic),
            ("inline", .traitMonoSpace), ("let value", .traitMonoSpace)
        ] {
            let runAttributes = try attributes(for: text)
            let renderedFont = try XCTUnwrap(runAttributes[.font] as? UIFont)
            XCTAssertTrue(renderedFont.fontDescriptor.symbolicTraits.contains(trait), text)
        }
        let headingAttributes = try attributes(for: "Heading")
        let headingFont = try XCTUnwrap(headingAttributes[.font] as? UIFont)
        XCTAssertGreaterThan(headingFont.pointSize, font.pointSize)
        let linkAttributes = try attributes(for: "guide")
        XCTAssertEqual(linkAttributes[.link] as? URL, URL(string: "https://example.com"))
        let separator = (document.string as NSString).range(of: "\u{2029}")
        XCTAssertNotEqual(separator.location, NSNotFound)
        if separator.location != NSNotFound {
            XCTAssertNil(document.attribute(.link, at: separator.location, effectiveRange: nil))
        }

        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts)
            .dynamicTypeSize(.large).environment(\.colorScheme, .light)
            .environment(\.layoutDirection, .leftToRight))
        layout(host)
        let native = try XCTUnwrap(textView(in: host.view))
        XCTAssertTrue(native.attributedText.isEqual(to: document))
    }

    func testCompletedDocumentPreservesUnicodeAndUTF16SelectionAcrossParts() throws {
        let first = "Caf\u{E9} e\u{301} \u{1F469}\u{200D}\u{1F4BB}"
        let second = "\u{65E5}\u{672C}\u{8A9E} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
        let parts = ["**\(first)**", second]
        let document = MarkdownMessageText.selectableDocument(
            from: parts, baseFont: .systemFont(ofSize: 17), colorScheme: .dark, layoutDirection: .rightToLeft
        )
        let expected = first + "\u{2029}" + second
        XCTAssertEqual(document.string, expected)
        XCTAssertEqual(document.length, expected.utf16.count)
        let paragraph = try XCTUnwrap(document.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.baseWritingDirection, .rightToLeft)

        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts))
        layout(host)
        let native = try XCTUnwrap(textView(in: host.view))
        let passage = "\u{1F469}\u{200D}\u{1F4BB}\u{2029}" + second
        let range = try XCTUnwrap(expected.range(of: passage))
        native.selectedRange = NSRange(range, in: expected)
        let selection = try XCTUnwrap(native.selectedTextRange)
        XCTAssertEqual(native.text(in: selection), passage)
    }

    func testCompletedEmptyDocumentHasOneEmptySelectableTextView() throws {
        let inputs: [[String]] = [[], [""]]
        for parts in inputs {
            let document = MarkdownMessageText.selectableDocument(
                from: parts, baseFont: .systemFont(ofSize: 17), colorScheme: .light
            )
            XCTAssertEqual(document.string, "")
            XCTAssertEqual(document.length, 0)
            let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts))
            let size = layout(host)
            let views = allTextViews(in: host.view)
            XCTAssertEqual(views.count, 1)
            let native = try XCTUnwrap(views.first)
            XCTAssertEqual(native.text, "")
            XCTAssertTrue(native.isSelectable)
            XCTAssertGreaterThan(size.height, 0)
        }
    }

    func testCompletedDocumentParsesEachPartIndependentlyAfterUnclosedFence() throws {
        let document = MarkdownMessageText.selectableDocument(
            from: ["```swift\nlet value = **literal**", "# Real heading\n\n**Real emphasis**"],
            baseFont: .systemFont(ofSize: 17), colorScheme: .light
        )
        XCTAssertEqual(document.string, "let value = **literal**\u{2029}Real heading\n\nReal emphasis")
        let codeFont = try XCTUnwrap(document.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
        let headingRange = try XCTUnwrap(document.string.range(of: "Real heading"))
        let headingFont = try XCTUnwrap(document.attribute(
            .font, at: NSRange(headingRange, in: document.string).location, effectiveRange: nil
        ) as? UIFont)
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(headingFont.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testCompletedLongResponseRemainsOneUntruncatedTextView() throws {
        let paragraph = String(repeating: "A long selectable answer. ", count: 40)
        let parts = ["# Long answer\n\n" + paragraph, "Final **paragraph**."]
        XCTAssertGreaterThan(parts[0].count, 600)
        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts))
        layout(host, width: 240)
        let views = allTextViews(in: host.view)
        XCTAssertEqual(views.count, 1)
        let native = try XCTUnwrap(views.first)
        let expected = "Long answer\n\n" + paragraph + "\u{2029}Final paragraph."
        XCTAssertEqual(native.text, expected)
        XCTAssertFalse(native.isScrollEnabled)
        native.selectedRange = NSRange(location: 0, length: expected.utf16.count)
        let selection = try XCTUnwrap(native.selectedTextRange)
        XCTAssertEqual(native.text(in: selection), expected)
    }

    func testCompletedResponsePreservesSelectionWhenOnlyTapCallbackChanges() throws {
        let parts = ["First **paragraph**.", "Second paragraph."]
        let host = UIHostingController(rootView: CompletedResponseText(markdownParts: parts))
        layout(host)
        let original = try XCTUnwrap(textView(in: host.view))
        let originalDocument = NSAttributedString(attributedString: original.attributedText)
        let passage = "paragraph.\u{2029}Second"
        let range = try XCTUnwrap(original.text.range(of: passage))
        let selection = NSRange(range, in: original.text)
        original.selectedRange = selection
        var callbackCount = 0

        for hasCallback in [true, false, true] {
            let callback: (() -> Void)? = hasCallback ? { callbackCount += 1 } : nil
            host.rootView = CompletedResponseText(markdownParts: parts, onTextTap: callback)
            layout(host)
            let views = allTextViews(in: host.view)
            XCTAssertEqual(views.count, 1)
            let updated = try XCTUnwrap(views.first)
            XCTAssertTrue(updated === original)
            XCTAssertEqual(updated.selectedRange, selection)
            XCTAssertTrue(updated.attributedText.isEqual(to: originalDocument))
        }
        XCTAssertEqual(callbackCount, 0)
    }

    private func allTextViews(in view: UIView) -> [UITextView] {
        let current = (view as? UITextView).map { [$0] } ?? []
        return current + view.subviews.flatMap { allTextViews(in: $0) }
    }
#endif

    func testCompletionTimeConvertsMillisecondsAndLegacySecondsAtStrictThreshold() throws {
        for (timestamp, seconds) in [
            (1_750_000_000_250.0, 1_750_000_000.25),
            (1_750_000_000.25, 1_750_000_000.25),
            (100_000_000_000.0, 100_000_000_000.0),
            (100_000_000_001.0, 100_000_000.001)
        ] {
            for usesPartEnd in [true, false] {
                let message = timedMessage(completed: usesPartEnd ? nil : timestamp, ends: usesPartEnd ? [timestamp] : [])
                let date = try XCTUnwrap(ResponseCompletionTime.date(message: message, parts: message.parts))
                XCTAssertEqual(date.timeIntervalSince1970, seconds, accuracy: 0.000_001)
            }
        }
    }

    func testCompletionTimePrefersLatestValidSuppliedPartEndOverMessageCompletion() throws {
        let latest = 1_750_000_003_000.0
        let message = timedMessage(completed: latest + 20_000, ends: [latest + 10_000])
        let parts = timedMessage(completed: nil, ends: [
            nil, 0, -1, .nan, .infinity, -.infinity, latest - 2_000, latest, latest - 1_000
        ]).parts
        for orderedParts in [parts, Array(parts.reversed())] {
            let date = try XCTUnwrap(ResponseCompletionTime.date(message: message, parts: orderedParts))
            XCTAssertEqual(date.timeIntervalSince1970, latest / 1_000, accuracy: 0.000_001)
        }
    }

    func testCompletionTimeFallsBackToMessageWhenAllPartEndsAreUnavailableOrInvalid() throws {
        let inputs: [[Double?]] = [[], [nil], [0, -1, .nan, .infinity, -.infinity]]
        for ends in inputs {
            let message = timedMessage(completed: 1_750_000_000_500, ends: ends)
            let date = try XCTUnwrap(ResponseCompletionTime.date(message: message, parts: message.parts))
            XCTAssertEqual(date.timeIntervalSince1970, 1_750_000_000.5, accuracy: 0.000_001)
        }
    }

    func testCompletionTimeNeverSubstitutesCreationStartOrNowForMissingCompletion() {
        let missingTime = message(parts: [part(text: "No timestamps")])
        XCTAssertNil(ResponseCompletionTime.date(message: missingTime, parts: missingTime.parts))
        let invalid: [Double?] = [nil, 0, -1, .nan, .infinity, -.infinity]
        for completed in invalid {
            let message = timedMessage(completed: completed, created: 1_750_000_000_000, ends: invalid)
            XCTAssertNil(ResponseCompletionTime.date(message: message, parts: message.parts))
        }
    }

    private func timedMessage(completed: Double?, created: Double? = nil, ends: [Double?]) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: "msg_completion", role: "assistant", sessionID: "ses_copy",
                time: OpenCodeMessageTime(created: created, completed: completed), agent: nil, model: nil
            ),
            parts: ends.enumerated().map { index, end in
                OpenCodePart(
                    id: "part_\(index)", messageID: "msg_completion", sessionID: "ses_copy", type: "text",
                    mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil,
                    text: "Answer", time: OpenCodePartTime(start: 1_750_000_000_000, end: end)
                )
            }
        )
    }
}
