import Combine
import XCTest
@testable import OpenClient

@MainActor
final class ModelConfigurationStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
        super.tearDown()
    }

    func testApplyProviderStateUsesOnlyConnectedProvidersForSelection() {
        let store = ModelConfigurationStore()
        let openAI = provider(id: "openai", name: "OpenAI")
        let anthropic = provider(id: "anthropic", name: "Anthropic")

        store.applyProviderState(OpenCodeProviderListResponse(all: [openAI, anthropic], connected: ["openai"], default: ["openai": "gpt-5"]))

        XCTAssertEqual(store.allProviders.map(\.id).sorted(), ["anthropic", "openai"])
        XCTAssertEqual(store.availableProviders.map(\.id), ["openai"])
        XCTAssertEqual(store.addableProviders.map(\.id).sorted(), ["anthropic", "openai"])
        XCTAssertEqual(store.defaultModelReference(), OpenCodeModelReference(providerID: "openai", modelID: "gpt-5"))
    }

    func testModelVisibilityPreferenceOverridesDefaultVisibility() {
        let store = ModelConfigurationStore()
        let provider = provider(id: "openai", name: "OpenAI", releaseDate: "2020-01-01")
        store.applyProviderState(OpenCodeProviderListResponse(all: [provider], connected: ["openai"], default: [:]))
        let reference = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5")

        XCTAssertFalse(store.isModelVisible(reference))

        store.setModelVisibility(reference, isVisible: true)

        XCTAssertTrue(store.isModelVisible(reference))

        store.setModelVisibility(reference, isVisible: false)

        XCTAssertFalse(store.isModelVisible(reference))
    }

    func testProviderVisibilityTogglesEveryModel() {
        let store = ModelConfigurationStore()
        let provider = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            models: [
                "gpt-5": model(id: "gpt-5", providerID: "openai"),
                "gpt-5-mini": model(id: "gpt-5-mini", providerID: "openai"),
            ]
        )
        store.applyProviderState(OpenCodeProviderListResponse(all: [provider], connected: ["openai"], default: [:]))

        store.setProviderVisibility(provider, isVisible: false)

        XCTAssertFalse(store.isProviderFullyVisible(provider))
        XCTAssertTrue(store.visibleModels(for: provider).isEmpty)

        store.setProviderVisibility(provider, isVisible: true)

        XCTAssertTrue(store.isProviderFullyVisible(provider))
        XCTAssertEqual(store.visibleModels(for: provider).count, 2)
    }

    func testConfigBackedProviderIsNotTreatedAsCustomProvider() {
        let store = ModelConfigurationStore()
        let provider = provider(id: "github-copilot", name: "GitHub Copilot", source: "config")

        XCTAssertFalse(store.isConfigCustomProvider(provider))
        XCTAssertEqual(store.sourceTitle(for: provider), "Config")
    }

    func testVisibleModelsAreCappedForLargeConnectedCatalogs() {
        let store = ModelConfigurationStore()
        let models = Dictionary(uniqueKeysWithValues: (0 ..< 140).map { index in
            let id = String(format: "model-%03d", index)
            return (id, model(id: id, providerID: "openrouter"))
        })
        let provider = OpenCodeProvider(id: "openrouter", name: "OpenRouter", models: models)

        store.applyProviderState(OpenCodeProviderListResponse(all: [provider], connected: ["openrouter"], default: [:]))

        let visibleModels = store.visibleModels(for: provider)
        XCTAssertEqual(visibleModels.count, ModelConfigurationStore.visibleModelLimitPerProvider)
        XCTAssertEqual(visibleModels.first?.id, "model-000")
        XCTAssertEqual(visibleModels.last?.id, "model-079")
    }

    func testSyncingUnchangedComposerSelectionDoesNotPublish() {
        let store = ModelConfigurationStore(
            availableAgents: [
                OpenCodeAgent(
                    name: "build",
                    description: nil,
                    mode: "primary",
                    hidden: false,
                    model: nil,
                    variant: nil
                ),
            ],
            allProviders: [provider(id: "openai", name: "OpenAI")],
            availableProviders: [provider(id: "openai", name: "OpenAI")]
        )
        let model = OpenCodeMessageModelReference(providerID: "openai", modelID: "gpt-5", variant: nil)
        _ = store.syncSelections(forSessionID: "session", agent: "build", model: model)
        var publicationCount = 0
        let observation = store.objectWillChange.sink { publicationCount += 1 }

        _ = store.syncSelections(forSessionID: "session", agent: "build", model: model)

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testTimestampReleaseDateUsesDefaultVisibilityRules() {
        let store = ModelConfigurationStore()
        let oldProvider = provider(id: "openai", name: "OpenAI", releaseDate: "2020-01-01T00:00:00.000Z")
        store.applyProviderState(OpenCodeProviderListResponse(all: [oldProvider], connected: ["openai"], default: [:]))

        XCTAssertFalse(store.isModelVisible(OpenCodeModelReference(providerID: "openai", modelID: "gpt-5")))
    }

    func testPluginStorePreservesResolvedConfigOrder() throws {
        let config = try JSONDecoder().decode(
            OpenCodeResolvedConfig.self,
            from: Data(#"{"plugin":["zeta",["alpha",{"enabled":true}]]}"#.utf8)
        )
        let store = PluginStore()

        store.beginLoading(scope: "server|/tmp/project")
        store.apply(config, scope: "server|/tmp/project")
        store.finishLoading(scope: "server|/tmp/project")

        XCTAssertEqual(store.plugins.map(\.specifier), ["zeta", "alpha"])
        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
    }

    func testProviderScopeSkipsAlreadyLoadedCatalog() {
        let store = ModelConfigurationStore(allProviders: [provider(id: "openai", name: "OpenAI")])

        XCTAssertTrue(store.shouldLoadProviders(for: "server|/tmp/project"))

        store.markProvidersLoaded(for: "server|/tmp/project")

        XCTAssertFalse(store.shouldLoadProviders(for: "server|/tmp/project"))
        XCTAssertTrue(store.shouldLoadProviders(for: "server|/tmp/other"))
    }

    func testSanitizingValidDefaultsDoesNotPublishAChange() {
        let store = ModelConfigurationStore()
        var publicationCount = 0
        let observation = store.objectWillChange.sink { publicationCount += 1 }

        store.sanitizeNewSessionDefaults()

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testVoiceSessionUsesVoiceModelWithoutChangingNormalSessionDefault() {
        let openAI = OpenCodeProvider(
            id: "openai",
            name: "OpenAI",
            models: [
                "gpt-5": model(id: "gpt-5", providerID: "openai"),
                "gpt-5-mini": model(id: "gpt-5-mini", providerID: "openai"),
            ]
        )
        let store = ModelConfigurationStore(
            allProviders: [openAI],
            availableProviders: [openAI]
        )
        let normalModel = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5")
        let voiceModel = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5-mini")
        store.setNewSessionDefaultModel(normalModel)
        store.setVoiceModeModel(voiceModel)

        store.seedSelectionsForNewSession(sessionID: "chat")
        store.seedSelectionsForVoiceSession(sessionID: "voice")

        XCTAssertEqual(store.selectedModelReference(for: "chat"), normalModel)
        XCTAssertEqual(store.selectedModelReference(for: "voice"), voiceModel)
    }

    func testVoiceSessionFallsBackToNewSessionDefaultWhenUnset() {
        let openAI = provider(id: "openai", name: "OpenAI")
        let store = ModelConfigurationStore(
            allProviders: [openAI],
            availableProviders: [openAI]
        )
        let normalModel = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5")
        store.setNewSessionDefaultModel(normalModel)

        store.seedSelectionsForVoiceSession(sessionID: "voice")

        XCTAssertEqual(store.selectedModelReference(for: "voice"), normalModel)
    }

    func testSanitizeClearsUnavailableVoiceModel() {
        let store = ModelConfigurationStore()
        store.setVoiceModeModel(OpenCodeModelReference(providerID: "missing", modelID: "missing"))

        store.sanitizeNewSessionDefaults()

        XCTAssertNil(store.voiceModeModelReference())
        XCTAssertNil(store.newSessionDefaults.voiceModeProviderID)
        XCTAssertNil(store.newSessionDefaults.voiceModeModelID)
    }

    func testLegacyNewSessionDefaultsDecodeWithoutVoiceModel() throws {
        let data = Data(#"{"agentName":"build","providerID":"openai","modelID":"gpt-5"}"#.utf8)

        let defaults = try JSONDecoder().decode(NewSessionDefaults.self, from: data)

        XCTAssertEqual(defaults.agentName, "build")
        XCTAssertNil(defaults.voiceModeProviderID)
        XCTAssertNil(defaults.voiceModeModelID)
    }

    private func provider(id: String, name: String, releaseDate: String? = nil, source: String? = nil) -> OpenCodeProvider {
        OpenCodeProvider(id: id, name: name, models: ["gpt-5": model(id: "gpt-5", providerID: id, releaseDate: releaseDate)], source: source)
    }

    private func model(id: String, providerID: String, releaseDate: String? = nil) -> OpenCodeModel {
        OpenCodeModel(
            id: id,
            providerID: providerID,
            name: id,
            capabilities: OpenCodeModelCapabilities(reasoning: false),
            releaseDate: releaseDate
        )
    }
}
