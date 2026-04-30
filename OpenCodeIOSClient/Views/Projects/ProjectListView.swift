import SwiftUI

struct ProjectListView: View {
    @ObservedObject var viewModel: AppViewModel
    let onProjectChosen: () -> Void

    var body: some View {
        let projectIDs = viewModel.projects.map { $0.id }.joined(separator: "|")

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
                        viewModel.currentProject = project
                        viewModel.prepareDirectorySelection(project.id == "global" ? nil : project.worktree)
                        withAnimation(opencodeSelectionAnimation) {
                            onProjectChosen()
                        }
                        Task {
                            await viewModel.selectProject(project)
                        }
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .opencodeLeading) {
                Button {
                    viewModel.disconnect()
                } label: {
                    Label("Servers", systemImage: "chevron.left")
                        .labelStyle(.titleAndIcon)
                }
                .accessibilityLabel("Disconnect")
                .accessibilityIdentifier("projects.disconnect")
            }

            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    viewModel.presentConfigurationsSheet()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Configurations")
                .accessibilityIdentifier("projects.configurations")
            }

            ToolbarItem(placement: .opencodeTrailing) {
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
        .sheet(isPresented: $viewModel.isShowingConfigurationsSheet) {
            ConfigurationsSheet(viewModel: viewModel)
        }
        .animation(opencodeSelectionAnimation, value: viewModel.selectedDirectory)
        .animation(opencodeSelectionAnimation, value: projectIDs)
    }

    private func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" {
            return "Global"
        }
        return project.name ?? project.worktree.split(separator: "/").last.map(String.init) ?? project.worktree
    }
}
