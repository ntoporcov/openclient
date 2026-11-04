import Foundation

@MainActor
final class OpenClientRemoteDesktopCoordinator {
    private var task: Task<Void, Never>?
    let native = OpenClientNativeDesktopSession()
    private var tunnel: OpenClientDesktopTunnel?
    private let credentials: OpenClientDesktopCredentialStore
    private var credentialScope: String?
    private var pendingCredentials: OpenClientDesktopCredentials?
    private var skipSavedCredentials = false
    private var submittedManualCredentials = false

    init(credentials: OpenClientDesktopCredentialStore = OpenClientDesktopCredentialStore()) {
        self.credentials = credentials
    }

    func authenticate(username: String, password: String, save: Bool) {
        submittedManualCredentials = true
        pendingCredentials = save ? OpenClientDesktopCredentials(username: username, password: password) : nil
        native.authenticate(username: username, password: password)
    }

    func forgetCredentials(store: OpenClientRemoteDesktopStore) {
        pendingCredentials = nil
        skipSavedCredentials = true
        guard let credentialScope else { return }
        do { try credentials.delete(scope: credentialScope) }
        catch { store.credentialStorageFailed(error) }
    }

    func open(endpoint: OpenClientBridgeEndpoint, access: OpenClientDesktopAccess?, store: OpenClientRemoteDesktopStore) {
        disconnect(store: store)
        store.begin()
        let tunnel = OpenClientDesktopTunnel()
        self.tunnel = tunnel
        task = Task { [self, store] in
            do {
                guard let access else { throw OpenClientDesktopAccess.AccessError.unavailable }
                let ticket = try await access.open()
                guard !Task.isCancelled else { return }
                credentialScope = access.client.config.recentServerID + ":" + ticket.targetID
                let url = try OpenClientRemoteDesktopClient(endpoint: endpoint).viewerURL(ticket: ticket.ticket)
                let port = try await tunnel.start(viewerURL: url)
                guard !Task.isCancelled else { tunnel.stop(); return }
                native.onCredentialsRequested = { [weak self, weak store] in
                    guard let self, let store, !skipSavedCredentials, let credentialScope else { return }
                    do {
                        if let saved = try credentials.load(scope: credentialScope) {
                            // At most one automatic attempt. A rejection returns to manual login
                            // on reconnect instead of looping over a stale password.
                            skipSavedCredentials = true
                            native.authenticate(username: saved.username, password: saved.password)
                        }
                    } catch { store.credentialStorageFailed(error) }
                }
                native.onConnected = { [weak self, weak store] in
                    guard let self else { return }
                    defer { pendingCredentials = nil }
                    if let pendingCredentials, let credentialScope {
                        do { try credentials.save(pendingCredentials, scope: credentialScope) }
                        catch { store?.credentialStorageFailed(error) }
                    } else if submittedManualCredentials, let credentialScope {
                        do { try credentials.delete(scope: credentialScope) }
                        catch { store?.credentialStorageFailed(error) }
                    }
                    skipSavedCredentials = false
                }
                native.onDisconnected = { [weak self] in self?.pendingCredentials = nil }
                native.start(port: port, store: store)
            } catch {
                guard !Task.isCancelled else { return }
                tunnel.stop()
                store.failed(error)
            }
        }
    }

    func complete(_ handoff: OpenClientDesktopHandoff, outcome: String, endpoint: OpenClientBridgeEndpoint,
                  access: OpenClientDesktopAccess?, store: OpenClientRemoteDesktopStore) {
        guard !store.isBusy else { return }
        task?.cancel()
        store.begin()
        task = Task {
            do {
                guard let access else { throw OpenClientDesktopAccess.AccessError.unavailable }
                try await access.complete(handoff, outcome: outcome)
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
        pendingCredentials = nil
        submittedManualCredentials = false
        task?.cancel()
        task = nil
        native.stop()
        tunnel?.stop()
        tunnel = nil
        store.disconnect()
    }
}
