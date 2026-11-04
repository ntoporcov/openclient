import Foundation

@MainActor
final class OpenClientRemoteDesktopCoordinator {
    private var task: Task<Void, Never>?

    func open(endpoint: OpenClientBridgeEndpoint, token: String, store: OpenClientRemoteDesktopStore) {
        task?.cancel()
        store.disconnect()
        store.begin()
        task = Task {
            do {
                let url = try await OpenClientRemoteDesktopClient(endpoint: endpoint).open(token: token)
                guard !Task.isCancelled else { return }
                store.opened(url)
            } catch {
                guard !Task.isCancelled else { return }
                store.failed(error)
            }
        }
    }

    func complete(_ handoff: OpenClientDesktopHandoff, outcome: String, endpoint: OpenClientBridgeEndpoint,
                  token: String, store: OpenClientRemoteDesktopStore) {
        guard !store.isBusy else { return }
        task?.cancel()
        store.begin()
        task = Task {
            do {
                try await OpenClientRemoteDesktopClient(endpoint: endpoint).complete(handoff, outcome: outcome, token: token)
                guard !Task.isCancelled else { return }
                store.finish()
            } catch {
                guard !Task.isCancelled else { return }
                store.failed(error)
            }
        }
    }

    func disconnect(store: OpenClientRemoteDesktopStore) {
        task?.cancel()
        task = nil
        store.disconnect()
    }
}
