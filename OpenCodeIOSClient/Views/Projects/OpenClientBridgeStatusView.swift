import SwiftUI

struct OpenClientBridgeToolbarButton: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    let action: () -> Void

    var body: some View {
        let snapshot = bridge.snapshot
        if snapshot.showsToolbarButton {
            Button(action: action) {
                Image(systemName: snapshot.toolbarSystemImage)
                    .foregroundStyle(snapshot.isConnected ? .green : .secondary)
            }
            .accessibilityLabel("OpenClient Plugin")
            .accessibilityValue(Text(snapshot.statusTitle))
            .accessibilityIdentifier("projects.bridge.status")
        }
    }
}

struct OpenClientBridgeStatusView: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let snapshot = bridge.snapshot
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OpenClientBridgeSheetHeader(dismiss: dismiss)
                    OpenClientBridgeConnectedStatus(snapshot: snapshot)

                    HStack(spacing: 12) {
                        Button {
                            bridge.forceConnect()
                        } label: {
                            Label(
                                snapshot.isConnected ? LocalizedStringResource("Reconnect Now") : LocalizedStringResource("Force Connect"),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("projects.bridge.force-connect")

                        NavigationLink {
                            OpenClientBridgeDiagnosticsView(bridge: bridge)
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        .accessibilityIdentifier("projects.bridge.diagnostics")
                    }

                    Divider()
                    OpenClientNotificationSetupSection(bridge: bridge, snapshot: snapshot)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("projects.bridge.compact-status")
#if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
#endif
        }
    }
}

private struct OpenClientBridgeSheetHeader: View {
    let dismiss: DismissAction

    var body: some View {
        HStack {
            Text("OpenClient Plugin")
                .font(.headline)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
}

private struct OpenClientBridgeConnectedStatus: View {
    let snapshot: OpenClientBridgeSnapshot

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.isConnected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(snapshot.isConnected ? .green : .secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(bridgeStatusTitle(snapshot))
                    .font(.title3.weight(.semibold))
                Text(snapshot.isConnected ? String(localized: "Plugin tools are ready in OpenCode.") : snapshot.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OpenClientNotificationSetupSection: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    let snapshot: OpenClientBridgeSnapshot
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OC Notify", systemImage: "bell.badge")
                .font(.headline)
            Text(snapshot.notificationGuidance)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if case .ready(let setup) = snapshot.notificationSetupPhase {
                OpenClientNotificationSetupResult(
                    setup: setup,
                    open: {
                        guard let request = bridge.notificationOpenRequest() else { return }
                        OpenCodeClipboard.copy(request.clipboardPayload)
                        openURL(request.url) { accepted in
                            guard !accepted else { return }
                            Task { @MainActor in
                                bridge.notificationBrowserOpenFailed(request: request)
                            }
                        }
                    },
                    generate: {
                        Task { await bridge.setupNotifications() }
                    }
                )
            } else if snapshot.canSetUpNotifications {
                Button("Set Up Notifications") {
                    Task { await bridge.setupNotifications() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("projects.bridge.notifications.setup")
            }

            if case .requesting = snapshot.notificationSetupPhase {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing notification setup...")
                        .foregroundStyle(.secondary)
                }
            }

            if case .failed(let message) = snapshot.notificationSetupPhase {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if let message = snapshot.notificationBrowserErrorMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct OpenClientNotificationSetupResult: View {
    let setup: OpenClientNotificationSetup
    let open: () -> Void
    let generate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: open) {
                Label("Copy Setup & Open Guide", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("projects.bridge.notifications.open")

            Button("Generate New Code", action: generate)
                .accessibilityIdentifier("projects.bridge.notifications.generate")

            Text("Code expires at \(setup.expiresAt, format: .dateTime.hour().minute())")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct OpenClientBridgeDiagnosticsView: View {
    @ObservedObject var bridge: OpenClientBridgeFacade

    var body: some View {
        let snapshot = bridge.snapshot
        List {
            OpenClientBridgeDiagnosticsConnectionSection(snapshot: snapshot)
            OpenClientBridgeDeviceSection(snapshot: snapshot)

            if let errorMessage = snapshot.errorMessage {
                Section("Last Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button {
                    bridge.forceConnect()
                } label: {
                    Label(
                        snapshot.isConnected ? LocalizedStringResource("Reconnect Now") : LocalizedStringResource("Force Connect"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .accessibilityIdentifier("plugins.openclient.force-connect")
            } footer: {
                Text("OpenClient scans the connected OpenCode host on ports 4070 through 4090. The network is expected to be protected by your Tailnet, VPN, or firewall.")
            }
        }
        .navigationTitle("OpenClient Diagnostics")
        .opencodeInlineNavigationTitle()
        .accessibilityIdentifier("plugins.openclient.diagnostics")
    }
}

private struct OpenClientBridgeDiagnosticsConnectionSection: View {
    let snapshot: OpenClientBridgeSnapshot

    var body: some View {
        Section("Connection") {
            HStack(spacing: 12) {
                Text("Status")
                Spacer()
                Label(bridgeStatusTitle(snapshot), systemImage: snapshot.toolbarSystemImage)
                    .foregroundStyle(snapshot.isConnected ? .green : .secondary)
            }

            Text(snapshot.statusDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let endpoint = snapshot.endpoint {
                LabeledContent("Endpoint") {
                    Text(endpoint.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if snapshot.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connection attempt in progress")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func bridgeStatusTitle(_ snapshot: OpenClientBridgeSnapshot) -> LocalizedStringResource {
    switch snapshot.phase {
    case .idle: "Disconnected"
    case .searching: "Searching"
    case .connecting: "Connecting"
    case .connected: "Connected"
    }
}

private struct OpenClientBridgeDeviceSection: View {
    let snapshot: OpenClientBridgeSnapshot

    var body: some View {
        Section("This Device") {
            LabeledContent("Name", value: snapshot.displayName)
            LabeledContent("App Version", value: snapshot.appVersion)
            LabeledContent("Client ID") {
                Text(snapshot.clientID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}
