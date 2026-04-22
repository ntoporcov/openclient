import SwiftUI

struct GitStatusView: View {
    @ObservedObject var viewModel: AppViewModel
    let onFileChosen: () -> Void

    private var statusIDs: String {
        viewModel.vcsFileStatuses.map(\.id).joined(separator: "|")
    }

    var body: some View {
        List {
            if let info = viewModel.vcsInfo {
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

            if !viewModel.vcsIntensityFiles.isEmpty {
                Section {
                    GitSummaryCard(
                        summary: viewModel.vcsSummary,
                        branch: viewModel.vcsInfo?.branch,
                        modeTitle: viewModel.selectedVCSDiffMode.title
                    )
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))

                    GitIntensityStrip(
                        files: viewModel.vcsIntensityFiles,
                        selectedPath: viewModel.selectedVCSFile,
                        onSelect: { path in
                            viewModel.selectVCSFile(path)
                            withAnimation(opencodeSelectionAnimation) {
                                onFileChosen()
                            }
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if !viewModel.availableVCSDiffModes.isEmpty {
                Section {
                    Picker("Diff Mode", selection: Binding(
                        get: { viewModel.selectedVCSDiffMode },
                        set: { viewModel.selectVCSMode($0) }
                    )) {
                        ForEach(viewModel.availableVCSDiffModes, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if let errorMessage = viewModel.directoryState.vcsErrorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section(viewModel.selectedVCSDiffMode == .git ? "Working Tree" : "Branch Diff") {
                if viewModel.directoryState.isLoadingVCS && viewModel.vcsFileStatuses.isEmpty {
                    ProgressView("Loading changes")
                } else if viewModel.vcsFileStatuses.isEmpty {
                    Text("No changes")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.vcsFileStatuses) { file in
                        Button {
                            viewModel.selectVCSFile(file.path)
                            withAnimation(opencodeSelectionAnimation) {
                                onFileChosen()
                            }
                        } label: {
                            GitStatusRow(
                                title: relativeTitle(for: file.path),
                                subtitle: relativeSubtitle(for: file.path),
                                status: file.status,
                                additions: file.added,
                                deletions: file.removed,
                                selected: viewModel.selectedVCSFile == file.path
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(viewModel.selectedVCSFile == file.path ? Color.blue.opacity(0.10) : Color.clear)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    }
                }
            }
        }
        .listStyle(.plain)
        .task {
            await viewModel.loadGitViewDataIfNeeded()
        }
        .animation(opencodeSelectionAnimation, value: statusIDs)
        .animation(opencodeSelectionAnimation, value: viewModel.selectedVCSFile ?? "")
    }

    private func relativeTitle(for path: String) -> String {
        let relative = viewModel.relativeGitPath(path)
        return relative.split(separator: "/").last.map(String.init) ?? relative
    }

    private func relativeSubtitle(for path: String) -> String? {
        let relative = viewModel.relativeGitPath(path)
        let components = relative.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
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
