import SwiftUI

struct GitDiffView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GitDiffContent(
            hasGitProject: viewModel.hasGitProject,
            snapshot: viewModel.projectFilesSnapshot,
            relativeGitPath: { viewModel.relativeGitPath($0) }
        )
    }
}

private struct GitDiffContent: View {
    let hasGitProject: Bool
    let snapshot: AppViewModel.ProjectFilesSnapshot
    let relativeGitPath: (String) -> String

    private var diff: OpenCodeVCSFileDiff? {
        snapshot.selectedFileDiff
    }

    var body: some View {
        Group {
            if !hasGitProject {
                ContentUnavailableView("Git Unavailable", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            } else if let diff {
                OpenCodeUnifiedDiffView(
                    diff: OpenCodeUnifiedDiffData(
                        file: relativeGitPath(diff.file),
                        patch: diff.patch,
                        additions: diff.additions,
                        deletions: diff.deletions,
                        status: diff.status
                    )
                )
                .navigationTitle(fileTitle(for: diff.file))
                .opencodeInlineNavigationTitle()
            } else if let selectedFile = snapshot.selectedVCSFile {
                ContentUnavailableView(
                    "Diff Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(relativeGitPath(selectedFile))
                )
            } else {
                ContentUnavailableView("Select a Changed File", systemImage: "doc.text")
            }
        }
    }

    private func fileTitle(for path: String) -> String {
        relativeGitPath(path).split(separator: "/").last.map(String.init) ?? path
    }
}

struct ProjectFileContentView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ProjectFileContent(
            hasGitProject: viewModel.hasGitProject,
            snapshot: viewModel.projectFilesSnapshot,
            relativeGitPath: { viewModel.relativeGitPath($0) },
            onLoadSelectedFileContent: {
                await viewModel.loadSelectedProjectFileContentIfNeeded()
            }
        )
    }
}

private struct ProjectFileContent: View {
    let hasGitProject: Bool
    let snapshot: AppViewModel.ProjectFilesSnapshot
    let relativeGitPath: (String) -> String
    let onLoadSelectedFileContent: () async -> Void

    var body: some View {
        Group {
            if !hasGitProject {
                ContentUnavailableView("Files Unavailable", systemImage: "doc")
            } else if let path = snapshot.selectedFilePath,
                      let content = snapshot.selectedFileContent {
                fileContent(content, path: path)
                    .navigationTitle(fileTitle(for: path))
                    .opencodeInlineNavigationTitle()
            } else if snapshot.isLoadingSelectedFileContent,
                      let path = snapshot.selectedFilePath {
                ContentUnavailableView(
                    "Loading File",
                    systemImage: "doc.text",
                    description: Text(relativeGitPath(path))
                )
            } else if let error = snapshot.fileContentErrorMessage,
                      let path = snapshot.selectedFilePath {
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text("\(relativeGitPath(path))\n\n\(error)")
                )
            } else if let path = snapshot.selectedFilePath {
                ContentUnavailableView(
                    "Select a File",
                    systemImage: "doc",
                    description: Text(relativeGitPath(path))
                )
            } else {
                ContentUnavailableView("Select a File", systemImage: "doc")
            }
        }
        .task(id: snapshot.selectedFilePath) {
            await onLoadSelectedFileContent()
        }
    }

    @ViewBuilder
    private func fileContent(_ content: OpenCodeFileContent, path: String) -> some View {
        if content.type == "binary" {
            ContentUnavailableView(
                "Binary File",
                systemImage: "doc.fill",
                description: Text(relativeGitPath(path))
            )
        } else {
            ScrollView(.vertical) {
                HighlightedCodeBlock(
                    code: content.content,
                    language: OpenCodeCodeLanguage.infer(fromPath: path)
                )
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(OpenCodePlatformColor.groupedBackground)
        }
    }

    private func fileTitle(for path: String) -> String {
        relativeGitPath(path).split(separator: "/").last.map(String.init) ?? path
    }
}

struct OpenCodeUnifiedDiffData: Identifiable, Hashable, Sendable {
    let file: String
    let patch: String
    let additions: Int
    let deletions: Int
    let status: String?

    var id: String { file }
}

struct OpenCodeUnifiedDiffView: View {
    let diff: OpenCodeUnifiedDiffData
    var showsHeader = true

    private var language: String? {
        OpenCodeCodeLanguage.infer(fromPath: diff.file)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        header(diff)
                            .padding(16)
                    }

                    ForEach(GitPatchParser.parse(diff.patch)) { line in
                        DiffLineRow(line: line, language: language)
                            .frame(minWidth: geometry.size.width, alignment: .leading)
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .background(OpenCodePlatformColor.groupedBackground)
        }
    }

    private func header(_ diff: OpenCodeUnifiedDiffData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(diff.file)
                .font(.headline)

            HStack(spacing: 12) {
                Text(statusTitle(diff.status))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(statusColor(diff.status))
                Text("+\(diff.additions)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.green)
                Text("-\(diff.deletions)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
    }

    private func statusTitle(_ status: String?) -> String {
        switch status {
        case "added":
            return "Added"
        case "deleted":
            return "Deleted"
        default:
            return "Modified"
        }
    }

    private func statusColor(_ status: String?) -> Color {
        switch status {
        case "added":
            return .green
        case "deleted":
            return .red
        default:
            return .orange
        }
    }
}

private struct DiffLineRow: View {
    let line: GitPatchParser.Line
    let language: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutterText(line.oldLineNumber)
            gutterText(line.newLineNumber)

            Text(verbatim: line.prefix)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(line.foregroundColor)
                .frame(width: 18, alignment: .center)

            lineContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background(line.backgroundColor)
    }

    private var lineContent: some View {
        Group {
            if line.shouldSyntaxHighlight,
               let language,
               let attributed = OpenCodeSyntaxHighlighter.shared.highlight(line.content, language: language, colorScheme: colorScheme) {
                Text(attributed)
            } else {
                Text(verbatim: line.content.isEmpty ? " " : line.content)
                    .foregroundStyle(line.foregroundColor)
            }
        }
        .font(.system(.footnote, design: .monospaced))
    }

    private func gutterText(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 8)
            .textSelection(.enabled)
    }
}

enum GitPatchParser {
    struct Line: Identifiable {
        enum Kind {
            case header
            case hunk
            case addition
            case deletion
            case context
        }

        let id: Int
        let text: String
        let kind: Kind
        let oldLineNumber: Int?
        let newLineNumber: Int?

        var prefix: String {
            guard let first = text.first else { return "" }
            switch kind {
            case .addition, .deletion, .context:
                return String(first)
            case .header:
                return ""
            case .hunk:
                return "@"
            }
        }

        var content: String {
            switch kind {
            case .addition, .deletion, .context:
                return String(text.dropFirst())
            case .hunk:
                return text
            case .header:
                return text
            }
        }

        var backgroundColor: Color {
            switch kind {
            case .header:
                return OpenCodePlatformColor.secondaryGroupedBackground
            case .hunk:
                return Color.blue.opacity(0.10)
            case .addition:
                return Color.green.opacity(0.12)
            case .deletion:
                return Color.red.opacity(0.12)
            case .context:
                return .clear
            }
        }

        var foregroundColor: Color {
            switch kind {
            case .header:
                return .secondary
            case .hunk:
                return .blue
            case .addition:
                return .green
            case .deletion:
                return .red
            case .context:
                return .primary
            }
        }

        var shouldSyntaxHighlight: Bool {
            switch kind {
            case .addition, .deletion, .context:
                return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .header, .hunk:
                return false
            }
        }
    }

    static func parse(_ patch: String) -> [Line] {
        let rows = patch.components(separatedBy: .newlines)
        var lines: [Line] = []
        var oldLineNumber: Int?
        var newLineNumber: Int?

        for (index, raw) in rows.enumerated() {
            let kind: Line.Kind
            let oldValue: Int?
            let newValue: Int?

            if raw.hasPrefix("@@") {
                kind = .hunk
                let range = parseHunkRange(raw)
                oldLineNumber = range?.oldStart
                newLineNumber = range?.newStart
                oldValue = nil
                newValue = nil
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") || raw.hasPrefix("diff --git") || raw.hasPrefix("index ") || raw.hasPrefix("new file mode") || raw.hasPrefix("deleted file mode") {
                kind = .header
                oldValue = nil
                newValue = nil
            } else if raw.hasPrefix("+") {
                kind = .addition
                oldValue = nil
                newValue = newLineNumber
                if newLineNumber != nil {
                    selfIncrement(&newLineNumber)
                }
            } else if raw.hasPrefix("-") {
                kind = .deletion
                oldValue = oldLineNumber
                newValue = nil
                if oldLineNumber != nil {
                    selfIncrement(&oldLineNumber)
                }
            } else {
                kind = .context
                oldValue = oldLineNumber
                newValue = newLineNumber
                if oldLineNumber != nil {
                    selfIncrement(&oldLineNumber)
                }
                if newLineNumber != nil {
                    selfIncrement(&newLineNumber)
                }
            }

            lines.append(
                Line(
                    id: index,
                    text: raw,
                    kind: kind,
                    oldLineNumber: oldValue,
                    newLineNumber: newValue
                )
            )
        }

        return lines
    }

    private static func parseHunkRange(_ line: String) -> (oldStart: Int, newStart: Int)? {
        guard let firstSpace = line.firstIndex(of: " "),
              let secondSpace = line[line.index(after: firstSpace)...].firstIndex(of: " ") else {
            return nil
        }

        let oldToken = String(line[line.index(after: firstSpace)..<secondSpace])
        let remainderStart = line.index(after: secondSpace)
        let remainder = line[remainderStart...]
        guard let thirdSpace = remainder.firstIndex(of: " ") else {
            return nil
        }

        let newToken = String(remainder[..<thirdSpace])
        guard let oldStart = parseRangeStart(oldToken),
              let newStart = parseRangeStart(newToken) else {
            return nil
        }

        return (oldStart, newStart)
    }

    private static func parseRangeStart(_ token: String) -> Int? {
        guard let sign = token.first, sign == "-" || sign == "+" else {
            return nil
        }

        let body = token.dropFirst()
        let startText = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? String(body)
        return Int(startText)
    }

    private static func selfIncrement(_ value: inout Int?) {
        guard let current = value else { return }
        value = current + 1
    }
}
