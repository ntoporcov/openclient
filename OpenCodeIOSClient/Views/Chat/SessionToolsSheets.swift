import SwiftUI

struct TurnChangesRequest: Identifiable {
    let scope: ChatFacade.HeaderScope
    let promptID: String
    var id: String { "\(scope.id):\(promptID)" }
}

struct TurnChangesSheet: View {
    @ObservedObject var facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    let promptID: String
    @StateObject private var store = SessionToolsStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView()
                } else if let error = store.errorMessage {
                    ContentUnavailableView {
                        Label("Could Not Load Changes", systemImage: "exclamationmark.triangle")
                    } description: { Text(verbatim: error) } actions: {
                        Button("Retry") { Task { await facade.loadTurnChanges(scope: scope, promptID: promptID, store: store) } }
                    }
                } else if store.diffs.isEmpty {
                    ContentUnavailableView("No Recorded Changes", systemImage: "doc.text.magnifyingglass",
                        description: Text("This turn has no recorded file changes. Snapshot capture may be unavailable."))
                } else {
                    List(store.diffs) { diff in
                        NavigationLink {
                            OpenCodeUnifiedDiffView(diff: .init(file: diff.file, patch: diff.patch,
                                additions: diff.additions, deletions: diff.deletions, status: diff.status))
                                .navigationTitle(diff.file)
                                .opencodeInlineNavigationTitle()
                        } label: {
                            HStack {
                                Text(verbatim: diff.file).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text("+\(diff.additions)").foregroundStyle(.green)
                                Text("-\(diff.deletions)").foregroundStyle(.red)
                            }
                            .font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle("Turn Changes")
            .opencodeInlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await facade.loadTurnChanges(scope: scope, promptID: promptID, store: store) }
        }
        .onChange(of: facade.promptContextID) { dismiss() }
        .onChange(of: facade.promptConnectionID) { dismiss() }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { dismiss() } }
        .presentationDetents([.large])
    }
}

struct MoveSessionSheet: View {
    @ObservedObject var facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    @StateObject private var store = SessionToolsStore()
    @State private var query = ""
    @State private var searchedQuery: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServerDirectoryPickerContent(query: $query, searchRoot: facade.sessionDirectorySearchRoot,
                directories: store.directories, selectedDirectory: store.selectedDirectory,
                isLoading: store.isLoading || store.isMoving, errorMessage: store.errorMessage,
                selectionEnabled: facade.supportsSessionTools(scope) && searchedQuery == query
                    && store.selectedDirectory != scope.session.directory,
                actionTitle: "Move Session", systemImage: "folder",
                displayPath: { $0 },
                onBrowse: { directory in query = directory.hasSuffix("/") ? directory : directory + "/" },
                onSelect: { directory in
                    Task { if await facade.moveSession(scope: scope, directory: directory, store: store) { dismiss() } }
                })
                .safeAreaInset(edge: .bottom) {
                    Text("If the session is working, it moves after the current turn. Project files are not moved.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                        .background(.regularMaterial)
                }
                .navigationTitle("Move Session")
                .opencodeInlineNavigationTitle()
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(store.isMoving) } }
                .task(id: query) {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    await facade.searchSessionMoveDirectories(scope: scope, query: query, store: store)
                    if !Task.isCancelled { searchedQuery = query }
                }
        }
        .interactiveDismissDisabled(store.isMoving)
        .onChange(of: facade.promptContextID) { dismiss() }
        .onChange(of: facade.promptConnectionID) { dismiss() }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { dismiss() } }
        .presentationDetents([.medium, .large])
    }
}
