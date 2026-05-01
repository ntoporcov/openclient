import SwiftUI

struct ProjectSettingsSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Sessions") {
                    Toggle("Auto-start Live Activity", isOn: Binding(
                        get: { viewModel.isLiveActivityAutoStartEnabled },
                        set: { viewModel.setLiveActivityAutoStartEnabled($0) }
                    ))

                    Text("Start a Live Activity automatically when a session begins working in this project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Workspaces") {
                    Toggle("Show Workspaces", isOn: Binding(
                        get: { viewModel.isProjectWorkspacesEnabled },
                        set: { isEnabled in
                            viewModel.setProjectWorkspacesEnabled(isEnabled)
                            if isEnabled {
                                Task { await viewModel.loadWorkspaceSessionsIfNeeded() }
                            }
                        }
                    ))
                    .disabled(!viewModel.hasGitProject)

                    Text(workspacesDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Project Settings")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        viewModel.isShowingProjectSettingsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var workspacesDescription: String {
        if viewModel.hasGitProject {
            return "Group sessions by the main worktree and any OpenCode sandbox worktrees for this project."
        }

        return "Workspaces are available for git projects."
    }
}
