import SwiftUI

struct CreateProjectSheet: View {
    @ObservedObject var facade: ProjectFacade

    var body: some View {
        let snapshot = facade.createProjectSnapshot
        NavigationStack {
            ServerDirectoryPickerContent(query: Binding(
                get: { facade.createProjectQuery }, set: { facade.createProjectQuery = $0 }),
                searchRoot: snapshot.defaultSearchRoot, directories: snapshot.results,
                selectedDirectory: snapshot.selectedDirectory, isLoading: snapshot.isLoading,
                errorMessage: snapshot.errorMessage,
                actionTitle: snapshot.isLoading ? "Selecting..." : "Select",
                displayPath: facade.createProjectResultPath,
                onBrowse: { directory in Task { await facade.selectCreateProjectDirectory(directory) } },
                onSelect: { directory in Task { await facade.createProject(from: directory) } })
                .navigationTitle("Add Project")
                .opencodeInlineNavigationTitle()
                .task(id: facade.createProjectQuery) {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    await facade.searchCreateProjectDirectories()
                }
                .toolbar {
                    ToolbarItem(placement: .opencodeLeading) {
                        Button("Cancel") { facade.dismissCreateProject() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}
