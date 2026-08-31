import SwiftUI
#if canImport(UIKit)
import SafariServices
#endif

struct ConfigurationsSheet: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    @ObservedObject var connection: ConnectionFacade
    let bridge: OpenClientBridgeFacade?
    @State private var navigationPath = NavigationPath()

    var body: some View {
        let connectedProviders = viewModel.sortedConnectedProviders

        NavigationStack(path: $navigationPath) {
            Form {
                Section {
                    NavigationLink {
                        RootConfigurationsView(facade: connection)
                    } label: {
                        Label("Global Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("configurations.global-settings")
                }

                Section {
                    NavigationLink {
                        AgentDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Agent", value: viewModel.configurationAgentTitle)
                    }

                    NavigationLink {
                        ModelDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Model", value: viewModel.configurationModelTitle)
                    }

                    NavigationLink {
                        VoiceModeModelSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Talk Model", value: viewModel.configurationVoiceModeModelTitle)
                    }
                    .accessibilityIdentifier("configurations.talk-model")

                    NavigationLink {
                        ReasoningDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Reasoning", value: viewModel.configurationReasoningTitle)
                    }
                    .disabled(viewModel.configurationReasoningVariants.isEmpty)
                } header: {
                    Text("New Session Defaults")
                } footer: {
                    Text("Used when starting a new session on this server. Changes made in a chat only affect that session.")
                }

                Section("Providers") {
                    if viewModel.isLoadingProviders && connectedProviders.isEmpty {
                        ProgressView("Loading providers")
                    } else if connectedProviders.isEmpty {
                        Text("No connected providers.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(connectedProviders) { provider in
                            NavigationLink(value: ConfigurationRoute.providerVisibility(provider.id)) {
                                ProviderConfigurationRow(
                                    providerID: provider.id,
                                    providerName: provider.name,
                                    subtitle: providerSummary(
                                        source: viewModel.providerSourceTitle(provider),
                                        modelCount: provider.models.count
                                    )
                                )
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Task { await viewModel.disconnectProvider(provider) }
                                } label: {
                                    Label("Disconnect", systemImage: "trash")
                                }
                                .disabled(!viewModel.canDisconnectProvider(provider) || viewModel.modelConfigurationStore.disconnectingProviderID == provider.id)
                            }
                        }
                    }

                    NavigationLink(value: ConfigurationRoute.addProvider) {
                        Label("Add Provider", systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("configurations.addProvider")
                }

                Section("Server") {
                    NavigationLink(value: ConfigurationRoute.plugins) {
                        Label("Plugins", systemImage: "puzzlepiece.extension")
                    }
                    .accessibilityIdentifier("configurations.plugins")
                }

            }
            .navigationTitle("Configurations")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        viewModel.isShowingConfigurationsSheet = false
                    }
                }
            }
            .task {
                await viewModel.loadProvidersForConfigurationIfNeeded()
            }
            .onAppear {
                #if DEBUG
                if OpenClientScreenshotScene.current == .providerSetup, navigationPath.isEmpty {
                    navigationPath.append(ConfigurationRoute.addProvider)
                }
                #endif
            }
            .navigationDestination(for: ConfigurationRoute.self) { route in
                switch route {
                case .plugins:
                    PluginsConfigurationView(
                        viewModel: viewModel,
                        store: viewModel.pluginStore,
                        bridge: bridge
                    )
                case .addProvider:
                    AddProviderView(viewModel: viewModel)
                case .customProvider:
                    CustomProviderView(viewModel: viewModel)
                case .providerConnect(let providerID):
                    if let provider = viewModel.modelConfigurationStore.provider(id: providerID) {
                        ProviderConnectView(viewModel: viewModel, provider: provider) {
                            navigationPath = NavigationPath()
                        }
                    } else {
                        ContentUnavailableView("Provider Unavailable", systemImage: "server.rack")
                    }
                case .providerMethod(let providerID, let methodIndex):
                    if let provider = viewModel.modelConfigurationStore.provider(id: providerID),
                       viewModel.authMethods(for: provider).indices.contains(methodIndex) {
                        let method = viewModel.authMethods(for: provider)[methodIndex]
                        ProviderConnectMethodView(viewModel: viewModel, provider: provider, method: method, methodIndex: methodIndex) {
                            navigationPath = NavigationPath()
                        }
                    } else {
                        ContentUnavailableView("Auth Method Unavailable", systemImage: "person.badge.key")
                    }
                case .providerVisibility(let providerID):
                    ProviderModelVisibilityView(viewModel: viewModel, providerID: providerID)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func configurationRow(title: LocalizedStringResource, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private enum ConfigurationRoute: Hashable {
    case plugins
    case addProvider
    case customProvider
    case providerConnect(String)
    case providerMethod(String, Int)
    case providerVisibility(String)
}

private struct PluginsConfigurationView: View {
    let viewModel: ConfigurationsFacade
    @ObservedObject var store: PluginStore
    let bridge: OpenClientBridgeFacade?

    var body: some View {
        Group {
            if store.isLoading && store.plugins.isEmpty {
                ProgressView("Loading plugins")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.errorMessage != nil, store.plugins.isEmpty {
                ContentUnavailableView {
                    Label("Plugins Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("OpenClient couldn't load the configured plugins.")
                } actions: {
                    Button("Try Again") {
                        Task { await viewModel.loadPluginsForConfiguration() }
                    }
                }
            } else if store.plugins.isEmpty {
                ContentUnavailableView(
                    "No Plugins",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Plugins configured in `opencode.json`")
                )
            } else {
                List {
                    Section(pluginCountTitle(store.plugins.count)) {
                        ForEach(store.plugins) { plugin in
                            if let bridge, isOpenClientPlugin(plugin.specifier) {
                                NavigationLink {
                                    OpenClientBridgeDiagnosticsView(bridge: bridge)
                                } label: {
                                    ConfiguredPluginRow(specifier: plugin.specifier)
                                }
                                .accessibilityIdentifier("plugins.openclient.diagnostics-link")
                            } else {
                                ConfiguredPluginRow(specifier: plugin.specifier)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .opencodeInlineNavigationTitle()
        .task {
            await viewModel.loadPluginsForConfiguration()
        }
    }

    private func isOpenClientPlugin(_ specifier: String) -> Bool {
        specifier.localizedCaseInsensitiveContains("openclient")
    }
}

private struct ConfiguredPluginRow: View {
    let specifier: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)

            Text(specifier)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(specifier), configured")
    }
}

private struct ProviderConfigurationRow: View {
    let providerID: String
    let providerName: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ProviderLogo(providerID: providerID)

            VStack(alignment: .leading, spacing: 3) {
                Text(providerName)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

}

private struct ProviderLogo: View {
    let providerID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(brand.background)

            Group {
                if let image = UIImage(named: assetName) {
                    Image(uiImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .padding(7)
                } else {
                    Image(systemName: "server.rack")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(brand.foreground)
        }
        .frame(width: 32, height: 32)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(brand.usesLightStroke ? 0.3 : 0), lineWidth: 1)
        }
        .shadow(color: brand.shadow.opacity(0.18), radius: 4, x: 0, y: 2)
        .accessibilityHidden(true)
    }

    private var assetName: String {
        "ProviderIcon_\(providerID)"
    }

    private var brand: ProviderLogoBrand {
        ProviderLogoBrand(providerID: providerID)
    }
}

private struct ProviderLogoBrand {
    let background: Color
    let foreground: Color
    let shadow: Color
    let usesLightStroke: Bool

    init(providerID: String) {
        switch providerID {
        case "openai":
            background = Color(red: 0.05, green: 0.06, blue: 0.055)
            foreground = .white
            shadow = .black
            usesLightStroke = true
        case "anthropic":
            background = Color(red: 0.86, green: 0.45, blue: 0.22)
            foreground = Color(red: 0.12, green: 0.08, blue: 0.05)
            shadow = background
            usesLightStroke = false
        case "google", "google-vertex", "google-vertex-anthropic":
            background = Color(red: 0.26, green: 0.52, blue: 0.96)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "github-copilot", "github-models":
            background = Color(red: 0.10, green: 0.12, blue: 0.16)
            foreground = .white
            shadow = .black
            usesLightStroke = true
        case "openrouter":
            background = Color(red: 0.08, green: 0.10, blue: 0.16)
            foreground = Color(red: 0.80, green: 0.88, blue: 1.0)
            shadow = .black
            usesLightStroke = true
        case "opencode":
            background = Color(red: 0.39, green: 0.24, blue: 0.92)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "opencode-go":
            background = Color(red: 0.05, green: 0.62, blue: 0.78)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "vercel", "xai", "ollama-cloud", "lmstudio":
            background = .black
            foreground = .white
            shadow = .black
            usesLightStroke = true
        case "mistral":
            background = Color(red: 1.0, green: 0.61, blue: 0.13)
            foreground = Color(red: 0.14, green: 0.08, blue: 0.02)
            shadow = background
            usesLightStroke = false
        case "deepseek":
            background = Color(red: 0.19, green: 0.36, blue: 0.95)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "perplexity":
            background = Color(red: 0.11, green: 0.65, blue: 0.64)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "groq":
            background = Color(red: 0.94, green: 0.28, blue: 0.14)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "cohere":
            background = Color(red: 0.20, green: 0.56, blue: 0.42)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "togetherai", "fireworks-ai":
            background = Color(red: 0.46, green: 0.28, blue: 0.95)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "amazon-bedrock":
            background = Color(red: 1.0, green: 0.60, blue: 0.0)
            foreground = Color(red: 0.10, green: 0.08, blue: 0.04)
            shadow = background
            usesLightStroke = false
        case "azure":
            background = Color(red: 0.00, green: 0.47, blue: 0.84)
            foreground = .white
            shadow = background
            usesLightStroke = false
        case "cloudflare-workers-ai", "cloudflare-ai-gateway":
            background = Color(red: 0.96, green: 0.45, blue: 0.05)
            foreground = .white
            shadow = background
            usesLightStroke = false
        default:
            background = Color.accentColor.opacity(0.16)
            foreground = Color.accentColor
            shadow = .clear
            usesLightStroke = false
        }
    }
}

private struct ProviderModelVisibilityView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    let providerID: String
    @State private var query = ""
    @State private var modelItems: [ModelConfigurationModelEntry] = []
    @State private var visibilityStates: [String: Bool] = [:]
    @State private var hasLoadedSnapshot = false

    private var provider: OpenCodeProvider? {
        viewModel.modelConfigurationStore.provider(id: providerID)
    }

    var body: some View {
        List {
            if viewModel.isLoadingProviders && !hasLoadedSnapshot {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading models...")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if provider != nil {
                Section {
                    Toggle("Show All Models", isOn: Binding(
                        get: { !modelItems.isEmpty && modelItems.allSatisfy { visibilityStates[$0.id] == true } },
                        set: { isVisible in
                            for item in modelItems {
                                visibilityStates[item.id] = isVisible
                                viewModel.setModelVisibility(item.reference, isVisible: isVisible)
                            }
                        }
                    ))
                } footer: {
                    Text("Controls which models appear in model pickers on this device, matching the upstream web UI preference behavior.")
                }

                Section("Models") {
                    if modelItems.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Loading models...")
                                .foregroundStyle(.secondary)
                        }
                    } else if filteredModelItems.isEmpty {
                        ContentUnavailableView("No Models", systemImage: "magnifyingglass")
                    } else {
                        ForEach(filteredModelItems) { item in
                            Toggle(isOn: Binding(
                                get: { visibilityStates[item.id] ?? true },
                                set: { isVisible in
                                    visibilityStates[item.id] = isVisible
                                    viewModel.setModelVisibility(item.reference, isVisible: isVisible)
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.model.name.replacingOccurrences(of: "(latest)", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
                                    Text(item.model.id)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Provider Unavailable", systemImage: "server.rack")
            }
        }
        .task(id: providerID) {
            reloadSnapshot()
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle(provider?.name ?? String(localized: "Provider"))
        .opencodeInlineNavigationTitle()
    }

    private var filteredModelItems: [ModelConfigurationModelEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return modelItems }
        return modelItems.filter { item in
            item.model.name.localizedCaseInsensitiveContains(trimmed) || item.model.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private func reloadSnapshot() {
        guard let provider else {
            modelItems = []
            visibilityStates = [:]
            hasLoadedSnapshot = true
            return
        }
        modelItems = viewModel.modelEntries(for: provider)
        visibilityStates = viewModel.modelVisibilityStates(for: provider)
        hasLoadedSnapshot = true
    }
}

private struct AddProviderView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    @State private var query = ""

    var body: some View {
        List {
            Section {
                NavigationLink(value: ConfigurationRoute.customProvider) {
                    Label("Custom Provider", systemImage: "slider.horizontal.3")
                }
            }

            Section("Popular") {
                ForEach(filtered(viewModel.popularAddableProviders)) { provider in
                    NavigationLink(value: ConfigurationRoute.providerConnect(provider.id)) {
                        ProviderConfigurationRow(providerID: provider.id, providerName: provider.name, subtitle: providerSubtitle(provider))
                    }
                }
            }

            let other = filtered(viewModel.addableProviders.filter { !ModelConfigurationStore.popularProviderIDs.contains($0.id) })
            if !other.isEmpty {
                Section("Other") {
                    ForEach(other) { provider in
                        NavigationLink(value: ConfigurationRoute.providerConnect(provider.id)) {
                            ProviderConfigurationRow(providerID: provider.id, providerName: provider.name, subtitle: providerSubtitle(provider))
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search providers")
        .navigationTitle("Add Provider")
        .opencodeInlineNavigationTitle()
        .task {
            await viewModel.loadProvidersForConfiguration()
        }
    }

    private func filtered(_ providers: [OpenCodeProvider]) -> [OpenCodeProvider] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return providers }
        return providers.filter { $0.name.localizedCaseInsensitiveContains(trimmed) || $0.id.localizedCaseInsensitiveContains(trimmed) }
    }

    private func providerSubtitle(_ provider: OpenCodeProvider) -> String {
        let labels = viewModel.authMethods(for: provider).map { method in
            if method.type == "api" { return String(localized: "API Key") }
            if method.type == "oauth" { return method.label.isEmpty ? String(localized: "OAuth") : method.label }
            return method.label.isEmpty ? method.type.capitalized : method.label
        }
        let unique = Array(NSOrderedSet(array: labels)) as? [String] ?? labels
        return providerSummary(source: unique.formatted(), modelCount: provider.models.count)
    }
}

private struct ProviderConnectView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    let provider: OpenCodeProvider
    let returnToRoot: () -> Void

    private var methods: [OpenCodeProviderAuthMethod] {
        viewModel.authMethods(for: provider)
    }

    var body: some View {
        Group {
            if methods.count == 1, let method = methods.first {
                ProviderConnectMethodView(viewModel: viewModel, provider: provider, method: method, methodIndex: 0, returnToRoot: returnToRoot)
            } else {
                List {
                    Section {
                        ForEach(Array(methods.enumerated()), id: \.offset) { index, method in
                            NavigationLink(value: ConfigurationRoute.providerMethod(provider.id, index)) {
                                Label(methodLabel(method), systemImage: method.type == "oauth" ? "person.badge.key" : "key")
                            }
                        }
                    } footer: {
                        Text("Choose how this OpenCode server should authenticate with \(provider.name).")
                    }
                }
                .navigationTitle(provider.name)
                .opencodeInlineNavigationTitle()
            }
        }
    }

    private func methodLabel(_ method: OpenCodeProviderAuthMethod) -> String {
        if method.type == "api" { return String(localized: "API Key") }
        return method.label
    }
}

private struct ProviderConnectMethodView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    let provider: OpenCodeProvider
    let method: OpenCodeProviderAuthMethod
    let methodIndex: Int
    let returnToRoot: () -> Void

    var body: some View {
        if method.type == "oauth" {
            ProviderOAuthConnectView(viewModel: viewModel, provider: provider, method: method, methodIndex: methodIndex, returnToRoot: returnToRoot)
        } else {
            ProviderAPIKeyConnectView(viewModel: viewModel, provider: provider, returnToRoot: returnToRoot)
        }
    }
}

private struct ProviderOAuthConnectView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    let provider: OpenCodeProvider
    let method: OpenCodeProviderAuthMethod
    let methodIndex: Int
    let returnToRoot: () -> Void

    @State private var inputs: [String: String] = [:]
    @State private var promptIndex = 0
    @State private var authorization: OpenCodeProviderAuthAuthorization?
    @State private var code = ""
    @State private var isAuthorizing = false
    @State private var isCompleting = false
    @State private var didAutoAuthorize = false
    @State private var didPresentAuthorizationURL = false
    @State private var didStartAutoCallback = false
    @State private var errorMessage: String?
    @State private var browserURL: ProviderOAuthBrowserURL?
    @State private var didCopyCode = false

    private var prompts: [OpenCodeProviderAuthMethod.Prompt] {
        method.prompts ?? []
    }

    private var currentPrompt: OpenCodeProviderAuthMethod.Prompt? {
        prompts.enumerated().first { index, prompt in
            index >= promptIndex && prompt.matches(inputs)
        }?.element
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ProviderLogo(providerID: provider.id)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name)
                        Text(method.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if let prompt = currentPrompt, authorization == nil {
                promptSection(prompt)
            } else if let authorization {
                authorizationSection(authorization)
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text(isAuthorizing ? LocalizedStringResource("Starting OAuth...") : LocalizedStringResource("Preparing OAuth..."))
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("OpenCode will start the OAuth flow and store the resulting credentials on the server.")
                }
            }
        }
        .navigationTitle(provider.name)
        .opencodeInlineNavigationTitle()
        .toolbar {
            if currentPrompt?.type == "text", authorization == nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await advancePromptOrAuthorize() }
                    } label: {
                        if isAuthorizing { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .disabled(!canContinueTextPrompt)
                    .accessibilityLabel("Continue")
                }
            } else if authorization?.method == "code" {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await complete(code: code) }
                    } label: {
                        if isCompleting { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCompleting)
                    .accessibilityLabel("Complete OAuth")
                }
            }
        }
        .task(id: authorization) {
            guard let authorization else { return }
            presentAuthorizationURLIfNeeded(authorization)
            guard authorization.method == "auto", !didStartAutoCallback else { return }
            didStartAutoCallback = true
            await complete(code: nil)
        }
        .task {
            guard !didAutoAuthorize, prompts.isEmpty, authorization == nil else { return }
            didAutoAuthorize = true
            await authorize()
        }
        .safeAreaInset(edge: .bottom) {
            if let code = confirmationCode {
                ProviderOAuthCopyCodeButton(code: code, didCopy: didCopyCode) {
                    OpenCodeClipboard.copy(code)
                    OpenCodeHaptics.impact(.crisp)
                    didCopyCode = true
                }
            }
        }
        .fullScreenCover(item: $browserURL) { item in
            ProviderOAuthBrowserSheet(url: item.url, confirmationCode: confirmationCode)
        }
    }

    @ViewBuilder
    private func promptSection(_ prompt: OpenCodeProviderAuthMethod.Prompt) -> some View {
        if prompt.type == "select" {
            Section(prompt.message) {
                ForEach(prompt.options ?? []) { option in
                    Button {
                        inputs[prompt.key] = option.value
                        Task { await advancePromptOrAuthorize() }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.label)
                                if let hint = option.hint {
                                    Text(hint)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if inputs[prompt.key] == option.value {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        } else {
            Section {
                TextField(prompt.placeholder ?? prompt.message, text: Binding(
                    get: { inputs[prompt.key] ?? "" },
                    set: { inputs[prompt.key] = $0 }
                ))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            } header: {
                Text(prompt.message)
            }
        }
    }

    @ViewBuilder
    private func authorizationSection(_ authorization: OpenCodeProviderAuthAuthorization) -> some View {
        Section {
            Text(authorization.instructions)
                .foregroundStyle(.secondary)

            if let url = URL(string: authorization.url) {
                Button {
                    browserURL = ProviderOAuthBrowserURL(url: url)
                } label: {
                    Label("Open Browser", systemImage: "safari")
                }

                Button {
                    browserURL = ProviderOAuthBrowserURL(url: url)
                } label: {
                    Label("Open Again", systemImage: "arrow.clockwise")
                }
            }

            if let confirmationCode = confirmationCode(from: authorization.instructions), authorization.method == "auto" {
                LabeledContent("Code", value: confirmationCode)
                    .fontDesign(.monospaced)
            }

            if authorization.method == "auto" {
                HStack {
                    ProgressView()
                    Text(isCompleting ? LocalizedStringResource("Waiting for authorization...") : LocalizedStringResource("Ready to complete"))
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("Authorization code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } footer: {
            if authorization.url.contains("localhost") || authorization.url.contains("127.0.0.1") {
                Text("If this opens a localhost callback, complete it on the machine running OpenCode. Device-code flows can be completed from this iPhone.")
            }
        }
    }

    private var canContinueTextPrompt: Bool {
        guard let prompt = currentPrompt, prompt.type == "text" else { return false }
        return !(inputs[prompt.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isAuthorizing
    }

    private func advancePromptOrAuthorize() async {
        if let prompt = currentPrompt,
           let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
            let next = prompts.enumerated().first { offset, candidate in
                offset > index && candidate.matches(inputs)
            }?.offset
            if let next {
                promptIndex = next
                return
            }
        }
        await authorize()
    }

    private func authorize() async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        errorMessage = nil
        let result = await viewModel.authorizeProviderOAuth(providerID: provider.id, methodIndex: methodIndex, inputs: inputs)
        isAuthorizing = false
        if let result {
            authorization = result
            presentAuthorizationURLIfNeeded(result)
        } else {
            errorMessage = viewModel.errorMessage ?? String(localized: "OAuth authorization failed.")
        }
    }

    private func complete(code: String?) async {
        guard !isCompleting else { return }
        isCompleting = true
        errorMessage = nil
        if await viewModel.completeProviderOAuth(providerID: provider.id, methodIndex: methodIndex, code: code) {
            browserURL = nil
            returnToRoot()
        } else {
            errorMessage = viewModel.errorMessage ?? String(localized: "OAuth authorization did not complete.")
        }
        isCompleting = false
    }

    private var confirmationCode: String? {
        guard let authorization, authorization.method == "auto" else { return nil }
        return confirmationCode(from: authorization.instructions)
    }

    private func presentAuthorizationURLIfNeeded(_ authorization: OpenCodeProviderAuthAuthorization) {
        guard !didPresentAuthorizationURL, let url = URL(string: authorization.url) else { return }
        didPresentAuthorizationURL = true
        browserURL = ProviderOAuthBrowserURL(url: url)
    }

    private func confirmationCode(from instructions: String) -> String? {
        guard let value = instructions.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines), value != instructions else {
            return nil
        }
        return value.isEmpty ? nil : value
    }
}

private extension OpenCodeProviderAuthMethod.Prompt {
    func matches(_ inputs: [String: String]) -> Bool {
        guard let when else { return true }
        guard let actual = inputs[when.key] else { return false }
        if when.op == "eq" { return actual == when.value }
        return actual != when.value
    }
}

private struct ProviderOAuthBrowserURL: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}

private struct ProviderOAuthBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let confirmationCode: String?
    @State private var didCopyCode = false
    #if canImport(UIKit)
    @State private var keyboardHeight: CGFloat = 0
    #endif

    var body: some View {
        #if canImport(UIKit)
        ProviderOAuthSafariView(url: url) {
            dismiss()
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottomTrailing) {
            if let confirmationCode {
                ProviderOAuthCopyCodeButton(code: confirmationCode, didCopy: didCopyCode) {
                    OpenCodeClipboard.copy(confirmationCode)
                    OpenCodeHaptics.impact(.crisp)
                    didCopyCode = true
                }
                .padding(.trailing, 12)
                .padding(.bottom, copyButtonBottomPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: keyboardHeight)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            keyboardHeight = keyboardHeight(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardHeight = 0
        }
        #else
        NavigationStack {
            ContentUnavailableView {
                Label("Continue in Browser", systemImage: "safari")
            } description: {
                Text("Open the provider authorization page in your default browser.")
            } actions: {
                Link("Open Authorization Page", destination: url)
                if let confirmationCode {
                    Button {
                        OpenCodeClipboard.copy(confirmationCode)
                        didCopyCode = true
                    } label: {
                        Text(didCopyCode ? LocalizedStringResource("Code Copied") : LocalizedStringResource("Copy Confirmation Code"))
                    }
                }
            }
            .navigationTitle("Provider Authorization")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        #endif
    }

    #if canImport(UIKit)
    private func keyboardHeight(from notification: Notification) -> CGFloat {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return 0 }
        return max(0, UIScreen.main.bounds.maxY - frame.minY)
    }

    private var copyButtonBottomPadding: CGFloat {
        keyboardHeight > 0 ? keyboardHeight + 8 : 96
    }
    #endif
}

private struct ProviderOAuthCopyCodeButton: View {
    let code: String
    let didCopy: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 10) {
                Text(code)
                    .font(.headline.monospaced())
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 16, x: 0, y: 8)
        .padding(.leading, 16)
    }
}

#if canImport(UIKit)
private struct ProviderOAuthSafariView: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}
#endif

private struct ProviderAPIKeyConnectView: View {
    @ObservedObject var viewModel: ConfigurationsFacade
    let provider: OpenCodeProvider
    let returnToRoot: () -> Void
    @State private var apiKey = ""
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                Text("Connect \(provider.name) with an API key stored by the OpenCode server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("API Key", text: $apiKey)
                    .textContentType(.password)
            }

            Section {
                if providerModels.isEmpty {
                    Text("No models reported for this provider yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(providerModels.prefix(12)), id: \.id) { model in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(cleanModelName(model.name))
                                .foregroundStyle(.primary)
                            Text(model.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if providerModels.count > 12 {
                        Text(additionalModelCountTitle(providerModels.count - 12))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("This read-only list comes from the provider catalog returned by OpenCode.")
            }
        }
        .navigationTitle(provider.name)
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(!canConnect)
                .accessibilityLabel("Connect Provider")
            }
        }
    }

    private var canConnect: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    private func save() async {
        guard canConnect else { return }
        isSaving = true
        if await viewModel.connectProviderWithAPIKey(providerID: provider.id, key: apiKey) {
            returnToRoot()
        }
        isSaving = false
    }

    private var providerModels: [OpenCodeModel] {
        viewModel.models(for: provider)
    }

    private func cleanModelName(_ name: String) -> String {
        name.replacingOccurrences(of: "(latest)", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct CustomProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ConfigurationsFacade
    @State private var draft = OpenCodeCustomProviderDraft()
    @State private var isSaving = false

    var body: some View {
        Form {
            Section("Provider") {
                TextField("Provider ID", text: $draft.providerID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Display Name", text: $draft.name)
                TextField("Base URL", text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key or {env:VAR_NAME}", text: $draft.apiKey)
            }

            Section("Models") {
                ForEach($draft.models) { $model in
                    HStack {
                        TextField("Model ID", text: $model.modelID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Name", text: $model.name)
                    }
                }
                .onDelete { offsets in
                    guard draft.models.count > 1 else { return }
                    draft.models.remove(atOffsets: offsets)
                }

                Button("Add Model") {
                    draft.models.append(OpenCodeCustomProviderDraft.ModelRow())
                }
            }

            Section("Headers") {
                ForEach($draft.headers) { $header in
                    HStack {
                        TextField("Key", text: $header.key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Value", text: $header.value)
                    }
                }
                .onDelete { offsets in
                    guard draft.headers.count > 1 else { return }
                    draft.headers.remove(atOffsets: offsets)
                }

                Button("Add Header") {
                    draft.headers.append(OpenCodeCustomProviderDraft.HeaderRow())
                }
            }

        }
        .navigationTitle("Custom Provider")
        .opencodeInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Image(systemName: "checkmark")
                    }
                }
                .disabled(!canSave)
                .accessibilityLabel("Save Provider")
            }
        }
    }

    private var canSave: Bool {
        guard !isSaving else { return false }
        let providerID = draft.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerID.range(of: #"^[a-z0-9][a-z0-9-_]*$"#, options: .regularExpression) != nil else { return false }
        guard !name.isEmpty else { return false }
        guard baseURL.hasPrefix("http://") || baseURL.hasPrefix("https://") else { return false }

        let modelPairs = draft.models.map {
            ($0.modelID.trimmingCharacters(in: .whitespacesAndNewlines), $0.name.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !modelPairs.isEmpty, modelPairs.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else { return false }
        guard Set(modelPairs.map(\.0)).count == modelPairs.count else { return false }

        let headers = draft.headers
            .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty || !$0.1.isEmpty }
        guard headers.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else { return false }
        guard Set(headers.map { $0.0.lowercased() }).count == headers.count else { return false }
        return true
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        if await viewModel.saveCustomProvider(draft) {
            dismiss()
        }
        isSaving = false
    }
}

private struct AgentDefaultSelectionView: View {
    @ObservedObject var viewModel: ConfigurationsFacade

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultAgent(nil as String?)
                } label: {
                    selectionRow(title: String(localized: "Use System Default"), isSelected: viewModel.newSessionDefaults.agentName == nil)
                }
                .buttonStyle(.plain)
            }

            Section("Options") {
                ForEach(viewModel.selectableAgents) { agent in
                    Button {
                        viewModel.setNewSessionDefaultAgent(agent.name)
                    } label: {
                        selectionRow(title: agent.name.capitalized, isSelected: viewModel.newSessionDefaults.agentName == agent.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Agent")
        .opencodeInlineNavigationTitle()
    }
}

private struct ModelDefaultSelectionView: View {
    @ObservedObject var viewModel: ConfigurationsFacade

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultModel(nil as OpenCodeModelReference?)
                } label: {
                    selectionRow(title: String(localized: "Use System Default"), isSelected: viewModel.newSessionDefaultModelReference() == nil)
                }
                .buttonStyle(.plain)
            }

            ForEach(viewModel.sortedProviders) { provider in
                Section(provider.name) {
                    ForEach(viewModel.modelConfigurationStore.visibleModels(for: provider), id: \.id) { model in
                        let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                        Button {
                            viewModel.setNewSessionDefaultModel(reference)
                        } label: {
                            selectionRow(title: model.name, isSelected: viewModel.newSessionDefaultModelReference() == reference)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Model")
        .opencodeInlineNavigationTitle()
    }
}

private struct VoiceModeModelSelectionView: View {
    @ObservedObject var viewModel: ConfigurationsFacade

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setVoiceModeModel(nil as OpenCodeModelReference?)
                } label: {
                    selectionRow(
                        title: String(localized: "Use New Session Default"),
                        isSelected: viewModel.voiceModeModelReference() == nil
                    )
                }
                .buttonStyle(.plain)
            }

            ForEach(viewModel.sortedProviders) { provider in
                Section(provider.name) {
                    ForEach(viewModel.modelConfigurationStore.visibleModels(for: provider), id: \.id) { model in
                        let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                        Button {
                            viewModel.setVoiceModeModel(reference)
                        } label: {
                            selectionRow(title: model.name, isSelected: viewModel.voiceModeModelReference() == reference)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Talk Model")
        .opencodeInlineNavigationTitle()
    }
}

private struct ReasoningDefaultSelectionView: View {
    @ObservedObject var viewModel: ConfigurationsFacade

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultReasoning(nil as String?)
                } label: {
                    selectionRow(title: String(localized: "Use System Default"), isSelected: viewModel.newSessionDefaults.reasoningVariant == nil)
                }
                .buttonStyle(.plain)
            }

            Section("Options") {
                ForEach(viewModel.configurationReasoningVariants, id: \.self) { variant in
                    Button {
                        viewModel.setNewSessionDefaultReasoning(variant)
                    } label: {
                        selectionRow(
                            title: viewModel.formattedVariantTitle(variant),
                            isSelected: viewModel.newSessionDefaults.reasoningVariant == variant
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Reasoning")
        .opencodeInlineNavigationTitle()
    }
}

private func selectionRow(title: String, isSelected: Bool) -> some View {
    HStack {
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "checkmark")
                .foregroundStyle(.clear)
        }

        Text(title)
            .foregroundStyle(.primary)
        Spacer()
    }
    .contentShape(Rectangle())
}

private func providerSummary(source: String, modelCount: Int) -> String {
    if modelCount == 1 {
        return String(localized: "\(source) • 1 model")
    }
    return String(localized: "\(source) • \(modelCount) models")
}

private func pluginCountTitle(_ count: Int) -> String {
    count == 1 ? String(localized: "1 Plugin") : String(localized: "\(count) Plugins")
}

private func additionalModelCountTitle(_ count: Int) -> LocalizedStringResource {
    count == 1 ? "1 more model" : LocalizedStringResource("\(count) more models")
}
