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
                    Button(viewModel.isLoading ? "Creating..." : "Create Session") {
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
        .presentationDetents(viewModel.hasProUnlock ? [.medium] : [.large])
    }
}
