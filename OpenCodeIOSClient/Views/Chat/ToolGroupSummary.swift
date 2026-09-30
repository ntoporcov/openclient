import Foundation

struct ToolGroupSummary {
    let title: String
    let caption: String
    let toolCallCount: Int

    init(parts: [OpenCodePart]) {
        let tools = parts.filter(OpenCodeToolActivityPolicy.isToolCall)
        toolCallCount = tools.count
        if tools.isEmpty {
            let hasContext = parts.contains { $0.timelineContextType != nil }
            title = hasContext ? String(localized: "Context") : String(localized: "Reasoning")
            caption = hasContext ? "" : String((parts.compactMap(\.text).first ?? "").prefix(160))
            return
        }
        let running = tools.contains(where: OpenCodeToolActivityPolicy.isRunning)
        let verbs = tools.map { part -> String in
            let name = OpenCodeToolActivityPolicy.toolName(for: part).lowercased()
            switch name {
            case "shell", "bash": return running ? String(localized: "Running commands") : String(localized: "Ran commands")
            case "read", "list": return running ? String(localized: "Reading files") : String(localized: "Read files")
            case "grep", "glob", "websearch", "web_search": return running ? String(localized: "Searching") : String(localized: "Searched")
            case "patch", "apply_patch", "edit", "write", "multiedit": return running ? String(localized: "Editing files") : String(localized: "Edited files")
            case "webfetch", "web_fetch": return running ? String(localized: "Fetching pages") : String(localized: "Fetched pages")
            default: return running ? String(localized: "Using tools") : String(localized: "Used tools")
            }
        }
        var unique: [String] = []
        for verb in verbs where !unique.contains(verb) { unique.append(verb) }
        title = unique.formatted(.list(type: .and))
        let details = tools.compactMap { part -> String? in
            let input = part.state?.input
            let name = OpenCodeToolActivityPolicy.toolName(for: part).lowercased()
            let detail: String?
            switch name {
            case "read", "list", "patch", "apply_patch", "edit", "write", "multiedit":
                detail = input?.filePath.map { ($0 as NSString).lastPathComponent }
            case "shell", "bash", "grep", "glob", "websearch", "web_search", "webfetch", "web_fetch":
                detail = input?.description
            default:
                return nil
            }
            guard let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !detail.isEmpty, detail.count <= 80, !detail.contains(where: \.isNewline) else { return nil }
            return detail
        }
        var distinct: [String] = []
        for detail in details where !distinct.contains(detail) { distinct.append(detail) }
        let count = tools.count
        let countLabel = count == 1 ? String(localized: "1 tool call") : String(localized: "\(count) tool calls")
        caption = ([countLabel] + distinct.prefix(2)).joined(separator: " · ")
    }
}
