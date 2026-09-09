import SwiftUI

struct V2ProvidersConfigurationView: View {
    @ObservedObject var facade: ConfigurationsFacade
    let store: V2ProviderStore
    @State private var query = ""

    var body: some View {
        let groups = ConfigurationsFacade.v2ProviderGroups(store.integrations, query: query)

        List {
            if store.isLoading || (!store.isReady && store.discoveryErrorMessage == nil) { ProgressView("Loading providers") }
            if let error = store.discoveryErrorMessage {
                Text(error).foregroundStyle(.red)
                Button("Try Again") { Task { await facade.loadV2Integrations() } }
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            Section {
                Label("Custom Provider", systemImage: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
            } footer: {
                Text("Custom provider configuration is unavailable on this v2 server. Configure it on the server instead.")
            }
            if store.isReady, !store.isLoading, store.discoveryErrorMessage == nil, groups.popular.isEmpty, groups.other.isEmpty {
                ContentUnavailableView("No Providers", systemImage: "magnifyingglass")
            }
            Section("Popular") {
                V2ProviderLinks(integrations: groups.popular)
            }
            if !groups.other.isEmpty {
                Section("Other") {
                    V2ProviderLinks(integrations: groups.other)
                }
            }
        }
        .navigationTitle("Add Provider")
        .opencodeInlineNavigationTitle()
        .searchable(text: $query, prompt: "Search providers")
        .task(id: facade.configurationRevision) { await facade.loadV2Integrations() }
        .refreshable { await facade.loadV2Integrations() }
        .accessibilityIdentifier("configurations.v2.providers")
        .navigationDestination(for: V2ProviderRoute.self) { route in
            if facade.supportsProviderManagement && facade.isV2Connection {
                switch route {
                case .provider(let integrationID):
                    V2IntegrationDetailView(facade: facade, store: store, integrationID: integrationID)
                case .method(let integrationID, let methodID):
                    if let integration = store.integrations.first(where: { $0.id == integrationID }),
                       let method = integration.methods.first(where: { $0.id == methodID }) {
                        V2IntegrationMethodView(facade: facade, store: store, integrationID: integrationID, method: method)
                    } else {
                        ContentUnavailableView("Auth Method Unavailable", systemImage: "person.badge.key")
                    }
                }
            } else {
                ContentUnavailableView("Provider Unavailable", systemImage: "server.rack")
            }
        }
    }
}

private struct V2ProviderLinks: View {
    let integrations: [OpenCodeV2Integration]

    var body: some View {
        ForEach(integrations) { integration in
            NavigationLink(value: ConfigurationsFacade.v2ProviderRoute(for: integration)) {
                ProviderConfigurationRow(
                    providerID: integration.id,
                    providerName: integration.name,
                    subtitle: ConfigurationsFacade.providerAuthenticationSummary(integration.methods.map(\.displayTitle))
                )
            }
        }
    }
}

private struct V2IntegrationDetailView: View {
    let facade: ConfigurationsFacade
    let store: V2ProviderStore
    let integrationID: String
    @State private var removingCredentialID: String?

    var body: some View {
        Form {
            if let integration = store.integrations.first(where: { $0.id == integrationID }) {
                Section {
                    ProviderConfigurationRow(
                        providerID: integration.id,
                        providerName: integration.name,
                        subtitle: ConfigurationsFacade.providerAuthenticationSummary(integration.methods.map(\.displayTitle))
                    )
                }
                if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                if let error = store.discoveryErrorMessage { Text(error).foregroundStyle(.red) }
                if store.isBusy { ProgressView() }
                if !integration.connections.isEmpty {
                    Section("Credentials") {
                        ForEach(integration.connections) { connection in
                            switch connection {
                            case .credential(_, let label):
                                LabeledContent {
                                    Button("Remove", role: .destructive) { removingCredentialID = connection.removableCredentialID }
                                        .disabled(store.isBusy || store.attempt != nil)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(label)
                                        Text("Stored Credential").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            case .env(let name):
                                LabeledContent("Environment", value: name)
                            case .unsupported(let type):
                                Text(type).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Connect Provider") {
                    ForEach(integration.methods) { method in
                        NavigationLink(value: V2ProviderRoute.method(integrationID: integrationID, methodID: method.id)) {
                            V2IntegrationMethodLabel(method: method)
                        }
                        .disabled(store.isBusy)
                    }
                }
            } else {
                ContentUnavailableView("Provider Unavailable", systemImage: "server.rack")
            }
        }
        .navigationTitle(store.integrations.first(where: { $0.id == integrationID })?.name ?? String(localized: "Provider"))
        .opencodeInlineNavigationTitle()
        .confirmationDialog("Remove Credential?", isPresented: Binding(
            get: { removingCredentialID != nil }, set: { if !$0 { removingCredentialID = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let id = removingCredentialID { facade.v2Coordinator.removeCredential(integrationID: integrationID, credentialID: id) }
                removingCredentialID = nil
            }
        } message: {
            Text("This removes the stored credential from the OpenCode server. Environment credentials are not changed.")
        }
    }
}

private struct V2IntegrationMethodLabel: View {
    let method: OpenCodeV2IntegrationMethod

    var body: some View {
        switch method {
        case .key: Label(method.displayTitle, systemImage: "key")
        case .oauth: Label(method.displayTitle, systemImage: "person.badge.key")
        case .env: Label(method.displayTitle, systemImage: "server.rack")
        case .command: Label(method.displayTitle, systemImage: "terminal")
        case .unsupported: Label(method.displayTitle, systemImage: "exclamationmark.triangle")
        }
    }
}

private struct V2IntegrationMethodView: View {
    let facade: ConfigurationsFacade
    let store: V2ProviderStore
    let integrationID: String
    let method: OpenCodeV2IntegrationMethod
    @State private var key = ""
    @State private var code = ""
    @State private var values: [String: OpenCodeJSONValue] = [:]

    var body: some View {
        Form {
            Section {
                ProviderConfigurationRow(
                    providerID: integrationID,
                    providerName: store.integrations.first(where: { $0.id == integrationID })?.name ?? integrationID,
                    subtitle: method.displayTitle
                )
            }
            if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
            if store.isBusy { ProgressView() }
            if store.didConnect {
                Label("Connected", systemImage: "checkmark.circle")
            } else if let attempt = store.attempt, store.attemptIntegrationID == integrationID {
                V2OAuthAttemptSection(attempt: attempt, status: store.attemptStatus, code: $code,
                                      isBusy: store.isBusy, complete: { facade.v2Coordinator.complete(code: code) },
                                      cancel: { facade.v2Coordinator.cancelAttempt() })
            } else if method.isSupported {
                Section {
                    if case .key = method {
                        SecureField("API Key", text: $key)
                            .textContentType(.password)
                    }
                    ForEach(method.activeFields(values: values)) { field in
                        BackendFormFieldEditor(field: field, value: Binding(
                            get: {
                                let value = values[field.id] ?? field.raw["default"]
                                return value == .null ? nil : value
                            },
                            set: { values[field.id] = $0 ?? .null }
                        ))
                    }
                    Button("Connect Provider") {
                        facade.v2Coordinator.connect(integrationID: integrationID, method: method, key: key, values: values)
                        key = ""
                    }
                    .disabled(store.isBusy || !ConfigurationsFacade.canConnectV2Provider(method: method, key: key, values: values))
                } footer: {
                    Text("Credentials are stored on the OpenCode server, not on this device.")
                }
            } else {
                V2UnsupportedAuthenticationSection(method: method)
            }
        }
        .navigationTitle(store.integrations.first(where: { $0.id == integrationID })?.name ?? String(localized: "Provider"))
        .opencodeInlineNavigationTitle()
        .onChange(of: store.attempt?.attemptID) { _, id in
            if id != nil { values = [:] }
        }
        .onChange(of: store.didConnect) { _, connected in
            if connected {
                key = ""
                code = ""
                values = [:]
            }
        }
        .onDisappear {
            key = ""
            code = ""
            values = [:]
            store.stopAttempt()
        }
    }
}

private struct V2UnsupportedAuthenticationSection: View {
    let method: OpenCodeV2IntegrationMethod

    var body: some View {
        Section {
            switch method {
            case .env(let names):
                Text("Configure these environment variables on the machine running OpenCode.")
                ForEach(names, id: \.self) { Text($0).fontDesign(.monospaced) }
            case .command(_, _, let command):
                Text("Command authentication is not supported in OpenClient. Complete it on the server.")
                Text(command.joined(separator: " ")).fontDesign(.monospaced).textSelection(.enabled)
            default:
                Text("This authentication form is not supported in OpenClient. Use the OpenCode web app.")
            }
        }
    }
}

private struct V2OAuthAttemptSection: View {
    let attempt: OpenCodeV2OAuthAttempt
    let status: OpenCodeV2OAuthStatus.Status?
    @Binding var code: String
    let isBusy: Bool
    let complete: () -> Void
    let cancel: () -> Void

    var body: some View {
        Section {
            Text(attempt.instructions).textSelection(.enabled)
            if status == .pending {
                if let url = attempt.browserURL { Link("Open Browser", destination: url) }
                if attempt.mode == .code {
                    SecureField("Authorization code", text: $code)
                    Button("Complete OAuth", action: complete).disabled(isBusy || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    ProgressView("Waiting for authorization...")
                }
            }
            LabeledContent("Expires") { Text(attempt.time.expiration, style: .relative) }
            Button("Cancel Authorization", role: .cancel, action: cancel).disabled(isBusy)
        } footer: {
            Text("If authorization uses a localhost callback, complete it on the machine running OpenCode. Leaving this screen stops waiting; the server attempt expires automatically.")
        }
    }
}

struct V2ConfiguredPluginRow: View {
    let plugin: OpenCodeV2Plugin

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(plugin.specifier).textSelection(.enabled)
            switch plugin.state?.status {
            case "active": Label("Active", systemImage: "checkmark.circle").foregroundStyle(.green)
            case "failed": Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            default: Label("Status Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            if let error = plugin.state?.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if let version = plugin.source?.version { Text(version).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
