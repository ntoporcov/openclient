import Foundation

extension AppViewModel {
    private struct DirectorySearchScope {
        let directory: String
        let path: String
        let isPathLike: Bool
        let displayPrefix: String?
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

    func presentProjectPicker() {
        isShowingProjectPicker = true
    }

    func presentCreateProjectSheet() {
        createProjectQuery = ""
        createProjectResults = []
        createProjectSelectedDirectory = nil
        isShowingCreateProjectSheet = true
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
        createProjectSelectedDirectory = directory
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
            isShowingCreateProjectSheet = false
            await selectDirectory(selectedProjectDirectory)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectDirectory(_ directory: String?) async {
        selectedDirectory = directory
        directoryState.selectedSession = nil
        directoryState.messages = []
        directoryState.todos = []
        directoryState.permissions = []
        directoryState.questions = []
        do {
            if let directory, !directory.isEmpty {
                _ = try await client.listSessions(directory: directory, roots: true, limit: 55)
                try await refreshProjects()
            } else {
                try await refreshProjects()
            }
            try await reloadSessions()
            await loadComposerOptions()
            isShowingProjectPicker = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ project: OpenCodeProject?) async {
        guard let project else {
            await selectDirectory(nil)
            return
        }

        if project.id == "global" {
            currentProject = project
            await selectDirectory(nil)
            return
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

    func directorySelection(for project: OpenCodeProject?) -> String? {
        guard let project, project.id != "global" else { return nil }
        return project.worktree
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

        currentProject = projects.first(where: { $0.id == "global" })
            ?? serverProject.flatMap { project in
                project.id == "global" ? project : nil
            }
    }

    func prefetchSessionPreviews(for sessions: [OpenCodeSession]) {
        for session in sessions where sessionPreviews[session.id] == nil {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let messages = try await self.client.listMessages(sessionID: session.id, limit: 1)
                    let preview = self.buildSessionPreview(from: messages.first)
                    await MainActor.run {
                        self.sessionPreviews[session.id] = preview
                    }
                } catch {
                    return
                }
            }
        }
    }

    func buildSessionPreview(from message: OpenCodeMessageEnvelope?) -> SessionPreview {
        guard let message else {
            return SessionPreview(text: "No messages yet", date: nil)
        }

        let text = message.parts
            .compactMap { part -> String? in
                if let text = part.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text.replacingOccurrences(of: "\n", with: " ")
                }
                if part.type == "tool", let tool = part.tool {
                    return tool.replacingOccurrences(of: "-", with: " ").capitalized
                }
                return nil
            }
            .joined(separator: " ")

        let date = dateFromMilliseconds(message.info.time?.completed ?? message.info.time?.created)
        return SessionPreview(text: text.isEmpty ? "No preview available" : text, date: date)
    }

    func dateFromMilliseconds(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
