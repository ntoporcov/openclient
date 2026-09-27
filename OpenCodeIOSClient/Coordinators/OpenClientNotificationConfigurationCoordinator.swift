import Foundation

@MainActor
enum OpenClientNotificationConfigurationCoordinator {
    static func start(using viewModel: AppViewModel) async throws -> Bool {
        guard let connection = viewModel.backendConnection,
              viewModel.isCurrentBackendConnection(connection),
              connection.openCodeCompatibility != nil else {
            throw BackendError.disconnected
        }

        var createdSessionID: String?
        let sent = await viewModel.startNewProjectChat(
            title: String(localized: "Configure OC Notify"),
            prompt: prompt,
            projectID: "global",
            onSessionCreated: { createdSessionID = $0.id },
            isSubmissionCurrent: { viewModel.isCurrentBackendConnection(connection) }
        )
        guard viewModel.isCurrentBackendConnection(connection) else { throw BackendError.disconnected }
        // Reveal a created chat even if its first send failed. Its normal composer and
        // admission UI own recovery; another tap must not create a replacement session.
        if sent || (createdSessionID != nil && viewModel.selectedSession?.id == createdSessionID) {
            return true
        }
        if let message = viewModel.errorMessage { throw ConfigurationError(message: message) }
        return false
    }

    // Agent instructions are protocol/configuration guidance, not presentation copy.
    static let prompt = """
    Configure OC Notify for this OpenCode instance so I can finish notification setup in the OpenClient app. The plugin is connected, but reports that its HTTPS public origin is not configured.

    Inspect the running OpenCode version, its actual global configuration location (including HOME/XDG overrides), and the installed @openclient-ios/opencode-plugin. Preserve existing settings and configure this instance globally, not only the current repository. Use the installed plugin's README for the matching version. V2 uses plugins with {package, options}; V1 uses plugin with [package, options]. Keep a single OpenClient plugin entry.

    Configure notifications.enabled, a working path-free HTTPS notifications.publicOrigin, an available local notification port, and an absolute persistent dataDir. Reuse an existing suitable HTTPS reverse proxy or tunnel if available; otherwise ask me which hostname and hosting/tunnel option to use and help configure it. Route that HTTPS origin to the notification service's loopback port. This origin is for the OC Notify web app, not the OpenCode API or device bridge. Keep separate OpenCode instances on distinct notification ports and data directories. For managed V2 services, set the plugin serverURL to the actual OpenCode server origin rather than assuming port 4096.

    Apply the configuration, coordinate any necessary reload or restart with me so this session is not unexpectedly interrupted, and verify the HTTPS origin and plugin notification readiness. Then tell me to reconnect the plugin in OpenClient and tap Set Up Notifications. Respond in my language: \(Locale.current.identifier).
    """

    private struct ConfigurationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
