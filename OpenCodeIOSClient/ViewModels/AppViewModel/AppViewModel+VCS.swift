import Foundation
import SwiftUI

extension AppViewModel {
    struct ProjectFilesSnapshot: Hashable {
        let vcsInfo: OpenCodeVCSInfo?
        let summary: OpenCodeVCSSummary
        let intensityFiles: [OpenCodeVCSIntensityFile]
        let fileStatuses: [OpenCodeVCSFileStatus]
        let selectedMode: OpenCodeVCSDiffMode
        let selectedVCSFile: String?
        let filesMode: OpenCodeProjectFilesMode
        let selectedFilePath: String?
        let visibleRows: [FileTreeRow]
        let isLoadingVCS: Bool
        let isLoadingFileTree: Bool
        let vcsErrorMessage: String?
        let fileTreeErrorMessage: String?
        let selectedFileContent: OpenCodeFileContent?
        let selectedFileDiff: OpenCodeVCSFileDiff?
        let selectedFileIsChanged: Bool
        let isLoadingSelectedFileContent: Bool
        let fileContentErrorMessage: String?
        let effectiveDirectory: String?
    }

    var projectFilesSnapshot: ProjectFilesSnapshot {
        ProjectFilesSnapshot(
            vcsInfo: vcsInfo,
            summary: vcsSummary,
            intensityFiles: vcsIntensityFiles,
            fileStatuses: vcsFileStatuses,
            selectedMode: selectedVCSDiffMode,
            selectedVCSFile: selectedVCSFile,
            filesMode: projectFilesMode,
            selectedFilePath: selectedProjectFilePath,
            visibleRows: visibleFileTreeRows,
            isLoadingVCS: isLoadingVCS,
            isLoadingFileTree: isLoadingFileTree,
            vcsErrorMessage: vcsErrorMessage,
            fileTreeErrorMessage: fileTreeErrorMessage,
            selectedFileContent: selectedProjectFileContent,
            selectedFileDiff: selectedVCSFileDiff,
            selectedFileIsChanged: selectedProjectFileIsChanged,
            isLoadingSelectedFileContent: isLoadingSelectedFileContent,
            fileContentErrorMessage: fileContentErrorMessage,
            effectiveDirectory: effectiveFilesDirectory
        )
    }

    struct FileTreeRow: Identifiable, Hashable {
        let node: OpenCodeFileNode
        let depth: Int

        var id: String { node.absolute }
    }

    var vcsSummary: OpenCodeVCSSummary {
        projectFilesStore.vcsSummary
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
        flattenFileTree(nodes: fileTreeRootNodes, depth: 0)
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
        projectFilesStore.isExpandedDirectory(path)
    }

    func isChangedFile(_ path: String) -> Bool {
        projectFilesStore.isChangedFile(path, effectiveDirectory: effectiveFilesDirectory)
    }

    func changedStatus(for path: String) -> OpenCodeVCSFileStatus? {
        projectFilesStore.changedStatus(for: path, effectiveDirectory: effectiveFilesDirectory)
    }

    func aggregateStatus(for node: OpenCodeFileNode) -> OpenCodeVCSAggregateStatus? {
        projectFilesStore.aggregateStatus(for: node, effectiveDirectory: effectiveFilesDirectory)
    }

    var availableVCSDiffModes: [OpenCodeVCSDiffMode] {
        projectFilesStore.availableDiffModes(hasGitProject: hasGitProject)
    }

    func presentGitView() {
        guard hasGitProject else { return }
        preserveCurrentMessageDraftForNavigation()
        if selectedFilesWorkspaceDirectory == nil {
            selectedFilesWorkspaceDirectory = currentProject?.worktree
        }
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            selectedSession = nil
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
            _ = projectFilesStore.selectVCSMode(mode, availableModes: availableVCSDiffModes)
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
            selectedVCSDiffMode = .git
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
            objectWillChange.send()
            _ = projectFilesStore.selectMode(mode)
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
            selectedSession = nil
            projectFilesStore.selectVCSFile(path)
        }

        Task {
            await loadVCSDiff(mode: selectedVCSDiffMode)
        }
    }

    func selectProjectFile(_ node: OpenCodeFileNode) {
        guard !node.isDirectory else { return }
        preserveCurrentMessageDraftForNavigation()

        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            selectedSession = nil
            projectFilesStore.selectProjectFile(node, isChanged: isChangedFile(node.absolute))
        }

        guard !isChangedFile(node.absolute) else { return }
        Task {
            await loadFileContentIfNeeded(for: node)
        }
    }

    func toggleFileTreeDirectory(_ node: OpenCodeFileNode) {
        guard node.isDirectory else { return }

        let shouldLoad = projectFilesStore.toggleDirectory(node)
        if shouldLoad {
            Task {
                await loadFileTreeChildrenIfNeeded(for: node)
            }
        }
    }

    func loadFileTreeIfNeeded() async {
        guard hasGitProject else { return }
        guard projectFilesStore.needsFileTreeRootLoad() else { return }
        await reloadFileTree(force: false)
    }

    func reloadFileTree(force: Bool) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }

        isLoadingFileTree = true
        if force {
            fileTreeErrorMessage = nil
        }
        defer { isLoadingFileTree = false }

        do {
            let nodes = try await client.listFiles(directory: directory, path: "")
            projectFilesStore.applyLoadedRootNodes(nodes)
            fileTreeErrorMessage = nil
        } catch {
            fileTreeErrorMessage = error.localizedDescription
        }
    }

    func loadFileTreeChildrenIfNeeded(for node: OpenCodeFileNode) async {
        guard projectFilesStore.needsChildrenLoad(for: node) else { return }
        await loadFileTreeChildren(for: node, force: false)
    }

    func loadFileTreeChildren(for node: OpenCodeFileNode, force: Bool) async {
        guard projectFilesStore.needsChildrenLoad(for: node, force: force), let directory = effectiveFilesDirectory else { return }

        isLoadingFileTree = true
        defer { isLoadingFileTree = false }

        do {
            let nodes = try await client.listFiles(directory: directory, path: node.path)
            projectFilesStore.applyLoadedChildren(nodes, for: node)
            fileTreeErrorMessage = nil
        } catch {
            fileTreeErrorMessage = error.localizedDescription
        }
    }

    func loadFileContentIfNeeded(for node: OpenCodeFileNode) async {
        guard !node.isDirectory else { return }
        guard projectFilesStore.needsFileContent(path: node.absolute) else { return }
        await loadFileContent(for: node, force: false)
    }

    func loadFileContent(for node: OpenCodeFileNode, force: Bool) async {
        guard !node.isDirectory, let directory = effectiveFilesDirectory else { return }
        guard projectFilesStore.needsFileContent(path: node.absolute, force: force) else { return }

        isLoadingSelectedFileContent = true
        defer { isLoadingSelectedFileContent = false }

        do {
            let content = try await client.readFileContent(directory: directory, path: node.path)
            projectFilesStore.applyLoadedFileContent(content, path: node.absolute)
            fileContentErrorMessage = nil
        } catch {
            fileContentErrorMessage = error.localizedDescription
        }
    }

    func loadSelectedProjectFileContentIfNeeded() async {
        guard let path = selectedProjectFilePath else { return }
        guard projectFilesStore.needsFileContent(path: path) else { return }
        guard !selectedProjectFileIsChanged else { return }
        await loadFileContent(path: path, force: false)
    }

    private func loadFileContent(path: String, force: Bool) async {
        guard let directory = effectiveFilesDirectory else { return }
        guard projectFilesStore.needsFileContent(path: path, force: force) else { return }

        let requestPath = projectFilesStore.relativeFileRequestPath(for: path, directory: directory)
        isLoadingSelectedFileContent = true
        defer { isLoadingSelectedFileContent = false }

        do {
            let content = try await client.readFileContent(directory: directory, path: requestPath)
            projectFilesStore.applyLoadedFileContent(content, path: path)
            fileContentErrorMessage = nil
        } catch {
            fileContentErrorMessage = error.localizedDescription
        }
    }

    func loadGitViewDataIfNeeded() async {
        guard hasGitProject else { return }
        guard projectFilesStore.needsGitViewLoad() else { return }
        await reloadGitViewData(force: false)
    }

    func reloadGitViewData(force: Bool) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }

        withAnimation(opencodeSelectionAnimation) {
            isLoadingVCS = true
            if force {
                vcsErrorMessage = nil
            }
        }

        do {
            async let info = client.getVCSInfo(directory: directory)
            async let status = client.listFileStatus(directory: directory)

            let loadedInfo = try await info
            applyLoadedVCSInfo(loadedInfo)

            let loadedStatus = try await status
            applyLoadedVCSStatus(loadedStatus)

            if projectFilesStore.vcsDiffsByMode[selectedVCSDiffMode] != nil {
                let loadedDiff = try await client.getVCSDiff(mode: selectedVCSDiffMode, directory: directory)
                applyLoadedVCSDiff(loadedDiff, mode: selectedVCSDiffMode)
            }
            vcsErrorMessage = nil
        } catch {
            vcsErrorMessage = error.localizedDescription
        }

        isLoadingVCS = false
    }

    func loadVCSDiff(mode: OpenCodeVCSDiffMode, force: Bool = false) async {
        guard hasGitProject, let directory = effectiveFilesDirectory else { return }
        if !projectFilesStore.needsDiffLoad(mode: mode, force: force) {
            projectFilesStore.selectReasonableVCSFileIfNeeded()
            return
        }

        isLoadingVCS = true
        defer { isLoadingVCS = false }

        do {
            let diff = try await client.getVCSDiff(mode: mode, directory: directory)
            applyLoadedVCSDiff(diff, mode: mode)
            vcsErrorMessage = nil
        } catch {
            vcsErrorMessage = error.localizedDescription
        }
    }

    func refreshVCSFromEvent() {
        guard hasGitProject else { return }

        vcsEventRefreshTask?.cancel()
        vcsEventRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, self.hasGitProject else { return }
            guard self.selectedProjectContentTab == .git else { return }
            await self.reloadGitViewData(force: true)
            self.vcsEventRefreshTask = nil
        }
    }

    func relativeGitPath(_ path: String) -> String {
        projectFilesStore.relativeGitPath(path, effectiveDirectory: effectiveFilesDirectory)
    }

    private func applyLoadedVCSInfo(_ info: OpenCodeVCSInfo) {
        projectFilesStore.applyLoadedVCSInfo(info, hasGitProject: hasGitProject)
    }

    private func applyLoadedVCSStatus(_ status: [OpenCodeVCSFileStatus]) {
        projectFilesStore.applyLoadedVCSStatus(status, relativePath: relativeGitPath)
    }

    private func applyLoadedVCSDiff(_ diff: [OpenCodeVCSFileDiff], mode: OpenCodeVCSDiffMode) {
        projectFilesStore.applyLoadedVCSDiff(diff, mode: mode, relativePath: relativeGitPath)
    }

    private func flattenFileTree(nodes: [OpenCodeFileNode], depth: Int) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for node in nodes {
            rows.append(FileTreeRow(node: node, depth: depth))
            guard node.isDirectory,
                  isExpandedDirectory(node.absolute),
                  let children = projectFilesStore.fileTreeChildrenByParentPath[node.absolute] else {
                continue
            }
            rows.append(contentsOf: flattenFileTree(nodes: children, depth: depth + 1))
        }
        return rows
    }

    private func clearVCSWorkspaceData() {
        projectFilesStore.clearWorkspaceData()
    }
}
