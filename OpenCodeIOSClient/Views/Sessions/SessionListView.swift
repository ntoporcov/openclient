import SwiftUI

struct SessionListView: View {
    @ObservedObject var facade: SessionListFacade
    let onSessionChosen: () -> Void
    let onNewChat: () -> Void
    let onNewTalk: () -> Void

    init(
        facade: SessionListFacade,
        onSessionChosen: @escaping () -> Void,
        onNewChat: @escaping () -> Void = {},
        onNewTalk: @escaping () -> Void = {}
    ) {
        self.facade = facade
        self.onSessionChosen = onSessionChosen
        self.onNewChat = onNewChat
        self.onNewTalk = onNewTalk
    }

    var body: some View {
        SessionListContent(
            facade: facade,
            snapshot: facade.snapshot,
            onSessionChosen: onSessionChosen
        )
        .equatable()
        .safeAreaInset(edge: .bottom) {
            if !facade.snapshot.isReadOnly {
                HStack(spacing: 8) {
                    Spacer()
                    SessionListActionButton(
                        title: "Talk",
                        systemImage: "waveform",
                        accessibilityIdentifier: "sessions.newTalk",
                        action: onNewTalk
                    )
                    SessionListActionButton(
                        title: "Chat",
                        systemImage: "square.and.pencil",
                        accessibilityIdentifier: "sessions.create",
                        action: onNewChat
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct SessionListActionButton: View {
    let title: LocalizedStringResource
    let systemImage: String
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        button
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .opencodeConcentricGlassSurface(
                clear: true,
                tint: Color.accentColor.opacity(0.82),
                isInteractive: true,
                minimumCornerRadius: 19,
                in: Capsule()
            )
            .frame(minHeight: 44)
            .contentShape(Capsule())
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var button: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Capsule())
        }
    }
}

private struct SessionListContent: View, Equatable {
    let facade: SessionListFacade
    let snapshot: SessionListFacade.Snapshot
    @State private var renamingSession: OpenCodeSession?
    @State private var renameTitle = ""
    @State private var isShowingCreateWorkspaceAlert = false
    @State private var createWorkspaceName = ""
    let onSessionChosen: () -> Void

    nonisolated static func == (lhs: SessionListContent, rhs: SessionListContent) -> Bool {
        lhs.facade === rhs.facade && lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        List {
            if !snapshot.isReadOnly, !snapshot.hasProUnlock {
                ProjectUsageCTA(facade: facade)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !snapshot.isReadOnly, snapshot.hasProUnlock {
                if !snapshot.currentProjectActions.isEmpty {
                    ProjectActionStrip(facade: facade, actions: snapshot.currentProjectActions)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if !snapshot.isReadOnly {
                LockedProjectActionStrip {
                    facade.presentPaywall(reason: .actions)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if snapshot.isLoadingEmpty {
                Section {
                    ForEach(0 ..< 3, id: \.self) { _ in
                        SessionRowSkeleton()
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    SessionSectionHeader(title: "Pinned", systemImage: "pin")
                }
            } else if !snapshot.pinnedRows.isEmpty {
                Section {
                    ForEach(snapshot.pinnedRows) { row in
                        sessionRow(for: row)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: movePinnedSessions)
                } header: {
                    SessionSectionHeader(title: "Pinned", systemImage: "pin.fill", accessory: "\(snapshot.pinnedRows.count)")
                }
            }

            if snapshot.showsWorkspaces {
                ForEach(snapshot.workspaceSections) { section in
                    workspaceSection(section)
                }
            } else {
                Section {
                    if snapshot.isLoadingEmpty {
                    ForEach(0 ..< 6, id: \.self) { _ in
                        SessionRowSkeleton()
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    } else if snapshot.unpinnedRows.isEmpty {
                        Group {
                            if snapshot.isEmpty {
                                if snapshot.isReadOnly {
                                    Text("No downloaded sessions.")
                                } else {
                                    Text("Create a session to start chatting.")
                                }
                            } else {
                                Text("All visible sessions are pinned.")
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(snapshot.unpinnedRows) { row in
                            sessionRow(for: row)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }

                    if snapshot.hasMoreSessions {
                        Button {
                            Task { await facade.loadMoreSessions() }
                        } label: {
                            HStack {
                                Spacer(minLength: 0)
                                Text(loadMoreTitle(isLoading: snapshot.isLoadingMoreSessions))
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(snapshot.isLoadingMoreSessions)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    if !snapshot.pinnedRows.isEmpty {
                        SessionSectionHeader(title: "Sessions", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }

            if let errorMessage = snapshot.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    SessionSectionHeader(title: "Error", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OpenCodePlatformColor.groupedBackground)
        .opencodeInteractiveKeyboardDismiss()
        .refreshable {
            await facade.refresh()
        }
        .task(id: snapshot.cardStyle) {
            await facade.prepareActivityCardsIfNeeded()
        }
        .transaction { transaction in
            if snapshot.hasBusySession {
                transaction.animation = nil
            }
        }
        .alert("Rename Session", isPresented: renameAlertBinding) {
            TextField("Title", text: $renameTitle)
            Button("Cancel", role: .cancel) {
                renamingSession = nil
                renameTitle = ""
            }
            Button("Rename") {
                guard let session = renamingSession else { return }
                let title = renameTitle
                renamingSession = nil
                renameTitle = ""
                Task { await facade.rename(session, title: title) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new title for this session.")
        }
        .alert("New Workspace", isPresented: $isShowingCreateWorkspaceAlert) {
            TextField("Name (optional)", text: $createWorkspaceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Button("Cancel", role: .cancel) {
                createWorkspaceName = ""
            }

            Button("Create Workspace") {
                let name = createWorkspaceName
                createWorkspaceName = ""
                Task { await facade.createWorkspace(name: name) }
            }
        } message: {
            Text("OpenCode will create a separate git worktree for this project.")
        }
        .animation(opencodeSelectionAnimation, value: snapshot.selectedSessionID)
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingSession != nil },
            set: { isPresented in
                if !isPresented {
                    renamingSession = nil
                    renameTitle = ""
                }
            }
        )
    }

    private func workspaceSection(_ section: SessionListFacade.WorkspaceSection) -> some View {
        Section {
            if section.isLoading && section.rows.isEmpty {
                ForEach(0 ..< 2, id: \.self) { _ in
                    SessionRowSkeleton()
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if case let .failed(message) = section.operation, section.rows.isEmpty {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if section.rows.isEmpty {
                Text("No sessions in this workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(section.rows) { row in
                    sessionRow(for: row)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            if section.hasMore {
                Button {
                    Task { await facade.loadMoreWorkspaceSessions(directory: section.directory) }
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Text(loadMoreTitle(isLoading: section.isLoading))
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(section.isLoading)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } header: {
            WorkspaceSectionHeader(
                section: section,
                onNewSession: {
                    facade.presentNewSession(inWorkspace: section.directory)
                },
                onCreateWorkspace: {
                    createWorkspaceName = ""
                    isShowingCreateWorkspaceAlert = true
                },
                onRefresh: {
                    Task { await facade.refreshWorkspaceSessions(directory: section.directory) }
                },
                onResetConfirmed: { directory in
                    Task { await facade.resetWorktree(directory: directory) }
                },
                onDeleteConfirmed: { directory in
                    Task { await facade.deleteWorktree(directory: directory) }
                }
            )
            .id(section.directory)
        }
    }

    private func movePinnedSessions(from offsets: IndexSet, to destination: Int) {
        withAnimation(opencodeSelectionAnimation) {
            facade.movePinnedSessions(from: offsets, to: destination)
        }
    }

    private func sessionRow(
        for row: SessionListFacade.RowSnapshot
    ) -> some View {
        Button {
            let ticket = facade.beginSelection(row.session)
            Task { @MainActor in
                guard await facade.prepareSelectionForNavigation(ticket) else { return }
                withAnimation(opencodeSelectionAnimation) {
                    onSessionChosen()
                }
                await facade.completeSelection(ticket)
            }
        } label: {
            sessionRowLabel(for: row)
        }
        .buttonStyle(SessionRowButtonStyle())
        .contentShape(Rectangle())
        .accessibilityIdentifier("session.row.\(row.session.id)")
        .contextMenu {
            pinButton(for: row.session)
            if !snapshot.isReadOnly {
                deleteButton(for: row.session)
                renameButton(for: row.session)
#if !targetEnvironment(macCatalyst)
                liveActivityButton(for: row.session)
#endif
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            pinButton(for: row.session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !snapshot.isReadOnly {
                deleteButton(for: row.session)
                renameButton(for: row.session)
#if !targetEnvironment(macCatalyst)
                liveActivityButton(for: row.session)
#endif
            }
        }
    }

    @ViewBuilder
    private func sessionRowLabel(for row: SessionListFacade.RowSnapshot) -> some View {
        switch snapshot.cardStyle {
        case .compact:
            SessionRow(
                session: row.session,
                isSelected: row.isSelected,
                showsPinnedBadge: row.showsPinnedBadge,
                workspaceOverline: row.workspaceOverline,
                style: .compact,
                preview: row.preview,
                isBusy: row.isBusy,
                hasLiveActivity: row.hasLiveActivity,
                hasDraft: row.hasDraft,
                hasPermissionRequest: row.hasPermissionRequest,
                displayTitle: row.displayTitle,
                shimmersTitle: row.shimmersTitle
            )
            .equatable()
        case .simple:
            SessionRow(
                session: row.session,
                isSelected: row.isSelected,
                showsPinnedBadge: row.showsPinnedBadge,
                workspaceOverline: row.workspaceOverline,
                style: row.style,
                preview: row.preview,
                isBusy: row.isBusy,
                hasLiveActivity: row.hasLiveActivity,
                hasDraft: row.hasDraft,
                hasPermissionRequest: row.hasPermissionRequest,
                displayTitle: row.displayTitle,
                shimmersTitle: row.shimmersTitle
            )
            .equatable()
        case .activity:
            ActivitySessionRow(
                row: row.activityRow,
                showsLastUserMessage: snapshot.showsActivityLastUserMessage,
                isSelected: row.isSelected
            )
        }
    }

    @ViewBuilder
    private func pinButton(for session: OpenCodeSession) -> some View {
        if facade.isPinned(session) {
            Button {
                withAnimation(opencodeSelectionAnimation) {
                    facade.unpin(session)
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
            .tint(.gray)
        } else {
            Button {
                withAnimation(opencodeSelectionAnimation) {
                    facade.pin(session)
                }
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .tint(.orange)
        }
    }

    private func deleteButton(for session: OpenCodeSession) -> some View {
        Button(role: .destructive) {
            Task { await facade.delete(session) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func renameButton(for session: OpenCodeSession) -> some View {
        Button {
            renamingSession = session
            renameTitle = session.title ?? ""
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .tint(.blue)
    }

    private func liveActivityButton(for session: OpenCodeSession) -> some View {
        Button {
            Task { await facade.toggleLiveActivity(for: session) }
        } label: {
            Label(
                liveActivityActionTitle(isActive: facade.isLiveActivityActive(for: session)),
                systemImage: facade.isLiveActivityActive(for: session) ? "waveform.slash" : "waveform"
            )
        }
        .tint(.indigo)
    }
}

private struct SessionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct ProjectActionStrip: View {
    let facade: SessionListFacade
    let actions: [SessionListFacade.ProjectActionSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Actions", systemImage: "bolt.fill")
                    .font(.headline)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(actions) { item in
                        ProjectActionChip(
                            action: item.action,
                            command: item.command,
                            phase: item.phase
                        ) {
                            Task { await facade.runAction(item.action) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }
}

private struct ProjectActionChip: View {
    let action: OpenCodeAction
    let command: OpenCodeCommand?
    let phase: OpenCodeActionRunPhase?
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                        .frame(width: 38, height: 38)

                    if phase != nil {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: action.iconName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(tint)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(action.commandName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(command == nil ? .red : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minWidth: 148, alignment: .leading)
            .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(tint.opacity(phase == nil ? 0.12 : 0.32), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(phase != nil || command == nil)
        .accessibilityIdentifier("session.action.\(action.commandName)")
    }

    private var tint: Color {
        phase == nil ? .orange : .accentColor
    }

    private var subtitle: LocalizedStringResource {
        if let phase {
            return actionRunPhaseTitle(phase)
        }
        if command == nil {
            return "Unavailable"
        }
        return "Run action"
    }
}

private struct LockedProjectActionStrip: View {
    let onUnlock: () -> Void

    var body: some View {
        Button(action: onUnlock) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 38, height: 38)
                    .background(.orange.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Actions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("Run /commands in temporary sessions that only stick around when they need debugging.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("PRO")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.16), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ProjectUsageCTA: View {
    let facade: SessionListFacade

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Free plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(usageSummary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.84)
            }

            Spacer(minLength: 6)

            Button("Upgrade") {
                facade.presentPaywall(reason: .manual)
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("project.usage.cta")
    }

    private var usageSummary: LocalizedStringResource {
        let prompts = facade.remainingFreePromptsToday
        let sessions = facade.remainingFreeSessions
        return LocalizedStringResource(
            "Messages today: \(prompts) · Sessions left: \(sessions)",
            comment: "Free-plan usage summary with remaining messages today and remaining sessions."
        )
    }
}

private enum WorkspaceActionConfirmation: Identifiable, Equatable {
    case reset(directory: String, title: String)
    case delete(directory: String, title: String)

    var id: String {
        switch self {
        case let .reset(directory, _):
            return "reset:\(directory)"
        case let .delete(directory, _):
            return "delete:\(directory)"
        }
    }

    var message: LocalizedStringResource {
        switch self {
        case let .reset(_, title):
            return LocalizedStringResource(
                "Reset \(title) to the default branch and archive its sessions. Local changes in that worktree will be discarded.",
                comment: "Destructive worktree reset warning. The variable is the user-visible workspace name."
            )
        case let .delete(_, title):
            return LocalizedStringResource(
                "Delete \(title), remove its git worktree, and delete its branch. This cannot be undone.",
                comment: "Destructive worktree deletion warning. The variable is the user-visible workspace name."
            )
        }
    }
}

private struct SessionRowSkeleton: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(OpenCodePlatformColor.secondaryGroupedBackground)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OpenCodePlatformColor.secondaryGroupedBackground)
                    .frame(width: 150, height: 14)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(OpenCodePlatformColor.secondaryGroupedBackground)
                    .frame(width: 100, height: 12)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .redacted(reason: .placeholder)
    }
}

private struct WorkspaceSectionHeader: View {
    @State private var actionConfirmation: WorkspaceActionConfirmation?

    let section: SessionListFacade.WorkspaceSection
    let onNewSession: () -> Void
    let onCreateWorkspace: () -> Void
    let onRefresh: () -> Void
    let onResetConfirmed: (String) -> Void
    let onDeleteConfirmed: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: "arrow.triangle.branch")
                .font(.headline)

            if section.isMain {
                Text("Local")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let operation = section.operation {
                operationLabel(operation)
            } else {
                Text(URL(fileURLWithPath: section.directory).lastPathComponent)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Menu {
                Button(action: onNewSession) {
                    Label("New Session Here", systemImage: "square.and.pencil")
                }
                .disabled(section.isBusy)

                Button(action: onCreateWorkspace) {
                    Label("New Workspace", systemImage: "plus.square")
                }
                .disabled(section.isWorkspaceOperationBusy)

                Button(action: onRefresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(section.isBusy)

                if !section.isMain {
                    Divider()

                    Button {
                        actionConfirmation = .reset(directory: section.directory, title: section.title)
                    } label: {
                        Label("Reset Worktree", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(section.isWorkspaceOperationBusy)

                    Button(role: .destructive) {
                        actionConfirmation = .delete(directory: section.directory, title: section.title)
                    } label: {
                        Label("Delete Worktree", systemImage: "trash")
                    }
                    .disabled(section.isWorkspaceOperationBusy)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .opencodeGlassButton(clear: false)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Workspace Actions")
            .accessibilityIdentifier("workspace.actions.\(section.directory)")
            .confirmationDialog(
                "Manage Worktree",
                isPresented: actionConfirmationBinding,
                titleVisibility: .visible
            ) {
                if let actionConfirmation {
                    confirmationButton(for: actionConfirmation)
                }
            } message: {
                if let actionConfirmation {
                    Text(actionConfirmation.message)
                }
            }
        }
        .textCase(nil)
    }

    private var actionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { actionConfirmation != nil },
            set: { isPresented in
                if !isPresented {
                    actionConfirmation = nil
                }
            }
        )
    }

    @ViewBuilder
    private func confirmationButton(for confirmation: WorkspaceActionConfirmation) -> some View {
        switch confirmation {
        case let .reset(directory, _):
            Button("Reset Worktree", role: .destructive) {
                actionConfirmation = nil
                onResetConfirmed(directory)
            }
        case let .delete(directory, _):
            Button("Delete Worktree", role: .destructive) {
                actionConfirmation = nil
                onDeleteConfirmed(directory)
            }
        }

        Button("Cancel", role: .cancel) {
            actionConfirmation = nil
        }
    }

    @ViewBuilder
    private func operationLabel(_ operation: OpenCodeWorkspaceOperation) -> some View {
        HStack(spacing: 5) {
            if operation.isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }

            Text(operation.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(operation.isBusy ? Color.secondary : Color.red)
        }
    }
}

private struct SessionSectionHeader: View {
    let title: LocalizedStringResource
    let systemImage: String
    var accessory: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Spacer(minLength: 8)

            if let accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}

private func loadMoreTitle(isLoading: Bool) -> LocalizedStringResource {
    isLoading ? "Loading..." : "Show More"
}

private func liveActivityActionTitle(isActive: Bool) -> LocalizedStringResource {
    isActive ? "Stop Live" : "Live"
}

private func actionRunPhaseTitle(_ phase: OpenCodeActionRunPhase) -> LocalizedStringResource {
    switch phase {
    case .runningCommand: "Running command"
    case .checkingResult: "Checking result"
    }
}
