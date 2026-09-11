import Combine
import Foundation
import SwiftUI

enum AppShellPrimarySheet: Identifiable, Equatable {
    case connection
    case createSession
    case newProjectChat(NewProjectChatSheetRequest)

    var id: String {
        switch self {
        case .connection:
            return "connection"
        case .createSession:
            return "createSession"
        case let .newProjectChat(request):
            return "newProjectChat-\(request.id.uuidString)"
        }
    }

    static func == (lhs: AppShellPrimarySheet, rhs: AppShellPrimarySheet) -> Bool {
        switch (lhs, rhs) {
        case (.connection, .connection):
            return true
        case (.createSession, .createSession):
            return true
        case let (.newProjectChat(lhsRequest), .newProjectChat(rhsRequest)):
            return lhsRequest.id == rhsRequest.id
        default:
            return false
        }
    }
}

enum AppShellContentRoute: Equatable {
    case selectProject
    case loadingProject
    case projectContent
    case activity
}

enum AppShellContentSelection: Equatable {
    case project
    case activity
}

struct AppShellChatRoute: Equatable {
    let sessionID: String
    let presentationRequest: Int
}

enum AppShellDetailRoute: Equatable {
    case gitFile
    case gitDiff
    case mcp
    case terminal(id: String)
    case selectTerminal
    case loadingChat(sessionID: String)
    case chat(AppShellChatRoute)
    case selectSession
}

@MainActor
final class AppShellFacade: ObservableObject {
    var globalForms: GlobalFormsFacade { viewModel.globalFormsFacade }
    var globalFormLocation: BackendFormLocation? {
        if case .chat = detailRoute(isCompact: false), let session = viewModel.selectedSession, let directory = session.directory {
            return .init(directory: directory, workspaceID: session.workspaceID)
        }
        if let project = viewModel.currentProject {
            let scope = viewModel.projectExecutionScope(for: project, directory: viewModel.effectiveSelectedDirectory)
            return scope.directory.map { .init(directory: $0, workspaceID: scope.workspaceID) }
        }
        return nil
    }
    struct ProjectContentSnapshot: Equatable {
        let selectedTab: OpenClientProjectContentTab
        let availableTabs: [OpenClientProjectContentTab]
        let title: String
        let isShowingSettings: Bool
        let hasGitProject: Bool
        let filesMode: OpenCodeProjectFilesMode
        let isLoadingVCS: Bool
        let isLoadingFileTree: Bool
        let isLoadingMCP: Bool
        let isTerminalAvailable: Bool
        let isReadOnly: Bool
        let allowsSessionCreation: Bool
        let currentProjectID: String?
        let effectiveSelectedDirectory: String?

        var toolbarIcon: String {
            switch selectedTab {
            case .sessions:
                return "square.and.pencil"
            case .git, .mcp:
                return "arrow.clockwise"
            case .terminal:
                return "plus"
            }
        }

        var toolbarLabel: String {
            switch selectedTab {
            case .sessions:
                return String(localized: "Create Session")
            case .git:
                return filesMode == .tree ? String(localized: "Refresh File Tree") : String(localized: "Refresh Files")
            case .mcp:
                return String(localized: "Refresh MCP Servers")
            case .terminal:
                return String(localized: "New Terminal")
            }
        }

        var toolbarIdentifier: String {
            switch selectedTab {
            case .sessions:
                return "sessions.create"
            case .git:
                return "git.refresh"
            case .mcp:
                return "mcp.refresh"
            case .terminal:
                return "terminal.create"
            }
        }

        var isToolbarDisabled: Bool {
            if selectedTab == .sessions { return !allowsSessionCreation }
            if isReadOnly { return true }
            switch selectedTab {
            case .sessions:
                return false
            case .git:
                return isLoadingVCS || isLoadingFileTree
            case .mcp:
                return isLoadingMCP
            case .terminal:
                return false
            }
        }

        func showsToolbarAction(usesNativeComposeTab: Bool) -> Bool {
            if selectedTab == .sessions {
                return allowsSessionCreation && !usesNativeComposeTab
            }
            if isReadOnly { return false }
            return selectedTab != .sessions || !usesNativeComposeTab
        }
    }

    let connection: ConnectionFacade
    let commerce: CommerceFacade
    let projects: ProjectFacade
    let newProjectChat: NewProjectChatFacade
    let sessions: SessionListFacade
    let activity: ActivityFacade
    let projectFiles: ProjectFilesFacade
    let mcp: MCPFacade
    let terminal: TerminalFacade
    let configurations: ConfigurationsFacade
    let funAndGames: FunAndGamesFacade
    let chat: ChatFacade
    let talkSessions: TalkSessionCoordinator
    let browser: BrowserStore

    private unowned let viewModel: AppViewModel
    @Published private(set) var contentSelection: AppShellContentSelection = .project
    private var observations: Set<AnyCancellable> = []
    private var activeDirectoryObservations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        connection = viewModel.connectionFacade
        commerce = viewModel.commerceFacade
        projects = viewModel.projectFacade
        newProjectChat = viewModel.newProjectChatFacade
        sessions = viewModel.sessionListFacade
        activity = viewModel.activityFacade
        projectFiles = viewModel.projectFilesFacade
        mcp = viewModel.mcpFacade
        terminal = viewModel.terminalFacade
        configurations = viewModel.configurationsFacade
        funAndGames = viewModel.funAndGamesFacade
        chat = viewModel.chatFacade
        talkSessions = viewModel.talkSessionCoordinator
        browser = BrowserStore()
        browser.selectContext(
            connectionID: viewModel.backendConnection?.id,
            projectID: viewModel.projectStore.currentProject?.id,
            directory: viewModel.effectiveSelectedDirectory
        )

        Publishers.MergeMany([
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.$backendConnection.map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectStore.objectWillChange.eraseToAnyPublisher(),
            commerce.objectWillChange.eraseToAnyPublisher(),
            projectFiles.objectWillChange.eraseToAnyPublisher(),
            mcp.objectWillChange.eraseToAnyPublisher(),
            terminal.objectWillChange.eraseToAnyPublisher(),
            browser.objectWillChange.eraseToAnyPublisher(),
            viewModel.chatStore.$preparedSessionID.map { _ in () }.eraseToAnyPublisher(),
            talkSessions.objectWillChange.eraseToAnyPublisher(),
            viewModel.$isShowingConnectionOverlay.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$newProjectChatSheetRequest.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingCreateSessionSheet.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingProjectSettingsSheet.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$openURLNavigationMessage.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$chatDetailPresentationRequest.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        var browserWasConnected = viewModel.connectionStore.isConnected
        Publishers.CombineLatest4(
            viewModel.projectStore.$currentProject
                .removeDuplicates { $0?.id == $1?.id && $0?.worktree == $1?.worktree },
            viewModel.projectStore.$selectedDirectory.removeDuplicates(),
            viewModel.$backendConnection.map { $0?.id }.removeDuplicates(),
            viewModel.connectionStore.$isConnected.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak browser] project, directory, connectionID, isConnected in
                guard let browser else { return }
                if browserWasConnected && !isConnected {
                    browser.clearAllBrowserSessions()
                }
                browserWasConnected = isConnected
                browser.selectContext(
                    connectionID: connectionID,
                    projectID: project?.id,
                    directory: directory.flatMap { $0.isEmpty ? nil : $0 }
                        ?? (project?.id == "global" ? nil : project?.worktree)
                )
            }
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

    var primarySheet: AppShellPrimarySheet? {
        if let request = viewModel.newProjectChatSheetRequest {
            return .newProjectChat(request)
        }
        if viewModel.isShowingCreateSessionSheet {
            return .createSession
        }
        if showsConnectionSheetContent {
            return .connection
        }
        return nil
    }

    var showsConnectionSheetContent: Bool {
        (!connection.isConnected && !connection.isBrowsingLocalCache)
            || connection.isUsingAppleIntelligence
            || connection.isShowingConnectionOverlay
    }

    var hidesShellForConnectionExperience: Bool {
        (!connection.isConnected && !connection.isBrowsingLocalCache) || connection.isShowingConnectionOverlay
    }

    var openURLNavigationMessage: String? { viewModel.openURLNavigationMessage }
    var isConnected: Bool { connection.isConnected }
    var isShowingConnectionOverlay: Bool { connection.isShowingConnectionOverlay }
    var hasActiveWorkspace: Bool { viewModel.hasActiveWorkspace }
    var isBrowsingLocalCache: Bool { connection.isBrowsingLocalCache }
    var isV2Connection: Bool { connection.isV2Connection }
    var v2NoticeConnectionID: UUID? {
        guard !hidesShellForConnectionExperience else { return nil }
        return connection.v2NoticeConnectionID
    }
    var allowsProjectCreation: Bool { projects.allowsProjectCreation }
    var allowsProjectBrowser: Bool { hasCurrentProject && !connection.isBrowsingLocalCache }
    var currentProjectID: String? { projects.currentProject?.id }
    var hasCurrentProject: Bool { projects.currentProject != nil }
    var selectedSessionID: String? { viewModel.directoryStoreRegistry.activeStore.selectedSession?.id }
    var isSelectedSessionPrepared: Bool {
        guard let selectedSessionID else { return false }
        return viewModel.chatStore.preparedSessionID == selectedSessionID
    }
    var canPresentSelectedSessionDetail: Bool {
        guard let selectedSessionID else { return false }
        return isSelectedSessionPrepared
            || viewModel.hasPresentableCachedV2Chat
            || (isV2Connection && viewModel.chatStore.isHydratingV2Transcript(sessionID: selectedSessionID))
    }
    var chatDetailPresentationRequest: Int { viewModel.chatDetailPresentationRequest }
    var isActivitySelected: Bool { contentSelection == .activity }

    var projectContentSnapshot: ProjectContentSnapshot {
        let files = projectFiles.snapshot
        let isReadOnly = connection.isBrowsingLocalCache
        let selectedTab: OpenClientProjectContentTab = isReadOnly
            ? .sessions
            : viewModel.projectStore.selectedContentTab
        let isTerminalAvailable = supportsTerminal
            && viewModel.compatibilityClient(for: .terminal) != nil
            && !isReadOnly
            && connection.isConnected
            && !connection.isUsingAppleIntelligence
            && viewModel.effectiveTerminalDirectory != nil
        let scopeTitle = viewModel.projectScopeTitle
        return ProjectContentSnapshot(
            selectedTab: selectedTab,
            availableTabs: OpenClientProjectContentTab.allCases.filter { tab in
                switch tab {
                case .git:
                    return !isReadOnly && projectFiles.hasGitProject
                case .terminal:
                    return isTerminalAvailable
                case .mcp:
                    return !isReadOnly && viewModel.compatibilityClient(for: .mcp) != nil
                case .sessions:
                    return true
                }
            },
            title: scopeTitle.split(separator: "/").last.map(String.init) ?? scopeTitle,
            isShowingSettings: projects.isShowingProjectSettingsSheet,
            hasGitProject: projectFiles.hasGitProject,
            filesMode: files.filesMode,
            isLoadingVCS: files.isLoadingVCS,
            isLoadingFileTree: files.isLoadingFileTree,
            isLoadingMCP: mcp.snapshot.isLoading,
            isTerminalAvailable: isTerminalAvailable,
            isReadOnly: isReadOnly,
            allowsSessionCreation: !connection.isBrowsingLocalCache,
            currentProjectID: projects.currentProject?.id,
            effectiveSelectedDirectory: viewModel.effectiveSelectedDirectory
        )
    }

    private var supportsTerminal: Bool {
#if targetEnvironment(macCatalyst)
        false
#else
        true
#endif
    }

    func contentRoute(isCompact: Bool) -> AppShellContentRoute {
        if contentSelection == .activity, activity.isAvailable { return .activity }
        guard projects.currentProject != nil else { return .selectProject }
        let directory = viewModel.directoryStoreRegistry.activeStore
        if isCompact, directory.isLoadingSessions, directory.sessions.isEmpty {
            return .loadingProject
        }
        return .projectContent
    }

    func detailRoute(isCompact: Bool) -> AppShellDetailRoute {
        let projectContent = projectContentSnapshot
        if contentSelection == .project, projectContent.selectedTab == .git, projectContent.hasGitProject {
            return projectFiles.snapshot.selectedFileIsChanged ? .gitDiff : .gitFile
        }
        if contentSelection == .project, projectContent.selectedTab == .mcp {
            return .mcp
        }
        if contentSelection == .project, projectContent.selectedTab == .terminal {
            guard let terminalID = terminal.snapshot.activeTerminalID else {
                return .selectTerminal
            }
            return .terminal(id: terminalID)
        }

        let directory = viewModel.directoryStoreRegistry.activeStore
        guard let session = directory.selectedSession, !connection.isUsingAppleIntelligence else {
            return .selectSession
        }
        if !canPresentSelectedSessionDetail {
            return .loadingChat(sessionID: session.id)
        }
        return .chat(
            AppShellChatRoute(
                sessionID: session.id,
                presentationRequest: viewModel.chatDetailPresentationRequest
            )
        )
    }

    func selectActivity() {
        guard activity.isAvailable else { return }
        contentSelection = .activity
    }

    func selectProjectContent() {
        contentSelection = .project
    }

    func selectAutomaticConnectionLandingDestination(_ destination: AutoConnectLandingDestination) {
        switch destination {
        case .projects:
            selectProjectContent()
        case .activity:
            if !activity.isAvailable {
                selectProjectContent()
            } else {
                selectActivity()
            }
        }
    }

    func dismissPrimarySheet() {
        if viewModel.newProjectChatSheetRequest != nil {
            projects.dismissNewChat()
            return
        }
        if viewModel.isShowingCreateSessionSheet {
            sessions.dismissCreateSession()
        }
    }

    func setProjectSettingsPresented(_ isPresented: Bool) {
        projects.isShowingProjectSettingsSheet = isPresented
    }

    func presentProjectSettings() {
        guard !projectContentSnapshot.isReadOnly else { return }
        projects.presentSettings()
    }

    func retryCachedServerConnection() {
        connection.retryCachedServerConnection()
    }

    func selectProjectContentTab(_ tab: OpenClientProjectContentTab) {
        guard projectContentSnapshot.availableTabs.contains(tab) else { return }
        if viewModel.selectedProjectContentTab == .terminal, tab != .terminal {
            terminal.detachRenderer()
        }
        switch tab {
        case .sessions:
            viewModel.selectedProjectContentTab = .sessions
        case .git:
            guard projectFiles.hasGitProject else { return }
            viewModel.preserveCurrentMessageDraftForNavigation()
            projectFiles.prepareForPresentation()
            withAnimation(opencodeSelectionAnimation) {
                viewModel.selectedProjectContentTab = .git
                viewModel.selectedSession = nil
            }

            Task { [projectFiles] in
                await projectFiles.loadGitViewDataIfNeeded()
                if projectFiles.snapshot.filesMode == .tree {
                    await projectFiles.loadFileTreeIfNeeded()
                }
            }
        case .mcp:
            viewModel.preserveCurrentMessageDraftForNavigation()
            withAnimation(opencodeSelectionAnimation) {
                viewModel.selectedProjectContentTab = .mcp
                viewModel.selectedSession = nil
            }

            Task { [mcp] in
                await mcp.loadIfNeeded()
            }
        case .terminal:
            guard projectContentSnapshot.isTerminalAvailable else { return }
            viewModel.preserveCurrentMessageDraftForNavigation()
            withAnimation(opencodeSelectionAnimation) {
                viewModel.selectedProjectContentTab = .terminal
                viewModel.selectedSession = nil
            }
            terminal.prepareForPresentation()
        }
    }

    func reconcileInvalidGitSelection() {
        if projectContentSnapshot.isReadOnly {
            terminal.detachRenderer()
            viewModel.selectedProjectContentTab = .sessions
            return
        }
        if !projectFiles.hasGitProject, viewModel.selectedProjectContentTab == .git {
            viewModel.selectedProjectContentTab = .sessions
        }
        if !projectContentSnapshot.isTerminalAvailable, viewModel.selectedProjectContentTab == .terminal {
            terminal.detachRenderer()
            viewModel.selectedProjectContentTab = .sessions
        }
    }

    func presentNewChat(
        projectID: String?,
        workspaceDirectory: String?,
        locksProject: Bool
    ) {
        guard projects.allowsNewChat else { return }
        viewModel.presentNewProjectChatSheet(
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            locksProject: locksProject
        )
    }

    func presentCreateProject() {
        guard allowsProjectCreation else { return }
        projects.presentCreateProject()
    }

    func presentNewChatForCurrentContext() {
        presentNewChat(
            projectID: viewModel.currentProject?.id,
            workspaceDirectory: viewModel.effectiveSelectedDirectory,
            locksProject: true
        )
    }

    func presentNewTalkForCurrentContext() {
        guard viewModel.projectFacade.allowsNewTalk, let project = viewModel.currentProject else { return }
        talkSessions.start(project: project, workspaceDirectory: viewModel.effectiveSelectedDirectory)
    }

    func presentPluginSetupChat() {
        viewModel.presentNewProjectChatSheet(
            projectID: "global",
            workspaceDirectory: nil,
            locksProject: true,
            initialContent: NewProjectChatInitialContent(
                text: OpenClientPluginSetup.prompt,
                attachments: []
            ),
            presentsAboveConnection: true
        )
    }

    func performProjectContentToolbarAction() {
        guard !projectContentSnapshot.isToolbarDisabled else { return }
        switch projectContentSnapshot.selectedTab {
        case .sessions:
            presentNewChatForCurrentContext()
        case .git:
            Task { [projectFiles] in
                await projectFiles.refresh()
            }
        case .mcp:
            Task { [mcp] in
                await mcp.reload()
            }
        case .terminal:
            terminal.createTerminal()
        }
    }

    func prepareOpenURLPresentation(_ url: URL) {
        viewModel.prepareOpenURLPresentation(url)
    }

    func handleOpenURL(_ url: URL) async {
        await viewModel.handleOpenURL(url)
    }

    func scheduleForegroundChatCatchUp(reason: String) {
        viewModel.scheduleForegroundChatCatchUp(reason: reason)
    }

    func applicationActivityChanged(isActive: Bool) {
        viewModel.applicationActivityChanged(isActive: isActive)
    }

    private func bindActiveDirectoryStore(_ store: DirectoryStore) {
        activeDirectoryObservations.removeAll()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &activeDirectoryObservations)
    }
}
