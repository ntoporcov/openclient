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

            if viewModel.funAndGamesPreferences.showsSection {
                Section("Fun & Games") {
                    ProjectRow(
                        title: "Find the Place",
                        subtitle: "Guess a secret city from live weather clues",
                        systemImage: "map.fill",
                        isSelected: false
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.presentFindPlaceModelSheet()
                    }

                    ProjectRow(
                        title: "Find the Bug",
                        subtitle: "Spot the hidden bug in a generated code snippet",
                        systemImage: "ladybug.fill",
                        isSelected: false
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.presentFindBugLanguageSheet()
                    }
                }
            }

        }
        .listStyle(.sidebar)
        .refreshable {
            await viewModel.refreshProjectList()
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem(placement: .opencodeLeading) {
                Button {
                    viewModel.disconnect()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
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
        .sheet(isPresented: $viewModel.isShowingFindPlaceModelSheet) {
            FindPlaceModelSelectionSheet(viewModel: viewModel, onGameStarted: onProjectChosen)
        }
        .sheet(isPresented: $viewModel.isShowingFindBugLanguageSheet) {
            FindBugLanguageSelectionSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.isShowingFindBugModelSheet) {
            FindBugModelSelectionSheet(viewModel: viewModel, onGameStarted: onProjectChosen)
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

private struct FindBugLanguageSelectionSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the language for the buggy snippet. These match the app's syntax highlighting support.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Languages") {
                    ForEach(FindBugGame.supportedLanguages) { language in
                        Button {
                            viewModel.selectFindBugLanguage(language)
                        } label: {
                            HStack {
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(.tint)
                                Text(language.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Find the Bug")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        viewModel.isShowingFindBugLanguageSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FindBugModelSelectionSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let onGameStarted: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the model that will generate the buggy code and judge your answer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.sortedProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), id: \.id) { model in
                            let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                            Button {
                                Task {
                                    await viewModel.startFindBugGame(model: reference)
                                    onGameStarted()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }
            }
            .navigationTitle(viewModel.pendingFindBugLanguage?.title ?? "Model")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Back") {
                        viewModel.isShowingFindBugModelSheet = false
                        viewModel.isShowingFindBugLanguageSheet = true
                    }
                }
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Cancel") {
                        viewModel.isShowingFindBugModelSheet = false
                        viewModel.pendingFindBugLanguage = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct FindPlaceModelSelectionSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let onGameStarted: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose the model that will host the game. OpenClient will start a new chat and send the private game setup automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.sortedProviders) { provider in
                    Section(provider.name) {
                        ForEach(provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), id: \.id) { model in
                            let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                            Button {
                                Task {
                                    await viewModel.startFindPlaceGame(model: reference)
                                    onGameStarted()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.tint)
                                    Text(model.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }
            }
            .navigationTitle("Find the Place")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Cancel") {
                        viewModel.isShowingFindPlaceModelSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
