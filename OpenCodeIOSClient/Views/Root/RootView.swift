import SwiftUI

struct RootView<ChatDestination: View>: View {
    @ObservedObject var shell: AppShellFacade
    @ObservedObject var whatsNew: OpenClientWhatsNewStore
    let bridge: OpenClientBridgeFacade?
    let chatDestination: (String, Int) -> ChatDestination
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var didRunUITestAutoConnect = false
    @State private var isWaitingForAutomaticConnection = false
    @State private var didFinishAutomaticConnection = false

    init(
        shell: AppShellFacade,
        bridge: OpenClientBridgeFacade? = nil,
        whatsNew: OpenClientWhatsNewStore? = nil,
        @ViewBuilder chatDestination: @escaping (String, Int) -> ChatDestination
    ) {
        self.shell = shell
        self.bridge = bridge
        self.whatsNew = whatsNew ?? OpenClientWhatsNewStore(checksForUpdates: false)
        self.chatDestination = chatDestination
    }

    private var primarySheet: Binding<AppShellPrimarySheet?> {
        Binding(
            get: { shell.primarySheet },
            set: { sheet in
                guard sheet == nil else { return }
                shell.dismissPrimarySheet()
            }
        )
    }

    private var rootWhatsNewSheet: Binding<OpenClientReleaseNotes?> {
        Binding(
            get: {
                guard shell.primarySheet == nil,
                      !isWaitingForAutomaticConnection || didFinishAutomaticConnection else { return nil }
                return whatsNew.presentedRelease
            },
            set: { release in
                guard release == nil else { return }
                whatsNew.dismiss()
            }
        )
    }

    private var isShowingConnectionExperience: Bool {
        shell.hidesShellForConnectionExperience
    }

    private var shouldAutoFocusNewChatInput: Bool {
        #if DEBUG
        OpenClientScreenshotScene.current == nil
        #else
        true
        #endif
    }

    var body: some View {
        ZStack {
            if isShowingConnectionExperience {
                ConnectionSheetBackdrop()
                    .transition(.opacity)
            }

            appShell
                .opacity(isShowingConnectionExperience ? 0 : 1)

            if let message = shell.openURLNavigationMessage {
                RootDeepLinkProgressOverlay(message: message)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }

            if shell.talkSessions.isPresented {
                TalkSessionOverlay(coordinator: shell.talkSessions)
                    .zIndex(20)
            }
        }
        .sheet(item: primarySheet) { sheet in
            switch sheet {
            case .connection:
                ConnectionSheetView(
                    facade: shell.connection,
                    commerce: shell.commerce,
                    whatsNew: whatsNew
                )
            case let .newProjectChat(request):
                ProjectNewChatSheet(
                    viewModel: shell.newProjectChat,
                    request: request,
                    autoFocusInput: shouldAutoFocusNewChatInput
                ) {
                    withAnimation(opencodeSelectionAnimation) {
                        showDetailColumn()
                    }
                }
                .equatable()
            }
        }
        .sheet(item: rootWhatsNewSheet) { release in
            OpenClientWhatsNewView(
                release: release,
                connection: shell.connection,
                onDone: whatsNew.dismiss
            )
        }
        .sheet(item: Binding(
            get: { shell.commerce.paywallReason },
            set: { shell.commerce.paywallReason = $0 }
        )) { reason in
            OpenClientPaywallView(commerce: shell.commerce, reason: reason)
        }
        .animation(.snappy(duration: 0.34, extraBounce: 0.02), value: shell.isShowingConnectionOverlay)
        .onChange(of: shell.isConnected) { _, isConnected in
            if !isConnected {
                shell.talkSessions.stop()
            }
            withAnimation(opencodeSelectionAnimation) {
                showProjectSidebarIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            shell.talkSessions.applicationActivityChanged(isActive: phase == .active)
        }
        .onChange(of: shell.isShowingConnectionOverlay) { _, isShowing in
            guard !isShowing else { return }

            if isWaitingForAutomaticConnection {
                isWaitingForAutomaticConnection = false
                didFinishAutomaticConnection = true

                if shell.isConnected {
                    shell.selectAutomaticConnectionLandingDestination(
                        shell.connection.autoConnectLandingDestination
                    )
                    withAnimation(opencodeSelectionAnimation) {
                        showCurrentRoute()
                    }
                    return
                }
            }

            withAnimation(opencodeSelectionAnimation) {
                showProjectSidebarIfNeeded()
            }
        }
        .animation(opencodeSelectionAnimation, value: shell.hasActiveWorkspace)
        .task {
#if DEBUG
            if !didRunUITestAutoConnect,
               ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_AUTO_CONNECT"] == "1" {
                didRunUITestAutoConnect = true
                await Task.yield()
                shell.connection.startConnectionFromEditor()
                return
            }
#endif
            isWaitingForAutomaticConnection = shell.connection.startAutomaticConnectionIfConfigured()
        }
    }

    @ViewBuilder
    private var appShell: some View {
        BrowserRootContainer(
            browser: shell.browser,
            usesInspectorPresentation: usesBrowserInspector
        ) {
            splitShell
        }
    }

    private var usesBrowserInspector: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    private var splitShell: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredCompactColumn) {
            offlineBannerColumn(.sidebar) {
                ProjectListView(
                    facade: shell.projects,
                    connection: shell.connection,
                    configurations: shell.configurations,
                    games: shell.funAndGames,
                    bridge: bridge,
                    isActivitySelected: shell.isActivitySelected,
                    onActivityChosen: {
                        shell.selectActivity()
                        withAnimation(opencodeSelectionAnimation) {
                            columnVisibility = .doubleColumn
                            preferredCompactColumn = .content
                        }
                    }
                ) {
                    guard shell.hasCurrentProject else { return }
                    shell.selectProjectContent()

                    withAnimation(opencodeSelectionAnimation) {
                        showProjectContentOrDetail()
                    }
                }
                #if targetEnvironment(macCatalyst)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                #endif
            }
        } content: {
            offlineBannerColumn(.content) {
                switch shell.contentRoute(isCompact: horizontalSizeClass == .compact) {
                case .selectProject:
                    ContentUnavailableView("Select a Project", systemImage: "folder")
                case .loadingProject:
                    CompactRouteLoadingView(title: "Loading project...")
                case .projectContent:
                    ProjectContentView(shell: shell) {
                        withAnimation(opencodeSelectionAnimation) {
                            preferredCompactColumn = .detail
                        }
                    }
                case .activity:
                    ActivityView(facade: shell.activity, connection: shell.connection) {
                        withAnimation(opencodeSelectionAnimation) {
                            showDetailColumn()
                        }
                    }
                }
            }
        } detail: {
            BrowserInspectorContainer(
                browser: shell.browser,
                isEnabled: usesBrowserInspector
            ) {
                offlineBannerColumn(.detail) {
                    switch shell.detailRoute(isCompact: horizontalSizeClass == .compact) {
                    case .gitDiff:
                        GitDiffView(facade: shell.projectFiles)
                    case .gitFile:
                        ProjectFileContentView(facade: shell.projectFiles)
                    case .mcp:
                        ContentUnavailableView("MCP Servers", systemImage: "server.rack", description: Text("Toggle servers from the MCP tab."))
                    case let .terminal(id):
                        TerminalDetailView(facade: shell.terminal, terminalID: id)
                            .id(id)
                    case .selectTerminal:
                        ContentUnavailableView("Select a Terminal", systemImage: "terminal", description: Text("Choose a terminal session from the list."))
                    case let .loadingChat(sessionID):
                        CompactRouteLoadingView(title: "Loading chat...")
                            .id(sessionID)
                    case let .chat(route):
                        ChatRouteView(route: route, destination: chatDestination)
                            .equatable()
                    case .selectSession:
                        ContentUnavailableView("Select a Session", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
        }
        .onChange(of: shell.selectedSessionID) { _, sessionID in
            if sessionID != nil {
                guard shell.isSelectedSessionPrepared else { return }
                withAnimation(opencodeSelectionAnimation) {
                    showDetailColumn()
                }
                return
            }

            guard shell.hasCurrentProject else {
                withAnimation(opencodeSelectionAnimation) {
                    columnVisibility = .all
                    preferredCompactColumn = .sidebar
                }
                return
            }

            withAnimation(opencodeSelectionAnimation) {
                columnVisibility = .doubleColumn
                preferredCompactColumn = .content
            }
        }
        .onChange(of: shell.currentProjectID) { _, projectID in
            withAnimation(opencodeSelectionAnimation) {
                if projectID == nil {
                    showProjectSidebarIfNeeded()
                } else {
                    showProjectContentOrDetail()
                }
            }
        }
        .onChange(of: shell.chatDetailPresentationRequest) { _, _ in
            guard shell.selectedSessionID != nil else { return }
            withAnimation(opencodeSelectionAnimation) {
                showDetailColumn()
            }
        }
        .onAppear {
            showCurrentRoute()
        }
    }

    private func offlineBannerColumn<Content: View>(
        _ column: NavigationSplitViewColumn,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .top, spacing: 0) {
                if shell.isBrowsingLocalCache,
                   !shell.isShowingConnectionOverlay,
                   preferredCompactColumn == column {
                    CachedServerBanner {
                        shell.retryCachedServerConnection()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    private func showCurrentRoute() {
        if shell.isActivitySelected {
            columnVisibility = .doubleColumn
            preferredCompactColumn = .content
            return
        }

        if shell.selectedSessionID != nil {
            showDetailColumn()
            return
        }

        guard shell.hasCurrentProject else {
            showProjectSidebarIfNeeded()
            return
        }

        showProjectContentOrDetail()
    }

    private func showProjectSidebarIfNeeded() {
        guard !shell.hasCurrentProject, shell.selectedSessionID == nil else { return }

        columnVisibility = .all
        preferredCompactColumn = .sidebar
    }

    private func showProjectContentOrDetail() {
        if shell.selectedSessionID == nil {
            columnVisibility = .doubleColumn
            preferredCompactColumn = .content
        } else {
            showDetailColumn()
        }
    }

    private func showDetailColumn() {
        columnVisibility = horizontalSizeClass == .compact ? .detailOnly : .doubleColumn
        preferredCompactColumn = .detail
    }
}

private struct CachedServerBanner: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Browsing downloaded chats")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Button(action: retry) {
                Text("Retry")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("cache.retry")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.primary.opacity(0.1), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cache.offline-banner")
    }
}

private struct ChatRouteView<Destination: View>: View, Equatable {
    let route: AppShellChatRoute
    let destination: (String, Int) -> Destination

    nonisolated static func == (lhs: ChatRouteView, rhs: ChatRouteView) -> Bool {
        lhs.route == rhs.route
    }

    var body: some View {
        destination(route.sessionID, route.presentationRequest)
            .id(route.sessionID)
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

private struct RootDeepLinkProgressOverlay: View {
    let message: String

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(.top, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityLabel(message)
    }
}

private struct CompactRouteLoadingView: View {
    let title: LocalizedStringResource
    @State private var showsIndicator = false

    var body: some View {
        ZStack {
            OpenCodePlatformColor.groupedBackground
                .ignoresSafeArea()

            if showsIndicator {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(title)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                showsIndicator = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}
