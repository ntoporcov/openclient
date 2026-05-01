import SwiftUI

struct ProjectContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onDetailChosen: () -> Void

    var body: some View {
        rootContent
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(projectTitle)
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    viewModel.presentProjectSettingsSheet()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Project Settings")
                .accessibilityIdentifier("project.settings")
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button(action: toolbarAction) {
                    Image(systemName: toolbarIcon)
                }
                .accessibilityLabel(toolbarLabel)
                .accessibilityIdentifier(toolbarIdentifier)
                .disabled(toolbarDisabled)
            }
        }
        .onAppear {
            syncProjectTabIfNeeded()
        }
        .sheet(isPresented: $viewModel.isShowingProjectSettingsSheet) {
            ProjectSettingsSheet(viewModel: viewModel)
        }
        .onChange(of: viewModel.currentProject?.id) { _, _ in
            syncProjectTabIfNeeded()
        }
        .onChange(of: viewModel.selectedProjectContentTab) { _, tab in
            if tab == .git {
                viewModel.presentGitView()
            } else if tab == .mcp {
                viewModel.presentMCPView()
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesSystemTabView {
            tabContent
        } else {
            VStack(spacing: 0) {
                ProjectContentTabSelector(
                    selection: $viewModel.selectedProjectContentTab,
                    tabs: availableTabs
                )

                content
            }
        }
    }

    private var usesSystemTabView: Bool {
        horizontalSizeClass == .compact
    }

    private var tabContent: some View {
        TabView(selection: $viewModel.selectedProjectContentTab) {
            SessionListView(viewModel: viewModel, onSessionChosen: onDetailChosen)
                .tabItem {
                    Label(AppViewModel.ProjectContentTab.sessions.title, systemImage: "bubble.left.and.bubble.right")
                }
                .tag(AppViewModel.ProjectContentTab.sessions)

            if viewModel.hasGitProject {
                GitStatusView(viewModel: viewModel, onFileChosen: onDetailChosen)
                    .tabItem {
                        Label(AppViewModel.ProjectContentTab.git.title, systemImage: "doc.on.doc")
                    }
                    .tag(AppViewModel.ProjectContentTab.git)
            }

            MCPListView(viewModel: viewModel)
                .tabItem {
                    Label(AppViewModel.ProjectContentTab.mcp.title, systemImage: "server.rack")
                }
                .tag(AppViewModel.ProjectContentTab.mcp)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            SessionListView(viewModel: viewModel, onSessionChosen: onDetailChosen)
        case .git:
            if viewModel.hasGitProject {
                GitStatusView(viewModel: viewModel, onFileChosen: onDetailChosen)
            } else {
                SessionListView(viewModel: viewModel, onSessionChosen: onDetailChosen)
            }
        case .mcp:
            MCPListView(viewModel: viewModel)
        }
    }

    private var availableTabs: [AppViewModel.ProjectContentTab] {
        AppViewModel.ProjectContentTab.allCases.filter { tab in
            tab != .git || viewModel.hasGitProject
        }
    }

    private func syncProjectTabIfNeeded() {
        if !viewModel.hasGitProject, viewModel.selectedProjectContentTab == .git {
            viewModel.selectedProjectContentTab = .sessions
        }
    }

    private var projectTitle: String {
        viewModel.projectScopeTitle.split(separator: "/").last.map(String.init) ?? viewModel.projectScopeTitle
    }

    private var toolbarIcon: String {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            return "square.and.pencil"
        case .git:
            return "arrow.clockwise"
        case .mcp:
            return "arrow.clockwise"
        }
    }

    private var toolbarLabel: String {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            return "Create Session"
        case .git:
            return viewModel.projectFilesMode == .tree ? "Refresh File Tree" : "Refresh Files"
        case .mcp:
            return "Refresh MCP Servers"
        }
    }

    private var toolbarIdentifier: String {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            return "sessions.create"
        case .git:
            return "git.refresh"
        case .mcp:
            return "mcp.refresh"
        }
    }

    private var toolbarDisabled: Bool {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            return false
        case .git:
            return viewModel.directoryState.isLoadingVCS || viewModel.directoryState.isLoadingFileTree
        case .mcp:
            return viewModel.directoryState.isLoadingMCP
        }
    }

    private func toolbarAction() {
        switch viewModel.selectedProjectContentTab {
        case .sessions:
            viewModel.presentCreateSessionSheet()
        case .git:
            Task {
                if viewModel.projectFilesMode == .tree {
                    await viewModel.reloadGitViewData(force: true)
                    await viewModel.reloadFileTree(force: true)
                } else {
                    await viewModel.reloadGitViewData(force: true)
                }
            }
        case .mcp:
            Task {
                await viewModel.reloadMCPStatus()
            }
        }
    }
}

struct ProjectContentTabSelector: View {
    @Binding var selection: AppViewModel.ProjectContentTab
    let tabs: [AppViewModel.ProjectContentTab]

    var body: some View {
        Picker("Project Content", selection: $selection.animation(opencodeSelectionAnimation)) {
            ForEach(tabs, id: \.self) { tab in
                Label(tab.title, systemImage: systemImage(for: tab))
                    .labelStyle(.titleAndIcon)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func systemImage(for tab: AppViewModel.ProjectContentTab) -> String {
        switch tab {
        case .sessions:
            return "bubble.left.and.bubble.right"
        case .git:
            return "doc.on.doc"
        case .mcp:
            return "server.rack"
        }
    }
}
