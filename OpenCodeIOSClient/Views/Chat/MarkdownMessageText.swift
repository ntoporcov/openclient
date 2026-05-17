import SwiftUI

struct MarkdownMessageText: View {
    enum Style {
        case standard
        case reasoning
    }

    fileprivate enum MarkdownBlock: Identifiable {
        case text(id: Int, value: String)
        case heading(id: Int, level: Int, value: String)
        case blockQuote(id: Int, value: String)
        case listItem(id: Int, marker: ListMarker, value: String)
        case table(id: Int, headers: [String], rows: [[String]])
        case codeBlock(id: Int, language: String?, value: String)

        var id: Int {
            switch self {
            case let .text(id, _), let .heading(id, _, _), let .blockQuote(id, _), let .listItem(id, _, _), let .table(id, _, _), let .codeBlock(id, _, _):
                return id
            }
        }
    }

    fileprivate enum ListMarker {
        case unordered
        case ordered(String)
        case checkbox(isChecked: Bool)
    }

    let text: String
    let isUser: Bool
    let style: Style
    var isStreaming = false
    var animatesStreamingText = true

    @State private var hasRenderedStreaming = false
    @State private var richContentOpacity = 1.0

    var body: some View {
        switch style {
        case .standard:
            content
                .padding(.vertical, isUser ? 0 : 10)
        case .reasoning:
            content
        }
    }

    private var content: some View {
        Group {
            if isStreaming {
                streamingTextView
            } else {
                richMarkdownContent
                    .opacity(richContentOpacity)
            }
        }
        .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
        .modifier(ConditionalTextSelectionModifier(isEnabled: !isStreaming))
        .onAppear {
            hasRenderedStreaming = isStreaming
        }
        .onChange(of: isStreaming) { oldValue, newValue in
            if newValue {
                hasRenderedStreaming = true
                richContentOpacity = 1
            } else if oldValue || hasRenderedStreaming {
                richContentOpacity = 0
                withAnimation(.easeOut(duration: 0.22)) {
                    richContentOpacity = 1
                }
                hasRenderedStreaming = false
            }
        }
    }

    private var richMarkdownContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                switch block {
                case let .text(_, value):
                    styledText(markdownText(value))
                        .padding(.bottom, textBlockBottomPadding(for: value))
                case let .heading(_, level, value):
                    styledHeading(markdownText(value), level: level)
                case let .blockQuote(_, value):
                    styledBlockQuote(markdownText(value))
                case let .listItem(_, marker, value):
                    styledListItem(markdownText(value), marker: marker)
                case let .table(_, headers, rows):
                    styledTable(headers: headers, rows: rows)
                case let .codeBlock(_, language, value):
                    HighlightedCodeBlock(code: value, language: language)
                        .padding(.vertical, codeBlockOuterPadding)
                }
            }
        }
    }

    @ViewBuilder
    private var streamingTextView: some View {
#if canImport(UIKit)
        NativeStreamingTextLabel(
            text: text,
            isUser: isUser,
            style: style,
            lineSpacing: textLineSpacing,
            animatesTextReveal: shouldUseNativeStreamingTextReveal
        )
#else
        if shouldUseStreamingTextFade {
            StreamingTextFade(
                text: text,
                font: textFont,
                foregroundColor: textForegroundStyle,
                lineSpacing: textLineSpacing
            )
        } else {
            StreamingPlainText(
                text: text,
                font: textFont,
                foregroundColor: textForegroundStyle,
                lineSpacing: textLineSpacing
            )
        }
#endif
    }

    private var shouldUseStreamingTextFade: Bool {
        animatesStreamingText && !isUser
    }

    private var shouldUseNativeStreamingTextReveal: Bool {
        animatesStreamingText && !isUser && text.utf16.count <= 1_200
    }

    private func styledText(_ text: Text) -> some View {
        text
            .font(textFont)
            .foregroundStyle(textForegroundStyle)
            .lineSpacing(textLineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func styledHeading(_ text: Text, level: Int) -> some View {
        text
            .font(headingFont(level: level))
            .foregroundStyle(textForegroundStyle)
            .lineSpacing(textLineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, headingTopPadding(level: level))
            .padding(.bottom, headingBottomPadding(level: level))
    }

    private func styledBlockQuote(_ text: Text) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(blockQuoteAccentStyle)
                .frame(width: 3)

            styledText(text)
                .foregroundStyle(blockQuoteForegroundStyle)
        }
        .padding(.vertical, blockQuoteVerticalPadding)
        .padding(.horizontal, 10)
        .background(blockQuoteBackgroundStyle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, blockQuoteOuterPadding)
    }

    private func styledListItem(_ text: Text, marker: ListMarker) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            listMarkerView(marker)
                .frame(width: listMarkerWidth(for: marker), alignment: .trailing)

            styledText(text)
        }
        .padding(.vertical, listItemVerticalPadding)
    }

    private func styledTable(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(headers, isHeader: true)

                ForEach(rows.indices, id: \.self) { rowIndex in
                    Divider()
                        .overlay(tableDividerStyle)

                    tableRow(rows[rowIndex], isHeader: false)
                }
            }
            .background(tableBackgroundStyle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tableBorderStyle, lineWidth: 1)
            }
        }
        .padding(.vertical, tableOuterPadding)
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { columnIndex in
                tableCell(cells[columnIndex], isHeader: isHeader)

                if columnIndex < cells.count - 1 {
                    Rectangle()
                        .fill(tableDividerStyle)
                        .frame(width: 1)
                }
            }
        }
        .background(isHeader ? tableHeaderBackgroundStyle : .clear)
    }

    private func tableCell(_ value: String, isHeader: Bool) -> some View {
        markdownText(value)
            .font(isHeader ? tableHeaderFont : textFont)
            .foregroundStyle(isHeader ? tableHeaderForegroundStyle : textForegroundStyle)
            .lineSpacing(textLineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: tableCellMinWidth, maxWidth: tableCellMaxWidth, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, isHeader ? 8 : 7)
    }

    @ViewBuilder
    private func listMarkerView(_ marker: ListMarker) -> some View {
        switch marker {
        case .unordered:
            Text("•")
                .font(listMarkerFont)
                .foregroundStyle(listMarkerForegroundStyle)
        case let .ordered(value):
            Text(value)
                .font(listMarkerFont)
                .foregroundStyle(listMarkerForegroundStyle)
        case let .checkbox(isChecked):
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(checkboxMarkerFont)
                .foregroundStyle(isChecked ? checkboxCheckedForegroundStyle : listMarkerForegroundStyle)
        }
    }

    private func markdownText(_ value: String) -> Text {
        if let attributed = OpenCodeMarkdownRenderCache.shared.inlineMarkdown(for: value) {
            return Text(attributed)
        }

        return Text(value)
    }

    private var blocks: [MarkdownBlock] {
        OpenCodeMarkdownRenderCache.shared.blocks(for: text) {
            let lines = text.components(separatedBy: .newlines)
            var result: [MarkdownBlock] = []
            var index = 0
            var id = 0

            while index < lines.count {
                let line = lines[index]

                if let codeBlock = fencedCodeBlock(in: lines, startingAt: index) {
                    result.append(.codeBlock(id: id, language: codeBlock.language, value: codeBlock.value))
                    id += 1
                    index = codeBlock.nextIndex
                    continue
                }

                if let table = markdownTable(in: lines, startingAt: index) {
                    result.append(.table(id: id, headers: table.headers, rows: table.rows))
                    id += 1
                    index = table.nextIndex
                    continue
                }

                if let quote = blockQuoteLine(from: line) {
                    var values = [quote]
                    index += 1

                    while index < lines.count, let nextQuote = blockQuoteLine(from: lines[index]) {
                        values.append(nextQuote)
                        index += 1
                    }

                    result.append(.blockQuote(id: id, value: values.joined(separator: "\n")))
                    id += 1
                    continue
                }

                if let heading = heading(from: line) {
                    result.append(.heading(id: id, level: heading.level, value: heading.value))
                } else if let item = listItem(from: line) {
                    result.append(.listItem(id: id, marker: item.marker, value: item.value))
                } else {
                    result.append(.text(id: id, value: line))
                }

                id += 1
                index += 1
            }

            return result
        }
    }

    private func heading(from line: String) -> (level: Int, value: String)? {
        for level in 1...3 {
            let marker = String(repeating: "#", count: level) + " "
            guard line.hasPrefix(marker) else { continue }

            let value = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }

            return (level, value)
        }

        return nil
    }

    private func fencedCodeBlock(in lines: [String], startingAt startIndex: Int) -> (language: String?, value: String, nextIndex: Int)? {
        guard let fence = codeFence(from: lines[startIndex]) else { return nil }

        var values: [String] = []
        var index = startIndex + 1

        while index < lines.count {
            if isClosingCodeFence(lines[index], fence: fence.marker) {
                return (fence.language, values.joined(separator: "\n"), index + 1)
            }

            values.append(lines[index])
            index += 1
        }

        return (fence.language, values.joined(separator: "\n"), index)
    }

    private func codeFence(from line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let marker: String

        if trimmed.hasPrefix("```") {
            marker = "```"
        } else if trimmed.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }

        let language = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first

        return (marker, language?.isEmpty == false ? language : nil)
    }

    private func isClosingCodeFence(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(fence)
    }

    private func listItem(from line: String) -> (marker: ListMarker, value: String)? {
        if let checkbox = checkboxListItem(from: line) {
            return checkbox
        }

        if let unordered = unorderedListItem(from: line) {
            return unordered
        }

        return orderedListItem(from: line)
    }

    private func checkboxListItem(from line: String) -> (marker: ListMarker, value: String)? {
        let prefixes: [(prefix: String, isChecked: Bool)] = [
            ("- [ ] ", false),
            ("- [x] ", true),
            ("- [X] ", true),
            ("* [ ] ", false),
            ("* [x] ", true),
            ("* [X] ", true),
            ("+ [ ] ", false),
            ("+ [x] ", true),
            ("+ [X] ", true)
        ]

        for prefix in prefixes where line.hasPrefix(prefix.prefix) {
            let value = String(line.dropFirst(prefix.prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return (.checkbox(isChecked: prefix.isChecked), value)
        }

        return nil
    }

    private func unorderedListItem(from line: String) -> (marker: ListMarker, value: String)? {
        for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
            let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            return (.unordered, value)
        }

        return nil
    }

    private func orderedListItem(from line: String) -> (marker: ListMarker, value: String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }

        let number = String(line[..<dotIndex])
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }

        let valueStart = line.index(after: dotIndex)
        guard valueStart < line.endIndex, line[valueStart] == " " else { return nil }

        let value = String(line[line.index(after: valueStart)...]).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        return (.ordered("\(number)."), value)
    }

    private func markdownTable(in lines: [String], startingAt startIndex: Int) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard startIndex + 1 < lines.count,
              let headers = tableCells(from: lines[startIndex]),
              isTableSeparator(lines[startIndex + 1]) else {
            return nil
        }

        var rows: [[String]] = []
        var index = startIndex + 2

        while index < lines.count, let cells = tableCells(from: lines[index]), !isTableSeparator(lines[index]) {
            rows.append(normalizedTableRow(cells, count: headers.count))
            index += 1
        }

        guard !rows.isEmpty else { return nil }
        return (headers, rows, index)
    }

    private func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }

        var value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("|") {
            value.removeFirst()
        }
        if value.hasSuffix("|") {
            value.removeLast()
        }

        let cells = value
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }

        guard cells.count >= 2, cells.contains(where: { !$0.isEmpty }) else { return nil }
        return cells
    }

    private func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(from: line) else { return false }

        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-"), trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { character in
                character == "-" || character == ":"
            }
        }
    }

    private func normalizedTableRow(_ cells: [String], count: Int) -> [String] {
        if cells.count == count {
            return cells
        }

        if cells.count > count {
            return Array(cells.prefix(count))
        }

        return cells + Array(repeating: "", count: count - cells.count)
    }

    private func blockQuoteLine(from line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }

        let value = String(line.dropFirst())
        if value.hasPrefix(" ") {
            return String(value.dropFirst())
        }

        return value
    }

    private var textFont: Font {
        switch style {
        case .standard:
            return .body
        case .reasoning:
            return .caption
        }
    }

    private func headingFont(level: Int) -> Font {
        switch style {
        case .standard:
            switch level {
            case 1:
                return .title3.weight(.bold)
            case 2:
                return .headline.weight(.bold)
            default:
                return .subheadline.weight(.semibold)
            }
        case .reasoning:
            switch level {
            case 1:
                return .subheadline.weight(.bold)
            case 2:
                return .caption.weight(.bold)
            default:
                return .caption.weight(.semibold)
            }
        }
    }

    private var textForegroundStyle: Color {
        if isUser {
            return .white
        }

        switch style {
        case .standard:
            return .primary
        case .reasoning:
            return .secondary
        }
    }

    private var blockQuoteForegroundStyle: Color {
        isUser ? .white.opacity(0.86) : .secondary
    }

    private var blockQuoteAccentStyle: Color {
        isUser ? .white.opacity(0.55) : .secondary.opacity(0.45)
    }

    private var blockQuoteBackgroundStyle: Color {
        isUser ? .white.opacity(0.12) : .secondary.opacity(0.09)
    }

    private var listMarkerForegroundStyle: Color {
        isUser ? .white.opacity(0.78) : .secondary
    }

    private var checkboxCheckedForegroundStyle: Color {
        isUser ? .white : .accentColor
    }

    private var tableHeaderForegroundStyle: Color {
        isUser ? .white : .primary
    }

    private var tableBackgroundStyle: Color {
        isUser ? .white.opacity(0.08) : .secondary.opacity(0.06)
    }

    private var tableHeaderBackgroundStyle: Color {
        isUser ? .white.opacity(0.12) : .secondary.opacity(0.11)
    }

    private var tableBorderStyle: Color {
        isUser ? .white.opacity(0.18) : .secondary.opacity(0.2)
    }

    private var tableDividerStyle: Color {
        isUser ? .white.opacity(0.16) : .secondary.opacity(0.18)
    }

    private var textLineSpacing: CGFloat {
        switch style {
        case .standard:
            return isUser ? 1 : 3
        case .reasoning:
            return 2
        }
    }

    private func headingTopPadding(level: Int) -> CGFloat {
        switch style {
        case .standard:
            return level == 1 ? 8 : 6
        case .reasoning:
            return 4
        }
    }

    private func headingBottomPadding(level: Int) -> CGFloat {
        switch style {
        case .standard:
            return level == 1 ? 6 : 4
        case .reasoning:
            return 3
        }
    }

    private func textBlockBottomPadding(for value: String) -> CGFloat {
        value.isEmpty ? textFontLinePadding : 0
    }

    private var textFontLinePadding: CGFloat {
        switch style {
        case .standard:
            return 7
        case .reasoning:
            return 5
        }
    }

    private var blockQuoteVerticalPadding: CGFloat {
        switch style {
        case .standard:
            return 8
        case .reasoning:
            return 6
        }
    }

    private var blockQuoteOuterPadding: CGFloat {
        switch style {
        case .standard:
            return 4
        case .reasoning:
            return 3
        }
    }

    private var listMarkerFont: Font {
        switch style {
        case .standard:
            return .body.weight(.semibold)
        case .reasoning:
            return .caption.weight(.semibold)
        }
    }

    private var checkboxMarkerFont: Font {
        switch style {
        case .standard:
            return .body
        case .reasoning:
            return .caption
        }
    }

    private func listMarkerWidth(for marker: ListMarker) -> CGFloat {
        switch marker {
        case .unordered, .checkbox:
            return 18
        case let .ordered(value):
            return max(22, CGFloat(value.count) * 8)
        }
    }

    private var listItemVerticalPadding: CGFloat {
        switch style {
        case .standard:
            return 2
        case .reasoning:
            return 1
        }
    }

    private var tableHeaderFont: Font {
        switch style {
        case .standard:
            return .body.weight(.semibold)
        case .reasoning:
            return .caption.weight(.semibold)
        }
    }

    private var tableCellMinWidth: CGFloat {
        switch style {
        case .standard:
            return 96
        case .reasoning:
            return 82
        }
    }

    private var tableCellMaxWidth: CGFloat {
        switch style {
        case .standard:
            return 180
        case .reasoning:
            return 150
        }
    }

    private var tableOuterPadding: CGFloat {
        switch style {
        case .standard:
            return 5
        case .reasoning:
            return 4
        }
    }

    private var codeBlockOuterPadding: CGFloat {
        switch style {
        case .standard:
            return 5
        case .reasoning:
            return 4
        }
    }
}

@MainActor
fileprivate final class OpenCodeMarkdownRenderCache {
    static let shared = OpenCodeMarkdownRenderCache()

    private var blocksByText: [String: [MarkdownMessageText.MarkdownBlock]] = [:]
    private var inlineMarkdownByText: [String: AttributedString] = [:]

    func blocks(for text: String, build: () -> [MarkdownMessageText.MarkdownBlock]) -> [MarkdownMessageText.MarkdownBlock] {
        if let cached = blocksByText[text] {
            return cached
        }

        let blocks = build()
        if text.count <= 24_000 {
            trimIfNeeded(&blocksByText, limit: 220)
            blocksByText[text] = blocks
        }
        return blocks
    }

    func inlineMarkdown(for text: String) -> AttributedString? {
        if let cached = inlineMarkdownByText[text] {
            return cached
        }

        guard text.count <= 4_000,
              let attributed = try? AttributedString(
                  markdown: text,
                  options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
              ) else {
            return nil
        }

        trimIfNeeded(&inlineMarkdownByText, limit: 600)
        inlineMarkdownByText[text] = attributed
        return attributed
    }

    private func trimIfNeeded<Value>(_ cache: inout [String: Value], limit: Int) {
        if cache.count >= limit {
            cache.removeAll(keepingCapacity: true)
        }
    }
}

private struct ConditionalTextSelectionModifier: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}

#if canImport(UIKit)
private struct NativeStreamingTextLabel: UIViewRepresentable {
    let text: String
    let isUser: Bool
    let style: MarkdownMessageText.Style
    let lineSpacing: CGFloat
    let animatesTextReveal: Bool

    func makeUIView(context: Context) -> StreamingTextUILabel {
        let label = StreamingTextUILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.backgroundColor = .clear
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateUIView(_ label: StreamingTextUILabel, context: Context) {
        label.configure(
            text: text,
            font: uiFont,
            textColor: uiTextColor,
            lineSpacing: lineSpacing,
            animatesTextReveal: animatesTextReveal
        )
    }

    static func dismantleUIView(_ label: StreamingTextUILabel, coordinator: ()) {
        label.stopStreaming()
    }

    private var uiFont: UIFont {
        switch style {
        case .standard:
            return UIFont.preferredFont(forTextStyle: .body)
        case .reasoning:
            return UIFont.preferredFont(forTextStyle: .caption1)
        }
    }

    private var uiTextColor: UIColor {
        if isUser {
            return .white
        }

        switch style {
        case .standard:
            return .label
        case .reasoning:
            return .secondaryLabel
        }
    }
}

private final class StreamingTextUILabel: UILabel {
    private var configuredText = ""
    private var configuredFont: UIFont?
    private var configuredTextColor: UIColor?
    private var configuredLineSpacing: CGFloat = 0
    private var configuredAnimatesTextReveal = false
    private var displayLink: CADisplayLink?
    private var displayedCharacterCount: Double = 0
    private var lastFrameTime = Date.timeIntervalSinceReferenceDate

    private let revealCharactersPerSecond: Double = 96
    private let fadeWindowCharacterCount = 18

    func configure(text: String, font: UIFont, textColor: UIColor, lineSpacing: CGFloat, animatesTextReveal: Bool) {
        guard configuredText != text || configuredFont != font || configuredTextColor != textColor || configuredLineSpacing != lineSpacing || configuredAnimatesTextReveal != animatesTextReveal else {
            return
        }

        let previousCharacterCount: Int
        let newCharacterCount: Int
        let shouldReveal: Bool
        if animatesTextReveal {
            previousCharacterCount = configuredText.count
            newCharacterCount = text.count
            shouldReveal = text.hasPrefix(configuredText) && newCharacterCount > previousCharacterCount
        } else {
            previousCharacterCount = 0
            newCharacterCount = 0
            shouldReveal = false
        }
        configuredText = text
        configuredFont = font
        configuredTextColor = textColor
        configuredLineSpacing = lineSpacing
        configuredAnimatesTextReveal = animatesTextReveal

        if shouldReveal {
            displayedCharacterCount = min(displayedCharacterCount, Double(newCharacterCount))
            renderDisplayedText()
            startDisplayLink()
        } else {
            displayedCharacterCount = animatesTextReveal ? Double(newCharacterCount) : .greatestFiniteMagnitude
            renderDisplayedText()
            stopDisplayLink()
        }
    }

    func stopStreaming() {
        stopDisplayLink()
    }

    private func renderDisplayedText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = configuredLineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: configuredFont ?? UIFont.preferredFont(forTextStyle: .body),
            .foregroundColor: configuredTextColor ?? UIColor.label,
            .paragraphStyle: paragraph
        ]

        guard configuredAnimatesTextReveal else {
            attributedText = NSAttributedString(string: configuredText, attributes: attributes)
            return
        }

        let characterCount = configuredText.count
        let solidCount = min(characterCount, max(0, Int(floor(displayedCharacterCount))))
        guard solidCount < characterCount else {
            attributedText = NSAttributedString(string: configuredText, attributes: attributes)
            return
        }

        let solidEnd = configuredText.index(
            configuredText.startIndex,
            offsetBy: solidCount,
            limitedBy: configuredText.endIndex
        ) ?? configuredText.endIndex
        let attributed = NSMutableAttributedString(
            string: String(configuredText[..<solidEnd]),
            attributes: attributes
        )

        let fadeEnd = min(characterCount, solidCount + fadeWindowCharacterCount)
        if solidCount < fadeEnd {
            var characterIndex = solidCount
            var textIndex = solidEnd
            while characterIndex < fadeEnd, textIndex < configuredText.endIndex {
                let nextIndex = configuredText.index(after: textIndex)
                let opacity = opacity(forCharacterAt: characterIndex)
                attributed.append(NSAttributedString(
                    string: String(configuredText[textIndex..<nextIndex]),
                    attributes: [
                        .font: configuredFont ?? UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: (configuredTextColor ?? UIColor.label).withAlphaComponent(opacity),
                        .paragraphStyle: paragraph
                    ]
                ))
                characterIndex += 1
                textIndex = nextIndex
            }
        }

        attributedText = attributed
    }

    private func opacity(forCharacterAt index: Int) -> CGFloat {
        let distance = Double(index + 1) - displayedCharacterCount
        let opacity = 1 - (distance / Double(fadeWindowCharacterCount))
        return CGFloat(min(1, max(0.12, opacity)))
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        lastFrameTime = Date.timeIntervalSinceReferenceDate
        let link = CADisplayLink(target: self, selector: #selector(displayLinkDidTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkDidTick() {
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = max(0, now - lastFrameTime)
        lastFrameTime = now

        let targetCount = Double(configuredText.count)
        guard displayedCharacterCount < targetCount else {
            displayedCharacterCount = targetCount
            renderDisplayedText()
            stopDisplayLink()
            return
        }

        displayedCharacterCount = min(targetCount, displayedCharacterCount + elapsed * revealCharactersPerSecond)
        renderDisplayedText()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if preferredMaxLayoutWidth != width {
            preferredMaxLayoutWidth = width
            invalidateIntrinsicContentSize()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else if displayedCharacterCount < Double(configuredText.count) {
            startDisplayLink()
        }
    }
}
#endif

private struct StreamingPlainText: View {
    private struct Chunk: Identifiable {
        let id: Int
        let value: String
    }

    let text: String
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    @State private var frozenChunks: [Chunk] = []
    @State private var liveText = ""
    @State private var lastText = ""
    @State private var committedCharacterCount = 0
    @State private var nextChunkID = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(frozenChunks) { chunk in
                streamingText(chunk.value)
            }

            if !liveText.isEmpty {
                streamingText(liveText)
            }
        }
        .onAppear {
            updateText(text)
        }
        .onChange(of: text) { _, newText in
            updateText(newText)
        }
    }

    private func streamingText(_ value: String) -> some View {
        Text(verbatim: value)
            .font(font)
            .foregroundStyle(foregroundColor)
            .lineSpacing(lineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func updateText(_ newText: String) {
        guard newText != lastText else { return }

        guard newText.hasPrefix(lastText) else {
            rebuild(from: newText)
            return
        }

        lastText = newText
        refreshLiveText(from: newText)
    }

    private func rebuild(from newText: String) {
        frozenChunks = []
        liveText = ""
        lastText = newText
        committedCharacterCount = 0
        nextChunkID = 0
        refreshLiveText(from: newText)
    }

    private func refreshLiveText(from fullText: String) {
        let committedIndex = fullText.index(
            fullText.startIndex,
            offsetBy: committedCharacterCount,
            limitedBy: fullText.endIndex
        ) ?? fullText.endIndex
        var tail = String(fullText[committedIndex...])

        while let boundary = commitBoundary(in: tail) {
            let frozen = String(tail[..<boundary])
            appendFrozenChunk(frozen)
            committedCharacterCount += frozen.count
            tail = String(tail[boundary...])
        }

        liveText = tail
    }

    private func appendFrozenChunk(_ value: String) {
        guard !value.isEmpty else { return }
        frozenChunks.append(Chunk(id: nextChunkID, value: value))
        nextChunkID += 1
    }

    private func commitBoundary(in text: String) -> String.Index? {
        if let paragraphRange = text.range(of: "\n\n") {
            return paragraphRange.upperBound
        }

        guard text.count > softChunkCharacterLimit else {
            return nil
        }

        let preferredLimit = text.index(
            text.startIndex,
            offsetBy: softChunkCharacterLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        if let newline = text[..<preferredLimit].lastIndex(of: "\n") {
            return text.index(after: newline)
        }

        guard text.count > hardChunkCharacterLimit else {
            return nil
        }

        let hardLimit = text.index(
            text.startIndex,
            offsetBy: hardChunkCharacterLimit,
            limitedBy: text.endIndex
        ) ?? text.endIndex

        guard let newline = text[..<hardLimit].lastIndex(of: "\n") else {
            return nil
        }

        return text.index(after: newline)
    }

    private var softChunkCharacterLimit: Int { 1_200 }
    private var hardChunkCharacterLimit: Int { 2_400 }
}

private struct StreamingTextFade: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let lineSpacing: CGFloat

    @State private var targetText = ""
    @State private var revealProgress = 0.0
    @State private var writerTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            layoutText
                .opacity(0)
                .accessibilityHidden(true)

            renderedText
        }
        .font(font)
        .lineSpacing(lineSpacing)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            updateTarget(text, animatingInitialText: true)
        }
        .onChange(of: text) { _, newText in
            updateTarget(newText, animatingInitialText: false)
        }
        .onDisappear {
            writerTask?.cancel()
            writerTask = nil
        }
    }

    private var layoutText: Text {
        Text(verbatim: targetText.isEmpty ? text : targetText)
            .foregroundColor(foregroundColor)
    }

    private var renderedText: Text {
        let characters = Array(targetText.isEmpty ? text : targetText)
        let solidCount = min(characters.count, max(0, Int(floor(revealProgress))))
        var attributed = AttributedString(String(characters.prefix(solidCount)))
        attributed.foregroundColor = foregroundColor

        let fadeEnd = min(characters.count, solidCount + fadeWindowCharacterCount)
        for index in solidCount ..< fadeEnd {
            var character = AttributedString(String(characters[index]))
            character.foregroundColor = foregroundColor.opacity(opacity(forCharacterAt: index))
            attributed += character
        }

        return Text(attributed)
    }

    private func updateTarget(_ newText: String, animatingInitialText: Bool) {
        guard newText != targetText else { return }

        guard targetText.isEmpty || newText.hasPrefix(targetText) || newText.count >= Int(revealProgress) else {
            targetText = newText
            revealProgress = Double(newText.count)
            return
        }

        targetText = newText
        if animatingInitialText, revealProgress == 0 {
            revealProgress = max(0, Double(newText.count) - 18)
        } else {
            revealProgress = min(revealProgress, Double(newText.count))
        }
        startWriterIfNeeded()
    }

    private func startWriterIfNeeded() {
        guard writerTask == nil else { return }

        writerTask = Task { @MainActor in
            defer { writerTask = nil }
            while !Task.isCancelled {
                let remaining = Double(targetText.count) - revealProgress
                guard remaining > 0.01 else {
                    revealProgress = Double(targetText.count)
                    return
                }

                revealProgress = min(Double(targetText.count), revealProgress + revealStep(forRemainingCharacters: remaining))
                try? await Task.sleep(for: .milliseconds(writerTickMilliseconds(forRemainingCharacters: remaining)))
            }
        }
    }

    private func opacity(forCharacterAt index: Int) -> Double {
        let distance = Double(index + 1) - revealProgress
        let opacity = 1 - (distance / Double(fadeWindowCharacterCount))
        return min(1, max(0.12, opacity))
    }

    private func revealStep(forRemainingCharacters remaining: Double) -> Double {
        if remaining < 10 {
            return 1.1
        }

        if remaining < 45 {
            return min(4.5, max(1.6, remaining / 9))
        }

        if remaining < 180 {
            return min(14, max(5, remaining / 7))
        }

        return min(32, max(16, remaining / 5))
    }

    private func writerTickMilliseconds(forRemainingCharacters remaining: Double) -> Int {
        remaining > 120 ? 18 : 26
    }

    private var fadeWindowCharacterCount: Int { 18 }
}
