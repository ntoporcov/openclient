import SwiftUI
import MapKit
#if canImport(RealityKit) && canImport(UIKit)
import RealityKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension OpenCodeMessageEnvelope {
    var isAssistantMessage: Bool {
        (info.role ?? "").lowercased() == "assistant"
    }

    func containsText(_ marker: String) -> Bool {
        parts.contains { $0.text?.contains(marker) == true }
    }
}

struct OpenCodeLargeMessageChunk: Identifiable, Equatable {
    let id: String
    let text: String
    let isTail: Bool
}

enum OpenCodeLargeMessageChunker {
    static let minimumCharacterCount = 600
    static let softCharacterLimit = 1_000
    static let hardCharacterLimit = 1_800

    private enum MarkdownBlockKind {
        case paragraph
        case heading
        case listItem
        case codeBlock
        case blockQuote
        case table
    }

    private struct MarkdownBlock {
        let kind: MarkdownBlockKind
        let text: String
    }

    private struct MarkdownLine {
        let value: String
        let text: String

        var isBlank: Bool {
            value.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private struct ListMarker {
        let indent: Int
    }

    static func chunks(for message: OpenCodeMessageEnvelope) -> [OpenCodeLargeMessageChunk]? {
        guard let text = chunkableText(in: message) else {
            return nil
        }

        let chunks = makeChunks(from: text)
        return chunks.count > 1 ? chunks : nil
    }

    static func chunkableText(in message: OpenCodeMessageEnvelope) -> String? {
        guard (message.info.role ?? "").lowercased() == "assistant",
              let part = chunkTextPart(in: message),
              let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= minimumCharacterCount else {
            return nil
        }

        return text
    }

    static func chunkTextPart(in message: OpenCodeMessageEnvelope) -> OpenCodePart? {
        let textParts = message.parts.filter { part in
            part.type == "text" && part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        guard textParts.count == 1 else { return nil }

        let hasRenderableNonTextPart = message.parts.contains { part in
            guard part.type != "text" else { return false }

            if part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }

            return !["", "step-start", "step-finish", "reasoning"].contains(part.type)
        }
        guard !hasRenderableNonTextPart else { return nil }

        return textParts[0]
    }

    static func makeChunks(from text: String) -> [OpenCodeLargeMessageChunk] {
        makeChunks(fromNormalizedText: normalizedText(text), startingAt: 0)
    }

    static func makeChunks(fromNormalizedText normalizedText: String, startingAt startIndex: Int) -> [OpenCodeLargeMessageChunk] {
        let blocks = markdownBlocks(fromNormalizedText: normalizedText)
        let values = chunkValues(from: blocks)

        return values.enumerated().map { index, value in
            OpenCodeLargeMessageChunk(id: "chunk-\(startIndex + index)", text: value, isTail: index == values.count - 1)
        }
    }

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    static func isMarkdownListLine(_ line: String) -> Bool {
        markdownListMarker(in: line) != nil
    }

    static func isMarkdownTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") || trimmed.contains(" | ")
    }

    static func isMarkdownFenceLine(_ line: String) -> Bool {
        markdownFenceMarker(in: line) != nil
    }

    static func structuralSignature(for message: OpenCodeMessageEnvelope) -> String {
        let parts = message.parts.map { part in
            [part.id ?? "", part.type].joined(separator: ":")
        }

        return [message.info.role ?? "", parts.joined(separator: "|")].joined(separator: "#")
    }

    private static func chunkValues(from blocks: [MarkdownBlock]) -> [String] {
        var values: [String] = []
        var paragraphBuffer = ""
        var listBuffer = ""

        func appendParagraphBuffer() {
            guard !paragraphBuffer.isEmpty else { return }
            values.append(paragraphBuffer)
            paragraphBuffer = ""
        }

        func appendListBuffer() {
            guard !listBuffer.isEmpty else { return }
            values.append(listBuffer)
            listBuffer = ""
        }

        func appendParagraphText(_ text: String) {
            for value in splitPlainTextBlock(text) {
                if paragraphBuffer.isEmpty {
                    paragraphBuffer = value
                } else if paragraphBuffer.count + value.count > softCharacterLimit {
                    appendParagraphBuffer()
                    paragraphBuffer = value
                } else {
                    paragraphBuffer += value
                }

                if paragraphBuffer.count >= hardCharacterLimit {
                    appendParagraphBuffer()
                }
            }
        }

        for block in blocks {
            switch block.kind {
            case .paragraph:
                appendListBuffer()
                appendParagraphText(block.text)
            case .listItem:
                appendParagraphBuffer()
                if !listBuffer.isEmpty, listBuffer.count + block.text.count > softCharacterLimit {
                    appendListBuffer()
                }
                listBuffer += block.text
            case .heading, .codeBlock, .blockQuote, .table:
                appendParagraphBuffer()
                appendListBuffer()
                values.append(block.text)
            }
        }

        appendParagraphBuffer()
        appendListBuffer()

        return values.filter { !$0.isEmpty }
    }

    private static func markdownBlocks(fromNormalizedText text: String) -> [MarkdownBlock] {
        let lines = markdownLines(fromNormalizedText: text)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if lines[index].isBlank {
                blocks.append(MarkdownBlock(kind: .paragraph, text: consumeBlankLines(in: lines, index: &index)))
                continue
            }

            if isMarkdownFenceLine(lines[index].value) {
                blocks.append(MarkdownBlock(kind: .codeBlock, text: consumeFencedCodeBlock(in: lines, index: &index)))
                continue
            }

            if isMarkdownTableStart(in: lines, at: index) {
                blocks.append(MarkdownBlock(kind: .table, text: consumeMarkdownTable(in: lines, index: &index)))
                continue
            }

            if isMarkdownBlockQuoteLine(lines[index].value) {
                blocks.append(MarkdownBlock(kind: .blockQuote, text: consumeBlockQuote(in: lines, index: &index)))
                continue
            }

            if isMarkdownHeadingLine(lines[index].value) {
                blocks.append(MarkdownBlock(kind: .heading, text: consumeSingleLineBlock(in: lines, index: &index)))
                continue
            }

            if markdownListMarker(in: lines[index].value) != nil {
                blocks.append(MarkdownBlock(kind: .listItem, text: consumeListItem(in: lines, index: &index)))
                continue
            }

            blocks.append(MarkdownBlock(kind: .paragraph, text: consumeParagraph(in: lines, index: &index)))
        }

        return blocks
    }

    private static func markdownLines(fromNormalizedText text: String) -> [MarkdownLine] {
        let values = text.components(separatedBy: "\n")
        return values.indices.map { index in
            let isLast = index == values.index(before: values.endIndex)
            return MarkdownLine(value: values[index], text: isLast ? values[index] : values[index] + "\n")
        }
    }

    private static func consumeSingleLineBlock(in lines: [MarkdownLine], index: inout Int) -> String {
        var text = lines[index].text
        index += 1
        text += consumeBlankLines(in: lines, index: &index)
        return text
    }

    private static func consumeParagraph(in lines: [MarkdownLine], index: inout Int) -> String {
        var text = ""

        while index < lines.count {
            if !text.isEmpty, isMarkdownBlockStart(in: lines, at: index) {
                break
            }

            text += lines[index].text
            let isBlank = lines[index].isBlank
            index += 1

            if isBlank {
                text += consumeBlankLines(in: lines, index: &index)
                break
            }
        }

        return text
    }

    private static func consumeFencedCodeBlock(in lines: [MarkdownLine], index: inout Int) -> String {
        let openingFence = markdownFenceMarker(in: lines[index].value)
        var text = lines[index].text
        index += 1

        while index < lines.count {
            let line = lines[index]
            text += line.text
            index += 1

            if let openingFence, markdownFenceMarker(in: line.value) == openingFence {
                text += consumeBlankLines(in: lines, index: &index)
                break
            }
        }

        return text
    }

    private static func consumeMarkdownTable(in lines: [MarkdownLine], index: inout Int) -> String {
        var text = ""

        while index < lines.count {
            guard isMarkdownTableLine(lines[index].value) || isMarkdownTableSeparatorLine(lines[index].value) else {
                break
            }

            text += lines[index].text
            index += 1
        }

        text += consumeBlankLines(in: lines, index: &index)
        return text
    }

    private static func consumeBlockQuote(in lines: [MarkdownLine], index: inout Int) -> String {
        var text = ""

        while index < lines.count, isMarkdownBlockQuoteLine(lines[index].value) {
            text += lines[index].text
            index += 1
        }

        text += consumeBlankLines(in: lines, index: &index)
        return text
    }

    private static func consumeListItem(in lines: [MarkdownLine], index: inout Int) -> String {
        guard let marker = markdownListMarker(in: lines[index].value) else { return consumeParagraph(in: lines, index: &index) }

        var text = lines[index].text
        var hasConsumedBlankLine = false
        index += 1

        while index < lines.count {
            let line = lines[index]

            if line.isBlank {
                text += line.text
                hasConsumedBlankLine = true
                index += 1
                continue
            }

            if let nextMarker = markdownListMarker(in: line.value), nextMarker.indent <= marker.indent {
                break
            }

            let indent = leadingWhitespaceCount(in: line.value)
            if hasConsumedBlankLine, indent <= marker.indent {
                break
            }

            if indent <= marker.indent, isMarkdownBlockStart(in: lines, at: index) {
                break
            }

            text += line.text
            hasConsumedBlankLine = false
            index += 1
        }

        return text
    }

    private static func consumeBlankLines(in lines: [MarkdownLine], index: inout Int) -> String {
        var text = ""

        while index < lines.count, lines[index].isBlank {
            text += lines[index].text
            index += 1
        }

        return text
    }

    private static func splitPlainTextBlock(_ text: String) -> [String] {
        guard text.count > hardCharacterLimit else { return [text] }

        var remaining = text
        var values: [String] = []

        while remaining.count > hardCharacterLimit {
            let upperBound = remaining.index(remaining.startIndex, offsetBy: hardCharacterLimit)
            let searchRange = remaining.startIndex..<upperBound
            let splitIndex = bestPlainTextSplitIndex(in: remaining, range: searchRange) ?? upperBound
            values.append(String(remaining[..<splitIndex]))
            remaining = String(remaining[splitIndex...])
        }

        if !remaining.isEmpty {
            values.append(remaining)
        }

        return values
    }

    private static func bestPlainTextSplitIndex(in text: String, range: Range<String.Index>) -> String.Index? {
        var candidate = range.upperBound

        while candidate > range.lowerBound {
            let previous = text.index(before: candidate)
            if text[previous] == "." || text[previous] == "!" || text[previous] == "?" || text[previous].isNewline {
                return candidate
            }
            candidate = previous
        }

        candidate = range.upperBound
        while candidate > range.lowerBound {
            let previous = text.index(before: candidate)
            if text[previous].isWhitespace {
                return candidate
            }
            candidate = previous
        }

        return nil
    }

    private static func isMarkdownBlockStart(in lines: [MarkdownLine], at index: Int) -> Bool {
        guard index < lines.count, !lines[index].isBlank else { return false }
        return isMarkdownFenceLine(lines[index].value)
            || isMarkdownTableStart(in: lines, at: index)
            || isMarkdownBlockQuoteLine(lines[index].value)
            || isMarkdownHeadingLine(lines[index].value)
            || markdownListMarker(in: lines[index].value) != nil
    }

    private static func isMarkdownHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return false }

        var level = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == "#", level < 6 {
            level += 1
            index = trimmed.index(after: index)
        }

        return level > 0 && index < trimmed.endIndex && trimmed[index].isWhitespace
    }

    private static func isMarkdownBlockQuoteLine(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func isMarkdownTableStart(in lines: [MarkdownLine], at index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        return isMarkdownTableLine(lines[index].value) && isMarkdownTableSeparatorLine(lines[index + 1].value)
    }

    private static func markdownListMarker(in line: String) -> ListMarker? {
        let indent = leadingWhitespaceCount(in: line)
        let trimmed = line.dropFirst(min(indent, line.count))
        guard !trimmed.isEmpty else { return nil }

        let prefixes = ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "* [x] ", "* [X] ", "+ [ ] ", "+ [x] ", "+ [X] ", "- ", "* ", "+ "]
        if prefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return ListMarker(indent: indent)
        }

        var digitCount = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index].isNumber, digitCount < 6 {
            digitCount += 1
            index = trimmed.index(after: index)
        }

        guard digitCount > 0, index < trimmed.endIndex else { return nil }
        guard trimmed[index] == "." || trimmed[index] == ")" else { return nil }
        let nextIndex = trimmed.index(after: index)
        guard nextIndex < trimmed.endIndex, trimmed[nextIndex].isWhitespace else { return nil }
        return ListMarker(indent: indent)
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " {
                count += 1
            } else if character == "\t" {
                count += 4
            } else {
                break
            }
        }

        return count
    }

    private static func isMarkdownTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let cells = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            guard value.count >= 3, value.contains("-") else { return false }
            return value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func markdownFenceMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }
}

final class OpenCodeLargeMessageChunkCache {
    private struct Entry {
        let signature: String
        var text: String
        var normalizedText: String
        var frozenChunks: [OpenCodeLargeMessageChunk]
        var liveTail: String

        var result: [OpenCodeLargeMessageChunk]? {
            var chunks = frozenChunks
            if !liveTail.isEmpty {
                chunks.append(OpenCodeLargeMessageChunk(id: "chunk-\(frozenChunks.count)", text: liveTail, isTail: true))
            }

            return chunks.count > 1 ? chunks : nil
        }

        init(signature: String, text: String) {
            self.signature = signature
            self.text = text
            self.normalizedText = OpenCodeLargeMessageChunker.normalizedText(text)

            let chunks = OpenCodeLargeMessageChunker.makeChunks(fromNormalizedText: normalizedText, startingAt: 0)
            self.frozenChunks = Array(chunks.dropLast())
            self.liveTail = chunks.last?.text ?? ""
        }

        mutating func append(_ suffix: String) {
            guard !suffix.isEmpty else { return }

            let normalizedSuffix = OpenCodeLargeMessageChunker.normalizedText(suffix)
            text += suffix
            normalizedText += normalizedSuffix

            let mutableText = liveTail + normalizedSuffix
            let mutableChunks = OpenCodeLargeMessageChunker.makeChunks(
                fromNormalizedText: mutableText,
                startingAt: frozenChunks.count
            )

            frozenChunks.append(contentsOf: mutableChunks.dropLast())
            liveTail = mutableChunks.last?.text ?? ""
        }
    }

    private var entries: [String: Entry] = [:]

    func chunks(for message: OpenCodeMessageEnvelope, isStreaming: Bool) -> [OpenCodeLargeMessageChunk]? {
        if isStreaming {
            return chunks(for: message)
        }

        return finalizedChunks(for: message)
    }

    func chunks(for message: OpenCodeMessageEnvelope) -> [OpenCodeLargeMessageChunk]? {
        guard let text = OpenCodeLargeMessageChunker.chunkableText(in: message) else {
            entries[message.id] = nil
            return nil
        }

        let signature = OpenCodeLargeMessageChunker.structuralSignature(for: message)

        if var entry = entries[message.id], entry.signature == signature {
            if entry.text == text {
                return entry.result
            }

            if text.hasPrefix(entry.text) {
                let suffixStart = text.index(text.startIndex, offsetBy: entry.text.count)
                entry.append(String(text[suffixStart...]))
                entries[message.id] = entry
                return entry.result
            }
        }

        let entry = Entry(signature: signature, text: text)
        entries[message.id] = entry
        return entry.result
    }

    private func finalizedChunks(for message: OpenCodeMessageEnvelope) -> [OpenCodeLargeMessageChunk]? {
        guard let text = OpenCodeLargeMessageChunker.chunkableText(in: message) else {
            entries[message.id] = nil
            return nil
        }

        let signature = OpenCodeLargeMessageChunker.structuralSignature(for: message)
        if let entry = entries[message.id], entry.signature == signature, entry.text == text {
            return entry.result
        }

        let entry = Entry(signature: signature, text: text)
        entries[message.id] = entry
        return entry.result
    }

    func prune(keeping messageIDs: Set<String>) {
        entries = entries.filter { messageIDs.contains($0.key) }
    }
}

fileprivate enum AppleIntelligenceInstructionTab: String, CaseIterable, Identifiable {
    case user
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .user:
            return "User Prompt"
        case .system:
            return "System Prompt"
        }
    }
}

private struct MessageDebugPayload: Identifiable {
    let id: String
    let title: String
    let json: String

    init?(message: OpenCodeMessageEnvelope) {
        guard let json = message.debugJSONString() else { return nil }
        self.id = message.id
        self.title = message.info.id
        self.json = json
    }
}

private struct CompactionSummaryPayload: Identifiable {
    let id: String
    let title: String
    let summary: String
}

private struct CompactionDisplayItem: Identifiable {
    let boundaryMessage: OpenCodeMessageEnvelope
    let summaryMessage: OpenCodeMessageEnvelope?

    var id: String { "compaction-\(boundaryMessage.id)" }

    var summaryText: String? {
        summaryMessage?.parts
            .compactMap(\.text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
            .nilIfEmpty
    }

    var payload: CompactionSummaryPayload? {
        guard let summaryText else { return nil }
        return CompactionSummaryPayload(id: id, title: "Compacted Context", summary: summaryText)
    }
}

private struct LargeMessageChunkDisplayItem: Identifiable {
    let message: OpenCodeMessageEnvelope
    let chunk: OpenCodeLargeMessageChunk

    var id: String { "message-chunk-\(message.id)-\(chunk.id)" }
}

private enum ChatDisplayItem: Identifiable {
    case message(OpenCodeMessageEnvelope)
    case largeMessageChunk(LargeMessageChunkDisplayItem)
    case compaction(CompactionDisplayItem)
    case findPlaceReveal(FindPlaceGameCity)
    case findBugSolved

    var id: String {
        switch self {
        case let .message(message):
            return message.id
        case let .largeMessageChunk(item):
            return item.id
        case let .compaction(item):
            return item.id
        case let .findPlaceReveal(city):
            return "find-place-reveal-\(city.id)"
        case .findBugSolved:
            return "find-bug-solved"
        }
    }
}

private enum ChatTranscriptRow: Identifiable {
    case weatherAttribution
    case olderMessages(count: Int)
    case displayItem(ChatDisplayItem)
    case thinking(isVisible: Bool)
    case bottomAnchor

    var id: String {
        switch self {
        case .weatherAttribution:
            return "chat-weather-attribution"
        case .olderMessages:
            return ChatScrollTarget.olderMessagesButton
        case let .displayItem(item):
            return item.id
        case .thinking:
            return ChatScrollTarget.thinkingRow
        case .bottomAnchor:
            return ChatScrollTarget.bottomAnchor
        }
    }
}

private extension ChatTranscriptRow {
    var renderSignature: String {
        switch self {
        case .weatherAttribution:
            return id
        case let .olderMessages(count):
            return "\(id):\(count)"
        case let .thinking(isVisible):
            return "\(id):\(isVisible)"
        case .bottomAnchor:
            return id
        case let .displayItem(item):
            return item.renderSignature
        }
    }
}

private extension ChatDisplayItem {
    var renderSignature: String {
        switch self {
        case let .message(message):
            return message.renderSignature
        case let .largeMessageChunk(item):
            return [item.id, item.chunk.text.count.description, item.chunk.text.hashValue.description, item.chunk.isTail.description, item.message.renderSignature].joined(separator: ":")
        case let .compaction(item):
            return [item.id, item.boundaryMessage.renderSignature, item.summaryMessage?.renderSignature ?? "nil"].joined(separator: ":")
        case let .findPlaceReveal(city):
            return "\(id):\(city.name):\(city.country)"
        case .findBugSolved:
            return id
        }
    }
}

private extension OpenCodeMessageEnvelope {
    var renderSignature: String {
        "\(id)#\(hashValue)"
    }
}

private struct ChatDisplayItemCacheKey: Equatable {
    struct MessageKey: Equatable {
        let id: String
        let role: String?
        let parentID: String?
        let errorName: String?
        let errorMessage: String?
        let isStreaming: Bool
        let isCompactionSummary: Bool
        let parts: [PartKey]
    }

    struct PartKey: Equatable {
        let id: String?
        let type: String
        let tool: String?
        let textCount: Int
        let textSampleHash: Int
        let reason: String?
        let filename: String?
        let mime: String?
        let stateStatus: String?
        let stateTitle: String?
        let stateInputSampleHash: Int
        let stateOutputCount: Int
        let stateOutputSampleHash: Int
        let metadataSessionID: String?
        let metadataFileCount: Int?
        let metadataLoadedCount: Int?
        let metadataTruncated: Bool?
    }

    let messages: [MessageKey]
    let findPlaceGameID: String?
    let findBugGameID: String?
}

private final class ChatDisplayItemCache {
    private var lastKey: ChatDisplayItemCacheKey?
    private var lastItems: [ChatDisplayItem] = []

    func items(
        for key: ChatDisplayItemCacheKey,
        messagesByID: [String: OpenCodeMessageEnvelope],
        build: () -> [ChatDisplayItem]
    ) -> [ChatDisplayItem] {
        if lastKey == key {
            let refreshedItems = lastItems.map { $0.refreshedMessages(using: messagesByID) }
            lastItems = refreshedItems
            return lastItems
        }

        let items = build()
        lastKey = key
        lastItems = items
        return items
    }
}

private extension ChatDisplayItem {
    func refreshedMessages(using messagesByID: [String: OpenCodeMessageEnvelope]) -> ChatDisplayItem {
        switch self {
        case let .message(message):
            return .message(messagesByID[message.id] ?? message)
        case let .largeMessageChunk(item):
            return .largeMessageChunk(
                LargeMessageChunkDisplayItem(message: messagesByID[item.message.id] ?? item.message, chunk: item.chunk)
            )
        case let .compaction(item):
            return .compaction(
                CompactionDisplayItem(
                    boundaryMessage: messagesByID[item.boundaryMessage.id] ?? item.boundaryMessage,
                    summaryMessage: item.summaryMessage.map { messagesByID[$0.id] ?? $0 }
                )
            )
        case let .findPlaceReveal(city):
            return .findPlaceReveal(city)
        case .findBugSolved:
            return .findBugSolved
        }
    }
}

private enum ChatScrollTarget {
    static let olderMessagesButton = "chat-older-messages-button"
    static let thinkingRow = "chat-thinking-row"
    static let bottomAnchor = "chat-bottom-anchor"
}

private struct PendingOutgoingSend {
    let text: String
    let agentMentions: [OpenCodeAgentMention]
    let attachments: [OpenCodeComposerAttachment]
    let messageID: String?
    let partID: String?
}

private struct LargeMessageChunkRow: View, Equatable {
    let text: String
    let allowsTextSelection: Bool
    let isStreamingTail: Bool
    let animatesStreamingText: Bool

    var body: some View {
        if allowsTextSelection {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            MarkdownMessageText(
                text: text,
                isUser: false,
                style: .standard,
                isStreaming: isStreamingTail,
                animatesStreamingText: animatesStreamingText
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FindPlaceRevealRow: View {
    let city: FindPlaceGameCity
    @State private var position: MapCameraPosition

    init(city: FindPlaceGameCity) {
        self.city = city
        _position = State(initialValue: .region(MKCoordinateRegion(
            center: city.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.8, longitudeDelta: 0.8)
        )))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You found it")
                    .font(.headline)
                Text("\(city.name), \(city.country)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Map(position: $position) {
                Marker(city.name, coordinate: city.coordinate)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.quaternary)
            }
        }
        .padding(14)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct WeatherAttributionRow: View {
    private let legalAttributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(" Weather")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)

            Text("weather data")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Link("weatherkit.apple.com/legal-attribution.html", destination: legalAttributionURL)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct FindBugSolvedRow: View {
    var body: some View {
        VStack(spacing: 12) {
            BugSolvedMedalView()
                .frame(width: 260, height: 260)

            VStack(spacing: 4) {
                Text("Bug Found")
                    .font(.headline)
                Text("Nice catch. You found the broken logic.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct BugSolvedMedalView: View {
    @State private var baseSpin: Double = 0
    @State private var dragSpin: Double = 0
    @State private var velocity: Double = 80
    @State private var lastDragWidth: CGFloat = 0

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil
    }

    var body: some View {
        Group {
            if isScreenshotScene {
                RealityMedalView(angle: 0)
            } else {
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let spin = baseSpin + dragSpin + time.truncatingRemainder(dividingBy: 10) * velocity

                    RealityMedalView(angle: spin)
                }
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let delta = value.translation.width - lastDragWidth
                    lastDragWidth = value.translation.width
                    dragSpin += Double(delta) * 1.7
                }
                .onEnded { value in
                    velocity = max(30, min(520, abs(Double(value.predictedEndTranslation.width - value.translation.width)) * 2.2))
                    if value.predictedEndTranslation.width < value.translation.width {
                        velocity *= -1
                    }
                    baseSpin += dragSpin
                    dragSpin = 0
                    lastDragWidth = 0
                }
        )
        .accessibilityLabel("Bug found medal")
    }
}

private struct RealityMedalView: View {
    let angle: Double

    var body: some View {
#if canImport(RealityKit) && canImport(UIKit)
        if #available(iOS 18.0, *) {
            RealityKitMedalScene(angle: angle)
        } else {
            FallbackMedalView(angle: angle)
        }
#else
        FallbackMedalView(angle: angle)
#endif
    }
}

#if canImport(RealityKit) && canImport(UIKit)
@available(iOS 18.0, *)
private struct RealityKitMedalScene: View {
    let angle: Double

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "medal-root"

            let rim = ModelEntity(
                mesh: .generateCylinder(height: 0.16, radius: 0.92),
                materials: [SimpleMaterial(color: UIColor.systemOrange, roughness: 0.2, isMetallic: true)]
            )
            rim.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            root.addChild(rim)

            let medal = ModelEntity(
                mesh: .generateCylinder(height: 0.15, radius: 0.84),
                materials: [SimpleMaterial(color: UIColor.systemYellow, roughness: 0.26, isMetallic: true)]
            )
            medal.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
            medal.position.z = 0.006
            root.addChild(medal)

            if let starMaterial = Self.starMaterial() {
                let star = ModelEntity(mesh: .generatePlane(width: 0.92, height: 0.92), materials: [starMaterial])
                star.position.z = 0.083
                root.addChild(star)
            }

            root.position.z = -2.2
            content.add(root)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == "medal-root" }) else { return }
            root.orientation = simd_quatf(angle: Float(angle * .pi / 180), axis: SIMD3<Float>(0, 1, 0))
        }
        .background(Color.clear)
    }

    private static func starMaterial() -> UnlitMaterial? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 220, weight: .black)
        guard let image = UIImage(systemName: "star.fill", withConfiguration: configuration) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320))
        let rendered = renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: 320, height: 320)))
            UIColor.white.setFill()
            image.draw(in: CGRect(x: 50, y: 50, width: 220, height: 220))
        }

        guard let cgImage = rendered.cgImage,
              let texture = try? TextureResource.generate(from: cgImage, options: .init(semantic: .color)) else {
            return nil
        }

        var material = UnlitMaterial()
        material.color = .init(texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        return material
    }
}
#endif

private struct FallbackMedalView: View {
    let angle: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.orange.opacity(0.85), .yellow.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                .offset(x: 10)
                .shadow(color: .orange.opacity(0.28), radius: 16, y: 8)

            Circle()
                .fill(AngularGradient(colors: [.yellow, .orange, .yellow, .white, .yellow], center: .center))
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.55), lineWidth: 5)
                        .padding(8)
                }
                .shadow(color: .orange.opacity(0.35), radius: 24, y: 10)

            Image(systemName: "star.fill")
                .font(.system(size: 74, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
    }
}

private final class ChatViewTaskStore {
    var delayedLoadingIndicatorTask: Task<Void, Never>?
    var composerDraftPersistenceTask: Task<Void, Never>?
}

private struct MessageComposerSnapshot: Equatable {
    let isAccessoryMenuOpenValue: Bool
    let commands: [OpenCodeCommand]
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let forkSignature: String
    let mcpSignature: String
    let pinnedCommandSignature: String
    let mentionableAgentSignature: String
    let actionSignature: String
}

private struct MessageBubbleSnapshot: Equatable {
    let message: OpenCodeMessageEnvelope
    let detailedMessage: OpenCodeMessageEnvelope?
    let currentSessionID: String?
    let isStreamingMessage: Bool
    let animatesStreamingText: Bool
    let hidesReasoningBlocks: Bool
    let reserveEntryFromComposer: Bool
    let animateEntryFromComposer: Bool
    let streamingReservePadding: CGFloat
}

private struct MessageRowRenderSnapshot {
    let bubble: MessageBubbleSnapshot
    let transition: AnyTransition
}

private struct CompactionRowRenderSnapshot {
    let hasSummary: Bool
    let isStreaming: Bool
    let isDisabled: Bool
}

private struct LargeMessageChunkRowRenderSnapshot {
    let text: String
    let allowsTextSelection: Bool
    let isStreamingTail: Bool
    let animatesStreamingText: Bool
    let bottomPadding: CGFloat
    let streamingReservePadding: CGFloat
}

private struct ThinkingRowRenderSnapshot {
    let animateEntry: Bool
}

private struct BottomRefreshRenderSnapshot {
    let showsIndicator: Bool
    let progress: CGFloat
    let isRefreshing: Bool
    let colorIsActive: Bool
}

private struct ChatProgressOverlaySnapshot {
    let title: String
    let accessibilityLabel: String
}

private enum ChatOverlayKind {
    case forkPreparation
    case delayedLoading
}

private struct ChatOverlayVisibilitySnapshot {
    let visibleOverlay: ChatOverlayKind?
}

private struct DelayedLoadingIndicatorSnapshot {
    let shouldDelay: Bool
}

private enum ComposerOverlayMode {
    case permissions
    case questions
    case childSessionNotice
    case activeComposer
}

private struct ComposerOverlayModeSnapshot {
    let mode: ComposerOverlayMode
}

private struct ChatDisplaySnapshot {
    let messages: [OpenCodeMessageEnvelope]
    let hiddenMessageCount: Int
    let items: [ChatDisplayItem]
    let showsThinking: Bool

    var itemIDs: [String] {
        items.map(\.id) + (showsThinking ? [ChatScrollTarget.thinkingRow] : [])
    }
}

private struct EquatableMessageBubbleHost: View, Equatable {
    let snapshot: MessageBubbleSnapshot
    let resolveTaskSessionID: (OpenCodePart, String) -> String?
    let onSelectPart: (OpenCodePart) -> Void
    let onOpenTaskSession: (String) -> Void
    let onForkMessage: (OpenCodeMessageEnvelope) -> Void
    let onInspectDebugMessage: (OpenCodeMessageEnvelope) -> Void
    let onEntryAnimationStarted: (String) -> Void

    nonisolated static func == (lhs: EquatableMessageBubbleHost, rhs: EquatableMessageBubbleHost) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        MessageBubble(
            message: snapshot.message,
            detailedMessage: snapshot.detailedMessage,
            currentSessionID: snapshot.currentSessionID,
            isStreamingMessage: snapshot.isStreamingMessage,
            animatesStreamingText: snapshot.animatesStreamingText,
            hidesReasoningBlocks: snapshot.hidesReasoningBlocks,
            reserveEntryFromComposer: snapshot.reserveEntryFromComposer,
            animateEntryFromComposer: snapshot.animateEntryFromComposer,
            resolveTaskSessionID: resolveTaskSessionID,
            onSelectPart: onSelectPart,
            onOpenTaskSession: onOpenTaskSession,
            onForkMessage: onForkMessage,
            onInspectDebugMessage: onInspectDebugMessage,
            onEntryAnimationStarted: onEntryAnimationStarted
        )
        .padding(.bottom, snapshot.streamingReservePadding)
    }
}

private struct AccessoryPresenceState: Equatable {
    let attachmentIDs: [String]
    let incompleteTodoIDs: [String]
}

private struct EquatableMessageComposerHost: View, Equatable {
    let draftStore: MessageComposerDraftStore
    let isAccessoryMenuOpen: Binding<Bool>
    let snapshot: MessageComposerSnapshot
    let commands: [OpenCodeCommand]
    let mentionableAgents: [OpenCodeAgent]
    let pinnedCommands: [OpenCodeCommand]
    let pinnedCommandNames: Set<String>
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let forkableMessages: [OpenCodeForkableMessage]
    let mcpServers: [OpenCodeMCPServer]
    let connectedMCPServerCount: Int
    let isLoadingMCP: Bool
    let togglingMCPServerNames: Set<String>
    let mcpErrorMessage: String?
    let actionSignature: String
    let onFocusChange: (Bool) -> Void
    let onTextChange: (String) -> Void
    let onAgentMentionsChange: ([OpenCodeAgentMention]) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSelectCommand: (OpenCodeCommand) -> Void
    let onPinCommand: (OpenCodeCommand) -> Void
    let onUnpinCommand: (OpenCodeCommand) -> Void
    let onCompact: () -> Void
    let onForkMessage: (String) -> Void
    let onLoadMCP: () -> Void
    let onToggleMCP: (String) -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void

    nonisolated static func == (lhs: EquatableMessageComposerHost, rhs: EquatableMessageComposerHost) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        MessageComposer(
            draftStore: draftStore,
            isAccessoryMenuOpen: isAccessoryMenuOpen,
            commands: commands,
            mentionableAgents: mentionableAgents,
            pinnedCommands: pinnedCommands,
            pinnedCommandNames: pinnedCommandNames,
            attachmentCount: attachmentCount,
            isBusy: isBusy,
            canFork: canFork,
            forkableMessages: forkableMessages,
            mcpServers: mcpServers,
            connectedMCPServerCount: connectedMCPServerCount,
            isLoadingMCP: isLoadingMCP,
            togglingMCPServerNames: togglingMCPServerNames,
            mcpErrorMessage: mcpErrorMessage,
            onFocusChange: onFocusChange,
            onTextChange: onTextChange,
            onAgentMentionsChange: onAgentMentionsChange,
            onHeightChange: onHeightChange,
            onSend: onSend,
            onStop: onStop,
            onSelectCommand: onSelectCommand,
            onPinCommand: onPinCommand,
            onUnpinCommand: onUnpinCommand,
            onCompact: onCompact,
            onForkMessage: onForkMessage,
            onLoadMCP: onLoadMCP,
            onToggleMCP: onToggleMCP,
            onAddAttachments: onAddAttachments
        )
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var viewModel: AppViewModel
    let sessionID: String

    @Namespace private var toolbarGlassNamespace
    @State private var copiedDebugLog = false
    @State private var selectedMessageDebugPayload: MessageDebugPayload?
    @State private var selectedCompactionSummary: CompactionSummaryPayload?
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var showingTodoInspector = false
    @State private var visibleMessageCount = 50
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var taskStore = ChatViewTaskStore()
    @State private var composerDraftStore = MessageComposerDraftStore()
    @StateObject private var pinnedCommandStore = PinnedCommandStore()
    @State private var isComposerInputFocused = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var isComposerMenuOpen = false
    @State private var copiedTranscript = false
    @State private var pendingOutgoingSend: PendingOutgoingSend?
    @State private var pendingOutgoingSendTask: Task<Void, Never>?
    @State private var outgoingEntryResetTask: Task<Void, Never>?
    @State private var initialBottomScrollTask: Task<Void, Never>?
    @State private var eagerRefreshTask: Task<Void, Never>?
    @State private var lastEagerRefreshAt: Date?
    @State private var isThinkingRowRevealAllowed = true
    @State private var preparingOutgoingMessageID: String?
    @State private var animatingOutgoingMessageID: String?
    @State private var outgoingEntryAnimationStartedMessageIDs: Set<String> = []
    @State private var hasCompletedInitialHydrationSnap = false
    @State private var isScrollGeometryAtBottom = true
    @State private var isRefreshingChatData = false
    @State private var showsDelayedLoadingIndicator = false
    @State private var bottomPullDistance: CGFloat = 0
    @State private var bottomPullStartedAtBottom = false
    @State private var bottomPullIsTracking = false
    @State private var hasFiredBottomPullHaptic = false
    @State private var chatViewportHeight: CGFloat = 0
    @State private var composerMeasuredHeight: CGFloat = 0
    @State private var keyboardMeasuredHeight: CGFloat = 0
    @State private var bottomReadjustmentToken = 0
    @State private var largeMessageChunkCache = OpenCodeLargeMessageChunkCache()
    @State private var chatDisplayItemCache = ChatDisplayItemCache()

    @State private var selectedInstructionTab: AppleIntelligenceInstructionTab = .user

    private let messageWindowSize = 50
    private let bottomRefreshThreshold: CGFloat = 72
    private let bottomRefreshIndicatorHeight: CGFloat = 34
    private let outgoingRequestDelayMS = 720
    private let thinkingRevealHoldMS = 140
    private let eagerRefreshMinimumInterval: TimeInterval = 4

    private var composerOverlaySnapshot: AppViewModel.ChatComposerOverlaySnapshot {
        viewModel.chatComposerOverlaySnapshot(forSessionID: sessionID)
    }

    private var todoIDs: String {
        composerOverlaySnapshot.todos.map { $0.id }.joined(separator: "|")
    }

    private var permissionIDs: String {
        composerOverlaySnapshot.permissions.map { $0.id }.joined(separator: "|")
    }

    private var questionIDs: String {
        composerOverlaySnapshot.questions.map { $0.id }.joined(separator: "|")
    }

    private var liveSession: OpenCodeSession {
        if let selected = viewModel.selectedSession, selected.id == sessionID {
            return selected
        }

        return viewModel.session(matching: sessionID) ?? OpenCodeSession(
            id: sessionID,
            title: "Session",
            workspaceID: nil,
            directory: nil,
            projectID: nil,
            parentID: nil
        )
    }

    private var isSessionBusy: Bool {
        viewModel.sessionStatuses[liveSession.id] == "busy"
    }

    private var isComposerBusy: Bool {
        isSessionBusy || pendingOutgoingSend != nil
    }

    private var shouldAnimateStreamingText: Bool {
        true
    }

    private var chatHeaderSnapshot: AppViewModel.ChatSessionHeaderSnapshot {
        viewModel.chatSessionHeaderSnapshot(for: liveSession)
    }

    private var isFindPlaceSession: Bool {
        viewModel.findPlaceGame(for: sessionID) != nil
    }

    private var chatItemChangeAnimation: Animation? {
        if !hasCompletedInitialHydrationSnap { return nil }
        if isSendChoreographyActive { return nil }
        return isSessionBusy ? nil : .snappy(duration: 0.28, extraBounce: 0.02)
    }

    private var isSendChoreographyActive: Bool {
        pendingOutgoingSend != nil || preparingOutgoingMessageID != nil || animatingOutgoingMessageID != nil
    }

    var body: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            GeometryReader { geometry in
                let displaySnapshot = chatDisplaySnapshot

                ChatTranscriptCollectionView(
                    rows: transcriptRows(for: displaySnapshot),
                    isAtBottom: $isScrollGeometryAtBottom,
                    bottomScrollToken: bottomReadjustmentToken,
                    bottomContentInset: composerMeasuredHeight + keyboardMeasuredHeight + messageBottomPadding,
                    bottomRefreshThreshold: bottomRefreshThreshold,
                    bottomRefreshProgress: bottomRefreshRenderSnapshot.progress,
                    showsBottomRefreshIndicator: bottomRefreshRenderSnapshot.showsIndicator,
                    bottomRefreshColorIsActive: bottomRefreshRenderSnapshot.colorIsActive,
                    bottomRefreshHeight: messageBottomPadding + bottomRefreshIndicatorHeight * bottomRefreshRenderSnapshot.progress,
                    isRefreshing: isRefreshingChatData,
                    animatedRowIDs: animatedTranscriptRowIDs(for: displaySnapshot),
                    onBottomPullChanged: { distance in
                        bottomPullDistance = distance
                        if distance >= bottomRefreshThreshold, !hasFiredBottomPullHaptic {
                            hasFiredBottomPullHaptic = true
                            OpenCodeHaptics.impact(.crisp)
                        } else if distance < bottomRefreshThreshold * 0.65 {
                            hasFiredBottomPullHaptic = false
                        }
                    },
                    onBottomPullEnded: { shouldRefresh in
                        hasFiredBottomPullHaptic = false
                        if shouldRefresh {
                            Task { @MainActor in
                                await refreshChatDataFromBottomOverscroll()
                            }
                        } else {
                            withAnimation(.snappy(duration: 0.2, extraBounce: 0.02)) {
                                bottomPullDistance = 0
                            }
                        }
                    }
                ) { row in
                    transcriptRowContent(for: row)
                }
                .background(OpenCodePlatformColor.groupedBackground)
                .ignoresSafeArea(.container, edges: [.top, .bottom])
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .accessibilityIdentifier("chat.scroll")
                .onAppear {
                    viewModel.activeChatSessionID = sessionID
                    hasCompletedInitialHydrationSnap = !viewModel.messages.isEmpty
                    chatViewportHeight = geometry.size.height
                    updateDelayedLoadingIndicator()
                    requestBottomReadjustment()
                }
                .onChange(of: geometry.size.height) { _, height in
                    chatViewportHeight = height
                }
                .onChange(of: viewModel.messages.count) { _, count in
                    visibleMessageCount = min(count, max(visibleMessageCount, messageWindowSize))
                    if count == 0 {
                        visibleMessageCount = messageWindowSize
                    }

                    if count > 0, !hasCompletedInitialHydrationSnap {
                        hasCompletedInitialHydrationSnap = true
                        requestBottomReadjustment()
                    }
                    updateDelayedLoadingIndicator()
                }
#if canImport(UIKit)
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                    keyboardMeasuredHeight = keyboardHeight(from: notification)
                    guard keyboardMeasuredHeight > 0 else { return }
                    requestBottomReadjustmentIfPinned()
                }
#endif
            }

            if chatOverlayVisibilitySnapshot.visibleOverlay == .forkPreparation {
                forkPreparationOverlay
            } else if chatOverlayVisibilitySnapshot.visibleOverlay == .delayedLoading {
                delayedLoadingOverlay
            }
            bottomRefreshFloatingIndicator
        }
        .overlay(alignment: .bottom) {
            composerOverlay
        }
        .navigationTitle(chatHeaderSnapshot.navigationTitle)
        .opencodeInlineNavigationTitle()
        .onAppear {
            viewModel.activeChatSessionID = sessionID
            syncComposerDraftFromViewModel()
            updateDelayedLoadingIndicator()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            scheduleEagerChatRefresh(reason: "scene active")
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            scheduleEagerChatRefresh(reason: "did become active")
        }
#endif
        .onDisappear {
            persistComposerDraftNow()
            viewModel.setComposerStreamingFocus(false)
            taskStore.delayedLoadingIndicatorTask?.cancel()
            taskStore.composerDraftPersistenceTask?.cancel()
            pendingOutgoingSendTask?.cancel()
            outgoingEntryResetTask?.cancel()
            initialBottomScrollTask?.cancel()
            eagerRefreshTask?.cancel()
            keyboardMeasuredHeight = 0
            showsDelayedLoadingIndicator = false
            if viewModel.activeChatSessionID == sessionID {
                viewModel.activeChatSessionID = nil
            }
        }
        .toolbar { chatToolbar }
#if DEBUG
        .sheet(isPresented: $viewModel.isShowingDebugProbe) {
            ChatDebugProbeSheet(viewModel: viewModel, copiedDebugLog: $copiedDebugLog)
        }
#endif
        .sheet(item: $selectedActivityDetail) { detail in
            NavigationStack {
                ActivityDetailView(viewModel: viewModel, detail: detail)
            }
        }
        .sheet(item: $selectedMessageDebugPayload) { payload in
            NavigationStack {
                MessageDebugSheet(payload: payload)
            }
        }
        .sheet(item: $selectedCompactionSummary) { payload in
            NavigationStack {
                CompactionSummarySheet(payload: payload)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingTodoInspector) {
            NavigationStack {
                TodoInspectorView(viewModel: viewModel)
            }
        }
        .sheet(item: $selectedAttachmentPreview) { attachment in
            NavigationStack {
                AttachmentPreviewSheet(attachment: attachment)
            }
        }
        .sheet(isPresented: $viewModel.isShowingAppleIntelligenceInstructionsSheet) {
            NavigationStack {
                AppleIntelligenceInstructionsSheet(
                    userInstructions: $viewModel.appleIntelligenceUserInstructions,
                    systemInstructions: $viewModel.appleIntelligenceSystemInstructions,
                    selectedTab: $selectedInstructionTab,
                    defaultUserInstructions: viewModel.defaultAppleIntelligenceUserInstructions,
                    defaultSystemInstructions: viewModel.defaultAppleIntelligenceSystemInstructions,
                    onDone: {
                        viewModel.isShowingAppleIntelligenceInstructionsSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $viewModel.isShowingForkSessionSheet) {
            NavigationStack {
                ForkSessionSheet(viewModel: viewModel, sessionID: sessionID)
            }
            .presentationDetents([.medium, .large])
        }
        .overlay {
            if composerAccessoryExpansion.isExpanded {
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        Color.black.opacity(0.001)
                            .frame(height: geometry.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                dismissComposerOverlays()
                            }
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .onChange(of: accessoryPresenceSignature) { _, _ in
            let overlaySnapshot = composerOverlaySnapshot
            if overlaySnapshot.attachments.isEmpty || overlaySnapshot.todos.allSatisfy(\.isComplete) {
                composerAccessoryExpansion = .collapsed
            }
        }
        .onChange(of: viewModel.messages.count) { _, _ in
            copiedTranscript = false
        }
        .onChange(of: viewModel.composerResetToken) { _, _ in
            syncComposerDraftFromViewModel()
        }
        .onChange(of: viewModel.isLoadingSelectedSession) { _, _ in
            updateDelayedLoadingIndicator()
        }
    }

    private func syncComposerDraftFromViewModel() {
        guard viewModel.selectedSession?.id == sessionID else { return }
        taskStore.composerDraftPersistenceTask?.cancel()
        if composerDraftStore.text != viewModel.draftMessage {
            composerDraftStore.text = viewModel.draftMessage
        }
        if composerDraftStore.agentMentions != viewModel.draftAgentMentions {
            composerDraftStore.agentMentions = viewModel.draftAgentMentions
        }
    }

    private func scheduleComposerDraftPersistence(_ text: String) {
        taskStore.composerDraftPersistenceTask?.cancel()
        taskStore.composerDraftPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            viewModel.saveMessageDraft(text, agentMentions: composerDraftStore.agentMentions, forSessionID: sessionID, updateActiveDraft: false)
        }
    }

    private func persistComposerDraftNow(removesEmpty: Bool = true) {
        taskStore.composerDraftPersistenceTask?.cancel()
        viewModel.saveMessageDraft(composerDraftStore.text, agentMentions: composerDraftStore.agentMentions, forSessionID: sessionID, removesEmpty: removesEmpty)
    }

    private func clearComposerDraft() {
        taskStore.composerDraftPersistenceTask?.cancel()
        if !composerDraftStore.text.isEmpty {
            composerDraftStore.text = ""
        }
        if !composerDraftStore.agentMentions.isEmpty {
            composerDraftStore.agentMentions = []
        }
        viewModel.saveMessageDraft("", agentMentions: [], forSessionID: sessionID)
        viewModel.composerResetToken = UUID()
    }

    private func restoreComposerDraft(_ text: String) {
        taskStore.composerDraftPersistenceTask?.cancel()
        if composerDraftStore.text != text {
            composerDraftStore.text = text
        }
        composerDraftStore.agentMentions = []
        viewModel.saveMessageDraft(text, agentMentions: [], forSessionID: sessionID)
        viewModel.composerResetToken = UUID()
    }

    @ViewBuilder
    private var composerStack: some View {
        let overlaySnapshot = composerOverlaySnapshot
        let modeSnapshot = composerOverlayModeSnapshot(overlaySnapshot: overlaySnapshot, headerSnapshot: chatHeaderSnapshot)

        VStack(spacing: 6) {
            if overlaySnapshot.showsAccessoryArea {
                ComposerAccessoryArea(
                    todos: overlaySnapshot.todos,
                    attachments: overlaySnapshot.attachments,
                    expansion: $composerAccessoryExpansion,
                    onTapTodo: {
                        showingTodoInspector = true
                    },
                    onTapAttachment: { attachment in
                        selectedAttachmentPreview = attachment
                    },
                    onRemoveAttachment: { attachment in
                        viewModel.removeDraftAttachment(attachment)
                    }
                )
                .padding(.horizontal, 16)
            }

            switch modeSnapshot.mode {
            case .permissions:
                PermissionActionStack(
                    permissions: overlaySnapshot.permissions,
                    onDismiss: { permission in
                        viewModel.dismissPermission(permission)
                    },
                    onRespond: { permission, response in
                        Task { await viewModel.respondToPermission(permission, response: response) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            case .questions:
                QuestionPanel(
                    requests: overlaySnapshot.questions,
                    answers: $questionAnswers,
                    customAnswers: $questionCustomAnswers,
                    onDismiss: { request in
                        Task { await viewModel.dismissQuestion(request) }
                    },
                    onSubmit: { request, answers in
                        Task { await viewModel.respondToQuestion(request, answers: answers) }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            case .childSessionNotice:
                childSessionComposerNotice(headerSnapshot: chatHeaderSnapshot)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            case .activeComposer:
                activeMessageComposer(isBusy: isComposerBusy)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func composerOverlayModeSnapshot(
        overlaySnapshot: AppViewModel.ChatComposerOverlaySnapshot,
        headerSnapshot: AppViewModel.ChatSessionHeaderSnapshot
    ) -> ComposerOverlayModeSnapshot {
        if !overlaySnapshot.permissions.isEmpty {
            return ComposerOverlayModeSnapshot(mode: .permissions)
        }
        if !overlaySnapshot.questions.isEmpty {
            return ComposerOverlayModeSnapshot(mode: .questions)
        }
        if headerSnapshot.isChildSession {
            return ComposerOverlayModeSnapshot(mode: .childSessionNotice)
        }
        return ComposerOverlayModeSnapshot(mode: .activeComposer)
    }

    @ViewBuilder
    private func activeMessageComposer(isBusy: Bool) -> some View {
        let composerSnapshot = viewModel.chatComposerSnapshot(for: liveSession, isBusy: isBusy)
        let commands = composerSnapshot.commands
        let mentionableAgents = viewModel.mentionableAgents
        let commandScopeKey = viewModel.currentProjectPreferenceScopeKey
        let pinnedCommands = pinnedCommandStore.pinnedCommands(from: commands, scopeKey: commandScopeKey)
        let pinnedCommandNames = Set(pinnedCommandStore.pinnedNames(for: commandScopeKey))
        let pinnedCommandSignature = [commandScopeKey, pinnedCommands.map(\.name).joined(separator: ",")].joined(separator: "|")
        let mentionableAgentSignature = mentionableAgents.map { "\($0.name):\($0.description ?? "")" }.joined(separator: "|")
        let snapshot = MessageComposerSnapshot(
            isAccessoryMenuOpenValue: isComposerMenuOpen,
            commands: commands,
            attachmentCount: composerSnapshot.attachmentCount,
            isBusy: composerSnapshot.isBusy,
            canFork: composerSnapshot.canFork,
            forkSignature: composerSnapshot.forkSignature,
            mcpSignature: composerSnapshot.mcpSignature,
            pinnedCommandSignature: pinnedCommandSignature,
            mentionableAgentSignature: mentionableAgentSignature,
            actionSignature: composerSnapshot.actionSignature
        )

        let composer = EquatableMessageComposerHost(
            draftStore: composerDraftStore,
            isAccessoryMenuOpen: $isComposerMenuOpen,
            snapshot: snapshot,
            commands: commands,
            mentionableAgents: mentionableAgents,
            pinnedCommands: pinnedCommands,
            pinnedCommandNames: pinnedCommandNames,
            attachmentCount: snapshot.attachmentCount,
            isBusy: composerSnapshot.isBusy,
            canFork: composerSnapshot.canFork,
            forkableMessages: composerSnapshot.forkableMessages,
            mcpServers: composerSnapshot.mcp.servers,
            connectedMCPServerCount: composerSnapshot.mcp.connectedServerCount,
            isLoadingMCP: composerSnapshot.mcp.isLoading,
            togglingMCPServerNames: composerSnapshot.mcp.togglingServerNames,
            mcpErrorMessage: composerSnapshot.mcp.errorMessage,
            actionSignature: snapshot.actionSignature,
            onFocusChange: { isFocused in
                isComposerInputFocused = isFocused
                viewModel.setComposerStreamingFocus(isFocused)
            },
            onTextChange: { text in
                scheduleComposerDraftPersistence(text)
            },
            onAgentMentionsChange: { mentions in
                viewModel.setDraftAgentMentions(mentions, forSessionID: sessionID)
            },
            onHeightChange: { height in
                handleComposerHeightChange(height)
            },
            onSend: {
                startOutgoingBubbleAnimationAndSend()
            },
            onStop: {
                stopComposerAction()
            },
            onSelectCommand: { command in
                viewModel.flushBufferedTranscript(reason: "command action")
                if viewModel.isForkClientCommand(command) {
                    clearComposerDraft()
                    viewModel.presentForkSessionSheet()
                    return
                }
                if viewModel.shouldMeterPrompts(for: sessionID) {
                    guard viewModel.reserveUserPromptIfAllowed() else { return }
                }
                clearComposerDraft()
                Task {
                    if viewModel.isCompactClientCommand(command) {
                        await viewModel.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false, restoreDraftOnFailure: false)
                    } else {
                        await viewModel.sendCommand(command, sessionID: sessionID, userVisible: true, meterPrompt: false, restoreDraftOnFailure: false)
                    }
                }
            },
            onPinCommand: { command in
                withAnimation(opencodeSelectionAnimation) {
                    pinnedCommandStore.pin(command, scopeKey: commandScopeKey)
                }
            },
            onUnpinCommand: { command in
                withAnimation(opencodeSelectionAnimation) {
                    pinnedCommandStore.unpin(command, scopeKey: commandScopeKey)
                }
            },
            onCompact: {
                viewModel.flushBufferedTranscript(reason: "compact menu action")
                if viewModel.shouldMeterPrompts(for: sessionID) {
                    guard viewModel.reserveUserPromptIfAllowed() else { return }
                }
                Task { await viewModel.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false) }
            },
            onForkMessage: { messageID in
                Task { await viewModel.forkSelectedSession(from: messageID) }
            },
            onLoadMCP: {
                Task { await viewModel.loadMCPStatusIfNeeded() }
            },
            onToggleMCP: { name in
                Task { await viewModel.toggleMCPServer(name: name) }
            },
            onAddAttachments: { attachments in
                viewModel.addDraftAttachments(attachments)
            }
        )

        composer
            .equatable()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.clear)
    }

    private func childSessionComposerNotice(headerSnapshot: AppViewModel.ChatSessionHeaderSnapshot) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .font(.headline)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 4) {
                Text("Subagent sessions cannot be prompted.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("Return to the main session to continue the conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button("Back") {
                guard let parentSession = headerSnapshot.parentSession else { return }
                Task { await viewModel.selectSession(parentSession) }
            }
            .buttonStyle(.bordered)
            .tint(.purple)
        }
        .padding(12)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var composerOverlay: some View {
        composerStack
            .background(Color.clear)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            handleComposerHeightChange(proxy.size.height)
                        }
                        .onChange(of: proxy.size.height) { _, height in
                            handleComposerHeightChange(height)
                        }
                }
            }
    }

    private var chatOverlayVisibilitySnapshot: ChatOverlayVisibilitySnapshot {
        if viewModel.pendingForkSessionID == sessionID {
            return ChatOverlayVisibilitySnapshot(visibleOverlay: .forkPreparation)
        }
        if showsDelayedLoadingIndicator {
            return ChatOverlayVisibilitySnapshot(visibleOverlay: .delayedLoading)
        }
        return ChatOverlayVisibilitySnapshot(visibleOverlay: nil)
    }

    private var delayedLoadingOverlay: some View {
        progressOverlay(snapshot: ChatProgressOverlaySnapshot(title: "Loading chat...", accessibilityLabel: "Loading chat"))
    }

    private var forkPreparationOverlay: some View {
        progressOverlay(snapshot: ChatProgressOverlaySnapshot(title: "Preparing fork...", accessibilityLabel: "Preparing fork"))
    }

    private func progressOverlay(snapshot: ChatProgressOverlaySnapshot) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text(snapshot.title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.accessibilityLabel)
    }

    @ViewBuilder
    private var bottomRefreshFloatingIndicator: some View {
        let snapshot = bottomRefreshRenderSnapshot
        if snapshot.showsIndicator {
            VStack {
                Spacer()
                BottomRefreshSpinner(
                    progress: snapshot.progress,
                    isRefreshing: snapshot.isRefreshing,
                    tint: snapshot.colorIsActive ? .blue : .secondary
                )
                .frame(width: 28, height: 28)
                .scaleEffect(0.55 + 0.45 * snapshot.progress)
                .opacity(0.25 + 0.75 * snapshot.progress)
                .padding(.bottom, composerMeasuredHeight + 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .animation(.snappy(duration: 0.18, extraBounce: 0.02), value: snapshot.progress)
            .animation(.easeOut(duration: 0.12), value: snapshot.isRefreshing)
            .transition(.opacity.combined(with: .scale(scale: 0.86)))
        }
    }

    @ViewBuilder
    private var bottomAnchorListItem: some View {
        let snapshot = bottomRefreshRenderSnapshot
        VStack(spacing: 8) {
            if snapshot.showsIndicator {
                bottomRefreshIndicator(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: messageBottomPadding + bottomRefreshIndicatorHeight * snapshot.progress)
        .id(ChatScrollTarget.bottomAnchor)
    }

    private var bottomRefreshRenderSnapshot: BottomRefreshRenderSnapshot {
        let progress = isRefreshingChatData ? 1 : min(1, bottomPullDistance / bottomRefreshThreshold)
        return BottomRefreshRenderSnapshot(
            showsIndicator: isRefreshingChatData || bottomPullDistance > 1,
            progress: progress,
            isRefreshing: isRefreshingChatData,
            colorIsActive: progress >= 1
        )
    }

    private func bottomRefreshIndicator(snapshot: BottomRefreshRenderSnapshot) -> some View {
        BottomRefreshSpinner(
            progress: snapshot.progress,
            isRefreshing: snapshot.isRefreshing,
            tint: snapshot.colorIsActive ? .blue : .secondary
        )
        .frame(width: 28, height: 28)
        .scaleEffect(0.55 + 0.45 * snapshot.progress)
        .opacity(0.25 + 0.75 * snapshot.progress)
        .animation(.snappy(duration: 0.18, extraBounce: 0.02), value: snapshot.progress)
        .animation(.easeOut(duration: 0.12), value: snapshot.isRefreshing)
        .transition(.opacity.combined(with: .scale(scale: 0.86)))
    }

    private var bottomOverscrollRefreshGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if !bottomPullIsTracking {
                    bottomPullIsTracking = true
                    bottomPullStartedAtBottom = isScrollGeometryAtBottom && !isRefreshingChatData
                    hasFiredBottomPullHaptic = false
                }

                guard bottomPullStartedAtBottom else { return }

                let distance = max(0, -value.translation.height)
                bottomPullDistance = distance

                if distance >= bottomRefreshThreshold, !hasFiredBottomPullHaptic {
                    hasFiredBottomPullHaptic = true
                    OpenCodeHaptics.impact(.crisp)
                } else if distance < bottomRefreshThreshold * 0.65 {
                    hasFiredBottomPullHaptic = false
                }
            }
            .onEnded { _ in
                let shouldRefresh = bottomPullStartedAtBottom && bottomPullDistance >= bottomRefreshThreshold && !isRefreshingChatData
                bottomPullIsTracking = false
                bottomPullStartedAtBottom = false
                hasFiredBottomPullHaptic = false

                if shouldRefresh {
                    Task { @MainActor in
                        await refreshChatDataFromBottomOverscroll()
                    }
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0.02)) {
                        bottomPullDistance = 0
                    }
                }
            }
    }

    @MainActor
    private func refreshChatDataFromBottomOverscroll() async {
        guard !isRefreshingChatData else { return }
        withAnimation(.snappy(duration: 0.18, extraBounce: 0.02)) {
            bottomPullDistance = bottomRefreshThreshold
            isRefreshingChatData = true
        }
        defer {
            withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                isRefreshingChatData = false
                bottomPullDistance = 0
            }
        }
        await viewModel.refreshChatData(for: sessionID)
    }

    private func requestBottomReadjustmentIfPinned() {
        guard isScrollGeometryAtBottom else { return }
        requestBottomReadjustment()
    }

    private func requestBottomReadjustment() {
        bottomReadjustmentToken &+= 1
    }

    private func scheduleEagerChatRefresh(reason: String) {
        guard viewModel.isConnected else { return }
        guard viewModel.activeChatSessionID == sessionID || viewModel.selectedSession?.id == sessionID else { return }
        guard shouldRunEagerChatRefresh else { return }

        eagerRefreshTask?.cancel()
        eagerRefreshTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard viewModel.isConnected else { return }
            guard viewModel.activeChatSessionID == sessionID || viewModel.selectedSession?.id == sessionID else { return }

            lastEagerRefreshAt = Date()
            viewModel.appendDebugLog("eager chat refresh session=\(sessionID) reason=\(reason)")
            await viewModel.refreshChatData(for: sessionID)
            requestBottomReadjustmentIfPinned()
        }
    }

    private var shouldRunEagerChatRefresh: Bool {
        guard let lastEagerRefreshAt else { return true }
        return Date().timeIntervalSince(lastEagerRefreshAt) >= eagerRefreshMinimumInterval
    }

    private func scheduleInitialBottomScroll(with proxy: ScrollViewProxy) {
        initialBottomScrollTask?.cancel()
        initialBottomScrollTask = Task { @MainActor in
            for delayMS in [0, 80, 240, 520] {
                if delayMS > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMS))
                } else {
                    await Task.yield()
                }

                guard !Task.isCancelled else { return }
                proxy.scrollTo(ChatScrollTarget.bottomAnchor, anchor: .bottom)
            }
            isScrollGeometryAtBottom = true
        }
    }

    private func scheduleBottomScrollIfPinned(with proxy: ScrollViewProxy) {
        guard isScrollGeometryAtBottom else { return }
        scheduleInitialBottomScroll(with: proxy)
    }

    private func handleComposerHeightChange(_ height: CGFloat) {
        guard height > 0 else { return }
        guard abs(height - composerMeasuredHeight) > 0.5 else { return }
        composerMeasuredHeight = height
        requestBottomReadjustmentIfPinned()
    }

    private func updateDelayedLoadingIndicator() {
        guard delayedLoadingIndicatorSnapshot.shouldDelay else {
            taskStore.delayedLoadingIndicatorTask?.cancel()
            taskStore.delayedLoadingIndicatorTask = nil
            if showsDelayedLoadingIndicator {
                withAnimation(.easeOut(duration: 0.16)) {
                    showsDelayedLoadingIndicator = false
                }
            }
            return
        }

        guard taskStore.delayedLoadingIndicatorTask == nil else { return }
        taskStore.delayedLoadingIndicatorTask = Task { @MainActor in
            defer { taskStore.delayedLoadingIndicatorTask = nil }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, delayedLoadingIndicatorSnapshot.shouldDelay else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showsDelayedLoadingIndicator = true
            }
        }
    }

    private var delayedLoadingIndicatorSnapshot: DelayedLoadingIndicatorSnapshot {
        DelayedLoadingIndicatorSnapshot(
            shouldDelay: viewModel.isLoadingSelectedSession && viewModel.messages.isEmpty && pendingOutgoingSend == nil
        )
    }

#if canImport(UIKit)
    private func keyboardHeight(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return 0 }
        return max(0, UIScreen.main.bounds.maxY - frame.minY)
    }

#endif

    private var messageBottomPadding: CGFloat { 20 }

    private var chatDisplaySnapshot: ChatDisplaySnapshot {
        let messages = Array(viewModel.messages.suffix(visibleMessageCount))
        return ChatDisplaySnapshot(
            messages: messages,
            hiddenMessageCount: max(0, viewModel.messages.count - messages.count),
            items: displayedChatItems(for: messages),
            showsThinking: shouldShowThinking(in: messages)
        )
    }

    private var displayedMessages: [OpenCodeMessageEnvelope] {
        Array(viewModel.messages.suffix(visibleMessageCount))
    }

    private func displayedChatItems(for messages: [OpenCodeMessageEnvelope]) -> [ChatDisplayItem] {
        let messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let key = ChatDisplayItemCacheKey(
            messages: messages.map { message in
                displayItemCacheMessageKey(for: message)
            },
            findPlaceGameID: viewModel.findPlaceGame(for: sessionID)?.city.id,
            findBugGameID: viewModel.findBugGame(for: sessionID)?.language.id
        )

        return chatDisplayItemCache.items(for: key, messagesByID: messagesByID) {
            makeDisplayItems(from: messages)
        }
    }

    private func displayItemCacheMessageKey(for message: OpenCodeMessageEnvelope) -> ChatDisplayItemCacheKey.MessageKey {
        ChatDisplayItemCacheKey.MessageKey(
            id: message.id,
            role: message.info.role,
            parentID: message.info.parentID,
            errorName: message.info.error?.name,
            errorMessage: message.info.error?.displayMessage,
            isStreaming: isStreamingMessage(message),
            isCompactionSummary: message.info.isCompactionSummary,
            parts: message.parts.map(displayItemCachePartKey(for:))
        )
    }

    private func displayItemCachePartKey(for part: OpenCodePart) -> ChatDisplayItemCacheKey.PartKey {
        ChatDisplayItemCacheKey.PartKey(
            id: part.id,
            type: part.type,
            tool: part.tool,
            textCount: part.text?.count ?? 0,
            textSampleHash: sampledTextHash(part.text),
            reason: part.reason,
            filename: part.filename,
            mime: part.mime,
            stateStatus: part.state?.status,
            stateTitle: part.state?.title,
            stateInputSampleHash: sampledTextHash(part.state?.input.map { displayItemCacheInputSignature(from: $0) }),
            stateOutputCount: part.state?.output?.count ?? 0,
            stateOutputSampleHash: sampledTextHash(part.state?.output),
            metadataSessionID: part.state?.metadata?.sessionId,
            metadataFileCount: part.state?.metadata?.files?.count,
            metadataLoadedCount: part.state?.metadata?.loaded?.count,
            metadataTruncated: part.state?.metadata?.truncated
        )
    }

    private func displayItemCacheInputSignature(from input: OpenCodeToolInput) -> String {
        [
            input.command,
            input.description,
            input.filePath,
            input.name,
            input.path,
            input.query,
            input.pattern,
            input.subagentType,
            input.url,
        ]
        .map { $0 ?? "" }
        .joined(separator: "\u{1f}")
    }

    private func sampledTextHash(_ value: String?) -> Int {
        guard let value, !value.isEmpty else { return 0 }
        if value.count <= 512 {
            return value.hashValue
        }

        return "\(value.prefix(160))\u{1f}\(value.suffix(160))".hashValue
    }

    private var accessoryPresenceSignature: AccessoryPresenceState {
        let overlaySnapshot = composerOverlaySnapshot
        return AccessoryPresenceState(
            attachmentIDs: overlaySnapshot.attachmentIDs,
            incompleteTodoIDs: overlaySnapshot.incompleteTodoIDs
        )
    }

    private func dismissComposerOverlays() {
        withAnimation(opencodeSelectionAnimation) {
            composerAccessoryExpansion = .collapsed
            isComposerMenuOpen = false
        }
    }

    private func thinkingRowListItem(isVisible: Bool) -> some View {
        let snapshot = thinkingRowRenderSnapshot
        return ZStack(alignment: .leading) {
            if isVisible {
                ThinkingRow(animateEntry: snapshot.animateEntry)
                    .padding(.horizontal, 16)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isVisible ? 64 : 0, alignment: .center)
        .transition(.identity)
    }

    private var thinkingRowRenderSnapshot: ThinkingRowRenderSnapshot {
        ThinkingRowRenderSnapshot(animateEntry: pendingOutgoingSend != nil)
    }

    private func transcriptRows(for displaySnapshot: ChatDisplaySnapshot) -> [ChatTranscriptRow] {
        var rows: [ChatTranscriptRow] = []
        if isFindPlaceSession {
            rows.append(.weatherAttribution)
        }
        if displaySnapshot.hiddenMessageCount > 0 {
            rows.append(.olderMessages(count: displaySnapshot.hiddenMessageCount))
        }
        rows.append(contentsOf: displaySnapshot.items.map(ChatTranscriptRow.displayItem))
        rows.append(.thinking(isVisible: displaySnapshot.showsThinking))
        rows.append(.bottomAnchor)
        return rows
    }

    private func animatedTranscriptRowIDs(for displaySnapshot: ChatDisplaySnapshot) -> Set<String> {
        guard let lastItem = displaySnapshot.items.last else { return [] }
        return [lastItem.id]
    }

    @ViewBuilder
    private func transcriptRowContent(for row: ChatTranscriptRow) -> some View {
        switch row {
        case .weatherAttribution:
            WeatherAttributionRow()
                .padding(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
        case let .olderMessages(count):
            Button {
                visibleMessageCount = min(viewModel.messages.count, visibleMessageCount + messageWindowSize)
            } label: {
                Text("View older messages (\(count))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(OpenCodePlatformColor.secondaryGroupedBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
        case let .displayItem(item):
            chatRow(for: item)
        case let .thinking(isVisible):
            thinkingRowListItem(isVisible: isVisible)
        case .bottomAnchor:
            bottomAnchorListItem
        }
    }

    @ViewBuilder
    private func chatRow(for item: ChatDisplayItem) -> some View {
        switch item {
        case let .message(message):
            messageRow(for: message)
        case let .largeMessageChunk(item):
            largeMessageChunkRow(for: item)
        case let .compaction(compaction):
            compactionRow(for: compaction)
        case let .findPlaceReveal(city):
            FindPlaceRevealRow(city: city)
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
        case .findBugSolved:
            FindBugSolvedRow()
                .padding(EdgeInsets(top: 8, leading: 16, bottom: 14, trailing: 16))
        }
    }

    private func largeMessageChunkRow(for item: LargeMessageChunkDisplayItem) -> some View {
        let snapshot = largeMessageChunkRowRenderSnapshot(for: item)

        return LargeMessageChunkRow(
            text: snapshot.text,
            allowsTextSelection: snapshot.allowsTextSelection,
            isStreamingTail: snapshot.isStreamingTail,
            animatesStreamingText: snapshot.animatesStreamingText
        )
            .equatable()
            .contextMenu {
                messageChunkContextMenu(for: item.message)
            }
            .transition(.identity)
            .padding(EdgeInsets(top: 0, leading: 16, bottom: snapshot.bottomPadding + snapshot.streamingReservePadding, trailing: 16))
    }

    private func largeMessageChunkRowRenderSnapshot(for item: LargeMessageChunkDisplayItem) -> LargeMessageChunkRowRenderSnapshot {
        let isStreaming = isStreamingMessage(item.message)
        return LargeMessageChunkRowRenderSnapshot(
            text: item.chunk.text,
            allowsTextSelection: !isStreaming,
            isStreamingTail: isStreaming && item.chunk.isTail,
            animatesStreamingText: shouldAnimateStreamingText,
            bottomPadding: item.chunk.isTail ? 6 : 0,
            streamingReservePadding: isStreaming && item.chunk.isTail ? 44 : 0
        )
    }

    @ViewBuilder
    private func messageChunkContextMenu(for message: OpenCodeMessageEnvelope) -> some View {
        Button {} label: {
            Label("Agent: \(message.info.agent?.nilIfEmpty ?? "Default")", systemImage: "person.crop.circle")
        }
        .disabled(true)

        Button {} label: {
            if let model = message.info.model {
                Label("Model: \(model.providerID)/\(model.modelID)", systemImage: "cpu")
            } else {
                Label("Model: Default", systemImage: "cpu")
            }
        }
        .disabled(true)

        Divider()

        Button {
            selectedMessageDebugPayload = MessageDebugPayload(message: message)
        } label: {
            Label("Debug JSON", systemImage: "curlybraces")
        }

        if let copiedText = message.copiedTextContent() {
            Button {
                OpenCodeClipboard.copy(copiedText)
            } label: {
                Label("Copy Message", systemImage: "doc.on.doc")
            }
        }
    }

    private func messageRow(for message: OpenCodeMessageEnvelope) -> some View {
        let snapshot = messageRowRenderSnapshot(for: message)

        return EquatableMessageBubbleHost(
            snapshot: snapshot.bubble,
            resolveTaskSessionID: { part, currentSessionID in
                viewModel.resolveTaskSessionID(from: part, currentSessionID: currentSessionID)
            }
        ) { part in
            selectedActivityDetail = ActivityDetail(message: message, part: part)
        } onOpenTaskSession: { taskSessionID in
            Task { await viewModel.openSession(sessionID: taskSessionID) }
        } onForkMessage: { forkMessage in
            Task { await viewModel.forkSelectedSession(from: forkMessage.id) }
        } onInspectDebugMessage: { debugMessage in
            selectedMessageDebugPayload = MessageDebugPayload(message: debugMessage)
        } onEntryAnimationStarted: { messageID in
            outgoingEntryAnimationStartedMessageIDs.insert(messageID)
        }
        .equatable()
        .transition(.identity)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func messageRowRenderSnapshot(for message: OpenCodeMessageEnvelope) -> MessageRowRenderSnapshot {
        MessageRowRenderSnapshot(
            bubble: messageBubbleSnapshot(for: message),
            transition: messageRowTransition(for: message)
        )
    }

    private func messageBubbleSnapshot(for message: OpenCodeMessageEnvelope) -> MessageBubbleSnapshot {
        MessageBubbleSnapshot(
            message: message,
            detailedMessage: viewModel.toolMessageDetails[message.id],
            currentSessionID: sessionID,
            isStreamingMessage: isStreamingMessage(message),
            animatesStreamingText: shouldAnimateStreamingText,
            hidesReasoningBlocks: viewModel.isFunAndGamesSession(sessionID),
            reserveEntryFromComposer: message.id == preparingOutgoingMessageID,
            animateEntryFromComposer: message.id == animatingOutgoingMessageID && !outgoingEntryAnimationStartedMessageIDs.contains(message.id),
            streamingReservePadding: isStreamingMessage(message) ? 44 : 0
        )
    }

    private func messageRowTransition(for message: OpenCodeMessageEnvelope) -> AnyTransition {
        if message.id == preparingOutgoingMessageID || message.id == animatingOutgoingMessageID {
            return .identity
        }

        if isStreamingMessage(message) {
            return .identity
        }

        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        )
    }

    private func compactionRow(for compaction: CompactionDisplayItem) -> some View {
        let snapshot = compactionRowRenderSnapshot(for: compaction)

        return Button {
            selectedCompactionSummary = compaction.payload
        } label: {
            CompactionBoundaryRow(hasSummary: snapshot.hasSummary, isStreaming: snapshot.isStreaming)
        }
        .buttonStyle(.plain)
        .disabled(snapshot.isDisabled)
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
    }

    private func compactionRowRenderSnapshot(for compaction: CompactionDisplayItem) -> CompactionRowRenderSnapshot {
        let isStreaming = isSessionBusy && compaction.summaryMessage?.info.time?.completed == nil
        let hasSummary = compaction.summaryText != nil
        return CompactionRowRenderSnapshot(
            hasSummary: hasSummary,
            isStreaming: isStreaming,
            isDisabled: !hasSummary || isStreaming
        )
    }

    private func makeDisplayItems(from messages: [OpenCodeMessageEnvelope]) -> [ChatDisplayItem] {
        var result: [ChatDisplayItem] = []
        var displayedIDs: Set<String> = []
        let displayedMessageIDs = Set(messages.map(\.id))
        largeMessageChunkCache.prune(keeping: displayedMessageIDs)
        let findPlaceGame = viewModel.findPlaceGame(for: sessionID)
        let findBugGame = viewModel.findBugGame(for: sessionID)

        func appendUnique(_ item: ChatDisplayItem) {
            guard displayedIDs.insert(item.id).inserted else { return }
            result.append(item)
        }

        for (index, message) in messages.enumerated() {
            if message.containsText(FindPlaceGame.setupMarker) {
                continue
            }

            if message.containsText(FindBugGame.setupMarker) {
                continue
            }

            if message.isAssistantMessage, message.containsText(FindPlaceGame.winMarker), let game = findPlaceGame {
                appendUnique(.findPlaceReveal(game.city))
                continue
            }

            if message.isAssistantMessage, message.containsText(FindBugGame.winMarker), findBugGame != nil {
                appendUnique(.findBugSolved)
                continue
            }

            if message.info.isCompactionSummary {
                continue
            }

            if message.parts.contains(where: \.isCompaction) {
                let summary = compactionSummary(for: message, at: index, in: messages)
                appendUnique(.compaction(CompactionDisplayItem(boundaryMessage: message, summaryMessage: summary)))
                continue
            }

            if let chunks = largeMessageChunkCache.chunks(for: message, isStreaming: isStreamingMessage(message)) {
                for chunk in chunks {
                    appendUnique(.largeMessageChunk(LargeMessageChunkDisplayItem(message: message, chunk: chunk)))
                }
                continue
            }

            appendUnique(.message(message))
        }

        return result
    }

    private func compactionSummary(for boundary: OpenCodeMessageEnvelope, at index: Int, in messages: [OpenCodeMessageEnvelope]) -> OpenCodeMessageEnvelope? {
        if let paired = messages.first(where: { $0.info.isCompactionSummary && $0.info.parentID == boundary.id }) {
            return paired
        }

        return messages.dropFirst(index + 1).first { message in
            message.info.isCompactionSummary
        }
    }

    private func startOutgoingBubbleAnimationAndSend() {
        let rawDraftText = composerDraftStore.text
        let draftText = rawDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftAgentMentions = composerDraftStore.agentMentions
        let draftAttachments = viewModel.draftAttachments
        let hasAttachments = !draftAttachments.isEmpty

        guard !draftText.isEmpty || hasAttachments else { return }
        viewModel.flushBufferedTranscript(reason: "send action")

        if !hasAttachments,
           (viewModel.shouldOpenForkSheet(forSlashInput: draftText) || viewModel.slashCommandInput(from: draftText).map({ viewModel.isForkClientCommand($0.command) }) == true) {
            clearComposerDraft()
            viewModel.presentForkSessionSheet()
            return
        }

        if viewModel.shouldMeterPrompts(for: sessionID) {
            guard viewModel.reserveUserPromptIfAllowed() else { return }
        }

        if !hasAttachments,
           viewModel.slashCommandInput(from: draftText).map({ viewModel.isCompactClientCommand($0.command) }) == true {
            clearComposerDraft()
            Task { await viewModel.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false) }
            return
        }

        OpenCodeHaptics.impact(.strong)
        viewModel.markChatBreadcrumb("send tapped", sessionID: sessionID)

        let messageID = OpenCodeIdentifier.message()
        let partID = OpenCodeIdentifier.part()

        let pendingSend = PendingOutgoingSend(
            text: rawDraftText,
            agentMentions: draftAgentMentions,
            attachments: draftAttachments,
            messageID: messageID,
            partID: partID
        )

        pendingOutgoingSendTask?.cancel()
        isThinkingRowRevealAllowed = false
        preparingOutgoingMessageID = messageID
        let optimisticPrompt = OpenCodeAgentMention.trimmingTextAndMentions(text: rawDraftText, mentions: draftAgentMentions)
        _ = viewModel.insertOptimisticUserMessage(optimisticPrompt.text, agentMentions: optimisticPrompt.mentions, attachments: draftAttachments, in: liveSession, messageID: messageID, partID: partID, animated: false)
        pendingOutgoingSend = pendingSend
        scheduleOutgoingEntryAnimation(messageID: messageID)
        clearComposerDraft()
        viewModel.clearDraftAttachments()
        requestBottomReadjustment()

        pendingOutgoingSendTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(outgoingRequestDelayMS))
            guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID else { return }

            await viewModel.sendMessage(
                pendingSend.text,
                agentMentions: pendingSend.agentMentions,
                attachments: pendingSend.attachments,
                in: liveSession,
                userVisible: true,
                messageID: pendingSend.messageID,
                partID: pendingSend.partID,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
            guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID else { return }
            let optimisticMessageStillVisible = pendingSend.messageID.map { messageID in
                viewModel.messages.contains { $0.id == messageID }
            } ?? true
            if optimisticMessageStillVisible {
                isThinkingRowRevealAllowed = true
                try? await Task.sleep(for: .milliseconds(thinkingRevealHoldMS))
                guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID else { return }
            }
            pendingOutgoingSend = nil
        }
    }

    private func scheduleOutgoingEntryAnimation(messageID: String) {
        outgoingEntryResetTask?.cancel()
        animatingOutgoingMessageID = nil

        outgoingEntryResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            animatingOutgoingMessageID = messageID

            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            animatingOutgoingMessageID = nil
            if preparingOutgoingMessageID == messageID {
                preparingOutgoingMessageID = nil
            }
            outgoingEntryAnimationStartedMessageIDs.remove(messageID)
        }
    }

    private func stopComposerAction() {
        viewModel.flushBufferedTranscript(reason: "stop action")

        if let pendingSend = pendingOutgoingSend {
            pendingOutgoingSendTask?.cancel()
            pendingOutgoingSendTask = nil
            pendingOutgoingSend = nil
            if let messageID = pendingSend.messageID {
                viewModel.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
            }
            outgoingEntryResetTask?.cancel()
            isThinkingRowRevealAllowed = true
            preparingOutgoingMessageID = nil
            animatingOutgoingMessageID = nil
            if let messageID = pendingSend.messageID {
                outgoingEntryAnimationStartedMessageIDs.remove(messageID)
            }
            restoreComposerDraft(pendingSend.text)
            viewModel.addDraftAttachments(pendingSend.attachments)
            return
        }

        Task { await viewModel.stopCurrentSession() }
    }

    private func shouldShowThinking(in messages: [OpenCodeMessageEnvelope]) -> Bool {
        if pendingOutgoingSend != nil {
            return isThinkingRowRevealAllowed
        }

        guard isSessionBusy else { return false }
        guard isThinkingRowRevealAllowed else { return false }
        guard let lastUserIndex = messages.lastIndex(where: { ($0.info.role ?? "").lowercased() == "user" }) else {
            return false
        }

        let assistantTextAfterUser = messages
            .suffix(from: messages.index(after: lastUserIndex))
            .contains { message in
                guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
                return message.parts.contains { part in
                    guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                    return !text.isEmpty
                }
            }

        return !assistantTextAfterUser
    }

    private func isStreamingMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
        guard isSessionBusy else { return false }
        guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
        return displayedMessages.last?.id == message.id
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if viewModel.isUsingAppleIntelligence {
            ToolbarItem(placement: .opencodeLeading) {
                Button("Home") {
                    viewModel.leaveAppleIntelligenceSession()
                }
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    OpenCodeClipboard.copy(appleIntelligenceTranscript())
                    copiedTranscript = true
                } label: {
                    Image(systemName: copiedTranscript ? "checkmark.doc" : "doc.on.doc")
                }
                .accessibilityLabel(copiedTranscript ? "Copied Transcript" : "Copy Transcript")
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    viewModel.isShowingAppleIntelligenceInstructionsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Model Instructions")
            }
        } else {
            let headerSnapshot = chatHeaderSnapshot
            if headerSnapshot.isChildSession {
                ToolbarItem(placement: .opencodeLeading) {
                    if let parentSession = headerSnapshot.parentSession {
                        Button("Back") {
                            Task { await viewModel.selectSession(parentSession) }
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(headerSnapshot.parentTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(headerSnapshot.childTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: 220)
                }
            }

            ToolbarItem(placement: .opencodeTrailing) {
                AgentToolbarMenu(viewModel: viewModel, session: liveSession, glassNamespace: toolbarGlassNamespace)
            }

            #if !os(macOS)
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.flexible, placement: .topBarTrailing)
            }
            #endif

            ToolbarItem(placement: .opencodeTrailing) {
                ModelToolbarMenu(viewModel: viewModel, session: liveSession, glassNamespace: toolbarGlassNamespace)
            }
        }
    }

    private func appleIntelligenceTranscript() -> String {
        viewModel.messages.map { message in
            let role = (message.info.role ?? "assistant").lowercased()
            let text = message.parts
                .compactMap(\.text)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            if !text.isEmpty {
                return "\(role):\n\(text)"
            }

            let partSummary = message.parts.map { part in
                let filename = part.filename ?? part.type
                return "[\(filename)]"
            }.joined(separator: " ")
            return "\(role):\n\(partSummary)"
        }.joined(separator: "\n\n")
    }
}

private struct CompactionBoundaryRow: View {
    let hasSummary: Bool
    let isStreaming: Bool

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)

            HStack(spacing: 8) {
                if isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(isStreaming ? "Compacting session" : "Session compacted")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if hasSummary && !isStreaming {
                    Text("View context")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }

            Rectangle()
                .fill(Color.secondary.opacity(0.22))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(isStreaming ? "Compacting session" : (hasSummary ? "Session compacted. View context." : "Session compacted"))
    }
}

private struct CompactionSummarySheet: View {
    let payload: CompactionSummaryPayload

    @State private var copiedSummary = false

    var body: some View {
        ScrollView {
            MarkdownMessageText(text: payload.summary, isUser: false, style: .standard, isStreaming: false, animatesStreamingText: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(payload.title)
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button(copiedSummary ? "Copied" : "Copy") {
                    OpenCodeClipboard.copy(payload.summary)
                    copiedSummary = true
                }
            }
        }
    }
}

private struct FindPlaceWeatherDebugSheet: View {
    let game: FindPlaceGameSession?

    @State private var copiedDebugText = false

    var body: some View {
        Form {
            if let game {
                Section("City") {
                    labeledValue("Name", "\(game.city.name), \(game.city.country)")
                    labeledValue("Latitude", String(format: "%.4f", game.city.latitude))
                    labeledValue("Longitude", String(format: "%.4f", game.city.longitude))
                }

                if let weather = game.weather {
                    Section("WeatherKit Pull") {
                        labeledValue("Status", weather.didUseWeatherKit ? "Success" : "Fallback")
                        labeledValue("Provider", weather.provider)
                        labeledValue("Requested", weather.requestedAt.formatted(date: .abbreviated, time: .standard))
                        if let errorDomain = weather.errorDomain {
                            labeledValue("Error Domain", errorDomain)
                        }
                        if let errorCode = weather.errorCode {
                            labeledValue("Error Code", String(errorCode))
                        }
                    }

                    Section("Returned Clue") {
                        Text(weather.text)
                            .textSelection(.enabled)
                    }

                    Section("Diagnostic") {
                        Text(weather.errorDescription ?? "WeatherKit request succeeded.")
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Section("WeatherKit Pull") {
                        Text("No weather diagnostic is attached to this session. This can happen for older Find the Place sessions created before diagnostics were recorded.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section("Find the Place") {
                    Text("This chat is not currently recognized as a Find the Place session.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Weather Debug")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button(copiedDebugText ? "Copied" : "Copy") {
                    OpenCodeClipboard.copy(debugText)
                    copiedDebugText = true
                }
                .disabled(debugText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var debugText: String {
        guard let game else { return "" }
        let weather = game.weather
        return [
            "City: \(game.city.name), \(game.city.country)",
            "Coordinates: \(game.city.latitude), \(game.city.longitude)",
            "Status: \(weather?.didUseWeatherKit == true ? "Success" : "Fallback/Unavailable")",
            "Provider: \(weather?.provider ?? "unknown")",
            "Requested: \(weather?.requestedAt.formatted(date: .abbreviated, time: .standard) ?? "unknown")",
            "Error Domain: \(weather?.errorDomain ?? "none")",
            "Error Code: \(weather?.errorCode.map(String.init) ?? "none")",
            "Clue: \(weather?.text ?? "unknown")",
            "Diagnostic: \(weather?.errorDescription ?? "WeatherKit request succeeded.")"
        ].joined(separator: "\n")
    }
}

private struct MessageDebugSheet: View {
    let payload: MessageDebugPayload

    @State private var copiedJSON = false

    var body: some View {
        ScrollView {
            Text(payload.json)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding()
        .navigationTitle("Message JSON")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button(copiedJSON ? "Copied" : "Copy") {
                    OpenCodeClipboard.copy(payload.json)
                    copiedJSON = true
                }
            }
        }
    }
}

private struct AppleIntelligenceInstructionsSheet: View {
    @Binding var userInstructions: String
    @Binding var systemInstructions: String
    @Binding var selectedTab: AppleIntelligenceInstructionTab

    let defaultUserInstructions: String
    let defaultSystemInstructions: String
    let onDone: () -> Void

    var body: some View {
        Form {
            Picker("Prompt", selection: $selectedTab) {
                ForEach(AppleIntelligenceInstructionTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Section(selectedTab.title) {
                TextEditor(text: activeBinding)
                    .frame(minHeight: 280)
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                Text("These prompts apply to the second execution round after intent inference.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear Current Tab", role: .destructive) {
                    activeBinding.wrappedValue = ""
                }

                Button("Reset Current Tab") {
                    switch selectedTab {
                    case .user:
                        userInstructions = defaultUserInstructions
                    case .system:
                        systemInstructions = defaultSystemInstructions
                    }
                }
            }
        }
        .navigationTitle("Model Instructions")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeLeading) {
                Button("Done") {
                    onDone()
                }
            }
        }
        .presentationDetents([.large])
    }

    private var activeBinding: Binding<String> {
        switch selectedTab {
        case .user:
            return $userInstructions
        case .system:
            return $systemInstructions
        }
    }
}

private struct ChatSkeletonRow: View {
    let isLeading: Bool

    var body: some View {
        HStack {
            if isLeading {
                bubble
                Spacer(minLength: 36)
            } else {
                Spacer(minLength: 36)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.9))
                .frame(width: isLeading ? 180 : 150, height: 12)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.9))
                .frame(width: isLeading ? 220 : 190, height: 12)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.7))
                .frame(width: isLeading ? 140 : 110, height: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .redacted(reason: .placeholder)
    }
}

private struct BottomRefreshSpinner: View {
    let progress: CGFloat
    let isRefreshing: Bool
    let tint: Color

    private let tickCount = 12

    var body: some View {
        if isRefreshing {
#if canImport(UIKit)
            UIKitRefreshActivityIndicator(tint: tint)
#else
            ProgressView()
                .controlSize(.small)
#endif
        } else {
            spinner(phase: 0)
        }
    }

    private func spinner(phase: Int) -> some View {
        ZStack {
            ForEach(0 ..< tickCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint.opacity(opacity(for: index, phase: phase)))
                    .frame(width: 2.6, height: 7.0)
                    .offset(y: -8.5)
                    .rotationEffect(.degrees(Double(index) / Double(tickCount) * 360))
            }
        }
    }

    private func opacity(for index: Int, phase: Int) -> Double {
        if isRefreshing {
            let distance = (index - phase + tickCount) % tickCount
            return 0.18 + (1 - Double(distance) / Double(tickCount - 1)) * 0.72
        }

        let visibleTicks = Int(ceil(min(1, max(0, progress)) * CGFloat(tickCount)))
        return index < visibleTicks ? 0.92 : 0.16
    }

}

#if canImport(UIKit)
private struct UIKitRefreshActivityIndicator: UIViewRepresentable {
    let tint: Color

    func makeUIView(context: Context) -> UIActivityIndicatorView {
        let view = UIActivityIndicatorView(style: .medium)
        view.hidesWhenStopped = false
        view.startAnimating()
        return view
    }

    func updateUIView(_ view: UIActivityIndicatorView, context: Context) {
        view.color = UIColor(tint)
        if !view.isAnimating {
            view.startAnimating()
        }
    }
}
#endif

#if canImport(UIKit)
private struct ChatTranscriptCollectionView<RowContent: View>: UIViewRepresentable {
    let rows: [ChatTranscriptRow]
    @Binding var isAtBottom: Bool
    let bottomScrollToken: Int
    let bottomContentInset: CGFloat
    let bottomRefreshThreshold: CGFloat
    let bottomRefreshProgress: CGFloat
    let showsBottomRefreshIndicator: Bool
    let bottomRefreshColorIsActive: Bool
    let bottomRefreshHeight: CGFloat
    let isRefreshing: Bool
    let animatedRowIDs: Set<String>
    let onBottomPullChanged: (CGFloat) -> Void
    let onBottomPullEnded: (Bool) -> Void
    let rowContent: (ChatTranscriptRow) -> RowContent

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            isAtBottom: $isAtBottom,
            bottomRefreshThreshold: bottomRefreshThreshold,
            bottomRefreshProgress: bottomRefreshProgress,
            showsBottomRefreshIndicator: showsBottomRefreshIndicator,
            bottomRefreshColorIsActive: bottomRefreshColorIsActive,
            bottomRefreshHeight: bottomRefreshHeight,
            isRefreshing: isRefreshing,
            animatedRowIDs: animatedRowIDs,
            onBottomPullChanged: onBottomPullChanged,
            onBottomPullEnded: onBottomPullEnded,
            rowContent: rowContent
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(ChatTranscriptHostingCell.self, forCellWithReuseIdentifier: ChatTranscriptHostingCell.reuseIdentifier)
        context.coordinator.collectionView = collectionView
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.rowContent = rowContent
        context.coordinator.isAtBottom = $isAtBottom
        context.coordinator.bottomRefreshThreshold = bottomRefreshThreshold
        context.coordinator.bottomRefreshProgress = bottomRefreshProgress
        context.coordinator.showsBottomRefreshIndicator = showsBottomRefreshIndicator
        context.coordinator.bottomRefreshColorIsActive = bottomRefreshColorIsActive
        context.coordinator.bottomRefreshHeight = bottomRefreshHeight
        context.coordinator.isRefreshing = isRefreshing
        context.coordinator.animatedRowIDs = animatedRowIDs
        context.coordinator.onBottomPullChanged = onBottomPullChanged
        context.coordinator.onBottomPullEnded = onBottomPullEnded
        context.coordinator.updateBottomContentInset(bottomContentInset, in: collectionView)
        context.coordinator.updateRows(rows, in: collectionView)
        context.coordinator.scrollToBottomIfNeeded(token: bottomScrollToken, in: collectionView)
    }

    private static func makeLayout() -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(80)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(80)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 0
        return UICollectionViewCompositionalLayout(section: section)
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate {
        var rows: [ChatTranscriptRow]
        var isAtBottom: Binding<Bool>
        var bottomRefreshThreshold: CGFloat
        var bottomRefreshProgress: CGFloat
        var showsBottomRefreshIndicator: Bool
        var bottomRefreshColorIsActive: Bool
        var bottomRefreshHeight: CGFloat
        var isRefreshing: Bool
        var animatedRowIDs: Set<String>
        var onBottomPullChanged: (CGFloat) -> Void
        var onBottomPullEnded: (Bool) -> Void
        var rowContent: (ChatTranscriptRow) -> RowContent
        weak var collectionView: UICollectionView?

        private var rowIDs: [String]
        private var rowSignaturesByID: [String: String]
        private var pendingRows: [ChatTranscriptRow]?
        private var isThinkingVisible = false
        private var thinkingEntryGeneration = 0
        private var lastBottomScrollToken: Int?
        private var bottomContentInset: CGFloat = 0

        init(
            rows: [ChatTranscriptRow],
            isAtBottom: Binding<Bool>,
            bottomRefreshThreshold: CGFloat,
            bottomRefreshProgress: CGFloat,
            showsBottomRefreshIndicator: Bool,
            bottomRefreshColorIsActive: Bool,
            bottomRefreshHeight: CGFloat,
            isRefreshing: Bool,
            animatedRowIDs: Set<String>,
            onBottomPullChanged: @escaping (CGFloat) -> Void,
            onBottomPullEnded: @escaping (Bool) -> Void,
            rowContent: @escaping (ChatTranscriptRow) -> RowContent
        ) {
            self.rows = rows
            self.isAtBottom = isAtBottom
            self.bottomRefreshThreshold = bottomRefreshThreshold
            self.bottomRefreshProgress = bottomRefreshProgress
            self.showsBottomRefreshIndicator = showsBottomRefreshIndicator
            self.bottomRefreshColorIsActive = bottomRefreshColorIsActive
            self.bottomRefreshHeight = bottomRefreshHeight
            self.isRefreshing = isRefreshing
            self.animatedRowIDs = animatedRowIDs
            self.onBottomPullChanged = onBottomPullChanged
            self.onBottomPullEnded = onBottomPullEnded
            self.rowContent = rowContent
            self.rowIDs = rows.map(\.id)
            self.rowSignaturesByID = Self.signaturesByID(for: rows)
            self.isThinkingVisible = Self.isThinkingVisible(in: rows)
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            rows.count
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatTranscriptHostingCell.reuseIdentifier,
                for: indexPath
            ) as! ChatTranscriptHostingCell
            configure(cell, at: indexPath)
            return cell
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            updateBottomState(for: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func updateRows(_ newRows: [ChatTranscriptRow], in collectionView: UICollectionView) {
            if isUserScrolling(collectionView) {
                pendingRows = newRows
                return
            }

            applyRows(newRows, in: collectionView)
        }

        private func applyRows(_ newRows: [ChatTranscriptRow], in collectionView: UICollectionView) {
            let newIDs = newRows.map(\.id)
            let newSignaturesByID = Self.signaturesByID(for: newRows)
            let newThinkingVisible = Self.isThinkingVisible(in: newRows)
            if !isThinkingVisible, newThinkingVisible {
                thinkingEntryGeneration &+= 1
            }
            isThinkingVisible = newThinkingVisible
            let wasAtBottom = isAtBottom.wrappedValue
            rows = newRows

            if newIDs != rowIDs {
                rowIDs = newIDs
                rowSignaturesByID = newSignaturesByID
                UIView.performWithoutAnimation {
                    collectionView.reloadData()
                }
                if wasAtBottom {
                    scrollToBottom(in: collectionView, animated: false)
                }
                return
            }

            let changedRowIDs = Set(newSignaturesByID.compactMap { id, signature in
                rowSignaturesByID[id] == signature ? nil : id
            })
            rowSignaturesByID = newSignaturesByID

            guard !changedRowIDs.isEmpty else { return }

            configureVisibleHostingCells(in: collectionView, changedRowIDs: changedRowIDs)

            guard wasAtBottom else { return }
            UIView.performWithoutAnimation {
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
            }
            scrollToBottom(in: collectionView, animated: true)
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView, self.isAtBottom.wrappedValue else { return }
                collectionView.layoutIfNeeded()
                self.scrollToBottom(in: collectionView, animated: true)
            }
        }

        func updateBottomContentInset(_ inset: CGFloat, in collectionView: UICollectionView) {
            let inset = max(0, inset)
            guard abs(inset - bottomContentInset) > 0.5 else { return }
            bottomContentInset = inset
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }

        func scrollToBottomIfNeeded(token: Int, in collectionView: UICollectionView) {
            guard lastBottomScrollToken != token else { return }
            lastBottomScrollToken = token
            guard !isUserScrolling(collectionView) else { return }
            scrollToBottom(in: collectionView, animated: false)
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                guard !self.isUserScrolling(collectionView) else { return }
                self.scrollToBottom(in: collectionView, animated: false)
            }
        }

        private func configure(_ cell: ChatTranscriptHostingCell, at indexPath: IndexPath) {
            guard rows.indices.contains(indexPath.item) else { return }
            let row = rows[indexPath.item]
            let allowsAnimations = row.id == ChatScrollTarget.bottomAnchor || row.id == ChatScrollTarget.thinkingRow || animatedRowIDs.contains(row.id)
            let thinkingEntryGeneration: Int? = {
                if case let .thinking(isVisible) = row, isVisible {
                    return self.thinkingEntryGeneration
                }
                return nil
            }()
            cell.configure(
                rowID: row.id,
                renderSignature: row.renderSignature,
                AnyView(rowContent(row)),
                disablesAnimations: !allowsAnimations,
                thinkingEntryGeneration: thinkingEntryGeneration
            )
        }

        private func configureVisibleHostingCells(in collectionView: UICollectionView, changedRowIDs: Set<String>) {
            guard !changedRowIDs.isEmpty else { return }
            for case let cell as ChatTranscriptHostingCell in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell), rows.indices.contains(indexPath.item) else { continue }
                let row = rows[indexPath.item]
                guard changedRowIDs.contains(row.id) else { continue }
                if row.id == ChatScrollTarget.bottomAnchor || row.id == ChatScrollTarget.thinkingRow {
                    configure(cell, at: indexPath)
                } else {
                    UIView.performWithoutAnimation {
                        configure(cell, at: indexPath)
                    }
                }
            }
        }

        private func applyPendingRowsIfNeeded(in scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView, !isUserScrolling(collectionView), let pendingRows else { return }
            self.pendingRows = nil
            applyRows(pendingRows, in: collectionView)
        }

        private func scrollToBottom(in collectionView: UICollectionView, animated: Bool) {
            guard !rows.isEmpty else { return }
            collectionView.layoutIfNeeded()
            let targetY = max(
                -collectionView.adjustedContentInset.top,
                collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
            )
            if animated {
                UIView.animate(
                    withDuration: 0.18,
                    delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
                ) {
                    collectionView.contentOffset.y = targetY
                }
            } else {
                collectionView.contentOffset.y = targetY
            }
            isAtBottom.wrappedValue = true
        }

        private func updateBottomState(for scrollView: UIScrollView) {
            let distanceFromBottom = distanceFromBottom(for: scrollView)
            if isAtBottom.wrappedValue {
                guard distanceFromBottom > 140 else { return }
                isAtBottom.wrappedValue = false
            } else {
                guard distanceFromBottom < 24 else { return }
                isAtBottom.wrappedValue = true
            }
        }

        private func distanceFromBottom(for scrollView: UIScrollView) -> CGFloat {
            max(0, scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y + scrollView.adjustedContentInset.bottom)
        }

        private func isUserScrolling(_ collectionView: UICollectionView) -> Bool {
            collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        }

        private static func signaturesByID(for rows: [ChatTranscriptRow]) -> [String: String] {
            var signatures: [String: String] = [:]
            signatures.reserveCapacity(rows.count)
            for row in rows {
                signatures[row.id] = row.renderSignature
            }
            return signatures
        }

        private static func isThinkingVisible(in rows: [ChatTranscriptRow]) -> Bool {
            rows.contains { row in
                if case let .thinking(isVisible) = row {
                    return isVisible
                }
                return false
            }
        }

    }
}

private final class ChatTranscriptHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatTranscriptHostingCell"

    private var configuredRowID: String?
    private var configuredRenderSignature: String?
    private var configuredDisablesAnimations: Bool?
    private var configuredThinkingEntryGeneration: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(rowID: String, renderSignature: String, _ content: AnyView, disablesAnimations: Bool, thinkingEntryGeneration: Int?) {
        let shouldRunThinkingEntry = thinkingEntryGeneration != nil && configuredThinkingEntryGeneration != thinkingEntryGeneration
        guard configuredRowID != rowID || configuredRenderSignature != renderSignature || configuredDisablesAnimations != disablesAnimations || shouldRunThinkingEntry else {
            return
        }

        configuredRowID = rowID
        configuredRenderSignature = renderSignature
        configuredDisablesAnimations = disablesAnimations
        configuredThinkingEntryGeneration = thinkingEntryGeneration

        if disablesAnimations {
            contentConfiguration = UIHostingConfiguration {
                content
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
            .margins(.all, 0)
        } else {
            contentConfiguration = UIHostingConfiguration {
                content
            }
            .margins(.all, 0)
        }

        if shouldRunThinkingEntry {
            runThinkingEntryAnimation()
        } else if thinkingEntryGeneration == nil {
            contentView.layer.removeAllAnimations()
            contentView.transform = .identity
            contentView.alpha = 1
        }
    }

    private func runThinkingEntryAnimation() {
        contentView.layer.removeAllAnimations()
        contentView.transform = CGAffineTransform(translationX: -96, y: 0).scaledBy(x: 0.97, y: 0.97)
        contentView.alpha = 0.72

        UIView.animate(
            withDuration: 0.34,
            delay: 0.04,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
        ) { [contentView] in
            contentView.transform = .identity
            contentView.alpha = 1
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuredRowID = nil
        configuredRenderSignature = nil
        configuredDisablesAnimations = nil
        configuredThinkingEntryGeneration = nil
        contentView.layer.removeAllAnimations()
        contentView.transform = .identity
        contentView.alpha = 1
        contentConfiguration = nil
    }
}
#else
private struct ChatTranscriptCollectionView<RowContent: View>: View {
    let rows: [ChatTranscriptRow]
    @Binding var isAtBottom: Bool
    let bottomScrollToken: Int
    let bottomContentInset: CGFloat
    let bottomRefreshThreshold: CGFloat
    let bottomRefreshProgress: CGFloat
    let showsBottomRefreshIndicator: Bool
    let bottomRefreshColorIsActive: Bool
    let bottomRefreshHeight: CGFloat
    let isRefreshing: Bool
    let animatedRowIDs: Set<String>
    let onBottomPullChanged: (CGFloat) -> Void
    let onBottomPullEnded: (Bool) -> Void
    let rowContent: (ChatTranscriptRow) -> RowContent

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    rowContent(row)
                }
            }
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func chatDefaultScrollAnchors() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            self
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
#else
        self.defaultScrollAnchor(.bottom)
#endif
    }

    @ViewBuilder
    func chatListDefaultScrollAnchors() -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            self.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            self.defaultScrollAnchor(.bottom)
        }
#else
        self.defaultScrollAnchor(.bottom)
#endif
    }

    @ViewBuilder
    func chatScrollBottomTracking(_ isAtBottom: Binding<Bool>) -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            self.onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentSize.height - geometry.visibleRect.maxY)
            } action: { _, distanceFromBottom in
                if isAtBottom.wrappedValue {
                    guard distanceFromBottom > 140 else { return }
                    isAtBottom.wrappedValue = false
                } else {
                    guard distanceFromBottom < 24 else { return }
                    isAtBottom.wrappedValue = true
                }
            }
        } else {
            self
        }
#else
        self
#endif
    }

    @ViewBuilder
    func chatBottomReadjustment(token: Int) -> some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            self.modifier(ChatBottomReadjustmentModifier(token: token))
        } else {
            self
        }
#else
        self
#endif
    }

    func chatTranscriptListRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

#if os(iOS) || targetEnvironment(macCatalyst)
@available(iOS 18.0, *)
private struct ChatBottomReadjustmentModifier: ViewModifier {
    let token: Int

    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var readjustmentTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollPosition($scrollPosition)
            .onChange(of: token) { _, _ in
                scheduleBottomReadjustment()
            }
            .onDisappear {
                readjustmentTask?.cancel()
                readjustmentTask = nil
            }
    }

    private func scheduleBottomReadjustment() {
        readjustmentTask?.cancel()
        readjustmentTask = Task { @MainActor in
            for delayMS in [0, 80, 220] {
                if delayMS > 0 {
                    try? await Task.sleep(for: .milliseconds(delayMS))
                } else {
                    await Task.yield()
                }

                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
    }
}
#endif
