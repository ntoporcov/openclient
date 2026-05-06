import Combine
import Foundation

@MainActor
final class LiveActivityStore: ObservableObject {
    @Published var activeSessionIDs: Set<String>
    @Published var activeChatSessionID: String?

    init(activeSessionIDs: Set<String> = [], activeChatSessionID: String? = nil) {
        self.activeSessionIDs = activeSessionIDs
        self.activeChatSessionID = activeChatSessionID
    }
}
