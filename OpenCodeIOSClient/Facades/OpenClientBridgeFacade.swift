import Combine
import Foundation

struct OpenClientBridgeSnapshot: Equatable {
    let phase: OpenClientBridgePhase
    let endpoint: URL?
    let errorMessage: String?
    let clientID: String
    let displayName: String
    let appVersion: String
    let notifications: OpenClientBridgeNotificationsCapability
    let notificationSetupPhase: OpenClientNotificationSetupPhase
    let notificationBrowserErrorMessage: String?

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    var showsToolbarButton: Bool { true }

    var isBusy: Bool {
        switch phase {
        case .searching, .connecting:
            return true
        case .idle, .connected:
            return false
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return String(localized: "Disconnected")
        case .searching:
            return String(localized: "Searching")
        case .connecting:
            return String(localized: "Connecting")
        case .connected:
            return String(localized: "Connected")
        }
    }

    var statusDetail: String {
        switch phase {
        case .idle:
            return errorMessage ?? String(localized: "No plugin bridge connection is active.")
        case .searching:
            return String(localized: "Scanning the OpenCode host on ports 4070 through 4090.")
        case .connecting(let port):
            return String(localized: "Opening the plugin bridge on port \(port).")
        case .connected(let port):
            return String(localized: "Device tools are available through port \(port).")
        }
    }

    var toolbarSystemImage: String {
        isConnected ? "link.circle.fill" : "link.circle"
    }

    var notificationGuidance: LocalizedStringResource {
        guard isConnected else {
            return "Connect the OpenClient plugin first to configure OC Notify."
        }
        return switch notifications {
        case .ready:
            "Set up OC Notify in your browser, then install it on your Home Screen and allow notifications."
        case .unconfigured:
            "Configure the OC Notify HTTPS public origin on the OpenCode host, then reconnect."
        case .missing, .unsupportedVersion:
            "Update the OpenClient plugin on the OpenCode host to set up OC Notify from this app."
        case .unavailable:
            "OC Notify is unavailable on the OpenCode host. Check its notification service configuration."
        }
    }

    var canSetUpNotifications: Bool {
        guard isConnected, case .ready = notifications else { return false }
        if case .requesting = notificationSetupPhase { return false }
        return true
    }
}

@MainActor
final class OpenClientBridgeFacade: ObservableObject {
    private let store: OpenClientBridgeStore
    private let forceConnectAction: @MainActor () -> Void
    private let setupNotificationsAction: @MainActor () async -> Void
    private let notificationOpenRequestAction: @MainActor () -> OpenClientNotificationOpenRequest?
    private let notificationBrowserOpenFailedAction: @MainActor (OpenClientNotificationOpenRequest) -> Void
    private var observation: AnyCancellable?

    init(
        store: OpenClientBridgeStore,
        forceConnect: @escaping @MainActor () -> Void,
        setupNotifications: @escaping @MainActor () async -> Void = {},
        notificationOpenRequest: @escaping @MainActor () -> OpenClientNotificationOpenRequest? = { nil },
        notificationBrowserOpenFailed: @escaping @MainActor (OpenClientNotificationOpenRequest) -> Void = { _ in }
    ) {
        self.store = store
        forceConnectAction = forceConnect
        setupNotificationsAction = setupNotifications
        notificationOpenRequestAction = notificationOpenRequest
        notificationBrowserOpenFailedAction = notificationBrowserOpenFailed
        observation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var snapshot: OpenClientBridgeSnapshot {
        OpenClientBridgeSnapshot(
            phase: store.phase,
            endpoint: store.endpoint?.webSocketURL,
            errorMessage: store.errorMessage,
            clientID: store.clientID,
            displayName: store.displayName,
            appVersion: store.appVersion,
            notifications: store.endpoint?.notifications ?? .missing,
            notificationSetupPhase: store.notificationSetupPhase,
            notificationBrowserErrorMessage: store.notificationBrowserErrorMessage
        )
    }

    func forceConnect() {
        forceConnectAction()
    }

    func setupNotifications() async {
        await setupNotificationsAction()
    }

    func notificationOpenRequest() -> OpenClientNotificationOpenRequest? {
        notificationOpenRequestAction()
    }

    func notificationBrowserOpenFailed(request: OpenClientNotificationOpenRequest) {
        notificationBrowserOpenFailedAction(request)
    }
}
