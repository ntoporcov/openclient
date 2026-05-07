import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        ZStack {
            Group {
                if viewModel.isConnected {
                    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
                        ProjectListView(viewModel: viewModel) {
                            guard viewModel.currentProject != nil else { return }

                            withAnimation(opencodeSelectionAnimation) {
                                columnVisibility = .doubleColumn
                                preferredCompactColumn = .content
                            }
                        }
                    } content: {
                        if viewModel.currentProject == nil {
                            ContentUnavailableView("Select a Project", systemImage: "folder")
                        } else {
                            ProjectContentView(viewModel: viewModel) {
                                withAnimation(opencodeSelectionAnimation) {
                                    preferredCompactColumn = .detail
                                }
                            }
                        }
                    } detail: {
                        if viewModel.selectedProjectContentTab == .git, viewModel.hasGitProject {
                            if viewModel.selectedProjectFileIsChanged {
                                GitDiffView(viewModel: viewModel)
                            } else {
                                ProjectFileContentView(viewModel: viewModel)
                            }
                        } else if viewModel.selectedProjectContentTab == .mcp {
                            ContentUnavailableView("MCP Servers", systemImage: "server.rack", description: Text("Toggle servers from the MCP tab."))
                        } else if let session = viewModel.selectedSession {
                            ChatView(viewModel: viewModel, sessionID: session.id)
                                .id(session.id)
                        } else {
                            ContentUnavailableView("Select a Session", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    .onChange(of: viewModel.selectedSession?.id) { _, sessionID in
                        guard viewModel.currentProject != nil else {
                            withAnimation(opencodeSelectionAnimation) {
                                columnVisibility = .all
                                preferredCompactColumn = .sidebar
                            }
                            return
                        }

                        if sessionID == nil {
                            withAnimation(opencodeSelectionAnimation) {
                                preferredCompactColumn = .content
                            }
                        } else {
                            withAnimation(opencodeSelectionAnimation) {
                                preferredCompactColumn = .detail
                            }
                        }
                    }
                    .onChange(of: viewModel.currentProject?.id) { _, projectID in
                        withAnimation(opencodeSelectionAnimation) {
                            if projectID == nil {
                                showProjectSidebarIfNeeded()
                            } else {
                                columnVisibility = .doubleColumn
                                preferredCompactColumn = .content
                            }
                        }
                    }
                    .onAppear {
                        showProjectSidebarIfNeeded()
                    }
                    .animation(opencodeSelectionAnimation, value: viewModel.selectedSession?.id)
                } else if viewModel.isUsingAppleIntelligence, let session = viewModel.selectedSession {
                    NavigationStack {
                        ChatView(viewModel: viewModel, sessionID: session.id)
                            .id(session.id)
                    }
                } else {
                    NavigationStack {
                        ConnectionView(viewModel: viewModel)
                    }
                }
            }

            if viewModel.isShowingConnectionOverlay {
                ConnectingServerView(
                    config: viewModel.config,
                    phase: viewModel.connectionPhase,
                    cancel: { viewModel.cancelConnectionAttempt() },
                    retry: { viewModel.startConnection() },
                    edit: { viewModel.cancelConnectionAttempt() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .sheet(item: $viewModel.paywallReason) { reason in
            OpenClientPaywallView(viewModel: viewModel, purchaseManager: viewModel.purchaseManager, reason: reason)
        }
        .animation(.snappy(duration: 0.34, extraBounce: 0.02), value: viewModel.isShowingConnectionOverlay)
        .onChange(of: viewModel.isConnected) { _, _ in
            withAnimation(opencodeSelectionAnimation) {
                showProjectSidebarIfNeeded()
            }
        }
        .onChange(of: viewModel.isShowingConnectionOverlay) { _, isShowing in
            guard !isShowing else { return }

            withAnimation(opencodeSelectionAnimation) {
                showProjectSidebarIfNeeded()
            }
        }
        .animation(opencodeSelectionAnimation, value: viewModel.hasActiveWorkspace)
    }

    private func showProjectSidebarIfNeeded() {
        guard viewModel.currentProject == nil else { return }

        columnVisibility = .all
        preferredCompactColumn = .sidebar
    }
}
