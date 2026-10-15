import Foundation

/// Adapts the same public projections used by DSH's web context meter.
/// Transcript token totals, loaded history size, catalog limits, and prices are
/// deliberately not substitutes for current session projections.
enum DSHSessionContextMetricsBuilder {
    static func metrics(session: OpenCodeSession, providers: [OpenCodeProvider]) -> OpenCodeSessionContextMetrics {
        let metadata = session.backendMetadata
        let values = metadata?.isCurrent == true ? metadata?.projections ?? [:] : [:]
        let pressure = values["contextPressure"] ?? .null
        let projected = count(pressure[dsh: "projectedTokens"])
        let reported = count(pressure[dsh: "pressureTokens"])
        let used = projected ?? reported
        let capacity = count(pressure[dsh: "contextWindow"]).flatMap { $0 > 0 ? $0 : nil }
        let percentage = used.flatMap { used in
            capacity.map { Int(min(100, (Double(used) / Double($0) * 100).rounded())) }
        }
        let selection = values["modelSelection"] ?? .null
        let lastModel = selection[dsh: "lastUsed"]
        let providerID = lastModel[dsh: "provider"].dshString
        let modelID = lastModel[dsh: "model"].dshString
        let provider = providers.first { $0.id == providerID }
        let model = modelID.flatMap { provider?.models[$0] }
        let context = used.map {
            OpenCodeSessionContextSnapshot(
                messageID: session.id + ":context", messageCreatedAt: nil,
                providerLabel: provider?.name ?? providerID ?? "—", modelLabel: model?.name ?? modelID ?? "—",
                limit: capacity, input: reported, output: nil, reasoning: nil,
                cacheRead: nil, cacheWrite: nil, total: $0, usage: percentage
            )
        }
        var sections = [SessionMetadataSection(
            id: "context", title: "Context", rows: [
                row("used", "Current Context Tokens", integer(used)),
                row("capacity", "Context Limit", integer(capacity)),
                row("percent", "Usage", percentage.map { .percent(Double($0)) } ?? .unavailable),
                row("projected", "Projected Context Tokens", integer(projected)),
                row("reported", "Last Reported Input Tokens", integer(reported))
            ], note: "Context uses DSH's current projection, not cumulative token usage. Projected tokens include an estimate of changes since the last reported input."
        )]
        if let breakdown = values["contextBreakdown"], breakdown.objectValue != nil {
            sections.append(.init(id: "breakdown", title: "Estimated Context Composition", rows: [
                row("system", "System Tokens", integer(count(breakdown[dsh: "systemTokens"]))),
                row("tools", "Tool Definition Tokens", integer(count(breakdown[dsh: "toolsTokens"]))),
                row("messages", "Message Tokens", integer(count(breakdown[dsh: "messageTokens"])))
            ], note: "These are approximate composition counts. Their sum is not the measured context usage."))
        }
        sections.append(usageSection(values["tokenUsage"] ?? .null))
        if let stats = values["sessionStats"], stats.objectValue != nil {
            sections.append(statisticsSection(stats))
        }
        sections.append(modelSection(id: "last-model", title: "Last Used Model", selection: lastModel, providers: providers))
        sections.append(modelSection(id: "next-model", title: "Next Model", selection: selection[dsh: "next"], providers: providers))
        let plan = values["plan"] ?? .null
        sections.append(.init(id: "configuration", title: "Session Configuration", rows: [
            row("preset", "Agent Preset", text(values["agentPreset"]?.dshString)),
            row("permissions", "Permissions", text(values["permissions"]?[dsh: "currentValue"].dshString)),
            row("plan-active", "Plan Mode", boolean(plan[dsh: "active"])),
            row("plan-pending", "Plan Mode Change Pending", boolean(plan[dsh: "pending"]))
        ]))
        sections.append(sessionSection(session, metadata: metadata, values: values))
        if let goal = values["goal"], goal.objectValue != nil {
            sections.append(goalSection(goal))
        }
        // Preserve contributed projections without guessing a schema or extracting
        // credentials from connection configuration. These are session metadata only.
        let handled: Set<String> = ["contextPressure", "contextBreakdown", "tokenUsage", "sessionStats", "modelSelection", "agentPreset", "permissions", "plan", "sessionListMetadata", "title", "goal"]
        let extra = values.keys.filter { !handled.contains($0) }.sorted().map { key in
            SessionMetadataRow(id: key, label: "Projection", value: displayJSON(values[key] ?? .null), rawLabel: key)
        }
        if !extra.isEmpty {
            sections.append(.init(id: "additional", title: "Additional Server Metadata", rows: extra))
        }
        return .init(totalCost: nil, messageCount: nil, userMessageCount: nil, assistantMessageCount: nil,
                     context: context, breakdown: [], systemPrompt: nil, metadataSections: sections)
    }

    private static func usageSection(_ usage: DSHJSON) -> SessionMetadataSection {
        let uncached = count(usage[dsh: "uncachedInputTokens"])
        let output = count(usage[dsh: "outputTokens"])
        let read = count(usage[dsh: "cacheReadTokens"])
        let write = count(usage[dsh: "cacheWriteTokens"])
        let input = sum([uncached, read, write])
        let total = sum([input, output])
        let cachePercent: SessionMetadataValue
        if let read, let input, input > 0 {
            cachePercent = .percent(Double(read) / Double(input) * 100)
        } else { cachePercent = .unavailable }
        return .init(id: "usage", title: "Recorded Token Usage", rows: [
            row("uncached", "Uncached Input Tokens", integer(uncached)),
            row("cache-read", "Cache Read Tokens", integer(read)),
            row("cache-write", "Cache Write Tokens", integer(write)),
            row("input", "Total Input Tokens", integer(input)),
            row("output", "Output Tokens", integer(output)),
            row("total", "Total Recorded Tokens", integer(total)),
            row("cache-percent", "Cache Read Share", cachePercent),
            row("cost", "Total Cost", .unavailable)
        ], note: "Cumulative assistant usage is separate from current context. Output includes reasoning; compaction summaries are not included. DSH does not report session cost.")
    }

    private static func statisticsSection(_ stats: DSHJSON) -> SessionMetadataSection {
        let ttft = number(stats[dsh: "ttftMs"])
        let samples = count(stats[dsh: "ttftSteps"])
        let decode = number(stats[dsh: "decodeMs"])
        let decoded = count(stats[dsh: "decodeTokens"])
        let average: SessionMetadataValue
        if let ttft, let samples, samples > 0 { average = .durationMilliseconds(ttft / Double(samples)) }
        else { average = .unavailable }
        let speed: SessionMetadataValue
        if let decoded, let decode, decode > 0 {
            let rate = Double(decoded) / (decode / 1000)
            speed = rate.isFinite ? .decimal(rate) : .unavailable
        } else { speed = .unavailable }
        return .init(id: "statistics", title: "Session Performance", rows: [
            row("turns", "Turns", integer(count(stats[dsh: "turns"]))),
            row("steps", "Steps", integer(count(stats[dsh: "steps"]))),
            row("llm", "Model Time", duration(stats[dsh: "llmMs"])),
            row("tools", "Tool Time", duration(stats[dsh: "toolMs"])),
            row("ttft", "Total Time to First Token", duration(stats[dsh: "ttftMs"])),
            row("ttft-samples", "First Token Samples", integer(samples)),
            row("ttft-average", "Average Time to First Token", average),
            row("decode", "Decode Time", duration(stats[dsh: "decodeMs"])),
            row("decode-tokens", "Decode Tokens", integer(decoded)),
            row("decode-speed", "Decode Tokens per Second", speed)
        ], note: "Server-reported totals for completed steps, independent of loaded history.")
    }

    private static func modelSection(id: String, title: LocalizedStringResource, selection: DSHJSON,
                                     providers: [OpenCodeProvider]) -> SessionMetadataSection {
        let providerID = selection[dsh: "provider"].dshString
        let modelID = selection[dsh: "model"].dshString
        let provider = providers.first { $0.id == providerID }
        let model = modelID.flatMap { provider?.models[$0] }
        return .init(id: id, title: title, rows: [
            row("provider", "Provider", text(provider?.name ?? providerID)),
            row("provider-id", "Provider ID", text(providerID)),
            row("model", "Model", text(model?.name ?? modelID)),
            row("model-id", "Model ID", text(modelID)),
            row("reasoning", "Reasoning Effort", text(selection[dsh: "reasoningEffort"].dshString))
        ])
    }

    private static func sessionSection(_ session: OpenCodeSession, metadata: BackendSessionMetadata?,
                                       values: [String: DSHJSON]) -> SessionMetadataSection {
        let list = values["sessionListMetadata"] ?? .null
        return .init(id: "session", title: "Session", rows: [
            row("title", "Title", text(session.title)),
            row("id", "Session ID", .text(session.id)),
            row("workspace", "Workspace", text(session.projectID ?? session.workspaceID)),
            row("directory", "Working Directory", text(session.directory)),
            row("parent", "Parent Session", text(metadata?.parentSession ?? session.parentID)),
            row("origin", "Origin", text(metadata?.origin)),
            row("seeded", "Forked History", metadata?.isSeeded.map(SessionMetadataValue.boolean) ?? .unavailable),
            row("depth", "Delegation Depth", integer(metadata?.delegationDepth)),
            row("version", "Session Format Version", integer(metadata?.version)),
            row("created", "Created", date(metadata?.createdAt ?? session.time?.created)),
            row("updated", "Last Activity", date(session.time?.updated)),
            row("last-prompt", "Last Prompt", date(number(list[dsh: "lastPromptAt"]))),
            row("blank", "Blank Session", boolean(list[dsh: "blank"])),
            row("current", "Live Metadata", .boolean(metadata?.isCurrent == true))
        ])
    }

    private static func goalSection(_ projection: DSHJSON) -> SessionMetadataSection {
        let goal = projection[dsh: "goal"]
        return .init(id: "goal", title: "Goal", rows: [
            row("objective", "Objective", text(goal[dsh: "objective"].dshString)),
            row("phase", "Phase", text(goal[dsh: "phase"].dshString)),
            row("rounds", "Rounds Started", integer(count(projection[dsh: "roundsStarted"]))),
            row("max-rounds", "Maximum Rounds", integer(count(goal[dsh: "maxGoalRounds"]))),
            row("id", "Goal ID", text(goal[dsh: "id"].dshString)),
            row("revision", "Revision", integer(count(goal[dsh: "revision"]))),
            row("blocked-code", "Blocked Reason Code", text(goal[dsh: "blockedReason"][dsh: "code"].dshString)),
            row("blocked-message", "Blocked Reason", text(goal[dsh: "blockedReason"][dsh: "message"].dshString)),
            row("created", "Created", date(number(projection[dsh: "createdAt"]))),
            row("updated", "Updated", date(number(projection[dsh: "updatedAt"])))
        ])
    }

    private static func row(_ id: String, _ label: LocalizedStringResource, _ value: SessionMetadataValue) -> SessionMetadataRow {
        .init(id: id, label: label, value: value)
    }
    private static func count(_ value: DSHJSON) -> Int? {
        guard let value = value.intValue, value >= 0 else { return nil }
        return value
    }
    private static func number(_ value: DSHJSON) -> Double? {
        guard let value = value.doubleValue, value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return value
    }
    private static func sum(_ values: [Int?]) -> Int? {
        var total = 0
        for value in values {
            guard let value else { return nil }
            let sum = total.addingReportingOverflow(value)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }
    private static func integer(_ value: Int?) -> SessionMetadataValue { value.map(SessionMetadataValue.integer) ?? .unavailable }
    private static func text(_ value: String?) -> SessionMetadataValue { value.map(SessionMetadataValue.text) ?? .unavailable }
    private static func boolean(_ value: DSHJSON) -> SessionMetadataValue {
        guard case .bool(let value) = value else { return .unavailable }
        return .boolean(value)
    }
    private static func duration(_ value: DSHJSON) -> SessionMetadataValue { number(value).map(SessionMetadataValue.durationMilliseconds) ?? .unavailable }
    private static func date(_ value: Double?) -> SessionMetadataValue {
        guard let value, value.isFinite, value >= 0, value <= 253_402_300_799_999 else { return .unavailable }
        return .dateMilliseconds(value)
    }
    private static func displayJSON(_ value: DSHJSON) -> SessionMetadataValue {
        if case .string(let string) = value { return .text(string) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return .unavailable }
        return .text(text)
    }
}
