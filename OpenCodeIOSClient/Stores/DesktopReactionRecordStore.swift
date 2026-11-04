import Combine
import Foundation

@MainActor
final class DesktopReactionRecordStore: ObservableObject {
    @Published private(set) var bestMilliseconds: Int?
    private let defaults: UserDefaults
    private static let key = "remoteDesktop.bestReactionMilliseconds"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.key)
        bestMilliseconds = saved > 0 ? saved : nil
    }

    func record(milliseconds: Int) {
        guard milliseconds > 0, milliseconds < (bestMilliseconds ?? Int.max) else { return }
        bestMilliseconds = milliseconds
        defaults.set(milliseconds, forKey: Self.key)
    }
}
