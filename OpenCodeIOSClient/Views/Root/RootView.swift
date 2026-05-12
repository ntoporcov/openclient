import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    private var isShowingConnectionSheet: Binding<Bool> {
        Binding(
            get: { !viewModel.isConnected || viewModel.isUsingAppleIntelligence || viewModel.isShowingConnectionOverlay },
            set: { _ in }
        )
    }

    private var isShowingConnectionExperience: Bool {
        !viewModel.isConnected || viewModel.isShowingConnectionOverlay
    }

    var body: some View {
        ZStack {
            if isShowingConnectionExperience {
                ConnectionSheetBackdrop()
                    .transition(.opacity)
            }

            appShell
                .opacity(isShowingConnectionExperience ? 0 : 1)
        }
        .sheet(isPresented: isShowingConnectionSheet) {
            ConnectionSheetView(viewModel: viewModel)
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

    private var appShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            ProjectListView(viewModel: viewModel) {
                guard viewModel.currentProject != nil else { return }

                withAnimation(opencodeSelectionAnimation) {
                    columnVisibility = .doubleColumn
                    preferredCompactColumn = viewModel.selectedSession == nil ? .content : .detail
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
            } else if let session = viewModel.selectedSession, viewModel.isUsingAppleIntelligence == false {
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
    }

    private func showProjectSidebarIfNeeded() {
        guard viewModel.currentProject == nil else { return }

        columnVisibility = .all
        preferredCompactColumn = .sidebar
    }
}

private struct ConnectionSheetBackdrop: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.indigo.opacity(0.32),
                    Color.purple.opacity(0.22),
                    Color.cyan.opacity(0.18),
                    OpenCodePlatformColor.groupedBackground,
                ],
                startPoint: phase ? .topTrailing : .topLeading,
                endPoint: phase ? .bottomLeading : .bottomTrailing
            )

            movingBlob(color: .purple, size: 360, x: phase ? -150 : 120, y: phase ? -240 : -90)
            movingBlob(color: .cyan, size: 300, x: phase ? 180 : -130, y: phase ? 80 : 220)
            movingBlob(color: .orange, size: 260, x: phase ? -80 : 170, y: phase ? 260 : 120)
        }
        .ignoresSafeArea()
        .blur(radius: 18)
        .saturation(1.15)
        .onAppear {
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }

    private func movingBlob(color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(0.38), color.opacity(0.0)],
                    center: .center,
                    startRadius: 20,
                    endRadius: size * 0.5
                )
            )
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .blendMode(.plusLighter)
    }
}
