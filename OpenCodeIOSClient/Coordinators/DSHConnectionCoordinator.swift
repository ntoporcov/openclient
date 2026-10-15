import Foundation

/// Connection intent, credential persistence, and the injected DSH factory share
/// one lifetime. The normal app connection coordinator still owns bootstrap.
@MainActor
final class DSHConnectionCoordinator: BackendFactory {
    let store = DSHConnectionStore()
    private let credentials: any DSHCredentialPersisting
    private let makeConnection: @MainActor (DSHCredential) async throws -> BackendConnection
    private weak var connection: ConnectionFacade?
    private var saved: DSHCredential?
    private var candidate: DSHCredential?
    private var generation = UUID()
    private var attemptedAutomaticConnection = false
    private var factoryError: DSHLoginError?
    private var connectionTask: Task<Void, Never>?

    init(credentials: any DSHCredentialPersisting = DSHCredentialStore(),
         makeConnection: @escaping @MainActor (DSHCredential) async throws -> BackendConnection = { credential in
             try await DSHBackendFactory(configuration: credential.configuration).connect()
         }) {
        self.credentials = credentials
        self.makeConnection = makeConnection
        do { saved = try credentials.load(); store.savedServer(saved) }
        catch { store.finish(error: .storage) }
    }

    func attach(_ connection: ConnectionFacade) { self.connection = connection }

    func prepareEditor(editingSaved: Bool) {
        guard !store.isBusy else { return }
        store.clearInput()
        store.finish()
        guard editingSaved, let saved else { store.usesPasswordLogin = false; return }
        store.launchURLInput = saved.baseURL.absoluteString
        store.usesPasswordLogin = saved.username != nil
        store.usernameInput = saved.username ?? ""
        store.passwordInput = saved.password ?? ""
        store.tokenInput = saved.token
        store.nameInput = store.savedName
        store.iconInput = store.savedIcon
    }

    func connect() async throws -> BackendConnection {
        let lifetime = generation
        guard let credential = candidate ?? saved else { throw DSHLoginError.invalidLink }
        do {
            let backend = try await makeConnection(credential)
            guard generation == lifetime, !Task.isCancelled else { backend.close(); throw CancellationError() }
            return backend
        } catch {
            guard generation == lifetime, !Task.isCancelled else { throw CancellationError() }
            let failure: DSHLoginError = (error as? URLError)?.code == .userAuthenticationRequired
                ? (credential.username == nil ? .authentication : .accountAuthentication) : .unavailable
            factoryError = failure
            // Do not expose remote error text or URLs containing launch tokens.
            throw failure
        }
    }

    func connectFromInput() async {
        guard !store.isBusy else { return }
        do {
            let credential = try store.usesPasswordLogin
                ? DSHCredential(serverURL: store.launchURLInput, username: store.usernameInput, password: store.passwordInput)
                : DSHCredential(serverURL: store.launchURLInput, token: store.tokenInput)
            try await run(credential, savesIdentity: true)
        }
        catch { store.finish(error: store.usesPasswordLogin ? .invalidAccount : .invalidLink) }
    }

    func reconnect() async {
        guard !store.isBusy else { return }
        do {
            saved = try credentials.load()
            store.savedServer(saved)
            guard let saved else { store.finish(error: .invalidLink); return }
            try await run(saved)
        } catch { store.finish(error: .storage) }
    }

    func connectAutomatically() async {
        guard !attemptedAutomaticConnection else { return }
        attemptedAutomaticConnection = true
        // Developer launch injection remains available without embedding a secret.
        if let url = ProcessInfo.processInfo.environment["OPENCLIENT_DSH_URL"] {
            do { try await run(DSHCredential(launchURL: url)) }
            catch { store.finish(error: .invalidLink) }
        } else if saved != nil {
            await reconnect()
        }
    }

    private func run(_ credential: DSHCredential, savesIdentity: Bool = false) async throws {
        guard let connection else { return }
        generation = UUID()
        let lifetime = generation
        candidate = credential
        factoryError = nil
        store.begin()
        let task = Task { await connection.connect() }
        connectionTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard generation == lifetime else { return }
        connectionTask = nil
        guard !Task.isCancelled else { cancel(); return }
        candidate = nil
        guard connection.isConnected else { store.finish(error: factoryError ?? .unavailable); return }
        do {
            try credentials.save(credential)
            if savesIdentity { store.saveIdentity(for: credential) }
            saved = credential
            store.savedServer(credential)
            store.clearInput()
            store.finish()
        } catch {
            connection.disconnect()
            store.finish(error: .storage)
        }
    }

    func cancel() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        candidate = nil
        connection?.disconnect()
        store.clearInput()
        store.finish()
    }

    func signOut() {
        cancel()
        do {
            try credentials.delete()
            saved = nil
            store.savedServer(nil)
            store.clearInput()
        } catch { store.finish(error: .storage) }
    }

    var webLoginURL: URL? { saved?.launchURL }
}
