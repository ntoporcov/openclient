import Foundation

/// Presentation-only slices. Parts retain their canonical message IDs for tool actions.
struct TranscriptActivitySlice: Identifiable {
    let source: OpenCodeMessageEnvelope
    var parts: [OpenCodePart]
    let isActivity: Bool
    var additionalSourceMessageIDs: [String] = []
    var sourceMessageIDs: [String] { [source.id] + additionalSourceMessageIDs }
    var id: String { "activity-slice-\(source.id)-\(parts.first?.id ?? "first")" }
    var message: OpenCodeMessageEnvelope {
        var result = source
        result.parts = parts
        return result
    }
}

enum TranscriptActivityGrouping {
    static func filteringContext(_ message: OpenCodeMessageEnvelope, showsContextChanges: Bool) -> OpenCodeMessageEnvelope {
        guard !showsContextChanges, message.info.role == "assistant" else { return message }
        var result = message
        result.parts.removeAll { $0.timelineContextType != nil }
        return result
    }

    static func isActivity(_ part: OpenCodePart) -> Bool {
        part.timelineContextType != nil || part.type == "reasoning" || (part.type == "text" && part.reason?.lowercased().contains("reasoning") == true)
            || (part.type != "compaction" && OpenCodeToolActivityPolicy.isToolCall(part))
    }

    static func slices(_ messages: [OpenCodeMessageEnvelope]) -> [TranscriptActivitySlice] {
        var result: [TranscriptActivitySlice] = []
        for message in messages {
            guard message.info.role == "assistant" else {
                result.append(.init(source: message, parts: message.parts, isActivity: false))
                continue
            }
            for part in message.parts {
                // Transport step markers do not separate visible activity.
                if part.type == "step-start" || part.type == "step-finish" { continue }
                let activity = isActivity(part)
                if let last = result.last,
                   last.source.info.role == "assistant",
                   last.isActivity == activity,
                   activity || last.source.id == message.id {
                    result[result.count - 1].parts.append(part)
                    if (last.additionalSourceMessageIDs.last ?? last.source.id) != message.id {
                        result[result.count - 1].additionalSourceMessageIDs.append(message.id)
                    }
                } else {
                    result.append(.init(source: message, parts: [part], isActivity: activity))
                }
            }
        }
        return result
    }
}

/// Selects canonical messages using the actual projected row spans. A message may
/// contain several rows, and an activity row may span many messages.
enum GroupedTranscriptWindowing {
    struct Selection: Equatable {
        let messageCount: Int
        let hiddenRowCount: Int
        let nextMessageCount: Int
    }

    static func select(totalCount: Int, requestedCount: Int, batchSize: Int,
                       rowRanges: [ClosedRange<Int>]) -> Selection {
        guard totalCount > 0 else { return .init(messageCount: 0, hiddenRowCount: 0, nextMessageCount: 0) }
        let batch = max(1, batchSize)
        let ranges = rowRanges.filter { $0.lowerBound >= 0 && $0.upperBound < totalCount }
        guard !ranges.isEmpty else {
            return .init(messageCount: totalCount, hiddenRowCount: 0, nextMessageCount: totalCount)
        }
        // Sorted by source start, so a reverse pass also handles overlapping spans
        // (e.g. a message containing the end of one group and start of another).
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        func completeBoundary(_ candidate: Int) -> Int {
            var start = candidate
            for range in ordered.reversed() where range.upperBound >= start {
                start = min(start, range.lowerBound)
            }
            return start
        }
        let rawStart = max(0, totalCount - max(requestedCount, batch))
        let rowStart = ranges[max(0, ranges.count - batch)].lowerBound
        let start = completeBoundary(min(rawStart, rowStart))
        let hidden = ranges.filter { $0.upperBound < start }
        let nextStart = hidden.isEmpty ? start : completeBoundary(hidden[max(0, hidden.count - batch)].lowerBound)
        return .init(messageCount: totalCount - start, hiddenRowCount: hidden.count,
                     nextMessageCount: totalCount - nextStart)
    }
}
