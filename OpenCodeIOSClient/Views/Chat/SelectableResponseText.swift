#if canImport(UIKit)
import SwiftUI
import UIKit

struct SelectableResponseText: View {
    struct Styling {
        var textStyle: UIFont.TextStyle = .body
        var weight: UIFont.Weight? = nil
        var foregroundColor: UIColor = .label
        var lineSpacing: CGFloat = 3
    }

    var text: String = ""
    var isScrollEnabled = false
    var inlineMarkdown: AttributedString? = nil
    var styling = Styling()
    var attributedText: NSAttributedString? = nil
    var onTextTap: (() -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let font = Self.preferredFont(for: dynamicTypeSize, styling: styling)
        NativeSelectableResponseText(
            text: text,
            isScrollEnabled: isScrollEnabled,
            inlineMarkdown: inlineMarkdown,
            styling: styling,
            font: font,
            attributedText: attributedText,
            onTextTap: onTextTap
        )
        // Representables otherwise use their bottom edge as a SwiftUI text baseline.
        .alignmentGuide(.firstTextBaseline) { _ in font.ascender }
        .alignmentGuide(.lastTextBaseline) { dimensions in dimensions.height + font.descender }
    }

    static func preferredFont(for dynamicTypeSize: DynamicTypeSize, styling: Styling = Styling()) -> UIFont {
        let category: UIContentSizeCategory
        switch dynamicTypeSize {
        case .xSmall: category = .extraSmall
        case .small: category = .small
        case .medium: category = .medium
        case .large: category = .large
        case .xLarge: category = .extraLarge
        case .xxLarge: category = .extraExtraLarge
        case .xxxLarge: category = .extraExtraExtraLarge
        case .accessibility1: category = .accessibilityMedium
        case .accessibility2: category = .accessibilityLarge
        case .accessibility3: category = .accessibilityExtraLarge
        case .accessibility4: category = .accessibilityExtraExtraLarge
        case .accessibility5: category = .accessibilityExtraExtraExtraLarge
        @unknown default: category = .large
        }
        let font = UIFont.preferredFont(
            forTextStyle: styling.textStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
        )
        guard let weight = styling.weight else { return font }
        return .systemFont(ofSize: font.pointSize, weight: weight)
    }

    @MainActor
    static func attributedString(
        from source: AttributedString,
        font: UIFont,
        color: UIColor,
        paragraph: NSParagraphStyle,
        monospacedWeight: UIFont.Weight = .regular
    ) -> NSMutableAttributedString {
        let attributed = NSMutableAttributedString(
            string: String(source.characters),
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
        var offset = 0
        for run in source.runs {
            let length = String(source[run.range].characters).utf16.count
            let range = NSRange(location: offset, length: length)
            offset += length
            let intent = run.inlinePresentationIntent ?? []
            var runFont = intent.contains(.code)
                ? UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: monospacedWeight)
                : font
            var traits = runFont.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
            }
            attributed.addAttribute(.font, value: runFont, range: range)
            if intent.contains(.strikethrough) {
                attributed.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let link = run.link {
                attributed.addAttribute(.link, value: link, range: range)
            }
        }
        return attributed
    }
}

private struct NativeSelectableResponseText: UIViewRepresentable {
    let text: String
    let isScrollEnabled: Bool
    let inlineMarkdown: AttributedString?
    let styling: SelectableResponseText.Styling
    let font: UIFont
    let attributedText: NSAttributedString?
    let onTextTap: (() -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.isOpaque = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.contentInsetAdjustmentBehavior = .never
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let singleTap = ResponseTextTapRecognizer(target: context.coordinator, action: #selector(Coordinator.textTapped(_:)))
        let doubleTap = ResponseTextTapRecognizer(target: nil, action: nil)
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [singleTap, doubleTap] {
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        singleTap.require(toFail: doubleTap)
        context.coordinator.singleTap = singleTap
        context.coordinator.doubleTap = doubleTap
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.openURL = context.environment.openURL
        context.coordinator.onTextTap = onTextTap
        if view.isScrollEnabled != isScrollEnabled { view.isScrollEnabled = isScrollEnabled }
        let detectors: UIDataDetectorTypes = attributedText == nil && inlineMarkdown == nil ? .link : []
        if view.dataDetectorTypes != detectors { view.dataDetectorTypes = detectors }

        let attributed: NSAttributedString
        if let attributedText {
            // The immutable completed document retains its UIKit fonts, tabs and colors.
            if context.coordinator.document === attributedText { return }
            attributed = attributedText
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = styling.lineSpacing
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.alignment = context.environment.layoutDirection == .rightToLeft ? .right : .left
            attributed = SelectableResponseText.attributedString(
                from: inlineMarkdown ?? AttributedString(text),
                font: font,
                color: styling.foregroundColor,
                paragraph: paragraph,
                monospacedWeight: styling.weight ?? .regular
            )
        }
        context.coordinator.document = attributedText

        // Reassigning attributedText resets native selection, even for identical content.
        guard !view.attributedText.isEqual(to: attributed) else { return }
        context.coordinator.interactionRevision &+= 1
        let selection = view.selectedRange
        let contentOffset = view.contentOffset
        view.attributedText = attributed
        if selection.location != NSNotFound {
            let location = min(selection.location, attributed.length)
            view.selectedRange = NSRange(
                location: location,
                length: min(selection.length, attributed.length - location)
            )
        }
        if isScrollEnabled { view.setContentOffset(contentOffset, animated: false) }
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let width: CGFloat
        if attributedText != nil, let proposedWidth {
            width = proposedWidth
        } else {
            let naturalWidth = ceil(uiView.attributedText.size().width)
            width = isScrollEnabled
                ? (proposedWidth ?? naturalWidth)
                : min(proposedWidth ?? naturalWidth, naturalWidth)
        }
        if isScrollEnabled, let height = proposal.height, height.isFinite {
            return CGSize(width: width, height: max(0, height))
        }
        guard uiView.attributedText.length > 0 else {
            return CGSize(width: width, height: ceil(font.lineHeight))
        }
        let size = uiView.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(size.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) {
        coordinator.interactionRevision &+= 1
        coordinator.onTextTap = nil
        uiView.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var openURL: OpenURLAction?
        var onTextTap: (() -> Void)?
        var document: NSAttributedString?
        weak var singleTap: UITapGestureRecognizer?
        weak var doubleTap: UITapGestureRecognizer?
        var interactionRevision: UInt = 0
        private var touchRevision: UInt = 0

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if touch.tapCount > 1 {
                interactionRevision &+= 1
                return gestureRecognizer === doubleTap && onTextTap != nil
            }
            guard gestureRecognizer === singleTap else { return onTextTap != nil }
            interactionRevision &+= 1
            touchRevision = interactionRevision
            guard onTextTap != nil, let view = gestureRecognizer.view as? UITextView,
                   touch.view?.isDescendant(of: view) == true,
                   !isScrolling(view), ResponseTextTapTarget.allowsCaption(at: touch.location(in: view), in: view) else { return false }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Only our single/double pair has a failure relationship. UIKit keeps all
            // of its scrolling, link and text-selection recognizers unimpeded.
            return !((gestureRecognizer === singleTap && otherGestureRecognizer === doubleTap)
                || (gestureRecognizer === doubleTap && otherGestureRecognizer === singleTap))
        }

        @objc func textTapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view as? UITextView else { return }
            let revision = touchRevision
            let point = recognizer.location(in: view)
            // Let native selection settle before reporting an action to SwiftUI.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, view.window != nil,
                      self.interactionRevision == revision, view.selectedRange.length == 0,
                       !self.isScrolling(view), ResponseTextTapTarget.allowsCaption(at: point, in: view) else { return }
                self.onTextTap?()
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.selectedRange.length > 0 { interactionRevision &+= 1 }
        }

        private func isScrolling(_ view: UIView) -> Bool {
            var ancestor: UIView? = view
            while let current = ancestor {
                if let scroll = current as? UIScrollView,
                   scroll.isDragging || scroll.isDecelerating { return true }
                ancestor = current.superview
            }
            return false
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            interactionRevision &+= 1
            guard case let .link(url) = textItem.content, let openURL else { return defaultAction }
            return UIAction { _ in openURL(url) }
        }
    }
}

@MainActor
enum ResponseTextTapTarget {
    static func allowsCaption(at point: CGPoint, in view: UITextView) -> Bool {
        guard view.bounds.contains(point), view.textStorage.length > 0 else { return false }
        let point = CGPoint(x: point.x - view.textContainerInset.left, y: point.y - view.textContainerInset.top)
        let manager = view.layoutManager
        let glyph = manager.glyphIndex(for: point, in: view.textContainer)
        guard glyph < manager.numberOfGlyphs else { return true }
        let glyphBounds = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer)
        // Include whitespace and paragraph gaps, but leave link taps to UIKit.
        guard glyphBounds.insetBy(dx: -4, dy: -4).contains(point) else { return true }
        let character = manager.characterIndexForGlyph(at: glyph)
        return character >= view.textStorage.length
            || view.textStorage.attribute(.link, at: character, effectiveRange: nil) == nil
    }
}

// Observes quick taps without winning against any native text or scroll interaction.
private final class ResponseTextTapRecognizer: UITapGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif
