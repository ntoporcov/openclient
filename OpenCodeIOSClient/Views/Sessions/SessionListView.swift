import SwiftUI

struct SessionListView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var renderStore = SessionListRenderStore()
    let onSessionChosen: () -> Void

    var body: some View {
        let snapshot = viewModel.sessionListSnapshot

        SessionListContent(
            viewModel: viewModel,
            renderStore: renderStore,
            onSessionChosen: onSessionChosen
        )
        .onAppear {
            renderStore.update(snapshot)
        }
        .onChange(of: snapshot) { _, snapshot in
            withAnimation(opencodeSelectionAnimation) {
                renderStore.update(snapshot)
            }
        }
        .sheet(isPresented: $viewModel.isShowingCreateSessionSheet) {
            CreateSessionSheet(viewModel: viewModel)
        }
    }
}

extension AppViewModel {
    fileprivate var sessionListSnapshot: SessionListDisplaySnapshot {
        let sessions = sessions
        let pinnedIDs = pinnedSessionIDs
        var sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for session in workspaceSessionsByDirectory.values.flatMap(\.rootSessions) where !isActionSession(session) {
            sessionsByID[session.id] = session
        }
        let pinnedSessions = pinnedIDs.compactMap { sessionsByID[$0] }
        let pinnedIDSet = Set(pinnedIDs)
        let unpinnedSessions = sessions.filter { !pinnedIDSet.contains($0.id) }
        let showsWorkspaces = isProjectWorkspacesEnabled && hasGitProject
        let pinnedRows = pinnedSessions.map { session in
            sessionListRowSnapshot(for: session, showsPinnedBadge: true, workspaceOverline: showsWorkspaces ? workspaceDisplayName(for: session.directory) : nil)
        }
        let unpinnedRows = unpinnedSessions.map { sessionListRowSnapshot(for: $0) }
        let workspaceSections = sessionListWorkspaceSections(excluding: pinnedIDSet)

        return SessionListDisplaySnapshot(
            isLoadingEmpty: isLoadingSessions && sessions.isEmpty,
            isEmpty: sessions.isEmpty,
            selectedSessionID: selectedSession?.id,
            pinnedRows: pinnedRows,
            unpinnedRows: unpinnedRows,
            showsWorkspaces: showsWorkspaces,
            workspaceSections: workspaceSections,
            errorMessage: errorMessage,
            hasProUnlock: hasProUnlock,
            currentProjectActions: currentProjectActions.map { action in
                ProjectActionSnapshot(
                    action: action,
                    command: actionCommand(for: action),
                    phase: actionRunPhase(for: action)
                )
            }
        )
    }

    private func sessionListWorkspaceSections(excluding pinnedIDSet: Set<String>) -> [WorkspaceSessionDisplaySection] {
        workspaceDirectories().map { directory in
            let state = workspaceSessionsByDirectory[directory] ?? OpenCodeWorkspaceSessionState()
            let sessions = state.rootSessions.filter { !pinnedIDSet.contains($0.id) && !isActionSession($0) }
            return WorkspaceSessionDisplaySection(
                directory: directory,
                title: workspaceDisplayName(for: directory) ?? URL(fileURLWithPath: directory).lastPathComponent,
                rows: sessions.map { sessionListRowSnapshot(for: $0) },
                isLoading: state.isLoading,
                hasMore: state.hasMore
            )
        }
    }

    private func sessionListRowSnapshot(
        for session: OpenCodeSession,
        showsPinnedBadge: Bool = false,
        workspaceOverline: String? = nil,
        style: SessionRow.Style = .regular
    ) -> SessionRowSnapshot {
        SessionRowSnapshot(
            session: session,
            isSelected: selectedSession?.id == session.id,
            showsPinnedBadge: showsPinnedBadge,
            workspaceOverline: workspaceOverline,
            style: style,
            preview: sessionPreviews[session.id],
            isBusy: sessionStatuses[session.id] == "busy",
            hasLiveActivity: isLiveActivityActive(for: session),
            hasDraft: hasMessageDraft(for: session),
            hasPermissionRequest: hasPermissionRequest(for: session)
        )
    }
}

private final class SessionListRenderStore: ObservableObject {
    @Published private(set) var snapshot = SessionListDisplaySnapshot.empty

    func update(_ snapshot: SessionListDisplaySnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

private struct SessionListContent: View {
    let viewModel: AppViewModel
    @ObservedObject var renderStore: SessionListRenderStore
    @Namespace private var sessionRowNamespace
    @State private var renamingSession: OpenCodeSession?
    @State private var renameTitle = ""
    let onSessionChosen: () -> Void

    var body: some View {
        let snapshot = renderStore.snapshot

        List {
            if !snapshot.hasProUnlock {
                ProjectUsageCTA(viewModel: viewModel)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if snapshot.hasProUnlock {
                if !snapshot.currentProjectActions.isEmpty {
                    ProjectActionStrip(viewModel: viewModel, actions: snapshot.currentProjectActions)
                        .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                LockedProjectActionStrip {
                    viewModel.presentPaywall(reason: .actions)
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
                        Text(snapshot.isEmpty ? "Create a session to start chatting." : "All visible sessions are pinned.")
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
                } header: {
                    SessionSectionHeader(title: "Sessions", systemImage: "bubble.left.and.bubble.right")
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
            await viewModel.refreshSessionList()
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
                Task { await viewModel.renameSession(session, title: title) }
            }
            .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Enter a new title for this session.")
        }
        .task(id: snapshot.workspaceTaskID) {
            await viewModel.loadWorkspaceSessionsIfNeeded()
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

    private func workspaceSection(_ section: WorkspaceSessionDisplaySection) -> some View {
        Section {
            if section.isLoading && section.rows.isEmpty {
                ForEach(0 ..< 2, id: \.self) { _ in
                    SessionRowSkeleton()
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
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
                    Task { await viewModel.loadMoreWorkspaceSessions(directory: section.directory) }
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        Text(section.isLoading ? "Loading..." : "Show More")
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
            SessionSectionHeader(
                title: section.title,
                systemImage: "arrow.triangle.branch",
                accessory: URL(fileURLWithPath: section.directory).lastPathComponent
            )
        }
    }

    private func movePinnedSessions(from offsets: IndexSet, to destination: Int) {
        withAnimation(opencodeSelectionAnimation) {
            viewModel.movePinnedSessions(fromOffsets: offsets, toOffset: destination)
        }
    }

    private func sessionRow(
        for row: SessionRowSnapshot
    ) -> some View {
        return SessionRow(
            session: row.session,
            isSelected: row.isSelected,
            showsPinnedBadge: row.showsPinnedBadge,
            workspaceOverline: row.workspaceOverline,
            style: row.style,
            preview: row.preview,
            isBusy: row.isBusy,
            hasLiveActivity: row.hasLiveActivity,
            hasDraft: row.hasDraft,
            hasPermissionRequest: row.hasPermissionRequest
        )
        .equatable()
        .matchedGeometryEffect(id: row.session.id, in: sessionRowNamespace)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.prepareSessionSelection(row.session)
            withAnimation(opencodeSelectionAnimation) {
                onSessionChosen()
            }
            Task {
                await viewModel.selectSession(row.session)
            }
        }
        .contextMenu {
            pinButton(for: row.session)
            deleteButton(for: row.session)
            renameButton(for: row.session)
            liveActivityButton(for: row.session)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            pinButton(for: row.session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteButton(for: row.session)
            renameButton(for: row.session)
            liveActivityButton(for: row.session)
        }
    }

    @ViewBuilder
    private func pinButton(for session: OpenCodeSession) -> some View {
        if viewModel.isSessionPinned(session) {
            Button {
                withAnimation(opencodeSelectionAnimation) {
                    viewModel.unpinSession(session)
                }
            } label: {
                Label("Unpin", systemImage: "pin.slash")
            }
            .tint(.gray)
        } else {
            Button {
                withAnimation(opencodeSelectionAnimation) {
                    viewModel.pinSession(session)
                }
            } label: {
                Label("Pin", systemImage: "pin")
            }
            .tint(.orange)
        }
    }

    private func deleteButton(for session: OpenCodeSession) -> some View {
        Button(role: .destructive) {
            Task { await viewModel.deleteSession(session) }
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
            Task { await viewModel.toggleLiveActivity(for: session) }
        } label: {
            Label(
                viewModel.isLiveActivityActive(for: session) ? "Stop Live" : "Live",
                systemImage: viewModel.isLiveActivityActive(for: session) ? "waveform.slash" : "waveform"
            )
        }
        .tint(.indigo)
    }
}

private struct ProjectActionStrip: View {
    let viewModel: AppViewModel
    let actions: [ProjectActionSnapshot]

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
                            Task { await viewModel.runAction(item.action) }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollClipDisabled()
        }
    }
}

private struct ProjectActionSnapshot: Identifiable, Equatable {
    let action: OpenCodeAction
    let command: OpenCodeCommand?
    let phase: OpenCodeActionRunPhase?

    var id: UUID { action.id }
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

    private var subtitle: String {
        if let phase {
            return phase.title
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
    let viewModel: AppViewModel

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
                viewModel.presentPaywall(reason: .manual)
            }
            .font(.caption.weight(.bold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("project.usage.cta")
    }

    private var usageSummary: String {
        let prompts = viewModel.remainingFreePromptsToday
        let sessions = viewModel.remainingFreeSessions
        return "\(prompts) \(prompts == 1 ? "message" : "messages") today, \(sessions) \(sessions == 1 ? "session" : "sessions") left"
    }
}

private struct SessionListDisplaySnapshot: Equatable {
    static let empty = SessionListDisplaySnapshot(
        isLoadingEmpty: false,
        isEmpty: true,
        selectedSessionID: nil,
        pinnedRows: [],
        unpinnedRows: [],
        showsWorkspaces: false,
        workspaceSections: [],
        errorMessage: nil,
        hasProUnlock: true,
        currentProjectActions: []
    )

    let isLoadingEmpty: Bool
    let isEmpty: Bool
    let selectedSessionID: String?
    let pinnedRows: [SessionRowSnapshot]
    let unpinnedRows: [SessionRowSnapshot]
    let showsWorkspaces: Bool
    let workspaceSections: [WorkspaceSessionDisplaySection]
    let errorMessage: String?
    let hasProUnlock: Bool
    let currentProjectActions: [ProjectActionSnapshot]

    var hasBusySession: Bool {
        pinnedRows.contains(where: \.isBusy)
            || unpinnedRows.contains(where: \.isBusy)
            || workspaceSections.contains { $0.rows.contains(where: \.isBusy) }
    }

    var workspaceTaskID: String {
        showsWorkspaces ? workspaceSections.map(\.directory).joined(separator: "|") : "off"
    }

}

private struct SessionRowSnapshot: Identifiable, Equatable {
    let session: OpenCodeSession
    let isSelected: Bool
    let showsPinnedBadge: Bool
    let workspaceOverline: String?
    let style: SessionRow.Style
    var preview: SessionPreview?
    var isBusy = false
    var hasLiveActivity = false
    var hasDraft = false
    var hasPermissionRequest = false

    var id: String { session.id }
}

private struct WorkspaceSessionDisplaySection: Identifiable, Equatable {
    let directory: String
    let title: String
    let rows: [SessionRowSnapshot]
    let isLoading: Bool
    let hasMore: Bool

    var id: String { directory }
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

private struct SessionSectionHeader: View {
    let title: String
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
