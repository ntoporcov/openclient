import SwiftUI
import Highlighter

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct HighlightedCodeBlock: View {
    let code: String
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label = languageLabel {
                HStack {
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer(minLength: 8)

                    Button {
                        OpenCodeClipboard.copy(code)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(headerBackgroundStyle)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                highlightedText
                    .padding(12)
            }
        }
        .background(blockBackgroundStyle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderStyle, lineWidth: 1)
        }
        .textSelection(.enabled)
    }

    private var highlightedText: some View {
        Group {
            if shouldUsePlainTextFallback {
                Text(verbatim: code)
                    .foregroundStyle(.primary)
            } else if let attributed = OpenCodeSyntaxHighlighter.shared.highlight(code, language: language, colorScheme: colorScheme) {
                Text(attributed)
            } else {
                Text(verbatim: code)
                    .foregroundStyle(.primary)
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .lineSpacing(3)
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shouldUsePlainTextFallback: Bool {
        if code.count > 12_000 {
            return true
        }

        return code.filter(\.isNewline).count > 260
    }

    private var languageLabel: String? {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty else {
            return nil
        }

        return language
    }

    private var blockBackgroundStyle: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
    }

    private var headerBackgroundStyle: Color {
        colorScheme == .dark ? Color.white.opacity(0.055) : Color.black.opacity(0.045)
    }

    private var borderStyle: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

enum OpenCodeCodeLanguage {
    static func infer(fromPath path: String) -> String? {
        let filename = path.split(separator: "/").last.map(String.init) ?? path
        let lowercasedFilename = filename.lowercased()

        if let exact = exactFilenameLanguages[lowercasedFilename] {
            return exact
        }

        guard let ext = lowercasedFilename.split(separator: ".").last.map(String.init), ext != lowercasedFilename else {
            return nil
        }

        return extensionLanguages[ext]
    }

    private static let exactFilenameLanguages: [String: String] = [
        ".bash_profile": "bash",
        ".bashrc": "bash",
        ".gitignore": "plaintext",
        ".zshrc": "bash",
        "dockerfile": "dockerfile",
        "gemfile": "ruby",
        "makefile": "makefile",
        "package.resolved": "json",
        "podfile": "ruby"
    ]

    private static let extensionLanguages: [String: String] = [
        "bash": "bash",
        "c": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cs": "csharp",
        "css": "css",
        "diff": "diff",
        "go": "go",
        "h": "cpp",
        "html": "xml",
        "java": "java",
        "js": "javascript",
        "json": "json",
        "jsx": "javascript",
        "kt": "kotlin",
        "m": "objectivec",
        "md": "markdown",
        "mm": "objectivec",
        "patch": "diff",
        "plist": "xml",
        "py": "python",
        "rb": "ruby",
        "rs": "rust",
        "sh": "bash",
        "sql": "sql",
        "swift": "swift",
        "toml": "toml",
        "ts": "typescript",
        "tsx": "typescript",
        "xml": "xml",
        "yaml": "yaml",
        "yml": "yaml",
        "zsh": "bash"
    ]
}

@MainActor
final class OpenCodeSyntaxHighlighter {
    private struct CacheKey: Hashable {
        let codeHash: Int
        let characterCount: Int
        let language: String?
        let theme: String
    }

    static let shared = OpenCodeSyntaxHighlighter()

    private let highlighter: Highlighter?
    private var configuredTheme: String?
    private var highlightedCodeCache: [CacheKey: AttributedString] = [:]

    private init() {
        highlighter = Highlighter()
        highlighter?.ignoreIllegals = true
    }

    func highlight(_ code: String, language: String?, colorScheme: ColorScheme) -> AttributedString? {
        guard !code.isEmpty, let highlighter else { return nil }

        let normalizedLanguage = normalizedLanguage(language)
        let theme = themeName(for: normalizedLanguage, colorScheme: colorScheme)
        let cacheKey = CacheKey(codeHash: code.hashValue, characterCount: code.count, language: normalizedLanguage, theme: theme)
        if let cached = highlightedCodeCache[cacheKey] {
            return cached
        }

        configureTheme(named: theme)

        guard let highlighted = highlighter.highlight(code, as: normalizedLanguage) else {
            return nil
        }

        guard let attributed = platformAttributedString(from: highlighted) else {
            return nil
        }

        if highlightedCodeCache.count >= 96 {
            highlightedCodeCache.removeAll(keepingCapacity: true)
        }
        highlightedCodeCache[cacheKey] = attributed
        return attributed
    }

    private func configureTheme(named theme: String) {
        guard configuredTheme != theme else { return }

        if highlighter?.setTheme(theme, withFont: codeFontName, ofSize: 13) == true {
            configuredTheme = theme
        }
    }

    private func themeName(for language: String?, colorScheme: ColorScheme) -> String {
        if language == "swift" {
            return colorScheme == .dark ? "xcode-dusk" : "xcode"
        }

        return colorScheme == .dark ? "github-dark" : "github"
    }

    private func normalizedLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }

        return languageAliases[raw] ?? raw
    }

    private var codeFontName: String {
#if canImport(UIKit)
        return UIFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
#elseif canImport(AppKit)
        return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName
#else
        return "Menlo-Regular"
#endif
    }

    private let languageAliases: [String: String] = [
        "c++": "cpp",
        "c#": "csharp",
        "cjs": "javascript",
        "console": "bash",
        "es6": "javascript",
        "js": "javascript",
        "jsx": "javascript",
        "kt": "kotlin",
        "md": "markdown",
        "mjs": "javascript",
        "patch": "diff",
        "ps1": "powershell",
        "py": "python",
        "rb": "ruby",
        "sh": "bash",
        "shell": "bash",
        "ts": "typescript",
        "tsx": "typescript",
        "yml": "yaml"
    ]

    private func platformAttributedString(from attributedString: NSAttributedString) -> AttributedString? {
#if canImport(UIKit)
        return try? AttributedString(attributedString, including: \.uiKit)
#elseif canImport(AppKit)
        return try? AttributedString(attributedString, including: \.appKit)
#else
        return try? AttributedString(attributedString, including: \.foundation)
#endif
    }
}
