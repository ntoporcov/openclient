import SwiftUI

struct CreateSessionSheet: View {
    @ObservedObject var facade: SessionListFacade
    @State private var startingSnapshot: NewSessionStartingSnapshot?

    var body: some View {
        let snapshot = facade.createSessionSnapshot

        NavigationStack {
            Group {
                if let startingSnapshot {
                    NewSessionStartingPreview(snapshot: startingSnapshot)
                        .padding(.horizontal, 24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(OpenCodePlatformColor.groupedBackground)
                } else {
                    createSessionForm
                }
            }
            .navigationTitle("New Session")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        facade.dismissCreateSession()
                    }
                    .disabled(startingSnapshot != nil)
                }
            }
        }
        .presentationDetents(snapshot.hasProUnlock && !snapshot.showsWorkspacePicker ? [.medium] : [.large])
        .task(id: facade.workspaceCreationContextID) {
            if snapshot.showsWorkspacePicker { await facade.loadWorkspaceSessionsIfNeeded() }
        }
        .onChange(of: facade.workspaceCreationContextID) { _, _ in
            startingSnapshot = nil
            facade.dismissCreateSession()
        }
    }

    private var createSessionForm: some View {
        let snapshot = facade.createSessionSnapshot

        return Form {
            Section("Session Name") {
                TextField("Optional title", text: Binding(
                    get: { facade.createSessionTitle },
                    set: { facade.createSessionTitle = $0 }
                ))
                    .accessibilityIdentifier("sessions.create.title")
            }

            Section("Scope") {
                Text(snapshot.projectScopeTitle)
                    .foregroundStyle(.secondary)
            }

            if snapshot.showsWorkspacePicker {
                Section("Workspace") {
                    Picker("Workspace", selection: Binding(
                        get: { facade.newSessionWorkspaceSelection },
                        set: { facade.newSessionWorkspaceSelection = $0 }
                    )) {
                        Text(facade.workspaceTitle(for: .main))
                            .tag(NewSessionWorkspaceSelection.main)

                        ForEach(snapshot.workspaceDirectories, id: \.self) { directory in
                            if directory != snapshot.currentProject?.worktree {
                                Text(facade.workspaceTitle(for: .directory(directory)))
                                    .tag(NewSessionWorkspaceSelection.directory(directory))
                            }
                        }

                        Text("Create new worktree")
                            .tag(NewSessionWorkspaceSelection.createNew)
                    }

                    if snapshot.workspaceSelection == .createNew {
                        TextField("Worktree name (optional)", text: Binding(
                            get: { facade.newWorkspaceName },
                            set: { facade.newWorkspaceName = $0 }
                        ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("sessions.create.worktree.name")

                        if facade.requiresWorktreeDestinationParent {
                            TextField("Destination Parent Directory", text: Binding(
                                get: { facade.worktreeDestinationParent },
                                set: { facade.worktreeDestinationParent = $0 }
                            ))
                            .opencodeDisableTextAutocapitalization()
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("sessions.create.worktree.destinationParent")
                            Text("Choose an absolute path on the server. New worktrees are created inside this directory.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Text("OpenCode will create a separate git worktree, then start this session inside it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(selectedWorkspaceDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !snapshot.hasProUnlock {
                Section("Free Plan") {
                    Text(snapshot.canCreateFreeSession ? LocalizedStringResource("Your first session is included. Upgrade for unlimited sessions and prompts.") : LocalizedStringResource("Upgrade to create more sessions."))
                        .foregroundStyle(.secondary)

                    Button("Upgrade to Pro") {
                        facade.presentSessionLimitPaywall()
                    }
                }
            }

            Section {
                Button(createButtonTitle) {
                    startCreatingSession()
                }
                .disabled(snapshot.isLoading || !hasValidWorkspaceDestination)
                .accessibilityIdentifier("sessions.create.confirm")
            }
            if let error = facade.workspaceErrorMessage {
                Section("Error") { Text(error).foregroundStyle(.red) }
            }
        }
        .disabled(facade.snapshot.isReadOnly || snapshot.isLoading)
    }

    private var hasValidWorkspaceDestination: Bool {
        let snapshot = facade.createSessionSnapshot
        guard snapshot.showsWorkspacePicker, snapshot.workspaceSelection == .createNew,
              facade.requiresWorktreeDestinationParent else { return true }
        return facade.worktreeDestinationParent.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private var selectedWorkspaceDescription: String {
        let snapshot = facade.createSessionSnapshot
        switch snapshot.workspaceSelection {
        case .main:
            return snapshot.currentProject?.worktree ?? snapshot.projectScopeTitle
        case let .directory(directory):
            return directory
        case .createNew:
            return ""
        }
    }

    private var createButtonTitle: LocalizedStringResource {
        let snapshot = facade.createSessionSnapshot
        if snapshot.isLoading, snapshot.workspaceSelection == .createNew {
            return "Creating Worktree..."
        }

        return snapshot.isLoading ? "Creating..." : "Create Session"
    }

    private func startCreatingSession() {
        guard !facade.snapshot.isReadOnly, !facade.createSessionSnapshot.isLoading, hasValidWorkspaceDestination else { return }
        let context = facade.workspaceCreationContextID
        startingSnapshot = NewSessionStartingSnapshot(
            title: submittedTitle,
            subtitle: facade.createSessionSnapshot.projectScopeTitle,
            promptPreview: nil,
            attachmentCount: 0,
            phase: facade.createSessionSnapshot.workspaceSelection == .createNew ? .creatingWorktree : .creatingSession
        )

        Task { @MainActor in
            guard facade.workspaceCreationContextID == context else { return }
            await facade.createSession()
            if facade.createSessionSnapshot.isPresented {
                startingSnapshot = nil
            }
        }
    }

    private var submittedTitle: String {
        let title = facade.createSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "New Session") : title
    }
}

enum NewSessionStartingPhase: Equatable {
    case creatingWorktree
    case creatingSession
    case sendingMessage
    case waitingForOpenCode

    var title: LocalizedStringResource {
        switch self {
        case .creatingWorktree:
            return "Creating worktree"
        case .creatingSession:
            return "Creating session"
        case .sendingMessage:
            return "Sending message"
        case .waitingForOpenCode:
            return "Waiting for OpenCode"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .creatingWorktree:
            return "Preparing a fresh workspace before the session opens."
        case .creatingSession:
            return "Setting up the session before opening chat."
        case .sendingMessage:
            return "Your first message is being added to the new session."
        case .waitingForOpenCode:
            return "OpenCode accepted the prompt. Chat will open with this message already in place."
        }
    }
}

struct NewSessionStartingSnapshot: Equatable {
    var title: String
    var subtitle: String
    var promptPreview: String?
    var attachmentCount: Int
    var phase: NewSessionStartingPhase
}

struct NewSessionStartingPreview: View {
    let snapshot: NewSessionStartingSnapshot

    @State private var hasPresentedUserBubble = false

    var body: some View {
        Group {
            if showsChatPreview {
                chatLikePreview
            } else {
                sessionOnlyPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard showsChatPreview else { return }
            hasPresentedUserBubble = false
            withAnimation(.snappy(duration: 0.42, extraBounce: 0.04)) {
                hasPresentedUserBubble = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sessions.create.startingPreview")
    }

    private var showsChatPreview: Bool {
        guard let promptPreview = snapshot.promptPreview else { return snapshot.attachmentCount > 0 }
        return !promptPreview.isEmpty || snapshot.attachmentCount > 0
    }

    private var chatLikePreview: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                pendingUserBubble(text: snapshot.promptPreview ?? "")
                    .offset(y: hasPresentedUserBubble ? 0 : 220)
                    .opacity(hasPresentedUserBubble ? 1 : 0.78)
                    .scaleEffect(hasPresentedUserBubble ? 1 : 0.96, anchor: .bottomTrailing)

                ThinkingRow(animateEntry: true)
                    .padding(.top, 2)
                    .opacity(hasPresentedUserBubble ? 1 : 0)
            }
            .frame(maxWidth: 430)
            .padding(.top, 18)

            Spacer(minLength: 0)
        }
    }

    private var sessionOnlyPreview: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Text(snapshot.phase.title)
                    .font(.title3.weight(.semibold))

                Text(snapshot.phase.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            ThinkingRow(animateEntry: true)
                .frame(maxWidth: 430)

            Spacer(minLength: 0)
        }
    }

    private func pendingUserBubble(text: String) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            Spacer(minLength: 44)

            VStack(alignment: .trailing, spacing: 8) {
                if !text.isEmpty {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }

                if snapshot.attachmentCount > 0 {
                    Label(attachmentLabel, systemImage: "paperclip")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var attachmentLabel: LocalizedStringResource {
        if snapshot.attachmentCount == 1 {
            return "1 attachment"
        }
        return LocalizedStringResource(
            "\(snapshot.attachmentCount) attachments",
            comment: "Attachment count shown while a new session starts."
        )
    }
}
