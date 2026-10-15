import SwiftUI

struct DSHConnectionView: View {
    let coordinator: DSHConnectionCoordinator
    @ObservedObject private var store: DSHConnectionStore
    @Environment(\.openURL) private var openURL
    @FocusState private var isServerURLFocused: Bool
    @State private var isShowingEditor = false
    @State private var isEditingSaved = false

    private var showsForm: Bool { store.serverAddress == nil || isShowingEditor }

    init(coordinator: DSHConnectionCoordinator) {
        self.coordinator = coordinator
        self.store = coordinator.store
    }

    var body: some View {
        NavigationStack {
            Form {
                if let address = store.serverAddress, !showsForm {
                    Section("Saved DSH server") {
                        Button { Task { await coordinator.reconnect() } } label: {
                            HStack(spacing: 14) {
                                Image(systemName: store.savedIcon).font(.title2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.savedName.isEmpty ? address : store.savedName).font(.headline)
                                    Text(address).font(.subheadline).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("dsh.savedServer")
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                        }
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("dsh.reconnect")
                        Button("Edit") {
                            coordinator.prepareEditor(editingSaved: true)
                            isEditingSaved = true
                            isShowingEditor = true
                        }
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("dsh.editConnection")
                        Button("Sign Out", role: .destructive) {
                            coordinator.signOut()
                            isEditingSaved = false
                            isShowingEditor = false
                        }
                        .accessibilityIdentifier("dsh.signOut")
                    }
                }
                if showsForm {
                Section("Connection") {
                    TextField("Name", text: $store.nameInput)
                        .accessibilityIdentifier("dsh.name")
                    TextField("Server URL", text: $store.launchURLInput)
                        .opencodeDisableTextAutocapitalization().autocorrectionDisabled()
                        .opencodeURLKeyboardType()
                        .focused($isServerURLFocused)
                        .onSubmit { store.updateServerURL(store.launchURLInput) }
                        .onChange(of: isServerURLFocused) { _, focused in
                            if !focused { store.updateServerURL(store.launchURLInput) }
                        }
                        .accessibilityIdentifier("dsh.serverURL")
                    if store.usesInsecureHTTP {
                        Text("This connection uses unencrypted HTTP.").foregroundStyle(.orange)
                    }
                }
                .disabled(store.isBusy)
                Section("Icon") {
                    ConnectionIconPicker(selection: $store.iconInput)
                        .disabled(store.isBusy)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                Section("Login method") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            DSHAuthenticationCard(
                                title: "URL token",
                                detail: "The default for dsh web. Use the token from your server’s launch URL.",
                                symbol: "key", isSelected: !store.usesPasswordLogin
                            ) { store.usesPasswordLogin = false }
                            .accessibilityIdentifier("dsh.loginMethod.token")
                            DSHAuthenticationCard(
                                title: "Username and password",
                                detail: "Requires the dsh-auth-gate plugin configured for password login.",
                                symbol: "person.crop.circle", isSelected: store.usesPasswordLogin
                            ) { store.usesPasswordLogin = true }
                            .accessibilityIdentifier("dsh.loginMethod.password")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                    .disabled(store.isBusy)
                    .accessibilityIdentifier("dsh.loginMethod")
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                Section {
                    if store.usesPasswordLogin {
                        TextField("Username", text: $store.usernameInput)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .disabled(store.isBusy).accessibilityIdentifier("dsh.username")
                        SecureField("Password", text: $store.passwordInput)
                            .textContentType(.password).disabled(store.isBusy)
                            .accessibilityIdentifier("dsh.password")
                    } else {
                        SecureField("Token", text: $store.tokenInput)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("dsh.token")
                        .disabled(store.isBusy)
                    }
                } footer: {
                    if store.usesPasswordLogin {
                        Text("Requires dsh-auth-gate in password mode. Your credentials are saved securely in Keychain and reused when reconnecting. Verification codes and required password changes are not supported in the app yet.")
                    } else {
                        Text("Enter the token above, or paste the full launch URL into Server URL. Your login is saved securely in Keychain.")
                    }
                }
                Section {
                    Button("Connect to DSH") { Task { await coordinator.connectFromInput() } }
                        .frame(maxWidth: .infinity)
                        .disabled(!store.canConnect)
                        .accessibilityIdentifier("dsh.connect")
                }
                }
                if store.isBusy {
                    Section {
                        ProgressView("Connecting…")
                        Button("Cancel") { coordinator.cancel() }
                            .accessibilityIdentifier("dsh.cancel")
                    }
                }
                if let error = store.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                            .accessibilityIdentifier("dsh.loginError")
                    }
                }
                if showsForm { Section("Model provider login") {
                    Text("Sign in to your Codex subscription in the DSH web interface. This app connects to that server and uses its configured providers.")
                    if let url = coordinator.webLoginURL {
                        Button("Open DSH in Browser") { openURL(url) }
                    }
                }
                }
            }
            .navigationTitle(showsForm ? (isEditingSaved ? Text("Edit Connection") : Text("Add Connection")) : Text("Connections"))
            .toolbar {
                if !showsForm {
                    ToolbarItem(placement: .opencodeTrailing) {
                        Button {
                            coordinator.prepareEditor(editingSaved: false)
                            isEditingSaved = false
                            isShowingEditor = true
                        } label: { Label("Add Connection", systemImage: "plus") }
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("dsh.addConnection")
                    }
                } else if store.serverAddress != nil {
                    ToolbarItem(placement: .opencodeLeading) {
                        Button("Cancel") {
                            if store.isBusy { coordinator.cancel() }
                            else { store.clearInput(); store.finish() }
                            isShowingEditor = false
                            isEditingSaved = false
                        }
                        .accessibilityIdentifier("dsh.cancelEditor")
                    }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct DSHAuthenticationCard: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let symbol: String
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.appAccentColor) private var accent

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: symbol)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .foregroundStyle(isSelected ? accent : .secondary)
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 220, alignment: .leading)
            .padding(16)
            .background(isSelected ? accent.opacity(0.12) : OpenCodePlatformColor.secondaryGroupedBackground,
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? accent : Color.primary.opacity(0.12), lineWidth: isSelected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
