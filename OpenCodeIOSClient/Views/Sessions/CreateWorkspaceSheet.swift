import SwiftUI

struct CreateWorkspaceSheet: View {
    @ObservedObject var facade: SessionListFacade
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var destinationParent = ""
    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Workspace") {
                    TextField("Name (optional)", text: $name)
                        .opencodeDisableTextAutocapitalization()
                        .autocorrectionDisabled()
                    if facade.supportsWorktreeDestinationParent {
                        TextField("Destination Parent Directory", text: $destinationParent)
                            .opencodeDisableTextAutocapitalization()
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("workspace.destinationParent")
                        Text("Choose an absolute path on the server. New worktrees are created inside this directory.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !facade.requiresWorktreeDestinationParent {
                            Text("Leave blank to use the server’s default worktree directory.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = facade.workspaceErrorMessage {
                    Section("Error") {
                        Text(error).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("workspace.create.error")
                    }
                }
            }
            .disabled(isCreating || !facade.allowsWorkspaceCreation)
            .navigationTitle("New Workspace")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isCreating)
                }
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        isCreating = true
                        let context = facade.workspaceCreationContextID
                        Task {
                            guard facade.workspaceCreationContextID == context, facade.allowsWorkspaceCreation else {
                                isCreating = false
                                return
                            }
                            let created = await facade.createWorkspace(name: name,
                                destinationParent: facade.supportsWorktreeDestinationParent ? destinationParent : nil)
                            isCreating = false
                            if created && facade.workspaceCreationContextID == context { dismiss() }
                        }
                    } label: {
                        if isCreating {
                            ProgressView().accessibilityLabel("Creating Worktree...")
                        } else {
                            Text("Create Workspace")
                        }
                    }
                    .accessibilityIdentifier("workspace.create.confirm")
                    .disabled(isCreating || !facade.allowsWorkspaceCreation
                        || !facade.isValidWorktreeDestination(destinationParent))
                }
            }
        }
        .onAppear { destinationParent = facade.worktreeDestinationParent }
        .onChange(of: facade.workspaceCreationContextID) { _, _ in dismiss() }
        .interactiveDismissDisabled(isCreating)
    }
}

struct WorktreeRemovalConfirmationModifier: ViewModifier {
    @ObservedObject var facade: SessionListFacade

    func body(content: Content) -> some View {
        content.confirmationDialog("Discard Changes and Remove Workspace?", isPresented: Binding(
            get: { facade.pendingWorktreeRemoval != nil },
            set: { if !$0 { facade.cancelForceWorktreeRemoval() } }
        ), titleVisibility: .visible) {
            Button("Discard Changes and Remove", role: .destructive) {
                let confirmation = facade.pendingWorktreeRemoval
                Task { await facade.confirmForceWorktreeRemoval(confirmation) }
            }
            Button("Cancel", role: .cancel) { facade.cancelForceWorktreeRemoval() }
        } message: {
            if let confirmation = facade.pendingWorktreeRemoval {
                Text(confirmation.message)
                Text("This permanently discards local changes in \(confirmation.directory). Session history is not deleted.")
            }
        }
    }
}
