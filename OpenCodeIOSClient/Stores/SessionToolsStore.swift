import Combine
import Foundation

@MainActor
final class SessionToolsStore: ObservableObject {
    @Published private(set) var diffs: [OpenCodeTurnFileDiff] = []
    @Published private(set) var directories: [String] = []
    @Published private(set) var selectedDirectory: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isMoving = false
    @Published private(set) var errorMessage: String?
    private var requestID: UUID?

    func beginRead() -> UUID {
        let id = UUID()
        requestID = id
        isLoading = true
        errorMessage = nil
        selectedDirectory = nil
        return id
    }

    func finishRead(_ id: UUID, diffs: [OpenCodeTurnFileDiff]? = nil, search: BackendDirectorySearch? = nil, error: Error? = nil) {
        guard requestID == id else { return }
        requestID = nil
        isLoading = false
        self.diffs = diffs ?? []
        directories = search?.directories ?? []
        selectedDirectory = search?.selectedDirectory
        errorMessage = error?.localizedDescription
    }

    func beginMove() -> Bool {
        guard !isMoving, !isLoading else { return false }
        isMoving = true
        errorMessage = nil
        return true
    }

    func finishMove(error: Error? = nil) {
        isMoving = false
        errorMessage = error?.localizedDescription
    }
}
