import Foundation

@MainActor
final class ForegroundChatRefreshCoordinator {
    struct Context: Equatable {
        let connectionID: UUID
        let registryGeneration: Int
        let navigationGeneration: UInt
        let directoryKey: String
        let sessionID: String
        let scope: BackendScope
        let apiProfile: OpenCodeAPIProfile?
        let lifecycleRevision: UInt
    }

    private var context: Context?
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    func invalidate() {
        task?.cancel()
        task = nil
        context = nil
        requestID = nil
    }

    func schedule(context: Context, refresh: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if self.context == context, let task, !task.isCancelled { return task }
        task?.cancel()
        self.context = context
        let requestID = UUID()
        self.requestID = requestID
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.requestID == requestID {
                    self?.task = nil
                    self?.context = nil
                    self?.requestID = nil
                }
            }
            // App scene, UIKit, and chat-view activation can arrive in the same turn.
            await Task.yield()
            guard !Task.isCancelled else { return }
            await refresh()
        }
        self.task = task
        return task
    }

    deinit { task?.cancel() }
}
