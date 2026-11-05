import Foundation
import CoreGraphics
@preconcurrency import RoyalVNCKit

@MainActor
protocol DesktopPointerInput: AnyObject {
    func pointer(x: UInt16, y: UInt16, down: Bool)
}

@MainActor
final class OpenClientNativeDesktopSession: NSObject, DesktopPointerInput {
    private var connection: VNCConnection?
    private var credentialReply: ((VNCCredential?) -> Void)?
    private weak var store: OpenClientRemoteDesktopStore?
    var onCredentialsRequested: (() -> Void)?
    var onConnected: (() -> Void)?
    var onDisconnected: (() -> Void)?
    var onClipboardText: ((String) -> Void)?

    func start(port: UInt16, store: OpenClientRemoteDesktopStore) {
        self.store = store
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false, hostname: "127.0.0.1", port: port,
            isShared: true, isScalingEnabled: true, useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false, colorDepth: .depth24Bit,
            frameEncodings: .default)
        let connection = VNCConnection(settings: settings)
        self.connection = connection
        connection.delegate = self
        connection.serverClipboardTextHandler = { [weak self] connection, text in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                self.onClipboardText?(text)
            }
        }
        connection.connect()
    }

    func authenticate(username: String, password: String) {
        let reply = credentialReply
        credentialReply = nil
        store?.authenticating()
        if store?.requiresUsername == true {
            reply?(VNCUsernamePasswordCredential(username: username, password: password))
        } else {
            reply?(VNCPasswordCredential(password: password))
        }
    }

    func stop() {
        credentialReply?(nil); credentialReply = nil
        connection?.delegate = nil
        connection?.disconnect()
        connection = nil
        onClipboardText = nil
    }

    func type(_ text: String) {
        for key in VNCKeyCode.keyCodesFrom(characters: text) { connection?.keyDown(key); connection?.keyUp(key) }
    }

    func key(_ key: VNCKeyCode) { connection?.keyDown(key); connection?.keyUp(key) }

    func copySelection() {
        modifier(.command, pressed: true)
        type("c")
        modifier(.command, pressed: false)
    }

    func modifier(_ key: VNCKeyCode, pressed: Bool) {
        if pressed { connection?.keyDown(key) } else { connection?.keyUp(key) }
    }

    func pointer(x: UInt16, y: UInt16, down: Bool) {
        if down { connection?.mouseButtonDown(.left, x: x, y: y) }
        else { connection?.mouseButtonUp(.left, x: x, y: y) }
    }
}

extension OpenClientNativeDesktopSession: VNCConnectionDelegate {
    // The SDK gives this continuation to exactly one delegate call. Transfer it
    // to the main actor, where submit/cancel consume it exactly once.
    private struct CredentialReply: @unchecked Sendable {
        let call: (VNCCredential?) -> Void
    }
    nonisolated func connection(_ connection: VNCConnection, stateDidChange state: VNCConnection.ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.connection === connection else { return }
            if state.status == .connected { store?.connected(); onConnected?() }
            if state.status == .disconnected {
                if let error = state.error { store?.failed(error) }
                else { store?.disconnect() }
                onDisconnected?()
                stop()
            }
        }
    }
    nonisolated func connection(_ connection: VNCConnection, credentialFor type: VNCAuthenticationType,
                                completion: @escaping (VNCCredential?) -> Void) {
        let reply = CredentialReply(call: completion)
        Task { @MainActor [weak self] in
            guard let self, self.connection === connection else { reply.call(nil); return }
            credentialReply = reply.call
            store?.requestCredentials(requiresUsername: type.requiresUsername)
            onCredentialsRequested?()
        }
    }
    nonisolated func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) { publish(connection, framebuffer) }
    nonisolated func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) { publish(connection, framebuffer) }
    nonisolated func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer,
                                x: UInt16, y: UInt16, width: UInt16, height: UInt16) { publish(connection, framebuffer) }
    nonisolated func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {}
    nonisolated private func publish(_ connection: VNCConnection, _ framebuffer: VNCFramebuffer) {
        let image = framebuffer.cgImage
        Task { @MainActor [weak self] in
            guard let self, self.connection === connection else { return }
            store?.updateFrame(image)
        }
    }
}
