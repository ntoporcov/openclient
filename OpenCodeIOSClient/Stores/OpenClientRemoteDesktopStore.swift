import Foundation

@MainActor
final class OpenClientRemoteDesktopStore: ObservableObject {
    @Published private(set) var viewerURL: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completed = false

    func begin() { isBusy = true; errorMessage = nil }
    func opened(_ url: URL) { viewerURL = url; isBusy = false }
    func failed(_ error: Error) { errorMessage = error.localizedDescription; isBusy = false }
    func finish() { viewerURL = nil; isBusy = false; completed = true }
    func disconnect() { viewerURL = nil; isBusy = false }
}
