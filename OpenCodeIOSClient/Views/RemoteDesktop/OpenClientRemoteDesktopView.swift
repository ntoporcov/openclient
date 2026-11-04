import SwiftUI
import RoyalVNCKit

private struct DesktopBridgeKey: EnvironmentKey {
    static let defaultValue: OpenClientBridgeFacade? = nil
}

extension EnvironmentValues {
    var desktopBridge: OpenClientBridgeFacade? {
        get { self[DesktopBridgeKey.self] }
        set { self[DesktopBridgeKey.self] = newValue }
    }
}

struct OpenClientRemoteDesktopButton: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    var handoff: OpenClientDesktopHandoff? = nil
    @State private var isPresented = false

    var body: some View {
        if let endpoint = bridge.remoteDesktopEndpoint {
            Button { isPresented = true } label: {
                Label("Remote Desktop", systemImage: "desktopcomputer")
            }
            .accessibilityIdentifier("remote-desktop.open")
            .sheet(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, handoff: handoff)
            }
            .onChange(of: bridge.remoteDesktopEndpoint) { _, value in
                if value != endpoint { isPresented = false }
            }
        }
    }
}

struct OpenClientDesktopHandoffCard: View {
    @Environment(\.desktopBridge) private var bridge
    let handoff: OpenClientDesktopHandoff
    let pending: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Your help is needed", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text(verbatim: handoff.reason)
            if pending {
                if let bridge {
                    OpenClientRemoteDesktopButton(bridge: bridge, handoff: handoff)
                } else {
                    Text("Connect the OpenClient plugin to open the desktop.").font(.caption)
                }
            } else {
                Text(handoff.outcome == "done" ? "Completed" : "Closed")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("chat.remote-desktop.handoff")
    }
}

private struct OpenClientRemoteDesktopView: View {
    let endpoint: OpenClientBridgeEndpoint
    let handoff: OpenClientDesktopHandoff?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = OpenClientRemoteDesktopStore()
    @State private var coordinator = OpenClientRemoteDesktopCoordinator()
    @State private var token = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let handoff {
                    Text(verbatim: handoff.reason).font(.callout).padding()
                }
                if let error = store.errorMessage {
                    Text(verbatim: error).foregroundStyle(.red).padding()
                }
                if store.needsCredentials {
                    DesktopCredentialsForm(requiresUsername: store.requiresUsername) { username, password in
                        coordinator.native.authenticate(username: username, password: password)
                    }
                } else if let frame = store.frame {
                    NativeDesktopCanvas(frame: frame, session: coordinator.native)
                } else if store.isBusy || store.isConnected {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Section {
                            SecureField("Remote access token", text: $token)
                                .autocorrectionDisabled()
                                #if canImport(UIKit)
                                .textInputAutocapitalization(.never)
                                #endif
                            Button("Connect") { coordinator.open(endpoint: endpoint, token: token, store: store) }
                                .disabled(token.isEmpty || store.isBusy)
                        } footer: {
                            Text("Enter the remote access token configured on your host. You’ll sign in to your Mac next.")
                        }
                        if store.isBusy { ProgressView() }
                    }
                }
                if let handoff {
                    DesktopHandoffActions(isBusy: store.isBusy || token.isEmpty) { outcome in
                        coordinator.complete(handoff, outcome: outcome, endpoint: endpoint, token: token, store: store)
                    }
                }
            }
            .navigationTitle("Remote Desktop")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Reconnect") { coordinator.open(endpoint: endpoint, token: token, store: store) }
                        .disabled(token.isEmpty || store.isBusy)
                }
            }
        }
        .onChange(of: store.completed) { _, completed in if completed { dismiss() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { coordinator.disconnect(store: store) }
        }
        .onDisappear { coordinator.disconnect(store: store) }
    }
}

private struct DesktopHandoffActions: View {
    let isBusy: Bool
    let complete: (String) -> Void
    var body: some View {
        HStack {
            Button("Cancel request", role: .destructive) { complete("cancelled") }
            Spacer()
            Button("Done — continue") { complete("done") }.buttonStyle(.borderedProminent)
        }
        .padding().disabled(isBusy)
    }
}

private struct DesktopCredentialsForm: View {
    let requiresUsername: Bool
    let submit: (String, String) -> Void
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section("Sign in to your Mac") {
                if requiresUsername {
                    TextField("Username", text: $username).autocorrectionDisabled()
                        #if canImport(UIKit)
                        .textInputAutocapitalization(.never)
                        #endif
                        .accessibilityIdentifier("remote-desktop.username")
                }
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("remote-desktop.password")
                Button("Sign in") {
                    submit(username, password)
                    password = ""
                }
                .disabled(password.isEmpty || (requiresUsername && username.isEmpty))
                .accessibilityIdentifier("remote-desktop.sign-in")
            }
        }
    }
}

private struct NativeDesktopCanvas: View {
    let frame: CGImage
    let session: OpenClientNativeDesktopSession
    @State private var text = ""

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let scale = min(geometry.size.width / CGFloat(frame.width), geometry.size.height / CGFloat(frame.height))
                Image(decorative: frame, scale: 1)
                    .resizable().interpolation(.medium)
                    .frame(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            session.pointer(x: UInt16(max(0, min(CGFloat(frame.width - 1), value.location.x / scale))),
                                            y: UInt16(max(0, min(CGFloat(frame.height - 1), value.location.y / scale))), down: true)
                        }
                        .onEnded { value in
                            session.pointer(x: UInt16(max(0, min(CGFloat(frame.width - 1), value.location.x / scale))),
                                            y: UInt16(max(0, min(CGFloat(frame.height - 1), value.location.y / scale))), down: false)
                        })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(.black)
            .accessibilityLabel("Remote Desktop")
            .accessibilityIdentifier("remote-desktop.canvas")
            HStack {
                Button("Esc") { session.key(.escape) }
                Button("Tab") { session.key(.tab) }
                TextField("Type here", text: $text)
                    .autocorrectionDisabled()
                    #if canImport(UIKit)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { session.key(.return) }
                    .onChange(of: text) { _, value in
                        if !value.isEmpty { session.type(value); text = "" }
                    }
                Button { session.key(.delete) } label: { Image(systemName: "delete.left") }
                    .accessibilityLabel("Delete")
            }.padding()
        }
    }
}
