import SwiftUI

struct ProjectListView: View {
    @ObservedObject var viewModel: AppViewModel
    let onProjectChosen: () -> Void

    var body: some View {
        List {
            Section("Projects") {
                ForEach(viewModel.projects) { project in
                    ProjectRow(
                        title: projectTitle(project),
                        subtitle: project.id == "global" ? "Shared sessions across the current server context" : project.worktree,
                        systemImage: project.id == "global" ? "globe" : "folder.fill",
                        isSelected: viewModel.isProjectSelected(project)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task {
                            await viewModel.selectProject(project)
                            onProjectChosen()
                        }
                    }
                }
            }

            Section {
                Button("Disconnect", role: .destructive) {
                    viewModel.disconnect()
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.presentCreateProjectSheet()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create Project")
                .accessibilityIdentifier("projects.create")
            }
        }
        .sheet(isPresented: $viewModel.isShowingCreateProjectSheet) {
            CreateProjectSheet(viewModel: viewModel)
        }
    }

    private func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" {
            return "Global"
        }
        return project.name ?? project.worktree.split(separator: "/").last.map(String.init) ?? project.worktree
    }
}
