import SwiftUI

struct ProjectContentView: View {
    @ObservedObject var viewModel: AppViewModel
    let onDetailChosen: () -> Void

    var body: some View {
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
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(projectTitle)
        .opencodeInlineNavigationTitle()
        .toolbar {
            if viewModel.selectedProjectContentTab == .sessions {
                ToolbarItem(placement: .opencodeTrailing) {
                    SessionLiveActivityMenu(viewModel: viewModel)
                }
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
