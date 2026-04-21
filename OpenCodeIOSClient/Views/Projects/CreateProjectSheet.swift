import SwiftUI

struct CreateProjectSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            List {
                Section("Directory") {
                    TextField("Search under \(viewModel.defaultSearchRoot)", text: $viewModel.createProjectQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: viewModel.createProjectQuery) { _, _ in
                            Task { await viewModel.searchCreateProjectDirectories() }
                        }
                }

                if let selectedDirectory = viewModel.createProjectSelectedDirectory {
                    Section("Selected Directory") {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                Task { await viewModel.createProject(from: selectedDirectory) }
                            } label: {
                                ProjectRow(
                                    title: viewModel.createProjectResultPath(selectedDirectory).split(separator: "/").last.map(String.init) ?? selectedDirectory,
                                    subtitle: viewModel.createProjectResultPath(selectedDirectory),
                                    systemImage: "folder.badge.plus",
                                    isSelected: true
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)

                            Button(viewModel.isLoading ? "Selecting..." : "Select") {
                                Task { await viewModel.createProject(from: selectedDirectory) }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isLoading)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Directories") {
                    if viewModel.createProjectResults.isEmpty {
                        Text("No directories found")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.createProjectResults, id: \.self) { directory in
                            Button {
                                Task { await viewModel.selectCreateProjectDirectory(directory) }
                            } label: {
                                let displayPath = viewModel.createProjectResultPath(directory)
                                ProjectRow(
                                    title: displayPath.split(separator: "/").last.map(String.init) ?? displayPath,
                                    subtitle: displayPath,
                                    systemImage: "folder.badge.plus",
                                    isSelected: viewModel.createProjectSelectedDirectory == directory
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                        }
                    }
                }
            }
            .navigationTitle("Create Project")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if viewModel.createProjectResults.isEmpty {
                    Task { await viewModel.searchCreateProjectDirectories() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        viewModel.isShowingCreateProjectSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
