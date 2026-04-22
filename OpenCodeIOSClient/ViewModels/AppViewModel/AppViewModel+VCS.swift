import Foundation
import SwiftUI

extension AppViewModel {
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
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            directoryState.selectedSession = nil
        }

        Task {
            await loadGitViewDataIfNeeded()
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

    func selectVCSFile(_ path: String) {
        withAnimation(opencodeSelectionAnimation) {
            selectedProjectContentTab = .git
            directoryState.selectedSession = nil
            directoryState.selectedVCSFile = path
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
        guard hasGitProject else { return }

        withAnimation(opencodeSelectionAnimation) {
            directoryState.isLoadingVCS = true
            if force {
                directoryState.vcsErrorMessage = nil
            }
        }

        do {
            async let info = client.getVCSInfo(directory: effectiveSelectedDirectory)
            async let status = client.listFileStatus(directory: effectiveSelectedDirectory)

            let loadedInfo = try await info
            applyLoadedVCSInfo(loadedInfo)

            let loadedStatus = try await status
            applyLoadedVCSStatus(loadedStatus)

            let loadedDiff = try await client.getVCSDiff(mode: directoryState.selectedVCSMode, directory: effectiveSelectedDirectory)
            applyLoadedVCSDiff(loadedDiff, mode: directoryState.selectedVCSMode)
            directoryState.vcsErrorMessage = nil
        } catch {
            directoryState.vcsErrorMessage = error.localizedDescription
        }

        directoryState.isLoadingVCS = false
    }

    func loadVCSDiff(mode: OpenCodeVCSDiffMode, force: Bool = false) async {
        guard hasGitProject else { return }
        if !force, directoryState.vcsDiffsByMode[mode] != nil {
            selectReasonableVCSFileIfNeeded()
            return
        }

        directoryState.isLoadingVCS = true
        defer { directoryState.isLoadingVCS = false }

        do {
            let diff = try await client.getVCSDiff(mode: mode, directory: effectiveSelectedDirectory)
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
        guard let root = effectiveSelectedDirectory, !root.isEmpty else { return path }
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

        directoryState.selectedVCSFile = currentVCSDiffs.first?.file ?? directoryState.vcsFileStatuses.first?.path
    }
}
