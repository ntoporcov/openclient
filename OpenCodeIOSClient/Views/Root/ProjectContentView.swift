import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ProjectContentView: View {
    @ObservedObject var shell: AppShellFacade
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let onDetailChosen: () -> Void

    private var snapshot: AppShellFacade.ProjectContentSnapshot {
        shell.projectContentSnapshot
    }

    private var selectedTab: Binding<OpenClientProjectContentTab> {
        Binding(
            get: { shell.projectContentSnapshot.selectedTab },
            set: { shell.selectProjectContentTab($0) }
        )
    }

    var body: some View {
        rootContent
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(projectTitle)
        .opencodeInlineNavigationTitle()
        .toolbar {
            if showsBrowserToolbarAction {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        if shell.browser.presentation == .closed {
                            shell.browser.openAddressBar()
                        } else {
                            shell.browser.expand()
                        }
                    } label: {
                        Image(systemName: "globe")
                    }
                    .accessibilityLabel("Open Browser")
                    .accessibilityIdentifier("browser.open")
                }
            }

            if !snapshot.isReadOnly {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        shell.presentProjectSettings()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Project Settings")
                    .accessibilityIdentifier("project.settings")
                }
            }

            if showsTopToolbarAction {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button(action: toolbarAction) {
                        Image(systemName: toolbarIcon)
                    }
                    .accessibilityLabel(Text(toolbarLabel))
                    .accessibilityIdentifier(toolbarIdentifier)
                    .disabled(toolbarDisabled)
                }
            }
        }
        .onAppear {
            syncProjectTabIfNeeded()
        }
        .sheet(isPresented: Binding(
            get: { shell.projectContentSnapshot.isShowingSettings },
            set: { shell.setProjectSettingsPresented($0) }
        )) {
            ProjectSettingsSheet(
                facade: shell.projects,
                connection: shell.connection
            )
        }
        .onChange(of: snapshot.currentProjectID) { _, _ in
            syncProjectTabIfNeeded()
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        if usesIPadGlassTabSwitcher {
            content
                .safeAreaInset(edge: .top, spacing: 0) {
                    ProjectContentModeMenu(
                        selection: selectedTab,
                        tabs: snapshot.availableTabs
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }
        } else if usesSystemTabView {
            tabContent
        } else {
            VStack(spacing: 0) {
                ProjectContentTabSelector(
                    selection: selectedTab,
                    tabs: snapshot.availableTabs
                )

                content
            }
        }
    }

    private var usesSystemTabView: Bool {
        return horizontalSizeClass == .compact
    }

    private var usesIPadGlassTabSwitcher: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .pad
#else
        false
#endif
    }

    @ViewBuilder
    private var tabContent: some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 18.0, *) {
            nativeRoleTabContent
        } else {
            legacyTabContent
        }
#else
        legacyTabContent
#endif
    }

    private var legacyTabContent: some View {
        TabView(selection: selectedTab) {
            sessionList
                .tabItem {
                    Label(projectTabTitle(.sessions), systemImage: OpenClientProjectContentTab.sessions.systemImage)
                }
                .tag(OpenClientProjectContentTab.sessions)

            if snapshot.availableTabs.contains(.git) {
                GitStatusView(facade: shell.projectFiles, onFileChosen: onDetailChosen)
                    .tabItem {
                        Label(projectTabTitle(.git), systemImage: OpenClientProjectContentTab.git.systemImage)
                    }
                    .tag(OpenClientProjectContentTab.git)
            }

            if snapshot.isTerminalAvailable {
                TerminalProjectView(facade: shell.terminal, onTerminalChosen: onDetailChosen)
                    .tabItem {
                        Label(projectTabTitle(.terminal), systemImage: OpenClientProjectContentTab.terminal.systemImage)
                    }
                    .tag(OpenClientProjectContentTab.terminal)
            }

            if snapshot.availableTabs.contains(.mcp) {
                MCPListView(facade: shell.mcp)
                    .tabItem {
                        Label(projectTabTitle(.mcp), systemImage: OpenClientProjectContentTab.mcp.systemImage)
                    }
                    .tag(OpenClientProjectContentTab.mcp)
            }
        }
    }

#if os(iOS) || targetEnvironment(macCatalyst)
    @available(iOS 18.0, *)
    private var nativeRoleTabContent: some View {
        nativeRoleTabView
            .opencodeProjectBrowserAccessory(
                browser: shell.browser,
                isEnabled: !usesIPadGlassTabSwitcher
            )
    }

    @available(iOS 18.0, *)
    private var nativeRoleTabView: some View {
        TabView(selection: nativeTabSelection) {
            Tab(
                projectTabTitle(.sessions),
                systemImage: OpenClientProjectContentTab.sessions.systemImage,
                value: ProjectNativeTab.sessions
            ) {
                sessionList
            }

            if snapshot.availableTabs.contains(.git) {
                Tab(
                    projectTabTitle(.git),
                    systemImage: OpenClientProjectContentTab.git.systemImage,
                    value: ProjectNativeTab.git
                ) {
                    GitStatusView(facade: shell.projectFiles, onFileChosen: onDetailChosen)
                }
            }


            if snapshot.isTerminalAvailable {
                Tab(
                    projectTabTitle(.terminal),
                    systemImage: OpenClientProjectContentTab.terminal.systemImage,
                    value: ProjectNativeTab.terminal
                ) {
                    TerminalProjectView(facade: shell.terminal, onTerminalChosen: onDetailChosen)
                }
            }

            if snapshot.availableTabs.contains(.mcp) {
                Tab(
                    projectTabTitle(.mcp),
                    systemImage: OpenClientProjectContentTab.mcp.systemImage,
                    value: ProjectNativeTab.mcp
                ) {
                    MCPListView(facade: shell.mcp)
                }
            }

        }
    }

    @available(iOS 18.0, *)
    private var nativeTabSelection: Binding<ProjectNativeTab> {
        Binding(
            get: { ProjectNativeTab(projectTab: snapshot.selectedTab) },
            set: { selection in
                if let projectTab = selection.projectTab {
                    shell.selectProjectContentTab(projectTab)
                }
            }
        )
    }
#endif

    private var showsTopToolbarAction: Bool {
        snapshot.selectedTab != .sessions
    }

    private var showsBrowserToolbarAction: Bool {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return true
        }
        #endif
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.selectedTab {
        case .sessions:
            sessionList
        case .git:
            if snapshot.hasGitProject {
                GitStatusView(facade: shell.projectFiles, onFileChosen: onDetailChosen)
            } else {
                sessionList
            }
        case .mcp:
            MCPListView(facade: shell.mcp)
        case .terminal:
            if snapshot.isTerminalAvailable {
                TerminalProjectView(facade: shell.terminal, onTerminalChosen: onDetailChosen)
            } else {
                sessionList
            }
        }
    }

    private func syncProjectTabIfNeeded() {
        shell.reconcileInvalidGitSelection()
    }

    private var projectTitle: String {
        snapshot.title
    }

    private var toolbarIcon: String {
        snapshot.toolbarIcon
    }

    private var toolbarLabel: LocalizedStringResource {
        switch snapshot.selectedTab {
        case .sessions: "Create Session"
        case .git: snapshot.filesMode == .tree ? "Refresh File Tree" : "Refresh Files"
        case .mcp: "Refresh MCP Servers"
        case .terminal: "New Terminal"
        }
    }

    private var toolbarIdentifier: String {
        snapshot.toolbarIdentifier
    }

    private var toolbarDisabled: Bool {
        snapshot.isToolbarDisabled
    }

    private func toolbarAction() {
        shell.performProjectContentToolbarAction()
    }

    private var sessionList: some View {
        SessionListView(
            facade: shell.sessions,
            onSessionChosen: onDetailChosen,
            onNewChat: shell.presentNewChatForCurrentContext,
            onNewTalk: shell.presentNewTalkForCurrentContext
        )
    }
}

struct ProjectContentTabSelector: View {
    @Binding var selection: OpenClientProjectContentTab
    let tabs: [OpenClientProjectContentTab]

    var body: some View {
        Picker("Project Content", selection: $selection.animation(opencodeSelectionAnimation)) {
            ForEach(tabs, id: \.self) { tab in
                Label(projectTabTitle(tab), systemImage: systemImage(for: tab))
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

    private func systemImage(for tab: OpenClientProjectContentTab) -> String {
        tab.systemImage
    }
}

private struct ProjectContentModeMenu: View {
    @Binding var selection: OpenClientProjectContentTab
    let tabs: [OpenClientProjectContentTab]

    var body: some View {
        Menu {
            ForEach(tabs.filter { $0 != selection }, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(projectTabTitle(tab), systemImage: tab.systemImage)
                }
                .accessibilityIdentifier("project.tab.\(tab.rawValue)")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: selection.systemImage)
                    .font(.system(size: 14, weight: .semibold))

                Text(projectTabTitle(selection))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(Capsule())
            .opencodeConcentricGlassSurface(
                isInteractive: true,
                minimumCornerRadius: 18,
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(projectTabTitle(selection)))
        .accessibilityIdentifier("project.mode.menu")
    }
}

private func projectTabTitle(_ tab: OpenClientProjectContentTab) -> LocalizedStringKey {
    switch tab {
    case .sessions: "Sessions"
    case .git: "Files"
    case .terminal: "Terminal"
    case .mcp: "MCP"
    }
}

#if os(iOS) || targetEnvironment(macCatalyst)
@available(iOS 18.0, *)
private enum ProjectNativeTab: Hashable {
    case sessions
    case git
    case terminal
    case mcp

    init(projectTab: OpenClientProjectContentTab) {
        switch projectTab {
        case .sessions:
            self = .sessions
        case .git:
            self = .git
        case .mcp:
            self = .mcp
        case .terminal:
            self = .terminal
        }
    }

    var projectTab: OpenClientProjectContentTab? {
        switch self {
        case .sessions:
            return .sessions
        case .git:
            return .git
        case .mcp:
            return .mcp
        case .terminal:
            return .terminal
        }
    }
}
#endif
