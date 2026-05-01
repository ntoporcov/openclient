import Foundation
import SwiftUI

extension AppViewModel {
    private struct DirectorySearchScope {
        let directory: String
        let path: String
        let isPathLike: Bool
        let displayPrefix: String?
    }

    func prepareDirectorySelection(_ directory: String?) {
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedDirectory = directory
            selectedProjectContentTab = .sessions
            directoryState.isLoadingSessions = true
            directoryState.selectedSession = nil
            directoryState.isLoadingSelectedSession = false
            directoryState.messages = []
            directoryState.todos = []
            directoryState.permissions = []
            directoryState.questions = []
            directoryState.mcpStatuses = [:]
            directoryState.isMCPReady = false
            directoryState.isLoadingMCP = false
            directoryState.togglingMCPServerNames = []
            directoryState.mcpErrorMessage = nil
            directoryState.vcsInfo = nil
            directoryState.vcsFileStatuses = []
            directoryState.vcsDiffsByMode = [:]
            directoryState.selectedVCSMode = .git
            directoryState.selectedVCSFile = nil
            directoryState.projectFilesMode = .changes
            directoryState.fileTreeRootNodes = []
            directoryState.fileTreeChildrenByParentPath = [:]
            directoryState.expandedFileTreeDirectories = []
            directoryState.selectedProjectFilePath = nil
            directoryState.fileContentsByPath = [:]
            directoryState.isLoadingFileTree = false
            directoryState.isLoadingSelectedFileContent = false
            directoryState.fileTreeErrorMessage = nil
            directoryState.fileContentErrorMessage = nil
            directoryState.vcsErrorMessage = nil
        }
    }

    var effectiveSelectedDirectory: String? {
        if let selectedDirectory, !selectedDirectory.isEmpty {
            return selectedDirectory
        }

        guard let currentProject, currentProject.id != "global" else {
            return nil
        }

        return currentProject.worktree
    }

    var currentPinScopeKey: String {
        if isUsingAppleIntelligence {
            return [
                "apple-intelligence",
                activeAppleIntelligenceWorkspaceID ?? "global",
            ].joined(separator: "|")
        }

        return [
            "server",
            config.recentServerID,
            effectiveSelectedDirectory ?? "global",
        ].joined(separator: "|")
    }

    var currentProjectPreferenceScopeKey: String {
        currentPinScopeKey
    }

    var isLiveActivityAutoStartEnabled: Bool {
        liveActivityAutoStartByScope[currentProjectPreferenceScopeKey] ?? false
    }

    func presentProjectPicker() {
        withAnimation(opencodeSelectionAnimation) {
            isShowingProjectPicker = true
        }
    }

    func presentCreateProjectSheet() {
        createProjectQuery = ""
        createProjectResults = []
        createProjectSelectedDirectory = nil
        withAnimation(opencodeSelectionAnimation) {
            isShowingCreateProjectSheet = true
        }
    }

    func searchProjects() async {
        let query = projectSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            projectSearchResults = []
            return
        }

        do {
            projectSearchResults = try await client.findFiles(query: query, directory: defaultSearchRoot)
                .filter { $0.hasSuffix("/") }
                .map { value in
                    let trimmed = String(value.dropLast())
                    if trimmed.hasPrefix("/") { return trimmed }
                    return defaultSearchRoot + "/" + trimmed
                }
        } catch {
            projectSearchResults = []
        }
    }

    func searchCreateProjectDirectories() async {
        let query = cleanedDirectorySearchInput(createProjectQuery)

        do {
            if query.isEmpty {
                createProjectSelectedDirectory = nil
                createProjectResults = try await client.listFiles(directory: "/")
                    .filter { $0.type == "directory" }
                    .map(\.absolute)
                return
            }

            guard let scope = directorySearchScope(for: query) else {
                createProjectResults = []
                return
            }

            if scope.isPathLike {
                let results = try await pathAutocompleteResults(for: scope)
                createProjectSelectedDirectory = try await resolveCreateProjectDirectory(for: query, scope: scope)
                createProjectResults = Array(results.prefix(50))
                return
            }

            createProjectSelectedDirectory = nil
            createProjectResults = try await client.findFiles(query: query, directory: defaultSearchRoot)
                .filter { $0.hasSuffix("/") }
                .map { value in
                    let trimmed = String(value.dropLast())
                    if trimmed.hasPrefix("/") { return trimmed }
                    return defaultSearchRoot + "/" + trimmed
                }
        } catch {
            createProjectSelectedDirectory = nil
            createProjectResults = []
        }
    }

    func selectCreateProjectDirectory(_ directory: String) async {
        withAnimation(opencodeSelectionAnimation) {
            createProjectSelectedDirectory = directory
        }
        let displayPath = createProjectResultPath(directory)
        createProjectQuery = displayPath.hasSuffix("/") ? displayPath : displayPath + "/"
        await searchCreateProjectDirectories()
    }

    func createProjectResultPath(_ absolute: String) -> String {
        let query = cleanedDirectorySearchInput(createProjectQuery)
        guard query.hasPrefix("~") else { return absolute }
        let home = defaultSearchRoot
        if absolute == home { return "~" }
        if absolute.hasPrefix(home + "/") {
            return "~" + String(absolute.dropFirst(home.count))
        }
        return absolute
    }

    func createProject(from directory: String) async {
        isLoading = true
        defer { isLoading = false }

        let normalizedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDirectory.isEmpty else { return }

        do {
            _ = try? await client.listSessions(directory: normalizedDirectory, roots: true, limit: 55)
            let discovered = try await client.currentProject(directory: normalizedDirectory)
            let projectName = URL(fileURLWithPath: normalizedDirectory).lastPathComponent
            let selectedProjectDirectory: String

            if discovered.id == "global" {
                let localProject = OpenCodeProject(
                    id: localProjectID(for: normalizedDirectory),
                    worktree: normalizedDirectory,
                    vcs: nil,
                    name: projectName,
                    icon: nil,
                    time: nil
                )
                mergeProjectsPreservingLocal(serverProjects: projects + [localProject])
                selectedProjectDirectory = normalizedDirectory
            } else {
                let canonicalDirectory = discovered.worktree
                _ = try await client.updateProject(projectID: discovered.id, directory: canonicalDirectory, name: projectName)
                try await refreshProjects()
                selectedProjectDirectory = canonicalDirectory
            }

            createProjectQuery = ""
            createProjectResults = []
            createProjectSelectedDirectory = nil
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateProjectSheet = false
            }
            await selectDirectory(selectedProjectDirectory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDirectory(_ directory: String?) async {
        prepareDirectorySelection(directory)
        do {
            if let directory, !directory.isEmpty {
                _ = try await client.listSessions(directory: directory, roots: true, limit: 55)
                try await refreshProjects()
            } else {
                try await refreshProjects()
            }
            try await reloadSessions()
            await loadComposerOptions()
            withAnimation(opencodeSelectionAnimation) {
                isShowingProjectPicker = false
            }
        } catch {
            directoryState.isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ project: OpenCodeProject?) async {
        guard let project else {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = projects.first(where: { $0.id == "global" })
            }
            await selectDirectory(nil)
            return
        }

        if project.id == "global" {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = project
            }
            await selectDirectory(nil)
            return
        }

        withAnimation(opencodeSelectionAnimation) {
            currentProject = project
        }
        await selectDirectory(project.worktree)
    }

    var projectScopeTitle: String {
        if effectiveSelectedDirectory == nil {
            return "Global"
        }
        return effectiveSelectedDirectory ?? currentProject?.worktree ?? "All Projects"
    }

    func isProjectSelected(_ project: OpenCodeProject?) -> Bool {
        guard currentProject != nil else { return false }

        switch project {
        case .none:
            return selectedDirectory == nil
        case let .some(project):
            if project.id == "global" {
                return selectedDirectory == nil
            }
            return selectedDirectory == project.worktree
        }
    }

    func refreshProjects() async throws {
        let serverProjects = try await client.listProjects()
        mergeProjectsPreservingLocal(serverProjects: serverProjects)
        let serverProject = try? await client.currentProject()
        reconcileCurrentProjectSelection(serverProject: serverProject)
    }

    private func cleanedDirectorySearchInput(_ value: String) -> String {
        value
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func directorySearchScope(for query: String) -> DirectorySearchScope? {
        if query.hasPrefix("~/") {
            return .init(directory: defaultSearchRoot, path: String(query.dropFirst(2)), isPathLike: true, displayPrefix: "~")
        }

        if query == "~" {
            return .init(directory: defaultSearchRoot, path: "", isPathLike: true, displayPrefix: "~")
        }

        if query.hasPrefix("/") {
            return .init(directory: "/", path: String(query.dropFirst()), isPathLike: true, displayPrefix: nil)
        }

        if query.contains("/") {
            return .init(directory: defaultSearchRoot, path: query, isPathLike: true, displayPrefix: nil)
        }

        return .init(directory: defaultSearchRoot, path: query, isPathLike: false, displayPrefix: nil)
    }

    private func pathAutocompleteResults(for scope: DirectorySearchScope) async throws -> [String] {
        let normalizedPath = scope.path.replacingOccurrences(of: "//", with: "/")
        let trimmedTrailingSlash = normalizedPath.hasSuffix("/") ? String(normalizedPath.dropLast()) : normalizedPath

        let parentPath: String
        let partialName: String
        let shouldListChildrenDirectly = normalizedPath.isEmpty || normalizedPath.hasSuffix("/")

        if shouldListChildrenDirectly {
            parentPath = trimmedTrailingSlash
            partialName = ""
        } else if let slashIndex = trimmedTrailingSlash.lastIndex(of: "/") {
            parentPath = String(trimmedTrailingSlash[..<slashIndex])
            partialName = String(trimmedTrailingSlash[trimmedTrailingSlash.index(after: slashIndex)...])
        } else {
            parentPath = ""
            partialName = trimmedTrailingSlash
        }

        let nodes = try await client.listFiles(directory: scope.directory, path: parentPath)
        let directories = nodes
            .filter { $0.type == "directory" }
            .map(\.absolute)

        guard !partialName.isEmpty else {
            return directories.sorted()
        }

        let lowercasedPartial = partialName.lowercased()
        let prefixMatches = directories.filter {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased().hasPrefix(lowercasedPartial)
        }
        if !prefixMatches.isEmpty {
            return prefixMatches.sorted()
        }

        let containsMatches = directories.filter {
            URL(fileURLWithPath: $0).lastPathComponent.lowercased().contains(lowercasedPartial)
        }
        return containsMatches.sorted()
    }

    private func localProjectID(for directory: String) -> String {
        "local:\(directory)"
    }

    private func mergeProjectsPreservingLocal(serverProjects: [OpenCodeProject]) {
        let localProjects = projects.filter { $0.id.hasPrefix("local:") }
        var merged: [String: OpenCodeProject] = [:]

        for project in localProjects {
            merged[project.id] = project
        }

        for project in serverProjects {
            merged[project.id] = project
        }

        projects = merged.values.sorted { lhs, rhs in
            if lhs.id == "global" { return true }
            if rhs.id == "global" { return false }
            return (lhs.name ?? lhs.worktree) < (rhs.name ?? rhs.worktree)
        }
    }

    private func resolveCreateProjectDirectory(for query: String, scope: DirectorySearchScope) async throws -> String? {
        guard scope.isPathLike,
              let candidate = absoluteDirectoryCandidate(for: query, scope: scope) else {
            return nil
        }

        _ = try await client.listFiles(directory: candidate, path: "")
        return candidate
    }

    private func absoluteDirectoryCandidate(for query: String, scope: DirectorySearchScope) -> String? {
        if query == "~" || query == "~/" {
            return defaultSearchRoot
        }

        if query == "/" {
            return "/"
        }

        let trimmedPath = scope.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            return scope.directory
        }

        let baseURL = URL(fileURLWithPath: scope.directory, isDirectory: true)
        return baseURL.appendingPathComponent(trimmedPath, isDirectory: true).path
    }

    func reconcileCurrentProjectSelection(serverProject: OpenCodeProject?) {
        if let selectedDirectory, !selectedDirectory.isEmpty {
            currentProject = projects.first(where: { $0.worktree == selectedDirectory })
                ?? serverProject.flatMap { project in
                    project.worktree == selectedDirectory ? project : nil
                }
            return
        }

        guard currentProject != nil else { return }

        currentProject = projects.first(where: { $0.id == "global" })
            ?? serverProject.flatMap { project in
                project.id == "global" ? project : nil
            }
    }

    func loadSessionPreviews() -> [String: SessionPreview] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.sessionPreviews),
              let decoded = try? JSONDecoder().decode([String: SessionPreview].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func loadPinnedSessionIDsByScope() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.pinnedSessionsByScope),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func loadLiveActivityAutoStartByScope() -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.liveActivityAutoStartByScope),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func persistSessionPreviews() {
        guard let data = try? JSONEncoder().encode(sessionPreviews) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.sessionPreviews)
    }

    func persistPinnedSessionIDsByScope() {
        guard let data = try? JSONEncoder().encode(pinnedSessionIDsByScope) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.pinnedSessionsByScope)
    }

    func persistLiveActivityAutoStartByScope() {
        guard let data = try? JSONEncoder().encode(liveActivityAutoStartByScope) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.liveActivityAutoStartByScope)
    }

    func setSessionPreview(_ preview: SessionPreview, for sessionID: String) {
        guard sessionPreviews[sessionID] != preview else { return }
        sessionPreviews[sessionID] = preview
        persistSessionPreviews()
        publishWidgetSnapshots()
    }

    func removeSessionPreview(for sessionID: String) {
        sessionPreviews[sessionID] = nil
        persistSessionPreviews()
        removeWidgetSessionSnapshot(for: sessionID)
    }

    func isSessionPinned(_ session: OpenCodeSession) -> Bool {
        pinnedSessionIDs.contains(session.id)
    }

    func pinSession(_ session: OpenCodeSession, at targetIndex: Int? = nil) {
        guard session.isRootSession else { return }
        withAnimation(opencodeSelectionAnimation) {
            insertPinnedSession(withID: session.id, at: targetIndex ?? pinnedSessionIDs.count)
        }
    }

    func unpinSession(_ session: OpenCodeSession) {
        withAnimation(opencodeSelectionAnimation) {
            setPinnedSessionIDs(pinnedSessionIDs.filter { $0 != session.id })
        }
    }

    func movePinnedSessions(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var ids = pinnedSessionIDs
        ids.move(fromOffsets: offsets, toOffset: destination)
        withAnimation(opencodeSelectionAnimation) {
            setPinnedSessionIDs(ids)
        }
    }

    func insertPinnedSession(withID sessionID: String, at targetIndex: Int) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        var ids = pinnedSessionIDs
        let boundedTarget = min(max(targetIndex, 0), ids.count)

        if let currentIndex = ids.firstIndex(of: sessionID) {
            ids.remove(at: currentIndex)
            let adjustedTarget = currentIndex < boundedTarget ? boundedTarget - 1 : boundedTarget
            ids.insert(sessionID, at: min(max(adjustedTarget, 0), ids.count))
        } else {
            ids.insert(sessionID, at: boundedTarget)
        }

        withAnimation(opencodeSelectionAnimation) {
            setPinnedSessionIDs(ids)
        }
    }

    func prunePinnedSessionsForCurrentScope() {
        let visibleSessionIDs = Set(sessions.map(\.id))
        setPinnedSessionIDs(pinnedSessionIDs.filter { visibleSessionIDs.contains($0) })
    }

    func removePinnedSessionIDFromAllScopes(_ sessionID: String) {
        var next = pinnedSessionIDsByScope

        for (key, ids) in pinnedSessionIDsByScope {
            let filtered = ids.filter { $0 != sessionID }
            if filtered.isEmpty {
                next[key] = nil
            } else {
                next[key] = filtered
            }
        }

        guard next != pinnedSessionIDsByScope else { return }
        pinnedSessionIDsByScope = next
        persistPinnedSessionIDsByScope()
        publishWidgetSnapshots()
    }

    func setPinnedSessionIDs(_ sessionIDs: [String], for scopeKey: String? = nil) {
        let key = scopeKey ?? currentPinScopeKey
        var deduplicated: [String] = []
        var seen = Set<String>()

        for sessionID in sessionIDs where seen.insert(sessionID).inserted {
            deduplicated.append(sessionID)
        }

        if deduplicated.isEmpty {
            pinnedSessionIDsByScope[key] = nil
        } else {
            pinnedSessionIDsByScope[key] = deduplicated
        }

        persistPinnedSessionIDsByScope()
        publishWidgetSnapshots()
    }

    func setLiveActivityAutoStartEnabled(_ isEnabled: Bool, for scopeKey: String? = nil) {
        let key = scopeKey ?? currentProjectPreferenceScopeKey

        if isEnabled {
            liveActivityAutoStartByScope[key] = true
        } else {
            liveActivityAutoStartByScope[key] = nil
        }

        persistLiveActivityAutoStartByScope()
    }

    func refreshSessionPreview(for sessionID: String, messages: [OpenCodeMessageEnvelope]) {
        setSessionPreview(buildSessionPreview(from: messages), for: sessionID)
    }

    func buildSessionPreview(from messages: [OpenCodeMessageEnvelope]) -> SessionPreview {
        guard let message = messages.last(where: { message in
            message.parts.contains { part in
                guard let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
                return !text.isEmpty
            }
        }) else {
            return SessionPreview(text: "No messages yet", date: nil)
        }

        let text = message.parts
            .compactMap { part -> String? in
                part.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .joined(separator: "\n")
        let previewText = opencodePreviewText(text, limit: 120)

        let date = dateFromMilliseconds(message.info.time?.completed ?? message.info.time?.created)
        return SessionPreview(text: previewText ?? "No preview available", date: date)
    }

    func dateFromMilliseconds(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
