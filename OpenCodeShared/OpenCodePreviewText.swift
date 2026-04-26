import Foundation

func opencodePreviewText(_ text: String, limit: Int = 140) -> String? {
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

    guard let line = lines.last else { return nil }
    return String(line.prefix(limit))
}

private func isMarkdownFence(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix("~~~")
}

private func stripLeadingMarkdown(_ line: String) -> String {
    var value = line

    while value.hasPrefix("#") {
        value.removeFirst()
        value = value.trimmingCharacters(in: .whitespaces)
    }

    for prefix in ["> ", "- ", "* ", "+ "] {
        if value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
            return value.trimmingCharacters(in: .whitespaces)
        }
    }

    return value
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
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return value }
    let range = NSRange(value.startIndex..., in: value)
    return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: template)
}
