import SwiftUI

#if targetEnvironment(macCatalyst)
struct CatalystChatTitleMenu: View {
    @ObservedObject var facade: ChatFacade
    let session: OpenCodeSession
    let maximumWidth: CGFloat
    @State private var scope: ChatFacade.HeaderScope?

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: facade.headerSnapshot(for: session).navigationTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .frame(minWidth: 120, idealWidth: maximumWidth, maxWidth: maximumWidth, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        // Render the title outside the button label: Catalyst adapts toolbar
        // button labels to image-only even when they contain a custom HStack.
        .overlay {
            Button {
                scope = facade.headerScope(for: session)
            } label: {
                Color.clear
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: facade.headerSnapshot(for: session).navigationTitle))
            .accessibilityIdentifier("chat.header")
        }
        .foregroundStyle(.primary)
        .popover(item: $scope, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { scope in
            CatalystChatTitlePanel(facade: facade, scope: scope)
        }
        .onChange(of: facade.promptContextID) { scope = nil }
        .onChange(of: facade.promptConnectionID) { scope = nil }
        .onChange(of: facade.selectedSession?.id) { scope = nil }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { scope = nil } }
    }
}

private struct CatalystChatTitlePanel: View {
    @ObservedObject var facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var saving = false
    @State private var deleting = false

    init(facade: ChatFacade, scope: ChatFacade.HeaderScope) {
        self.facade = facade
        self.scope = scope
        _title = State(initialValue: scope.session.title ?? "")
    }

    private var canSave: Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !saving && !deleting && facade.allowsHeaderActions(scope)
            && !value.isEmpty && value != (facade.selectedSession ?? scope.session).title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .disabled(saving || deleting || !facade.allowsHeaderActions(scope))
                .accessibilityIdentifier("chat.header.rename.title")
            HStack {
                Button(role: .destructive) {
                    deleting = true
                    Task {
                        let deleted = await facade.deleteHeaderSession(scope)
                        deleting = false
                        if deleted { dismiss() }
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(saving || deleting || !facade.allowsHeaderActions(scope))
                .accessibilityIdentifier("chat.header.delete")
                Spacer()
                if saving || deleting { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .disabled(!canSave)
                    .accessibilityIdentifier("chat.header.rename.save")
            }
            .buttonStyle(.bordered)
        }
        .tint(.primary)
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        guard canSave else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saving = true
        Task {
            await facade.renameHeaderSession(scope, title: value)
            saving = false
            if facade.isCurrentHeaderScope(scope), facade.selectedSession?.title == value { dismiss() }
        }
    }
}

struct CatalystChatHeaderActions: View {
    @ObservedObject var facade: ChatFacade
    let session: OpenCodeSession
    let onSideQuestion: () -> Void
    @State private var mcpScope: ChatFacade.HeaderScope?

    var body: some View {
        let available = facade.headerActionAvailability(for: session)
        HStack(spacing: 4) {
            Button {
                mcpScope = facade.headerScope(for: session)
            } label: {
                Image(systemName: "server.rack").frame(width: 36, height: 36)
            }
            .disabled(!available.mcp)
            .help("MCP")
            .accessibilityLabel("MCP")
            .accessibilityIdentifier("chat.toolbar.mcp")
            .popover(item: $mcpScope, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { scope in
                NavigationStack {
                    MCPListView(facade: facade.mcpFacade)
                        .navigationTitle("MCP")
                        .navigationBarTitleDisplayMode(.inline)
                }
                .id(scope.id)
                .frame(width: 400, height: 440)
            }
            Button(action: onSideQuestion) {
                Image(systemName: SideQuestionAppearance.symbolName).frame(width: 36, height: 36)
            }
            .disabled(!available.sideQuestion)
            .help("Side Question")
            .accessibilityLabel("Side Question")
            .accessibilityIdentifier("chat.toolbar.sideQuestion")
            Button { facade.presentForkSessionSheet() } label: {
                Image(systemName: "arrow.triangle.branch").frame(width: 36, height: 36)
            }
            .disabled(!available.fork)
            .help("Fork")
            .accessibilityLabel("Fork")
            .accessibilityIdentifier("chat.toolbar.fork")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onChange(of: facade.promptContextID) { mcpScope = nil }
        .onChange(of: facade.promptConnectionID) { mcpScope = nil }
        .onChange(of: facade.selectedSession?.id) { mcpScope = nil }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { mcpScope = nil } }
    }
}
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
struct ChatHeaderMenu: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var facade: ChatFacade
    let session: OpenCodeSession
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let glassNamespace: Namespace.ID
    var maximumWidth: CGFloat = 220
    var onOpenAgents: () -> Void = {}
    var onPresentationChange: (Bool) -> Void = { _ in }
    @State private var scope: ChatFacade.HeaderScope?
    @State private var pendingAgentsScope: ChatFacade.HeaderScope?
    @StateObject private var panel = ChatHeaderPanelState()
    private let panelCornerRadius: CGFloat = 40

    var body: some View {
        let current = facade.selectedSession?.id == session.id ? facade.selectedSession ?? session : session
        let title = facade.headerSnapshot(for: current).navigationTitle
        let toolbar = facade.toolbarSnapshot(for: current)
        Button {
            panel.reset(title: current.title ?? "")
            facade.headerFilesFacade.reset()
            popoverScope.wrappedValue = facade.headerScope(for: current)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(.caption)
                Text(verbatim: toolbar.agentTitle)
                    .font(.caption2).foregroundStyle(.primary.opacity(0.72))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(minWidth: maximumWidth, idealWidth: maximumWidth, maxWidth: maximumWidth, minHeight: 44, alignment: .leading)
            .contentShape(Capsule())
            .opencodeToolbarGlassID("chat-header", in: glassNamespace)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("chat.header")
        .popover(item: popoverScope, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { scope in
            ChatHeaderPanel(facade: facade, scope: scope, panel: panel, onOpenAgents: {
                pendingAgentsScope = scope
                dismissPopover()
            })
                .frame(width: max(1, containerWidth - 32), height: min(600, max(1, containerHeight - 16)))
                .containerShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
                .presentationCornerRadius(panelCornerRadius)
                .presentationBackground {
                    Color.clear
                        .opencodeGlassSurface(
                            tint: colorScheme == .dark ? .black.opacity(0.65) : .white.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        )
                }
                .presentationCompactAdaptation(.popover)
                .preferredColorScheme(colorScheme)
                .onDisappear {
                    guard let pending = pendingAgentsScope else { return }
                    pendingAgentsScope = nil
                    guard facade.isCurrentHeaderScope(pending) else { return }
                    onOpenAgents()
                }
        }
        .onChange(of: facade.promptContextID) { dismissPopover() }
        .onChange(of: facade.selectedSession?.id) { dismissPopover() }
        .onChange(of: facade.promptConnectionID) { dismissPopover() }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { dismissPopover() } }
    }

    private var popoverScope: Binding<ChatFacade.HeaderScope?> {
        Binding(get: { scope }, set: { newValue in
            let wasPresented = scope != nil
            scope = newValue
            let isPresented = newValue != nil
            if wasPresented != isPresented {
                onPresentationChange(isPresented)
            }
        })
    }

    private func dismissPopover() {
        let wasPresented = scope != nil
        scope = nil
        if wasPresented { onPresentationChange(false) }
    }
}

private final class ChatHeaderPanelState: ObservableObject {
    enum Tab: Hashable { case chat, mcp, git, terminal }
    @Published var tab: Tab = .chat
    @Published var title = ""
    @Published var showsFile = false
    @Published var terminalPath: [String] = []

    func reset(title: String) {
        tab = .chat
        self.title = title
        showsFile = false
        terminalPath = []
    }
}

private struct ChatHeaderPanel: View {
    let facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    @ObservedObject var panel: ChatHeaderPanelState
    let onOpenAgents: () -> Void

    var body: some View {
        TabView(selection: $panel.tab) {
            ChatHeaderPopover(facade: facade, scope: scope, title: $panel.title, onOpenAgents: onOpenAgents)
                .tabItem { Label("Chat", systemImage: "bubble.left") }
                .tag(ChatHeaderPanelState.Tab.chat)
            NavigationStack {
                MCPListView(facade: facade.mcpFacade)
                    .navigationTitle("MCP")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("MCP", systemImage: OpenClientProjectContentTab.mcp.systemImage) }
            .tag(ChatHeaderPanelState.Tab.mcp)
            NavigationStack {
                GitStatusView(facade: facade.headerFilesFacade) { panel.showsFile = true }
                    .navigationTitle("Files")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: $panel.showsFile) {
                        GitDiffView(facade: facade.headerFilesFacade)
                    }
            }
            .tabItem { Label("Files", systemImage: OpenClientProjectContentTab.git.systemImage) }
            .tag(ChatHeaderPanelState.Tab.git)
            ChatHeaderTerminal(facade: facade.headerTerminalFacade, path: $panel.terminalPath)
                .tabItem { Label("Terminal", systemImage: OpenClientProjectContentTab.terminal.systemImage) }
                .tag(ChatHeaderPanelState.Tab.terminal)
        }
        .accessibilityIdentifier("chat.header.panel")
    }
}

private struct ChatHeaderTerminal: View {
    @ObservedObject var facade: TerminalFacade
    @Binding var path: [String]

    var body: some View {
        NavigationStack(path: $path) {
            TerminalProjectView(facade: facade, usesTransparentBackground: true) {
                if let id = facade.snapshot.activeTerminalID { path = [id] }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Terminal", systemImage: "plus") { facade.createTerminal() }
                        .disabled(facade.snapshot.isCreatingTerminal)
                }
            }
            .navigationDestination(for: String.self) { id in
                TerminalDetailView(facade: facade, terminalID: id, isPresentedInPopover: true)
            }
        }
        .onChange(of: facade.snapshot.activeTerminalID) { _, id in
            if let id { path = [id] }
        }
    }
}

private struct ChatHeaderPopover: View {
    @ObservedObject var facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    @Environment(\.dismiss) private var dismiss
    @Binding var title: String
    let onOpenAgents: () -> Void
    @State private var saving = false
    @State private var changingLiveActivity = false
    @State private var changingYOLOMode = false
    @State private var loadingPermissions = true
    @State private var showsMoveSession = false

    var body: some View {
        let session = facade.selectedSession ?? scope.session
        let snapshot = facade.toolbarSnapshot(for: session)
        let allowsAgentSelection = facade.allowsHeaderAgentSelection(scope)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("Title", text: animatedTitleBinding, axis: .vertical)
                            .font(.headline)
                            .lineLimit(1...2)
                            .submitLabel(.done)
                            .onSubmit(saveTitle)
                            .accessibilityIdentifier("chat.header.rename.title")
                        if canSaveTitle {
                            Button(action: saveTitle) {
                                Image(systemName: "checkmark")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Save")
                            .accessibilityIdentifier("chat.header.rename.save")
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                }
                Section {
                    if facade.supportsHeaderLiveActivity(scope) {
                        Toggle(isOn: liveActivityBinding) {
                            Label("Live Activity", systemImage: "waveform")
                                .foregroundStyle(.primary)
                        }
                        .disabled(changingLiveActivity)
                        .accessibilityIdentifier("chat.header.liveActivity")
                    }
                    if facade.supportsSessionTools(scope) {
                        Toggle(isOn: yoloModeBinding) {
                            Label("Auto-approve permissions", systemImage: "bolt.fill")
                                .foregroundStyle(.primary)
                        }
                        .disabled(changingYOLOMode || loadingPermissions)
                        .accessibilityIdentifier("chat.header.yoloMode")
                    }
                    NavigationLink {
                        ChatAppearanceSettingsView(store: facade.appCustomizationStore, isV2Connection: facade.isV2Connection)
                    } label: {
                        Label("Appearance Settings", systemImage: "paintbrush")
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("chat.header.appearance")
                    Button(action: onOpenAgents) {
                        HStack {
                            Label("Subagents", systemImage: "person.2")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("chat.header.subagents")
                    if facade.supportsSessionTools(scope), scope.session.parentID == nil {
                        Button { showsMoveSession = true } label: {
                            Label("Move Session", systemImage: "folder.badge.arrow.forward")
                                .foregroundStyle(.primary)
                        }
                        .accessibilityIdentifier("chat.header.move")
                    }
                }
                Section("Agents") {
                    ForEach(snapshot.selectableAgents, id: \.name) { agent in
                        Button {
                            facade.selectHeaderAgent(named: agent.name, scope: scope)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: agent.name)
                                        .font(.body)
                                    if let description = agent.description, !description.isEmpty {
                                        Text(verbatim: description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if agent.name == snapshot.agentTitle {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowsAgentSelection)
                        .accessibilityIdentifier("chat.header.agent.\(agent.name)")
                        .accessibilityAddTraits(agent.name == snapshot.agentTitle ? .isSelected : [])
                    }
                }
                if let error = facade.presentationErrorMessage {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("chat.header.list")
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("chat.header.popover")
        .sheet(isPresented: $showsMoveSession) { MoveSessionSheet(facade: facade, scope: scope) }
        .task(id: scope.id) {
            await facade.refreshHeaderPermissions(scope)
            loadingPermissions = false
        }
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var animatedTitleBinding: Binding<String> {
        Binding(get: { title }, set: { newValue in
            withAnimation(.snappy(duration: 0.2)) { title = newValue }
        })
    }

    private var canSaveTitle: Bool {
        !saving && !trimmedTitle.isEmpty && trimmedTitle != (facade.selectedSession ?? scope.session).title
            && facade.allowsHeaderActions(scope)
    }

    private var liveActivityBinding: Binding<Bool> {
        Binding(get: { facade.isHeaderLiveActivityActive(scope) }, set: { isActive in
            guard isActive != facade.isHeaderLiveActivityActive(scope), !changingLiveActivity else { return }
            changingLiveActivity = true
            Task {
                await facade.toggleHeaderLiveActivity(scope)
                guard facade.isCurrentHeaderScope(scope) else { return }
                changingLiveActivity = false
            }
        })
    }

    private var yoloModeBinding: Binding<Bool> {
        Binding(get: { facade.isHeaderYOLOModeEnabled(scope) }, set: { enabled in
            guard !changingYOLOMode, !loadingPermissions else { return }
            changingYOLOMode = true
            Task {
                await facade.setHeaderYOLOMode(enabled, scope: scope)
                changingYOLOMode = false
            }
        })
    }

    private func saveTitle() {
        guard canSaveTitle else { return }
        withAnimation(.snappy(duration: 0.2)) { saving = true }
        let submittedTitle = trimmedTitle
        Task {
            await facade.renameHeaderSession(scope, title: submittedTitle)
            guard facade.isCurrentHeaderScope(scope) else { return }
            withAnimation(.snappy(duration: 0.2)) { saving = false }
            if facade.selectedSession?.title == submittedTitle { dismiss() }
        }
    }
}
#endif
