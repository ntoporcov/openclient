import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum OpenClientBridgePhase: Equatable, Sendable {
    case idle
    case searching
    case connecting(port: Int)
    case connected(port: Int)
}

enum OpenClientNotificationSetupPhase: Equatable, Sendable {
    case idle
    case requesting
    case ready(OpenClientNotificationSetup)
    case failed(String)
}

struct OpenClientNotificationSetupOwner: Equatable, Sendable {
    let requestID: UUID
    let lifecycleID: UUID
    let endpoint: OpenClientBridgeEndpoint
    let context: OpenClientNotificationSetupContext
}

struct OpenClientNotificationOpenRequest: Equatable, Sendable {
    let requestID: UUID
    let url: URL
    let clipboardPayload: String
}

@MainActor
final class OpenClientBridgeStore: ObservableObject {
    @Published private(set) var phase: OpenClientBridgePhase = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var endpoint: OpenClientBridgeEndpoint?
    @Published private(set) var notificationSetupPhase: OpenClientNotificationSetupPhase = .idle
    @Published private(set) var notificationBrowserErrorMessage: String?
    private(set) var notificationSetupOwner: OpenClientNotificationSetupOwner?

    let clientID: String
    let displayName: String
    let appVersion: String
    let isEnabled: Bool

    private static let clientIDDefaultsKey = "OpenClientBridgeClientID"

    init(defaults: UserDefaults = .standard) {
        if let saved = defaults.string(forKey: Self.clientIDDefaultsKey), !saved.isEmpty {
            clientID = saved
        } else {
            let created = UUID().uuidString.lowercased()
            defaults.set(created, forKey: Self.clientIDDefaultsKey)
            clientID = created
        }
        displayName = Self.currentDeviceName
        appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        isEnabled = ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] == nil
    }

    func apply(_ event: OpenClientBridgeClientEvent) {
        switch event {
        case .searching:
            phase = .searching
            errorMessage = nil
            endpoint = nil
            notificationSetupPhase = .idle
            notificationSetupOwner = nil
            notificationBrowserErrorMessage = nil
        case .connecting(let endpoint):
            phase = .connecting(port: endpoint.port)
            errorMessage = nil
            self.endpoint = endpoint
            notificationSetupPhase = .idle
            notificationSetupOwner = nil
            notificationBrowserErrorMessage = nil
        case .connected(let endpoint):
            if self.endpoint != endpoint {
                notificationSetupPhase = .idle
                notificationSetupOwner = nil
                notificationBrowserErrorMessage = nil
            }
            phase = .connected(port: endpoint.port)
            errorMessage = nil
            self.endpoint = endpoint
        case .disconnected(let message):
            phase = .idle
            errorMessage = message
            endpoint = nil
            notificationSetupPhase = .idle
            notificationSetupOwner = nil
            notificationBrowserErrorMessage = nil
        }
    }

    func reset() {
        phase = .idle
        errorMessage = nil
        endpoint = nil
        notificationSetupPhase = .idle
        notificationSetupOwner = nil
        notificationBrowserErrorMessage = nil
    }

    func beginNotificationSetup(owner: OpenClientNotificationSetupOwner) {
        notificationSetupOwner = owner
        notificationBrowserErrorMessage = nil
        notificationSetupPhase = .requesting
    }

    func finishNotificationSetup(_ setup: OpenClientNotificationSetup, owner: OpenClientNotificationSetupOwner) {
        guard notificationSetupOwner == owner else { return }
        notificationBrowserErrorMessage = nil
        notificationSetupPhase = .ready(setup)
    }

    func failNotificationSetup(_ message: String, owner: OpenClientNotificationSetupOwner? = nil) {
        guard owner == nil || notificationSetupOwner == owner else { return }
        notificationSetupOwner = nil
        notificationBrowserErrorMessage = nil
        notificationSetupPhase = .failed(message)
    }

    func clearNotificationSetup(owner: OpenClientNotificationSetupOwner? = nil) {
        guard owner == nil || notificationSetupOwner == owner else { return }
        notificationSetupOwner = nil
        notificationBrowserErrorMessage = nil
        notificationSetupPhase = .idle
    }

    func failNotificationBrowserOpen(_ message: String, owner: OpenClientNotificationSetupOwner) {
        guard notificationSetupOwner == owner,
              case .ready = notificationSetupPhase else { return }
        notificationBrowserErrorMessage = message
    }

    private static var currentDeviceName: String {
#if canImport(UIKit)
        return UIDevice.current.name
#elseif canImport(AppKit)
        return Host.current().localizedName ?? "OpenClient for Mac"
#else
        return Host.current().localizedName ?? "OpenClient"
#endif
    }
}
