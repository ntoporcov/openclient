import Foundation

@MainActor
final class OpenClientRemoteDesktopCoordinator {
    private var task: Task<Void, Never>?
    let native = OpenClientNativeDesktopSession()
    private var tunnel: OpenClientDesktopTunnel?

    func open(endpoint: OpenClientBridgeEndpoint, token: String, store: OpenClientRemoteDesktopStore) {
        disconnect(store: store)
        store.begin()
        let tunnel = OpenClientDesktopTunnel()
        self.tunnel = tunnel
        task = Task {
            do {
                let url = try await OpenClientRemoteDesktopClient(endpoint: endpoint).open(token: token)
                guard !Task.isCancelled else { return }
                let port = try await tunnel.start(viewerURL: url)
                guard !Task.isCancelled else { tunnel.stop(); return }
                native.start(port: port, store: store)
            } catch {
                guard !Task.isCancelled else { return }
                tunnel.stop()
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
                native.stop()
                tunnel?.stop()
            } catch {
                guard !Task.isCancelled else { return }
                native.stop()
                tunnel?.stop()
                store.failed(error)
            }
        }
    }

    func disconnect(store: OpenClientRemoteDesktopStore) {
        task?.cancel()
        task = nil
        native.stop()
        tunnel?.stop()
        tunnel = nil
        store.disconnect()
    }
}
