import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ProjectListView: View {
    @ObservedObject var facade: ProjectFacade
    let connection: ConnectionFacade
    @ObservedObject var configurations: ConfigurationsFacade
    @ObservedObject var games: FunAndGamesFacade
    let bridge: OpenClientBridgeFacade?
    let isActivitySelected: Bool
    let onActivityChosen: () -> Void
    let onProjectChosen: () -> Void
    @State private var projectForColorPicker: OpenCodeProject?
    @State private var projectForImagePicker: OpenCodeProject?
    @State private var isShowingBridgeStatus = false
    @State private var isEditingProjects = false

    init(
        facade: ProjectFacade,
        connection: ConnectionFacade,
        configurations: ConfigurationsFacade,
        games: FunAndGamesFacade,
        bridge: OpenClientBridgeFacade? = nil,
        isActivitySelected: Bool = false,
        onActivityChosen: @escaping () -> Void = {},
        onProjectChosen: @escaping () -> Void
    ) {
        self.facade = facade
        self.connection = connection
        self.configurations = configurations
        self.games = games
        self.bridge = bridge
        self.isActivitySelected = isActivitySelected
        self.onActivityChosen = onActivityChosen
        self.onProjectChosen = onProjectChosen
    }

    var body: some View {
        projectListContent
    }

    @ViewBuilder
    private var projectListContent: some View {
        let snapshot = facade.listSnapshot
        let displayedProjects = isEditingProjects ? snapshot.allProjects : snapshot.projects
        let projectIDs = displayedProjects.map { $0.id }.joined(separator: "|")

        List {
            if snapshot.isShowingSearchResults {
                ProjectSessionSearchSection(
                    query: snapshot.searchQuery,
                    results: snapshot.searchResults,
                    isLoading: snapshot.isSearching,
                    rowInsets: projectListRowInsets,
                    onSelect: openProjectSession
                )
            } else {
                Section {
                    Button(action: onActivityChosen) {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.path.ecg")
                                .font(.headline)
                                .foregroundStyle(isActivitySelected ? Color.accentColor : .secondary)
                                .frame(width: 32, height: 32)
                                .background(Color.accentColor.opacity(isActivitySelected ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 9))

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Activity")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Monitor sessions across projects")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("projects.activity")
                    .listRowInsets(projectListRowInsets)
                }

                Section {
                    if displayedProjects.isEmpty, !isEditingProjects {
                        Text("No projects are visible. Use the project settings button to show projects.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowInsets(projectListRowInsets)
                    }

                    ForEach(displayedProjects) { project in
                        let title = projectTitle(project)
                        let isVisible = facade.isVisible(project)
                        HStack(spacing: 8) {
                            ProjectRow(
                                title: title,
                                subtitle: project.id == "global" ? String(localized: "Shared sessions across the current server context") : project.worktree,
                                systemImage: project.id == "global" ? "globe" : "folder.fill",
                                icon: project.icon,
                                usesSystemImageFallback: project.id == "global",
                                isSelected: !isActivitySelected && facade.isSelected(project),
                                isPreparing: facade.isPreparingSelection(project),
                                subtitleLineLimit: isEditingProjects ? 2 : 1
                            )

                            if isEditingProjects {
                                Button {
                                    facade.setVisibility(!isVisible, for: project)
                                } label: {
                                    Image(systemName: isVisible ? "eye.fill" : "eye.slash")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(isVisible ? Color.accentColor : .secondary)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Show \(title)")
                                .accessibilityValue(isVisible ? String(localized: "On") : String(localized: "Off"))
                                .accessibilityIdentifier("projects.visibility.\(project.id)")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isEditingProjects else { return }
                            Task { @MainActor in
                                guard let ticket = await facade.prepareSelectionForNavigation(project) else { return }
                                withAnimation(opencodeSelectionAnimation) {
                                    onProjectChosen()
                                }
                                await facade.completeSelection(ticket)
                            }
                        }
                        .contextMenu {
                            if isEditingProjects {
                                EmptyView()
                            } else if facade.canEditPreferences(for: project) {
                                Button {
                                    projectForColorPicker = project
                                } label: {
                                    Label("Set Color", systemImage: "paintpalette")
                                }

                                Button {
                                    projectForImagePicker = project
                                } label: {
                                    Label("Set Image", systemImage: "photo.on.rectangle")
                                }

                                if project.icon?.override?.isEmpty == false {
                                    Button(role: .destructive) {
                                        Task { await facade.setImageOverride(nil, for: project) }
                                    } label: {
                                        Label("Clear Image", systemImage: "trash")
                                    }
                                }
                            } else {
                                Label("Preferences unavailable", systemImage: "lock")
                            }
                        }
                        .disabled(facade.isPreparingSelection(project))
                        .listRowInsets(projectListRowInsets)
                    }
                    .onMove(perform: facade.moveProjects)
                } header: {
                    ProjectListSectionHeader(
                        isEditingProjects: isEditingProjects,
                        allowsProjectCreation: !facade.isReadOnly,
                        onCreateProject: facade.presentCreateProject,
                        onToggleEditing: toggleProjectEditing
                    )
                    .textCase(nil)
                }

                if games.showsSection, !facade.isReadOnly {
                    Section {
                        ProjectRow(
                            title: String(localized: "Find the Place"),
                            subtitle: String(localized: "Guess a secret city from live weather clues"),
                            systemImage: "map.fill",
                            usesSystemImageFallback: true,
                            isSelected: false
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            games.presentFindPlaceModelSheet()
                        }
                        .listRowInsets(projectListRowInsets)

                        ProjectRow(
                            title: String(localized: "Find the Bug"),
                            subtitle: String(localized: "Spot the hidden bug in a generated code snippet"),
                            systemImage: "ladybug.fill",
                            usesSystemImageFallback: true,
                            isSelected: false
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            games.presentFindBugLanguageSheet()
                        }
                        .listRowInsets(projectListRowInsets)
                    } header: {
                        Label("Fun & Games", systemImage: "gamecontroller.fill")
                            .font(.headline)
                            .textCase(nil)
                            .padding(.leading, -16)
                    }
                }
            }

            Section {
                Button {
                    connection.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .tint(.red)
                .accessibilityIdentifier("projects.disconnect")
                .listRowInsets(projectListRowInsets)
            }
        }
        .listStyle(.sidebar)
        .environment(\.editMode, projectEditMode)
        .scrollClipDisabled()
        .refreshable {
            guard !isScreenshotScene else { return }
            await facade.refreshList()
        }
        .safeAreaInset(edge: .bottom) {
            OpenCodeConversationBottomBar(
                query: Binding(
                    get: { facade.projectSessionSearchQuery },
                    set: { facade.projectSessionSearchQuery = $0 }
                ),
                isSearching: snapshot.isSearching,
                allowsNewChat: !facade.isReadOnly,
                accessibilityPrefix: "projects",
                onNewChat: {
                    facade.presentNewChat()
                },
                onNewTalk: {
                    facade.presentNewTalk()
                }
            )
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, projectListBottomBarBottomPadding)
        }
        .task(id: snapshot.recentLoadKey) {
            guard !isScreenshotScene else { return }
            await facade.loadRecentSessions()
        }
        .task(id: snapshot.searchQuery) {
            guard !isScreenshotScene else { return }
            let query = snapshot.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await facade.searchSessions()
        }
        .navigationTitle("Projects")
        .toolbar {
            if let bridge, !facade.isReadOnly {
                ToolbarItem(placement: .opencodeTrailing) {
                    OpenClientBridgeToolbarButton(bridge: bridge) {
                        isShowingBridgeStatus = true
                    }
                }
            }

            if !facade.isReadOnly {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        configurations.present()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Configurations")
                    .accessibilityIdentifier("projects.configurations")
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { isShowingBridgeStatus },
            set: { isShowingBridgeStatus = $0 }
        )) {
            if let bridge {
                OpenClientBridgeStatusView(bridge: bridge)
            }
        }
        .sheet(isPresented: Binding(
            get: { facade.isShowingCreateProjectSheet },
            set: { facade.isShowingCreateProjectSheet = $0 }
        )) {
            CreateProjectSheet(facade: facade)
        }
        .sheet(isPresented: Binding(
            get: { configurations.isShowingConfigurationsSheet },
            set: { configurations.isShowingConfigurationsSheet = $0 }
        )) {
            ConfigurationsSheet(viewModel: configurations, connection: connection, bridge: bridge)
        }
        .sheet(isPresented: Binding(
            get: { games.isShowingFindPlaceModelSheet },
            set: { games.isShowingFindPlaceModelSheet = $0 }
        )) {
            FindPlaceModelSelectionSheet(viewModel: games, onGameStarted: onProjectChosen)
        }
        .sheet(isPresented: Binding(
            get: { games.isShowingFindBugLanguageSheet },
            set: { games.isShowingFindBugLanguageSheet = $0 }
        )) {
            FindBugLanguageSelectionSheet(viewModel: games)
        }
        .sheet(isPresented: Binding(
            get: { games.isShowingFindBugModelSheet },
            set: { games.isShowingFindBugModelSheet = $0 }
        )) {
            FindBugModelSelectionSheet(viewModel: games, onGameStarted: onProjectChosen)
        }
        .sheet(item: $projectForColorPicker) { project in
            ProjectColorPickerSheet(facade: facade, project: project)
        }
        .sheet(item: $projectForImagePicker) { project in
            ProjectImagePickerSheet(facade: facade, project: project)
        }
        .animation(opencodeSelectionAnimation, value: snapshot.selectedDirectory)
        .animation(opencodeSelectionAnimation, value: projectIDs)
        .onChange(of: snapshot.isShowingSearchResults) { _, isShowingSearchResults in
            if isShowingSearchResults {
                isEditingProjects = false
            }
        }
    }

    private var projectListRowInsets: EdgeInsets? {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        UIDevice.current.userInterfaceIdiom == .pad ? EdgeInsets() : nil
        #else
        nil
        #endif
    }

    private var projectListBottomBarBottomPadding: CGFloat {
        #if targetEnvironment(macCatalyst)
        16
        #else
        OpenCodeConversationControlsLayout.bottomEdgeAdjustment
        #endif
    }

    private var projectEditMode: Binding<EditMode> {
        Binding(
            get: { isEditingProjects ? .active : .inactive },
            set: { isEditingProjects = $0.isEditing }
        )
    }

    private func toggleProjectEditing() {
        withAnimation(opencodeSelectionAnimation) {
            isEditingProjects.toggle()
        }
    }

    private func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" {
            return String(localized: "Global", comment: "Name of the special project containing sessions shared across the server context.")
        }
        return project.name ?? project.worktree.split(separator: "/").last.map(String.init) ?? project.worktree
    }

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil
    }

    private func openProjectSession(_ recent: RecentProjectSession) {
        facade.prepareRecentSessionSelection(recent)
        withAnimation(opencodeSelectionAnimation) {
            onProjectChosen()
        }
        Task {
            await facade.openRecentSession(recent)
        }
    }
}

private struct ProjectSessionSearchSection: View {
    let query: String
    let results: [RecentProjectSession]
    let isLoading: Bool
    let rowInsets: EdgeInsets?
    let onSelect: (RecentProjectSession) -> Void

    var body: some View {
        Section {
            if results.isEmpty && isLoading {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Searching chats...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
                .listRowInsets(rowInsets)
            } else if results.isEmpty {
                Text("No chats match \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .listRowInsets(rowInsets)
            } else {
                ForEach(results) { recent in
                    Button {
                        onSelect(recent)
                    } label: {
                        ProjectSessionSearchRow(recent: recent)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(rowInsets)
                }
            }
        } header: {
            Text("Chats")
                .font(ProjectListLayout.sectionTitleFont)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

private struct ProjectSessionSearchRow: View {
    let recent: RecentProjectSession

    var body: some View {
        HStack(spacing: 12) {
            SessionAvatar(title: title)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if recent.isBusy {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(recent.preview?.text ?? recent.projectTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(recent.projectTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.secondary.opacity(0.78))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var title: String {
        let trimmed = recent.session.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed ?? String(localized: "Session") : String(localized: "Session")
    }
}

struct OpenCodeConversationBottomBar: View {
    @Binding var query: String
    let isSearching: Bool
    let allowsNewChat: Bool
    let accessibilityPrefix: String
    let onNewChat: () -> Void
    let onNewTalk: () -> Void
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: ProjectListLayout.bottomBarControlSpacing) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                TextField("Search Chats", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .onSubmit {
                        isSearchFocused = false
                    }
                    .accessibilityIdentifier("\(accessibilityPrefix).searchChats")

                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel("Clear chat search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: ProjectListLayout.searchBarHeight)
            .opencodeConcentricGlassSurface(minimumCornerRadius: ProjectListLayout.searchBarHeight / 2, in: Capsule())
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5)

            if isSearchFocused {
                Button {
                    dismissSearchFocus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: ProjectListLayout.searchBarHeight, height: ProjectListLayout.searchBarHeight)
                        .contentShape(Circle())
                        .opencodeConcentricGlassSurface(minimumCornerRadius: ProjectListLayout.searchBarHeight / 2, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(width: ProjectListLayout.searchBarHeight, height: ProjectListLayout.searchBarHeight)
                .contentShape(Circle())
                .accessibilityLabel("Dismiss Search")
                .accessibilityIdentifier("\(accessibilityPrefix).search.dismiss")
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .zIndex(1)
            } else if allowsNewChat {
                HStack(spacing: ProjectListLayout.conversationButtonSpacing) {
                    OpenCodeNewTalkFloatingButton(
                        accessibilityIdentifier: "\(accessibilityPrefix).newTalk",
                        action: onNewTalk
                    )
                    OpenCodeNewChatFloatingButton(
                        accessibilityIdentifier: "\(accessibilityPrefix).newChat",
                        action: onNewChat
                    )
                }
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, isSearchFocused ? 8 : 0)
        .animation(opencodeSelectionAnimation, value: isSearchFocused)
    }

    private func dismissSearchFocus() {
        isSearchFocused = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }

}

struct OpenCodeNewChatFloatingButton: View {
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        OpenCodeConversationFloatingButton(
            systemImage: "square.and.pencil",
            accessibilityLabel: "New Chat",
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
    }
}

struct OpenCodeNewTalkFloatingButton: View {
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        OpenCodeConversationFloatingButton(
            systemImage: "waveform",
            accessibilityLabel: "New Talk",
            accessibilityIdentifier: accessibilityIdentifier,
            action: action
        )
    }
}

enum OpenCodeConversationControlsLayout {
    static let bottomEdgeAdjustment: CGFloat = -4
}

private struct OpenCodeConversationFloatingButton: View {
    let systemImage: String
    let accessibilityLabel: LocalizedStringResource
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: ProjectListLayout.newChatIconSize, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: ProjectListLayout.newChatButtonDiameter, height: ProjectListLayout.newChatButtonDiameter)
        }
        .frame(width: ProjectListLayout.newChatButtonDiameter, height: ProjectListLayout.newChatButtonDiameter)
        .buttonStyle(.plain)
        .opencodeConcentricGlassSurface(
            clear: true,
            tint: Color.accentColor.opacity(0.82),
            isInteractive: true,
            minimumCornerRadius: ProjectListLayout.newChatButtonDiameter / 2,
            in: Circle()
        )
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var foreground: Color {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return .white
        }
        #endif
        return .primary
    }
}

private struct InlineSubtitleSelectTrigger: View {
    let title: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .underline(true, color: .secondary.opacity(0.75))
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .baselineOffset(1)
        }
        .contentShape(Rectangle())
    }
}

private struct ProjectNewChatModelItem: Identifiable, Equatable {
    let providerID: String
    let modelID: String
    let name: String

    var id: String { "\(providerID):\(modelID)" }
    var reference: OpenCodeModelReference { OpenCodeModelReference(providerID: providerID, modelID: modelID) }
}

private struct ProjectNewChatModelSection: Identifiable, Equatable {
    let id: String
    let name: String
    let models: [ProjectNewChatModelItem]
}

private enum ProjectNewChatQuickPicker: Equatable {
    case project
    case workspace
    case agent
    case model
    case reasoning
}

struct ProjectNewChatSheet: View, Equatable {
    @ObservedObject var viewModel: NewProjectChatFacade
    private let facadeIdentity: ObjectIdentifier
    let request: NewProjectChatSheetRequest
    let autoFocusInput: Bool
    let onChatStarted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftStore = MessageComposerDraftStore()
    @State private var attachments: [OpenCodeComposerAttachment] = []
    @State private var isComposerMenuOpen = false
    @State private var composerAccessoryExpansion: ComposerAccessoryExpansion = .collapsed
    @State private var selectedAttachmentPreview: OpenCodeComposerAttachment?
    @State private var isStartingChat = false
    @State private var selectedProjectID = ""
    @State private var workspaceSelection: NewSessionWorkspaceSelection = .main
    @State private var newWorkspaceName = ""
    @State private var hasInitializedSelection = false
    @State private var hasAppliedInitialWorkspace = false
    @State private var selectedAgentName: String?
    @State private var selectedModelReference: OpenCodeModelReference?
    @State private var selectedReasoningVariant: String?
    @State private var hasInitializedComposerSettings = false
    @State private var chatTitleDraft = ""
    @State private var isEditingChatTitle = false
    @State private var startingSnapshot: NewSessionStartingSnapshot?
    @FocusState private var isChatTitleFocused: Bool

    init(viewModel: NewProjectChatFacade, request: NewProjectChatSheetRequest, autoFocusInput: Bool = true, onChatStarted: @escaping () -> Void) {
        self.viewModel = viewModel
        facadeIdentity = ObjectIdentifier(viewModel)
        self.request = request
        self.autoFocusInput = autoFocusInput
        self.onChatStarted = onChatStarted
        _selectedProjectID = State(initialValue: request.projectID ?? "")
        _selectedAgentName = State(initialValue: request.composerSelection?.agentName)
        _selectedModelReference = State(initialValue: request.composerSelection?.modelReference)
        _selectedReasoningVariant = State(initialValue: request.composerSelection?.reasoningVariant)
        _attachments = State(initialValue: request.initialContent?.attachments ?? [])
    }

    nonisolated static func == (lhs: ProjectNewChatSheet, rhs: ProjectNewChatSheet) -> Bool {
        lhs.facadeIdentity == rhs.facadeIdentity
            && lhs.request.id == rhs.request.id
            && lhs.autoFocusInput == rhs.autoFocusInput
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                OpenCodePlatformColor.groupedBackground
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                newChatBody
                    .padding(.horizontal, 24)
                    .padding(.bottom, startingSnapshot == nil ? 96 : 0)

                if startingSnapshot == nil {
                    VStack(spacing: 6) {
                        if !attachments.isEmpty {
                            ComposerAccessoryArea(
                                todos: [],
                                attachments: attachments,
                                expansion: $composerAccessoryExpansion,
                                isTodoStripMinimized: false,
                                onSetTodoStripMinimized: { _ in },
                                onTapTodo: {},
                                onTapAttachment: { attachment in
                                    selectedAttachmentPreview = attachment
                                },
                                onRemoveAttachment: removeAttachment
                            )
                            .padding(.horizontal, 16)
                        }

                        NewChatInputBar(
                            draftStore: draftStore,
                            isAccessoryMenuOpen: $isComposerMenuOpen,
                            attachmentCount: attachments.count,
                            isSending: isStartingChat,
                            canSend: selectedProject != nil,
                            autoFocus: autoFocusInput && !isEditingChatTitle && !isChatTitleFocused,
                            usesKeyboardBottomPadding: isEditingChatTitle || isChatTitleFocused,
                            onSend: startChat,
                            onAddAttachments: addAttachments
                        )
                    }
                }

            }
            .sheet(item: $selectedAttachmentPreview) { attachment in
                NavigationStack {
                    AttachmentPreviewSheet(attachment: attachment)
                }
            }
            .background {
                OpenCodePlatformColor.groupedBackground
                    .ignoresSafeArea()
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationTitle(visibleChatTitle)
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") { dismissSheet() }
                        .disabled(startingSnapshot != nil)
                }

                ToolbarItem(placement: .principal) {
                    editableNavigationChatTitle
                }
            }
        }
        .presentationDetents([.large])
        .onAppear {
            if let initialContent = request.initialContent,
               !initialContent.text.isEmpty,
               draftStore.text.isEmpty {
                draftStore.text = initialContent.text
            }
            initializeSelectionIfNeeded()
            initializeComposerSettingsIfNeeded()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncWorkspaceSelection()
        }
        .onChange(of: viewModel.projects.map(\.id).joined(separator: "|")) { _, _ in
            initializeSelectionIfNeeded()
        }
        .onChange(of: selectedModelReference) { _, _ in
            syncReasoningSelection()
        }
        .onChange(of: composerSettingsSourceSignature) { _, _ in
            initializeComposerSettingsIfNeeded()
        }
        .onChange(of: isChatTitleFocused) { _, isFocused in
            if !isFocused, isEditingChatTitle {
                finishEditingChatTitle()
            }
        }
    }

    @ViewBuilder
    private var newChatBody: some View {
        if let startingSnapshot {
            NewSessionStartingPreview(snapshot: startingSnapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.projects.isEmpty {
            ContentUnavailableView("No Projects", systemImage: "folder", description: Text("Refresh projects before starting a new chat."))
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 14) {
                Spacer(minLength: 0)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.92))
                    .padding(.bottom, 4)

                editableChatTitle

                destinationSubtitle

                newWorktreeFields

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var editableChatTitle: some View {
        Text(visibleChatTitle)
            .font(.largeTitle.weight(.semibold))
            .foregroundStyle(chatTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .primary : Color.accentColor)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
            .onTapGesture(perform: beginEditingChatTitle)
            .accessibilityLabel("Rename chat")
            .accessibilityIdentifier("projects.newChat.titleButton")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var editableNavigationChatTitle: some View {
        if isEditingChatTitle {
            TextField("New Session", text: $chatTitleDraft)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.sentences)
                .submitLabel(.done)
                .focused($isChatTitleFocused)
                .onSubmit { finishEditingChatTitle() }
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .frame(width: 230)
                .accessibilityLabel("Chat title")
                .accessibilityIdentifier("projects.newChat.titleField")
        } else {
            Button(action: beginEditingChatTitle) {
                HStack(spacing: 5) {
                    Text(visibleChatTitle)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 230)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rename chat")
            .accessibilityIdentifier("projects.newChat.navigationTitleButton")
        }
    }

    private var visibleChatTitle: String {
        let trimmedTitle = chatTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedTitle.isEmpty ? String(localized: "New Session") : trimmedTitle
    }

    private var submittedChatTitle: String {
        chatTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finishEditingChatTitle() {
        isChatTitleFocused = false
        withAnimation(opencodeSelectionAnimation) {
            isEditingChatTitle = false
        }
    }

    private func beginEditingChatTitle() {
        isComposerMenuOpen = false
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
        withAnimation(opencodeSelectionAnimation) {
            isEditingChatTitle = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isChatTitleFocused = true
        }
    }

    @ViewBuilder
    private var destinationSubtitle: some View {
        VStack(spacing: 0) {
            destinationLine
            Divider()
                .padding(.leading, 16)
            composerSettingsLine
        }
        .frame(maxWidth: 320)
        .background(
            OpenCodePlatformColor.secondaryGroupedBackground,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var destinationLine: some View {
        VStack(spacing: 0) {
            selectionField("Project") {
                projectSelectTrigger
            }
            if showsWorkspacePicker {
                Divider()
                    .padding(.leading, 16)
                selectionField("Workspace") {
                    workspaceSelectTrigger
                }
            }
        }
    }

    @ViewBuilder
    private var composerSettingsLine: some View {
        VStack(spacing: 0) {
            selectionField("Agent") {
                agentSelectTrigger
            }
            Divider()
                .padding(.leading, 16)
            selectionField("Model") {
                modelSelectTrigger
            }
            if showsReasoningPicker {
                Divider()
                    .padding(.leading, 16)
                selectionField("Reasoning") {
                    reasoningSelectTrigger
                }
            }
        }
    }

    private func selectionField<Content: View>(
        _ label: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
            Spacer(minLength: 12)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var newWorktreeFields: some View {
        if workspaceSelection == .createNew {
            VStack(spacing: 8) {
                TextField("Worktree name (optional)", text: $newWorkspaceName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: Capsule())
                    .frame(maxWidth: 280)
                    .accessibilityIdentifier("projects.newChat.worktree.name")

                Text("OpenCode will create a separate git worktree before sending.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private var projectSelectTrigger: some View {
        if request.locksProject {
            Text(selectedProject.map(projectTitle) ?? String(localized: "Project"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityIdentifier("projects.newChat.project")
        } else {
            StablePickerMenu(
                elements: quickPickerMenuElements(.project),
                accessibilityLabel: String(localized: "Project"),
                accessibilityValue: selectedProject.map(projectTitle) ?? String(localized: "Project"),
                accessibilityIdentifier: "projects.newChat.project",
                onSelect: { selectQuickPickerOption($0, in: .project) }
            ) {
                InlineSubtitleSelectTrigger(title: selectedProject.map(projectTitle) ?? String(localized: "Project"))
            }
        }
    }

    private var workspaceSelectTrigger: some View {
        StablePickerMenu(
            elements: quickPickerMenuElements(.workspace),
            accessibilityLabel: String(localized: "Workspace"),
            accessibilityValue: workspaceSelectionTitle,
            accessibilityIdentifier: "projects.newChat.worktree",
            onSelect: { selectQuickPickerOption($0, in: .workspace) }
        ) {
            InlineSubtitleSelectTrigger(title: workspaceSelectionTitle)
        }
    }

    private var agentSelectTrigger: some View {
        StablePickerMenu(
            elements: quickPickerMenuElements(.agent),
            accessibilityLabel: String(localized: "Agent"),
            accessibilityValue: agentTitle,
            accessibilityIdentifier: "projects.newChat.agent",
            onSelect: { selectQuickPickerOption($0, in: .agent) }
        ) {
            InlineSubtitleSelectTrigger(title: agentTitle)
        }
    }

    private var modelSelectTrigger: some View {
        StablePickerMenu(
            elements: quickPickerMenuElements(.model),
            accessibilityLabel: String(localized: "Model"),
            accessibilityValue: modelTitle,
            accessibilityIdentifier: "projects.newChat.model",
            onSelect: { selectQuickPickerOption($0, in: .model) }
        ) {
            InlineSubtitleSelectTrigger(title: modelTitle)
        }
    }

    private var reasoningSelectTrigger: some View {
        StablePickerMenu(
            elements: quickPickerMenuElements(.reasoning),
            accessibilityLabel: String(localized: "Reasoning"),
            accessibilityValue: reasoningTitle,
            accessibilityIdentifier: "projects.newChat.reasoning",
            onSelect: { selectQuickPickerOption($0, in: .reasoning) }
        ) {
            InlineSubtitleSelectTrigger(title: reasoningTitle)
        }
    }

    private func quickPickerMenuElements(_ picker: ProjectNewChatQuickPicker) -> [StablePickerMenuElement] {
        switch picker {
        case .project:
            return [.inline(
                id: "projects",
                title: nil,
                children: viewModel.projects.map { project in
                    .action(
                        id: project.id,
                        title: projectTitle(project),
                        systemImage: project.id == "global" ? "globe" : "folder.fill",
                        isSelected: selectedProject?.id == project.id
                    )
                }
            )]

        case .workspace:
            guard let selectedProject else { return [] }
            var options = [StablePickerMenuElement.action(
                id: "main",
                title: workspaceTitle(selectedProject.worktree),
                systemImage: "folder.fill",
                isSelected: workspaceSelection == .main
            )]
            options += workspaceDirectories.compactMap { directory in
                guard viewModel.workspaceKey(directory) != viewModel.workspaceKey(selectedProject.worktree) else { return nil }
                return .action(
                    id: "directory:\(viewModel.workspaceKey(directory))",
                    title: workspaceTitle(directory),
                    systemImage: "folder",
                    isSelected: workspaceSelection == .directory(directory)
                )
            }
            options.append(.action(
                id: "create",
                title: String(localized: "Create new worktree"),
                systemImage: "plus.rectangle.on.folder",
                isSelected: workspaceSelection == .createNew
            ))
            return [.inline(id: "workspaces", title: nil, children: options)]

        case .agent:
            let options = [StablePickerMenuElement.action(
                id: "default",
                title: String(localized: "Default"),
                systemImage: "sparkles",
                isSelected: selectedAgentName == nil
            )] + viewModel.selectableAgents.map { agent in
                .action(
                    id: agent.name,
                    title: agent.name.capitalized,
                    systemImage: "person.crop.circle",
                    isSelected: selectedAgentName == agent.name
                )
            }
            return [.inline(id: "agents", title: nil, children: options)]

        case .model:
            var sections = [StablePickerMenuElement.inline(
                id: "default",
                title: nil,
                children: [.action(
                    id: "default",
                    title: modelDefaultOptionTitle,
                    systemImage: nil,
                    isSelected: selectedModelReference == nil
                )]
            )]
            sections += modelPickerSourceSections.map { section in
                .inline(
                    id: section.id,
                    title: section.name,
                    children: section.models.map { model in
                        .action(
                            id: model.id,
                            title: model.name,
                            systemImage: nil,
                            isSelected: selectedModelReference == model.reference
                        )
                    }
                )
            }
            return sections

        case .reasoning:
            let options = [StablePickerMenuElement.action(
                id: "default",
                title: String(localized: "Default"),
                systemImage: "sparkles",
                isSelected: selectedReasoningVariant == nil
            )] + reasoningVariants.map { variant in
                .action(
                    id: variant,
                    title: viewModel.formattedVariantTitle(variant),
                    systemImage: "brain.head.profile",
                    isSelected: selectedReasoningVariant == variant
                )
            }
            return [.inline(id: "reasoning", title: nil, children: options)]
        }
    }

    private func selectQuickPickerOption(_ optionID: String, in picker: ProjectNewChatQuickPicker) {
        switch picker {
        case .project:
            if let project = viewModel.projects.first(where: { $0.id == optionID }) {
                selectedProjectID = project.id
            }

        case .workspace:
            if optionID == "main" {
                workspaceSelection = .main
            } else if optionID == "create" {
                workspaceSelection = .createNew
            } else if let directory = workspaceDirectories.first(where: {
                optionID == "directory:\(viewModel.workspaceKey($0))"
            }) {
                workspaceSelection = .directory(directory)
            }

        case .agent:
            selectedAgentName = optionID == "default" ? nil : optionID

        case .model:
            if optionID == "default" {
                selectedModelReference = nil
            } else if let model = modelPickerSourceSections.lazy.flatMap(\.models).first(where: { $0.id == optionID }) {
                selectedModelReference = model.reference
            }
            syncReasoningSelection()

        case .reasoning:
            selectedReasoningVariant = optionID == "default" ? nil : optionID
        }

    }

    private var effectiveModelReference: OpenCodeModelReference? {
        selectedModelReference ?? viewModel.defaultModelReference()
    }

    private var reasoningVariants: [String] {
        viewModel.reasoningVariants(for: effectiveModelReference)
    }

    private var showsReasoningPicker: Bool {
        !reasoningVariants.isEmpty
    }

    private var agentTitle: String {
        selectedAgentName?.capitalized ?? String(localized: "Default")
    }

    private var modelTitle: String {
        if let selectedModelReference,
           let model = viewModel.model(for: selectedModelReference) {
            return model.name
        }
        if let defaultModelReference = viewModel.defaultModelReference(),
           let model = viewModel.model(for: defaultModelReference) {
            return model.name
        }
        return String(localized: "Default")
    }

    private var modelDefaultOptionTitle: String {
        if let defaultModelReference = viewModel.defaultModelReference(),
           let model = viewModel.model(for: defaultModelReference) {
            return String(localized: "Default (\(model.name))", comment: "Default model picker option. The variable is a server-provided model name.")
        }
        return String(localized: "Default")
    }

    private var reasoningTitle: String {
        selectedReasoningVariant.map(viewModel.formattedVariantTitle) ?? String(localized: "Default")
    }

    private var composerSettingsSourceSignature: String {
        [
            viewModel.newSessionDefaults.agentName ?? "",
            viewModel.newSessionDefaults.providerID ?? "",
            viewModel.newSessionDefaults.modelID ?? "",
            viewModel.newSessionDefaults.reasoningVariant ?? "",
            viewModel.selectableAgents.map(\.name).joined(separator: ","),
            viewModel.sortedProviders.map { provider in
                let modelIDs = viewModel.visibleModels(for: provider).map(\.id).joined(separator: ",")
                return "\(provider.id):\(modelIDs)"
            }.joined(separator: "|")
        ].joined(separator: "|")
    }

    private var modelPickerSourceSections: [ProjectNewChatModelSection] {
        viewModel.sortedProviders.compactMap { provider in
            let models = viewModel.visibleModels(for: provider).map { model in
                ProjectNewChatModelItem(providerID: provider.id, modelID: model.id, name: model.name)
            }
            guard !models.isEmpty else { return nil }
            return ProjectNewChatModelSection(id: provider.id, name: provider.name, models: models)
        }
    }

    private var selectedProject: OpenCodeProject? {
        if request.locksProject, let projectID = request.projectID {
            return viewModel.projects.first { $0.id == projectID }
        }
        return viewModel.projects.first { $0.id == selectedProjectID } ?? viewModel.projects.first
    }

    private var workspaceDirectories: [String] {
        guard let selectedProject, selectedProject.id != "global" else { return [] }
        return viewModel.workspaceDirectories(for: selectedProject)
    }

    private var showsWorkspacePicker: Bool {
        guard let selectedProject else { return false }
        return viewModel.isWorkspacesEnabled(for: selectedProject)
    }

    private func initializeSelectionIfNeeded() {
        guard !viewModel.projects.isEmpty else { return }
        if !hasInitializedSelection || !viewModel.projects.contains(where: { $0.id == selectedProjectID }) {
            if let projectID = request.projectID, viewModel.projects.contains(where: { $0.id == projectID }) {
                selectedProjectID = projectID
            } else {
                selectedProjectID = viewModel.currentProject?.id ?? viewModel.projects.first(where: { $0.id != "global" })?.id ?? viewModel.projects[0].id
            }
            hasInitializedSelection = true
        }
        syncWorkspaceSelection()
    }

    private func initializeComposerSettingsIfNeeded() {
        guard !hasInitializedComposerSettings else {
            syncReasoningSelection()
            return
        }

        if let requestAgentName = request.composerSelection?.agentName,
           viewModel.selectableAgents.contains(where: { $0.name == requestAgentName }) {
            selectedAgentName = requestAgentName
        } else if let defaultAgentName = viewModel.newSessionDefaults.agentName,
           viewModel.selectableAgents.contains(where: { $0.name == defaultAgentName }) {
            selectedAgentName = defaultAgentName
        } else {
            selectedAgentName = nil
        }

        selectedModelReference = request.composerSelection?.modelReference ?? viewModel.newSessionDefaultModelReference()
        selectedReasoningVariant = request.composerSelection?.reasoningVariant ?? viewModel.newSessionDefaults.reasoningVariant
        syncReasoningSelection()
        hasInitializedComposerSettings = true
    }

    private func syncReasoningSelection() {
        guard let selectedReasoningVariant else { return }
        let variants = reasoningVariants
        guard !variants.isEmpty else { return }
        guard variants.contains(selectedReasoningVariant) else {
            self.selectedReasoningVariant = nil
            return
        }
    }

    private func syncWorkspaceSelection() {
        guard let selectedProject, selectedProject.id != "global" else {
            workspaceSelection = .main
            return
        }

        let directories = workspaceDirectories
        if let directory = request.workspaceDirectory,
           !directory.isEmpty,
           !hasAppliedInitialWorkspace,
           directories.contains(where: { viewModel.workspaceKey($0) == viewModel.workspaceKey(directory) }) {
            workspaceSelection = viewModel.workspaceKey(directory) == viewModel.workspaceKey(selectedProject.worktree) ? .main : .directory(directory)
            hasAppliedInitialWorkspace = true
            return
        }

        hasAppliedInitialWorkspace = true

        switch workspaceSelection {
        case .main, .createNew:
            return
        case let .directory(directory):
            if directories.contains(where: { viewModel.workspaceKey($0) == viewModel.workspaceKey(directory) }) {
                return
            }
        }
        workspaceSelection = .main
    }

    private func startChat() {
        guard let selectedProject else { return }
        guard !isStartingChat else { return }
        guard !draftStore.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        let workspaceDirectory = selectedProject.id == "global" ? nil : workspaceDirectoryForSelection
        let prompt = draftStore.text
        let agentMentions = draftStore.agentMentions
        let currentAttachments = attachments
        let messageID = OpenCodeIdentifier.message()
        let partID = OpenCodeIdentifier.part()

        withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
            startingSnapshot = NewSessionStartingSnapshot(
                title: visibleChatTitle,
                subtitle: startingPreviewSubtitle(for: selectedProject),
                promptPreview: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                attachmentCount: currentAttachments.count,
                phase: workspaceSelection == .createNew ? .creatingWorktree : .creatingSession
            )
            composerAccessoryExpansion = .collapsed
            isComposerMenuOpen = false
        }

        Task {
            isStartingChat = true
            defer { isStartingChat = false }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                guard isStartingChat, startingSnapshot != nil else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    startingSnapshot?.phase = .sendingMessage
                }
            }
            let didStart = await viewModel.startNewChat(
                title: submittedChatTitle,
                prompt: prompt,
                agentMentions: agentMentions,
                attachments: currentAttachments,
                messageID: messageID,
                partID: partID,
                composerSelection: NewProjectChatComposerSelection(
                    agentName: selectedAgentName,
                    modelReference: selectedModelReference,
                    reasoningVariant: showsReasoningPicker ? selectedReasoningVariant : nil
                ),
                projectID: selectedProject.id,
                workspaceDirectory: workspaceDirectory,
                workspaceSelection: selectedProject.id == "global" ? nil : workspaceSelection,
                newWorkspaceName: newWorkspaceName
            )
            if didStart {
                withAnimation(.easeInOut(duration: 0.16)) {
                    startingSnapshot?.phase = .waitingForOpenCode
                }
                dismissSheet()
                onChatStarted()
            } else if viewModel.paywallReason != nil {
                dismissSheet()
            } else {
                withAnimation(.snappy(duration: 0.22, extraBounce: 0.02)) {
                    startingSnapshot = nil
                }
            }
        }
    }

    private func startingPreviewSubtitle(for project: OpenCodeProject) -> String {
        guard project.id != "global" else { return String(localized: "Global", comment: "Name of the special project containing sessions shared across the server context.") }
        let workspace = workspaceSelectionTitle
        return "\(projectTitle(project)) • \(workspace)"
    }

    private var workspaceDirectoryForSelection: String? {
        guard let selectedProject, selectedProject.id != "global" else { return nil }
        switch workspaceSelection {
        case .main, .createNew:
            return selectedProject.worktree
        case let .directory(directory):
            return directory.isEmpty ? selectedProject.worktree : directory
        }
    }

    private var workspaceSelectionTitle: String {
        guard let selectedProject else { return String(localized: "Workspace") }
        switch workspaceSelection {
        case .main:
            return workspaceTitle(selectedProject.worktree)
        case let .directory(directory):
            return workspaceTitle(directory)
        case .createNew:
            return String(localized: "New worktree")
        }
    }

    private func dismissSheet() {
        viewModel.dismissNewChat()
        dismiss()
    }

    private func addAttachments(_ newAttachments: [OpenCodeComposerAttachment]) {
        guard !newAttachments.isEmpty else { return }
        withAnimation(opencodeSelectionAnimation) {
            var existingIDs = Set(attachments.map(\.id))
            let uniqueAttachments = newAttachments.filter { attachment in
                guard !existingIDs.contains(attachment.id) else { return false }
                existingIDs.insert(attachment.id)
                return true
            }
            attachments.append(contentsOf: uniqueAttachments)
            if !attachments.isEmpty {
                composerAccessoryExpansion = .expanded(focus: .attachments)
            }
        }
    }

    private func removeAttachment(_ attachment: OpenCodeComposerAttachment) {
        withAnimation(opencodeSelectionAnimation) {
            attachments.removeAll { $0.id == attachment.id }
            if attachments.isEmpty {
                composerAccessoryExpansion = .collapsed
            }
        }
    }

    private func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" { return String(localized: "Global", comment: "Name of the special project containing sessions shared across the server context.") }
        let trimmedName = project.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty { return trimmedName }
        return URL(fileURLWithPath: project.worktree).lastPathComponent
    }

    private func workspaceTitle(_ directory: String) -> String {
        viewModel.workspaceDisplayName(for: directory, in: selectedProject) ?? URL(fileURLWithPath: directory).lastPathComponent
    }

}

private struct NewChatInputBar: View {
    @ObservedObject var draftStore: MessageComposerDraftStore
    @Binding var isAccessoryMenuOpen: Bool
    @State private var isComposerFocused = false
    @Namespace private var glassNamespace
    let attachmentCount: Int
    let isSending: Bool
    let canSend: Bool
    let autoFocus: Bool
    let usesKeyboardBottomPadding: Bool
    let onSend: () -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void

    var body: some View {
        MessageComposer(
            draftStore: draftStore,
            isAccessoryMenuOpen: $isAccessoryMenuOpen,
            commands: [],
            mentionableAgents: [],
            pinnedCommands: [],
            pinnedCommandNames: [],
            attachmentCount: attachmentCount,
            isBusy: false,
            canFork: false,
            forkableMessages: [],
            mcpServers: [],
            connectedMCPServerCount: 0,
            isLoadingMCP: false,
            togglingMCPServerNames: [],
            mcpErrorMessage: nil,
            onFocusChange: { isComposerFocused = $0 },
            onTextChange: { _ in },
            onAgentMentionsChange: { _ in },
            onHeightChange: { _ in },
            onSend: {
                guard canSend && !isSending else { return }
                onSend()
            },
            onStop: {},
            onSelectCommand: { _ in },
            onPinCommand: { _ in },
            onUnpinCommand: { _ in },
            onCompact: {},
            onForkMessage: { _ in },
            onLoadMCP: {},
            onToggleMCP: { _ in },
            onAddAttachments: onAddAttachments,
            onOpenBrowser: nil,
            glassNamespace: glassNamespace,
            allowsTextTools: false,
            allowsSessionTools: false,
            autoFocus: autoFocus
        )
        .disabled(!canSend || isSending)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, isComposerFocused || usesKeyboardBottomPadding ? 8 : 0)
        .background(.clear)
    }
}

private struct ProjectListSectionHeader: View {
    let isEditingProjects: Bool
    let allowsProjectCreation: Bool
    let onCreateProject: () -> Void
    let onToggleEditing: () -> Void

    var body: some View {
        HStack {
            Label("Projects", systemImage: "folder.fill")
                .font(.headline)

            Spacer(minLength: 8)

            if allowsProjectCreation {
                Button(action: onCreateProject) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .opencodeGlassButton(clear: false)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Create Project")
                .accessibilityIdentifier("projects.create")
            }

            Button(action: onToggleEditing) {
                Image(systemName: isEditingProjects ? "checkmark" : "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .opencodeGlassButton(clear: false)
            .buttonBorderShape(.circle)
            .accessibilityLabel(Text(projectEditingAccessibilityLabel))
            .accessibilityIdentifier("projects.manage")
        }
        .padding(.leading, -16)
        .padding(.trailing, -29)
    }

    private var projectEditingAccessibilityLabel: LocalizedStringResource {
        isEditingProjects ? "Finish Editing Projects" : "Manage Projects"
    }
}

private enum ProjectListLayout {
    static let sectionTitleFont = Font.system(.footnote, design: .default).weight(.semibold)
    static let roundedSectionTitleFont = Font.system(.footnote, design: .rounded).weight(.semibold)
    static let searchBarHeight: CGFloat = 44
    static let newChatButtonDiameter: CGFloat = 44
    static let newChatIconSize: CGFloat = 22
    static let bottomBarControlSpacing: CGFloat = 12
    static let conversationButtonSpacing: CGFloat = 8
}

private struct ProjectColorPickerSheet: View {
    @ObservedObject var facade: ProjectFacade
    let project: OpenCodeProject
    @Environment(\.dismiss) private var dismiss

    private let colors = ["pink", "mint", "orange", "purple", "cyan", "lime"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                ProjectRow(
                    title: project.name ?? URL(fileURLWithPath: project.worktree).lastPathComponent,
                    subtitle: project.worktree,
                    systemImage: "folder.fill",
                    icon: project.icon,
                    isSelected: false
                )
                .padding(.horizontal)
                .padding(.top, 8)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(colors, id: \.self) { color in
                        Button {
                            Task {
                                await facade.setColor(color, for: project)
                                dismiss()
                            }
                        } label: {
                            VStack(spacing: 8) {
                                ProjectColorSwatch(color: color, title: project.name ?? project.worktree)
                                Text(projectColorTitle(color))
                                    .font(.caption.weight(.medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(project.icon?.color == color ? Color.accentColor : Color.clear, lineWidth: 2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 0)
            }
            .navigationTitle("Project Color")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private func projectColorTitle(_ color: String) -> LocalizedStringResource {
    switch color {
    case "pink": "Pink"
    case "mint": "Mint"
    case "orange": "Orange"
    case "purple": "Purple"
    case "cyan": "Cyan"
    default: "Lime"
    }
}

private struct ProjectImagePickerSheet: View {
    @ObservedObject var facade: ProjectFacade
    let project: OpenCodeProject
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ProjectImageCandidate] = []
    @State private var thumbnails: [String: String] = [:]
    @State private var isLoading = true
    @State private var selectedPath: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Searching images...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "No Images Found",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("OpenClient searched for PNG, JPG, and JPEG files in this project.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(candidates) { candidate in
                                Button {
                                    Task { await select(candidate) }
                                } label: {
                                    ProjectImageCandidateCell(
                                        candidate: candidate,
                                        dataURL: thumbnails[candidate.path],
                                        isSelected: selectedPath == candidate.path
                                    )
                                }
                                .buttonStyle(.plain)
                                .task {
                                    await loadThumbnailIfNeeded(candidate)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Project Image")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") { dismiss() }
                }

                ToolbarItem(placement: .opencodeTrailing) {
                    if project.icon?.override?.isEmpty == false {
                        Button("Clear", role: .destructive) {
                            Task {
                                await facade.setImageOverride(nil, for: project)
                                dismiss()
                            }
                        }
                    }
                }
            }
            .task {
                candidates = await facade.discoverImageCandidates(for: project)
                isLoading = false
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadThumbnailIfNeeded(_ candidate: ProjectImageCandidate) async {
        guard thumbnails[candidate.path] == nil else { return }
        guard let dataURL = await facade.imageDataURL(for: candidate, project: project) else { return }
        thumbnails[candidate.path] = dataURL
    }

    private func select(_ candidate: ProjectImageCandidate) async {
        selectedPath = candidate.path
        if thumbnails[candidate.path] == nil {
            await loadThumbnailIfNeeded(candidate)
        }
        guard let dataURL = thumbnails[candidate.path] else {
            selectedPath = nil
            return
        }
        await facade.setImageOverride(dataURL, for: project)
        dismiss()
    }
}

private struct ProjectColorSwatch: View {
    let color: String
    let title: String

    var body: some View {
        let colors = swatchColors(for: color)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colors.background)
            Text(title.first.map { String($0).uppercased() } ?? "?")
                .font(.title3.weight(.bold))
                .foregroundStyle(colors.foreground)
        }
        .frame(width: 58, height: 58)
    }

    private func swatchColors(for value: String) -> (background: Color, foreground: Color) {
        switch value {
        case "pink": return (Color(red: 0.96, green: 0.45, blue: 0.70), .white)
        case "mint": return (Color(red: 0.25, green: 0.82, blue: 0.62), Color.black.opacity(0.78))
        case "orange": return (Color(red: 0.98, green: 0.57, blue: 0.24), .white)
        case "purple": return (Color(red: 0.58, green: 0.45, blue: 0.86), .white)
        case "cyan": return (Color(red: 0.13, green: 0.79, blue: 0.89), Color.black.opacity(0.78))
        default: return (Color(red: 0.62, green: 0.82, blue: 0.20), Color.black.opacity(0.78))
        }
    }
}

private struct ProjectImageCandidateCell: View {
    let candidate: ProjectImageCandidate
    let dataURL: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                if let dataURL, let image = projectPreferencePlatformImage(from: dataURL) {
                    projectPreferencePlatformImageView(image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .frame(height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), lineWidth: isSelected ? 2 : 1)
            }

            Text(candidate.filename)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(candidate.displayPath)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#if canImport(UIKit)
private func projectPreferencePlatformImage(from dataURL: String) -> UIImage? {
    guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].contains("base64") else { return nil }
    guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
    return UIImage(data: data)
}

private func projectPreferencePlatformImageView(_ image: UIImage) -> Image {
    Image(uiImage: image)
}
#elseif canImport(AppKit)
private func projectPreferencePlatformImage(from dataURL: String) -> NSImage? {
    guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].contains("base64") else { return nil }
    guard let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
    return NSImage(data: data)
}

private func projectPreferencePlatformImageView(_ image: NSImage) -> Image {
    Image(nsImage: image)
}
#endif

private struct FindBugLanguageSelectionSheet: View {
    @ObservedObject var viewModel: FunAndGamesFacade

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the language for the buggy snippet. These match the app's syntax highlighting support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Languages") {
                    ForEach(FindBugGame.supportedLanguages) { language in
                        Button {
                            viewModel.selectFindBugLanguage(language)
                        } label: {
                            HStack {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(.tint)
                                Text(language.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Find the Bug")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        viewModel.isShowingFindBugLanguageSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FindBugModelSelectionSheet: View {
    @ObservedObject var viewModel: FunAndGamesFacade
    let onGameStarted: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the model that will generate the buggy code and judge your answer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.sortedProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), id: \.id) { model in
                            let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                            Button {
                                Task {
                                    await viewModel.startFindBugGame(model: reference)
                                    onGameStarted()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.pendingFindBugLanguage?.title ?? String(localized: "Model"))
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Back") {
                        viewModel.isShowingFindBugModelSheet = false
                        viewModel.isShowingFindBugLanguageSheet = true
                    }
                }
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Cancel") {
                        viewModel.cancelFindBugModelSelection()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FindPlaceModelSelectionSheet: View {
    @ObservedObject var viewModel: FunAndGamesFacade
    let onGameStarted: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the model that will host the game. OpenClient will start a new chat and send the private game setup automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.sortedProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), id: \.id) { model in
                            let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                            Button {
                                Task {
                                    await viewModel.startFindPlaceGame(model: reference)
                                    onGameStarted()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }
            }
            .navigationTitle("Find the Place")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        viewModel.isShowingFindPlaceModelSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
