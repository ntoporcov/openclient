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
            #if os(iOS)
            .fullScreenCover(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff)
            }
            #else
            .sheet(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff)
            }
            #endif
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
    @ObservedObject var bridge: OpenClientBridgeFacade
    let handoff: OpenClientDesktopHandoff?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = OpenClientRemoteDesktopStore()
    @State private var coordinator = OpenClientRemoteDesktopCoordinator()
    @State private var clickEnabled = false
    @State private var keyboardVisible = false
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let handoff {
                    Text(verbatim: handoff.reason).font(.callout).padding()
                }
                if let error = store.errorMessage {
                    Text(verbatim: error).foregroundStyle(.red).padding()
                }
                if let error = store.credentialStorageError {
                    Text(verbatim: error).foregroundStyle(.red).padding()
                }
                if store.needsCredentials {
                    DesktopCredentialsForm(requiresUsername: store.requiresUsername) { username, password, save in
                        coordinator.authenticate(username: username, password: password, save: save)
                    }
                } else if store.frame != nil {
                    Spacer()
                    if keyboardVisible { DesktopFunctionRow(session: coordinator.native) }
                } else if store.isBusy || store.isConnected {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Button("Connect") { coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store) }
                            .disabled(store.isBusy)
                    }
                }
                if let handoff {
                    DesktopHandoffActions(isBusy: store.isBusy) { outcome in
                        coordinator.complete(handoff, outcome: outcome, endpoint: endpoint, access: bridge.desktopAccess, store: store)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if let frame = store.frame, !store.needsCredentials {
                    #if canImport(UIKit)
                    DesktopStreamSurface(frame: frame, session: coordinator.native,
                                         clickEnabled: clickEnabled, keyboardVisible: $keyboardVisible)
                        .ignoresSafeArea(.container)
                    #else
                    NativeDesktopCanvas(frame: frame, session: coordinator.native)
                    #endif
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
            #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
            .background { DesktopPresentationOrientation().allowsHitTesting(false) }
            #endif
            .navigationTitle("Remote Desktop")
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Toggle(isOn: $clickEnabled) {
                        Label("Tap to click", systemImage: "hand.tap")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .tint(accent)
                    .accessibilityIdentifier("remote-desktop.click-mode")
                    .disabled(!store.isConnected)
                }
                ToolbarItem(placement: .bottomBar) { Spacer() }
                ToolbarItem(placement: .bottomBar) {
                    Button { keyboardVisible.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "keyboard")
                            Image(systemName: keyboardVisible ? "chevron.down" : "chevron.up")
                                .font(.caption2.weight(.semibold))
                        }
                    }
                    .accessibilityLabel(keyboardVisible ? Text("Dismiss Keyboard") : Text("Show Keyboard"))
                    .accessibilityIdentifier("remote-desktop.keyboard")
                    .disabled(!store.isConnected)
                }
                #endif
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Text("Using iPhone Duo? Unfold it to use the inner display.")
                        Button("Reconnect") { coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store) }
                        Button("Forget saved computer credentials", role: .destructive) {
                            coordinator.forgetCredentials(store: store)
                            coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Remote desktop options")
                    .disabled(store.isBusy)
                }
            }
        }
        .task { coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store) }
        .onChange(of: store.completed) { _, completed in if completed { dismiss() } }
        .onChange(of: store.isConnected) { _, connected in if !connected { keyboardVisible = false } }
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
    let submit: (String, String, Bool) -> Void
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredentials = false

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
                Toggle("Save computer credentials", isOn: $saveCredentials)
                    .accessibilityIdentifier("remote-desktop.save-credentials")
                Button("Sign in") {
                    submit(username, password, saveCredentials)
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
