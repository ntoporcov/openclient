import Foundation
import CoreGraphics

@MainActor
final class OpenClientRemoteDesktopStore: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completed = false
    @Published private(set) var frame: CGImage?
    @Published private(set) var needsCredentials = false
    @Published private(set) var requiresUsername = true
    @Published private(set) var isConnected = false

    func requestCredentials(requiresUsername: Bool) {
        self.requiresUsername = requiresUsername
        needsCredentials = true
        isBusy = false
    }
    func authenticating() { needsCredentials = false; isBusy = true }
    func connected() { isConnected = true; isBusy = false }
    func updateFrame(_ image: CGImage?) { frame = image }

    func begin() { isBusy = true; errorMessage = nil }
    func failed(_ error: Error) { errorMessage = error.localizedDescription; isBusy = false; needsCredentials = false; isConnected = false; frame = nil }
    func finish() { disconnect(); completed = true }
    func disconnect() { isBusy = false; frame = nil; needsCredentials = false; isConnected = false }
}
