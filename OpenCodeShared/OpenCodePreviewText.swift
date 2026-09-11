import Foundation

private let previewMarkdownExpressions: [String: NSRegularExpression] = {
    let patterns = [
        #"^#{1,6}\s*"#, #"^>\s*"#, #"^(?:[-*+•]|\d+[.)])\s+"#, #"^\[[ xX]\]\s+"#,
        #"!\[([^\]]*)\]\([^\)]*\)"#, #"\[([^\]]+)\]\([^\)]*\)"#,
        #"`{1,3}([^`]+)`{1,3}"#, #"\*\*([^*]+)\*\*"#, #"__([^_]+)__"#,
        #"(?<!\*)\*([^*]+)\*(?!\*)"#, #"(?<!_)_([^_]+)_(?!_)"#,
    ]
    return Dictionary(uniqueKeysWithValues: patterns.compactMap { pattern in
        (try? NSRegularExpression(pattern: pattern)).map { (pattern, $0) }
    })
}()

func opencodePreviewText(_ text: String, limit: Int? = 140) -> String? {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")

    let lines = normalized
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .filter { !isMarkdownFence($0) }
        .map(stripLeadingMarkdown)
        .map(stripInlineMarkdown)
        .filter { !$0.isEmpty }

    let preview = lines.joined(separator: " · ")
    guard !preview.isEmpty else { return nil }
    guard let limit, preview.count > limit else { return preview }
    guard limit > 1 else { return String(preview.suffix(max(0, limit))) }
    return "…" + String(preview.suffix(limit - 1))
}

private func isMarkdownFence(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix("~~~")
}

private func stripLeadingMarkdown(_ line: String) -> String {
    var value = replacingMatches(#"^#{1,6}\s*"#, in: line, template: "")
    value = replacingMatches(#"^>\s*"#, in: value, template: "")
    value = replacingMatches(#"^(?:[-*+•]|\d+[.)])\s+"#, in: value, template: "")
    value = replacingMatches(#"^\[[ xX]\]\s+"#, in: value, template: "")
    return value.trimmingCharacters(in: .whitespaces)
}

private func stripInlineMarkdown(_ line: String) -> String {
    var value = line
    value = replacingMatches(#"!\[([^\]]*)\]\([^\)]*\)"#, in: value, template: "$1")
    value = replacingMatches(#"\[([^\]]+)\]\([^\)]*\)"#, in: value, template: "$1")
    value = replacingMatches(#"`{1,3}([^`]+)`{1,3}"#, in: value, template: "$1")
    value = replacingMatches(#"\*\*([^*]+)\*\*"#, in: value, template: "$1")
    value = replacingMatches(#"__([^_]+)__"#, in: value, template: "$1")
    value = replacingMatches(#"(?<!\*)\*([^*]+)\*(?!\*)"#, in: value, template: "$1")
    value = replacingMatches(#"(?<!_)_([^_]+)_(?!_)"#, in: value, template: "$1")
    return value.trimmingCharacters(in: CharacterSet(charactersIn: "`*_ ").union(.whitespacesAndNewlines))
}

private func replacingMatches(_ pattern: String, in value: String, template: String) -> String {
    guard let regex = previewMarkdownExpressions[pattern] else { return value }
    let range = NSRange(value.startIndex..., in: value)
    return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
}
