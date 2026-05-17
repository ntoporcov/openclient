import Foundation
import SwiftUI

extension AppViewModel {
    func prepareDirectorySelection(_ directory: String?) {
        preserveCurrentMessageDraftForNavigation()
        withAnimation(opencodeSelectionAnimation) {
            selectedDirectory = directory
            selectedProjectContentTab = .sessions
            isLoadingSessions = true
            selectedSession = nil
            isLoadingSelectedSession = false
            messages = []
            sessionInteractionStore.reset()
            mcpStore.reset()
            projectFilesStore.reset()
            selectedFilesWorkspaceDirectory = nil
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

    func presentProjectSettingsSheet() {
        withAnimation(opencodeSelectionAnimation) {
            isShowingProjectSettingsSheet = true
        }
    }

    func searchProjects() async {
        projectSearchResults = await projectCoordinator.searchProjects(
            client: client,
            query: projectSearchQuery,
            defaultSearchRoot: defaultSearchRoot
        )
    }

    func searchCreateProjectDirectories() async {
        let result = await projectCoordinator.searchCreateProjectDirectories(
            client: client,
            query: createProjectQuery,
            defaultSearchRoot: defaultSearchRoot
        )
        createProjectSelectedDirectory = result.selectedDirectory
        createProjectResults = result.results
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
        projectCoordinator.createProjectResultPath(
            absolute,
            query: createProjectQuery,
            defaultSearchRoot: defaultSearchRoot
        )
    }

    func createProject(from directory: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            guard let result = try await projectCoordinator.createProject(
                client: client,
                directory: directory,
                currentProjects: projects
            ) else {
                return
            }

            if let nextProjects = result.projects {
                projects = nextProjects
            } else {
                try await refreshProjects()
            }

            createProjectQuery = ""
            createProjectResults = []
            createProjectSelectedDirectory = nil
            withAnimation(opencodeSelectionAnimation) {
                isShowingCreateProjectSheet = false
            }
            await selectDirectory(result.selectedDirectory)
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
            isLoadingSessions = false
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ project: OpenCodeProject?) async {
        let selection = projectCoordinator.selectionResult(for: project, projects: projects)
        withAnimation(opencodeSelectionAnimation) {
            currentProject = selection.currentProject
        }
        await selectDirectory(selection.selectedDirectory)
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
        let result = try await projectCoordinator.refreshProjects(
            client: client,
            currentProjects: projects,
            currentProject: currentProject,
            selectedDirectory: selectedDirectory
        )
        projects = result.projects
        currentProject = result.currentProject
    }

    func refreshProjectList() async {
        do {
            try await refreshProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
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

    func loadProjectWorkspacesEnabledByScope() -> [String: Bool] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.projectWorkspacesEnabledByScope),
              let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
            return [:]
        }
        return decoded
    }

    func loadProjectActionsByScope() -> [String: [OpenCodeAction]] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.projectActionsByScope),
              let decoded = try? JSONDecoder().decode([String: [OpenCodeAction]].self, from: data) else {
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

    func persistProjectWorkspacesEnabledByScope() {
        guard let data = try? JSONEncoder().encode(projectWorkspacesEnabledByScope) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.projectWorkspacesEnabledByScope)
    }

    func persistProjectActionsByScope() {
        guard let data = try? JSONEncoder().encode(projectActionsByScope) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.projectActionsByScope)
    }

    func setSessionPreview(_ preview: SessionPreview, for sessionID: String) {
        guard sessionListStore.setPreview(preview, for: sessionID) else { return }
        persistSessionPreviews()
        scheduleWidgetSnapshotPublication()
    }

    func removeSessionPreview(for sessionID: String) {
        sessionListStore.removePreview(for: sessionID)
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
        guard sessionListStore.removePinnedSessionIDFromAllScopes(sessionID) else { return }
        objectWillChange.send()
        persistPinnedSessionIDsByScope()
        publishWidgetSnapshots()
    }

    func setPinnedSessionIDs(_ sessionIDs: [String], for scopeKey: String? = nil) {
        let key = scopeKey ?? currentPinScopeKey
        objectWillChange.send()
        sessionListStore.setPinnedSessionIDs(sessionIDs, for: key)
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

    func setProjectWorkspacesEnabled(_ isEnabled: Bool, for scopeKey: String? = nil) {
        let key = scopeKey ?? currentProjectPreferenceScopeKey

        if isEnabled {
            projectWorkspacesEnabledByScope[key] = true
        } else {
            projectWorkspacesEnabledByScope[key] = nil
        }

        persistProjectWorkspacesEnabledByScope()
    }

    var currentProjectActions: [OpenCodeAction] {
        projectActionsByScope[currentProjectPreferenceScopeKey] ?? []
    }

    var actionEligibleCommands: [OpenCodeCommand] {
        var seen = Set<String>()
        return directoryCommands
            .filter { command in
                guard command.source != "client" else { return false }
                return seen.insert(command.name).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func actionCommand(for action: OpenCodeAction) -> OpenCodeCommand? {
        actionEligibleCommands.first { $0.name == action.commandName }
    }

    func addProjectAction(commandName: String, iconName: String) {
        let trimmedName = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let trimmedIcon = iconName.trimmingCharacters(in: .whitespacesAndNewlines)

        var actions = currentProjectActions.filter { $0.commandName != trimmedName }
        actions.append(OpenCodeAction(commandName: trimmedName, iconName: trimmedIcon.isEmpty ? "bolt.fill" : trimmedIcon))
        setProjectActions(actions)
    }

    func removeProjectAction(_ action: OpenCodeAction) {
        setProjectActions(currentProjectActions.filter { $0.id != action.id })
    }

    func updateProjectActionIcon(actionID: UUID, iconName: String) {
        let trimmedIcon = iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        var actions = currentProjectActions
        guard let index = actions.firstIndex(where: { $0.id == actionID }) else { return }
        actions[index].iconName = trimmedIcon.isEmpty ? "bolt.fill" : trimmedIcon
        setProjectActions(actions)
    }

    func moveProjectActions(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var actions = currentProjectActions
        actions.move(fromOffsets: offsets, toOffset: destination)
        setProjectActions(actions)
    }

    func isActionRunning(_ action: OpenCodeAction) -> Bool {
        pendingActionRunsBySessionID.values.contains { $0.actionID == action.id }
    }

    func actionRunPhase(for action: OpenCodeAction) -> OpenCodeActionRunPhase? {
        pendingActionRunsBySessionID.values.first { $0.actionID == action.id }?.phase
    }

    func isActionSession(_ session: OpenCodeSession) -> Bool {
        pendingActionRunsBySessionID[session.id] != nil || Self.isActionSessionTitle(session.title)
    }

    static func isActionSessionTitle(_ title: String?) -> Bool {
        title?.hasPrefix(actionSessionTitlePrefix) == true
    }

    func hiddenActionSessionTitle(commandName: String, runID: String) -> String {
        "\(Self.actionSessionTitlePrefix)\(commandName):\(runID)"
    }

    func actionDebugSessionTitle(commandName: String) -> String {
        "Debug /\(commandName) action"
    }

    private func setProjectActions(_ actions: [OpenCodeAction], for scopeKey: String? = nil) {
        let key = scopeKey ?? currentProjectPreferenceScopeKey
        var deduplicated: [OpenCodeAction] = []
        var seen = Set<String>()

        for action in actions where seen.insert(action.commandName).inserted {
            deduplicated.append(action)
        }

        if deduplicated.isEmpty {
            projectActionsByScope[key] = nil
        } else {
            projectActionsByScope[key] = deduplicated
        }

        persistProjectActionsByScope()
    }

    func workspaceDirectories(for project: OpenCodeProject? = nil) -> [String] {
        guard let project = project ?? currentProject, project.id != "global" else { return [] }
        var directories = [project.worktree]
        var seen = Set(directories.map(workspaceKey))

        for sandbox in project.sandboxes ?? [] {
            let key = workspaceKey(sandbox)
            guard seen.insert(key).inserted else { continue }
            directories.append(sandbox)
        }

        return directories
    }

    func workspaceDisplayName(for directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        guard let project = currentProject else {
            return URL(fileURLWithPath: directory).lastPathComponent
        }

        if workspaceKey(directory) == workspaceKey(project.worktree) {
            return "Local"
        }

        return URL(fileURLWithPath: directory).lastPathComponent
    }

    func newSessionWorkspaceTitle(for selection: NewSessionWorkspaceSelection) -> String {
        switch selection {
        case .main:
            return workspaceDisplayName(for: currentProject?.worktree) ?? "Main branch"
        case let .directory(directory):
            return workspaceDisplayName(for: directory) ?? URL(fileURLWithPath: directory).lastPathComponent
        case .createNew:
            return "Create new worktree"
        }
    }

    func appendSandboxDirectory(_ directory: String, to project: OpenCodeProject) {
        let key = workspaceKey(directory)
        let existingSandboxes = project.sandboxes ?? []
        guard !existingSandboxes.contains(where: { workspaceKey($0) == key }) else { return }

        let updatedProject = OpenCodeProject(
            id: project.id,
            worktree: project.worktree,
            vcs: project.vcs,
            name: project.name,
            sandboxes: existingSandboxes + [directory],
            icon: project.icon,
            time: project.time
        )

        if currentProject?.id == project.id {
            currentProject = updatedProject
        }

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = updatedProject
        }
    }

    func workspaceKey(_ directory: String) -> String {
        let normalized = directory.replacingOccurrences(of: "\\", with: "/")
        if normalized.allSatisfy({ $0 == "/" }) { return "/" }
        return normalized.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
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
