import Foundation

/// Prepared presentation values; backend projection decoding stays out of views.
struct SessionMetadataSection: Hashable, Sendable, Identifiable {
    let id: String
    let title: LocalizedStringResource
    let rows: [SessionMetadataRow]
    let note: LocalizedStringResource?

    init(id: String, title: LocalizedStringResource, rows: [SessionMetadataRow], note: LocalizedStringResource? = nil) {
        self.id = id
        self.title = title
        self.rows = rows
        self.note = note
    }

    // LocalizedStringResource is Equatable but not Hashable. Labels still
    // participate in synthesized equality; stable identities/data own the hash.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(rows)
    }
}

struct SessionMetadataRow: Hashable, Sendable, Identifiable {
    let id: String
    let label: LocalizedStringResource
    let value: SessionMetadataValue
    var rawLabel: String? = nil

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(value)
        hasher.combine(rawLabel)
    }
}

enum SessionMetadataValue: Hashable, Sendable {
    case text(String)
    case integer(Int)
    case decimal(Double)
    case currencyUSD(Double)
    case durationMilliseconds(Double)
    case dateMilliseconds(Double)
    /// Percentage points, e.g. 25 means 25%, not 2500%.
    case percent(Double)
    case boolean(Bool)
    case unavailable
}

/// Prepared outside the render path from canonical response usage and server timestamps.
enum OpenCodeResponseMetadataBuilder {
    static func sections(messages: [OpenCodeMessageEnvelope], providers: [OpenCodeProvider]) -> [SessionMetadataSection] {
        // V2 also projects shell and synthetic records as assistant envelopes.
        // Only model responses belong in response timing and usage statistics.
        let assistants: [OpenCodeMessage] = messages.compactMap { envelope in
            let message = envelope.info
            guard message.role == "assistant", message.summary != true else { return nil }
            if message.model != nil { return message }
            if message.modelID != nil { return message }
            if message.tokens != nil { return message }
            if message.time?.streamed != nil { return message }
            return nil
        }
        let usage = assistants.compactMap(\.tokens)
        var sections: [SessionMetadataSection] = []
        if !usage.isEmpty {
            let input = usage.reduce(0.0) { $0 + Double($1.input) }
            let read = usage.reduce(0.0) { $0 + Double($1.cache.read) }
            let write = usage.reduce(0.0) { $0 + Double($1.cache.write) }
            sections.append(.init(id: "recorded-usage", title: "Recorded Token Usage", rows: [
                row("samples", "Responses with Usage", .integer(usage.count)),
                row("input", "Uncached Input Tokens", .decimal(input)),
                row("cache-read", "Cache Read Tokens", .decimal(read)),
                row("cache-write", "Cache Write Tokens", .decimal(write)),
                row("input-total", "Total Input Tokens", .decimal(input + read + write)),
                row("output", "Output Tokens", .decimal(usage.reduce(0) { $0 + Double($1.output) })),
                row("reasoning", "Reasoning Tokens", .decimal(usage.reduce(0) { $0 + Double($1.reasoning) })),
                row("cache-share", "Cache Read Share", input + read + write > 0 ? .percent(read / (input + read + write) * 100) : .unavailable)
            ], note: "Totals cover loaded assistant responses, excluding compaction summaries. They are separate from current context usage."))
        }

        let completed = assistants.filter { $0.time?.completed != nil }
        let latencies = completed.compactMap { message -> Double? in
            guard duration(from: message.time?.streamed, to: message.time?.completed) != nil else { return nil }
            return duration(from: message.time?.created, to: message.time?.streamed)
        }
        let decodeSamples = completed.compactMap { message -> (milliseconds: Double, tokens: Double)? in
            guard let duration = duration(from: message.time?.streamed, to: message.time?.completed), duration > 0,
                  Self.duration(from: message.time?.created, to: message.time?.streamed) != nil,
                  let tokens = message.tokens, tokens.output >= 0, tokens.reasoning >= 0 else { return nil }
            // OpenCode normalizes output and reasoning into separate counters.
            return (duration, Double(tokens.output) + Double(tokens.reasoning))
        }
        let decodeTime = decodeSamples.reduce(0) { $0 + $1.milliseconds }
        let decodeTokens = decodeSamples.reduce(0) { $0 + $1.tokens }
        sections.append(.init(id: "performance", title: "Session Performance", rows: [
            row("completed", "Completed Responses", .integer(completed.count)),
            row("ttft-samples", "First Token Samples", .integer(latencies.count)),
            row("ttft", "Average Time to First Token", latencies.isEmpty ? .unavailable : .durationMilliseconds(latencies.reduce(0, +) / Double(latencies.count))),
            row("decode", "Decode Time", decodeSamples.isEmpty ? .unavailable : .durationMilliseconds(decodeTime)),
            row("decode-tokens", "Decode Tokens", decodeSamples.isEmpty ? .unavailable : .decimal(decodeTokens)),
            row("speed", "Decode Tokens per Second", decodeTime > 0 ? .decimal(decodeTokens * 1000 / decodeTime) : .unavailable)
        ], note: "Performance uses server timestamps for completed responses in loaded history. Decode speed includes output and reasoning tokens, measured from first stream to completion."))

        if let latest = assistants.last {
            let providerID = latest.model?.providerID ?? latest.providerID
            let modelID = latest.model?.modelID ?? latest.modelID
            let provider = providers.first { $0.id == providerID }
            let model = modelID.flatMap { provider?.models[$0] }
            let decode = duration(from: latest.time?.created, to: latest.time?.streamed) == nil ? nil : duration(from: latest.time?.streamed, to: latest.time?.completed)
            let speed: SessionMetadataValue
            if let decode, decode > 0, let tokens = latest.tokens, tokens.output >= 0, tokens.reasoning >= 0 {
                speed = .decimal((Double(tokens.output) + Double(tokens.reasoning)) * 1000 / decode)
            } else { speed = .unavailable }
            sections.append(.init(id: "last-response", title: "Latest Model Response", rows: [
                row("id", "Message ID", .text(latest.id)),
                row("agent", "Agent", text(latest.agent)),
                row("provider", "Provider", text(provider?.name ?? providerID)),
                row("provider-id", "Provider ID", text(providerID)),
                row("model", "Model", text(model?.name ?? modelID)),
                row("model-id", "Model ID", text(modelID)),
                row("variant", "Variant", text(latest.model?.variant)),
                row("input-limit", "Input Limit", integer(model?.limit?.input)),
                row("output-limit", "Output Limit", integer(model?.limit?.output)),
                row("finish", "Finish Reason", text(latest.finish)),
                row("cost", "Cost", latest.cost.map(SessionMetadataValue.currencyUSD) ?? .unavailable),
                row("created", "Created", date(latest.time?.created)),
                row("streamed", "First Token", date(latest.time?.streamed)),
                row("completed", "Completed", date(latest.time?.completed)),
                row("duration", "Response Time", duration(from: latest.time?.created, to: latest.time?.completed).map(SessionMetadataValue.durationMilliseconds) ?? .unavailable),
                row("ttft", "Time to First Token", duration(from: latest.time?.created, to: latest.time?.streamed).map(SessionMetadataValue.durationMilliseconds) ?? .unavailable),
                row("decode", "Decode Time", decode.map(SessionMetadataValue.durationMilliseconds) ?? .unavailable),
                row("speed", "Decode Tokens per Second", speed)
            ]))
        }
        return sections
    }

    static func sessionSection(_ session: OpenCodeSession) -> SessionMetadataSection {
        .init(id: "session-details", title: "Session Details", rows: [
            row("id", "Session ID", .text(session.id)),
            row("project", "Project ID", text(session.projectID)),
            row("workspace", "Workspace", text(session.workspaceID)),
            row("directory", "Working Directory", text(session.directory)),
            row("parent", "Parent Session", text(session.parentID)),
            row("agent", "Agent", text(session.agent)),
            row("provider", "Provider ID", text(session.model?.providerID)),
            row("model", "Model ID", text(session.model?.modelID)),
            row("variant", "Variant", text(session.model?.variant)),
            row("created", "Created", date(session.time?.created)),
            row("updated", "Last Activity", date(session.time?.updated)),
            row("archived", "Archived", date(session.time?.archived))
        ])
    }

    private static func row(_ id: String, _ label: LocalizedStringResource, _ value: SessionMetadataValue) -> SessionMetadataRow {
        .init(id: id, label: label, value: value)
    }
    private static func text(_ value: String?) -> SessionMetadataValue { value.map(SessionMetadataValue.text) ?? .unavailable }
    private static func integer(_ value: Int?) -> SessionMetadataValue { value.map(SessionMetadataValue.integer) ?? .unavailable }
    private static func date(_ value: Double?) -> SessionMetadataValue { value.map(SessionMetadataValue.dateMilliseconds) ?? .unavailable }
    private static func duration(from start: Double?, to end: Double?) -> Double? {
        guard let start, let end, start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
        let result = end - start
        return result.isFinite ? result : nil
    }
}
