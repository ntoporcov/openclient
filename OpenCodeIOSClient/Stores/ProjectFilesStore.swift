import Combine
import Foundation

@MainActor
final class ProjectFilesStore: ObservableObject {
    @Published var vcsInfo: OpenCodeVCSInfo?
    @Published var vcsFileStatuses: [OpenCodeVCSFileStatus]
    @Published var vcsDiffsByMode: [OpenCodeVCSDiffMode: [OpenCodeVCSFileDiff]]
    @Published var selectedVCSMode: OpenCodeVCSDiffMode
    @Published var selectedVCSFile: String?
    @Published var mode: OpenCodeProjectFilesMode
    @Published var fileTreeRootNodes: [OpenCodeFileNode]
    @Published var fileTreeChildrenByParentPath: [String: [OpenCodeFileNode]]
    @Published var expandedFileTreeDirectories: Set<String>
    @Published var selectedFilePath: String?
    @Published var fileContentsByPath: [String: OpenCodeFileContent]
    @Published var isLoadingFileTree: Bool
    @Published var isLoadingSelectedFileContent: Bool
    @Published var fileTreeErrorMessage: String?
    @Published var fileContentErrorMessage: String?
    @Published var isLoadingVCS: Bool
    @Published var vcsErrorMessage: String?

    init(
        vcsInfo: OpenCodeVCSInfo? = nil,
        vcsFileStatuses: [OpenCodeVCSFileStatus] = [],
        vcsDiffsByMode: [OpenCodeVCSDiffMode: [OpenCodeVCSFileDiff]] = [:],
        selectedVCSMode: OpenCodeVCSDiffMode = .git,
        selectedVCSFile: String? = nil,
        mode: OpenCodeProjectFilesMode = .changes,
        fileTreeRootNodes: [OpenCodeFileNode] = [],
        fileTreeChildrenByParentPath: [String: [OpenCodeFileNode]] = [:],
        expandedFileTreeDirectories: Set<String> = [],
        selectedFilePath: String? = nil,
        fileContentsByPath: [String: OpenCodeFileContent] = [:],
        isLoadingFileTree: Bool = false,
        isLoadingSelectedFileContent: Bool = false,
        fileTreeErrorMessage: String? = nil,
        fileContentErrorMessage: String? = nil,
        isLoadingVCS: Bool = false,
        vcsErrorMessage: String? = nil
    ) {
        self.vcsInfo = vcsInfo
        self.vcsFileStatuses = vcsFileStatuses
        self.vcsDiffsByMode = vcsDiffsByMode
        self.selectedVCSMode = selectedVCSMode
        self.selectedVCSFile = selectedVCSFile
        self.mode = mode
        self.fileTreeRootNodes = fileTreeRootNodes
        self.fileTreeChildrenByParentPath = fileTreeChildrenByParentPath
        self.expandedFileTreeDirectories = expandedFileTreeDirectories
        self.selectedFilePath = selectedFilePath
        self.fileContentsByPath = fileContentsByPath
        self.isLoadingFileTree = isLoadingFileTree
        self.isLoadingSelectedFileContent = isLoadingSelectedFileContent
        self.fileTreeErrorMessage = fileTreeErrorMessage
        self.fileContentErrorMessage = fileContentErrorMessage
        self.isLoadingVCS = isLoadingVCS
        self.vcsErrorMessage = vcsErrorMessage
    }

    func reset() {
        vcsInfo = nil
        vcsFileStatuses = []
        vcsDiffsByMode = [:]
        selectedVCSMode = .git
        selectedVCSFile = nil
        mode = .changes
        fileTreeRootNodes = []
        fileTreeChildrenByParentPath = [:]
        expandedFileTreeDirectories = []
        selectedFilePath = nil
        fileContentsByPath = [:]
        isLoadingFileTree = false
        isLoadingSelectedFileContent = false
        fileTreeErrorMessage = nil
        fileContentErrorMessage = nil
        isLoadingVCS = false
        vcsErrorMessage = nil
    }

    func clearWorkspaceData() {
        vcsInfo = nil
        vcsFileStatuses = []
        vcsDiffsByMode = [:]
        selectedVCSFile = nil
        selectedFilePath = nil
        fileTreeRootNodes = []
        fileTreeChildrenByParentPath = [:]
        expandedFileTreeDirectories = []
        fileContentsByPath = [:]
        fileTreeErrorMessage = nil
        fileContentErrorMessage = nil
        vcsErrorMessage = nil
    }

    var vcsSummary: OpenCodeVCSSummary {
        OpenCodeVCSSummary(
            fileCount: vcsFileStatuses.count,
            additions: vcsFileStatuses.reduce(0) { $0 + $1.added },
            deletions: vcsFileStatuses.reduce(0) { $0 + $1.removed }
        )
    }

    func availableDiffModes(hasGitProject: Bool) -> [OpenCodeVCSDiffMode] {
        guard hasGitProject else { return [] }

        var modes: [OpenCodeVCSDiffMode] = [.git]
        if let branch = vcsInfo?.branch,
           let defaultBranch = vcsInfo?.defaultBranch,
           branch != defaultBranch {
            modes.append(.branch)
        }
        return modes
    }

    func currentDiffs() -> [OpenCodeVCSFileDiff] {
        vcsDiffsByMode[selectedVCSMode] ?? []
    }

    func selectMode(_ nextMode: OpenCodeProjectFilesMode) -> Bool {
        guard mode != nextMode else { return false }
        mode = nextMode
        return true
    }

    func selectVCSMode(_ nextMode: OpenCodeVCSDiffMode, availableModes: [OpenCodeVCSDiffMode]) -> Bool {
        guard availableModes.contains(nextMode) else { return false }
        selectedVCSMode = nextMode
        return true
    }

    func selectVCSFile(_ path: String) {
        selectedVCSFile = path
        selectedFilePath = path
    }

    func selectProjectFile(_ node: OpenCodeFileNode, isChanged: Bool) {
        guard !node.isDirectory else { return }
        selectedFilePath = node.absolute
        selectedVCSFile = isChanged ? node.absolute : nil
    }

    func isExpandedDirectory(_ path: String) -> Bool {
        expandedFileTreeDirectories.contains(path)
    }

    func toggleDirectory(_ node: OpenCodeFileNode) -> Bool {
        guard node.isDirectory else { return false }

        if expandedFileTreeDirectories.contains(node.absolute) {
            expandedFileTreeDirectories.remove(node.absolute)
            return false
        }

        expandedFileTreeDirectories.insert(node.absolute)
        return fileTreeChildrenByParentPath[node.absolute] == nil
    }

    func needsFileTreeRootLoad() -> Bool {
        fileTreeRootNodes.isEmpty
    }

    func needsChildrenLoad(for node: OpenCodeFileNode, force: Bool = false) -> Bool {
        node.isDirectory && (force || fileTreeChildrenByParentPath[node.absolute] == nil)
    }

    func applyLoadedRootNodes(_ nodes: [OpenCodeFileNode]) {
        let sorted = sortedFileNodes(nodes)
        fileTreeRootNodes = sorted
        fileTreeChildrenByParentPath[""] = sorted
        fileTreeErrorMessage = nil
    }

    func applyLoadedChildren(_ nodes: [OpenCodeFileNode], for node: OpenCodeFileNode) {
        fileTreeChildrenByParentPath[node.absolute] = sortedFileNodes(nodes)
        fileTreeErrorMessage = nil
    }

    func needsFileContent(path: String, force: Bool = false) -> Bool {
        force || fileContentsByPath[path] == nil
    }

    func applyLoadedFileContent(_ content: OpenCodeFileContent, path: String) {
        fileContentsByPath[path] = content
        fileContentErrorMessage = nil
    }

    func needsGitViewLoad() -> Bool {
        vcsInfo == nil || vcsFileStatuses.isEmpty || vcsDiffsByMode[selectedVCSMode] == nil
    }

    func needsDiffLoad(mode: OpenCodeVCSDiffMode, force: Bool = false) -> Bool {
        force || vcsDiffsByMode[mode] == nil
    }

    func applyLoadedVCSInfo(_ info: OpenCodeVCSInfo, hasGitProject: Bool) {
        vcsInfo = info

        if !availableDiffModes(hasGitProject: hasGitProject).contains(selectedVCSMode) {
            selectedVCSMode = .git
        }
    }

    func applyBranchUpdate(_ branch: String?) {
        vcsInfo = OpenCodeVCSInfo(branch: branch, defaultBranch: vcsInfo?.defaultBranch)
    }

    func applyLoadedVCSStatus(_ status: [OpenCodeVCSFileStatus], relativePath: (String) -> String) {
        vcsFileStatuses = status.sorted { lhs, rhs in
            relativePath(lhs.path).localizedCaseInsensitiveCompare(relativePath(rhs.path)) == .orderedAscending
        }
        selectReasonableVCSFileIfNeeded()
    }

    func applyLoadedVCSDiff(_ diff: [OpenCodeVCSFileDiff], mode: OpenCodeVCSDiffMode, relativePath: (String) -> String) {
        let sorted = diff.sorted { lhs, rhs in
            relativePath(lhs.file).localizedCaseInsensitiveCompare(relativePath(rhs.file)) == .orderedAscending
        }
        vcsDiffsByMode[mode] = sorted
        selectReasonableVCSFileIfNeeded()
    }

    func selectReasonableVCSFileIfNeeded() {
        let current = selectedVCSFile
        let diffFiles = Set(currentDiffs().map(\.file))
        let statusFiles = vcsFileStatuses.map(\.path)

        if let current, diffFiles.contains(current) || statusFiles.contains(current) {
            return
        }

        let nextSelection = currentDiffs().first?.file ?? vcsFileStatuses.first?.path
        selectedVCSFile = nextSelection
        if selectedFilePath == nil {
            selectedFilePath = nextSelection
        }
    }

    func isChangedFile(_ path: String, effectiveDirectory: String?) -> Bool {
        vcsFileStatuses.contains { matchesVCSPath($0.path, toNodePath: path, effectiveDirectory: effectiveDirectory) }
    }

    func changedStatus(for path: String, effectiveDirectory: String?) -> OpenCodeVCSFileStatus? {
        vcsFileStatuses.first { matchesVCSPath($0.path, toNodePath: path, effectiveDirectory: effectiveDirectory) }
    }

    func aggregateStatus(for node: OpenCodeFileNode, effectiveDirectory: String?) -> OpenCodeVCSAggregateStatus? {
        let matches: [OpenCodeVCSFileStatus]

        if node.isDirectory {
            matches = vcsFileStatuses.filter { status in
                isStatus(status.path, withinDirectoryNode: node, effectiveDirectory: effectiveDirectory)
            }
        } else if let exact = changedStatus(for: node.absolute, effectiveDirectory: effectiveDirectory) ?? changedStatus(for: node.path, effectiveDirectory: effectiveDirectory) {
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

    func sortedFileNodes(_ nodes: [OpenCodeFileNode]) -> [OpenCodeFileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func relativeFileRequestPath(for path: String, directory: String) -> String {
        if path == directory { return "" }
        if path.hasPrefix(directory + "/") {
            return String(path.dropFirst(directory.count + 1))
        }
        return path
    }

    func relativeGitPath(_ path: String, effectiveDirectory: String?) -> String {
        guard let root = effectiveDirectory, !root.isEmpty else { return path }
        if path == root {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return path
    }

    private func matchesVCSPath(_ statusPath: String, toNodePath nodePath: String, effectiveDirectory: String?) -> Bool {
        let normalizedStatus = normalizedComparablePath(statusPath, effectiveDirectory: effectiveDirectory)
        let normalizedNode = normalizedComparablePath(nodePath, effectiveDirectory: effectiveDirectory)
        return normalizedStatus == normalizedNode
    }

    private func isStatus(_ statusPath: String, withinDirectoryNode node: OpenCodeFileNode, effectiveDirectory: String?) -> Bool {
        let statusComparable = normalizedComparablePath(statusPath, effectiveDirectory: effectiveDirectory)
        let absoluteComparable = normalizedComparablePath(node.absolute, effectiveDirectory: effectiveDirectory)
        let relativeComparable = normalizedComparablePath(node.path, effectiveDirectory: effectiveDirectory)

        return statusComparable == absoluteComparable
            || statusComparable == relativeComparable
            || statusComparable.hasPrefix(absoluteComparable + "/")
            || statusComparable.hasPrefix(relativeComparable + "/")
    }

    private func normalizedComparablePath(_ path: String, effectiveDirectory: String?) -> String {
        var normalized = path.replacingOccurrences(of: "\\", with: "/")
        while normalized.hasSuffix("/") && normalized.count > 1 {
            normalized.removeLast()
        }

        if let effectiveDirectory,
           normalized.hasPrefix(effectiveDirectory + "/") {
            return String(normalized.dropFirst(effectiveDirectory.count + 1))
        }

        if normalized == effectiveDirectory {
            return ""
        }

        return normalized
    }
}
