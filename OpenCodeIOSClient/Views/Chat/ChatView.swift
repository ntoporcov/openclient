import SwiftUI
import MapKit
import Combine
#if canImport(RealityKit) && canImport(UIKit)
import RealityKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private extension ContinuousClock.Instant {
    var chatElapsedMilliseconds: Double {
        let duration = self.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

struct ChatComposerFocusPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private func chatMeasureMS<T>(_ work: () -> T) -> (T, Double) {
    let start = ContinuousClock.now
    let value = work()
    return (value, start.chatElapsedMilliseconds)
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var chatRenderSampleHash: Int {
        if utf16.count <= 512 {
            return hashValue
        }

        return "\(prefix(160))\u{1f}\(suffix(160))".hashValue
    }

    var hasNonWhitespace: Bool {
        contains { !$0.isWhitespace }
    }
}

private extension OpenCodeMessageEnvelope {
    var isAssistantMessage: Bool {
        (info.role ?? "").lowercased() == "assistant"
    }

    var isUnfinishedAssistantMessage: Bool {
        isAssistantMessage && info.time?.completed == nil
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
              let text = part.text,
              text.utf16.count >= minimumCharacterCount,
              text.hasNonWhitespace else {
            return nil
        }

        return text
    }

    static func chunkTextPart(in message: OpenCodeMessageEnvelope) -> OpenCodePart? {
        let textParts = message.parts.filter { part in
            part.type == "text" && part.text?.hasNonWhitespace == true
        }
        guard textParts.count == 1 else { return nil }

        let hasRenderableNonTextPart = message.parts.contains { part in
            guard part.type != "text" else { return false }

            if part.text?.hasNonWhitespace == true {
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
            if lines[index].isBlank {
                guard let nextTableLineIndex = nextTableLineIndex(afterBlankLineAt: index, in: lines) else {
                    break
                }

                while index < nextTableLineIndex {
                    text += lines[index].text
                    index += 1
                }
                continue
            }

            guard isMarkdownTableLine(lines[index].value) || isMarkdownTableSeparatorLine(lines[index].value) else {
                break
            }

            text += lines[index].text
            index += 1
        }

        text += consumeBlankLines(in: lines, index: &index)
        return text
    }

    private static func nextTableLineIndex(afterBlankLineAt index: Int, in lines: [MarkdownLine]) -> Int? {
        var nextIndex = index + 1
        while nextIndex < lines.count, lines[nextIndex].isBlank {
            nextIndex += 1
        }

        guard nextIndex < lines.count,
              isMarkdownTableLine(lines[nextIndex].value) || isMarkdownTableSeparatorLine(lines[nextIndex].value) else {
            return nil
        }

        return nextIndex
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
        var textCharacterCount: Int
        var textUTF16Count: Int
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
            self.textCharacterCount = text.count
            self.textUTF16Count = text.utf16.count
            self.normalizedText = OpenCodeLargeMessageChunker.normalizedText(text)

            let chunks = OpenCodeLargeMessageChunker.makeChunks(fromNormalizedText: normalizedText, startingAt: 0)
            self.frozenChunks = Array(chunks.dropLast())
            self.liveTail = chunks.last?.text ?? ""
        }

        mutating func append(_ suffix: String) {
            guard !suffix.isEmpty else { return }

            let normalizedSuffix = OpenCodeLargeMessageChunker.normalizedText(suffix)
            text += suffix
            textCharacterCount += suffix.count
            textUTF16Count += suffix.utf16.count
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
            let textUTF16Count = text.utf16.count
            if entry.textUTF16Count == textUTF16Count, entry.text == text {
                return entry.result
            }

            if textUTF16Count > entry.textUTF16Count,
               text.hasPrefix(entry.text),
               let suffixStart = text.index(
                text.startIndex,
                offsetBy: entry.textCharacterCount,
                limitedBy: text.endIndex
               ) {
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

    var title: LocalizedStringResource {
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
    let title: LocalizedStringResource
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
    case responseCaption(AssistantResponseTurn)
    case largeMessageChunk(LargeMessageChunkDisplayItem)
    case compaction(CompactionDisplayItem)
    case findPlaceReveal(FindPlaceGameCity)
    case findBugSolved

    var id: String {
        switch self {
        case let .responseCaption(turn):
            return "response-caption-\(turn.id)"
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
    case previousUserContext(OpenCodeMessageEnvelope)
    case olderMessages(count: Int, nextRequestedCount: Int, hasMoreHistory: Bool, isLoading: Bool)
    case displayItem(ChatDisplayItem, recovery: ChatStore.SubmissionRecovery?, recoveryStatusVisible: Bool, entry: ChatOutgoingEntry = ChatOutgoingEntry())
    case thinking(isVisible: Bool, toolName: String?, height: CGFloat)
    case bottomAnchor

    var id: String {
        switch self {
        case .weatherAttribution:
            return "chat-weather-attribution"
        case .previousUserContext:
            return "chat-previous-user-context"
        case .olderMessages:
            return ChatScrollTarget.olderMessagesButton
        case let .displayItem(item, _, _, _):
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
        case let .previousUserContext(message):
            return "\(id):\(message.renderSignature)"
        case let .olderMessages(count, nextRequestedCount, hasMoreHistory, isLoading):
            return "\(id):\(count):\(nextRequestedCount):\(hasMoreHistory):\(isLoading)"
        case let .thinking(isVisible, toolName, height):
            return "\(id):\(isVisible):\(toolName ?? ""):\(height)"
        case .bottomAnchor:
            return id
        case let .displayItem(item, recovery, recoveryStatusVisible, entry):
            return item.renderSignature + (recovery.map { ":\($0.phase):\($0.pendingStatusUnknown):\($0.submittedAt.timeIntervalSinceReferenceDate):\(recoveryStatusVisible)" } ?? ":canonical") + ":entry:\(entry.reserves):\(entry.animates)"
        }
    }
}

struct ChatOutgoingEntry: Equatable {
    var reserves = false
    var animates = false

    static func presentation(messageID: String, preparingID: String?, animatingID: String?, startedIDs: Set<String>) -> Self {
        Self(reserves: messageID == preparingID && !startedIDs.contains(messageID),
             animates: messageID == animatingID && !startedIDs.contains(messageID))
    }
}

enum ChatTranscriptContinuity {
    static func difference(from oldIDs: [String], to newIDs: [String]) -> CollectionDifference<String>? {
        guard Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count else { return nil }
        return newIDs.difference(from: oldIDs)
    }

    static func requestedCount(messages: [OpenCodeMessageEnvelope], additional: Int, initial: Int, fallback: Int) -> Int {
        #if targetEnvironment(macCatalyst)
        return min(messages.count, initial + additional)
        #else
        let base = OpenCodeChatTranscriptWindowing.messageCountIncludingLatestUserRounds(
            1, fallbackMessageCount: fallback, in: messages.map(\.info))
        return min(messages.count, min(base, initial) + additional)
        #endif
    }
}

struct ChatThinkingEntryGate {
    private(set) var waitingMessageID: String?
    private var contextID: String?
    private var cancelled = false

    mutating func begin(messageID: String, contextID: String, alreadyVisible: Bool) {
        self.contextID = contextID
        waitingMessageID = alreadyVisible ? nil : messageID
        cancelled = false
    }

    mutating func release(messageID: String, contextID: String) {
        guard self.contextID == contextID, waitingMessageID == messageID else { return }
        waitingMessageID = nil
    }

    mutating func cancel() {
        guard waitingMessageID != nil else { return }
        waitingMessageID = nil
        cancelled = true
    }

    func reservesTail(in contextID: String) -> Bool {
        self.contextID == contextID && waitingMessageID != nil
    }

    func blocksThinking(in contextID: String) -> Bool {
        self.contextID == contextID && (waitingMessageID != nil || cancelled)
    }
}

enum ChatThinkingPresentation {
    static func shouldShow(messages: [OpenCodeMessageEnvelope], pendingMessageID: String?, isBusy: Bool,
                           showsToolCalls: Bool, showsReasoningBlocks: Bool, runningToolName: String?) -> Bool {
        guard pendingMessageID != nil || isBusy else { return false }
        let userIndex = pendingMessageID.flatMap { id in messages.lastIndex { $0.id == id } }
            ?? messages.lastIndex { $0.info.role?.lowercased() == "user" }
        // An outgoing request can start before its local row or any server message is available.
        if let pendingMessageID, !messages.contains(where: { $0.id == pendingMessageID }) { return true }
        if runningToolName != nil, summaryToolName(messages: messages, pendingMessageID: pendingMessageID,
            isBusy: isBusy, showsToolCalls: showsToolCalls) != nil { return true }
        guard let userIndex else { return false }
        return !messages.suffix(from: messages.index(after: userIndex)).contains { message in
            guard message.info.role?.lowercased() == "assistant" else { return false }
            return MessageBubbleMessageVisibilityPolicy.shouldDisplay(message, showsToolCalls: showsToolCalls,
                showsReasoningBlocks: showsReasoningBlocks)
        }
    }

    static func summaryToolName(messages: [OpenCodeMessageEnvelope], pendingMessageID: String?,
                                isBusy: Bool, showsToolCalls: Bool) -> String? {
        guard isBusy, !showsToolCalls else { return nil }
        // The previous canonical tail can still be running before the new local user row is projected.
        if let pendingMessageID, !messages.contains(where: { $0.id == pendingMessageID }) { return nil }
        guard let message = messages.last,
              message.info.role?.lowercased() == "assistant", message.info.time?.completed == nil else { return nil }
        return OpenCodeToolActivityPolicy.latestRunningToolName(in: message)
    }
}

enum ChatTranscriptTailSpacing {
    static let progressHeight: CGFloat = 64
    static let streamingReserveHeight: CGFloat = 44

    static func height(showsProgress: Bool, hasStreamingMessage: Bool) -> CGFloat {
        if showsProgress { return progressHeight }
        return hasStreamingMessage ? streamingReserveHeight : 0
    }
}

private extension ChatDisplayItem {
    var renderSignature: String {
        switch self {
        case let .responseCaption(turn):
            return "\(id):\(turn.hashValue)"
        case let .message(message):
            return message.renderSignature
        case let .largeMessageChunk(item):
            return item.renderSignature
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
        let samplesText = isUnfinishedAssistantMessage
        return ([id, metadataRenderSignature] + parts.map { $0.renderSignature(samplesText: samplesText) }).joined(separator: "#")
    }

    var metadataRenderSignature: String {
        let completed = info.time?.completed.map { String(describing: $0) } ?? "streaming"
        let providerID = info.model?.providerID ?? info.providerID ?? ""
        let modelID = info.model?.modelID ?? info.modelID ?? ""
        let variant = info.model?.variant ?? ""
        let errorName = info.error?.name ?? ""
        let errorMessage = info.error?.displayMessage ?? ""

        return [
            info.id,
            info.role ?? "",
            info.sessionID ?? "",
            completed,
            info.agent ?? "",
            providerID,
            modelID,
            variant,
            errorName,
            errorMessage
        ]
        .joined(separator: "\u{1f}")
    }
}

private extension OpenCodePart {
    var renderSignature: String {
        renderSignature(samplesText: true)
    }

    func renderSignature(samplesText: Bool) -> String {
        var segments: [String] = []
        segments.reserveCapacity(22)
        segments.append(id ?? "")
        segments.append(messageID ?? "")
        segments.append(sessionID ?? "")
        segments.append(type)
        segments.append(tool ?? "")
        segments.append(callID ?? "")
        segments.append(text?.utf16.count.description ?? "0")
        segments.append(samplesText ? (text?.chatRenderSampleHash.description ?? "0") : "0")
        segments.append(synthetic.map(String.init) ?? "")
        segments.append(reason ?? "")
        segments.append(filename ?? "")
        segments.append(mime ?? "")
        segments.append(url?.utf16.count.description ?? "0")
        segments.append(url?.chatRenderSampleHash.description ?? "0")
        segments.append(state?.status ?? "")
        segments.append(state?.title ?? "")
        if let input = state?.input {
            segments.append(samplesText ? ChatRenderSignatures.inputSignature(from: input).chatRenderSampleHash.description : "0")
        } else {
            segments.append("0")
        }
        segments.append(state?.output?.utf16.count.description ?? "0")
        segments.append(samplesText ? (state?.output?.chatRenderSampleHash.description ?? "0") : "0")
        segments.append(state?.metadata?.sessionId ?? "")
        segments.append(state?.metadata?.files?.count.description ?? "0")
        segments.append(state?.metadata?.loaded?.count.description ?? "0")
        segments.append(state?.metadata?.truncated?.description ?? "false")
        segments.append(state?.metadata?.renderer ?? "")
        segments.append(state?.metadata?.schemaVersion?.description ?? "")
        segments.append(ChatRenderSignatures.jsonSignature(from: state?.metadata?.payload))
        return segments.joined(separator: "\u{1f}")
    }
}

private enum ChatRenderSignatures {
    static func inputSignature(from input: OpenCodeToolInput) -> String {
        var values = [
            input.command,
            input.description,
            input.filePath,
            input.name,
            input.path,
            input.query,
            input.pattern,
            input.subagentType,
            input.url,
            input.clientID,
            input.toolID,
        ]
        .map { $0 ?? "" }
        values.append(jsonSignature(from: input.arguments.map(OpenCodeJSONValue.object)))
        return values.joined(separator: "\u{1f}")
    }

    static func jsonSignature(from value: OpenCodeJSONValue?) -> String {
        guard let value,
              let data = try? sortedJSONEncoder().encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return encoded
    }

    private static func sortedJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension LargeMessageChunkDisplayItem {
    var renderSignature: String {
        let shouldSampleText = chunk.isTail || !message.isUnfinishedAssistantMessage
        return [
            id,
            message.metadataRenderSignature,
            chunk.isTail.description,
            chunk.text.utf16.count.description,
            shouldSampleText ? chunk.text.chatRenderSampleHash.description : "frozen"
        ]
        .joined(separator: ":")
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
        let metadataRenderer: String?
        let metadataSchemaVersion: Int?
        let metadataPayloadHash: Int
    }

    let messages: [MessageKey]
    let findPlaceGameID: String?
    let findBugGameID: String?
    let showsToolCalls: Bool
    let showsReasoningBlocks: Bool
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

    func timedItems(
        for key: ChatDisplayItemCacheKey,
        messagesByID: [String: OpenCodeMessageEnvelope],
        build: () -> [ChatDisplayItem]
    ) -> (items: [ChatDisplayItem], mode: String, elapsedMS: Double) {
        let start = ContinuousClock.now
        if lastKey == key {
            let refreshedItems = lastItems.map { $0.refreshedMessages(using: messagesByID) }
            lastItems = refreshedItems
            return (lastItems, "hit", start.chatElapsedMilliseconds)
        }

        let items = build()
        lastKey = key
        lastItems = items
        return (items, "miss", start.chatElapsedMilliseconds)
    }
}

private extension ChatDisplayItem {
    func refreshedMessages(using messagesByID: [String: OpenCodeMessageEnvelope]) -> ChatDisplayItem {
        switch self {
        case .responseCaption:
            return self
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

enum OpenCodeChatBottomAnchorPolicy {
    static func preservesBottom(isAtBottom: Bool, isUserScrolling: Bool) -> Bool {
        isAtBottom && !isUserScrolling
    }
}

enum OpenCodeChatBottomInsetAnimationPolicy {
    static func shouldAnimate(
        animationToken: Int,
        lastAnimationToken: Int,
        preservesBottom: Bool
    ) -> Bool {
        preservesBottom && animationToken != lastAnimationToken
    }
}

struct ChatKeyboardTransition: Equatable {
    let duration: TimeInterval
    let curve: UInt
    let receivedAt: TimeInterval

    func remainingDuration(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, min(duration, receivedAt + duration - time))
    }

#if canImport(UIKit)
    var animationOptions: UIView.AnimationOptions {
        [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
    }

    init(notification: Notification) {
        duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        receivedAt = ProcessInfo.processInfo.systemUptime
    }
#endif

    init(duration: TimeInterval, curve: UInt, receivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.duration = duration
        self.curve = curve
        self.receivedAt = receivedAt
    }
}

private final class ChatTranscriptScrollController {
#if canImport(UIKit)
    @MainActor private weak var collectionView: UICollectionView?
    @MainActor private var bottomChaseTask: Task<Void, Never>?

    @MainActor
    func attach(_ collectionView: UICollectionView) {
        self.collectionView = collectionView
    }

    @MainActor
    @discardableResult
    func scrollToBottom(animated: Bool) -> Bool {
        guard let collectionView else { return false }
        bottomChaseTask?.cancel()
        let didScroll = Self.scrollToBottom(in: collectionView, animated: animated, interruptsCurrentScroll: true)
        if didScroll {
            scheduleBottomChase(animated: animated)
        }
        return didScroll
    }

    @MainActor
    @discardableResult
    static func scrollToBottom(
        in collectionView: UICollectionView,
        animated: Bool,
        interruptsCurrentScroll: Bool,
        performsLayout: Bool = true
    ) -> Bool {
        if performsLayout {
            collectionView.layoutIfNeeded()
        }
        guard collectionView.bounds.height > 0 else { return false }

        let targetY = bottomTargetY(in: collectionView)
        guard isStableBottomTarget(targetY, in: collectionView) else { return false }

        let targetOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)

        if interruptsCurrentScroll {
            interruptCurrentScroll(in: collectionView)
        }

        collectionView.setContentOffset(targetOffset, animated: animated)
        return true
    }

    @MainActor
    private func scheduleBottomChase(animated: Bool) {
        bottomChaseTask = Task { @MainActor [weak self] in
            defer { self?.bottomChaseTask = nil }
            for delay in [90, 180, 320, 520, 800, 1_200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let collectionView = self?.collectionView else { return }
                collectionView.layoutIfNeeded()
                guard Self.distanceFromBottom(in: collectionView) > 3 else { return }
                Self.scrollToBottom(
                    in: collectionView,
                    animated: animated,
                    interruptsCurrentScroll: false,
                    performsLayout: false
                )
            }
        }
    }

    @MainActor
    private static func bottomTargetY(in collectionView: UICollectionView) -> CGFloat {
        max(
            -collectionView.adjustedContentInset.top,
            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom
        )
    }

    @MainActor
    private static func distanceFromBottom(in collectionView: UICollectionView) -> CGFloat {
        max(0, bottomTargetY(in: collectionView) - collectionView.contentOffset.y)
    }

    @MainActor
    private static func isStableBottomTarget(_ targetY: CGFloat, in collectionView: UICollectionView) -> Bool {
        let currentY = collectionView.contentOffset.y
        let topY = -collectionView.adjustedContentInset.top
        guard currentY > topY + 80 else { return true }

        let allowedUpwardCorrection = max(96, collectionView.bounds.height * 0.25)
        return targetY >= currentY - allowedUpwardCorrection
    }

    @MainActor
    private static func interruptCurrentScroll(in collectionView: UICollectionView) {
        collectionView.layer.removeAllAnimations()
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)

        guard collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating else { return }
        let wasScrollEnabled = collectionView.isScrollEnabled
        collectionView.isScrollEnabled = false
        collectionView.isScrollEnabled = wasScrollEnabled
    }
#else
    @discardableResult
    func scrollToBottom(animated: Bool) -> Bool { false }
#endif
}

private struct PendingOutgoingSend {
    let session: OpenCodeSession
    let contextID: String
    let text: String
    let agentMentions: [OpenCodeAgentMention]
    let attachments: [OpenCodeComposerAttachment]
    let messageID: String?
    let partID: String?
    let reservedPromptDay: String?
}

private struct LargeMessageChunkRow: View, Equatable {
    let text: String
    let allowsTextSelection: Bool
    let isStreamingTail: Bool
    let animatesStreamingText: Bool
    let streamingAnimationID: String
    let tableMaximumWidth: CGFloat?

    var body: some View {
#if canImport(UIKit)
        content
#else
        if allowsTextSelection {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
#endif
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            MarkdownMessageText(
                text: text,
                isUser: false,
                style: .standard,
                isStreaming: isStreamingTail,
                animatesStreamingText: animatesStreamingText,
                streamingAnimationID: streamingAnimationID,
                tableMaximumWidth: tableMaximumWidth
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
    var contextMetricsTask: Task<Void, Never>?
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
    let contextSnapshot: OpenCodeSessionContextSnapshot?
    let conversationState: ConversationModeController.State
    let conversationInputLevel: CGFloat
    let blocksNewInput: Bool
    let prefersAssistantLayout: Bool
    let toolbarSnapshot: ChatFacade.ToolbarSnapshot
}

private struct MessageBubbleSnapshot: Equatable {
    let message: OpenCodeMessageEnvelope
    let detailedMessage: OpenCodeMessageEnvelope?
    let currentSessionID: String?
    let isStreamingMessage: Bool
    let animatesStreamingText: Bool
    let showsToolCalls: Bool
    let hidesReasoningBlocks: Bool
    let reserveEntryFromComposer: Bool
    let animateEntryFromComposer: Bool
    let expandedReasoningPartIDs: Set<String>
    let expandedContextGroupIDs: Set<String>
    let showsAllActivity: Bool
    let tableMaximumWidth: CGFloat?
    let allowsForkMessage: Bool
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
    let streamingAnimationID: String
    let bottomPadding: CGFloat
    let tableMaximumWidth: CGFloat?
}

private struct ThinkingRowRenderSnapshot {
    let animateEntry: Bool
    let toolName: String?
}

private struct BottomRefreshRenderSnapshot {
    let showsIndicator: Bool
    let progress: CGFloat
    let isRefreshing: Bool
    let colorIsActive: Bool
}

private struct ChatProgressOverlaySnapshot {
    let title: LocalizedStringResource
    let accessibilityLabel: LocalizedStringResource
}

private enum ChatOverlayKind {
    case forkPreparation
    case delayedLoading
}

private struct ChatOverlayVisibilitySnapshot {
    let visibleOverlay: ChatOverlayKind?
}

private struct ChatFocusedActionsModifier: ViewModifier {
    let stopAction: (() -> Void)?
    let switchSessionAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusedSceneValue(\.stopCurrentChat, stopAction)
            .focusedSceneValue(\.switchToRecentlyOpenedSession, switchSessionAction)
    }
}

private struct OpenClientSessionSwitcherOverlay: View {
    let presentation: OpenClientSessionSwitcherPresentation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(presentation.sessions) { session in
                        let isSelected = session.id == presentation.selectedSessionID
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            Text(session.displayTitle(fallback: String(localized: "Session")))
                                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(minHeight: 44)
                        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .id(session.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: presentation.selectedSessionID, initial: true) { _, id in
                proxy.scrollTo(id, anchor: .center)
            }
        }
        .frame(maxWidth: 360)
        .frame(height: min(360, CGFloat(presentation.sessions.count) * 56 + 20))
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .allowsHitTesting(false)
    }
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

private struct CachedChatReadOnlyComposerNotice: View {
    var body: some View {
        Label("Downloaded chat is read-only while the server is unavailable", systemImage: "externaldrive.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("chat.cache-read-only")
    }
}

private struct ChatDisplaySnapshot {
    let messages: [OpenCodeMessageEnvelope]
    let hiddenMessageCount: Int
    let nextRequestedMessageCount: Int
    let hasMoreHistory: Bool
    let isLoadingHistory: Bool
    let previousUserMessage: OpenCodeMessageEnvelope?
    let items: [ChatDisplayItem]
    let showsThinking: Bool
    let thinkingToolName: String?
    let tailHeight: CGFloat

    var itemIDs: [String] {
        items.map(\.id) + (showsThinking ? [ChatScrollTarget.thinkingRow] : [])
    }
}

private struct TimedChatDisplaySnapshot {
    let snapshot: ChatDisplaySnapshot
}

enum ChatPreviousUserContextPolicy {
    static func displayText(for message: OpenCodeMessageEnvelope) -> String {
        if let text = textPart(in: message, includesSynthetic: false) {
            return text
        }
        if let text = textPart(in: message, includesSynthetic: true) {
            return text
        }

        let attachmentCount = message.parts.lazy.filter { $0.type == "file" }.count
        if attachmentCount == 1 { return String(localized: "Sent an attachment") }
        if attachmentCount > 1 { return String(localized: "Sent \(attachmentCount) attachments") }
        return String(localized: "Previous user message")
    }

    private static func textPart(
        in message: OpenCodeMessageEnvelope,
        includesSynthetic: Bool
    ) -> String? {
        message.parts.first(where: {
            $0.type == "text"
                && (includesSynthetic || $0.synthetic != true)
                && $0.text?.hasNonWhitespace == true
        })?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct OpenCodeChatTranscriptWindow: Equatable {
    let messages: [OpenCodeMessageEnvelope]
    let hiddenMessageCount: Int
    var nextRequestedMessageCount: Int = 0

    static func showsHistoryControl(hiddenMessageCount: Int, hasMoreHistory: Bool) -> Bool {
        hiddenMessageCount > 0 || hasMoreHistory
    }
}

enum OpenCodeChatTranscriptWindowing {
    static func messageCountIncludingLatestUserRounds(
        _ roundCount: Int,
        fallbackMessageCount: Int,
        in messages: [OpenCodeMessage]
    ) -> Int {
        guard !messages.isEmpty else { return 0 }
        guard roundCount > 0 else { return min(messages.count, max(0, fallbackMessageCount)) }

        var remainingRounds = roundCount
        var oldestUserIndex: Int?
        for index in messages.indices.reversed() where (messages[index].role ?? "").lowercased() == "user" {
            oldestUserIndex = index
            remainingRounds -= 1
            if remainingRounds == 0 {
                return messages.count - index
            }
        }

        if let oldestUserIndex {
            return messages.count - oldestUserIndex
        }
        return min(messages.count, max(0, fallbackMessageCount))
    }

    static func window(
        from messages: [OpenCodeMessageEnvelope],
        requestedCount: Int,
        batchSize: Int,
        hasDisplayableContent: ([OpenCodeMessageEnvelope]) -> Bool
    ) -> OpenCodeChatTranscriptWindow {
        let messageIDs = Set(messages.map(\.id))
        return window(
            totalCount: messages.count,
            requestedCount: requestedCount,
            batchSize: batchSize,
            loadSuffix: { Array(messages.suffix($0)) },
            containsMessageID: { messageIDs.contains($0) },
            hasDisplayableContent: hasDisplayableContent
        )
    }

    static func window(
        totalCount: Int,
        requestedCount: Int,
        batchSize: Int,
        loadSuffix: (Int) -> [OpenCodeMessageEnvelope],
        containsMessageID _: (String) -> Bool,
        hasDisplayableMessage: ((OpenCodeMessageEnvelope) -> Bool)? = nil,
        hasDisplayableContent: ([OpenCodeMessageEnvelope]) -> Bool
    ) -> OpenCodeChatTranscriptWindow {
        guard totalCount > 0 else {
            return OpenCodeChatTranscriptWindow(messages: [], hiddenMessageCount: 0)
        }

        let minimumBatchSize = max(1, batchSize)
        var count = min(totalCount, max(requestedCount, minimumBatchSize))
        var window = loadSuffix(count)

        while count < totalCount, !hasDisplayableContent(window) {
            count = min(totalCount, count + minimumBatchSize)
            window = loadSuffix(count)
        }

        let hiddenRawCount = max(0, totalCount - window.count)
        let hiddenMessages: ArraySlice<OpenCodeMessageEnvelope> = hiddenRawCount > 0
            ? loadSuffix(totalCount).prefix(hiddenRawCount) : []
        let displayableIndices = hiddenMessages.indices.filter {
            hasDisplayableMessage?(hiddenMessages[$0]) ?? hasDisplayableContent([hiddenMessages[$0]])
        }
        // Keep the existing batch size, but skip empty batches so every reveal exposes a row.
        var nextCount = min(totalCount, window.count + minimumBatchSize)
        if let newestHiddenIndex = displayableIndices.last {
            nextCount = max(nextCount, totalCount - newestHiddenIndex)
        }
        return OpenCodeChatTranscriptWindow(
            messages: window,
            hiddenMessageCount: displayableIndices.count,
            nextRequestedMessageCount: nextCount
        )
    }

}

private struct EquatableMessageBubbleHost: View, Equatable {
    let snapshot: MessageBubbleSnapshot
    let imageContent: OpenClientImageContentCoordinator?
    let imageLoadingStore: OpenClientImageLoadingStore
    let videoStreams: OpenClientVideoStreamCoordinator?
    let videoPlaybackStore: OpenClientVideoPlaybackStore
    let resolveTaskSessionID: (OpenCodePart, String) -> String?
    let onSelectPart: (OpenCodePart) -> Void
    let onOpenTaskSession: (String) -> Void
    let onForkMessage: (OpenCodeMessageEnvelope) -> Void
    let onInspectDebugMessage: (OpenCodeMessageEnvelope) -> Void
    let onEntryAnimationStarted: (String) -> Void
    let onEntryAnimationCompleted: (String) -> Void
    let onEntryAnimationCancelled: (String) -> Void
    let onToggleReasoningPart: (String) -> Void
    let onToggleContextGroup: (String) -> Void
    let onShowEarlierActivity: () -> Void
    let onOpenVisualHTML: (OpenClientVisualHTMLPayload) -> Void
    let onAnswerTextTap: () -> Void

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
            showsToolCalls: snapshot.showsToolCalls,
            hidesReasoningBlocks: snapshot.hidesReasoningBlocks,
            reserveEntryFromComposer: snapshot.reserveEntryFromComposer,
            animateEntryFromComposer: snapshot.animateEntryFromComposer,
            expandedReasoningPartIDs: snapshot.expandedReasoningPartIDs,
            expandedContextGroupIDs: snapshot.expandedContextGroupIDs,
            showsAllActivity: snapshot.showsAllActivity,
            tableMaximumWidth: snapshot.tableMaximumWidth,
            allowsForkMessage: snapshot.allowsForkMessage,
            resolveTaskSessionID: resolveTaskSessionID,
            onSelectPart: onSelectPart,
            onOpenTaskSession: onOpenTaskSession,
            onForkMessage: onForkMessage,
            onInspectDebugMessage: onInspectDebugMessage,
            onEntryAnimationStarted: onEntryAnimationStarted,
            onToggleReasoningPart: onToggleReasoningPart,
            onToggleContextGroup: onToggleContextGroup,
            onShowEarlierActivity: onShowEarlierActivity,
            onOpenVisualHTML: onOpenVisualHTML,
            imageContent: imageContent,
            imageLoadingStore: imageLoadingStore,
            videoStreams: videoStreams,
            videoPlaybackStore: videoPlaybackStore,
            onAnswerTextTap: onAnswerTextTap,
            onEntryAnimationCompleted: onEntryAnimationCompleted,
            onEntryAnimationCancelled: onEntryAnimationCancelled
        )
    }
}

private struct ChatTranscriptPane<RowContent: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var syncStore: DirectorySyncStore
    @Binding var isScrollGeometryAtBottom: Bool
    @Binding var chatViewportHeight: CGFloat
    @Binding var chatViewportWidth: CGFloat

    let scrollController: ChatTranscriptScrollController
    let bottomReadjustmentToken: Int
    let animatedBottomScrollToken: Int
    let composerMeasuredHeight: CGFloat
    let keyboardMeasuredHeight: CGFloat
    let keyboardTransition: ChatKeyboardTransition?
    let bottomContentInsetAnimationToken: Int
    let messageBottomPadding: CGFloat
    let bottomRefreshThreshold: CGFloat
    let bottomRefreshIndicatorHeight: CGFloat
    let bottomRefreshRenderSnapshot: BottomRefreshRenderSnapshot
    let isRefreshingChatData: Bool
    let isSessionBusy: Bool
    let isInitialHydration: Bool
    let isLoadingPresentation: Bool
    let contentInvalidationToken: String
    let makeDisplaySnapshot: () -> TimedChatDisplaySnapshot
    let makeRows: (ChatDisplaySnapshot) -> [ChatTranscriptRow]
    let makeAnimatedRowIDs: (ChatDisplaySnapshot) -> Set<String>
    let onBottomPullChanged: (CGFloat) -> Void
    let onBottomPullEnded: (Bool) -> Void
    let onAppear: (CGFloat) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onSlowSnapshot: (String) -> Void
    let rowContent: (ChatTranscriptRow) -> RowContent

    var body: some View {
        let _ = syncStore.version
        GeometryReader { geometry in
            let timedDisplaySnapshot = makeDisplaySnapshot()
            let displaySnapshot = timedDisplaySnapshot.snapshot
            let rows = makeRows(displaySnapshot)
            let animatedRowIDs = makeAnimatedRowIDs(displaySnapshot)

            ChatTranscriptCollectionView(
                rows: rows,
                isAtBottom: $isScrollGeometryAtBottom,
                scrollController: scrollController,
                bottomScrollToken: bottomReadjustmentToken,
                animatedBottomScrollToken: animatedBottomScrollToken,
                bottomContentInset: composerMeasuredHeight + keyboardMeasuredHeight + messageBottomPadding,
                bottomContentInsetAnimationToken: bottomContentInsetAnimationToken,
                keyboardHeight: keyboardMeasuredHeight,
                keyboardTransition: keyboardTransition,
                bottomRefreshThreshold: bottomRefreshThreshold,
                bottomRefreshProgress: bottomRefreshRenderSnapshot.progress,
                showsBottomRefreshIndicator: bottomRefreshRenderSnapshot.showsIndicator,
                bottomRefreshColorIsActive: bottomRefreshRenderSnapshot.colorIsActive,
                bottomRefreshHeight: messageBottomPadding + bottomRefreshIndicatorHeight * bottomRefreshRenderSnapshot.progress,
                isRefreshing: isRefreshingChatData,
                isStreaming: isSessionBusy || isInitialHydration,
                hasInitialContent: !displaySnapshot.messages.isEmpty || !isLoadingPresentation,
                contentInvalidationToken: contentInvalidationToken,
                animatedRowIDs: animatedRowIDs,
                onBottomPullChanged: onBottomPullChanged,
                onBottomPullEnded: onBottomPullEnded,
                rowContent: rowContent
            )
            .background(OpenCodePlatformColor.chatCanvasBackground(for: colorScheme))
            .opencodeSoftScrollEdgeEffect()
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .accessibilityIdentifier("chat.scroll")
            .onAppear {
                chatViewportHeight = geometry.size.height
                chatViewportWidth = geometry.size.width
                onAppear(geometry.size.height)
            }
            .onChange(of: geometry.size.height) { _, height in
                chatViewportHeight = height
                onHeightChange(height)
            }
            .onChange(of: geometry.size.width) { _, width in
                chatViewportWidth = width
            }
        }
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
    let onOpenBrowser: (() -> Void)?
    let glassNamespace: Namespace.ID
    var agentTitle: String = ""
    var selectableAgents: [OpenCodeAgent] = []
    var modelTitle: String = ""
    var modelReference: OpenCodeModelReference?
    var modelProviderName: String?
    var providerGroups: [ChatFacade.ToolbarProviderGroup] = []
    var reasoningVariants: [ChatFacade.ToolbarReasoningVariant] = []
    var reasoningTitle: String = ""
    var onSelectAgent: ((String) -> Void)?
    var onSelectModel: ((OpenCodeModelReference) -> Void)?
    var onSelectReasoningVariant: ((String?) -> Void)?
    var onShowContextMetrics: (() -> Void)?
    var conversationState: ConversationModeController.State = .inactive
    var conversationInputLevel: CGFloat = 0
    var onToggleConversation: (() -> Void)?

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
            onAddAttachments: onAddAttachments,
            onOpenBrowser: onOpenBrowser,
            glassNamespace: glassNamespace,
            blocksNewInput: snapshot.blocksNewInput,
            agentTitle: agentTitle,
            selectableAgents: selectableAgents,
            modelTitle: modelTitle,
            modelReference: modelReference,
            modelProviderName: modelProviderName,
            providerGroups: providerGroups,
            reasoningVariants: reasoningVariants,
            reasoningTitle: reasoningTitle,
            contextSnapshot: snapshot.contextSnapshot,
            onSelectAgent: onSelectAgent,
            onSelectModel: onSelectModel,
            onSelectReasoningVariant: onSelectReasoningVariant,
            onShowContextMetrics: onShowContextMetrics,
            conversationState: conversationState,
            conversationInputLevel: conversationInputLevel,
            onToggleConversation: onToggleConversation,
            prefersAssistantLayout: snapshot.prefersAssistantLayout
        )
    }
}

struct ChatView: View {
    @Environment(\.scenePhase) private var scenePhase
#if os(iOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
#endif

    @ObservedObject private var connectionStore: ConnectionStore
    @ObservedObject private var projectStore: ProjectStore
    @ObservedObject private var directoryStore: DirectoryStore
    @ObservedObject private var sessionListStore: SessionListStore
    @ObservedObject private var chatStore: ChatStore
    @ObservedObject private var appCustomizationStore: AppCustomizationStore
    @ObservedObject private var chatFacade: ChatFacade
    @ObservedObject private var sessionInteractionStore: SessionInteractionStore
    @ObservedObject private var composerStore: ComposerStore
    @ObservedObject private var modelConfigurationStore: ModelConfigurationStore
    @ObservedObject private var mcpStore: MCPStore
    @ObservedObject private var funAndGamesStore: FunAndGamesStore
    @ObservedObject private var chatPresentationStore: ChatPresentationStore
    @ObservedObject private var browser: BrowserStore
    private let imageContent: OpenClientImageContentCoordinator?
    private let videoStreams: OpenClientVideoStreamCoordinator?
    let sessionID: String
    let presentationRequest: Int
    private let onDismissChildSession: (() -> Void)?
    private let isDedicatedWindow: Bool

    @MainActor
    init(
        chatFacade: ChatFacade,
        browser: BrowserStore,
        imageContent: OpenClientImageContentCoordinator? = nil,
        videoStreams: OpenClientVideoStreamCoordinator? = nil,
        sessionID: String,
        presentationRequest: Int = 0,
        onDismissChildSession: (() -> Void)? = nil,
        preferredDirectoryKey: String? = nil,
        isDedicatedWindow: Bool = false
    ) {
        _connectionStore = ObservedObject(wrappedValue: chatFacade.connectionStore)
        _projectStore = ObservedObject(wrappedValue: chatFacade.projectStore)
        _directoryStore = ObservedObject(
            wrappedValue: chatFacade.directoryStore(
                forSessionID: sessionID,
                preferredDirectoryKey: preferredDirectoryKey
            )
        )
        _sessionListStore = ObservedObject(wrappedValue: chatFacade.sessionListStore)
        _chatStore = ObservedObject(wrappedValue: chatFacade.chatStore)
        _appCustomizationStore = ObservedObject(wrappedValue: chatFacade.appCustomizationStore)
        _conversationController = StateObject(
            wrappedValue: ConversationModeController(voiceStore: chatFacade.speechVoiceStore)
        )
        self.chatFacade = chatFacade
        _sessionInteractionStore = ObservedObject(wrappedValue: chatFacade.sessionInteractionStore)
        _composerStore = ObservedObject(wrappedValue: chatFacade.composerStore)
        _modelConfigurationStore = ObservedObject(wrappedValue: chatFacade.modelConfigurationStore)
        _mcpStore = ObservedObject(wrappedValue: chatFacade.mcpStore)
        _funAndGamesStore = ObservedObject(wrappedValue: chatFacade.funAndGamesStore)
        _chatPresentationStore = ObservedObject(wrappedValue: chatFacade.chatPresentationStore)
        _browser = ObservedObject(wrappedValue: browser)
        self.imageContent = imageContent
        self.videoStreams = videoStreams
        self.sessionID = sessionID
        self.presentationRequest = presentationRequest
        self.onDismissChildSession = onDismissChildSession
        self.isDedicatedWindow = isDedicatedWindow
    }

    @Namespace private var toolbarGlassNamespace
    @Namespace private var composerGlassNamespace
    // Keep the popover's anchor in place while its settings change the composer layout.
    @State private var pinnedHeaderUsesAssistantLayout: Bool?
    @State private var copiedDebugLog = false
    @State private var selectedMessageDebugPayload: MessageDebugPayload?
    @State private var selectedCompactionSummary: CompactionSummaryPayload?
    @State private var selectedActivityDetail: ActivityDetail?
    @State private var presentedTaskSession: OpenCodeSession?
    @State private var presentedTaskChat: ChatFacade?
    @State private var taskSessionDetent: PresentationDetent = .medium
    @State private var showingTodoInspector = false
    @State private var showingContextMetrics = false
    @State private var additionalLeadingMessageCount = 0
    @State private var questionAnswers: [String: Set<String>] = [:]
    @State private var questionCustomAnswers: [String: String] = [:]
    @State private var taskStore = ChatViewTaskStore()
    @State private var composerDraftStore = MessageComposerDraftStore()
    @State private var v2DraftRevision: UInt = 0
    @State private var v2DraftAttemptID: String?
    @State private var v2RetryDraft: OpenCodeV2RetryDraft?
    @State private var promptDraftRevision: UInt = 0
    @State private var promptRetryDraft: OpenCodeV2RetryDraft?
    @StateObject private var pinnedCommandStore = PinnedCommandStore()
    @StateObject private var conversationController: ConversationModeController
    @State private var conversationContextID: String?
    @State private var isComposerInputFocused = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var selectedVisualHTML: OpenClientVisualHTMLPresentation?
    @State private var isComposerMenuOpen = false
    @State private var copiedTranscript = false
    @State private var pendingOutgoingSend: PendingOutgoingSend?
    @State private var visibleRecoveryStatusIDs: Set<String> = []
    @State private var pendingOutgoingSendTask: Task<Void, Never>?
    @State private var hasSubmittedPendingOutgoingSend = false
    @State private var outgoingEntryResetTask: Task<Void, Never>?
    @State private var initialBottomScrollTask: Task<Void, Never>?
    @State private var eagerRefreshTask: Task<Void, Never>?
    @State private var lastEagerRefreshAt: Date?
    @State private var preparingOutgoingMessageID: String?
    @State private var animatingOutgoingMessageID: String?
    @State private var outgoingEntryAnimationStartedMessageIDs: Set<String> = []
    @State private var thinkingEntryGate = ChatThinkingEntryGate()
    @State private var expandedReasoningPartIDs: Set<String> = []
    @State private var expandedContextGroupIDs: Set<String> = []
    @State private var expandedEarlierActivityMessageIDs: Set<String> = []
    @State private var hasCompletedInitialHydrationSnap = false
    @State private var isScrollGeometryAtBottom = true
    @State private var isRefreshingChatData = false
    @State private var showsDelayedLoadingIndicator = false
    @State private var bottomPullDistance: CGFloat = 0
    @State private var bottomPullStartedAtBottom = false
    @State private var bottomPullIsTracking = false
    @State private var hasFiredBottomPullHaptic = false
    @State private var chatViewportHeight: CGFloat = 0
    @State private var chatViewportWidth: CGFloat = 0
    @State private var composerMeasuredHeight: CGFloat = 0
    @State private var keyboardMeasuredHeight: CGFloat = 0
    @State private var keyboardTransition: ChatKeyboardTransition?
    @State private var bottomContentInsetAnimationToken = 0
    @State private var transcriptScrollController = ChatTranscriptScrollController()
    @State private var bottomReadjustmentToken = 0
    @State private var animatedBottomScrollToken = 0
    @State private var largeMessageChunkCache = OpenCodeLargeMessageChunkCache()
    @State private var chatDisplayItemCache = ChatDisplayItemCache()
    @State private var responseActionsVisibility = ResponseActionsVisibility()
    @State private var cachedContextMetrics: OpenCodeSessionContextMetrics?
    @State private var cachedForkableMessages: [OpenCodeForkableMessage] = []

    @State private var selectedInstructionTab: AppleIntelligenceInstructionTab = .user

    private let initialMessageWindowSize = 12
    private let fallbackMessageWindowSize = 3
    private let olderMessageWindowSize = 12
    private let bottomRefreshThreshold: CGFloat = 72
    private let bottomRefreshIndicatorHeight: CGFloat = 34
    private let outgoingRequestDelayMS = 720
    private let eagerRefreshMinimumInterval: TimeInterval = 4
    #if targetEnvironment(macCatalyst)
    private let regularWidthChatMaximum: CGFloat = 1_000
    #else
    private let regularWidthChatMaximum: CGFloat = 720
    #endif

    private static let emptyContextMetrics = OpenCodeSessionContextMetrics(
        totalCost: 0,
        messageCount: 0,
        userMessageCount: 0,
        assistantMessageCount: 0,
        context: nil,
        breakdown: [],
        systemPrompt: nil
    )

    private var composerOverlaySnapshot: ChatFacade.ChatComposerOverlaySnapshot {
        let snapshot = chatFacade.composerOverlaySnapshot(forSessionID: sessionID)
        guard onDismissChildSession != nil else { return snapshot }
        return ChatFacade.ChatComposerOverlaySnapshot(
            todos: [],
            attachments: [],
            permissions: snapshot.permissions,
            questions: snapshot.questions
        )
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

    private var conversationBlockingInteractionSignature: String {
        let forms = chatFacade.sessionForms(forSessionID: sessionID)
            .map { "\($0.sessionID):\($0.id)" }.sorted().joined(separator: ",")
        return [permissionIDs, questionIDs, forms,
            chatFacade.hasUncertainPromptAdmission(sessionID: sessionID) ? "uncertain" : ""].joined(separator: "|")
    }

    private var conversationAvailable: Bool {
        connectionStore.isConnected && !chatFacade.isReadOnly && chatFacade.promptConnectionID != nil
            && !chatFacade.isPaywallPresented
            && liveSession.parentID == nil && onDismissChildSession == nil
    }

    private var voiceSpeechMessages: [OpenCodeMessageEnvelope] {
        chatFacade.presentationMessages.filter { $0.info.sessionID == sessionID }
    }

    private func refreshConversationAudioPolicy() {
        guard conversationController.isActive else { return }
        if let conversationContextID, conversationContextID != chatFacade.promptContextID {
            conversationController.stop()
            return
        }
        let available = conversationAvailable && scenePhase == .active
            && conversationBlockingInteractionSignature == "|||"
        conversationController.setAudioAvailable(available)
        conversationController.refreshPromptAdmission(chatFacade: chatFacade)
        guard available else { return }
        conversationController.resume(isSessionBusy: isSessionBusy)
        conversationController.update(messages: voiceSpeechMessages, isSessionBusy: isSessionBusy)
    }

    private var liveSession: OpenCodeSession {
        if let selected = chatFacade.selectedSession, selected.id == sessionID {
            return selected
        }

        return session(matching: sessionID) ?? OpenCodeSession(
            id: sessionID,
            title: String(localized: "Session"),
            workspaceID: nil,
            directory: nil,
            projectID: nil,
            parentID: nil
        )
    }

    private var isSessionBusy: Bool {
        directoryStore.sessionStatuses[liveSession.id] == "busy"
    }

    private var showsChatActivityShimmer: Bool {
        isSessionBusy && appCustomizationStore.showsChatActivityShimmer
    }

    private var isComposerBusy: Bool {
        isSessionBusy || pendingOutgoingSend != nil
    }

    private var showsImmersiveConversation: Bool {
        conversationController.state.isActive && conversationController.state != .paused
    }

    private var contextMetrics: OpenCodeSessionContextMetrics {
        cachedContextMetrics ?? Self.emptyContextMetrics
    }

    private var shouldAnimateStreamingText: Bool {
        true
    }

    private var chatHeaderSnapshot: ChatFacade.ChatSessionHeaderSnapshot {
        chatFacade.headerSnapshot(for: liveSession)
    }

    private var isFindPlaceSession: Bool {
        findPlaceGame(for: sessionID) != nil
    }

    private var currentProjectPreferenceScopeKey: String {
        chatFacade.preferenceScopeKey()
    }

    private func session(matching sessionID: String) -> OpenCodeSession? {
        sessionListStore.session(
            matching: sessionID,
            visibleSessions: directoryStore.sessions,
            selectedSession: chatFacade.selectedSession
        )
    }

    private func findPlaceGame(for sessionID: String) -> FindPlaceGameSession? {
        funAndGamesStore.findPlaceGame(for: sessionID)
    }

    private func findBugGame(for sessionID: String) -> FindBugGameSession? {
        funAndGamesStore.findBugGame(for: sessionID)
    }

    private func isFunAndGamesSession(_ sessionID: String) -> Bool {
        findPlaceGame(for: sessionID) != nil || findBugGame(for: sessionID) != nil
    }

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil
    }

    private var chatItemChangeAnimation: Animation? {
        if !hasCompletedInitialHydrationSnap { return nil }
        if isSendChoreographyActive { return nil }
        return isSessionBusy ? nil : .snappy(duration: 0.28, extraBounce: 0.02)
    }

    private var isSendChoreographyActive: Bool {
        pendingOutgoingSend != nil || preparingOutgoingMessageID != nil || animatingOutgoingMessageID != nil
    }

    private var chatContentMaximumWidth: CGFloat {
#if os(iOS)
        horizontalSizeClass == .regular ? regularWidthChatMaximum : .infinity
#else
        .infinity
#endif
    }

    private var showsIPadBrowserToolbarButton: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        horizontalSizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    private var usesAssistantComposerLayout: Bool {
#if targetEnvironment(macCatalyst)
        true
#elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad || appCustomizationStore.composerStyle == .assistant
#else
        false
#endif
    }

    private var usesAssistantHeaderLayout: Bool {
        pinnedHeaderUsesAssistantLayout ?? usesAssistantComposerLayout
    }

    private var supportsSessionSwitcherKeyboardBridge: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if chatFacade.windowContext == nil, !isDedicatedWindow, onDismissChildSession == nil,
           chatFacade.selectedSession?.id != sessionID {
            // Compact navigation can expose its retained detail before the shell replaces it.
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()
                .transition(.identity)
        } else {
            chatObservedContent
                .transition(.identity)
        }
        #else
        chatObservedContent
        #endif
    }

    private var chatTranscriptContent: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            ChatTranscriptPane(
                syncStore: directoryStore.syncStore,
                isScrollGeometryAtBottom: $isScrollGeometryAtBottom,
                chatViewportHeight: $chatViewportHeight,
                chatViewportWidth: $chatViewportWidth,
                scrollController: transcriptScrollController,
                bottomReadjustmentToken: bottomReadjustmentToken,
                animatedBottomScrollToken: animatedBottomScrollToken,
                composerMeasuredHeight: showsImmersiveConversation ? 0 : composerMeasuredHeight,
                keyboardMeasuredHeight: showsImmersiveConversation ? 0 : keyboardMeasuredHeight,
                keyboardTransition: keyboardTransition,
                bottomContentInsetAnimationToken: bottomContentInsetAnimationToken,
                messageBottomPadding: messageBottomPadding,
                bottomRefreshThreshold: bottomRefreshThreshold,
                bottomRefreshIndicatorHeight: bottomRefreshIndicatorHeight,
                bottomRefreshRenderSnapshot: bottomRefreshRenderSnapshot,
                isRefreshingChatData: isRefreshingChatData,
                isSessionBusy: isSessionBusy,
                isInitialHydration: chatFacade.isLoadingPresentation || !hasCompletedInitialHydrationSnap,
                isLoadingPresentation: chatFacade.isLoadingPresentation,
                contentInvalidationToken: transcriptContentInvalidationToken,
                makeDisplaySnapshot: { timedChatDisplaySnapshot },
                makeRows: { transcriptRows(for: $0) },
                makeAnimatedRowIDs: { animatedTranscriptRowIDs(for: $0) },
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
                },
                onAppear: { _ in
                    if !isDedicatedWindow {
                        chatFacade.setActiveChatSessionID(sessionID)
                    }
                    hasCompletedInitialHydrationSnap = chatSourceMessageCount > 0
                    updateDelayedLoadingIndicator()
                    scheduleInitialBottomReadjustments()
                },
                onHeightChange: { _ in },
                onSlowSnapshot: { message in
                    chatFacade.appendDebugLog(message)
                },
                rowContent: { row in
                    transcriptRowContent(for: row)
                        .frame(maxWidth: chatContentMaximumWidth)
                        .frame(maxWidth: .infinity)
                }
             )
            .onChange(of: chatFacade.presentationMessages.count) { _, count in
                if count == 0 {
                    additionalLeadingMessageCount = 0
                }

                if count > 0, !hasCompletedInitialHydrationSnap {
                    hasCompletedInitialHydrationSnap = true
                    scheduleInitialBottomReadjustments()
                }
                pruneExpandedReasoningParts()
                updateDelayedLoadingIndicator()
            }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
                updateKeyboardMeasuredHeight(keyboardHeight(from: notification), transition: ChatKeyboardTransition(notification: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
                updateKeyboardMeasuredHeight(0, transition: ChatKeyboardTransition(notification: notification))
            }
#endif

            if chatOverlayVisibilitySnapshot.visibleOverlay == .forkPreparation {
                forkPreparationOverlay
            } else if chatOverlayVisibilitySnapshot.visibleOverlay == .delayedLoading {
                delayedLoadingOverlay
            }
            bottomRefreshFloatingIndicator
            scrollToBottomButtonOverlay

            if showsImmersiveConversation {
                ImmersiveConversationView(
                    state: conversationController.state,
                    inputMode: conversationController.inputMode,
                    inputLevel: conversationController.inputLevel,
                    inputPitch: conversationController.inputPitch,
                    isSpeakingFiller: conversationController.isSpeakingFiller,
                    isSendHeld: conversationController.isSendHeld,
                    isMuted: conversationController.isMuted,
                    transcript: conversationController.transcript,
                    showsBackdrop: true,
                    onStop: conversationController.stop,
                    onToggleHold: conversationController.toggleSendHold,
                    onToggleMute: conversationController.toggleMute,
                    onBeginHold: conversationController.beginHoldToTalk,
                    onEndHold: conversationController.endHoldToTalk
                )
                .zIndex(10)
            }
        }
         .overlay(alignment: .bottom) {
             composerOverlay
                 .frame(maxWidth: chatContentMaximumWidth)
                 .opacity(showsImmersiveConversation ? 0 : 1)
                 .offset(y: showsImmersiveConversation ? 140 : 0)
                 .allowsHitTesting(!showsImmersiveConversation)
                 .animation(.snappy(duration: 0.34, extraBounce: 0.04), value: showsImmersiveConversation)
         }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if showsChatActivityShimmer {
                    ChatStatusBarStateShimmer(tint: activeSessionTint)
                        .ignoresSafeArea(.container, edges: .top)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let presentation = chatFacade.sessionSwitcherPresentation {
                    OpenClientSessionSwitcherOverlay(presentation: presentation)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.22), value: showsChatActivityShimmer)
            .animation(.snappy(duration: 0.2), value: chatFacade.sessionSwitcherPresentation)
        }
    }

    private var chatPresentationContent: some View {
        chatTranscriptContent
        .navigationTitle("")
        .opencodeInlineNavigationTitle()
        .preference(
            key: ChatComposerFocusPreferenceKey.self,
            value: isComposerInputFocused
        )
        .modifier(
            ChatFocusedActionsModifier(
                stopAction: isComposerBusy ? { stopComposerAction() } : nil,
                switchSessionAction: recentlyOpenedSessionSwitchAction
            )
        )
        .background {
            #if canImport(UIKit)
            if supportsSessionSwitcherKeyboardBridge, onDismissChildSession == nil {
                SessionSwitcherKeyboardBridge(onAdvance: { isActive in
                    advanceRecentlyOpenedSessionSwitcher(isActive: isActive)
                }, onCancel: {
                    chatFacade.cancelSessionSwitcher(for: sessionID)
                })
                .frame(width: 0, height: 0)
            }
            #endif
        }
        .onAppear {
            chatFacade.windowContext?.stopAudio = { [weak conversationController] in conversationController?.stop() }
            syncComposerDraftFromViewModel()
            refreshCachedContextMetrics()
            refreshCachedForkableMessages()
            pruneExpandedReasoningParts()
            updateDelayedLoadingIndicator()
            clearInactiveKeyboardMeasurement()
        }
        .task(id: [sessionID, connectionStore.isConnected ? "connected" : "disconnected"]) {
            guard connectionStore.isConnected, !isScreenshotScene else { return }
            await chatFacade.hydrateSessionForPresentation(liveSession)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { chatFacade.cancelSessionSwitcher(for: sessionID) }
            if phase == .active {
                clearInactiveKeyboardMeasurement()
                scheduleEagerChatRefresh(reason: "scene active")
            }
            refreshConversationAudioPolicy()
        }
#if canImport(UIKit)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            clearInactiveKeyboardMeasurement()
            scheduleEagerChatRefresh(reason: "did become active")
        }
#endif
        .onDisappear {
            chatFacade.cancelSessionSwitcher(for: sessionID)
            thinkingEntryGate = ChatThinkingEntryGate()
            preparingOutgoingMessageID = nil
            animatingOutgoingMessageID = nil
            outgoingEntryAnimationStartedMessageIDs = []
            invalidateV2RetryDraft()
            if chatFacade.selectedSession?.id == sessionID {
                persistComposerDraftNow()
            }
            chatFacade.setComposerStreamingFocus(false)
            taskStore.delayedLoadingIndicatorTask?.cancel()
            taskStore.composerDraftPersistenceTask?.cancel()
            taskStore.contextMetricsTask?.cancel()
            pendingOutgoingSendTask?.cancel()
            outgoingEntryResetTask?.cancel()
            initialBottomScrollTask?.cancel()
            eagerRefreshTask?.cancel()
            conversationController.stop()
            keyboardMeasuredHeight = 0
            showsDelayedLoadingIndicator = false
            if !isDedicatedWindow {
                chatFacade.clearActiveChatSessionIfMatching(sessionID)
            }
        }
        .toolbar { chatToolbar }
#if DEBUG
        .sheet(isPresented: $chatPresentationStore.isShowingDebugProbe) {
            ChatDebugProbeSheet(chatFacade: chatFacade, copiedDebugLog: $copiedDebugLog)
        }
#endif
        .sheet(item: $selectedActivityDetail) { detail in
            NavigationStack {
                ActivityDetailView(chatFacade: chatFacade, detail: detail)
            }
        }
        .sheet(item: $presentedTaskSession, onDismiss: restoreActiveSessionAfterTaskSheet) { taskSession in
            if let childChat = presentedTaskChat, let childContext = childChat.windowContext {
                NavigationStack {
                    ChatView(
                        chatFacade: childChat,
                        browser: childContext.browser,
                        imageContent: imageContent,
                        videoStreams: videoStreams,
                        sessionID: taskSession.id,
                        onDismissChildSession: {
                            presentedTaskSession = nil
                        }
                    )
                }
                .presentationDetents([.fraction(0.3), .medium, .large], selection: $taskSessionDetent)
                .presentationDragIndicator(.visible)
                .onDisappear { childContext.close() }
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
                TodoInspectorView(chatFacade: chatFacade)
            }
        }
        .sheet(isPresented: $showingContextMetrics) {
            NavigationStack {
                SessionContextMetricsSheet(session: liveSession, metrics: contextMetrics)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedAttachmentPreview) { attachment in
            NavigationStack {
                AttachmentPreviewSheet(attachment: attachment)
            }
        }
        .sheet(item: $selectedVisualHTML) { presentation in
            OpenClientVisualHTMLDetailView(payload: presentation.payload)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $chatPresentationStore.isShowingAppleIntelligenceInstructionsSheet) {
            NavigationStack {
                AppleIntelligenceInstructionsSheet(
                    userInstructions: $chatPresentationStore.appleIntelligenceUserInstructions,
                    systemInstructions: $chatPresentationStore.appleIntelligenceSystemInstructions,
                    selectedTab: $selectedInstructionTab,
                    defaultUserInstructions: chatFacade.defaultAppleIntelligenceUserInstructions,
                    defaultSystemInstructions: chatFacade.defaultAppleIntelligenceSystemInstructions,
                    onDone: {
                        chatPresentationStore.isShowingAppleIntelligenceInstructionsSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $chatPresentationStore.isShowingForkSessionSheet) {
            NavigationStack {
                ForkSessionSheet(chatFacade: chatFacade)
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
    }

    private var chatTranscriptObservedContent: some View {
        chatPresentationContent
        .onChange(of: accessoryPresenceSignature) { _, _ in
            let overlaySnapshot = composerOverlaySnapshot
            if overlaySnapshot.attachments.isEmpty || overlaySnapshot.todos.allSatisfy(\.isComplete) {
                composerAccessoryExpansion = .collapsed
            }
        }
        .onChange(of: composerOverlaySnapshot.showsAccessoryArea) { _, _ in
            bottomContentInsetAnimationToken &+= 1
        }
        .onChange(of: chatFacade.presentationMessages.count) { _, _ in
            copiedTranscript = false
            pruneExpandedReasoningParts()
            if !isSessionBusy {
                refreshCachedForkableMessages()
            }
        }
        .onReceive(chatStore.$messages.dropFirst()) { _ in
            guard !isSessionBusy else { return }
            refreshCachedContextMetrics()
        }
        .onReceive(chatStore.objectWillChange) { _ in
            DispatchQueue.main.async { refreshConversationAudioPolicy() }
        }
        .onReceive(chatFacade.objectWillChange) { _ in
            refreshConversationAudioPolicy()
        }
        .onReceive(conversationController.$transcript.dropFirst()) { transcript in
            if composerDraftStore.text != transcript {
                composerDraftStore.text = transcript
                scheduleComposerDraftPersistence(transcript)
            }
        }
    }

    private var chatObservedContent: some View {
        chatTranscriptObservedContent
        .onReceive(modelConfigurationStore.$availableProviders.dropFirst()) { _ in
            guard !isSessionBusy else { return }
            refreshCachedContextMetrics()
        }
        .onReceive(
            directoryStore.syncStore.$version
                .dropFirst()
                .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
        ) { _ in
            guard !isSessionBusy else { return }
            refreshCachedContextMetrics()
        }
        .onChange(of: reasoningPartKeySignature) { _, _ in
            pruneExpandedReasoningParts()
        }
        .onChange(of: isSessionBusy) { _, isBusy in
            if !isBusy {
                refreshCachedContextMetrics()
                refreshCachedForkableMessages()
            }
            refreshConversationAudioPolicy()
        }
        .onChange(of: conversationController.sendRequestToken) { _, _ in
            handleConversationSendRequest()
        }
        .onChange(of: conversationBlockingInteractionSignature) { _, _ in
            refreshConversationAudioPolicy()
        }
        .onChange(of: thinkingEntryContextID) { _, _ in
            thinkingEntryGate = ChatThinkingEntryGate()
            outgoingEntryResetTask?.cancel()
            preparingOutgoingMessageID = nil
            animatingOutgoingMessageID = nil
            outgoingEntryAnimationStartedMessageIDs = []
            refreshConversationAudioPolicy()
        }
        .onChange(of: conversationAvailable) { _, _ in
            refreshConversationAudioPolicy()
        }
        .onChange(of: composerStore.resetToken) { _, _ in
            syncComposerDraftFromViewModel()
        }
        .onChange(of: chatFacade.isLoadingPresentation) { _, _ in
            updateDelayedLoadingIndicator()
        }
        .onChange(of: presentationRequest) { _, _ in
            handleChatPresentationRequest()
        }
        .alert(
            "Dictation Unavailable",
            isPresented: Binding(
                get: { conversationController.errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        conversationController.errorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                conversationController.errorMessage = nil
            }
        } message: {
            Text(conversationController.errorMessage ?? "")
        }
    }

    private func refreshCachedContextMetrics() {
        refreshCachedContextMetrics(
            messages: sessionScopedFallbackMessages,
            providers: modelConfigurationStore.availableProviders
        )
    }

    private var recentlyOpenedSessionSwitchAction: (() -> Void)? {
        return {
            advanceRecentlyOpenedSessionSwitcher()
        }
    }

    private func advanceRecentlyOpenedSessionSwitcher(isActive: @escaping () -> Bool = { true }) {
        #if canImport(UIKit)
        SessionSwitcherDiagnostics.log("advance candidates=\(chatFacade.sessionSwitcherCandidates.count) commandDown=\(OpenClientCommandHoldMonitor.isCommandPressed)")
        #endif
        guard chatFacade.advanceSessionSwitcher(from: sessionID) != nil else { return }
        chatFacade.monitorSessionSwitcher(isActive: isActive)
    }

    private func refreshCachedContextMetrics(
        messages: [OpenCodeMessageEnvelope],
        providers: [OpenCodeProvider]
    ) {
        taskStore.contextMetricsTask?.cancel()
        taskStore.contextMetricsTask = Task { @MainActor in
            let metrics = await Task.detached(priority: .utility) {
                OpenCodeSessionContextMetricsBuilder.metrics(messages: messages, providers: providers)
            }.value
            guard !Task.isCancelled else { return }
            cachedContextMetrics = metrics
        }
    }

    private func refreshCachedForkableMessages() {
        cachedForkableMessages = makeForkableMessages()
    }

    private func syncComposerDraftFromViewModel() {
        guard chatFacade.selectedSession?.id == sessionID else { return }
        taskStore.composerDraftPersistenceTask?.cancel()
        if composerDraftStore.text != composerStore.draftMessage {
            composerDraftStore.text = composerStore.draftMessage
        }
        if composerDraftStore.agentMentions != composerStore.draftAgentMentions {
            composerDraftStore.agentMentions = composerStore.draftAgentMentions
        }
    }

    private func scheduleComposerDraftPersistence(_ text: String) {
        taskStore.composerDraftPersistenceTask?.cancel()
        taskStore.composerDraftPersistenceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            chatFacade.saveMessageDraft(text, agentMentions: composerDraftStore.agentMentions, forSessionID: sessionID, updateActiveDraft: false)
        }
    }

    private func persistComposerDraftNow(removesEmpty: Bool = true) {
        taskStore.composerDraftPersistenceTask?.cancel()
        chatFacade.saveMessageDraft(composerDraftStore.text, agentMentions: composerDraftStore.agentMentions, forSessionID: sessionID, removesEmpty: removesEmpty)
    }

    private func clearComposerDraft() {
        if !chatFacade.isV2Connection { promptDraftRevision &+= 1; promptRetryDraft = nil }
        invalidateV2RetryDraft()
        taskStore.composerDraftPersistenceTask?.cancel()
        if !composerDraftStore.text.isEmpty {
            composerDraftStore.text = ""
        }
        if !composerDraftStore.agentMentions.isEmpty {
            composerDraftStore.agentMentions = []
        }
        chatFacade.saveMessageDraft("", agentMentions: [], forSessionID: sessionID)
        chatFacade.resetComposer()
    }

    private func restoreComposerDraft(_ text: String) {
        if !chatFacade.isV2Connection { promptDraftRevision &+= 1; promptRetryDraft = nil }
        invalidateV2RetryDraft()
        taskStore.composerDraftPersistenceTask?.cancel()
        if composerDraftStore.text != text {
            composerDraftStore.text = text
        }
        composerDraftStore.agentMentions = []
        chatFacade.saveMessageDraft(text, agentMentions: [], forSessionID: sessionID)
        chatFacade.resetComposer()
    }

    @ViewBuilder
    private var composerStack: some View {
        let overlaySnapshot = composerOverlaySnapshot
        let modeSnapshot = composerOverlayModeSnapshot(overlaySnapshot: overlaySnapshot, headerSnapshot: chatHeaderSnapshot)
        let sessionForms = chatFacade.sessionForms(forSessionID: sessionID)

        VStack(spacing: 6) {
            let recoveryInputs = chatFacade.recoveryInputs(sessionID: sessionID)
            if recoveryInputs.isEmpty, !chatFacade.isV2Connection, chatFacade.hasUncertainPromptAdmission(sessionID: sessionID) {
                Text("Prompt admission is uncertain. Refresh the timeline before retrying.")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            } else if chatFacade.isV2Connection || chatFacade.windowContext != nil, let error = chatFacade.presentationErrorMessage {
                HStack(alignment: .top) {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Dismiss") { connectionStore.clearError() }
                }
                .padding(.horizontal, 16)
                .accessibilityIdentifier("chat.v2.error")
            }
            if overlaySnapshot.showsAccessoryArea {
                ComposerAccessoryArea(
                    todos: overlaySnapshot.todos,
                    attachments: overlaySnapshot.attachments,
                    expansion: $composerAccessoryExpansion,
                    isTodoStripMinimized: appCustomizationStore.isTodoStripMinimized,
                    onSetTodoStripMinimized: { isMinimized in
                        appCustomizationStore.setTodoStripMinimized(isMinimized)
                    },
                    onTapTodo: {
                        showingTodoInspector = true
                    },
                    onTapAttachment: { attachment in
                        selectedAttachmentPreview = attachment
                    },
                    onRemoveAttachment: { attachment in
                        invalidateV2RetryDraft()
                        chatFacade.removeDraftAttachment(attachment)
                    }
                )
                .padding(.horizontal, 16)
            }

            if chatFacade.isReadOnly {
                CachedChatReadOnlyComposerNotice()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            } else if !sessionForms.isEmpty && overlaySnapshot.permissions.isEmpty {
                SessionFormPanel(forms: sessionForms, store: chatFacade.sessionFormStore(forSessionID: sessionID),
                    contextID: chatFacade.promptContextID, allowsActions: chatFacade.allowsSessionForms,
                    submit: { await chatFacade.submitSessionForm($0) },
                    cancel: { await chatFacade.cancelSessionForm($0) },
                    refresh: { await chatFacade.refreshSessionForm($0) })
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .padding(.bottom, questionPanelBottomPadding)
            } else {
                switch modeSnapshot.mode {
                case .permissions:
                    PermissionActionStack(
                        permissions: overlaySnapshot.permissions,
                        onDismiss: { permission in
                            chatFacade.dismissPermission(permission)
                        },
                        onRespond: { permission, response in
                            Task { await chatFacade.respondToPermission(permission, response: response) }
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
                            Task { await chatFacade.dismissQuestion(request) }
                        },
                        onSubmit: { request, answers in
                            Task { await chatFacade.respondToQuestion(request, answers: answers) }
                        }
                    )
                    .padding(.vertical, 8)
                    .padding(.bottom, questionPanelBottomPadding)
                case .childSessionNotice:
                    childSessionComposerNotice(headerSnapshot: chatHeaderSnapshot)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                case .activeComposer:
                    activeMessageComposer(isBusy: isComposerBusy || chatFacade.isV2PromptInFlight(sessionID: sessionID)
                        || chatFacade.hasPendingPromptAdmission(sessionID: sessionID))
                }
            }

            if showsChatBrowserAccessory {
                BrowserAccessoryRow(
                    browser: browser,
                    accessibilityIdentifier: "browser.chatAccessory"
                )
                .opencodeConcentricGlassSurface(
                    isInteractive: true,
                    minimumCornerRadius: 20,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.02), value: showsChatBrowserAccessory)
        .onReceive(composerDraftStore.$text.removeDuplicates().dropFirst()) { text in
            if text != (v2RetryDraft?.text ?? "") { invalidateV2RetryDraft() }
            if !chatFacade.isV2Connection, text != (promptRetryDraft?.text ?? "") {
                promptDraftRevision &+= 1
                promptRetryDraft = nil
            }
        }
        .onReceive(composerDraftStore.$agentMentions.removeDuplicates().dropFirst()) { mentions in
            if mentions != (v2RetryDraft?.mentions ?? []) { invalidateV2RetryDraft() }
            if !chatFacade.isV2Connection, mentions != (promptRetryDraft?.mentions ?? []) {
                promptDraftRevision &+= 1
                promptRetryDraft = nil
            }
        }
        .onReceive(composerStore.$draftAttachments.removeDuplicates().dropFirst()) { attachments in
            if attachments != (v2RetryDraft?.attachments ?? []) { invalidateV2RetryDraft() }
            if !chatFacade.isV2Connection, attachments != (promptRetryDraft?.attachments ?? []) {
                promptDraftRevision &+= 1
                promptRetryDraft = nil
            }
        }
        .onChange(of: chatStore.submissionRecoveries) { _, _ in
            clearConfirmedV2RetryDraftIfUnchanged()
            clearConfirmedPromptDraftIfUnchanged()
        }
        .onChange(of: chatStore.canonicalSubmissionSessions) { _, _ in
            clearConfirmedV2RetryDraftIfUnchanged()
            clearConfirmedPromptDraftIfUnchanged()
        }
        .onChange(of: chatStore.promptAdmissions) { _, _ in
            clearConfirmedPromptDraftIfUnchanged()
            clearConfirmedV2RetryDraftIfUnchanged()
        }
    }

    @discardableResult
    private func clearConfirmedPromptDraftIfUnchanged() -> Bool {
        guard let retry = promptRetryDraft, chatFacade.selectedSession?.id == sessionID,
              chatFacade.promptAdmissionPhase(messageID: retry.messageID, sessionID: sessionID) == .admitted,
              retry.canClear(admittedMessageID: retry.messageID, sessionID: sessionID,
                  contextID: chatFacade.promptContextID, revision: promptDraftRevision, resetToken: composerStore.resetToken,
                  text: composerDraftStore.text, mentions: composerDraftStore.agentMentions,
                  attachments: composerStore.draftAttachments) else { return false }
        clearComposerDraft()
        chatFacade.clearDraftAttachments()
        return true
    }

    private func invalidateV2RetryDraft() {
        guard v2DraftAttemptID != nil || v2RetryDraft != nil else { return }
        v2DraftRevision &+= 1
        v2RetryDraft = nil
    }

    @discardableResult
    private func clearConfirmedV2RetryDraftIfUnchanged(verifiedMessageID: String? = nil) -> Bool {
        guard let retry = v2RetryDraft,
               chatFacade.activeChatSessionID == sessionID,
               (chatFacade.isPromptAdmitted(messageID: retry.messageID, sessionID: retry.sessionID) || verifiedMessageID == retry.messageID),
              retry.canClear(admittedMessageID: retry.messageID, sessionID: sessionID,
                  contextID: chatFacade.v2DraftContextID, revision: v2DraftRevision,
                  resetToken: composerStore.resetToken,
                  text: composerDraftStore.text, mentions: composerDraftStore.agentMentions,
                  attachments: composerStore.draftAttachments) else { return false }
        clearComposerDraft()
        chatFacade.clearDraftAttachments()
        return true
    }

    private func sendV2Prompt() {
        if clearConfirmedV2RetryDraftIfUnchanged() { return }
        guard v2DraftAttemptID == nil else { return }
        if let retry = v2RetryDraft,
           retry.canClear(admittedMessageID: retry.messageID, sessionID: sessionID,
               contextID: chatFacade.v2DraftContextID, revision: v2DraftRevision, resetToken: composerStore.resetToken,
               text: composerDraftStore.text, mentions: composerDraftStore.agentMentions, attachments: composerStore.draftAttachments) {
            // Resolve the original input with reads only. Never retry an uncertain
            // command or prompt by minting a fresh ID, even after an idle event.
            v2DraftAttemptID = retry.messageID
            Task { @MainActor in
                defer { if v2DraftAttemptID == retry.messageID { v2DraftAttemptID = nil } }
                if await chatFacade.resolvePromptAdmission(messageID: retry.messageID, sessionID: retry.sessionID) {
                    clearConfirmedV2RetryDraftIfUnchanged(verifiedMessageID: retry.messageID)
                }
            }
            return
        }
        let trimmed = OpenCodeAgentMention.trimmingTextAndMentions(
            text: composerDraftStore.text,
            mentions: composerDraftStore.agentMentions
        )
        let prompt = trimmed.text
        let attachments = composerStore.draftAttachments
        let mentions = trimmed.mentions
        guard !prompt.isEmpty || !attachments.isEmpty, !chatFacade.hasPendingPromptAdmission(sessionID: sessionID) else { return }
        let command = chatFacade.slashCommandInput(from: prompt)
        if attachments.isEmpty,
           chatFacade.shouldOpenForkSheet(forSlashInput: prompt) || command.map({ chatFacade.isForkClientCommand($0.command) }) == true {
            clearComposerDraft()
            chatFacade.presentForkSessionSheet()
            return
        }
        let session = liveSession
        let contextID = chatFacade.v2DraftContextID
        let messageID = OpenCodeIdentifier.message()
        if !(attachments.isEmpty && command.map({ chatFacade.isCompactClientCommand($0.command) }) == true) {
            thinkingEntryGate.begin(messageID: messageID, contextID: thinkingEntryContextID,
                alreadyVisible: timedChatDisplaySnapshot.snapshot.showsThinking)
            preparingOutgoingMessageID = messageID
            chatStore.stageSubmissionPresentation(.local(role: "user", text: prompt, agentMentions: mentions,
                attachments: attachments, messageID: messageID, sessionID: session.id), sessionID: session.id,
                canonical: transcriptSuffix(chatSourceMessageCount), attachments: attachments, agentMentions: mentions)
            scheduleOutgoingEntryAnimation(messageID: messageID)
            requestBottomReadjustment()
        }
        clearComposerDraft()
        chatFacade.clearDraftAttachments()
        v2DraftAttemptID = messageID
        let requestRevision = v2DraftRevision
        let requestResetToken = composerStore.resetToken
        Task { @MainActor in
            defer {
                chatStore.discardStagedSubmissionPresentation(messageID: messageID)
                if v2DraftAttemptID == messageID { v2DraftAttemptID = nil }
            }
            guard !Task.isCancelled, chatFacade.v2DraftContextID == contextID,
                  chatFacade.activeChatSessionID == session.id else { return }
            let accepted: Bool
            let tracksAdmission: Bool
            if let command, attachments.isEmpty, chatFacade.isCompactClientCommand(command.command) {
                tracksAdmission = false
                accepted = await chatFacade.compactSession(sessionID: session.id, userVisible: true, restoreDraftOnFailure: false)
            } else if let command, !chatFacade.isCompactClientCommand(command.command), !chatFacade.isForkClientCommand(command.command) {
                tracksAdmission = true
                accepted = await chatFacade.sendCommand(command.command, sessionID: session.id, userVisible: true,
                    restoreDraftOnFailure: false, arguments: command.arguments, attachments: attachments,
                    messageID: messageID, agentMentions: mentions)
            } else {
                tracksAdmission = true
                accepted = await chatFacade.sendV2TextPrompt(prompt, in: session, attachments: attachments,
                    agentMentions: mentions, messageID: messageID)
            }
            guard !accepted, chatFacade.activeChatSessionID == session.id,
                  chatFacade.v2DraftContextID == contextID, v2DraftRevision == requestRevision,
                  composerStore.resetToken == requestResetToken,
                  composerDraftStore.text.isEmpty, composerDraftStore.agentMentions.isEmpty,
                  composerStore.draftAttachments.isEmpty else { return }
            if tracksAdmission, chatFacade.isPromptAdmitted(messageID: messageID, sessionID: session.id) { return }
            restoreComposerDraft(prompt)
            composerDraftStore.agentMentions = mentions
            chatFacade.setDraftAgentMentions(mentions, forSessionID: session.id)
            chatFacade.addDraftAttachments(attachments)
            if tracksAdmission, chatFacade.promptAdmissionPhase(messageID: messageID, sessionID: session.id) == .uncertain {
                v2RetryDraft = OpenCodeV2RetryDraft(messageID: messageID, sessionID: session.id, contextID: contextID,
                    revision: v2DraftRevision, resetToken: composerStore.resetToken,
                    text: prompt, mentions: mentions, attachments: attachments)
                clearConfirmedV2RetryDraftIfUnchanged()
            }
        }
    }

    private var showsChatBrowserAccessory: Bool {
        guard !chatFacade.isReadOnly, browser.activeProjectID != nil else { return false }
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return browser.presentation == .collapsed
                && keyboardMeasuredHeight < 1
        }
        #endif
        return false
    }

    private func composerOverlayModeSnapshot(
        overlaySnapshot: ChatFacade.ChatComposerOverlaySnapshot,
        headerSnapshot: ChatFacade.ChatSessionHeaderSnapshot
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

    private func activeMessageComposer(isBusy: Bool) -> some View {
        let composerSnapshot = chatFacade.composerSnapshot(
            for: liveSession,
            isBusy: isBusy,
            forkableMessages: forkableMessages
        )
        let toolbarSnapshot = chatFacade.toolbarSnapshot(for: liveSession)
        let commands = composerSnapshot.commands
        let mentionableAgents = modelConfigurationStore.mentionableAgents
        let commandScopeKey = currentProjectPreferenceScopeKey
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
            actionSignature: composerSnapshot.actionSignature,
            contextSnapshot: contextMetrics.context,
            conversationState: conversationController.state,
            conversationInputLevel: conversationController.inputLevel,
            blocksNewInput: chatFacade.hasGlobalForms(sessionID: sessionID) || funAndGamesStore.hasPendingSetup(for: sessionID),
            prefersAssistantLayout: appCustomizationStore.composerStyle == .assistant,
            toolbarSnapshot: toolbarSnapshot
        )

        let browserAction: (() -> Void)?
        let conversationAction: (() -> Void)? = conversationAvailable ? { toggleConversationMode() } : nil
        if chatFacade.isReadOnly || browser.activeProjectID == nil {
            browserAction = nil
        } else {
            browserAction = { presentBrowser() }
        }

        let composer: EquatableMessageComposerHost = EquatableMessageComposerHost(
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
                if !isFocused {
                    clearInactiveKeyboardMeasurement()
                }
                chatFacade.setComposerStreamingFocus(isFocused)
            },
            onTextChange: { text in
                invalidateV2RetryDraft()
                scheduleComposerDraftPersistence(text)
            },
            onAgentMentionsChange: { mentions in
                invalidateV2RetryDraft()
                chatFacade.setDraftAgentMentions(mentions, forSessionID: sessionID)
            },
            onHeightChange: { height in
                handleComposerHeightChange(height)
            },
            onSend: {
                if chatFacade.isV2Connection {
                    sendV2Prompt()
                } else {
                    _ = startOutgoingBubbleAnimationAndSend()
                }
            },
            onStop: {
                if chatFacade.isV2Connection {
                    Task { await chatFacade.interruptV2Session(sessionID: sessionID) }
                } else {
                    stopComposerAction()
                }
            },
            onSelectCommand: { command in
                guard !chatFacade.hasPendingPromptAdmission(sessionID: sessionID) else { return }
                chatFacade.flushBufferedTranscript(reason: "command action")
                if chatFacade.isForkClientCommand(command) {
                    clearComposerDraft()
                    chatFacade.presentForkSessionSheet()
                    return
                }
                let metersPrompt = chatFacade.shouldMeterPrompts(for: sessionID)
                if chatFacade.isCompactClientCommand(command), metersPrompt {
                    guard chatFacade.reserveUserPromptIfAllowed() else { return }
                }
                let commandInputID = OpenCodeIdentifier.message()
                let commandAttachments = composerStore.draftAttachments
                clearComposerDraft()
                Task {
                    if chatFacade.isCompactClientCommand(command) {
                        await chatFacade.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false, restoreDraftOnFailure: false)
                    } else {
                        await chatFacade.sendCommand(command, sessionID: sessionID, userVisible: true, meterPrompt: metersPrompt,
                            restoreDraftOnFailure: false, attachments: commandAttachments, messageID: commandInputID, agentMentions: [])
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
                chatFacade.flushBufferedTranscript(reason: "compact menu action")
                if chatFacade.shouldMeterPrompts(for: sessionID) {
                    guard chatFacade.reserveUserPromptIfAllowed() else { return }
                }
                Task { await chatFacade.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false) }
            },
            onForkMessage: { messageID in
                Task { await chatFacade.forkSelectedSession(from: messageID) }
            },
            onLoadMCP: {
                Task { await chatFacade.loadMCPStatusIfNeeded() }
            },
            onToggleMCP: { name in
                Task { await chatFacade.toggleMCPServer(name: name) }
            },
            onAddAttachments: { attachments in
                invalidateV2RetryDraft()
                chatFacade.addDraftAttachments(attachments)
            },
            onOpenBrowser: browserAction,
            glassNamespace: composerGlassNamespace,
            agentTitle: toolbarSnapshot.agentTitle,
            selectableAgents: toolbarSnapshot.selectableAgents,
            modelTitle: toolbarSnapshot.modelTitle,
            modelReference: toolbarSnapshot.displayedModelReference,
            modelProviderName: toolbarSnapshot.modelProviderName,
            providerGroups: toolbarSnapshot.providerGroups,
            reasoningVariants: toolbarSnapshot.reasoningVariants,
            reasoningTitle: toolbarSnapshot.reasoningTitle,
            onSelectAgent: { chatFacade.selectAgent(named: $0, for: liveSession) },
            onSelectModel: { chatFacade.selectModel($0, for: liveSession) },
            onSelectReasoningVariant: { chatFacade.selectReasoningVariant($0, for: liveSession) },
            onShowContextMetrics: { showingContextMetrics = true },
            conversationState: snapshot.conversationState,
            conversationInputLevel: snapshot.conversationInputLevel,
            onToggleConversation: conversationAction
        )

        return composer
            .equatable()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, activeComposerBottomPadding)
            .background(.clear)
    }

    private func toggleConversationMode() {
        if conversationController.isActive {
            conversationController.stop()
            return
        }

        _ = startConversationMode()
    }

    @discardableResult
    private func startConversationMode(initialTranscript: String? = nil) -> Bool {
        guard conversationAvailable, scenePhase == .active, !conversationController.isActive,
              conversationBlockingInteractionSignature == "|||",
              !chatFacade.hasPendingPromptAdmission(sessionID: sessionID),
              !isComposerBusy,
              composerStore.draftAttachments.isEmpty else { return false }
        isComposerInputFocused = false
#if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
        composerDraftStore.agentMentions = []
        chatFacade.setDraftAgentMentions([], forSessionID: sessionID)
        if let voiceModel = modelConfigurationStore.voiceModeModelReference() {
            chatFacade.selectModel(voiceModel, for: liveSession)
        }
        conversationContextID = chatFacade.promptContextID
        conversationController.setAudioAvailable(true)
        conversationController.start(initialTranscript: initialTranscript ?? composerDraftStore.text)
        if chatFacade.supportsTalkLiveActivities {
            conversationController.startLiveActivity(
                title: liveSession.displayTitle(),
                directory: liveSession.directory,
                workspaceID: liveSession.workspaceID,
                sessionID: liveSession.id
            )
        }
        return conversationController.isActive
    }

    private func handleConversationSendRequest() {
        guard conversationController.state == .submitting else { return }
        refreshConversationAudioPolicy()
        conversationController.submitTurn(in: liveSession, chatFacade: chatFacade)
    }

    private var activeComposerBottomPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        8
        #else
        isComposerInputFocused ? 8 : 0
        #endif
    }

    private func presentBrowser() {
        if browser.presentation == .closed {
            browser.openAddressBar()
        } else {
            browser.expand()
        }
    }

    private var questionPanelBottomPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        8
        #else
        0
        #endif
    }

    private var forkableMessages: [OpenCodeForkableMessage] {
        if isSessionBusy {
            return cachedForkableMessages
        }

        return makeForkableMessages()
    }

    private func makeForkableMessages() -> [OpenCodeForkableMessage] {
        var result: [OpenCodeForkableMessage] = []

        for message in sessionScopedFallbackMessages {
            guard (message.info.role ?? "").lowercased() == "user" else { continue }
            let promptText = chatFacade.forkPromptText(from: message)
            let trimmedText = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }

            result.append(
                OpenCodeForkableMessage(
                    id: message.id,
                    text: trimmedText.replacingOccurrences(of: "\n", with: " "),
                    created: message.info.time?.created
                )
            )
        }

        return result.reversed()
    }

    private func childSessionComposerNotice(headerSnapshot: ChatFacade.ChatSessionHeaderSnapshot) -> some View {
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

            if let onDismissChildSession {
                Button("Close", action: onDismissChildSession)
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .accessibilityLabel("Close subagent thread")
            } else {
                Button("Back") {
                    guard let parentSession = headerSnapshot.parentSession else { return }
                    Task { await chatFacade.selectSession(parentSession) }
                }
                .buttonStyle(.bordered)
                .tint(.purple)
            }
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
        if chatPresentationStore.pendingForkSessionID == sessionID {
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

    private var showsScrollToBottomButton: Bool {
        !isScrollGeometryAtBottom && !chatFacade.presentationMessages.isEmpty && !bottomRefreshRenderSnapshot.showsIndicator
    }

    @ViewBuilder
    private var scrollToBottomButtonOverlay: some View {
        if showsScrollToBottomButton {
            VStack {
                Spacer(minLength: 0)

                Button {
                    scrollToBottomFromButton()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Circle())
                }
                .opencodeActionGlass(
                    clear: false,
                    tint: OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.72),
                    size: 38,
                    in: Circle()
                )
                .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
                .padding(.bottom, composerMeasuredHeight + 12)
                .accessibilityLabel("Scroll to bottom")
                .accessibilityIdentifier("chat.scrollToBottom")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .animation(.snappy(duration: 0.2, extraBounce: 0.04), value: showsScrollToBottomButton)
        }
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
        await chatFacade.refreshChatData(for: sessionID)
    }

    private func requestBottomReadjustmentIfPinned() {
        guard isScrollGeometryAtBottom else { return }
        requestBottomReadjustment()
    }

    private func requestBottomReadjustment() {
        bottomReadjustmentToken &+= 1
    }

    private func scheduleInitialBottomReadjustments() {
        initialBottomScrollTask?.cancel()
        initialBottomScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            requestBottomReadjustment()
        }
    }

    private func handleChatPresentationRequest() {
        guard chatFacade.selectedSession?.id == sessionID else { return }
        clearInactiveKeyboardMeasurement(forceBottomReadjustment: true)
        requestBottomReadjustment()
    }

    private func updateKeyboardMeasuredHeight(_ height: CGFloat, transition: ChatKeyboardTransition? = nil) {
        let height = max(0, height)
        guard abs(height - keyboardMeasuredHeight) > 0.5 else { return }
        keyboardTransition = transition
        keyboardMeasuredHeight = height
    }

    private func clearInactiveKeyboardMeasurement(forceBottomReadjustment: Bool = false) {
        guard !isComposerInputFocused else { return }
        if keyboardMeasuredHeight > 0 {
            keyboardMeasuredHeight = 0
        }
        if forceBottomReadjustment {
            requestBottomReadjustment()
        }
    }

    private func scrollToBottomFromButton() {
        OpenCodeHaptics.impact(.soft)
        if transcriptScrollController.scrollToBottom(animated: true) {
            isScrollGeometryAtBottom = true
        } else {
            animatedBottomScrollToken &+= 1
        }
    }

    private func scheduleEagerChatRefresh(reason: String) {
        guard !isScreenshotScene else { return }
        guard connectionStore.isConnected else { return }
        guard chatFacade.activeChatSessionID == sessionID || chatFacade.selectedSession?.id == sessionID else { return }
        guard let refresh = chatFacade.scheduleForegroundChatCatchUp(reason: reason) else { return }
        let contextID = chatFacade.promptContextID
        eagerRefreshTask?.cancel()
        eagerRefreshTask = Task { @MainActor in
            // Disappearing cancels only this scroll adjustment, not the shared snapshot.
            await refresh.value
            guard !Task.isCancelled, chatFacade.promptContextID == contextID,
                   chatFacade.activeChatSessionID == sessionID || chatFacade.selectedSession?.id == sessionID else { return }
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
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, delayedLoadingIndicatorSnapshot.shouldDelay else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showsDelayedLoadingIndicator = true
            }
        }
    }

    private var delayedLoadingIndicatorSnapshot: DelayedLoadingIndicatorSnapshot {
        DelayedLoadingIndicatorSnapshot(
            shouldDelay: chatFacade.isLoadingPresentation && chatFacade.presentationMessages.isEmpty && pendingOutgoingSend == nil
        )
    }

#if canImport(UIKit)
    private func keyboardHeight(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return 0 }
        return max(0, UIScreen.main.bounds.maxY - frame.minY)
    }

#endif

    private var messageBottomPadding: CGFloat { 20 }

    private var timedChatDisplaySnapshot: TimedChatDisplaySnapshot {
        let recoveries = chatFacade.recoveryInputs(sessionID: sessionID)
        let projected = recoveries.isEmpty ? nil : SubmissionTranscriptPresentation.messages(
            canonical: transcriptSuffix(chatSourceMessageCount), recoveries: recoveries)
        let window = OpenCodeChatTranscriptWindowing.window(
            totalCount: projected?.count ?? chatSourceMessageCount,
            requestedCount: projected.map {
                ChatTranscriptContinuity.requestedCount(messages: $0, additional: additionalLeadingMessageCount,
                    initial: initialMessageWindowSize, fallback: fallbackMessageWindowSize)
            } ?? transcriptRequestedMessageCount,
            batchSize: olderMessageWindowSize,
            loadSuffix: { count in projected.map { Array($0.suffix(count)) } ?? transcriptSuffix(count) },
            containsMessageID: transcriptContainsMessage,
            hasDisplayableMessage: hasDisplayableTranscriptContent
        ) { messages in
            !displayedChatItems(for: messages).isEmpty || shouldShowThinking(in: messages)
        }
        let messages = window.messages
        let items = displayedChatItems(for: messages)
        let showsThinking = shouldShowThinking(in: messages)
        let thinkingToolName = activeRunningToolName(in: messages)
        let tailHeight = ChatTranscriptTailSpacing.height(
            showsProgress: showsThinking || thinkingEntryGate.reservesTail(in: thinkingEntryContextID),
            hasStreamingMessage: messages.contains(where: isStreamingMessage)
        )
        let snapshot = ChatDisplaySnapshot(
            messages: messages,
            hiddenMessageCount: window.hiddenMessageCount,
            nextRequestedMessageCount: window.nextRequestedMessageCount,
            hasMoreHistory: chatFacade.hasOlderMessages(forSessionID: sessionID),
            isLoadingHistory: chatFacade.isLoadingOlderMessages(forSessionID: sessionID),
            previousUserMessage: previousUserMessage(before: messages),
            items: items,
            showsThinking: showsThinking,
            thinkingToolName: thinkingToolName,
            tailHeight: tailHeight
        )
        return TimedChatDisplaySnapshot(snapshot: snapshot)
    }

    private var chatSourceMessageCount: Int {
        let syncedCount = directoryStore.syncStore.messageCount(forSessionID: sessionID)
        return syncedCount == 0 ? sessionScopedFallbackMessages.count : syncedCount
    }

    private var sessionScopedFallbackMessages: [OpenCodeMessageEnvelope] {
        chatFacade.messageSource(for: liveSession)
    }

    private var visibleChatMessages: [OpenCodeMessageEnvelope] {
        transcriptSuffix(transcriptRequestedMessageCount)
    }

    private var transcriptRequestedMessageCount: Int {
        let baseCount: Int
        if directoryStore.syncStore.messageCount(forSessionID: sessionID) > 0 {
            baseCount = directoryStore.syncStore.messageCountIncludingLatestUserRounds(
                1,
                fallbackMessageCount: fallbackMessageWindowSize,
                forSessionID: sessionID
            )
        } else {
            baseCount = OpenCodeChatTranscriptWindowing.messageCountIncludingLatestUserRounds(
                1,
                fallbackMessageCount: fallbackMessageWindowSize,
                in: sessionScopedFallbackMessages.map(\.info)
            )
        }
        return min(
            chatSourceMessageCount,
            min(baseCount, initialMessageWindowSize) + additionalLeadingMessageCount
        )
    }

    private func transcriptSuffix(_ count: Int) -> [OpenCodeMessageEnvelope] {
        if directoryStore.syncStore.messageCount(forSessionID: sessionID) > 0 {
            return directoryStore.syncStore.messageEnvelopes(forSessionID: sessionID, suffix: count)
        }

        return Array(sessionScopedFallbackMessages.suffix(count))
    }

    private func transcriptContainsMessage(_ messageID: String) -> Bool {
        if directoryStore.syncStore.messageCount(forSessionID: sessionID) > 0 {
            return directoryStore.syncStore.containsMessage(id: messageID, forSessionID: sessionID)
        }

        return sessionScopedFallbackMessages.contains { $0.id == messageID }
    }

    private func previousUserMessage(
        before visibleMessages: [OpenCodeMessageEnvelope]
    ) -> OpenCodeMessageEnvelope? {
        guard !visibleMessages.contains(where: {
            ($0.info.role ?? "").lowercased() == "user"
        }) else { return nil }

        if directoryStore.syncStore.messageCount(forSessionID: sessionID) > 0 {
            return directoryStore.syncStore.latestUserMessageEnvelope(
                beforeSuffixCount: visibleMessages.count,
                forSessionID: sessionID
            )
        }

        let hiddenCount = max(0, sessionScopedFallbackMessages.count - visibleMessages.count)
        return sessionScopedFallbackMessages.prefix(hiddenCount).last(where: {
            ($0.info.role ?? "").lowercased() == "user"
        })
    }

    private var reasoningPartKeySignature: String {
        visibleChatMessages
            .flatMap(reasoningPartKeys(for:))
            .joined(separator: "|")
    }

    private func displayedChatItems(for messages: [OpenCodeMessageEnvelope]) -> [ChatDisplayItem] {
        var messagesByID: [String: OpenCodeMessageEnvelope] = [:]
        for message in messages {
            messagesByID[message.id] = message
        }
        let key = ChatDisplayItemCacheKey(
            messages: messages.map { message in
                displayItemCacheMessageKey(for: message)
            },
            findPlaceGameID: findPlaceGame(for: sessionID)?.city.id,
            findBugGameID: findBugGame(for: sessionID)?.language.id,
            showsToolCalls: appCustomizationStore.showsToolCalls,
            showsReasoningBlocks: appCustomizationStore.showsReasoningBlocks
        )

        let items = chatDisplayItemCache.items(for: key, messagesByID: messagesByID) {
            makeDisplayItems(from: messages)
        }
        return appendingResponseCaptions(to: items, messages: messages)
    }

    private func timedDisplayedChatItems(for messages: [OpenCodeMessageEnvelope]) -> (items: [ChatDisplayItem], diagnostics: String) {
        let (messagesByID, dictionaryMS) = chatMeasureMS {
            var messagesByID: [String: OpenCodeMessageEnvelope] = [:]
            for message in messages {
                messagesByID[message.id] = message
            }
            return messagesByID
        }
        let (findPlaceGameID, findPlaceMS) = chatMeasureMS { findPlaceGame(for: sessionID)?.city.id }
        let (findBugGameID, findBugMS) = chatMeasureMS { findBugGame(for: sessionID)?.language.id }
        let (messageKeys, keyMessagesMS) = chatMeasureMS {
            messages.map { message in
                displayItemCacheMessageKey(for: message)
            }
        }
        let key = ChatDisplayItemCacheKey(
            messages: messageKeys,
            findPlaceGameID: findPlaceGameID,
            findBugGameID: findBugGameID,
            showsToolCalls: appCustomizationStore.showsToolCalls,
            showsReasoningBlocks: appCustomizationStore.showsReasoningBlocks
        )
        let cacheResult = chatDisplayItemCache.timedItems(for: key, messagesByID: messagesByID) {
            makeDisplayItems(from: messages)
        }
        let diagnostics = String(
            format: "dict %.1fms games %.1f/%.1fms keys %.1fms cache %@ %.1fms",
            dictionaryMS,
            findPlaceMS,
            findBugMS,
            keyMessagesMS,
            cacheResult.mode,
            cacheResult.elapsedMS
        )
        return (appendingResponseCaptions(to: cacheResult.items, messages: messages), diagnostics)
    }

    private func appendingResponseCaptions(to items: [ChatDisplayItem], messages: [OpenCodeMessageEnvelope]) -> [ChatDisplayItem] {
        let displayedMessageIDs = Set(items.compactMap { item -> String? in
            if case let .message(message) = item { return message.id }
            return nil
        })
        var turnMessages = messages
        if let first = messages.first, first.info.role?.lowercased() != "user" {
            // Windowing controls visible rows, not what the turn's copy actions export.
            let loaded = transcriptSuffix(chatSourceMessageCount)
            if let start = loaded.firstIndex(where: { $0.id == first.id }) {
                let prompt = loaded[..<start].lastIndex { $0.info.role?.lowercased() == "user" } ?? 0
                turnMessages = Array(loaded[prompt..<start]) + messages
            }
        }
        let effectiveMessages = turnMessages.map { message in
            isStreamingMessage(message) ? message : chatStore.toolMessageDetails[message.id] ?? message
        }
        let turns = AssistantResponseTurn.project(
            messages: effectiveMessages,
            displayedMessageIDs: displayedMessageIDs,
            isSessionBusy: isSessionBusy
        )
        let captionsByAnchor = Dictionary(uniqueKeysWithValues: turns.map { ($0.anchorMessageID, $0) })
        return items.flatMap { item -> [ChatDisplayItem] in
            guard let turn = captionsByAnchor[item.id] else { return [item] }
            return [item, .responseCaption(turn)]
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
            parts: message.parts.map { displayItemCachePartKey(for: $0, in: message) }
        )
    }

    private func displayItemCachePartKey(for part: OpenCodePart, in message: OpenCodeMessageEnvelope) -> ChatDisplayItemCacheKey.PartKey {
        let samplesText = message.isUnfinishedAssistantMessage || isStreamingMessage(message)
        return ChatDisplayItemCacheKey.PartKey(
            id: part.id,
            type: part.type,
            tool: part.tool,
            textCount: part.text?.utf16.count ?? 0,
            textSampleHash: samplesText ? sampledTextHash(part.text) : 0,
            reason: part.reason,
            filename: part.filename,
            mime: part.mime,
            stateStatus: part.state?.status,
            stateTitle: part.state?.title,
            stateInputSampleHash: samplesText ? sampledTextHash(part.state?.input.map { displayItemCacheInputSignature(from: $0) }) : 0,
            stateOutputCount: part.state?.output?.utf16.count ?? 0,
            stateOutputSampleHash: samplesText ? sampledTextHash(part.state?.output) : 0,
            metadataSessionID: part.state?.metadata?.sessionId,
            metadataFileCount: part.state?.metadata?.files?.count,
            metadataLoadedCount: part.state?.metadata?.loaded?.count,
            metadataTruncated: part.state?.metadata?.truncated,
            metadataRenderer: part.state?.metadata?.renderer,
            metadataSchemaVersion: part.state?.metadata?.schemaVersion,
            metadataPayloadHash: ChatRenderSignatures
                .jsonSignature(from: part.state?.metadata?.payload)
                .chatRenderSampleHash
        )
    }

    private func displayItemCacheInputSignature(from input: OpenCodeToolInput) -> String {
        ChatRenderSignatures.inputSignature(from: input)
    }

    private func sampledTextHash(_ value: String?) -> Int {
        guard let value, !value.isEmpty else { return 0 }
        return value.chatRenderSampleHash
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

    private func thinkingRowListItem(isVisible: Bool, toolName: String?, height: CGFloat) -> some View {
        let snapshot = thinkingRowRenderSnapshot(toolName: toolName)
        return ZStack(alignment: .leading) {
            if isVisible {
                ThinkingRow(
                    animateEntry: snapshot.animateEntry,
                    tint: snapshot.toolName.map { OpenCodeToolActivityAppearance.resolve($0).tint } ?? .secondary,
                    title: snapshot.toolName == nil ? "Thinking" : "Working"
                )
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier(snapshot.toolName == nil ? "chat.thinking.neutral" : "chat.thinking.tool")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .center)
        .transition(.identity)
    }

    private func thinkingRowRenderSnapshot(toolName: String?) -> ThinkingRowRenderSnapshot {
        ThinkingRowRenderSnapshot(animateEntry: true, toolName: toolName)
    }

    private func transcriptRows(for displaySnapshot: ChatDisplaySnapshot) -> [ChatTranscriptRow] {
        var rows: [ChatTranscriptRow] = []
        if isFindPlaceSession {
            rows.append(.weatherAttribution)
        }
        if let previousUserMessage = displaySnapshot.previousUserMessage {
            rows.append(.previousUserContext(previousUserMessage))
        }
        if OpenCodeChatTranscriptWindow.showsHistoryControl(
            hiddenMessageCount: displaySnapshot.hiddenMessageCount,
            hasMoreHistory: displaySnapshot.hasMoreHistory
        ) {
            rows.append(.olderMessages(
                count: displaySnapshot.hiddenMessageCount,
                nextRequestedCount: displaySnapshot.nextRequestedMessageCount,
                hasMoreHistory: displaySnapshot.hasMoreHistory,
                isLoading: displaySnapshot.isLoadingHistory
            ))
        }
        let recoveries = Dictionary(uniqueKeysWithValues: chatFacade.recoveryInputs(sessionID: sessionID).map { ($0.id, $0) })
        rows.append(contentsOf: displaySnapshot.items.map { item in
            if case let .message(message) = item {
                return .displayItem(item, recovery: recoveries[message.id], recoveryStatusVisible: visibleRecoveryStatusIDs.contains(message.id),
                    entry: outgoingEntry(for: message.id))
            }
            return .displayItem(item, recovery: nil, recoveryStatusVisible: false)
        })
        rows.append(.thinking(
            isVisible: displaySnapshot.showsThinking,
            toolName: displaySnapshot.thinkingToolName,
            height: displaySnapshot.tailHeight
        ))
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
        case let .previousUserContext(message):
            previousUserContextRow(for: message)
        case let .olderMessages(count, nextRequestedCount, hasMoreHistory, isLoading):
            Button {
                if count > 0 {
                    additionalLeadingMessageCount += max(
                        0,
                        nextRequestedCount - transcriptRequestedMessageCount
                    )
                } else {
                    Task { @MainActor in
                        let loadedCount = await chatFacade.loadOlderMessages(
                            for: liveSession,
                            count: olderMessageWindowSize
                        )
                        additionalLeadingMessageCount += loadedCount
                    }
                }
            } label: {
                Group {
                    if isLoading {
                        Text("Loading earlier messages...")
                    } else if count > 0, !hasMoreHistory {
                        Text("View older messages (\(count))")
                    } else if count > 0 {
                        Text("View older messages")
                    } else {
                        Text("Load earlier messages")
                    }
                }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(OpenCodePlatformColor.secondaryGroupedBackground, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityIdentifier(ChatScrollTarget.olderMessagesButton)
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
        case let .displayItem(item, recovery, _, entry):
            chatRow(for: item, recovery: recovery, entry: entry)
        case let .thinking(isVisible, toolName, height):
            thinkingRowListItem(isVisible: isVisible, toolName: toolName, height: height)
        case .bottomAnchor:
            bottomAnchorListItem
        }
    }

    private func previousUserContextRow(for message: OpenCodeMessageEnvelope) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("Previous prompt")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(ChatPreviousUserContextPolicy.displayText(for: message))
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityIdentifier("chat.previousPrompt")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(EdgeInsets(top: 12, leading: 60, bottom: 2, trailing: 16))
    }

    @ViewBuilder
    private func chatRow(for item: ChatDisplayItem, recovery: ChatStore.SubmissionRecovery?, entry: ChatOutgoingEntry) -> some View {
        switch item {
        case let .responseCaption(turn):
            ResponseTurnCaption(turn: turn, visibility: responseActionsVisibility) {
                messageChunkContextMenu(for: turn.message)
            }
            .padding(.horizontal, 16)
        case let .message(message):
            VStack(spacing: 0) {
                messageRow(for: message, entry: entry)
                if let input = recovery {
                    SubmissionRecoveryView(input: input, checkStatus: { id in
                        await chatFacade.checkRecoveryStatus(messageID: id, sessionID: sessionID)
                    }, onVisibilityChange: { visible in
                        guard visibleRecoveryStatusIDs.contains(input.id) != visible else { return }
                        if visible { visibleRecoveryStatusIDs.insert(input.id) }
                        else { visibleRecoveryStatusIDs.remove(input.id) }
                    })
                }
            }
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

        return VStack(alignment: .leading, spacing: 10) {
            LargeMessageChunkRow(
                text: snapshot.text,
                allowsTextSelection: snapshot.allowsTextSelection,
                isStreamingTail: snapshot.isStreamingTail,
                animatesStreamingText: snapshot.animatesStreamingText,
                streamingAnimationID: snapshot.streamingAnimationID,
                tableMaximumWidth: snapshot.tableMaximumWidth
            )
                .equatable()

        }
            .transition(.identity)
            .padding(EdgeInsets(top: 0, leading: 16, bottom: snapshot.bottomPadding, trailing: 16))
    }

    private func largeMessageChunkRowRenderSnapshot(for item: LargeMessageChunkDisplayItem) -> LargeMessageChunkRowRenderSnapshot {
        let isStreaming = isStreamingMessage(item.message)
        return LargeMessageChunkRowRenderSnapshot(
            text: item.chunk.text,
            allowsTextSelection: !isStreaming,
            isStreamingTail: isStreaming && item.chunk.isTail,
            animatesStreamingText: shouldAnimateStreamingText,
            streamingAnimationID: item.id,
            bottomPadding: item.chunk.isTail ? 6 : 0,
            tableMaximumWidth: tableMaximumWidth
        )
    }

    @ViewBuilder
    private func messageChunkContextMenu(for message: OpenCodeMessageEnvelope) -> some View {
        let agent = message.info.agent?.nilIfEmpty ?? String(localized: "Default")
        Button {} label: {
            Label("Agent: \(agent)", systemImage: "person.crop.circle")
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

    }

    private func messageRow(for message: OpenCodeMessageEnvelope, entry: ChatOutgoingEntry) -> some View {
        let snapshot = messageRowRenderSnapshot(for: message, entry: entry)
        let entryContextID = thinkingEntryContextID

        return EquatableMessageBubbleHost(
            snapshot: snapshot.bubble,
            imageContent: imageContent,
            imageLoadingStore: chatStore.imageLoadingStore,
            videoStreams: videoStreams,
            videoPlaybackStore: chatStore.videoPlaybackStore,
            resolveTaskSessionID: { part, currentSessionID in
                chatFacade.resolveTaskSessionID(from: part, currentSessionID: currentSessionID)
            }
        ) { part in
            selectedActivityDetail = ActivityDetail(message: message, part: part)
        } onOpenTaskSession: { taskSessionID in
            Task { await presentTaskSession(sessionID: taskSessionID) }
        } onForkMessage: { forkMessage in
            guard !chatFacade.isReadOnly else { return }
            Task { await chatFacade.forkSelectedSession(from: forkMessage.id) }
        } onInspectDebugMessage: { debugMessage in
            selectedMessageDebugPayload = MessageDebugPayload(message: debugMessage)
        } onEntryAnimationStarted: { messageID in
            if !outgoingEntryAnimationStartedMessageIDs.contains(messageID) {
                outgoingEntryAnimationStartedMessageIDs.insert(messageID)
            }
        } onEntryAnimationCompleted: { messageID in
            thinkingEntryGate.release(messageID: messageID, contextID: entryContextID)
        } onEntryAnimationCancelled: { messageID in
            // An unmounted row is no longer rising. Abandon its presentation wait, not the request.
            thinkingEntryGate.release(messageID: messageID, contextID: entryContextID)
        } onToggleReasoningPart: { partID in
            toggleReasoningPart(partID)
        } onToggleContextGroup: { groupID in
            toggleContextGroup(groupID)
        } onShowEarlierActivity: {
            expandedEarlierActivityMessageIDs.insert(message.id)
        } onOpenVisualHTML: { payload in
            selectedVisualHTML = OpenClientVisualHTMLPresentation(payload: payload)
        } onAnswerTextTap: {
            responseActionsVisibility.tappedMessageID = message.id
        }
        .equatable()
        .transition(.identity)
        .padding(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func messageRowRenderSnapshot(for message: OpenCodeMessageEnvelope, entry: ChatOutgoingEntry) -> MessageRowRenderSnapshot {
        MessageRowRenderSnapshot(
            bubble: messageBubbleSnapshot(for: message, entry: entry),
            transition: messageRowTransition(for: message)
        )
    }

    private func messageBubbleSnapshot(for message: OpenCodeMessageEnvelope, entry: ChatOutgoingEntry) -> MessageBubbleSnapshot {
        let isStreaming = isStreamingMessage(message)
        let isRecovery = chatFacade.recoveryInputs(sessionID: sessionID).contains { $0.id == message.id }
        return MessageBubbleSnapshot(
            message: message,
            detailedMessage: isStreaming ? nil : chatStore.toolMessageDetails[message.id],
            currentSessionID: sessionID,
            isStreamingMessage: isStreaming,
            animatesStreamingText: shouldAnimateStreamingText,
            showsToolCalls: appCustomizationStore.showsToolCalls,
            hidesReasoningBlocks: !appCustomizationStore.showsReasoningBlocks || isFunAndGamesSession(sessionID),
            reserveEntryFromComposer: entry.reserves,
            animateEntryFromComposer: entry.animates,
            expandedReasoningPartIDs: expandedReasoningPartIDs,
            expandedContextGroupIDs: Set(expandedContextGroupIDs.filter { $0.hasPrefix("context-\(message.id)-") }),
            showsAllActivity: expandedEarlierActivityMessageIDs.contains(message.id),
            tableMaximumWidth: tableMaximumWidth,
            allowsForkMessage: !chatFacade.isReadOnly && !isRecovery
        )
    }

    private func outgoingEntry(for messageID: String) -> ChatOutgoingEntry {
        ChatOutgoingEntry.presentation(messageID: messageID, preparingID: preparingOutgoingMessageID,
            animatingID: animatingOutgoingMessageID, startedIDs: outgoingEntryAnimationStartedMessageIDs)
    }

    private var tableMaximumWidth: CGFloat? {
        guard chatViewportWidth > 32 else { return nil }
        return chatViewportWidth - 32
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
        let findPlaceGame = findPlaceGame(for: sessionID)
        let findBugGame = findBugGame(for: sessionID)

        func isGameSetupMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
            (findPlaceGame != nil && message.containsText(FindPlaceGame.setupMarker)) ||
                (findBugGame != nil && message.containsText(FindBugGame.setupMarker))
        }

        let hiddenGameSetupMessageIDs = Set(messages.compactMap { message in
            isGameSetupMessage(message) ? message.id : nil
        })

        func gameCompletionDisplayItem(for message: OpenCodeMessageEnvelope) -> ChatDisplayItem? {
            guard message.isAssistantMessage else { return nil }

            if message.containsText(FindPlaceGame.winMarker), let game = findPlaceGame {
                return .findPlaceReveal(game.city)
            }

            if message.containsText(FindBugGame.winMarker), findBugGame != nil {
                return .findBugSolved
            }

            return nil
        }

        func appendUnique(_ item: ChatDisplayItem) {
            guard displayedIDs.insert(item.id).inserted else { return }
            result.append(item)
        }

        for (index, message) in messages.enumerated() {
            if findPlaceGame != nil || findBugGame != nil {
                if hiddenGameSetupMessageIDs.contains(message.id) {
                    continue
                }

                if let gameCompletionItem = gameCompletionDisplayItem(for: message) {
                    appendUnique(gameCompletionItem)
                    continue
                }
            }

            if message.info.isCompactionSummary {
                continue
            }

            if message.parts.contains(where: \.isCompaction) {
                let summary = compactionSummary(for: message, at: index, in: messages)
                appendUnique(.compaction(CompactionDisplayItem(boundaryMessage: message, summaryMessage: summary)))
                continue
            }

            // Completed answers need one text document for selection across former chunk boundaries.
            if isStreamingMessage(message), let chunks = largeMessageChunkCache.chunks(for: message, isStreaming: true) {
                for chunk in chunks {
                    appendUnique(.largeMessageChunk(LargeMessageChunkDisplayItem(message: message, chunk: chunk)))
                }
                continue
            }

            guard shouldDisplayMessageRow(message) else {
                continue
            }

            appendUnique(.message(message))
        }

        return result
    }

    private func hasDisplayableTranscriptContent(_ message: OpenCodeMessageEnvelope) -> Bool {
        if findPlaceGame(for: sessionID) != nil, message.containsText(FindPlaceGame.setupMarker) { return false }
        if findBugGame(for: sessionID) != nil, message.containsText(FindBugGame.setupMarker) { return false }
        if message.info.isCompactionSummary { return false }
        if message.parts.contains(where: \.isCompaction) { return true }
        return shouldDisplayMessageRow(message)
    }

    private func shouldDisplayMessageRow(_ message: OpenCodeMessageEnvelope) -> Bool {
        MessageBubbleMessageVisibilityPolicy.shouldDisplay(
            message,
            showsToolCalls: appCustomizationStore.showsToolCalls,
            showsReasoningBlocks: appCustomizationStore.showsReasoningBlocks && !isFunAndGamesSession(sessionID)
        )
    }

    private func compactionSummary(for boundary: OpenCodeMessageEnvelope, at index: Int, in messages: [OpenCodeMessageEnvelope]) -> OpenCodeMessageEnvelope? {
        if let paired = messages.first(where: { $0.info.isCompactionSummary && $0.info.parentID == boundary.id }) {
            return paired
        }

        return messages.dropFirst(index + 1).first { message in
            message.info.isCompactionSummary
        }
    }

    @discardableResult
    private func startOutgoingBubbleAnimationAndSend() -> Bool {
        if clearConfirmedPromptDraftIfUnchanged() { return false }
        guard pendingOutgoingSend == nil, !chatFacade.hasPendingPromptAdmission(sessionID: sessionID) else { return false }
        let rawDraftText = composerDraftStore.text
        let draftText = rawDraftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftAgentMentions = composerDraftStore.agentMentions
        let draftAttachments = composerStore.draftAttachments
        let hasAttachments = !draftAttachments.isEmpty
        let command = chatFacade.slashCommandInput(from: draftText)

        guard !draftText.isEmpty || hasAttachments else { return false }
        chatFacade.flushBufferedTranscript(reason: "send action")

        if !hasAttachments,
           (chatFacade.shouldOpenForkSheet(forSlashInput: draftText) || chatFacade.slashCommandInput(from: draftText).map({ chatFacade.isForkClientCommand($0.command) }) == true) {
            clearComposerDraft()
            chatFacade.presentForkSessionSheet()
            return false
        }

        let shouldMeterPrompt = chatFacade.shouldMeterPrompts(for: sessionID)
        if shouldMeterPrompt {
            guard chatFacade.reserveUserPromptIfAllowed() else { return false }
        }

        if !hasAttachments,
           chatFacade.slashCommandInput(from: draftText).map({ chatFacade.isCompactClientCommand($0.command) }) == true {
            clearComposerDraft()
            Task { await chatFacade.compactSession(sessionID: sessionID, userVisible: true, meterPrompt: false) }
            return false
        }

        OpenCodeHaptics.impact(.strong)
        chatFacade.markChatBreadcrumb("send tapped", sessionID: sessionID)

        let messageID = OpenCodeIdentifier.message()
        let partID = OpenCodeIdentifier.part()

        let pendingSend = PendingOutgoingSend(
            session: liveSession,
            contextID: chatFacade.promptContextID,
            text: rawDraftText,
            agentMentions: draftAgentMentions,
            attachments: draftAttachments,
            messageID: messageID,
            partID: partID,
            reservedPromptDay: shouldMeterPrompt ? chatFacade.reservedPromptDay : nil
        )

        pendingOutgoingSendTask?.cancel()
        hasSubmittedPendingOutgoingSend = false
        thinkingEntryGate.begin(messageID: messageID, contextID: thinkingEntryContextID,
            alreadyVisible: timedChatDisplaySnapshot.snapshot.showsThinking)
        preparingOutgoingMessageID = messageID
        let optimisticPrompt = OpenCodeAgentMention.trimmingTextAndMentions(text: rawDraftText, mentions: draftAgentMentions)
        chatStore.stageSubmissionPresentation(.local(role: "user", text: optimisticPrompt.text,
            agentMentions: optimisticPrompt.mentions, attachments: draftAttachments, messageID: messageID,
            sessionID: sessionID, partID: partID), sessionID: sessionID,
            canonical: transcriptSuffix(chatSourceMessageCount), attachments: draftAttachments, agentMentions: optimisticPrompt.mentions)
        _ = chatFacade.insertOptimisticUserMessage(optimisticPrompt.text, agentMentions: optimisticPrompt.mentions, attachments: draftAttachments, in: liveSession, messageID: messageID, partID: partID, animated: false)
        pendingOutgoingSend = pendingSend
        scheduleOutgoingEntryAnimation(messageID: messageID)
        clearComposerDraft()
        chatFacade.clearDraftAttachments()
        let requestRevision = promptDraftRevision
        let requestResetToken = composerStore.resetToken
        requestBottomReadjustment()

        pendingOutgoingSendTask = Task { @MainActor in
            defer { chatStore.discardStagedSubmissionPresentation(messageID: messageID) }
            try? await Task.sleep(for: .milliseconds(outgoingRequestDelayMS))
            guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID,
                  chatFacade.promptContextID == pendingSend.contextID,
                   chatFacade.selectedSession?.id == pendingSend.session.id else { return }

            hasSubmittedPendingOutgoingSend = true
            let didSend: Bool
            if let command, !chatFacade.isCompactClientCommand(command.command), !chatFacade.isForkClientCommand(command.command) {
                didSend = await chatFacade.sendCommand(command.command, sessionID: pendingSend.session.id, userVisible: true,
                    meterPrompt: false, restoreDraftOnFailure: false, arguments: command.arguments, attachments: pendingSend.attachments,
                    messageID: pendingSend.messageID, agentMentions: pendingSend.agentMentions, reservedPromptDay: pendingSend.reservedPromptDay)
            } else {
                didSend = await chatFacade.sendMessage(
                    pendingSend.text,
                    agentMentions: pendingSend.agentMentions,
                    attachments: pendingSend.attachments,
                    in: pendingSend.session,
                    userVisible: true,
                    messageID: pendingSend.messageID,
                    partID: pendingSend.partID,
                    appendOptimisticMessage: false,
                    meterPrompt: false,
                    reservedPromptDay: pendingSend.reservedPromptDay
                )
            }
            guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID,
                  chatFacade.promptContextID == pendingSend.contextID,
                   chatFacade.selectedSession?.id == pendingSend.session.id else { return }
            let phase = pendingSend.messageID.flatMap { chatFacade.promptAdmissionPhase(messageID: $0, sessionID: pendingSend.session.id) }
            if !didSend, phase == .rejected || phase == nil {
                conversationController.submissionDidNotStart()
            }
            if !didSend, phase == nil {
                // This ID never entered admission (for example another window acquired the lock).
                if let messageID = pendingSend.messageID {
                    chatFacade.removeOptimisticUserMessage(messageID: messageID, sessionID: pendingSend.session.id)
                }
                chatFacade.refundReservedPrompt(on: pendingSend.reservedPromptDay)
            }
            if !didSend, phase == .rejected || phase == .uncertain || phase == nil,
               promptDraftRevision == requestRevision, composerStore.resetToken == requestResetToken,
               composerDraftStore.text.isEmpty, composerDraftStore.agentMentions.isEmpty, composerStore.draftAttachments.isEmpty {
                restoreComposerDraft(pendingSend.text)
                composerDraftStore.agentMentions = pendingSend.agentMentions
                chatFacade.setDraftAgentMentions(pendingSend.agentMentions, forSessionID: pendingSend.session.id)
                chatFacade.addDraftAttachments(pendingSend.attachments)
                if phase == .uncertain, let messageID = pendingSend.messageID {
                    promptRetryDraft = OpenCodeV2RetryDraft(messageID: messageID, sessionID: pendingSend.session.id,
                        contextID: pendingSend.contextID, revision: promptDraftRevision, resetToken: composerStore.resetToken,
                        text: pendingSend.text, mentions: pendingSend.agentMentions, attachments: pendingSend.attachments)
                    clearConfirmedPromptDraftIfUnchanged()
                }
            }
            guard !Task.isCancelled, pendingOutgoingSend?.messageID == pendingSend.messageID else { return }
            pendingOutgoingSend = nil
            hasSubmittedPendingOutgoingSend = false
        }
        return true
    }

    private func scheduleOutgoingEntryAnimation(messageID: String) {
        let entryContextID = thinkingEntryContextID
        outgoingEntryResetTask?.cancel()
        animatingOutgoingMessageID = nil

        outgoingEntryResetTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            animatingOutgoingMessageID = messageID

            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            if !outgoingEntryAnimationStartedMessageIDs.contains(messageID) {
                // The row never mounted (for example while browsing older history).
                thinkingEntryGate.release(messageID: messageID, contextID: entryContextID)
            }
            animatingOutgoingMessageID = nil
            if preparingOutgoingMessageID == messageID {
                preparingOutgoingMessageID = nil
            }
            outgoingEntryAnimationStartedMessageIDs.remove(messageID)
        }
    }

    private func stopComposerAction() {
        thinkingEntryGate.cancel()
        chatFacade.flushBufferedTranscript(reason: "stop action")

        if let pendingSend = pendingOutgoingSend {
            let submittedTask = hasSubmittedPendingOutgoingSend ? pendingOutgoingSendTask : nil
            if submittedTask == nil {
                pendingOutgoingSendTask?.cancel()
            }
            pendingOutgoingSendTask = nil
            pendingOutgoingSend = nil
            hasSubmittedPendingOutgoingSend = false
            outgoingEntryResetTask?.cancel()
            preparingOutgoingMessageID = nil
            animatingOutgoingMessageID = nil
            if let messageID = pendingSend.messageID {
                outgoingEntryAnimationStartedMessageIDs.remove(messageID)
            }

            if let submittedTask {
                Task {
                    await submittedTask.value
                    guard chatFacade.promptContextID == pendingSend.contextID else { return }
                    await chatFacade.stopSession(pendingSend.session)
                }
            } else {
                guard chatFacade.promptContextID == pendingSend.contextID else { return }
                if let messageID = pendingSend.messageID {
                    chatFacade.removeOptimisticUserMessage(messageID: messageID, sessionID: sessionID)
                }
                if composerDraftStore.text.isEmpty, composerDraftStore.agentMentions.isEmpty, composerStore.draftAttachments.isEmpty {
                    restoreComposerDraft(pendingSend.text)
                    composerDraftStore.agentMentions = pendingSend.agentMentions
                    chatFacade.setDraftAgentMentions(pendingSend.agentMentions, forSessionID: pendingSend.session.id)
                    chatFacade.addDraftAttachments(pendingSend.attachments)
                }
                chatFacade.refundReservedPrompt(on: pendingSend.reservedPromptDay)
            }
            return
        }

        Task { await chatFacade.stopSession(liveSession) }
    }

    private var thinkingEntryContextID: String { "\(sessionID)|\(chatFacade.promptContextID)" }

    private var thinkingPendingMessageID: String? {
        var pendingID = pendingOutgoingSend?.messageID ?? chatFacade.recoveryInputs(sessionID: sessionID)
            .last(where: { $0.phase == .submitting })?.id
        if let id = pendingID, let phase = chatFacade.promptAdmissionPhase(messageID: id, sessionID: sessionID),
           phase == .cancelled || phase == .rejected || phase == .uncertain { pendingID = nil }
        return pendingID
    }

    private func shouldShowThinking(in messages: [OpenCodeMessageEnvelope]) -> Bool {
        guard !thinkingEntryGate.blocksThinking(in: thinkingEntryContextID) else { return false }
        return ChatThinkingPresentation.shouldShow(messages: messages, pendingMessageID: thinkingPendingMessageID,
            isBusy: isSessionBusy, showsToolCalls: appCustomizationStore.showsToolCalls,
            showsReasoningBlocks: appCustomizationStore.showsReasoningBlocks && !isFunAndGamesSession(sessionID),
            runningToolName: activeRunningToolName(in: messages))
    }

    private func activeRunningToolName(in messages: [OpenCodeMessageEnvelope]) -> String? {
        ChatThinkingPresentation.summaryToolName(messages: messages, pendingMessageID: thinkingPendingMessageID,
            isBusy: isSessionBusy, showsToolCalls: appCustomizationStore.showsToolCalls)
    }

    private func isStreamingMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
        guard isSessionBusy else { return false }
        guard (message.info.role ?? "").lowercased() == "assistant" else { return false }
        guard message.info.time?.completed == nil else { return false }
        return lastSessionMessageID == message.id
    }

    private var latestSessionMessage: OpenCodeMessageEnvelope? {
        if directoryStore.syncStore.messageCount(forSessionID: sessionID) > 0 {
            return directoryStore.syncStore.messageEnvelopes(forSessionID: sessionID, suffix: 1).last
        }
        return sessionScopedFallbackMessages.last
    }

    private var activeSessionTint: Color {
        let agent: String?
        if let latestSessionMessage,
           (latestSessionMessage.info.role ?? "").lowercased() == "assistant",
           latestSessionMessage.info.time?.completed == nil {
            agent = latestSessionMessage.info.agent
        } else {
            agent = nil
        }
        return OpenCodeActivityTint.color(forAgent: agent)
    }

    private var lastSessionMessageID: String? {
        latestSessionMessage?.id
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
        if connectionStore.backendMode == .appleIntelligence {
            ToolbarItem(placement: .opencodeLeading) {
                Button("Home") {
                    chatFacade.leaveAppleIntelligenceSession()
                }
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    OpenCodeClipboard.copy(appleIntelligenceTranscript())
                    copiedTranscript = true
                } label: {
                    Image(systemName: copiedTranscript ? "checkmark.doc" : "doc.on.doc")
                }
                .accessibilityLabel(copiedTranscript ? LocalizedStringResource("Copied Transcript") : LocalizedStringResource("Copy Transcript"))
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    chatPresentationStore.isShowingAppleIntelligenceInstructionsSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Model Instructions")
            }
        } else {
            let headerSnapshot = chatHeaderSnapshot
            if headerSnapshot.isChildSession, let onDismissChildSession {
                let childToolbarSnapshot = chatFacade.childSessionToolbarSnapshot(for: liveSession)
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Close", action: onDismissChildSession)
                        .accessibilityLabel("Close subagent thread")
                }

                ToolbarItem(placement: .principal) {
                    ChildSessionSheetNavigationTitle(
                        title: headerSnapshot.navigationTitle,
                        agentTitle: childToolbarSnapshot.agentTitle,
                        modelTitle: childToolbarSnapshot.modelTitle
                    )
                }

                ToolbarItem(placement: .opencodeTrailing) {
                    SessionContextUsageToolbarButton(metrics: contextMetrics) {
                        showingContextMetrics = true
                    }
                    .opencodeToolbarGlassID("context-usage-toolbar", in: toolbarGlassNamespace)
                }
            } else {
                standardChatToolbar(
                    headerSnapshot: headerSnapshot,
                    toolbarSnapshot: chatFacade.toolbarSnapshot(for: liveSession)
                )
            }
        }
    }

    @ToolbarContentBuilder
    private func standardChatToolbar(
        headerSnapshot: ChatFacade.ChatSessionHeaderSnapshot,
        toolbarSnapshot: ChatFacade.ToolbarSnapshot
    ) -> some ToolbarContent {
        if headerSnapshot.isChildSession {
            ToolbarItem(placement: .opencodeLeading) {
                if let parentSession = headerSnapshot.parentSession {
                    Button("Back") {
                        Task { await chatFacade.selectSession(parentSession) }
                    }
                }
            }
        }

        #if os(iOS) && !targetEnvironment(macCatalyst)
        let headerBudget = ChatToolbarWidthBudget(containerWidth: chatViewportWidth)
        let isPhoneLandscape = UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
        let assistantHeaderWidth = !chatFacade.isReadOnly && toolbarSnapshot.isLoading
            ? headerBudget.assistantHeaderWithTrailingItem
            : headerBudget.assistantHeader
        let headerWidth: CGFloat = if usesAssistantHeaderLayout, UIDevice.current.userInterfaceIdiom == .phone {
            isPhoneLandscape
                ? min(360, assistantHeaderWidth)
                : assistantHeaderWidth
        } else if usesAssistantHeaderLayout {
            min(220, max(92, chatViewportWidth - 208))
        } else {
            headerBudget.header
        }
        ToolbarItem(placement: usesAssistantHeaderLayout && UIDevice.current.userInterfaceIdiom == .phone && !isPhoneLandscape
            ? .topBarTrailing : .topBarLeading) {
            HStack(spacing: headerBudget.spacing) {
                ChatHeaderMenu(facade: chatFacade, session: liveSession,
                    containerWidth: chatViewportWidth, containerHeight: chatViewportHeight,
                    glassNamespace: toolbarGlassNamespace,
                    maximumWidth: headerWidth - 44 - headerBudget.spacing,
                    onPresentationChange: { isPresented in
                        if isPresented {
                            pinnedHeaderUsesAssistantLayout = usesAssistantComposerLayout
                        } else {
                            pinnedHeaderUsesAssistantLayout = nil
                        }
                    })

                SessionContextUsageToolbarButton(metrics: contextMetrics, hitTargetSize: 44) {
                    showingContextMetrics = true
                }
                .opencodeToolbarGlassID("context-usage-toolbar", in: toolbarGlassNamespace)
                .accessibilityIdentifier("chat.toolbar.context")
            }
        }
        #else
        ToolbarItem(placement: .principal) {
            ChatNavigationTitle(snapshot: headerSnapshot)
                .frame(maxWidth: 300, alignment: .leading)
        }
        #endif

        #if !os(iOS) || targetEnvironment(macCatalyst)
        if chatFacade.isReadOnly {
            ToolbarItem(placement: .opencodeTrailing) {
                SessionContextUsageToolbarButton(metrics: contextMetrics) {
                    showingContextMetrics = true
                }
                .opencodeToolbarGlassID("context-usage-toolbar", in: toolbarGlassNamespace)
            }
        }
        #endif
        if !chatFacade.isReadOnly, toolbarSnapshot.isLoading {
            ToolbarItem(placement: .opencodeTrailing) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .opencodeToolbarGlassID("chat-toolbar-loading", in: toolbarGlassNamespace)
                    .accessibilityLabel("Loading chat controls")
            }
        } else if !chatFacade.isReadOnly {
            #if !targetEnvironment(macCatalyst)
            if !usesAssistantHeaderLayout {
                #if os(macOS)
                if toolbarSnapshot.showsAgentMenu {
                    ToolbarItem(placement: .opencodeTrailing) {
                        AgentToolbarMenu(
                            title: toolbarSnapshot.agentTitle,
                            agents: toolbarSnapshot.selectableAgents,
                            glassNamespace: toolbarGlassNamespace,
                            onSelectAgent: { chatFacade.selectAgent(named: $0, for: liveSession) }
                        )
                    }
                }
                #endif

                #if os(iOS)
                let modelMaximumWidth: CGFloat? = ChatToolbarWidthBudget(containerWidth: chatViewportWidth).model
                #else
                let modelMaximumWidth: CGFloat? = nil
                #endif
                ToolbarItem(placement: .opencodeTrailing) {
                    let modelMenu = ModelToolbarMenu(
                        modelTitle: toolbarSnapshot.modelTitle,
                        modelReference: toolbarSnapshot.displayedModelReference,
                        providerName: toolbarSnapshot.modelProviderName,
                        providerGroups: toolbarSnapshot.providerGroups,
                        reasoningVariants: toolbarSnapshot.reasoningVariants,
                        reasoningTitle: toolbarSnapshot.reasoningTitle,
                        glassNamespace: toolbarGlassNamespace,
                        onSelectModel: { chatFacade.selectModel($0, for: liveSession) },
                        onSelectReasoningVariant: { chatFacade.selectReasoningVariant($0, for: liveSession) },
                        maximumWidth: modelMaximumWidth
                    )
                    #if os(macOS)
                    HStack(spacing: 12) {
                        SessionContextUsageToolbarButton(metrics: contextMetrics) {
                            showingContextMetrics = true
                        }
                        .opencodeToolbarGlassID("context-usage-toolbar", in: toolbarGlassNamespace)
                        .accessibilityIdentifier("chat.toolbar.context")

                        modelMenu
                    }
                    #else
                    modelMenu
                    #endif
                }
            }
            #endif

            #if os(iOS)
            if (showsIPadBrowserToolbarButton && browser.activeProjectID != nil)
                || (supportsMultipleWindows && !isDedicatedWindow) {
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if showsIPadBrowserToolbarButton && browser.activeProjectID != nil {
                        Button(action: presentBrowser) {
                            Image(systemName: "globe")
                                .frame(minWidth: 44, minHeight: 44)
                                .opencodeToolbarGlassID("open-browser-toolbar", in: toolbarGlassNamespace)
                        }
                        .accessibilityLabel("Open Browser")
                        .accessibilityIdentifier("browser.open.chatToolbar")
                    }

                    if supportsMultipleWindows && !isDedicatedWindow {
                        Button {
                            openWindow(
                                id: OpenClientChatWindowRoute.sceneID,
                                value: chatFacade.windowRoute(for: liveSession)
                            )
                        } label: {
                            Image(systemName: "macwindow.badge.plus")
                                .frame(minWidth: 44, minHeight: 44)
                                .opencodeToolbarGlassID("open-chat-window-toolbar", in: toolbarGlassNamespace)
                        }
                        .accessibilityLabel("Open Chat in New Window")
                        .accessibilityIdentifier("chat.toolbar.openWindow")
                    }
                }
            }
            #endif
        }
    }

    @MainActor
    private func presentTaskSession(sessionID: String) async {
        if chatFacade.isV2Connection {
            await chatFacade.openSession(sessionID: sessionID)
            return
        }
        guard let session = await chatFacade.sessionForPresentation(sessionID: sessionID),
              let childChat = chatFacade.childPresentation(for: session) else { return }
        taskSessionDetent = .medium
        presentedTaskChat = childChat
        presentedTaskSession = session
    }

    private func restoreActiveSessionAfterTaskSheet() {
        presentedTaskChat?.windowContext?.close()
        presentedTaskChat = nil
        chatFacade.setActiveChatSessionID(sessionID)
    }

    private func appleIntelligenceTranscript() -> String {
        chatFacade.presentationMessages.map { message in
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

    private func toggleReasoningPart(_ id: String) {
        if expandedReasoningPartIDs.contains(id) {
            expandedReasoningPartIDs.remove(id)
        } else {
            expandedReasoningPartIDs.insert(id)
        }
        requestBottomReadjustmentIfPinned()
    }

    private func toggleContextGroup(_ id: String) {
        if expandedContextGroupIDs.contains(id) {
            expandedContextGroupIDs.remove(id)
        } else {
            expandedContextGroupIDs.insert(id)
        }
        requestBottomReadjustmentIfPinned()
    }

    private var transcriptContentInvalidationToken: String {
        let reasoning = expandedReasoningPartIDs.sorted().joined(separator: "|")
        let context = expandedContextGroupIDs.sorted().joined(separator: "|")
        let activity = expandedEarlierActivityMessageIDs.sorted().joined(separator: "|")
        let tools = appCustomizationStore.showsToolCalls
        let reasoningBlocks = appCustomizationStore.showsReasoningBlocks
        return "reasoning:\(reasoning)#context:\(context)#activity:\(activity)#tools:\(tools)#reasoningBlocks:\(reasoningBlocks)"
    }

    private func pruneExpandedReasoningParts() {
        guard !expandedReasoningPartIDs.isEmpty else { return }
        let activeIDs = Set(visibleChatMessages.flatMap(reasoningPartKeys(for:)))
        expandedReasoningPartIDs.formIntersection(activeIDs)
    }

    private func reasoningPartKeys(for message: OpenCodeMessageEnvelope) -> [String] {
        message.parts.enumerated().compactMap { index, part in
            guard isReasoningPart(part), part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }

            if let partID = part.id {
                return "\(message.id)-reasoning-\(partID)"
            }

            return "\(message.id)-reasoning-\(index)"
        }
    }

    private func isReasoningPart(_ part: OpenCodePart) -> Bool {
        if part.type == "reasoning" {
            return true
        }

        let lowerReason = part.reason?.lowercased() ?? ""
        return part.type == "text" && lowerReason.contains("reasoning")
    }
}

private struct ChatNavigationTitle: View {
    let snapshot: ChatFacade.ChatSessionHeaderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: snapshot.isChildSession ? 1 : 0) {
            if snapshot.isChildSession {
                Text(snapshot.parentTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ShimmeringChatNavigationTitle(text: snapshot.navigationTitle, active: snapshot.shimmersNavigationTitle)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.navigationTitle)
    }
}

private struct ChildSessionSheetNavigationTitle: View {
    let title: String
    let agentTitle: String
    let modelTitle: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text("\(agentTitle.capitalized) · \(modelTitle)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("Agent \(agentTitle), model \(modelTitle)")
    }
}

private struct ShimmeringChatNavigationTitle: View {
    let text: String
    let active: Bool

    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(active ? Color.primary.opacity(0.72) : Color.primary)
            .lineLimit(1)
            .overlay {
                if active {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [Color.clear, Color.white.opacity(0.85), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: max(geometry.size.width * 0.8, 36))
                        .offset(x: geometry.size.width * phase)
                        .blendMode(.plusLighter)
                    }
                    .mask(
                        Text(text)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    )
                    .allowsHitTesting(false)
                }
            }
            .onAppear { updateAnimation(active: active) }
            .onChange(of: active) { _, isActive in updateAnimation(active: isActive) }
    }

    private func updateAnimation(active: Bool) {
        guard active else {
            phase = -1
            return
        }
        phase = -1
        withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
            phase = 1.35
        }
    }
}

private struct ChatStatusBarStateShimmer: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                tint.opacity(0.14)

                if reduceMotion {
                    tint.opacity(0.06)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                        let width = max(geometry.size.width, 1)
                        let bandWidth = min(max(width * 0.42, 120), 260)
                        let duration = max(1.4, min(3.0, Double(width * 1.8 / 900)))
                        let phase = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: duration) / duration
                        let travel = width + bandWidth * 2
                        let centerX = -bandWidth + CGFloat(phase) * travel

                        LinearGradient(
                            stops: [
                                .init(color: tint.opacity(0), location: 0),
                                .init(color: tint.opacity(0.18), location: 0.28),
                                .init(color: tint.opacity(0.38), location: 0.5),
                                .init(color: tint.opacity(0.18), location: 0.72),
                                .init(color: tint.opacity(0), location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth, height: geometry.size.height)
                        .position(x: centerX, y: geometry.size.height / 2)
                        .blendMode(.plusLighter)
                    }
                }
            }
        }
        .frame(height: 78)
        .mask(
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .compositingGroup()
    }
}

struct SessionContextUsageToolbarButton: View {
    let context: OpenCodeSessionContextSnapshot?
    let hitTargetSize: CGFloat
    let action: () -> Void

    init(metrics: OpenCodeSessionContextMetrics, hitTargetSize: CGFloat = 32, action: @escaping () -> Void) {
        context = metrics.context
        self.hitTargetSize = hitTargetSize
        self.action = action
    }

    init(context: OpenCodeSessionContextSnapshot?, hitTargetSize: CGFloat = 32, action: @escaping () -> Void) {
        self.context = context
        self.hitTargetSize = hitTargetSize
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ContextUsageRing(progress: progress, tint: .primary, lineWidth: 3.25)
                .frame(width: 19, height: 19)
                .frame(width: hitTargetSize, height: hitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("View context usage")
        .accessibilityValue(accessibilityValue)
    }

    private var progress: Double {
        guard let usage = context?.usage else { return 0 }
        return min(1, max(0, Double(usage) / 100))
    }

    private var accessibilityValue: String {
        guard let context else { return String(localized: "No token usage yet") }
        if let usage = context.usage {
            return String(localized: "\(usage)% used, \(context.total) tokens")
        }
        return String(localized: "\(context.total) tokens")
    }
}

private struct ContextUsageRing: View {
    let progress: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct SessionContextMetricsSheet: View {
    let session: OpenCodeSession
    let metrics: OpenCodeSessionContextMetrics

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                summaryHeader
            }

            Section("Context") {
                if let context = metrics.context {
                    LabeledContent("Provider", value: context.providerLabel)
                    LabeledContent("Model", value: context.modelLabel)
                    LabeledContent("Context Limit", value: number(context.limit))
                    LabeledContent("Total Tokens", value: number(context.total))
                    LabeledContent("Usage", value: percent(context.usage))
                    LabeledContent("Input Tokens", value: number(context.input))
                    LabeledContent("Output Tokens", value: number(context.output))
                    LabeledContent("Reasoning Tokens", value: number(context.reasoning))
                    LabeledContent("Cache Tokens", value: "\(number(context.cacheRead)) / \(number(context.cacheWrite))")
                    LabeledContent("Last Activity", value: time(context.messageCreatedAt))
                } else {
                    Text("Context usage appears after the model returns token metrics for this chat.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Session") {
                LabeledContent("Session", value: session.title?.nilIfEmpty ?? session.id)
                LabeledContent("Messages", value: number(metrics.messageCount))
                LabeledContent("User Messages", value: number(metrics.userMessageCount))
                LabeledContent("Assistant Messages", value: number(metrics.assistantMessageCount))
                LabeledContent("Total Cost", value: currency(metrics.totalCost))
            }

            if !metrics.breakdown.isEmpty {
                Section("Estimated Input Breakdown") {
                    ContextBreakdownBar(segments: metrics.breakdown)
                        .frame(height: 10)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                    ForEach(metrics.breakdown) { segment in
                        LabeledContent {
                            Text("\(segment.percent.formatted(.number.precision(.fractionLength(0 ... 1))))%")
                                .foregroundStyle(.secondary)
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(breakdownColor(for: segment.kind))
                                    .frame(width: 10, height: 10)
                                Text(breakdownLabel(for: segment.kind))
                            }
                        }
                    }
                }
            }

            if let systemPrompt = metrics.systemPrompt {
                Section("System Prompt") {
                    Text(systemPrompt)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Context")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 16) {
            ContextUsageRing(progress: progress, tint: usageTint, lineWidth: 6)
                .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                if let context = metrics.context {
                    Text(percent(context.usage))
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(number(context.total)) tokens used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(currency(metrics.totalCost))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No token usage yet")
                        .font(.headline)
                    Text(currency(metrics.totalCost))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var progress: Double {
        guard let usage = metrics.context?.usage else { return 0 }
        return min(1, max(0, Double(usage) / 100))
    }

    private var usageTint: Color {
        guard let usage = metrics.context?.usage else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .blue
    }

    private func number(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    private func percent(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value.formatted(.number))%"
    }

    private func currency(_ value: Double) -> String {
        let fractionDigits = value > 0 && value < 0.01 ? 4 : 2
        return "$" + String(format: "%.*f", fractionDigits, value)
    }

    private func time(_ value: Double?) -> String {
        guard let value else { return "—" }
        let seconds = value > 100_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds).formatted(date: .abbreviated, time: .shortened)
    }

    private func breakdownLabel(for kind: OpenCodeSessionContextBreakdownSegment.Kind) -> LocalizedStringResource {
        switch kind {
        case .system:
            return "System"
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        case .tool:
            return "Tool Calls"
        case .other:
            return "Other"
        }
    }

    private func breakdownColor(for kind: OpenCodeSessionContextBreakdownSegment.Kind) -> Color {
        switch kind {
        case .system:
            return .cyan
        case .user:
            return .green
        case .assistant:
            return .indigo
        case .tool:
            return .orange
        case .other:
            return .secondary
        }
    }
}

private struct ContextBreakdownBar: View {
    let segments: [OpenCodeSessionContextBreakdownSegment]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(color(for: segment.kind))
                        .frame(width: proxy.size.width * CGFloat(max(0, segment.percent) / 100))
                }
            }
        }
        .background(Color.secondary.opacity(0.16), in: Capsule())
        .clipShape(Capsule())
    }

    private func color(for kind: OpenCodeSessionContextBreakdownSegment.Kind) -> Color {
        switch kind {
        case .system:
            return .cyan
        case .user:
            return .green
        case .assistant:
            return .indigo
        case .tool:
            return .orange
        case .other:
            return .secondary
        }
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
                if isStreaming {
                    Text("Compacting session")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text("Session compacted")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
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
        .accessibilityLabel(accessibilityTitle)
    }

    private var accessibilityTitle: LocalizedStringResource {
        if isStreaming { return "Compacting session" }
        if hasSummary { return "Session compacted. View context." }
        return "Session compacted"
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
                Button(copiedSummary ? LocalizedStringResource("Copied") : LocalizedStringResource("Copy")) {
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
                        labeledValue("Status", weather.didUseWeatherKit ? String(localized: "Success") : String(localized: "Fallback"))
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
                        if let errorDescription = weather.errorDescription {
                            Text(errorDescription)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text("WeatherKit request succeeded.")
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
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
                Button(copiedDebugText ? LocalizedStringResource("Copied") : LocalizedStringResource("Copy")) {
                    OpenCodeClipboard.copy(debugText)
                    copiedDebugText = true
                }
                .disabled(debugText.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func labeledValue(_ label: LocalizedStringResource, _ value: String) -> some View {
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
            String(localized: "City: \(game.city.name), \(game.city.country)"),
            String(localized: "Coordinates: \(game.city.latitude), \(game.city.longitude)"),
            String(localized: "Status: \(weather?.didUseWeatherKit == true ? String(localized: "Success") : String(localized: "Fallback/Unavailable"))"),
            String(localized: "Provider: \(weather?.provider ?? String(localized: "unknown"))"),
            String(localized: "Requested: \(weather?.requestedAt.formatted(date: .abbreviated, time: .standard) ?? String(localized: "unknown"))"),
            String(localized: "Error Domain: \(weather?.errorDomain ?? String(localized: "none"))"),
            String(localized: "Error Code: \(weather?.errorCode.map(String.init) ?? String(localized: "none"))"),
            String(localized: "Clue: \(weather?.text ?? String(localized: "unknown"))"),
            String(localized: "Diagnostic: \(weather?.errorDescription ?? String(localized: "WeatherKit request succeeded."))")
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
                Button(copiedJSON ? LocalizedStringResource("Copied") : LocalizedStringResource("Copy")) {
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
class ChatTranscriptCollection: UICollectionView {
    var didLayout: (() -> Void)?
    var didDetach: (() -> Void)?
    var didAttach: (() -> Void)?
#if DEBUG
    var keyboardProbe: ChatKeyboardFrameProbe?
#endif

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { didAttach?() }
#if DEBUG
        guard ChatKeyboardFrameProbe.enabled else { return }
        if window != nil {
            if keyboardProbe == nil { keyboardProbe = ChatKeyboardFrameProbe(collection: self) }
        } else {
            keyboardProbe?.stop()
            keyboardProbe = nil
        }
#endif
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            didDetach?()
            #if targetEnvironment(macCatalyst)
            if window != nil, let container = superview, !container.isHidden, container.alpha > 0,
               alpha > 0, !UIAccessibility.isReduceMotionEnabled,
               let snapshot = snapshotView(afterScreenUpdates: false) {
                snapshot.frame = convert(bounds, to: container)
                snapshot.isUserInteractionEnabled = false
                snapshot.accessibilityElementsHidden = true
                container.addSubview(snapshot)
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                    snapshot.alpha = 0
                } completion: { _ in snapshot.removeFromSuperview() }
            }
            #endif
        }
        super.willMove(toWindow: newWindow)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        didLayout?()
    }
}

#if DEBUG
@MainActor
final class ChatKeyboardFrameProbe: NSObject {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_KEYBOARD_CONTINUITY"] == "1" }
    static var frames: [[String: Double]] = []
    private weak var collection: UICollectionView?
    private var link: CADisplayLink?
    private var hidden = true
    var expectedInset: CGFloat = 0
    var requestedHeight: CGFloat = 0

    init(collection: UICollectionView) {
        self.collection = collection
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(willShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didHide), name: UIResponder.keyboardDidHideNotification, object: nil)
        link = CADisplayLink(target: self, selector: #selector(sample))
        link?.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func willShow() { hidden = false }
    @objc private func didHide() { hidden = true }

    @objc private func sample() {
        guard let collection, let window = collection.window else { return }
        let frame = collection.convert(collection.bounds, to: window)
        Self.frames.append(["time": ProcessInfo.processInfo.systemUptime, "hidden": hidden ? 1 : 0,
            "requestedKeyboard": Double(requestedHeight), "expectedInset": Double(expectedInset),
            "inset": Double(collection.contentInset.bottom), "adjustedInset": Double(collection.adjustedContentInset.bottom),
            "offset": Double(collection.contentOffset.y), "height": Double(collection.bounds.height),
            "minY": Double(frame.minY), "maxY": Double(frame.maxY),
            "contentHeight": Double(collection.contentSize.height),
            "scrolling": collection.isTracking || collection.isDragging || collection.isDecelerating ? 1 : 0])
        if Self.frames.count > 720 { Self.frames.removeFirst() }
    }
}
#endif

private struct ChatTranscriptCollectionView<RowContent: View>: UIViewRepresentable {
    let rows: [ChatTranscriptRow]
    @Binding var isAtBottom: Bool
    let scrollController: ChatTranscriptScrollController
    let bottomScrollToken: Int
    let animatedBottomScrollToken: Int
    let bottomContentInset: CGFloat
    let bottomContentInsetAnimationToken: Int
    var keyboardHeight: CGFloat = 0
    var keyboardTransition: ChatKeyboardTransition? = nil
    let bottomRefreshThreshold: CGFloat
    let bottomRefreshProgress: CGFloat
    let showsBottomRefreshIndicator: Bool
    let bottomRefreshColorIsActive: Bool
    let bottomRefreshHeight: CGFloat
    let isRefreshing: Bool
    let isStreaming: Bool
    var hasInitialContent = true
    let contentInvalidationToken: String
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
            isStreaming: isStreaming,
            bottomContentInsetAnimationToken: bottomContentInsetAnimationToken,
            contentInvalidationToken: contentInvalidationToken,
            animatedRowIDs: animatedRowIDs,
            onBottomPullChanged: onBottomPullChanged,
            onBottomPullEnded: onBottomPullEnded,
            rowContent: rowContent
        )
    }

    func makeUIView(context: Context) -> UICollectionView {
        let collectionView = ChatTranscriptCollection(frame: .zero, collectionViewLayout: Self.makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.keyboardDismissMode = .interactive
        Self.configureSoftScrollEdgeEffects(for: collectionView)
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(ChatTranscriptHostingCell.self, forCellWithReuseIdentifier: ChatTranscriptHostingCell.reuseIdentifier)
        context.coordinator.collectionView = collectionView
        context.coordinator.prepareInitialPresentation(in: collectionView)
        collectionView.didDetach = { [weak coordinator = context.coordinator] in
            coordinator?.cancelInitialPresentation()
        }
        collectionView.didAttach = { [weak collectionView, weak coordinator = context.coordinator] in
            guard let collectionView else { return }
            coordinator?.collectionViewDidAttach(collectionView)
        }
        collectionView.didLayout = { [weak collectionView, weak coordinator = context.coordinator] in
            guard let collectionView else { return }
            coordinator?.collectionViewDidLayout(collectionView)
        }
        scrollController.attach(collectionView)
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        update(collectionView, coordinator: context.coordinator)
    }

    func update(_ collectionView: UICollectionView, coordinator: Coordinator) {
        guard Set(rows.map(\.id)).count == rows.count else { return }
        coordinator.submitViewportUpdate(bottomContentInset, animationToken: bottomContentInsetAnimationToken,
            keyboardHeight: keyboardHeight, transition: keyboardTransition, in: collectionView)
        coordinator.submitViewUpdate(in: collectionView) { [self, weak collectionView, weak coordinator] in
            guard let collectionView, let coordinator else { return }
            applyUpdate(collectionView, coordinator: coordinator)
        }
    }

    private func applyUpdate(_ collectionView: UICollectionView, coordinator: Coordinator) {
        coordinator.beginViewUpdate()
        defer { coordinator.endViewUpdate() }
        scrollController.attach(collectionView)
        Self.configureSoftScrollEdgeEffects(for: collectionView)
        coordinator.rowContent = rowContent
        coordinator.isAtBottom = $isAtBottom
        coordinator.bottomRefreshThreshold = bottomRefreshThreshold
        coordinator.bottomRefreshProgress = bottomRefreshProgress
        coordinator.showsBottomRefreshIndicator = showsBottomRefreshIndicator
        coordinator.bottomRefreshColorIsActive = bottomRefreshColorIsActive
        coordinator.bottomRefreshHeight = bottomRefreshHeight
        coordinator.isRefreshing = isRefreshing
        coordinator.isStreaming = isStreaming
        coordinator.hasInitialContent = hasInitialContent
        coordinator.contentInvalidationToken = contentInvalidationToken
        coordinator.animatedRowIDs = animatedRowIDs
        coordinator.onBottomPullChanged = onBottomPullChanged
        coordinator.onBottomPullEnded = onBottomPullEnded
        coordinator.updateRows(rows, in: collectionView)
        coordinator.scrollToBottomIfNeeded(token: bottomScrollToken, animated: false, in: collectionView)
        coordinator.scrollToBottomIfNeeded(token: animatedBottomScrollToken, animated: true, in: collectionView)
    }

    private static func configureSoftScrollEdgeEffects(for collectionView: UICollectionView) {
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.style = .soft
            collectionView.bottomEdgeEffect.style = .soft
            collectionView.leftEdgeEffect.style = .soft
            collectionView.rightEdgeEffect.style = .soft
        }
    }

    fileprivate static func makeLayout() -> UICollectionViewLayout {
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
        var isStreaming: Bool
        var contentInvalidationToken: String
        var animatedRowIDs: Set<String>
        var onBottomPullChanged: (CGFloat) -> Void
        var onBottomPullEnded: (Bool) -> Void
        var rowContent: (ChatTranscriptRow) -> RowContent
        weak var collectionView: UICollectionView?

        private var rowIDs: [String]
        private var rowSignaturesByID: [String: String]
        private var pendingViewUpdate: (() -> Void)?
        private var pendingViewport: (inset: CGFloat, animationToken: Int, keyboardHeight: CGFloat,
            transition: ChatKeyboardTransition?, scrollGeneration: Int, preservesBottom: Bool)?
        private var isApplyingViewport = false
        private var keyboardHeight: CGFloat = 0
        private var isApplyingRows = false
        private var userScrollGeneration = 0
        private var lastBottomScrollToken: Int?
        private var lastAnimatedBottomScrollToken: Int?
        private var pendingBottomScroll: (token: Int, animated: Bool)?
        private var bottomContentInset: CGFloat = 0
        private var lastBottomContentInsetAnimationToken: Int
        private var bottomCorrectionGeneration = 0
        private var isBottomPullTracking = false
        private var isPerformingViewUpdate = false
        private var pendingAtBottomValue: Bool?
        private(set) var awaitsInitialReveal = false
        var hasInitialContent = true
        private let initialPresentationHandoff = OpenCodeDisplayFrameHandoff()
        private var initialPresentationScheduled = false
        private var isMeasuringInitialPresentation = false
        private var initialRevealGeneration = 0
        private struct InitialLayoutSample: Equatable {
            let size: CGSize
            let viewport: CGSize
            let inset: UIEdgeInsets
            let offset: CGPoint
            let frames: [CGRect]
        }
        private var initialLayoutSample: InitialLayoutSample?

        func prepareInitialPresentation(in collectionView: UICollectionView) {
            awaitsInitialReveal = true
            initialLayoutSample = nil
            collectionView.alpha = 0
        }

        func cancelInitialPresentation() {
            initialRevealGeneration &+= 1
            initialPresentationHandoff.cancel()
            initialPresentationScheduled = false
            initialLayoutSample = nil
            isMeasuringInitialPresentation = false
            collectionView?.layer.removeAnimation(forKey: "opacity")
        }

        func collectionViewDidAttach(_ collectionView: UICollectionView) {
            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView, collectionView.window != nil else { return }
                self.applyPendingRowsIfNeeded(in: collectionView)
                self.scheduleInitialPresentation(in: collectionView)
            }
        }

        private func scheduleInitialPresentation(in collectionView: UICollectionView) {
            guard awaitsInitialReveal, hasInitialContent, !initialPresentationScheduled,
                  collectionView.window != nil else { return }
            initialPresentationScheduled = true
            initialPresentationHandoff.schedule { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                self.initialPresentationScheduled = false
                self.settleInitialPresentation(in: collectionView)
            }
        }

        func settleInitialPresentation(in collectionView: UICollectionView) {
            guard awaitsInitialReveal, hasInitialContent, collectionView.window != nil else { return }
            guard !isApplyingRows, !isPerformingViewUpdate,
                  collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
                initialLayoutSample = nil
                scheduleInitialPresentation(in: collectionView)
                return
            }
            // Freeze this render snapshot through measurement and the fade. Live state keeps
            // advancing; submitViewUpdate coalesces its latest presentation for afterwards.
            isMeasuringInitialPresentation = true
            UIView.performWithoutAnimation {
                collectionView.layoutIfNeeded()
                let target = max(-collectionView.adjustedContentInset.top,
                    collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
                collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target), animated: false)
                collectionView.layoutIfNeeded()
            }
            let sample = InitialLayoutSample(size: collectionView.contentSize,
                viewport: collectionView.bounds.size, inset: collectionView.adjustedContentInset,
                offset: collectionView.contentOffset,
                frames: collectionView.indexPathsForVisibleItems.sorted().compactMap {
                    collectionView.layoutAttributesForItem(at: $0)?.frame
                })
            let target = max(-collectionView.adjustedContentInset.top,
                collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            guard sample == initialLayoutSample, abs(collectionView.contentOffset.y - target) < 1 else {
                initialLayoutSample = sample
                scheduleInitialPresentation(in: collectionView)
                return
            }
            awaitsInitialReveal = false
            initialPresentationHandoff.cancel()
            initialPresentationScheduled = false
            initialLayoutSample = nil
            // Only opacity animates; self-sizing and initial positioning have already settled.
            let revealGeneration = initialRevealGeneration
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
                delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
                collectionView.alpha = 1
            } completion: { [weak self, weak collectionView] _ in
                guard let self, let collectionView, collectionView.window != nil,
                      self.initialRevealGeneration == revealGeneration else { return }
                // Give a pending sidebar switch priority over catching up this fading chat.
                self.initialPresentationHandoff.schedule { [weak self, weak collectionView] in
                    guard let self, let collectionView, collectionView.window != nil,
                          self.initialRevealGeneration == revealGeneration else { return }
                    self.isMeasuringInitialPresentation = false
                    self.applyPendingRowsIfNeeded(in: collectionView)
                }
            }
        }

        init(
            rows: [ChatTranscriptRow],
            isAtBottom: Binding<Bool>,
            bottomRefreshThreshold: CGFloat,
            bottomRefreshProgress: CGFloat,
            showsBottomRefreshIndicator: Bool,
            bottomRefreshColorIsActive: Bool,
            bottomRefreshHeight: CGFloat,
            isRefreshing: Bool,
            isStreaming: Bool,
            bottomContentInsetAnimationToken: Int,
            contentInvalidationToken: String,
            animatedRowIDs: Set<String>,
            onBottomPullChanged: @escaping (CGFloat) -> Void,
            onBottomPullEnded: @escaping (Bool) -> Void,
            rowContent: @escaping (ChatTranscriptRow) -> RowContent
        ) {
            var seenIDs: Set<String> = []
            self.rows = rows.filter { seenIDs.insert($0.id).inserted }
            self.isAtBottom = isAtBottom
            self.bottomRefreshThreshold = bottomRefreshThreshold
            self.bottomRefreshProgress = bottomRefreshProgress
            self.showsBottomRefreshIndicator = showsBottomRefreshIndicator
            self.bottomRefreshColorIsActive = bottomRefreshColorIsActive
            self.bottomRefreshHeight = bottomRefreshHeight
            self.isRefreshing = isRefreshing
            self.isStreaming = isStreaming
            self.lastBottomContentInsetAnimationToken = bottomContentInsetAnimationToken
            self.contentInvalidationToken = contentInvalidationToken
            self.animatedRowIDs = animatedRowIDs
            self.onBottomPullChanged = onBottomPullChanged
            self.onBottomPullEnded = onBottomPullEnded
            self.rowContent = rowContent
            self.rowIDs = self.rows.map(\.id)
            self.rowSignaturesByID = Self.signaturesByID(for: self.rows)
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            rows.count
        }

        func beginViewUpdate() {
            isPerformingViewUpdate = true
        }

        func submitViewUpdate(in collectionView: UICollectionView, _ update: @escaping () -> Void) {
            // Queue the row presentation, not viewport geometry: closures and signatures must
            // describe the same snapshot throughout UIKit's asynchronous batch completion.
            guard !isApplyingRows, !isPerformingViewUpdate, !isMeasuringInitialPresentation,
                  !isApplyingViewport, !isUserScrolling(collectionView) else {
                pendingViewUpdate = update
                return
            }
            pendingViewUpdate = nil
            update()
        }

        func endViewUpdate() {
            isPerformingViewUpdate = false
            if let collectionView { applyPendingViewport(in: collectionView) }
            let pendingAtBottomValue = self.pendingAtBottomValue
            self.pendingAtBottomValue = nil
            let scrollGeneration = userScrollGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let pendingAtBottomValue, self.userScrollGeneration == scrollGeneration { self.setAtBottom(pendingAtBottomValue) }
                if let collectionView = self.collectionView { self.applyPendingRowsIfNeeded(in: collectionView) }
                if let collectionView = self.collectionView { self.scheduleInitialPresentation(in: collectionView) }
            }
        }

        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatTranscriptHostingCell.reuseIdentifier,
                for: indexPath
            ) as! ChatTranscriptHostingCell
            configure(cell, at: indexPath)
            return cell
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            if awaitsInitialReveal {
                awaitsInitialReveal = false
                cancelInitialPresentation()
                scrollView.alpha = 1
            }
            // A drag can end before an outstanding batch completes. Its intent must
            // outlive isDragging/isDecelerating, even while bottom publication is deferred.
            userScrollGeneration &+= 1
            bottomCorrectionGeneration &+= 1
            if let pendingBottomScroll, !pendingBottomScroll.animated {
                markBottomScrollTokenHandled(pendingBottomScroll.token, animated: false)
                self.pendingBottomScroll = nil
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
            updateBottomPullState(for: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
            finishBottomPull(for: scrollView)
            applyPendingBottomScrollIfNeeded(in: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            finishBottomPull(for: scrollView)
            guard !decelerate else { return }
            updateBottomState(for: scrollView)
            applyPendingBottomScrollIfNeeded(in: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            updateBottomState(for: scrollView)
            applyPendingBottomScrollIfNeeded(in: scrollView)
            applyPendingRowsIfNeeded(in: scrollView)
        }

        func collectionViewDidLayout(_ collectionView: UICollectionView) {
            guard !isPerformingViewUpdate, !isApplyingViewport else { return }
            applyPendingBottomScrollIfNeeded(in: collectionView, performsLayout: false)
            scheduleInitialPresentation(in: collectionView)
        }

        func updateRows(_ newRows: [ChatTranscriptRow], in collectionView: UICollectionView) {
            applyRows(newRows, in: collectionView)
        }

        private func applyRows(_ newRows: [ChatTranscriptRow], in collectionView: UICollectionView) {
            #if DEBUG
            if TranscriptContinuityDiagnostics.gated {
                TranscriptContinuityDiagnostics.sampleRows = { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return [] }
                    return self.rowIDs.enumerated().map { index, id in
                        let path = IndexPath(item: index, section: 0)
                        let cell = collectionView.cellForItem(at: path)
                        let frame = collectionView.layoutAttributesForItem(at: path)?.frame ?? .zero
                        return ["id": id, "cell": cell.map { String(describing: ObjectIdentifier($0)) } ?? "",
                            "y": String(Double(frame.minY)), "height": String(Double(frame.height)),
                            "offset": String(Double(collectionView.contentOffset.y))]
                    }
                }
            }
            #endif
            let newIDs = newRows.map(\.id)
            guard let difference = ChatTranscriptContinuity.difference(from: rowIDs, to: newIDs) else { return }
            #if DEBUG
            if TranscriptContinuityDiagnostics.gated, let id = TranscriptContinuityDiagnostics.outgoingID {
                for case let .remove(_, removedID, _) in difference where removedID == id {
                    TranscriptContinuityDiagnostics.outgoingRemovals += 1
                }
            }
            #endif
            let newSignaturesByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, rowContentRenderSignature(for: $0)) })
            let changedRowIDs = Set(newSignaturesByID.compactMap { id, signature in
                rowSignaturesByID[id] == signature ? nil : id
            })
            guard !difference.isEmpty || !changedRowIDs.isEmpty else { return }
            #if DEBUG
            if TranscriptContinuityDiagnostics.enabled, TranscriptContinuityDiagnostics.updates.count < 120 {
                TranscriptContinuityDiagnostics.updates.append("\(difference.isEmpty ? "content" : "batch"):\(newIDs.joined(separator: ","))")
            }
            #endif
            isApplyingRows = true
            let wasAtBottom = isAtBottom.wrappedValue
            let scrollGeneration = userScrollGeneration
            let survivingIDs = Set(newIDs)
            let anchor = collectionView.indexPathsForVisibleItems.sorted().compactMap { index -> (String, CGFloat)? in
                guard rows.indices.contains(index.item), survivingIDs.contains(rows[index.item].id),
                      let attributes = collectionView.layoutAttributesForItem(at: index) else { return nil }
                return (rows[index.item].id, attributes.frame.minY - collectionView.contentOffset.y)
            }.first
            let finish = { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                UIView.performWithoutAnimation {
                    self.configureVisibleHostingCells(in: collectionView, changedRowIDs: changedRowIDs)
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                    if self.userScrollGeneration == scrollGeneration, !self.isUserScrolling(collectionView) {
                        if wasAtBottom {
                            self.scrollToBottom(in: collectionView, animated: false, performsLayout: false)
                        } else if let anchor, let index = self.rowIDs.firstIndex(of: anchor.0),
                                  let attributes = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
                            collectionView.contentOffset.y = attributes.frame.minY - anchor.1
                        }
                    }
                }
                self.isApplyingRows = false
                self.applyPendingViewport(in: collectionView)
                if self.userScrollGeneration != scrollGeneration {
                    self.updateBottomState(for: collectionView)
                }
                DispatchQueue.main.async { [weak self, weak collectionView] in
                    guard let self, let collectionView else { return }
                    self.applyPendingRowsIfNeeded(in: collectionView)
                    self.applyPendingBottomScrollIfNeeded(in: collectionView)
                }
            }
            if difference.isEmpty {
                rows = newRows
                rowIDs = newIDs
                rowSignaturesByID = newSignaturesByID
                finish()
            } else {
                // Removal offsets refer to the old array; insertion offsets to the new.
                // Moves deliberately use remove/insert, with no overlapping reloads.
                UIView.performWithoutAnimation {
                    collectionView.performBatchUpdates {
                        self.rows = newRows
                        self.rowIDs = newIDs
                        self.rowSignaturesByID = newSignaturesByID
                        for change in difference {
                            switch change {
                            case let .remove(offset, _, _):
                                collectionView.deleteItems(at: [IndexPath(item: offset, section: 0)])
                            case let .insert(offset, _, _):
                                collectionView.insertItems(at: [IndexPath(item: offset, section: 0)])
                            }
                        }
                    } completion: { _ in finish() }
                }
            }
        }

        func submitViewportUpdate(
            _ inset: CGFloat,
            animationToken: Int,
            keyboardHeight: CGFloat,
            transition: ChatKeyboardTransition?,
            in collectionView: UICollectionView
        ) {
            #if DEBUG
            if let probe = (collectionView as? ChatTranscriptCollection)?.keyboardProbe {
                probe.expectedInset = inset
                probe.requestedHeight = keyboardHeight
            }
            #endif
            pendingViewport = (max(0, inset), animationToken, keyboardHeight, transition,
                userScrollGeneration, isAtBottom.wrappedValue && !isUserScrolling(collectionView))
            applyPendingViewport(in: collectionView)
        }

        private func applyPendingViewport(in collectionView: UICollectionView) {
            guard !isApplyingRows, !isPerformingViewUpdate, !isApplyingViewport,
                  let viewport = pendingViewport else { return }
            pendingViewport = nil
            isApplyingViewport = true
            defer {
                isApplyingViewport = false
                if pendingViewport != nil {
                    DispatchQueue.main.async { [weak self, weak collectionView] in
                        guard let self, let collectionView else { return }
                        self.applyPendingViewport(in: collectionView)
                    }
                }
            }
            let keyboardChanged = abs(viewport.keyboardHeight - keyboardHeight) > 0.5
            keyboardHeight = viewport.keyboardHeight
            let inset = viewport.inset
            guard abs(inset - bottomContentInset) > 0.5 else { return }
            initialLayoutSample = nil
            bottomCorrectionGeneration &+= 1
            let preservesBottom = viewport.preservesBottom && viewport.scrollGeneration == userScrollGeneration
                && !isUserScrolling(collectionView)
            let animatesChange = !awaitsInitialReveal && OpenCodeChatBottomInsetAnimationPolicy.shouldAnimate(
                animationToken: viewport.animationToken,
                lastAnimationToken: lastBottomContentInsetAnimationToken,
                preservesBottom: preservesBottom
            )
            lastBottomContentInsetAnimationToken = viewport.animationToken
            bottomContentInset = inset
            if keyboardChanged {
                let duration = preservesBottom && !awaitsInitialReveal ? viewport.transition?.remainingDuration() ?? 0 : 0
                let changes = {
                    collectionView.contentInset.bottom = inset
                    collectionView.verticalScrollIndicatorInsets.bottom = inset
                    if preservesBottom {
                        collectionView.layoutIfNeeded()
                        self.pinKeyboardViewport(in: collectionView)
                    }
                }
                if duration > 0 {
                    UIView.animate(withDuration: duration, delay: 0,
                        options: viewport.transition?.animationOptions ?? [], animations: changes)
                } else {
                    UIView.performWithoutAnimation(changes)
                }
                if preservesBottom {
                    schedulePinnedBottomCorrection(in: collectionView, delay: duration, keyboardChange: true)
                }
                return
            }
            UIView.performWithoutAnimation {
                collectionView.contentInset.bottom = inset
                collectionView.verticalScrollIndicatorInsets.bottom = inset
                guard preservesBottom else { return }
                collectionView.layoutIfNeeded()
            }
            if preservesBottom {
                scrollToBottom(in: collectionView, animated: animatesChange, performsLayout: false)
                schedulePinnedBottomCorrection(
                    in: collectionView,
                    delay: animatesChange ? 0.3 : 0
                )
            }
        }

        private func pinKeyboardViewport(in collectionView: UICollectionView) {
            guard !rows.isEmpty, collectionView.window != nil,
                  collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return }
            // A known keyboard shrink can exceed the general unstable-layout correction limit.
            let target = max(-collectionView.adjustedContentInset.top,
                collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
            collectionView.contentOffset.y = target
            setAtBottomAfterViewUpdate()
        }

        private func schedulePinnedBottomCorrection(
            in collectionView: UICollectionView,
            delay: TimeInterval = 0,
            keyboardChange: Bool = false
        ) {
            bottomCorrectionGeneration &+= 1
            let generation = bottomCorrectionGeneration
            let scrollGeneration = userScrollGeneration
            Task { @MainActor [weak self, weak collectionView] in
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1_000)))
                } else {
                    await Task.yield()
                }
                guard let self, let collectionView else { return }
                guard self.bottomCorrectionGeneration == generation else { return }
                guard collectionView.window != nil,
                      self.userScrollGeneration == scrollGeneration, !self.isApplyingRows,
                      !self.isUserScrolling(collectionView), self.isAtBottom.wrappedValue else { return }
                collectionView.layoutIfNeeded()
                if keyboardChange { self.pinKeyboardViewport(in: collectionView) }
                else { self.scrollToBottom(in: collectionView, animated: false, performsLayout: false) }
            }
        }

        func scrollToBottomIfNeeded(token: Int, animated: Bool, in collectionView: UICollectionView) {
            guard !animated || token > 0 else { return }

            if animated {
                guard lastAnimatedBottomScrollToken != token else { return }
            } else {
                guard lastBottomScrollToken != token else { return }
            }

            guard !isApplyingRows, !shouldDeferBottomScroll(animated: animated, in: collectionView) else {
                pendingBottomScroll = (token, animated)
                return
            }

            pendingBottomScroll = nil
            guard scrollToBottom(in: collectionView, animated: animated) else {
                pendingBottomScroll = (token, animated)
                return
            }
            markBottomScrollTokenHandled(token, animated: animated)
            guard animated else { return }

            DispatchQueue.main.async { [weak self, weak collectionView] in
                guard let self, let collectionView else { return }
                guard !self.shouldDeferBottomScroll(animated: animated, in: collectionView) else { return }
                self.scrollToBottom(in: collectionView, animated: animated)
            }
        }

        private func applyPendingBottomScrollIfNeeded(in scrollView: UIScrollView, performsLayout: Bool = true) {
            guard let collectionView = scrollView as? UICollectionView,
                  !isApplyingRows,
                  let pendingBottomScroll,
                  !shouldDeferBottomScroll(animated: pendingBottomScroll.animated, in: collectionView) else { return }
            self.pendingBottomScroll = nil
            guard scrollToBottom(in: collectionView, animated: pendingBottomScroll.animated, performsLayout: performsLayout) else {
                self.pendingBottomScroll = pendingBottomScroll
                return
            }
            markBottomScrollTokenHandled(pendingBottomScroll.token, animated: pendingBottomScroll.animated)
        }

        private func shouldDeferBottomScroll(animated: Bool, in collectionView: UICollectionView) -> Bool {
            if animated {
                return collectionView.isTracking || collectionView.isDragging
            }
            return isUserScrolling(collectionView)
        }

        private func markBottomScrollTokenHandled(_ token: Int, animated: Bool) {
            if animated {
                lastAnimatedBottomScrollToken = token
            } else {
                lastBottomScrollToken = token
            }
        }

        private func configure(_ cell: ChatTranscriptHostingCell, at indexPath: IndexPath) {
            guard rows.indices.contains(indexPath.item) else { return }
            let row = rows[indexPath.item]
            let allowsAnimations = !awaitsInitialReveal && (row.id == ChatScrollTarget.bottomAnchor || row.id == ChatScrollTarget.thinkingRow || animatedRowIDs.contains(row.id))
            cell.configure(
                rowID: row.id,
                renderSignature: rowContentRenderSignature(for: row),
                AnyView(rowContent(row)),
                disablesAnimations: !allowsAnimations
            )
        }

        private func rowContentRenderSignature(for row: ChatTranscriptRow) -> String {
            "\(row.renderSignature)\u{1f}\(contentInvalidationToken)"
        }

        func configureVisibleHostingCells(in collectionView: UICollectionView) {
            for case let cell as ChatTranscriptHostingCell in collectionView.visibleCells {
                guard let indexPath = collectionView.indexPath(for: cell), rows.indices.contains(indexPath.item) else { continue }
                UIView.performWithoutAnimation {
                    configure(cell, at: indexPath)
                }
            }
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

        private func indexPaths(for rowIDs: Set<String>) -> [IndexPath] {
            rows.enumerated().compactMap { index, row in
                rowIDs.contains(row.id) ? IndexPath(item: index, section: 0) : nil
            }
        }

        private func applyPendingRowsIfNeeded(in scrollView: UIScrollView) {
            guard let collectionView = scrollView as? UICollectionView, collectionView.window != nil, !isApplyingRows,
                  !isPerformingViewUpdate, !isMeasuringInitialPresentation, !isApplyingViewport,
                  !isUserScrolling(collectionView), let update = pendingViewUpdate else { return }
            pendingViewUpdate = nil
            update()
        }

        @discardableResult
        private func scrollToBottom(
            in collectionView: UICollectionView,
            animated: Bool,
            performsLayout: Bool = true
        ) -> Bool {
            guard !rows.isEmpty, collectionView.window != nil,
                  collectionView.bounds.width > 0, collectionView.bounds.height > 0 else { return false }
            guard ChatTranscriptScrollController.scrollToBottom(
                in: collectionView,
                animated: animated && !awaitsInitialReveal,
                interruptsCurrentScroll: animated && !awaitsInitialReveal,
                performsLayout: performsLayout
            ) else { return false }
            setAtBottomAfterViewUpdate()
            return true
        }

        private func scrollToBottomItem(in collectionView: UICollectionView, animated: Bool) {
            guard !rows.isEmpty, collectionView.numberOfSections > 0 else { return }
            let itemCount = collectionView.numberOfItems(inSection: 0)
            guard itemCount > 0 else { return }
            collectionView.scrollToItem(at: IndexPath(item: itemCount - 1, section: 0), at: .bottom, animated: animated)
            setAtBottomAfterViewUpdate()
        }

        private func setAtBottomAfterViewUpdate() {
            let scrollGeneration = userScrollGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.userScrollGeneration == scrollGeneration else { return }
                self.setAtBottom(true)
            }
        }

        private func updateBottomState(for scrollView: UIScrollView) {
            guard !isApplyingRows, !isApplyingViewport else { return }
            let distanceFromBottom = distanceFromBottom(for: scrollView)
            if isAtBottom.wrappedValue {
                guard distanceFromBottom > 140 else { return }
                setAtBottom(false)
            } else {
                guard distanceFromBottom < 24 else { return }
                setAtBottom(true)
            }
        }

        private func setAtBottom(_ value: Bool) {
            guard isAtBottom.wrappedValue != value else { return }
            if isPerformingViewUpdate {
                pendingAtBottomValue = value
                return
            }
            isAtBottom.wrappedValue = value
        }

        private func distanceFromBottom(for scrollView: UIScrollView) -> CGFloat {
            max(0, scrollView.contentSize.height - scrollView.bounds.height - scrollView.contentOffset.y + scrollView.adjustedContentInset.bottom)
        }

        private func bottomOverscrollDistance(for scrollView: UIScrollView) -> CGFloat {
            let restingBottomOffset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            return max(0, scrollView.contentOffset.y - restingBottomOffset)
        }

        private func updateBottomPullState(for scrollView: UIScrollView) {
            guard scrollView.isDragging, !isRefreshing else { return }
            let overscrollDistance = bottomOverscrollDistance(for: scrollView)
            if !isBottomPullTracking {
                guard overscrollDistance > 0, isAtBottom.wrappedValue || distanceFromBottom(for: scrollView) < 24 else { return }
                isBottomPullTracking = true
            }

            onBottomPullChanged(overscrollDistance)
        }

        private func finishBottomPull(for scrollView: UIScrollView) {
            guard isBottomPullTracking else { return }
            let shouldRefresh = bottomOverscrollDistance(for: scrollView) >= bottomRefreshThreshold && !isRefreshing
            isBottomPullTracking = false
            onBottomPullEnded(shouldRefresh)
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

    }
}

private final class ChatTranscriptHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatTranscriptHostingCell"

    private var configuredRowID: String?
    private var configuredRenderSignature: String?
    private var configuredDisablesAnimations: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(rowID: String, renderSignature: String, _ content: AnyView, disablesAnimations: Bool) {
        guard configuredRowID != rowID || configuredRenderSignature != renderSignature || configuredDisablesAnimations != disablesAnimations else {
            return
        }

        configuredRowID = rowID
        configuredRenderSignature = renderSignature
        configuredDisablesAnimations = disablesAnimations

        contentConfiguration = UIHostingConfiguration {
            content
                .id(rowID)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transaction { transaction in
                    if disablesAnimations {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
        }
        .margins(.all, 0)

    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuredRowID = nil
        configuredRenderSignature = nil
        configuredDisablesAnimations = nil
        contentView.layer.removeAllAnimations()
        contentView.transform = .identity
        contentView.alpha = 1
        contentConfiguration = nil
    }
}
#if DEBUG
/// Exercises the production coordinator and hosting cells without networking or app stores.
@MainActor
final class ChatTranscriptContinuityHarness {
    private struct Row: View {
        let id: String
        let revision: Int
        let rendered: (UUID) -> Void
        @State private var lifetime = UUID()

        var body: some View {
            Text(verbatim: "\(id):\(revision)").frame(height: 80)
                .onAppear { rendered(lifetime) }
                .onChange(of: revision) { _, _ in rendered(lifetime) }
        }
    }

    final class CollectionView: ChatTranscriptCollection {
        var insetAnimationDurations: [TimeInterval] = []
        override var contentInset: UIEdgeInsets {
            didSet { insetAnimationDurations.append(UIView.inheritedAnimationDuration) }
        }
        var simulatesTracking = false
        var simulatesDragging = false
        var simulatesDecelerating = false
        override var isTracking: Bool { simulatesTracking || super.isTracking }
        override var isDragging: Bool { simulatesDragging || super.isDragging }
        override var isDecelerating: Bool { simulatesDecelerating || super.isDecelerating }
        var reloadCount = 0
        var itemReloadCount = 0
        var batchCount = 0
        var duringBatch: (() -> Void)?
        var holdsBatchCompletion = false
        var heldBatchCompletion: (() -> Void)?
        override func reloadData() { reloadCount += 1; super.reloadData() }
        override func reloadItems(at indexPaths: [IndexPath]) { itemReloadCount += 1; super.reloadItems(at: indexPaths) }
        override func performBatchUpdates(_ updates: (() -> Void)?, completion: ((Bool) -> Void)? = nil) {
            batchCount += 1
            let callback = duringBatch
            duringBatch = nil
            super.performBatchUpdates({
                updates?()
                callback?()
            }, completion: { [weak self] finished in
                if self?.holdsBatchCompletion == true {
                    self?.heldBatchCompletion = { completion?(finished) }
                } else {
                    completion?(finished)
                }
            })
        }
    }

    let collectionView: CollectionView
    var pinned = true
    private(set) var lifetimes: [String: UUID] = [:]
    private let scrollController = ChatTranscriptScrollController()
    private var coordinator: ChatTranscriptCollectionView<AnyView>.Coordinator?

    init() {
        collectionView = CollectionView(frame: CGRect(x: 0, y: 0, width: 400, height: 600),
            collectionViewLayout: ChatTranscriptCollectionView<AnyView>.makeLayout())
        collectionView.register(ChatTranscriptHostingCell.self, forCellWithReuseIdentifier: ChatTranscriptHostingCell.reuseIdentifier)
    }

    func update(ids: [String], revision: Int = 0, streaming: Bool = false, hasInitialContent: Bool = true, bottomInset: CGFloat = 0,
                keyboardHeight: CGFloat = 0, keyboardTransition: ChatKeyboardTransition? = nil) {
        let rows = ids.map { id in
            ChatTranscriptRow.displayItem(.message(.local(role: "user", text: id + String(repeating: "!", count: revision), messageID: id, sessionID: "continuity", partID: "part-\(id)")),
                recovery: nil, recoveryStatusVisible: false)
        }
        let view = ChatTranscriptCollectionView<AnyView>(rows: rows,
            isAtBottom: Binding(get: { self.pinned }, set: { self.pinned = $0 }), scrollController: scrollController,
            bottomScrollToken: 0, animatedBottomScrollToken: 0, bottomContentInset: bottomInset,
            bottomContentInsetAnimationToken: 0, keyboardHeight: keyboardHeight, keyboardTransition: keyboardTransition,
            bottomRefreshThreshold: 90, bottomRefreshProgress: 0,
            showsBottomRefreshIndicator: false, bottomRefreshColorIsActive: false, bottomRefreshHeight: 0,
            isRefreshing: false, isStreaming: streaming, hasInitialContent: hasInitialContent,
            contentInvalidationToken: "", animatedRowIDs: [],
            onBottomPullChanged: { _ in }, onBottomPullEnded: { _ in }, rowContent: { [weak self] row in
                AnyView(Row(id: row.id, revision: revision) { [weak self] lifetime in
                    self?.lifetimes[row.id] = lifetime
                })
            })
        if coordinator == nil {
            let coordinator = view.makeCoordinator()
            self.coordinator = coordinator
            collectionView.dataSource = coordinator
            collectionView.delegate = coordinator
            coordinator.collectionView = collectionView
            collectionView.didDetach = { [weak coordinator] in coordinator?.cancelInitialPresentation() }
            collectionView.didAttach = { [weak collectionView = self.collectionView, weak coordinator] in
                guard let collectionView else { return }
                coordinator?.collectionViewDidAttach(collectionView)
            }
            collectionView.didLayout = { [weak collectionView = self.collectionView, weak coordinator] in
                guard let collectionView else { return }
                coordinator?.collectionViewDidLayout(collectionView)
            }
        }
        if let coordinator { view.update(collectionView, coordinator: coordinator) }
    }

    func cell(id: String) -> UICollectionViewCell? {
        guard let index = coordinator?.rows.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.cellForItem(at: IndexPath(item: index, section: 0))
    }

    var appliedIDs: [String] { coordinator?.rows.map(\.id) ?? [] }

    func prepareInitialReveal() { coordinator?.prepareInitialPresentation(in: collectionView) }
    func sampleInitialLayout() { coordinator?.settleInitialPresentation(in: collectionView) }
    var awaitsInitialReveal: Bool { coordinator?.awaitsInitialReveal ?? false }
    func updateBottomInset(_ inset: CGFloat) {
        coordinator?.submitViewportUpdate(inset, animationToken: 1, keyboardHeight: 0, transition: nil, in: collectionView)
    }
}
#endif
#else
private struct ChatTranscriptCollectionView<RowContent: View>: View {
    let rows: [ChatTranscriptRow]
    @Binding var isAtBottom: Bool
    let scrollController: ChatTranscriptScrollController
    let bottomScrollToken: Int
    let animatedBottomScrollToken: Int
    let bottomContentInset: CGFloat
    let bottomContentInsetAnimationToken: Int
    var keyboardHeight: CGFloat = 0
    var keyboardTransition: ChatKeyboardTransition? = nil
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
