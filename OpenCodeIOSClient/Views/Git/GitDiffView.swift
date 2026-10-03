import SwiftUI

struct GitDiffView: View {
    @ObservedObject var facade: ProjectFilesFacade

    var body: some View {
        GitDiffContent(
            hasGitProject: facade.hasGitProject,
            snapshot: facade.snapshot,
            relativeGitPath: { facade.relativeGitPath($0) },
            onLoadDiff: { mode in await facade.loadVCSDiff(mode: mode) },
            onLoadSelectedFileContent: {
                await facade.loadSelectedFileContentIfNeeded()
            }
        )
    }
}

private struct GitDiffContent: View {
    let hasGitProject: Bool
    let snapshot: ProjectFilesFacade.Snapshot
    let relativeGitPath: (String) -> String
    let onLoadDiff: (OpenCodeVCSDiffMode) async -> Void
    let onLoadSelectedFileContent: () async -> Void

    private var diff: OpenCodeVCSFileDiff? {
        snapshot.selectedFileDiff
    }

    var body: some View {
        Group {
            if !hasGitProject {
                ContentUnavailableView("Git Unavailable", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
            } else if let path = snapshot.selectedFilePath,
                      OpenCodeFilePreviewSupport.isImagePath(path),
                      let content = snapshot.selectedFileContent,
                      let image = OpenCodeFilePreview.image(from: content) {
                OpenCodeImageFilePreview(image: image, path: relativeGitPath(path))
                    .navigationTitle(fileTitle(for: path))
                    .opencodeInlineNavigationTitle()
            } else if let path = snapshot.selectedFilePath,
                      OpenCodeFilePreviewSupport.isImagePath(path),
                      snapshot.isLoadingSelectedFileContent {
                ContentUnavailableView(
                    "Loading Image",
                    systemImage: "photo",
                    description: Text(relativeGitPath(path))
                )
            } else if let path = snapshot.selectedFilePath,
                      OpenCodeFilePreviewSupport.isImagePath(path) {
                if snapshot.fileContentErrorMessage == nil {
                    ContentUnavailableView(
                        "Loading Image",
                        systemImage: "photo",
                        description: Text(relativeGitPath(path))
                    )
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text([relativeGitPath(path), snapshot.fileContentErrorMessage].compactMap { $0 }.joined(separator: "\n\n"))
                    )
                }
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
        .task(id: diffLoadTaskID) {
            guard snapshot.selectedFilePath != nil || snapshot.selectedVCSFile != nil else { return }
            await onLoadDiff(snapshot.selectedMode)
            if let path = snapshot.selectedFilePath, OpenCodeFilePreviewSupport.isImagePath(path) {
                await onLoadSelectedFileContent()
            }
        }
    }

    private var diffLoadTaskID: String {
        [snapshot.effectiveDirectory ?? "", snapshot.selectedMode.rawValue, snapshot.selectedFilePath ?? snapshot.selectedVCSFile ?? ""]
            .joined(separator: "|")
    }

    private func fileTitle(for path: String) -> String {
        relativeGitPath(path).split(separator: "/").last.map(String.init) ?? path
    }
}

struct ProjectFileContentView: View {
    @ObservedObject var facade: ProjectFilesFacade

    var body: some View {
        ProjectFileContent(
            hasGitProject: facade.hasGitProject,
            snapshot: facade.snapshot,
            relativeGitPath: { facade.relativeGitPath($0) },
            onLoadSelectedFileContent: {
                await facade.loadSelectedFileContentIfNeeded()
            }
        )
    }
}

private struct ProjectFileContent: View {
    let hasGitProject: Bool
    let snapshot: ProjectFilesFacade.Snapshot
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
        if let image = OpenCodeFilePreview.image(from: content), OpenCodeFilePreviewSupport.isImagePath(path) {
            OpenCodeImageFilePreview(image: image, path: relativeGitPath(path))
        } else if content.type == "binary" {
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

enum OpenCodeFilePreview {
    static func image(from content: OpenCodeFileContent) -> Image? {
        guard let data = OpenCodeFilePreviewSupport.imageData(from: content) else { return nil }
#if canImport(UIKit)
        guard let platformImage = UIImage(data: data) else { return nil }
        return Image(uiImage: platformImage)
#elseif canImport(AppKit)
        guard let platformImage = NSImage(data: data) else { return nil }
        return Image(nsImage: platformImage)
#endif
    }
}

private struct OpenCodeImageFilePreview: View {
    let image: Image
    let path: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    image
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                        .frame(
                            maxWidth: max(geometry.size.width - 32, 0),
                            maxHeight: max(geometry.size.height - 64, 240),
                            alignment: .center
                        )
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(16)
                .frame(maxWidth: geometry.size.width, alignment: .leading)
            }
            .background(OpenCodePlatformColor.groupedBackground)
        }
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
    @State private var collapsesUnchangedLines = true

    private var language: String? {
        OpenCodeCodeLanguage.infer(fromPath: diff.file)
    }

    var body: some View {
        let lines = GitPatchParser.parse(diff.patch)
        let rows = GitPatchParser.displayRows(lines, collapsingUnchangedLines: collapsesUnchangedLines)
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showsHeader {
                        header(diff)
                            .padding(16)
                    }

                    ForEach(rows) { row in
                        switch row {
                        case let .line(line):
                            DiffLineRow(line: line, language: language)
                                .frame(minWidth: geometry.size.width, alignment: .leading)
                        case let .collapsed(_, count):
                            Text(count == 1 ? LocalizedStringResource("1 unchanged line") : LocalizedStringResource("\(count) unchanged lines"))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(minWidth: geometry.size.width, alignment: .leading)
                                .background(.quaternary)
                        }
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .background(OpenCodePlatformColor.groupedBackground)
            .opencodeSoftScrollEdgeEffect()
        }
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    collapsesUnchangedLines.toggle()
                } label: {
                    Label(collapsesUnchangedLines ? LocalizedStringResource("Expand Unchanged Lines") : LocalizedStringResource("Collapse Unchanged Lines"),
                        systemImage: collapsesUnchangedLines ? "arrow.up.and.down" : "arrow.down.and.line.horizontal.and.arrow.up")
                }
                .accessibilityIdentifier("diff.toggleUnchangedLines")
            }
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

    private func statusTitle(_ status: String?) -> LocalizedStringResource {
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

    enum DisplayRow: Identifiable {
        case line(Line)
        case collapsed(id: Int, count: Int)

        var id: Int {
            switch self {
            case let .line(line): return line.id
            case let .collapsed(id, _): return id
            }
        }
    }

    static func displayRows(_ lines: [Line], collapsingUnchangedLines: Bool) -> [DisplayRow] {
        guard collapsingUnchangedLines else { return lines.map(DisplayRow.line) }
        var rows: [DisplayRow] = []
        var index = 0
        while index < lines.count {
            let start = index
            while index < lines.count, lines[index].kind == .context,
                  lines[index].text.hasPrefix(" "), lines[index].oldLineNumber != nil {
                index += 1
            }
            let count = index - start
            if count > 6 {
                rows += lines[start..<(start + 3)].map(DisplayRow.line)
                rows.append(.collapsed(id: lines[start + 3].id, count: count - 6))
                rows += lines[(index - 3)..<index].map(DisplayRow.line)
            } else if count > 0 {
                rows += lines[start..<index].map(DisplayRow.line)
            } else {
                rows.append(.line(lines[index]))
                index += 1
            }
        }
        return rows
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
