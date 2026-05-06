import Combine
import Foundation

@MainActor
final class DirectoryStore: ObservableObject {
    @Published var isLoadingSessions: Bool
    @Published var sessions: [OpenCodeSession]
    @Published var selectedSession: OpenCodeSession?
    @Published var commands: [OpenCodeCommand]
    @Published var sessionStatuses: [String: String]

    init(
        isLoadingSessions: Bool = false,
        sessions: [OpenCodeSession] = [],
        selectedSession: OpenCodeSession? = nil,
        commands: [OpenCodeCommand] = [],
        sessionStatuses: [String: String] = [:]
    ) {
        self.isLoadingSessions = isLoadingSessions
        self.sessions = sessions
        self.selectedSession = selectedSession
        self.commands = commands
        self.sessionStatuses = sessionStatuses
    }

    func reset() {
        isLoadingSessions = false
        sessions = []
        selectedSession = nil
        commands = []
        sessionStatuses = [:]
    }
}
