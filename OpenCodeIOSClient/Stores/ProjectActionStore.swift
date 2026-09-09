import Combine
import Foundation

struct ProjectActionScope: Codable, Hashable, Sendable {
    let backendID: String
    let contractID: String
    let projectID: String?
    let directory: String?
    let workspaceID: String?

    var backendScope: BackendScope {
        .init(projectID: projectID, directory: directory, workspaceID: workspaceID)
    }
}

struct ProjectActionRun: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case creating, runningCommand, checkingResult, succeeded, failed, interrupted

        var isRunning: Bool {
            self == .creating || self == .runningCommand || self == .checkingResult
        }
    }

    let id: String
    let actionID: UUID
    let commandName: String
    let scope: ProjectActionScope
    let createdAt: Date
    let commandMessageID: String
    let evaluationMessageID: String
    var sessionID: String?
    var state: State = .creating
    var revealed = false
    var requiresAttention = false

    var isHidden: Bool {
        sessionID != nil && !revealed && !requiresAttention && (state.isRunning || state == .succeeded)
    }

    var phase: OpenCodeActionRunPhase? {
        switch state {
        case .creating, .runningCommand: .runningCommand
        case .checkingResult: .checkingResult
        default: nil
        }
    }
}

@MainActor
final class ProjectActionStore: ObservableObject {
    @Published private(set) var runs: [ProjectActionRun]
    private let defaults: UserDefaults
    private let journalKey: String

    init(defaults: UserDefaults = .standard, journalKey: String = "openclient.project-action-journal.v1") {
        self.defaults = defaults
        self.journalKey = journalKey
        runs = defaults.data(forKey: journalKey)
            .flatMap { try? JSONDecoder().decode([ProjectActionRun].self, from: $0) } ?? []
        // An interrupted process cannot prove completion. Keep its server session visible.
        for index in runs.indices where runs[index].state.isRunning {
            runs[index].state = .interrupted
            runs[index].revealed = true
        }
        persist()
    }

    /// Synchronous reservation before the first network await prevents duplicate creates.
    func begin(action: OpenCodeAction, scope: ProjectActionScope) -> ProjectActionRun? {
        guard !runs.contains(where: { $0.scope == scope && $0.actionID == action.id && $0.state.isRunning }) else { return nil }
        let run = ProjectActionRun(
            id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            actionID: action.id, commandName: action.commandName, scope: scope, createdAt: Date(),
            commandMessageID: OpenCodeIdentifier.message(), evaluationMessageID: OpenCodeIdentifier.message()
        )
        runs.append(run)
        persist()
        return run
    }

    func run(id: String) -> ProjectActionRun? { runs.first { $0.id == id } }

    func update(id: String, _ mutation: (inout ProjectActionRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        mutation(&runs[index])
        persist()
    }

    func reveal(id: String, needsAttention: Bool = false) {
        update(id: id) {
            $0.revealed = true
            $0.requiresAttention = $0.requiresAttention || needsAttention
        }
    }

    /// One policy for Session, Home, Search and Activity. Titles are never ownership proof.
    func isHidden(sessionID: String, backendID: String, contractID: String) -> Bool {
        runs.contains {
            $0.scope.backendID == backendID && $0.scope.contractID == contractID
                && $0.sessionID == sessionID && $0.isHidden
        }
    }

    func hiddenSessionIDs(backendID: String, contractID: String) -> Set<String> {
        Set(runs.filter { $0.scope.backendID == backendID && $0.scope.contractID == contractID && $0.isHidden }.compactMap(\.sessionID))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        defaults.set(data, forKey: journalKey)
    }
}
