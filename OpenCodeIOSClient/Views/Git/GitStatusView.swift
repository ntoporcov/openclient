import SwiftUI

struct GitStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    let onFileChosen: () -> Void

    var body: some View {
        GitStatusContent(
            snapshot: viewModel.projectFilesSnapshot,
            workspaceDirectories: viewModel.workspaceDirectories(),
            workspaceDisplayName: { viewModel.workspaceDisplayName(for: $0) },
            relativeGitPath: { viewModel.relativeGitPath($0) },
            isExpandedDirectory: { viewModel.isExpandedDirectory($0) },
            aggregateStatus: { viewModel.aggregateStatus(for: $0) },
            onSelectWorkspace: { viewModel.selectFilesWorkspaceDirectory($0) },
            onSelectMode: { viewModel.selectProjectFilesMode($0) },
            onSelectVCSFile: { path in
                viewModel.selectVCSFile(path)
                withAnimation(opencodeSelectionAnimation) {
                    onFileChosen()
                }
            },
            onToggleDirectory: { viewModel.toggleFileTreeDirectory($0) },
            onSelectProjectFile: { node in
                viewModel.selectProjectFile(node)
                withAnimation(opencodeSelectionAnimation) {
                    onFileChosen()
                }
            },
            onLoadGitData: { await viewModel.loadGitViewDataIfNeeded() },
            onLoadFileTree: { await viewModel.loadFileTreeIfNeeded() }
        )
    }
}

private struct GitStatusContent: View {
    let snapshot: AppViewModel.ProjectFilesSnapshot
    let workspaceDirectories: [String]
    let workspaceDisplayName: (String?) -> String?
    let relativeGitPath: (String) -> String
    let isExpandedDirectory: (String) -> Bool
    let aggregateStatus: (OpenCodeFileNode) -> OpenCodeVCSAggregateStatus?
    let onSelectWorkspace: (String) -> Void
    let onSelectMode: (OpenCodeProjectFilesMode) -> Void
    let onSelectVCSFile: (String) -> Void
    let onToggleDirectory: (OpenCodeFileNode) -> Void
    let onSelectProjectFile: (OpenCodeFileNode) -> Void
    let onLoadGitData: () async -> Void
    let onLoadFileTree: () async -> Void

    private var statusIDs: String {
        snapshot.fileStatuses.map(\.id).joined(separator: "|")
    }

    var body: some View {
        List {
            if let info = snapshot.vcsInfo {
                Section("Repository") {
                    HStack(spacing: 12) {
                        Label(info.branch ?? "Unknown", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.subheadline.weight(.medium))

                        Spacer()

                        if let defaultBranch = info.defaultBranch, defaultBranch != info.branch {
                            Text("base \(defaultBranch)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !snapshot.intensityFiles.isEmpty {
                Section {
                    GitSummaryCard(
                        summary: snapshot.summary,
                        branch: snapshot.vcsInfo?.branch,
                        modeTitle: snapshot.selectedMode.title
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                    GitIntensityStrip(
                        files: snapshot.intensityFiles,
                        selectedPath: snapshot.selectedVCSFile,
                        onSelect: onSelectVCSFile
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if !workspaceDirectories.isEmpty {
                Section {
                    Picker("Workspace", selection: Binding(
                        get: { snapshot.effectiveDirectory ?? workspaceDirectories.first ?? "" },
                        set: { directory in onSelectWorkspace(directory) }
                    )) {
                        ForEach(workspaceDirectories, id: \.self) { directory in
                            Text(workspaceDisplayName(directory) ?? URL(fileURLWithPath: directory).lastPathComponent)
                                .tag(directory)
                        }
                    }
                }
            }

            Section {
                Picker("Files Mode", selection: Binding(
                    get: { snapshot.filesMode },
                    set: { mode in onSelectMode(mode) }
                )) {
                    ForEach(OpenCodeProjectFilesMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if let errorMessage = snapshot.vcsErrorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            if snapshot.filesMode == .tree,
               let treeError = snapshot.fileTreeErrorMessage {
                Section("File Tree Error") {
                    Text(treeError)
                        .foregroundStyle(.red)
                }
            }

            if snapshot.filesMode == .changes {
                Section(workspaceDisplayName(snapshot.effectiveDirectory) ?? "Working Tree") {
                    changesSectionContent
                }
            } else {
                Section("Project Tree") {
                    treeSectionContent
                }
            }
        }
        .listStyle(.plain)
        .task {
            await onLoadGitData()
        }
        .task(id: snapshot.filesMode) {
            if snapshot.filesMode == .tree {
                await onLoadFileTree()
            }
        }
        .task(id: snapshot.effectiveDirectory ?? "") {
            await onLoadGitData()
            if snapshot.filesMode == .tree {
                await onLoadFileTree()
            }
        }
        .animation(opencodeSelectionAnimation, value: statusIDs)
        .animation(opencodeSelectionAnimation, value: snapshot.selectedVCSFile ?? "")
    }

    private func relativeTitle(for path: String) -> String {
        let relative = relativeGitPath(path)
        return relative.split(separator: "/").last.map(String.init) ?? relative
    }

    private func relativeSubtitle(for path: String) -> String? {
        let relative = relativeGitPath(path)
        let components = relative.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    @ViewBuilder
    private var changesSectionContent: some View {
        if snapshot.isLoadingVCS && snapshot.fileStatuses.isEmpty {
            ProgressView("Loading changes")
        } else if snapshot.fileStatuses.isEmpty {
            Text("No changes")
                .foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.fileStatuses) { file in
                Button {
                    onSelectVCSFile(file.path)
                } label: {
                    GitStatusRow(
                        title: relativeTitle(for: file.path),
                        subtitle: relativeSubtitle(for: file.path),
                        status: file.status,
                        additions: file.added,
                        deletions: file.removed,
                        selected: snapshot.selectedFilePath == file.path
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(snapshot.selectedFilePath == file.path ? Color.blue.opacity(0.10) : Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
        }
    }

    @ViewBuilder
    private var treeSectionContent: some View {
        if snapshot.isLoadingFileTree && snapshot.visibleRows.isEmpty {
            ProgressView("Loading files")
        } else if snapshot.visibleRows.isEmpty {
            Text("No files")
                .foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.visibleRows) { row in
                GitFileTreeRow(
                    row: row,
                    isExpanded: isExpandedDirectory(row.node.absolute),
                    isSelected: snapshot.selectedFilePath == row.node.absolute,
                    aggregateStatus: aggregateStatus(row.node),
                    onToggleDirectory: {
                        onToggleDirectory(row.node)
                    },
                    onSelectFile: {
                        onSelectProjectFile(row.node)
                    }
                )
                .listRowBackground(snapshot.selectedFilePath == row.node.absolute ? Color.blue.opacity(0.10) : Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }
        }
    }
}

private struct GitFileTreeRow: View {
    let row: AppViewModel.FileTreeRow
    let isExpanded: Bool
    let isSelected: Bool
    let aggregateStatus: OpenCodeVCSAggregateStatus?
    let onToggleDirectory: () -> Void
    let onSelectFile: () -> Void

    var body: some View {
        Group {
            if row.node.isDirectory {
                Button(action: onToggleDirectory) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onSelectFile) {
                    content
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: CGFloat(row.depth) * 14)

            if row.node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder")
                    .foregroundStyle(aggregateStatus?.hasChanges == true ? statusColor : .secondary)
            } else {
                Color.clear.frame(width: 12)
                Image(systemName: "doc.text")
                    .foregroundStyle(aggregateStatus == nil ? .secondary : statusColor)
            }

            Text(row.node.name)
                .font(.body.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let aggregateStatus {
                HStack(spacing: 6) {
                    if row.node.isDirectory {
                        Text("\(aggregateStatus.fileCount)")
                            .foregroundStyle(.secondary)
                    }
                    Text("+\(aggregateStatus.additions)")
                        .foregroundStyle(.green)
                    Text("-\(aggregateStatus.deletions)")
                        .foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        if let aggregateStatus, aggregateStatus.deletions > 0, aggregateStatus.additions == 0 {
            return .red
        }
        if let aggregateStatus, aggregateStatus.additions > 0, aggregateStatus.deletions == 0 {
            return .green
        }
        return .orange
    }
}

private struct GitSummaryCard: View {
    let summary: OpenCodeVCSSummary
    let branch: String?
    let modeTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Repo Snapshot")
                        .font(.headline)
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(modeTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(OpenCodePlatformColor.groupedBackground, in: Capsule())
            }

            HStack(spacing: 12) {
                metric(title: "Files", value: "\(summary.fileCount)", color: .primary)
                metric(title: "Added", value: "+\(summary.additions)", color: .green)
                metric(title: "Removed", value: "-\(summary.deletions)", color: .red)
                if let branch, !branch.isEmpty {
                    metric(title: "Branch", value: branch, color: .secondary)
                }
            }
        }
        .padding(14)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var summaryLine: String {
        if summary.fileCount == 0 {
            return "No changed files in the current view"
        }
        return "\(summary.fileCount) changed \(summary.fileCount == 1 ? "file" : "files") with \(summary.additions) additions and \(summary.deletions) deletions"
    }

    private func metric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GitIntensityStrip: View {
    let files: [OpenCodeVCSIntensityFile]
    let selectedPath: String?
    let onSelect: (String) -> Void

    private var maxScore: Int {
        max(files.map(\.score).max() ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File Intensity")
                .font(.subheadline.weight(.medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(files) { file in
                        Button {
                            onSelect(file.path)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(fillColor(for: file))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(selectedPath == file.path ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(helpText(for: file))
                    }
                }
                .padding(.vertical, 2)
            }

            Text("Darker tiles mean more changed lines. Tap a tile to open that file diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func fillColor(for file: OpenCodeVCSIntensityFile) -> Color {
        let normalized = Double(file.score) / Double(maxScore)
        let opacity = 0.20 + (normalized * 0.70)

        switch file.status {
        case "added":
            return .green.opacity(opacity)
        case "deleted":
            return .red.opacity(opacity)
        default:
            return .orange.opacity(opacity)
        }
    }

    private func helpText(for file: OpenCodeVCSIntensityFile) -> String {
        "\(file.relativePath)  +\(file.additions)  -\(file.deletions)"
    }
}

private struct GitStatusRow: View {
    let title: String
    let subtitle: String?
    let status: String
    let additions: Int
    let deletions: Int
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Text("+\(additions)")
                    .foregroundStyle(.green)
                Text("-\(deletions)")
                    .foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .opacity(selected ? 1 : 0.96)
    }

    private var statusColor: Color {
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
