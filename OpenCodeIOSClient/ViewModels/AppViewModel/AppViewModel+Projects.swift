import Foundation
import SwiftUI

struct ProjectImageCandidate: Identifiable, Hashable {
    let path: String
    let displayPath: String

    var id: String { path }

    var filename: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct RecentSessionLoadResult: Sendable {
    let directory: String?
    let sessions: [OpenCodeSession]
}

struct NewProjectChatComposerSelection: Equatable, Sendable {
    let agentName: String?
    let modelReference: OpenCodeModelReference?
    let reasoningVariant: String?
}

struct NewProjectChatInitialContent: Equatable, Sendable {
    let text: String
    let attachments: [OpenCodeComposerAttachment]
}

struct NewProjectChatSheetRequest: Identifiable, Sendable {
    let id: UUID
    let projectID: String?
    let workspaceDirectory: String?
    let locksProject: Bool
    let composerSelection: NewProjectChatComposerSelection?
    let initialContent: NewProjectChatInitialContent?
    let presentsAboveConnection: Bool

    init(
        id: UUID = UUID(),
        projectID: String?,
        workspaceDirectory: String?,
        locksProject: Bool,
        composerSelection: NewProjectChatComposerSelection?,
        initialContent: NewProjectChatInitialContent? = nil,
        presentsAboveConnection: Bool = false
    ) {
        self.id = id
        self.projectID = projectID
        self.workspaceDirectory = workspaceDirectory
        self.locksProject = locksProject
        self.composerSelection = composerSelection
        self.initialContent = initialContent
        self.presentsAboveConnection = presentsAboveConnection
    }
}

extension AppViewModel {
    var projectSessionSearchQuery: String {
        get { sessionListStore.projectSessionSearchQuery }
        set {
            objectWillChange.send()
            sessionListStore.projectSessionSearchQuery = newValue
            sessionListStore.projectSessionSearchResults = cachedProjectSessionSearchResults(for: newValue)
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sessionListStore.isSearchingProjectSessions = false
            }
        }
    }

    var projectSessionSearchResults: [RecentProjectSession] {
        sessionListStore.projectSessionSearchResults
    }

    var isSearchingProjectSessions: Bool {
        sessionListStore.isSearchingProjectSessions
    }

    func beginProjectNavigation(_ project: OpenCodeProject) -> String? {
        let previousSessionID = selectedSession?.id
        let nextDirectory = project.id == "global" ? nil : project.worktree
        withAnimation(opencodeSelectionAnimation) {
            currentProject = project
            selectedDirectory = nextDirectory
            selectedProjectContentTab = .sessions
            isLoadingSessions = true
            selectedSession = nil
        }
        return previousSessionID
    }

    func prepareDirectorySelection(_ directory: String?) {
        prepareDirectorySelection(
            directory,
            preservingDraftForSessionID: selectedSession?.id,
            animatesChanges: true
        )
    }

    func prepareDirectorySelection(
        _ directory: String?,
        preservingDraftForSessionID previousSessionID: String?,
        animatesChanges: Bool
    ) {
        sessionNavigationGeneration &+= 1
        if let previousSessionID {
            preserveCurrentMessageDraftForNavigation(forSessionID: previousSessionID)
        }
        let applyChanges = { [self] in
            selectedDirectory = directory
            selectedProjectContentTab = .sessions
            isLoadingSessions = true
            selectedSession = nil
            isLoadingSelectedSession = false
            messages = []
            sessionInteractionStore.reset()
            mcpFacade.reset()
            projectFilesFacade.reset()
        }
        if animatesChanges {
            withAnimation(opencodeSelectionAnimation, applyChanges)
        } else {
            applyChanges()
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

    var recentProjectSessions: [RecentProjectSession] {
        guard showsRecentSessionsInProjectList else { return [] }
        return sessionListStore.recentProjectSessions(
            projects: projects,
            previews: sessionPreviews,
            statuses: sessionStatuses
        )
    }

    var isLoadingRecentProjectSessions: Bool {
        showsRecentSessionsInProjectList && sessionListStore.isLoadingRecentProjectSessions
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

    func presentNewProjectChatSheet(
        projectID: String? = nil,
        workspaceDirectory: String? = nil,
        locksProject: Bool = false,
        composerSelection: NewProjectChatComposerSelection? = nil,
        initialContent: NewProjectChatInitialContent? = nil,
        presentsAboveConnection: Bool = false
    ) {
        newProjectChatSheetRequest = NewProjectChatSheetRequest(
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            locksProject: locksProject,
            composerSelection: composerSelection,
            initialContent: initialContent,
            presentsAboveConnection: presentsAboveConnection
        )
    }

    func dismissNewProjectChatSheet() {
        newProjectChatSheetRequest = nil
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

    func canEditProjectPreferences(_ project: OpenCodeProject) -> Bool {
        project.id != "global" && !project.id.hasPrefix("local:") && !project.worktree.isEmpty
    }

    func setProjectColor(_ color: String, for project: OpenCodeProject) async {
        guard canEditProjectPreferences(project) else { return }
        let icon = OpenCodeProject.Icon(
            url: project.icon?.url,
            override: project.icon?.override,
            color: color
        )
        await updateProjectPreferences(project, icon: icon)
    }

    func setProjectImageOverride(_ dataURL: String?, for project: OpenCodeProject) async {
        guard canEditProjectPreferences(project) else { return }
        let icon = OpenCodeProject.Icon(
            url: project.icon?.url,
            override: dataURL ?? "",
            color: project.icon?.color
        )
        await updateProjectPreferences(project, icon: icon)
    }

    func discoverProjectImageCandidates(for project: OpenCodeProject) async -> [ProjectImageCandidate] {
        guard canEditProjectPreferences(project) else { return [] }

        var paths = Set<String>()
        for query in ["png", "jpg", "jpeg"] {
            do {
                let results = try await client.findFiles(query: query, directory: project.worktree)
                for result in results where isSupportedProjectImagePath(result) {
                    paths.insert(result)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }

        return paths
            .sorted { lhs, rhs in
                let lhsName = URL(fileURLWithPath: lhs).lastPathComponent
                let rhsName = URL(fileURLWithPath: rhs).lastPathComponent
                let nameOrder = lhsName.localizedCaseInsensitiveCompare(rhsName)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
            .prefix(96)
            .map { path in
                ProjectImageCandidate(
                    path: path,
                    displayPath: displayPath(forProjectImagePath: path, directory: project.worktree)
                )
            }
    }

    func projectImageDataURL(for candidate: ProjectImageCandidate, project: OpenCodeProject) async -> String? {
        guard canEditProjectPreferences(project) else { return nil }
        do {
            let content = try await client.readFileContent(
                directory: project.worktree,
                path: requestPath(forProjectImagePath: candidate.path, directory: project.worktree)
            )
            guard content.encoding == "base64" || content.type == "binary" else { return nil }
            let mime = content.mimeType ?? mimeType(forProjectImagePath: candidate.path)
            return "data:\(mime);base64,\(content.content)"
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func selectDirectory(_ directory: String?) async {
        await selectDirectory(
            directory,
            preservingDraftForSessionID: selectedSession?.id,
            animatesPreparation: true
        )
    }

    func selectDirectory(
        _ directory: String?,
        preservingDraftForSessionID previousSessionID: String?,
        animatesPreparation: Bool,
        isPreparedForNavigation: Bool = false
    ) async {
        let cachedDirectory: OpenCodeCachedDirectorySessionsSnapshot?
        if isPreparedForNavigation {
            cachedDirectory = nil
        } else {
            prepareDirectorySelection(
                directory,
                preservingDraftForSessionID: previousSessionID,
                animatesChanges: animatesPreparation
            )
            cachedDirectory = await hydrateDirectoryFromLocalCache(directory)
        }
        guard DirectoryStoreRegistry.key(for: effectiveSelectedDirectory) == DirectoryStoreRegistry.key(for: directory) else {
            return
        }
        if isBrowsingLocalCache {
            isLoadingSessions = false
            streamDirectory = directory
            withAnimation(opencodeSelectionAnimation) {
                isShowingProjectPicker = false
            }
            return
        }
        if cachedDirectory?.isFresh() == true {
            isLoadingSessions = false
            streamDirectory = directory
            withAnimation(opencodeSelectionAnimation) {
                isShowingProjectPicker = false
            }
        }
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

    private func updateProjectPreferences(_ project: OpenCodeProject, icon: OpenCodeProject.Icon) async {
        do {
            let updated = try await client.updateProject(
                projectID: project.id,
                directory: project.worktree,
                name: project.name,
                icon: icon
            )
            applyUpdatedProject(updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyUpdatedProject(_ project: OpenCodeProject) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        if currentProject?.id == project.id {
            currentProject = project
        }
        persistProjectsToLocalCache()
    }

    private func isSupportedProjectImagePath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasSuffix(".png") || lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg")
    }

    private func requestPath(forProjectImagePath path: String, directory: String) -> String {
        if path == directory { return "" }
        if path.hasPrefix(directory + "/") {
            return String(path.dropFirst(directory.count + 1))
        }
        return path
    }

    private func displayPath(forProjectImagePath path: String, directory: String) -> String {
        requestPath(forProjectImagePath: path, directory: directory)
    }

    private func mimeType(forProjectImagePath path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        default:
            return "image/png"
        }
    }

    func selectProject(_ project: OpenCodeProject?) async {
        await selectProject(
            project,
            preservingDraftForSessionID: selectedSession?.id,
            animatesPreparation: true
        )
    }

    func selectProject(
        _ project: OpenCodeProject?,
        preservingDraftForSessionID previousSessionID: String?,
        animatesPreparation: Bool,
        isPreparedForNavigation: Bool = false
    ) async {
        let selection = projectCoordinator.selectionResult(for: project, projects: projects)
        withAnimation(opencodeSelectionAnimation) {
            currentProject = selection.currentProject
        }
        await selectDirectory(
            selection.selectedDirectory,
            preservingDraftForSessionID: previousSessionID,
            animatesPreparation: animatesPreparation,
            isPreparedForNavigation: isPreparedForNavigation
        )
    }

    @discardableResult
    func prepareProjectNavigation(_ project: OpenCodeProject) async -> String? {
        let previousSessionID = beginProjectNavigation(project)
        _ = await hydrateDirectoryFromLocalCache(project.id == "global" ? nil : project.worktree)
        guard currentProject?.id == project.id else { return nil }
        return previousSessionID
    }

    var projectScopeTitle: String {
        if effectiveSelectedDirectory == nil {
            return String(localized: "Global")
        }
        return effectiveSelectedDirectory ?? currentProject?.worktree ?? String(localized: "All Projects")
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
        persistProjectsToLocalCache()
    }

    func refreshProjectList() async {
        guard !isBrowsingLocalCache else { return }
        do {
            try await refreshProjects()
            await loadRecentProjectSessionsAcrossProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func searchProjectSessionsAcrossProjects() async {
        let query = projectSessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            objectWillChange.send()
            sessionListStore.projectSessionSearchResults = []
            sessionListStore.isSearchingProjectSessions = false
            return
        }

        guard backendMode == .server, isConnected else {
            objectWillChange.send()
            sessionListStore.projectSessionSearchResults = []
            sessionListStore.isSearchingProjectSessions = false
            return
        }

        objectWillChange.send()
        sessionListStore.projectSessionSearchResults = cachedProjectSessionSearchResults(for: query)
        sessionListStore.isSearchingProjectSessions = true

        let directories = projectSessionSearchDirectoriesToLoad()
        let client = client

        await withTaskGroup(of: RecentSessionLoadResult?.self) { group in
            for directory in directories {
                group.addTask {
                    do {
                        let sessions = try await client.listSessions(directory: directory, roots: true, limit: 55)
                        return RecentSessionLoadResult(directory: directory, sessions: sessions)
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                guard let result else { continue }
                guard projectSessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                objectWillChange.send()
                sessionListStore.setRecentSessions(result.sessions, for: result.directory)
                sessionListStore.projectSessionSearchResults = cachedProjectSessionSearchResults(for: query)
            }
        }

        guard projectSessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
        objectWillChange.send()
        sessionListStore.projectSessionSearchResults = cachedProjectSessionSearchResults(for: query)
        sessionListStore.isSearchingProjectSessions = false
    }

    func isProjectWorkspacesEnabled(for project: OpenCodeProject) -> Bool {
        guard project.id != "global", project.vcs == "git" else { return false }
        return projectWorkspacesEnabledByScope[projectPreferenceScopeKey(forDirectory: project.worktree)] ?? false
    }

    func workspaceDisplayName(for directory: String?, in project: OpenCodeProject?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        guard let project else {
            return URL(fileURLWithPath: directory).lastPathComponent
        }

        if workspaceKey(directory) == workspaceKey(project.worktree) {
            return String(localized: "Local")
        }

        return URL(fileURLWithPath: directory).lastPathComponent
    }

    @discardableResult
    func startNewProjectChat(
        title: String = "",
        prompt: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        messageID: String? = nil,
        partID: String? = nil,
        composerSelection: NewProjectChatComposerSelection? = nil,
        projectID: String,
        workspaceDirectory: String? = nil,
        workspaceSelection: NewSessionWorkspaceSelection? = nil,
        newWorkspaceName: String = "",
        onSessionCreated: ((OpenCodeSession) -> Void)? = nil
    ) async -> Bool {
        guard backendMode == .server, isConnected else {
            errorMessage = String(localized: "Connect to an OpenCode server before starting a chat.")
            return false
        }

        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        guard let project = projects.first(where: { $0.id == projectID }) else {
            errorMessage = String(localized: "Project is no longer available.")
            return false
        }
        guard canCreateSessionOrPresentPaywall() else { return false }
        guard reserveUserPromptIfAllowed() else { return false }

        let routeDirectory = project.id == "global" ? nil : project.worktree
        isLoading = true
        defer { isLoading = false }

        do {
            let targetDirectory = try await resolveProjectChatDirectory(
                for: project,
                workspaceDirectory: workspaceDirectory,
                workspaceSelection: workspaceSelection,
                newWorkspaceName: newWorkspaceName
            )
            try Task.checkCancellation()
            currentProject = project
            prepareDirectorySelection(routeDirectory)

            let createSubmission = sessionCoordinator.prepareCreateSession(title: title, directory: targetDirectory)
            let session = try await sessionCoordinator.submitCreate(client: client, submission: createSubmission)
            try Task.checkCancellation()
            onSessionCreated?(session)
            recordCreatedSessionForMetering()
            upsertVisibleSession(session)
            try await reloadSessions()
            try Task.checkCancellation()
            await loadComposerOptions()
            try Task.checkCancellation()
            if let composerSelection {
                applyNewProjectChatComposerSelection(composerSelection, to: session)
            } else {
                seedComposerSelectionsForNewSession(session)
            }
            upsertVisibleSession(session)
            prepareSessionSelection(session)
            await selectSession(session)
            try Task.checkCancellation()

            try await waitForWorktreeReadyIfNeeded(directory: targetDirectory)
            try Task.checkCancellation()

            let didSend = await sendMessage(
                text,
                agentMentions: agentMentions,
                attachments: attachments,
                in: session,
                userVisible: true,
                messageID: messageID,
                partID: partID,
                meterPrompt: false
            )
            if !didSend {
                return false
            }

            errorMessage = nil
            return true
        } catch {
            refundReservedUserPromptIfNeeded()
            isLoadingSessions = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func resolveProjectChatDirectory(
        for project: OpenCodeProject,
        workspaceDirectory: String?,
        workspaceSelection: NewSessionWorkspaceSelection?,
        newWorkspaceName: String
    ) async throws -> String? {
        guard project.id != "global" else { return nil }

        guard let workspaceSelection,
              isProjectWorkspacesEnabled(for: project),
              project.vcs == "git" else {
            if let workspaceDirectory, !workspaceDirectory.isEmpty {
                return workspaceDirectory
            }
            return project.worktree
        }

        switch workspaceSelection {
        case .main:
            return project.worktree
        case let .directory(directory):
            return directory.isEmpty ? project.worktree : directory
        case .createNew:
            let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = try await client.createWorktree(
                directory: project.worktree,
                name: name.isEmpty ? nil : name
            )
            appendSandboxDirectory(created.directory, to: project)
            sessionListStore.ensureWorkspaceStateExists(
                for: created.directory,
                defaultState: OpenCodeWorkspaceSessionState(isLoading: true)
            )
            sessionListStore.setWorkspaceOperation(.preparing, for: created.directory)
            return created.directory
        }
    }

    func applyNewProjectChatComposerSelection(_ selection: NewProjectChatComposerSelection, to session: OpenCodeSession) {
        objectWillChange.send()
        if let agentName = selection.agentName,
           modelConfigurationStore.selectableAgents.contains(where: { $0.name == agentName }) {
            modelConfigurationStore.selectAgent(named: agentName, forSessionID: session.id)
        } else {
            modelConfigurationStore.selectAgent(named: nil, forSessionID: session.id)
        }

        if let modelReference = selection.modelReference,
           modelConfigurationStore.validModelReferences.contains(modelReference) {
            modelConfigurationStore.selectModel(modelReference, forSessionID: session.id)
        } else {
            modelConfigurationStore.selectModel(nil, forSessionID: session.id)
        }

        if let reasoningVariant = selection.reasoningVariant,
           modelConfigurationStore.reasoningVariants(forSessionID: session.id).contains(reasoningVariant) {
            modelConfigurationStore.selectVariant(reasoningVariant, forSessionID: session.id)
        } else {
            modelConfigurationStore.selectVariant(nil, forSessionID: session.id)
        }
    }

    func loadProjectListPreferences() {
        let scopedPreferences = ProjectListPreferencesStore.load()
        guard let key = currentServerDefaultsKey else {
            showsRecentSessionsInProjectList = true
            return
        }

        showsRecentSessionsInProjectList = scopedPreferences.preferencesByBaseURL[key]?.showsRecentSessions ?? true
    }

    func saveProjectListPreferences() {
        guard let key = currentServerDefaultsKey else { return }

        var scopedPreferences = ProjectListPreferencesStore.load()
        scopedPreferences.preferencesByBaseURL[key] = ProjectListPreferences(showsRecentSessions: showsRecentSessionsInProjectList)
        ProjectListPreferencesStore.save(scopedPreferences)
    }

    func setShowsRecentSessionsInProjectList(_ shows: Bool) {
        showsRecentSessionsInProjectList = shows
        saveProjectListPreferences()
    }

    func prepareRecentProjectSessionSelection(_ recent: RecentProjectSession) {
        let navigation = projectCoordinator.recentSessionNavigationResult(for: recent.session, projects: projects)
        projects = navigation.projects
        currentProject = navigation.currentProject
        prepareDirectorySelection(navigation.routeDirectory)
        prepareSessionSelection(recent.session)
    }

    func loadRecentProjectSessionsAcrossProjects() async {
        guard backendMode == .server, isConnected else { return }
        if let recentProjectSessionsLoadTask {
            await recentProjectSessionsLoadTask.value
            return
        }

        let generation = recentProjectSessionsLoadGeneration
        recentProjectSessionsLoadTask = Task { [weak self] in
            await self?.performRecentProjectSessionsLoad(generation: generation)
            await MainActor.run { [weak self] in
                guard let self, self.recentProjectSessionsLoadGeneration == generation else { return }
                self.recentProjectSessionsLoadTask = nil
            }
        }
        await recentProjectSessionsLoadTask?.value
    }

    private func performRecentProjectSessionsLoad(generation: Int) async {
        guard backendMode == .server else { return }
        if ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil, !recentProjectSessions.isEmpty {
            sessionListStore.isLoadingRecentProjectSessions = false
            return
        }

        let directories = projectCoordinator.recentSessionDirectories(
            projects: projects,
            currentProject: currentProject,
            selectedDirectory: selectedDirectory
        )
        guard !directories.isEmpty else { return }

        objectWillChange.send()
        sessionListStore.isLoadingRecentProjectSessions = true
        defer {
            if recentProjectSessionsLoadGeneration == generation {
                objectWillChange.send()
                sessionListStore.isLoadingRecentProjectSessions = false
            }
        }

        let client = client
        await withTaskGroup(of: RecentSessionLoadResult?.self) { group in
            for directory in directories {
                group.addTask {
                    do {
                        let sessions = try await client.listSessions(directory: directory, roots: true, limit: 5)
                        return RecentSessionLoadResult(directory: directory, sessions: sessions)
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                guard let result else { continue }
                guard recentProjectSessionsLoadGeneration == generation else { return }
                objectWillChange.send()
                sessionListStore.setRecentSessions(result.sessions, for: result.directory)
            }
        }
    }

    func beginRecentProjectSessionsLoadingIfPossible() {
        guard backendMode == .server, isConnected else { return }
        guard recentProjectSessionsLoadTask == nil else { return }

        let generation = recentProjectSessionsLoadGeneration
        objectWillChange.send()
        sessionListStore.isLoadingRecentProjectSessions = true
        recentProjectSessionsLoadTask = Task { [weak self] in
            await self?.performRecentProjectSessionsLoad(generation: generation)
            await MainActor.run { [weak self] in
                guard let self, self.recentProjectSessionsLoadGeneration == generation else { return }
                self.recentProjectSessionsLoadTask = nil
            }
        }
    }

    func resetRecentProjectSessionsForConnectionChange() {
        recentProjectSessionsLoadGeneration &+= 1
        recentProjectSessionsLoadTask?.cancel()
        recentProjectSessionsLoadTask = nil
        objectWillChange.send()
        sessionListStore.clearRecentSessions()
    }

    func openRecentProjectSession(_ recent: RecentProjectSession) async {
        let recentSession = recent.session
        let navigation = projectCoordinator.recentSessionNavigationResult(for: recentSession, projects: projects)
        pendingRecentSessionOpenID = navigation.shouldPreserveMissingSession ? recentSession.id : nil
        defer { pendingRecentSessionOpenID = nil }
        projects = navigation.projects
        currentProject = navigation.currentProject

        if selectedDirectory != navigation.routeDirectory || selectedSession?.id != recentSession.id {
            prepareDirectorySelection(navigation.routeDirectory)
            prepareSessionSelection(recentSession)
        }

        do {
            if let directory = recentSession.directory, !directory.isEmpty {
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
            return
        }

        let resolution = projectCoordinator.resolveRecentSessionAfterReload(
            recentSession: recentSession,
            matchingSession: session(matching: recentSession.id),
            allSessions: allSessions
        )
        guard let resolved = resolution.session else {
            errorMessage = String(localized: "Session is no longer available.")
            removeSessionPreview(for: recentSession.id)
            return
        }

        if resolution.shouldUpsertVisibleSession {
            upsertVisibleSession(resolved)
        }
        prepareSessionSelection(resolved)
        await selectSession(resolved)
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
        workspaceDisplayName(for: directory, in: currentProject)
    }

    func newSessionWorkspaceTitle(for selection: NewSessionWorkspaceSelection) -> String {
        switch selection {
        case .main:
            return workspaceDisplayName(for: currentProject?.worktree) ?? String(localized: "Main branch")
        case let .directory(directory):
            return workspaceDisplayName(for: directory) ?? URL(fileURLWithPath: directory).lastPathComponent
        case .createNew:
            return String(localized: "Create new worktree")
        }
    }

    func appendSandboxDirectory(_ directory: String, to project: OpenCodeProject) {
        let key = workspaceKey(directory)
        let existingSandboxes = project.sandboxes ?? []
        guard !existingSandboxes.contains(where: { workspaceKey($0) == key }) else { return }

        replaceSandboxDirectories(existingSandboxes + [directory], for: project)
    }

    func removeSandboxDirectory(_ directory: String, from project: OpenCodeProject) {
        let removedKey = workspaceKey(directory)
        let nextSandboxes = (project.sandboxes ?? []).filter { workspaceKey($0) != removedKey }

        replaceSandboxDirectories(nextSandboxes, for: project)
        sessionListStore.removeWorkspaceState(for: directory)
    }

    func refreshCurrentProjectWorktreesIfNeeded() async {
        guard let project = currentProject,
              project.id != "global",
              project.vcs == "git" else { return }

        do {
            let directories = try await client.listWorktrees(directory: project.worktree)
            replaceSandboxDirectories(directories, for: project)
        } catch {
            appendDebugLog("worktree list failed dir=\(project.worktree) error=\(error.localizedDescription)")
        }
    }

    private func replaceSandboxDirectories(_ directories: [String], for project: OpenCodeProject) {
        let rootKey = workspaceKey(project.worktree)
        var seen = Set<String>()
        let sandboxes = directories.compactMap { directory -> String? in
            let key = workspaceKey(directory)
            guard key != rootKey else { return nil }
            guard seen.insert(key).inserted else { return nil }
            return directory
        }

        let existingSandboxes = project.sandboxes ?? []
        guard existingSandboxes != sandboxes else { return }
        let nextKeys = Set(sandboxes.map(workspaceKey))
        for existing in existingSandboxes where !nextKeys.contains(workspaceKey(existing)) {
            sessionListStore.removeWorkspaceState(for: existing)
        }

        let updatedProject = OpenCodeProject(
            id: project.id,
            worktree: project.worktree,
            vcs: project.vcs,
            name: project.name,
            sandboxes: sandboxes,
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

    private func cachedProjectSessionSearchResults(for query: String) -> [RecentProjectSession] {
        sessionListStore.projectSessionSearchResults(
            projects: projects,
            previews: sessionPreviews,
            statuses: sessionStatuses,
            query: query
        )
    }

    private func projectSessionSearchDirectoriesToLoad() -> [String?] {
        var directories: [String?] = []
        var seen = Set<String>()

        func append(_ directory: String?) {
            let key = directory.map(workspaceKey) ?? "global"
            guard seen.insert(key).inserted else { return }
            directories.append(directory)
        }

        append(nil)

        for project in projects where project.id != "global" {
            append(project.worktree)
            for sandbox in project.sandboxes ?? [] {
                append(sandbox)
            }
        }

        return directories
    }

    private func projectPreferenceScopeKey(forDirectory directory: String?) -> String {
        [
            "server",
            config.recentServerID,
            directory ?? "global",
        ].joined(separator: "|")
    }

    func refreshSessionPreview(for sessionID: String, messages: [OpenCodeMessageEnvelope]) {
        setSessionPreview(buildSessionPreview(from: messages), for: sessionID)
    }

    func buildSessionPreview(from messages: [OpenCodeMessageEnvelope]) -> SessionPreview {
        guard let message = messages.last(where: { message in
            message.parts.contains { part in
                part.text?.contains(where: { !$0.isWhitespace }) == true
            }
        }) else {
            return SessionPreview(text: String(localized: "No messages yet"), date: nil)
        }

        let segments = message.parts.compactMap { part -> String? in
            guard let rawText = part.text else { return nil }
            let segment = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { return nil }
            return segment
        }
        let text = segments.joined(separator: "\n")
        let previewText = opencodePreviewText(text, limit: 120)

        let date = dateFromMilliseconds(message.info.time?.completed ?? message.info.time?.created)
        return SessionPreview(text: previewText ?? String(localized: "No preview available"), date: date)
    }

    func dateFromMilliseconds(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }
}
