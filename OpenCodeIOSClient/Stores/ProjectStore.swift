import Combine
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [OpenCodeProject]
    @Published var currentProject: OpenCodeProject?
    @Published var selectedDirectory: String?
    @Published var selectedContentTab: AppViewModel.ProjectContentTab
    @Published var isShowingProjectPicker: Bool
    @Published var searchQuery: String
    @Published var searchResults: [String]
    @Published var isShowingCreateProjectSheet: Bool
    @Published var createProjectQuery: String
    @Published var createProjectResults: [String]
    @Published var createProjectSelectedDirectory: String?

    init(
        projects: [OpenCodeProject] = [],
        currentProject: OpenCodeProject? = nil,
        selectedDirectory: String? = nil,
        selectedContentTab: AppViewModel.ProjectContentTab = .sessions,
        isShowingProjectPicker: Bool = false,
        searchQuery: String = "",
        searchResults: [String] = [],
        isShowingCreateProjectSheet: Bool = false,
        createProjectQuery: String = "",
        createProjectResults: [String] = [],
        createProjectSelectedDirectory: String? = nil
    ) {
        self.projects = projects
        self.currentProject = currentProject
        self.selectedDirectory = selectedDirectory
        self.selectedContentTab = selectedContentTab
        self.isShowingProjectPicker = isShowingProjectPicker
        self.searchQuery = searchQuery
        self.searchResults = searchResults
        self.isShowingCreateProjectSheet = isShowingCreateProjectSheet
        self.createProjectQuery = createProjectQuery
        self.createProjectResults = createProjectResults
        self.createProjectSelectedDirectory = createProjectSelectedDirectory
    }
}
