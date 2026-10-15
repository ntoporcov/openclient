import Combine
import Foundation

@MainActor
final class DSHConnectionStore: ObservableObject {
    @Published var launchURLInput = ""
    @Published var usesPasswordLogin = false
    @Published var usernameInput = ""
    @Published var passwordInput = ""
    @Published var tokenInput = ""
    @Published var nameInput = ""
    @Published var iconInput = "server.rack"
    @Published private(set) var savedName = ""
    @Published private(set) var savedIcon = "server.rack"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func updateServerURL(_ text: String) {
        // Normalize completed URL entry rather than rewriting partial typing.
        // Move a pasted launch secret into the secure token field.
        if let credential = try? DSHCredential(launchURL: text) {
            launchURLInput = credential.baseURL.absoluteString
            tokenInput = credential.token
        } else { launchURLInput = text }
    }

    var canConnect: Bool {
        guard !isBusy else { return false }
        if usesPasswordLogin {
            return (try? DSHCredential(serverURL: launchURLInput, username: usernameInput, password: passwordInput)) != nil
        }
        return (try? DSHCredential(serverURL: launchURLInput, token: tokenInput)) != nil
    }

    func saveIdentity(for credential: DSHCredential) {
        defaults.set(["name": nameInput.trimmingCharacters(in: .whitespacesAndNewlines), "icon": iconInput],
                     forKey: "dsh.connection.identity." + credential.baseURL.absoluteString)
    }
    @Published private(set) var serverAddress: String?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?

    var usesInsecureHTTP: Bool {
        let text = launchURLInput.isEmpty ? serverAddress ?? "" : launchURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: text)?.scheme?.lowercased() == "http"
    }

    func savedServer(_ credential: DSHCredential?) {
        serverAddress = credential?.baseURL.absoluteString
        if let credential {
            usesPasswordLogin = credential.username != nil
            let identity = defaults.dictionary(forKey: "dsh.connection.identity." + credential.baseURL.absoluteString)
            savedName = identity?["name"] as? String ?? ""
            savedIcon = identity?["icon"] as? String ?? "server.rack"
        } else {
            savedName = ""
            savedIcon = "server.rack"
        }
    }
    func begin() { isBusy = true; errorMessage = nil }
    func finish(error: DSHLoginError? = nil) { isBusy = false; errorMessage = error?.localizedDescription }
    func clearInput() {
        launchURLInput = ""; usernameInput = ""; passwordInput = ""; tokenInput = ""
        nameInput = ""; iconInput = "server.rack"
    }
}
