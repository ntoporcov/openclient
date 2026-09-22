#if DEBUG && os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

private enum ChatHeaderFixtureData {
    static let providers = OpenCodeProviderListResponse(all: [OpenCodeProvider(id: "openai", name: "OpenAI", models: [
        "astra": OpenCodeModel(id: "astra", providerID: "openai", name: "GPT-6 Astra",
            capabilities: .init(reasoning: true), variants: ["high": .bool(true), "extended_deliberation_for_complex_tasks": .bool(true)]),
        "astra-long": OpenCodeModel(id: "astra-long", providerID: "openai", name: "GPT-6 Astra Extended Context Research Preview",
            capabilities: .init(reasoning: true), variants: ["high": .bool(true), "extended_deliberation_for_complex_tasks": .bool(true)])
    ])], connected: ["openai"], default: ["openai": "astra"])

    static var agents: [OpenCodeAgent] {
        let many = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_MANY_AGENTS"] == "1"
        return (many ? (0..<24).map { "Agent \($0)" } : ["build", "plan", "ReviewAgent"]).map {
            .init(name: $0, description: "\($0) agent description", mode: "all", hidden: false, model: nil, variant: nil)
        }
    }
}

// All transport is intercepted, including incidental chat hydration requests.
private final class ChatHeaderFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = Data("[]".utf8)
        if request.url?.path == "/provider" {
            data = (try? JSONEncoder().encode(ChatHeaderFixtureData.providers)) ?? data
        } else if request.url?.path == "/agent" {
            data = (try? JSONEncoder().encode(ChatHeaderFixtureData.agents)) ?? data
        } else if request.url?.path == "/config/providers" {
            data = (try? JSONEncoder().encode(OpenCodeProvidersResponse(
                providers: ChatHeaderFixtureData.providers.all, default: ChatHeaderFixtureData.providers.default))) ?? data
        }
        if request.httpMethod == "PATCH" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                var collected = Data()
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    collected.append(buffer, count: count)
                }
                body = collected
            }
            let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            data = (try? JSONSerialization.data(withJSONObject: ["id": "header-b", "title": json?["title"] as? String ?? "",
                "directory": "/header", "projectID": "header-project"])) ?? data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct ChatHeaderFixture: View {
    @StateObject private var model: AppViewModel
    @State private var facade: ChatFacade
    @State private var path = ["chat"]

    init() {
        let model = AppViewModel(appCustomizationStore: AppCustomizationStore(storageKey: "chatHeaderFixtureAppearance"))
        model.config = .init(baseURL: "https://chat-header.invalid", apiPreference: .legacy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatHeaderFixtureProtocol.self]
        let adapter = OpenCodeBackendAdapter(client: .init(config: model.config, session: URLSession(configuration: configuration)), profile: .legacy)
        let connection = BackendConnection(descriptor: .init(id: "header", name: "Header", version: "1"),
            capabilities: [.liveActivities], projects: adapter, sessions: adapter, chat: adapter, models: adapter,
            events: OpenCodeBackendEventSource(client: adapter.client, profile: .legacy, manager: model.eventManager))
        model.backendConnection = connection
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        let usesAssistantComposer = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_ASSISTANT"] == "1"
        model.appCustomizationStore.setComposerStyleForFixture(usesAssistantComposer ? .assistant : .messenger)
        model.directoryStoreRegistry.activate("/header")
        let shortTitle = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_SHORT_TITLE"] == "1"
        let session = OpenCodeSession(id: "header-b", title: shortTitle ? "V2 work" : "A long chat title about building a thoughtful native client without losing the full session name",
            workspaceID: nil, directory: "/header", projectID: "header-project", parentID: nil)
        model.directoryStore.sessions = [session]
        model.selectedSession = session
        model.chatStore.finishLoadingSelectedSession()
        let many = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_MANY_AGENTS"] == "1"
        model.modelConfigurationStore.availableAgents = ChatHeaderFixtureData.agents
        model.modelConfigurationStore.applyProviderState(ChatHeaderFixtureData.providers)
        let longLabels = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_LONG_MODEL"] == "1"
        model.modelConfigurationStore.selectModel(.init(providerID: "openai", modelID: longLabels ? "astra-long" : "astra"), forSessionID: session.id)
        model.modelConfigurationStore.selectVariant(shortTitle ? nil : (longLabels ? "extended_deliberation_for_complex_tasks" : "high"), forSessionID: session.id)
        model.modelConfigurationStore.selectAgent(named: many ? "Agent 0" : "build", forSessionID: session.id)
        model.liveActivityFacade = LiveActivityFacade(viewModel: model, requestOrUpdate: { _ in }, activityRecords: { [] }, endActivity: { _, _, _, _ in })
        let window = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_WINDOW"] == "1"
        let context = window ? ChatWindowContext(model: model, connection: connection, session: session, owner: model.directoryStore) : nil
        let facade = context.map { ChatFacade(viewModel: model, windowContext: $0) } ?? model.chatFacade
        if window {
            let root = OpenCodeSession(id: "header-a", title: "Root A", workspaceID: nil, directory: "/root", projectID: "root", parentID: nil)
            model.directoryStoreRegistry.activate("/root")
            model.directoryStore.sessions = [root]
            model.selectedSession = root
            model.composerStore.draftMessage = "Root draft"
            model.modelConfigurationStore.selectModel(.init(providerID: "openai", modelID: "astra"), forSessionID: root.id)
            model.modelConfigurationStore.selectVariant("high", forSessionID: root.id)
        }
        _model = StateObject(wrappedValue: model)
        _facade = State(initialValue: facade)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Text("Sessions")
                .navigationTitle("Sessions")
                .navigationDestination(for: String.self) { _ in
                    ChatView(chatFacade: facade, browser: facade.windowContext?.browser ?? model.appShellFacade.browser,
                        sessionID: "header-b", isDedicatedWindow: facade.windowContext != nil)
                }
        }
        .frame(maxWidth: ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_NARROW"] == "1" ? 320 : (UIDevice.current.userInterfaceIdiom == .pad ? 650 : .infinity))
        .overlay(alignment: .bottomLeading) {
            VStack {
                Text(verbatim: model.selectedSession?.id ?? "")
                    .font(.caption2).foregroundStyle(.clear)
                    .accessibilityIdentifier("chat.header.fixture.root")
                    .accessibilityValue(Text(verbatim: "\(model.modelConfigurationStore.selectedModelReference(for: model.selectedSession?.id ?? "")?.modelID ?? "")|\(model.modelConfigurationStore.selectedVariant(for: model.selectedSession?.id ?? "") ?? "")"))
                Text(verbatim: model.modelConfigurationStore.selectedAgentName(for: "header-b") ?? "")
                    .font(.caption2).foregroundStyle(.clear)
                    .accessibilityIdentifier("chat.header.fixture.agent")
            }
        }
    }
}
#endif
