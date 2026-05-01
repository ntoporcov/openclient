import SwiftUI

struct CreateSessionSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Session Name") {
                    TextField("Optional title", text: $viewModel.draftTitle)
                        .accessibilityIdentifier("sessions.create.title")
                }

                Section("Scope") {
                    Text(viewModel.projectScopeTitle)
                        .foregroundStyle(.secondary)
                }

                if showsWorkspacePicker {
                    Section("Workspace") {
                        Picker("Workspace", selection: $viewModel.newSessionWorkspaceSelection) {
                            Text(viewModel.newSessionWorkspaceTitle(for: .main))
                                .tag(NewSessionWorkspaceSelection.main)

                            ForEach(workspaceDirectories, id: \.self) { directory in
                                if directory != viewModel.currentProject?.worktree {
                                    Text(viewModel.newSessionWorkspaceTitle(for: .directory(directory)))
                                        .tag(NewSessionWorkspaceSelection.directory(directory))
                                }
                            }

                            Text("Create new worktree")
                                .tag(NewSessionWorkspaceSelection.createNew)
                        }

                        if viewModel.newSessionWorkspaceSelection == .createNew {
                            TextField("Worktree name (optional)", text: $viewModel.newWorkspaceName)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("sessions.create.worktree.name")

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

                if !viewModel.hasProUnlock {
                    Section("Free Plan") {
                        Text(viewModel.canCreateFreeSession ? "Your first session is included. Upgrade for unlimited sessions and prompts." : "Upgrade to create more sessions.")
                            .foregroundStyle(.secondary)

                        Button("Upgrade to Pro") {
                            viewModel.isShowingCreateSessionSheet = false
                            viewModel.presentPaywall(reason: .sessionLimit)
                        }
                    }
                }

                Section {
                    Button(createButtonTitle) {
                        Task { await viewModel.createSession() }
                    }
                    .disabled(viewModel.isLoading)
                    .accessibilityIdentifier("sessions.create.confirm")
                }
            }
            .navigationTitle("New Session")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        viewModel.isShowingCreateSessionSheet = false
                    }
                }
            }
        }
        .presentationDetents(viewModel.hasProUnlock && !showsWorkspacePicker ? [.medium] : [.large])
    }

    private var showsWorkspacePicker: Bool {
        viewModel.isProjectWorkspacesEnabled && viewModel.hasGitProject
    }

    private var workspaceDirectories: [String] {
        viewModel.workspaceDirectories()
    }

    private var selectedWorkspaceDescription: String {
        switch viewModel.newSessionWorkspaceSelection {
        case .main:
            return viewModel.currentProject?.worktree ?? viewModel.projectScopeTitle
        case let .directory(directory):
            return directory
        case .createNew:
            return ""
        }
    }

    private var createButtonTitle: String {
        if viewModel.isLoading, viewModel.newSessionWorkspaceSelection == .createNew {
            return "Creating Worktree..."
        }

        return viewModel.isLoading ? "Creating..." : "Create Session"
    }
}
