import SwiftUI
import RoyalVNCKit

private struct DesktopBridgeKey: EnvironmentKey {
    static let defaultValue: OpenClientBridgeFacade? = nil
}

private struct DesktopChatKey: EnvironmentKey {
    static let defaultValue: ChatFacade? = nil
}

extension EnvironmentValues {
    var desktopChat: ChatFacade? {
        get { self[DesktopChatKey.self] }
        set { self[DesktopChatKey.self] = newValue }
    }
    var desktopBridge: OpenClientBridgeFacade? {
        get { self[DesktopBridgeKey.self] }
        set { self[DesktopBridgeKey.self] = newValue }
    }
}

struct OpenClientRemoteDesktopButton: View {
    @ObservedObject var bridge: OpenClientBridgeFacade
    var handoff: OpenClientDesktopHandoff? = nil
    @State private var isPresented = false
    @Environment(\.appAccentColor) private var accent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.desktopChat) private var desktopChat

    var body: some View {
        if let endpoint = bridge.remoteDesktopEndpoint {
            Button { isPresented = true } label: {
                if handoff != nil {
                    Label("Open Remote Desktop", systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Remote Desktop", systemImage: "desktopcomputer")
                }
            }
            .accessibilityIdentifier("remote-desktop.open")
            #if os(iOS)
            .fullScreenCover(isPresented: $isPresented) {
                DesktopLandscapeContainer {
                    OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff) { isPresented = false }
                        .environment(\.appAccentColor, accent)
                        .environment(\.scenePhase, scenePhase)
                        .environment(\.desktopChat, desktopChat)
                }
                .ignoresSafeArea()
            }
            #else
            .sheet(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff) { isPresented = false }
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
                        .buttonStyle(.borderedProminent)
                        .modifier(AppAccentActionModifier())
                        .controlSize(.large)
                        .labelStyle(.titleAndIcon)
                        .font(.headline)
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
    let dismiss: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.desktopChat) private var desktopChat
    @StateObject private var store = OpenClientRemoteDesktopStore()
    @State private var coordinator = OpenClientRemoteDesktopCoordinator()
    @State private var clickEnabled = false
    @State private var keyboardVisible = false
    @State private var clickToast: Bool?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
                    if keyboardVisible {
                        HStack(spacing: 8) {
                            DesktopFunctionRow(session: coordinator.native)
                            Button { keyboardVisible = false } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .frame(width: 38, height: 38)
                            }
                            .opencodeActionGlass(size: 38, in: Circle())
                            .accessibilityLabel("Dismiss Keyboard")
                            .accessibilityIdentifier("remote-desktop.keyboard.dismiss")
                            .padding(.trailing)
                        }
                    }
                } else if store.isBusy || store.isConnected {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Button("Connect") { coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store) }
                            .disabled(store.isBusy)
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
            #endif
            .overlay(alignment: .bottom) {
                if let clickToast {
                    Text(clickToast ? "Tap to click enabled" : "Tap to click disabled")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("remote-desktop.mode-toast")
                }
            }
            .navigationTitle(store.frame == nil ? Text("Remote Desktop") : Text(verbatim: ""))
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .bottomBar) {
                    Toggle(isOn: $clickEnabled) {
                        Label("Tap to click", systemImage: "hand.tap")
                    }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
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
                if let handoff {
                    ToolbarItem(placement: .opencodeTrailing) {
                        DesktopHandoffInstructions(reason: handoff.reason)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        DesktopHandoffDoneButton {
                            if handoff.preparesFollowupDraft {
                                if desktopChat?.prepareDesktopFollowup(forSessionID: handoff.sessionID) == true {
                                    dismiss()
                                }
                            } else {
                                coordinator.complete(handoff, outcome: "done", endpoint: endpoint,
                                                     access: bridge.desktopAccess, store: store)
                            }
                        }
                        .disabled(store.isBusy || store.completed || (handoff.preparesFollowupDraft && desktopChat == nil))
                    }
                }
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
        // Presentation inherits the card's environment; keep desktop controls native.
        .tint(nil)
        .foregroundStyle(.primary)
        .buttonStyle(.automatic)
        .toggleStyle(.automatic)
        .task { coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store) }
        .onChange(of: clickEnabled) { _, enabled in clickToast = enabled }
        .task(id: clickToast) {
            guard clickToast != nil else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            clickToast = nil
        }
        .onChange(of: store.completed) { _, completed in if completed { dismiss() } }
        .onChange(of: store.isConnected) { _, connected in if !connected { keyboardVisible = false } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { coordinator.disconnect(store: store) }
        }
        .onDisappear { coordinator.disconnect(store: store) }
    }
}

private struct DesktopHandoffInstructions: View {
    let reason: String
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Label("View instructions", systemImage: "info.circle")
        }
        .accessibilityIdentifier("remote-desktop.instructions")
        .popover(isPresented: $isPresented) {
            ScrollView {
                Text(verbatim: reason)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(idealWidth: 320, maxWidth: 360, idealHeight: 180, maxHeight: 360)
            .presentationCompactAdaptation(.popover)
        }
    }
}

private struct DesktopHandoffDoneButton: View {
    let complete: () -> Void

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Button(role: .confirm, action: complete) {
                Label("Done", systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .tint(.blue)
            .accessibilityIdentifier("remote-desktop.handoff.done")
        } else {
            Button(action: complete) {
                Label("Done", systemImage: "checkmark")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .accessibilityIdentifier("remote-desktop.handoff.done")
        }
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
