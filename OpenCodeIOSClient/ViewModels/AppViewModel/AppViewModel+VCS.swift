import Foundation
import SwiftUI

extension AppViewModel {
    struct FileTreeRow: Identifiable, Hashable {
        let node: OpenCodeFileNode
        let depth: Int

        var id: String { node.absolute }
    }

    var vcsSummary: OpenCodeVCSSummary {
        OpenCodeVCSSummary(
            fileCount: vcsFileStatuses.count,
            additions: vcsFileStatuses.reduce(0) { $0 + $1.added },
            deletions: vcsFileStatuses.reduce(0) { $0 + $1.removed }
        )
    }

    var vcsIntensityFiles: [OpenCodeVCSIntensityFile] {
        vcsFileStatuses.map { status in
            OpenCodeVCSIntensityFile(
                path: status.path,
                status: status.status,
                additions: status.added,
                deletions: status.removed,
                relativePath: relativeGitPath(status.path),
                score: status.added + status.removed
            )
        }
    }

    var visibleFileTreeRows: [FileTreeRow] {
        flattenFileTree(nodes: directoryState.fileTreeRootNodes, depth: 0)
    }

    var effectiveFilesDirectory: String? {
        guard hasGitProject else { return effectiveSelectedDirectory }
        let directories = workspaceDirectories()
        guard !directories.isEmpty else { return effectiveSelectedDirectory }

        if let selectedFilesWorkspaceDirectory,
           directories.contains(where: { workspaceKey($0) == workspaceKey(selectedFilesWorkspaceDirectory) }) {
            return selectedFilesWorkspaceDirectory
        }

        return currentProject?.worktree ?? effectiveSelectedDirectory
    }

    func isExpandedDirectory(_ path: String) -> Bool {
        directoryState.expandedFileTreeDirectories.contains(path)
    }

    func isChangedFile(_ path: String) -> Bool {
        vcsFileStatuses.contains { matchesVCSPath($0.path, toNodePath: path) }
    }

    func changedStatus(for path: String) -> OpenCodeVCSFileStatus? {
        vcsFileStatuses.first { matchesVCSPath($0.path, toNodePath: path) }
    }

    func aggregateStatus(for node: OpenCodeFileNode) -> OpenCodeVCSAggregateStatus? {
        let matches: [OpenCodeVCSFileStatus]

        if node.isDirectory {
            matches = vcsFileStatuses.filter { status in
                isStatus(status.path, withinDirectoryNode: node)
            }
        } else if let exact = changedStatus(for: node.absolute) ?? changedStatus(for: node.path) {
            matches = [exact]
        } else {
            matches = []
        }

        guard !matches.isEmpty else { return nil }
        return OpenCodeVCSAggregateStatus(
            fileCount: matches.count,
            additions: matches.reduce(0) { $0 + $1.added },
            deletions: matches.reduce(0) { $0 + $1.removed }
        )
    }

    var availableVCSDiffModes: [OpenCodeVCSDiffMode] {
        guard hasGitProject else { return [] }

        var modes: [OpenCodeVCSDiffMode] = [.git]
        if let branch = vcsInfo?.branch,
           let defaultBranch = vcsInfo?.defaultBranch,
           branch != defaultBranch {
            modes.append(.branch)
        }
        return modes
    }

    func presentGitView() {
        guard hasGitProject else { return }
        preserveCurrentMessageDraftForNavigation()
        if selectedFilesWorkspaceDirectory == nil {
            selectedFilesWorkspaceDirectory = currentProject?.worktree
        }
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            directoryState.selectedSession = nil
        }

        Task {
            await loadGitViewDataIfNeeded()
            if projectFilesMode == .tree {
                await loadFileTreeIfNeeded()
            }
        }
    }

    func selectVCSMode(_ mode: OpenCodeVCSDiffMode) {
        guard availableVCSDiffModes.contains(mode) else { return }

        withAnimation(opencodeSelectionAnimation) {
            directoryState.selectedVCSMode = mode
        }

        Task {
            await loadVCSDiff(mode: mode)
        }
    }

    func selectFilesWorkspaceDirectory(_ directory: String) {
        guard workspaceDirectories().contains(where: { workspaceKey($0) == workspaceKey(directory) }) else { return }
        guard selectedFilesWorkspaceDirectory == nil || workspaceKey(selectedFilesWorkspaceDirectory ?? "") != workspaceKey(directory) else { return }

        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedFilesWorkspaceDirectory = directory
            directoryState.selectedVCSMode = .git
            clearVCSWorkspaceData()
        }

        Task {
            await reloadGitViewData(force: true)
            if projectFilesMode == .tree {
                await reloadFileTree(force: true)
            }
        }
    }

    func selectProjectFilesMode(_ mode: OpenCodeProjectFilesMode) {
        guard projectFilesMode != mode else { return }

        withAnimation(opencodeSelectionAnimation) {
            directoryState.projectFilesMode = mode
        }

        if mode == .tree {
            Task {
                await loadFileTreeIfNeeded()
            }
        }
    }

    func selectVCSFile(_ path: String) {
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            directoryState.selectedSession = nil
            directoryState.selectedVCSFile = path
            directoryState.selectedProjectFilePath = path
        }
    }

    func selectProjectFile(_ node: OpenCodeFileNode) {
        guard !node.isDirectory else { return }
        preserveCurrentMessageDraftForNavigation()

        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            directoryState.selectedSession = nil
            directoryState.selectedProjectFilePath = node.absolute
            if isChangedFile(node.absolute) {
                directoryState.selectedVCSFile = node.absolute
            } else {
                directoryState.selectedVCSFile = nil
            }
        }

        guard !isChangedFile(node.absolute) else { return }
        Task {
            await loadFileContentIfNeeded(for: node)
        }
    }

    func toggleFileTreeDirectory(_ node: OpenCodeFileNode) {
        guard node.isDirectory else { return }

        if isExpandedDirectory(node.absolute) {
            directoryState.expandedFileTreeDirectories.remove(node.absolute)
            return
        }

        directoryState.expandedFileTreeDirectories.insert(node.absolute)
        Task {
            await loadFileTreeChildrenIfNeeded(for: node)
        }
    }

    func loadFileTreeIfNeeded() async {
        guard hasGitProject else { return }
        guard directoryState.fileTreeRootNodes.isEmpty else { return }
        await reloadFileTree(force: false)
    }

    func reloadFileTree(force: Bool) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }

        directoryState.isLoadingFileTree = true
        if force {
            directoryState.fileTreeErrorMessage = nil
        }
        defer { directoryState.isLoadingFileTree = false }

        do {
            let nodes = try await client.listFiles(directory: directory, path: "")
            let sorted = sortFileNodes(nodes)
            directoryState.fileTreeRootNodes = sorted
            directoryState.fileTreeChildrenByParentPath[""] = sorted
            directoryState.fileTreeErrorMessage = nil
        } catch {
            directoryState.fileTreeErrorMessage = error.localizedDescription
        }
    }

    func loadFileTreeChildrenIfNeeded(for node: OpenCodeFileNode) async {
        guard node.isDirectory, directoryState.fileTreeChildrenByParentPath[node.absolute] == nil else { return }
        await loadFileTreeChildren(for: node, force: false)
    }

    func loadFileTreeChildren(for node: OpenCodeFileNode, force: Bool) async {
        guard node.isDirectory, let directory = effectiveFilesDirectory else { return }
        if !force, directoryState.fileTreeChildrenByParentPath[node.absolute] != nil {
            return
        }

        directoryState.isLoadingFileTree = true
        defer { directoryState.isLoadingFileTree = false }

        do {
            let nodes = try await client.listFiles(directory: directory, path: node.path)
            directoryState.fileTreeChildrenByParentPath[node.absolute] = sortFileNodes(nodes)
            directoryState.fileTreeErrorMessage = nil
        } catch {
            directoryState.fileTreeErrorMessage = error.localizedDescription
        }
    }

    func loadFileContentIfNeeded(for node: OpenCodeFileNode) async {
        guard !node.isDirectory else { return }
        if directoryState.fileContentsByPath[node.absolute] != nil {
            return
        }
        await loadFileContent(for: node, force: false)
    }

    func loadFileContent(for node: OpenCodeFileNode, force: Bool) async {
        guard !node.isDirectory, let directory = effectiveFilesDirectory else { return }
        if !force, directoryState.fileContentsByPath[node.absolute] != nil {
            return
        }

        directoryState.isLoadingSelectedFileContent = true
        defer { directoryState.isLoadingSelectedFileContent = false }

        do {
            let content = try await client.readFileContent(directory: directory, path: node.path)
            directoryState.fileContentsByPath[node.absolute] = content
            directoryState.fileContentErrorMessage = nil
        } catch {
            directoryState.fileContentErrorMessage = error.localizedDescription
        }
    }

    func loadGitViewDataIfNeeded() async {
        guard hasGitProject else { return }

        let needsInfo = directoryState.vcsInfo == nil
        let needsStatus = directoryState.vcsFileStatuses.isEmpty
        let needsDiff = directoryState.vcsDiffsByMode[directoryState.selectedVCSMode] == nil

        guard needsInfo || needsStatus || needsDiff else { return }
        await reloadGitViewData(force: false)
    }

    func reloadGitViewData(force: Bool) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }

        withAnimation(opencodeSelectionAnimation) {
            directoryState.isLoadingVCS = true
            if force {
                directoryState.vcsErrorMessage = nil
            }
        }

        do {
            async let info = client.getVCSInfo(directory: directory)
            async let status = client.listFileStatus(directory: directory)

            let loadedInfo = try await info
            applyLoadedVCSInfo(loadedInfo)

            let loadedStatus = try await status
            applyLoadedVCSStatus(loadedStatus)

            let loadedDiff = try await client.getVCSDiff(mode: directoryState.selectedVCSMode, directory: directory)
            applyLoadedVCSDiff(loadedDiff, mode: directoryState.selectedVCSMode)
            directoryState.vcsErrorMessage = nil
        } catch {
            directoryState.vcsErrorMessage = error.localizedDescription
        }

        directoryState.isLoadingVCS = false
    }

    func loadVCSDiff(mode: OpenCodeVCSDiffMode, force: Bool = false) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }
        if !force, directoryState.vcsDiffsByMode[mode] != nil {
            selectReasonableVCSFileIfNeeded()
            return
        }

        directoryState.isLoadingVCS = true
        defer { directoryState.isLoadingVCS = false }

        do {
            let diff = try await client.getVCSDiff(mode: mode, directory: directory)
            applyLoadedVCSDiff(diff, mode: mode)
            directoryState.vcsErrorMessage = nil
        } catch {
            directoryState.vcsErrorMessage = error.localizedDescription
        }
    }

    func refreshVCSFromEvent() {
        guard hasGitProject else { return }
        Task {
            await reloadGitViewData(force: true)
        }
    }

    func relativeGitPath(_ path: String) -> String {
        guard let root = effectiveFilesDirectory, !root.isEmpty else { return path }
        if path == root {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    private func applyLoadedVCSInfo(_ info: OpenCodeVCSInfo) {
        directoryState.vcsInfo = info

        if !availableVCSDiffModes.contains(directoryState.selectedVCSMode) {
            directoryState.selectedVCSMode = .git
        }
    }

    private func applyLoadedVCSStatus(_ status: [OpenCodeVCSFileStatus]) {
        directoryState.vcsFileStatuses = status.sorted { lhs, rhs in
            relativeGitPath(lhs.path).localizedCaseInsensitiveCompare(relativeGitPath(rhs.path)) == .orderedAscending
        }
        selectReasonableVCSFileIfNeeded()
    }

    private func applyLoadedVCSDiff(_ diff: [OpenCodeVCSFileDiff], mode: OpenCodeVCSDiffMode) {
        let sorted = diff.sorted { lhs, rhs in
            relativeGitPath(lhs.file).localizedCaseInsensitiveCompare(relativeGitPath(rhs.file)) == .orderedAscending
        }
        directoryState.vcsDiffsByMode[mode] = sorted
        selectReasonableVCSFileIfNeeded()
    }

    private func selectReasonableVCSFileIfNeeded() {
        let current = directoryState.selectedVCSFile
        let diffFiles = Set(currentVCSDiffs.map(\.file))
        let statusFiles = directoryState.vcsFileStatuses.map(\.path)

        if let current, diffFiles.contains(current) || statusFiles.contains(current) {
            return
        }

        let nextSelection = currentVCSDiffs.first?.file ?? directoryState.vcsFileStatuses.first?.path
        directoryState.selectedVCSFile = nextSelection
        if directoryState.selectedProjectFilePath == nil {
            directoryState.selectedProjectFilePath = nextSelection
        }
    }

    private func flattenFileTree(nodes: [OpenCodeFileNode], depth: Int) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for node in nodes {
            rows.append(FileTreeRow(node: node, depth: depth))
            guard node.isDirectory,
                  isExpandedDirectory(node.absolute),
                  let children = directoryState.fileTreeChildrenByParentPath[node.absolute] else {
                continue
            }
            rows.append(contentsOf: flattenFileTree(nodes: children, depth: depth + 1))
        }
        return rows
    }

    private func sortFileNodes(_ nodes: [OpenCodeFileNode]) -> [OpenCodeFileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func matchesVCSPath(_ statusPath: String, toNodePath nodePath: String) -> Bool {
        let normalizedStatus = normalizedComparablePath(statusPath)
        let normalizedNode = normalizedComparablePath(nodePath)
        return normalizedStatus == normalizedNode
    }

    private func isStatus(_ statusPath: String, withinDirectoryNode node: OpenCodeFileNode) -> Bool {
        let statusComparable = normalizedComparablePath(statusPath)
        let absoluteComparable = normalizedComparablePath(node.absolute)
        let relativeComparable = normalizedComparablePath(node.path)

        return statusComparable == absoluteComparable
            || statusComparable == relativeComparable
            || statusComparable.hasPrefix(absoluteComparable + "/")
            || statusComparable.hasPrefix(relativeComparable + "/")
    }

    private func normalizedComparablePath(_ path: String) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasSuffix("/") && normalized.count > 1 {
            normalized.removeLast()
        }

        if let directory = effectiveFilesDirectory,
           normalized.hasPrefix(directory + "/") {
            return String(normalized.dropFirst(directory.count + 1))
        }

        if normalized == effectiveFilesDirectory {
            return ""
        }

        return normalized
    }

    private func clearVCSWorkspaceData() {
        directoryState.vcsInfo = nil
        directoryState.vcsFileStatuses = []
        directoryState.vcsDiffsByMode = [:]
        directoryState.selectedVCSFile = nil
        directoryState.selectedProjectFilePath = nil
        directoryState.fileTreeRootNodes = []
        directoryState.fileTreeChildrenByParentPath = [:]
        directoryState.expandedFileTreeDirectories = []
        directoryState.fileContentsByPath = [:]
        directoryState.fileTreeErrorMessage = nil
        directoryState.fileContentErrorMessage = nil
        directoryState.vcsErrorMessage = nil
    }
}
