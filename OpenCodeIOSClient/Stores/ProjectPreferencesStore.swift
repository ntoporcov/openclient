import Combine
import Foundation

@MainActor
final class ProjectPreferencesStore: ObservableObject {
    @Published var liveActivityAutoStartByScope: [String: Bool]
    @Published var projectWorkspacesEnabledByScope: [String: Bool]
    @Published var projectActionsByScope: [String: [OpenCodeAction]]

    init(
        liveActivityAutoStartByScope: [String: Bool] = [:],
        projectWorkspacesEnabledByScope: [String: Bool] = [:],
        projectActionsByScope: [String: [OpenCodeAction]] = [:]
    ) {
        self.liveActivityAutoStartByScope = liveActivityAutoStartByScope
        self.projectWorkspacesEnabledByScope = projectWorkspacesEnabledByScope
        self.projectActionsByScope = projectActionsByScope
    }
}
