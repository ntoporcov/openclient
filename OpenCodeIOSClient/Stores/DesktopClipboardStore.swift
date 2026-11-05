import Combine
import Foundation

struct DesktopClipboardItem: Identifiable, Equatable {
    let id: UUID
    let text: String
    let capturedAt: Date
}

/// In-memory, server/account-scoped history, retained when the viewer closes.
@MainActor
final class DesktopClipboardHistory: ObservableObject {
    static let maximumItems = 40
    static let maximumTextBytes = 65_536
    @Published private(set) var items: [DesktopClipboardItem] = []
    private(set) var targetID: String?

    func activate(targetID: String) {
        guard self.targetID != targetID else { return }
        self.targetID = targetID
        items = []
    }

    func capture(_ text: String, targetID: String, now: Date = .now) {
        guard self.targetID == targetID,
              !text.isEmpty, text.utf8.count <= Self.maximumTextBytes,
              items.first?.text != text else { return }
        var updated = items.filter { $0.text != text }
        updated.insert(DesktopClipboardItem(id: UUID(), text: text, capturedAt: now), at: 0)
        items = Array(updated.prefix(Self.maximumItems))
    }

    func clear() { items = [] }
}

@MainActor
final class DesktopClipboardStore {
    private var histories: [String: DesktopClipboardHistory] = [:]

    func history(serverID: String) -> DesktopClipboardHistory {
        if let history = histories[serverID] { return history }
        let history = DesktopClipboardHistory()
        histories[serverID] = history
        return history
    }
}
