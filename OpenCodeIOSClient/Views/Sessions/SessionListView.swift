import SwiftUI

struct SessionListView: View {
    @ObservedObject var viewModel: AppViewModel
    @Namespace private var sessionRowNamespace
    @State private var renamingSession: OpenCodeSession?
    @State private var renameTitle = ""
    let onSessionChosen: () -> Void

    var body: some View {
        let snapshot = sessionListSnapshot

        List {
            if !viewModel.hasProUnlock {
                ProjectUsageCTA(viewModel: viewModel)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
            } else if !snapshot.pinnedSessions.isEmpty {
                Section {
                    ForEach(snapshot.pinnedSessions) { session in
                        pinnedSessionRow(for: session)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: movePinnedSessions)
                } header: {
                    SessionSectionHeader(title: "Pinned", systemImage: "pin.fill", accessory: "\(snapshot.pinnedSessions.count)")
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
                    } else if snapshot.unpinnedSessions.isEmpty {
                        Text(snapshot.isEmpty ? "Create a session to start chatting." : "All visible sessions are pinned.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(snapshot.unpinnedSessions) { session in
                            sessionRow(for: session)
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
        .id(snapshot.structuralID)
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OpenCodePlatformColor.groupedBackground)
        .opencodeInteractiveKeyboardDismiss()
        .sheet(isPresented: $viewModel.isShowingCreateSessionSheet) {
            CreateSessionSheet(viewModel: viewModel)
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
        .animation(opencodeSelectionAnimation, value: viewModel.selectedSession?.id)
    }

    private var sessionListSnapshot: SessionListSnapshot {
        let sessions = viewModel.sessions
        let pinnedIDs = viewModel.pinnedSessionIDs
        var sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        for session in viewModel.workspaceSessionsByDirectory.values.flatMap(\.rootSessions) {
            sessionsByID[session.id] = session
        }
        let pinnedSessions = pinnedIDs.compactMap { sessionsByID[$0] }
        let pinnedIDSet = Set(pinnedIDs)
        let unpinnedSessions = sessions.filter { !pinnedIDSet.contains($0.id) }
        let workspaceSections = workspaceSections(excluding: pinnedIDSet)

        return SessionListSnapshot(
            isLoadingEmpty: viewModel.directoryState.isLoadingSessions && sessions.isEmpty,
            isEmpty: sessions.isEmpty,
            pinnedSessions: pinnedSessions,
            unpinnedSessions: unpinnedSessions,
            showsWorkspaces: viewModel.isProjectWorkspacesEnabled && viewModel.hasGitProject,
            workspaceSections: workspaceSections,
            errorMessage: viewModel.errorMessage
        )
    }

    private func workspaceSections(excluding pinnedIDSet: Set<String>) -> [WorkspaceSessionSection] {
        viewModel.workspaceDirectories().map { directory in
            let state = viewModel.workspaceSessionsByDirectory[directory] ?? OpenCodeWorkspaceSessionState()
            let sessions = state.rootSessions.filter { !pinnedIDSet.contains($0.id) }
            return WorkspaceSessionSection(
                directory: directory,
                title: viewModel.workspaceDisplayName(for: directory) ?? URL(fileURLWithPath: directory).lastPathComponent,
                sessions: sessions,
                isLoading: state.isLoading,
                hasMore: state.hasMore
            )
        }
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

    private func pinnedSessionRow(for session: OpenCodeSession) -> some View {
        sessionRow(
            for: session,
            showsPinnedBadge: true,
            workspaceOverline: viewModel.isProjectWorkspacesEnabled ? viewModel.workspaceDisplayName(for: session.directory) : nil
        )
    }

    private func workspaceSection(_ section: WorkspaceSessionSection) -> some View {
        Section {
            if section.isLoading && section.sessions.isEmpty {
                ForEach(0 ..< 2, id: \.self) { _ in
                    SessionRowSkeleton()
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else if section.sessions.isEmpty {
                Text("No sessions in this workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(section.sessions) { session in
                    sessionRow(for: session)
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
        for session: OpenCodeSession,
        showsPinnedBadge: Bool = false,
        workspaceOverline: String? = nil,
        style: SessionRow.Style = .regular
    ) -> some View {
        SessionRow(
            viewModel: viewModel,
            session: session,
            isSelected: viewModel.selectedSession?.id == session.id,
            showsPinnedBadge: showsPinnedBadge,
            workspaceOverline: workspaceOverline,
            style: style
        )
        .matchedGeometryEffect(id: session.id, in: sessionRowNamespace)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.prepareSessionSelection(session)
            withAnimation(opencodeSelectionAnimation) {
                onSessionChosen()
            }
            Task {
                await viewModel.selectSession(session)
            }
        }
        .contextMenu {
            pinButton(for: session)
            deleteButton(for: session)
            renameButton(for: session)
            liveActivityButton(for: session)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            pinButton(for: session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteButton(for: session)
            renameButton(for: session)
            liveActivityButton(for: session)
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

private struct ProjectUsageCTA: View {
    @ObservedObject var viewModel: AppViewModel

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

private struct SessionListSnapshot {
    let isLoadingEmpty: Bool
    let isEmpty: Bool
    let pinnedSessions: [OpenCodeSession]
    let unpinnedSessions: [OpenCodeSession]
    let showsWorkspaces: Bool
    let workspaceSections: [WorkspaceSessionSection]
    let errorMessage: String?

    var workspaceTaskID: String {
        showsWorkspaces ? workspaceSections.map(\.directory).joined(separator: "|") : "off"
    }

    var structuralID: String {
        [
            isLoadingEmpty ? "loading" : "loaded",
            pinnedSessions.map(\.id).joined(separator: ","),
            unpinnedSessions.map(\.id).joined(separator: ","),
            showsWorkspaces ? "workspaces" : "flat",
            workspaceSections.map { "\($0.directory):\($0.sessions.map(\.id).joined(separator: ",")):\($0.hasMore)" }.joined(separator: ";"),
            errorMessage == nil ? "no-error" : "error"
        ].joined(separator: "|")
    }
}

private struct WorkspaceSessionSection: Identifiable, Equatable {
    let directory: String
    let title: String
    let sessions: [OpenCodeSession]
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
