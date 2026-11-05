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
    @AppStorage("remoteDesktop.toolbarIcon") private var toolbarIcon = "desktopcomputer"
    @State private var isForgettingCredentials = false
    @State private var credentialError: String?
    @Environment(\.appAccentColor) private var accent
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.desktopChat) private var desktopChat

    var body: some View {
        if let endpoint = bridge.remoteDesktopEndpoint {
            Group {
                if handoff != nil {
                    Button { isPresented = true } label: {
                        Label("Open Remote Desktop", systemImage: "desktopcomputer")
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    DesktopToolbarMenu(
                        icon: toolbarIcon, isForgetting: isForgettingCredentials,
                        bridgeID: ObjectIdentifier(bridge),
                        selectIcon: { toolbarIcon = $0 },
                        open: { isPresented = true },
                        forget: {
                            isForgettingCredentials = true
                            Task {
                                defer { isForgettingCredentials = false }
                                do { try await bridge.forgetDesktopCredentials() }
                                catch { credentialError = error.localizedDescription }
                            }
                        }
                    )
                    .equatable()
                }
            }
            .accessibilityIdentifier("remote-desktop.open")
            .alert("Could not forget credentials", isPresented: Binding(
                get: { credentialError != nil }, set: { if !$0 { credentialError = nil } }
            )) {
                Button("OK", role: .cancel) { credentialError = nil }
            } message: { Text(verbatim: credentialError ?? "") }
            #if os(iOS)
            .fullScreenCover(isPresented: $isPresented) {
                DesktopLandscapeContainer {
                    OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff,
                                                clipboardHistory: bridge.desktopClipboardHistory) { isPresented = false }
                        .environment(\.appAccentColor, accent)
                        .environment(\.scenePhase, scenePhase)
                        .environment(\.desktopChat, desktopChat)
                }
                .ignoresSafeArea()
            }
            #else
            .sheet(isPresented: $isPresented) {
                OpenClientRemoteDesktopView(endpoint: endpoint, bridge: bridge, handoff: handoff,
                                            clipboardHistory: bridge.desktopClipboardHistory) { isPresented = false }
            }
            #endif
            .onChange(of: bridge.remoteDesktopEndpoint) { _, value in
                if value != endpoint { isPresented = false }
            }
        }
    }
}

/// Bridge notifications do not change this menu's contents. Keep its subtree
/// stable while a submenu is open, but update for actual selection/busy changes.
private struct DesktopToolbarMenu: View, Equatable {
    let icon: String
    let isForgetting: Bool
    let bridgeID: ObjectIdentifier
    let selectIcon: (String) -> Void
    let open: () -> Void
    let forget: () -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.icon == rhs.icon && lhs.isForgetting == rhs.isForgetting && lhs.bridgeID == rhs.bridgeID
    }

    var body: some View {
        Menu {
            Menu {
                Picker("Button icon", selection: Binding(get: { icon }, set: selectIcon)) {
                    Label("Desktop", systemImage: "desktopcomputer").tag("desktopcomputer")
                    Label("Laptop", systemImage: "laptopcomputer").tag("laptopcomputer")
                    Label("Display", systemImage: "display").tag("display")
                    Label("Keyboard", systemImage: "keyboard").tag("keyboard")
                    Label("Pointer", systemImage: "cursorarrow").tag("cursorarrow")
                    Label("Game controller", systemImage: "gamecontroller").tag("gamecontroller")
                }
            } label: { Label("Change icon", systemImage: "square.and.pencil") }
            Button("Forget credentials", role: .destructive, action: forget)
                .disabled(isForgetting)
        } label: {
            Label("Remote Desktop", systemImage: icon)
        } primaryAction: {
            open()
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
                    HStack {
                        OpenClientRemoteDesktopButton(bridge: bridge, handoff: handoff)
                            .buttonStyle(.borderedProminent)
                            .modifier(AppAccentActionModifier())
                            .controlSize(.large)
                            .labelStyle(.titleAndIcon)
                            .font(.headline)
                        if let history = bridge.desktopClipboardHistory {
                            DesktopClipboardButton(history: history)
                        }
                    }
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
    let clipboardHistory: DesktopClipboardHistory?
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
                    DesktopLoadingGame()
                } else {
                    Form {
                        Button("Connect") { openDesktop() }
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
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                if store.frame != nil && !store.needsCredentials {
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
                if let clipboardHistory {
                    ToolbarItem(placement: .bottomBar) {
                        DesktopClipboardButton(history: clipboardHistory)
                    }
                }
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
                        Button("Reconnect") { openDesktop() }
                        Button("Forget credentials", role: .destructive) {
                            coordinator.forgetCredentials(store: store)
                            openDesktop()
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Remote desktop options")
                    .disabled(store.isBusy)
                }
                }
            }
        }
        // Presentation inherits the card's environment; keep desktop controls native.
        .tint(nil)
        .foregroundStyle(.primary)
        .buttonStyle(.automatic)
        .toggleStyle(.automatic)
        .task { openDesktop() }
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

    private func openDesktop() {
        coordinator.open(endpoint: endpoint, access: bridge.desktopAccess, store: store,
                         clipboardHistory: clipboardHistory)
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
