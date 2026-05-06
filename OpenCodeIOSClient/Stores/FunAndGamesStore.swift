import Combine
import Foundation

@MainActor
final class FunAndGamesStore: ObservableObject {
    @Published var preferences: FunAndGamesPreferences
    @Published var findPlaceSessionsByID: [String: FindPlaceGameSession]
    @Published var findBugSessionsByID: [String: FindBugGameSession]
    @Published var pendingFindBugLanguage: FindBugGameLanguage?

    init(
        preferences: FunAndGamesPreferences = FunAndGamesPreferences(),
        findPlaceSessionsByID: [String: FindPlaceGameSession] = [:],
        findBugSessionsByID: [String: FindBugGameSession] = [:],
        pendingFindBugLanguage: FindBugGameLanguage? = nil
    ) {
        self.preferences = preferences
        self.findPlaceSessionsByID = findPlaceSessionsByID
        self.findBugSessionsByID = findBugSessionsByID
        self.pendingFindBugLanguage = pendingFindBugLanguage
    }
}
