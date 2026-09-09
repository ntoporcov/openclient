import Combine
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    static let listPreferencesStorageKey = "opencode.projectListPreferences.v1"

    @Published var projects: [OpenCodeProject]
    @Published var currentProject: OpenCodeProject?
    @Published var selectedDirectory: String?
    @Published var defaultServerDirectory: String?
    @Published var selectedContentTab: OpenClientProjectContentTab
    @Published var isShowingProjectPicker: Bool
    @Published var searchQuery: String
    @Published var searchResults: [String]
    @Published var isShowingCreateProjectSheet: Bool
    @Published var createProjectQuery: String
    @Published var createProjectResults: [String]
    @Published var createProjectSelectedDirectory: String?
    @Published private var listPreferencesByScope: [String: ListPreferences]
    @Published private(set) var worktreeInventories: [BackendWorktreeInventoryKey: [BackendWorktree]] = [:]
    @Published var worktreeDestinationParents: [BackendWorktreeInventoryKey: String] = [:]
    @Published private(set) var creatingWorktrees: Set<BackendWorktreeInventoryKey> = []
    private var worktreeInventoryRequests: [BackendWorktreeInventoryKey: UUID] = [:]
    private(set) var worktreeReadinessRevision: UInt = 0
    private var worktreeReadiness: [String: (connectionID: UUID, revision: UInt, error: String?)] = [:]
    private(set) var resolvedProjectScopes: [BackendWorktreeInventoryKey: BackendScope] = [:]
    private(set) var canonicalProjectDirectories: [BackendWorktreeInventoryKey: String] = [:]
    private var selectedProjectDirectories: [BackendWorktreeInventoryKey: String] = [:]
    var directorySearchRequestID: UUID?

    func rememberProjectResolution(_ resolution: BackendProjectResolution, connectionID: UUID) {
        let key = BackendWorktreeInventoryKey(connectionID: connectionID, projectID: resolution.project.id)
        resolvedProjectScopes[key] = resolution.scope
        canonicalProjectDirectories[key] = resolution.canonicalDirectory
        selectedProjectDirectories[key] = resolution.project.worktree
    }

    func preservingSelectedDirectory(_ project: OpenCodeProject, connectionID: UUID) -> OpenCodeProject {
        let key = BackendWorktreeInventoryKey(connectionID: connectionID, projectID: project.id)
        guard let directory = selectedProjectDirectories[key], directory != project.worktree else { return project }
        return OpenCodeProject(id: project.id, worktree: directory, vcs: project.vcs, name: project.name,
                               sandboxes: project.sandboxes, icon: project.icon, time: project.time)
    }

    func beginWorktreeInventoryRequest(for key: BackendWorktreeInventoryKey) -> UUID {
        let request = UUID()
        worktreeInventoryRequests[key] = request
        return request
    }

    func isWorktreeInventoryRequestCurrent(_ requestID: UUID, for key: BackendWorktreeInventoryKey) -> Bool {
        worktreeInventoryRequests[key] == requestID
    }

    func recordWorktreeReadiness(directory: String, connectionID: UUID, error: String?) {
        worktreeReadinessRevision &+= 1
        worktreeReadiness[directory] = (connectionID, worktreeReadinessRevision, error)
    }

    func worktreeReadinessEvent(directory: String, connectionID: UUID, after revision: UInt) -> (error: String?, revision: UInt)? {
        guard let event = worktreeReadiness[directory], event.connectionID == connectionID, event.revision > revision else { return nil }
        return (event.error, event.revision)
    }

    @discardableResult
    func applyWorktreeInventory(_ entries: [BackendWorktree], for key: BackendWorktreeInventoryKey, requestID: UUID) -> Bool {
        guard worktreeInventoryRequests[key] == requestID else { return false }
        setWorktreeInventory(entries, for: key)
        return true
    }

    func setWorktreeInventory(_ entries: [BackendWorktree], for key: BackendWorktreeInventoryKey) {
        worktreeInventoryRequests[key] = UUID()
        var seen = Set<String>()
        worktreeInventories[key] = entries.filter { seen.insert($0.directory).inserted }
    }

    func beginWorktreeCreation(for key: BackendWorktreeInventoryKey) -> Bool {
        creatingWorktrees.insert(key).inserted
    }

    func finishWorktreeCreation(for key: BackendWorktreeInventoryKey) {
        creatingWorktrees.remove(key)
    }

    func resetWorktreeInventory() {
        worktreeInventories = [:]
        worktreeInventoryRequests = [:]
        worktreeDestinationParents = [:]
        creatingWorktrees = []
        resolvedProjectScopes = [:]
        canonicalProjectDirectories = [:]
        selectedProjectDirectories = [:]
        worktreeReadiness = [:]
        worktreeReadinessRevision &+= 1
        directorySearchRequestID = nil
    }

    private let userDefaults: UserDefaults

    init(
        projects: [OpenCodeProject] = [],
        currentProject: OpenCodeProject? = nil,
        selectedDirectory: String? = nil,
        selectedContentTab: OpenClientProjectContentTab = .sessions,
        isShowingProjectPicker: Bool = false,
        searchQuery: String = "",
        searchResults: [String] = [],
        isShowingCreateProjectSheet: Bool = false,
        createProjectQuery: String = "",
        createProjectResults: [String] = [],
        createProjectSelectedDirectory: String? = nil,
        userDefaults: UserDefaults = .standard
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
        self.userDefaults = userDefaults
        self.listPreferencesByScope = Self.loadListPreferences(userDefaults: userDefaults)
    }

    func orderedProjects(scopeKey: String) -> [OpenCodeProject] {
        let projectsByID = projects.reduce(into: [String: OpenCodeProject]()) { result, project in
            result[project.id] = project
        }
        let preferredOrder = listPreferencesByScope[scopeKey]?.orderedIDs ?? []
        var seen = Set<String>()
        var ordered = preferredOrder.compactMap { id -> OpenCodeProject? in
            guard seen.insert(id).inserted else { return nil }
            return projectsByID[id]
        }
        ordered.append(contentsOf: projects.filter { seen.insert($0.id).inserted })
        return ordered
    }

    func visibleProjects(scopeKey: String) -> [OpenCodeProject] {
        orderedProjects(scopeKey: scopeKey).filter { isProjectVisible($0, scopeKey: scopeKey) }
    }

    func isProjectVisible(_ project: OpenCodeProject, scopeKey: String) -> Bool {
        listPreferencesByScope[scopeKey]?.hiddenIDs.contains(project.id) != true
    }

    func setProjectVisibility(_ project: OpenCodeProject, isVisible: Bool, scopeKey: String) {
        var preferences = listPreferencesByScope[scopeKey] ?? ListPreferences()
        if isVisible {
            preferences.hiddenIDs.remove(project.id)
        } else {
            preferences.hiddenIDs.insert(project.id)
        }
        setListPreferences(preferences, scopeKey: scopeKey)
    }

    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int, scopeKey: String) {
        var orderedIDs = orderedProjects(scopeKey: scopeKey).map(\.id)
        let validOffsets = source.filter { orderedIDs.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }

        let movingIDs = validOffsets.map { orderedIDs[$0] }
        for offset in validOffsets.reversed() {
            orderedIDs.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.lazy.filter { $0 < destination }.count
        let insertionIndex = min(max(0, destination - removedBeforeDestination), orderedIDs.count)
        orderedIDs.insert(contentsOf: movingIDs, at: insertionIndex)

        var preferences = listPreferencesByScope[scopeKey] ?? ListPreferences()
        let unavailableIDs = preferences.orderedIDs.filter { !orderedIDs.contains($0) }
        preferences.orderedIDs = orderedIDs + unavailableIDs
        setListPreferences(preferences, scopeKey: scopeKey)
    }

    private func setListPreferences(_ preferences: ListPreferences, scopeKey: String) {
        listPreferencesByScope[scopeKey] = preferences
        guard let data = try? JSONEncoder().encode(listPreferencesByScope) else { return }
        userDefaults.set(data, forKey: Self.listPreferencesStorageKey)
    }

    private static func loadListPreferences(userDefaults: UserDefaults) -> [String: ListPreferences] {
        guard let data = userDefaults.data(forKey: listPreferencesStorageKey),
              let preferences = try? JSONDecoder().decode([String: ListPreferences].self, from: data) else {
            return [:]
        }
        return preferences
    }
}

private struct ListPreferences: Codable {
    var orderedIDs: [String] = []
    var hiddenIDs: Set<String> = []
}
