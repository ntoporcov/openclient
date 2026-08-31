import Combine
import Foundation
import SwiftUI

enum AppShellPrimarySheet: Identifiable, Equatable {
    case connection
    case newProjectChat(NewProjectChatSheetRequest)

    var id: String {
        switch self {
        case .connection:
            return "connection"
        case let .newProjectChat(request):
            return "newProjectChat-\(request.id.uuidString)"
        }
    }

    static func == (lhs: AppShellPrimarySheet, rhs: AppShellPrimarySheet) -> Bool {
        switch (lhs, rhs) {
        case (.connection, .connection):
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
            selectedTab != .sessions || !usesNativeComposeTab
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
        browser = BrowserStore(projectID: viewModel.projectStore.currentProject?.id)

        Publishers.MergeMany([
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
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
            viewModel.$isShowingProjectSettingsSheet.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$openURLNavigationMessage.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$chatDetailPresentationRequest.map { _ in () }.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        viewModel.projectStore.$currentProject
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak browser] projectID in
                browser?.selectProject(projectID)
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
    var currentProjectID: String? { projects.currentProject?.id }
    var hasCurrentProject: Bool { projects.currentProject != nil }
    var selectedSessionID: String? { viewModel.directoryStoreRegistry.activeStore.selectedSession?.id }
    var isSelectedSessionPrepared: Bool {
        guard let selectedSessionID else { return false }
        return viewModel.chatStore.preparedSessionID == selectedSessionID
    }
    var chatDetailPresentationRequest: Int { viewModel.chatDetailPresentationRequest }
    var isActivitySelected: Bool { contentSelection == .activity }

    var projectContentSnapshot: ProjectContentSnapshot {
        let files = projectFiles.snapshot
        let selectedTab: OpenClientProjectContentTab = connection.isBrowsingLocalCache
            ? .sessions
            : viewModel.projectStore.selectedContentTab
        let isTerminalAvailable = supportsTerminal
            && connection.isConnected
            && !connection.isUsingAppleIntelligence
            && viewModel.effectiveSelectedDirectory != nil
        let scopeTitle = viewModel.projectScopeTitle
        return ProjectContentSnapshot(
            selectedTab: selectedTab,
            availableTabs: OpenClientProjectContentTab.allCases.filter { tab in
                switch tab {
                case .git:
                    return !connection.isBrowsingLocalCache && projectFiles.hasGitProject
                case .terminal:
                    return isTerminalAvailable
                case .mcp:
                    return !connection.isBrowsingLocalCache
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
            isReadOnly: connection.isBrowsingLocalCache,
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
        if contentSelection == .activity { return .activity }
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
        if viewModel.chatStore.preparedSessionID != session.id {
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
            selectActivity()
        }
    }

    func dismissPrimarySheet() {
        guard viewModel.newProjectChatSheetRequest != nil else { return }
        projects.dismissNewChat()
    }

    func setProjectSettingsPresented(_ isPresented: Bool) {
        projects.isShowingProjectSettingsSheet = isPresented
    }

    func presentProjectSettings() {
        guard !connection.isBrowsingLocalCache else { return }
        projects.presentSettings()
    }

    func retryCachedServerConnection() {
        connection.retryCachedServerConnection()
    }

    func selectProjectContentTab(_ tab: OpenClientProjectContentTab) {
        guard !connection.isBrowsingLocalCache || tab == .sessions else { return }
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
        if connection.isBrowsingLocalCache {
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
        guard !connection.isBrowsingLocalCache else { return }
        viewModel.presentNewProjectChatSheet(
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            locksProject: locksProject
        )
    }

    func presentNewChatForCurrentContext() {
        presentNewChat(
            projectID: viewModel.currentProject?.id,
            workspaceDirectory: viewModel.effectiveSelectedDirectory,
            locksProject: true
        )
    }

    func presentNewTalkForCurrentContext() {
        guard !connection.isBrowsingLocalCache, let project = viewModel.currentProject else { return }
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
        switch viewModel.selectedProjectContentTab {
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
