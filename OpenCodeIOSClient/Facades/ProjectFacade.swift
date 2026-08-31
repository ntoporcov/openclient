import Combine
import Foundation

@MainActor
final class ProjectFacade: ObservableObject {
    struct ListSnapshot: Equatable {
        let allProjects: [OpenCodeProject]
        let projects: [OpenCodeProject]
        let currentProjectID: String?
        let selectedDirectory: String?
        let recentSessions: [RecentProjectSession]
        let isLoadingRecentSessions: Bool
        let searchQuery: String
        let searchResults: [RecentProjectSession]
        let isSearching: Bool
        let recentLoadKey: String

        var isShowingSearchResults: Bool {
            !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct CreateProjectSnapshot: Equatable {
        let defaultSearchRoot: String
        let results: [String]
        let selectedDirectory: String?
        let isLoading: Bool
    }

    struct ActionSnapshot: Identifiable, Equatable {
        let action: OpenCodeAction
        let command: OpenCodeCommand?
        let phase: OpenCodeActionRunPhase?

        var id: UUID { action.id }
    }

    struct SettingsSnapshot: Equatable {
        let isLiveActivityAutoStartEnabled: Bool
        let sessionCardStyle: SessionCardStyle
        let showsActivityLastUserMessage: Bool
        let hasProUnlock: Bool
        let isProjectWorkspacesEnabled: Bool
        let hasGitProject: Bool
        let actions: [ActionSnapshot]
        let eligibleCommands: [OpenCodeCommand]

        var addableCommands: [OpenCodeCommand] {
            let configuredNames = Set(actions.map(\.action.commandName))
            return eligibleCommands.filter { !configuredNames.contains($0.name) }
        }
    }

    struct SelectionTicket {
        fileprivate let project: OpenCodeProject
        fileprivate let previousSessionID: String?
    }

    @Published private(set) var preparingProjectID: String?
    private var projectSelectionGeneration = 0

    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []
    private var activeDirectoryObservations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        Publishers.MergeMany([
            viewModel.projectStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.projectPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.sessionListStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.commerceFacade.objectWillChange.eraseToAnyPublisher(),
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.appCustomizationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.$config.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingProjectSettingsSheet.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        bindActiveDirectoryStore(viewModel.directoryStoreRegistry.activeStore)
        viewModel.directoryStoreRegistry.$activeStore
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] store in
                self?.bindActiveDirectoryStore(store)
                self?.objectWillChange.send()
            }
            .store(in: &observations)
    }

    var listSnapshot: ListSnapshot {
        let scopeKey = viewModel.config.recentServerID
        let allProjects = viewModel.projectStore.orderedProjects(scopeKey: scopeKey)
        let visibleProjects = viewModel.projectStore.visibleProjects(scopeKey: scopeKey)
        let projectIDs = allProjects.map(\.id).sorted().joined(separator: "|")
        return ListSnapshot(
            allProjects: allProjects,
            projects: visibleProjects,
            currentProjectID: viewModel.currentProject?.id,
            selectedDirectory: viewModel.selectedDirectory,
            recentSessions: viewModel.recentProjectSessions,
            isLoadingRecentSessions: viewModel.isLoadingRecentProjectSessions,
            searchQuery: viewModel.projectSessionSearchQuery,
            searchResults: viewModel.projectSessionSearchResults,
            isSearching: viewModel.isSearchingProjectSessions,
            recentLoadKey: [
                viewModel.config.recentServerID,
                viewModel.isConnected ? "connected" : "disconnected",
                viewModel.showsRecentSessionsInProjectList ? "recent-on" : "recent-off",
                projectIDs,
            ].joined(separator: "|")
        )
    }

    var createProjectSnapshot: CreateProjectSnapshot {
        CreateProjectSnapshot(
            defaultSearchRoot: viewModel.defaultSearchRoot,
            results: viewModel.createProjectResults,
            selectedDirectory: viewModel.createProjectSelectedDirectory,
            isLoading: viewModel.isLoading
        )
    }

    var settingsSnapshot: SettingsSnapshot {
        SettingsSnapshot(
            isLiveActivityAutoStartEnabled: viewModel.isLiveActivityAutoStartEnabled,
            sessionCardStyle: viewModel.appCustomizationStore.sessionCardStyle,
            showsActivityLastUserMessage: viewModel.appCustomizationStore.showsActivityLastUserMessage,
            hasProUnlock: viewModel.hasProUnlock,
            isProjectWorkspacesEnabled: viewModel.isProjectWorkspacesEnabled,
            hasGitProject: viewModel.hasGitProject,
            actions: viewModel.currentProjectActions.map {
                ActionSnapshot(
                    action: $0,
                    command: viewModel.actionCommand(for: $0),
                    phase: viewModel.actionRunPhase(for: $0)
                )
            },
            eligibleCommands: viewModel.actionEligibleCommands
        )
    }

    var projects: [OpenCodeProject] { viewModel.projects }
    var isReadOnly: Bool { viewModel.isBrowsingLocalCache }
    var currentProject: OpenCodeProject? { viewModel.currentProject }
    var isLoading: Bool { viewModel.isLoading }
    var paywallReason: OpenClientPaywallReason? { viewModel.commerceFacade.paywallReason }
    var selectableAgents: [OpenCodeAgent] { viewModel.selectableAgents }
    var sortedProviders: [OpenCodeProvider] { viewModel.sortedProviders }
    var newSessionDefaults: NewSessionDefaults { viewModel.newSessionDefaults }

    var projectSessionSearchQuery: String {
        get { viewModel.projectSessionSearchQuery }
        set { viewModel.projectSessionSearchQuery = newValue }
    }

    var createProjectQuery: String {
        get { viewModel.createProjectQuery }
        set { viewModel.createProjectQuery = newValue }
    }

    var isShowingCreateProjectSheet: Bool {
        get { viewModel.isShowingCreateProjectSheet }
        set { viewModel.isShowingCreateProjectSheet = newValue }
    }

    var isShowingProjectSettingsSheet: Bool {
        get { viewModel.isShowingProjectSettingsSheet }
        set { viewModel.isShowingProjectSettingsSheet = newValue }
    }

    func isSelected(_ project: OpenCodeProject) -> Bool { viewModel.isProjectSelected(project) }
    func isVisible(_ project: OpenCodeProject) -> Bool {
        viewModel.projectStore.isProjectVisible(project, scopeKey: viewModel.config.recentServerID)
    }

    func setVisibility(_ isVisible: Bool, for project: OpenCodeProject) {
        viewModel.projectStore.setProjectVisibility(project, isVisible: isVisible, scopeKey: viewModel.config.recentServerID)
    }

    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) {
        viewModel.projectStore.moveProjects(
            fromOffsets: source,
            toOffset: destination,
            scopeKey: viewModel.config.recentServerID
        )
    }

    func canEditPreferences(for project: OpenCodeProject) -> Bool {
        !isReadOnly && viewModel.canEditProjectPreferences(project)
    }

    func beginSelection(_ project: OpenCodeProject) -> SelectionTicket {
        SelectionTicket(project: project, previousSessionID: viewModel.beginProjectNavigation(project))
    }

    func prepareSelectionForNavigation(_ project: OpenCodeProject) async -> SelectionTicket? {
        projectSelectionGeneration &+= 1
        let generation = projectSelectionGeneration
        let progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, self?.projectSelectionGeneration == generation else { return }
            self?.preparingProjectID = project.id
        }
        let previousSessionID = await viewModel.prepareProjectNavigation(project)
        progressTask.cancel()
        guard projectSelectionGeneration == generation,
              viewModel.currentProject?.id == project.id else { return nil }
        preparingProjectID = nil
        return SelectionTicket(project: project, previousSessionID: previousSessionID)
    }

    func completeSelection(_ ticket: SelectionTicket) async {
        await Task.yield()
        guard viewModel.currentProject?.id == ticket.project.id else { return }
        await viewModel.selectProject(
            ticket.project,
            preservingDraftForSessionID: ticket.previousSessionID,
            animatesPreparation: false,
            isPreparedForNavigation: true
        )
    }

    func isPreparingSelection(_ project: OpenCodeProject) -> Bool {
        preparingProjectID == project.id
    }

    func refreshList() async { await viewModel.refreshProjectList() }
    func loadRecentSessions() async { await viewModel.loadRecentProjectSessionsAcrossProjects() }
    func searchSessions() async { await viewModel.searchProjectSessionsAcrossProjects() }

    func prepareRecentSessionSelection(_ recent: RecentProjectSession) {
        viewModel.prepareRecentProjectSessionSelection(recent)
    }

    func openRecentSession(_ recent: RecentProjectSession) async { await viewModel.openRecentProjectSession(recent) }

    func presentCreateProject() {
        guard !isReadOnly else { return }
        viewModel.presentCreateProjectSheet()
    }
    func dismissCreateProject() { viewModel.isShowingCreateProjectSheet = false }
    func searchCreateProjectDirectories() async {
        guard !isReadOnly else { return }
        await viewModel.searchCreateProjectDirectories()
    }
    func selectCreateProjectDirectory(_ directory: String) async {
        guard !isReadOnly else { return }
        await viewModel.selectCreateProjectDirectory(directory)
    }
    func createProjectResultPath(_ directory: String) -> String { viewModel.createProjectResultPath(directory) }
    func createProject(from directory: String) async {
        guard !isReadOnly else { return }
        await viewModel.createProject(from: directory)
    }

    func presentNewChat() {
        guard !isReadOnly else { return }
        viewModel.presentNewProjectChatSheet()
    }
    func presentNewTalk() {
        guard !isReadOnly else { return }
        viewModel.talkSessionCoordinator.presentProjectSelection()
    }
    func dismissNewChat() { viewModel.dismissNewProjectChatSheet() }

    func presentSettings() {
        guard !isReadOnly else { return }
        viewModel.presentProjectSettingsSheet()
    }
    func dismissSettings() { viewModel.isShowingProjectSettingsSheet = false }
    func setLiveActivityAutoStartEnabled(_ isEnabled: Bool) { viewModel.setLiveActivityAutoStartEnabled(isEnabled) }
    func setSessionCardStyle(_ style: SessionCardStyle) {
        viewModel.appCustomizationStore.setSessionCardStyle(style)
        objectWillChange.send()
    }
    func setShowsActivityLastUserMessage(_ shows: Bool) {
        viewModel.appCustomizationStore.setShowsActivityLastUserMessage(shows)
        objectWillChange.send()
    }

    func setWorkspacesEnabled(_ isEnabled: Bool) async {
        guard !isReadOnly else { return }
        viewModel.setProjectWorkspacesEnabled(isEnabled)
        if isEnabled {
            await viewModel.loadWorkspaceSessionsIfNeeded()
        }
    }

    func addAction(commandName: String, iconName: String) {
        viewModel.addProjectAction(commandName: commandName, iconName: iconName)
    }

    func removeAction(_ action: OpenCodeAction) { viewModel.removeProjectAction(action) }
    func updateActionIcon(actionID: UUID, iconName: String) {
        viewModel.updateProjectActionIcon(actionID: actionID, iconName: iconName)
    }
    func moveActions(from offsets: IndexSet, to destination: Int) {
        viewModel.moveProjectActions(fromOffsets: offsets, toOffset: destination)
    }
    func presentActionsPaywall() { viewModel.commerceFacade.presentPaywall(reason: .actions) }

    func setColor(_ color: String, for project: OpenCodeProject) async {
        guard !isReadOnly else { return }
        await viewModel.setProjectColor(color, for: project)
    }

    func setImageOverride(_ dataURL: String?, for project: OpenCodeProject) async {
        guard !isReadOnly else { return }
        await viewModel.setProjectImageOverride(dataURL, for: project)
    }

    func discoverImageCandidates(for project: OpenCodeProject) async -> [ProjectImageCandidate] {
        guard !isReadOnly else { return [] }
        return await viewModel.discoverProjectImageCandidates(for: project)
    }

    func imageDataURL(for candidate: ProjectImageCandidate, project: OpenCodeProject) async -> String? {
        guard !isReadOnly else { return nil }
        return await viewModel.projectImageDataURL(for: candidate, project: project)
    }

    func visibleModels(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        viewModel.modelConfigurationStore.visibleModels(for: provider)
    }

    func formattedVariantTitle(_ variant: String) -> String { viewModel.formattedVariantTitle(variant) }
    func defaultModelReference() -> OpenCodeModelReference? { viewModel.defaultModelReference() }
    func newSessionDefaultModelReference() -> OpenCodeModelReference? { viewModel.newSessionDefaultModelReference() }
    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? { viewModel.model(for: reference) }
    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] { viewModel.reasoningVariants(for: reference) }
    func workspaceDirectories(for project: OpenCodeProject) -> [String] { viewModel.workspaceDirectories(for: project) }
    func isWorkspacesEnabled(for project: OpenCodeProject) -> Bool { viewModel.isProjectWorkspacesEnabled(for: project) }
    func workspaceKey(_ directory: String) -> String { viewModel.workspaceKey(directory) }
    func workspaceDisplayName(for directory: String?, in project: OpenCodeProject?) -> String? {
        viewModel.workspaceDisplayName(for: directory, in: project)
    }

    @discardableResult
    func startNewChat(
        title: String,
        prompt: String,
        agentMentions: [OpenCodeAgentMention],
        attachments: [OpenCodeComposerAttachment],
        messageID: String,
        partID: String,
        composerSelection: NewProjectChatComposerSelection,
        projectID: String,
        workspaceDirectory: String?,
        workspaceSelection: NewSessionWorkspaceSelection?,
        newWorkspaceName: String
    ) async -> Bool {
        await viewModel.startNewProjectChat(
            title: title,
            prompt: prompt,
            agentMentions: agentMentions,
            attachments: attachments,
            messageID: messageID,
            partID: partID,
            composerSelection: composerSelection,
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            workspaceSelection: workspaceSelection,
            newWorkspaceName: newWorkspaceName
        )
    }

    private func bindActiveDirectoryStore(_ store: DirectoryStore) {
        activeDirectoryObservations.removeAll()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &activeDirectoryObservations)
    }
}
