import XCTest
@testable import OpenClient

@MainActor
final class ProviderUsageDiscoveryTests: XCTestCase {
    func testSupportedProviderCatalogIsStableAndOwnsOpenCodeMappings() {
        XCTAssertEqual(ProviderUsageProvider.allCases, [.codex, .openRouter])
        XCTAssertEqual(ProviderUsageProvider.allCases.map(\.id), ["codex", "openrouter"])
        XCTAssertEqual(ProviderUsageProvider.codex.openCodeProviderID, "openai")
        XCTAssertEqual(ProviderUsageProvider.codex.legacyCredentialKind, .oauthAccessToken)
        XCTAssertEqual(ProviderUsageProvider.openRouter.openCodeProviderID, "openrouter")
        XCTAssertEqual(ProviderUsageProvider.openRouter.legacyCredentialKind, .apiKey)
        XCTAssertNil(ProviderUsageProvider(openCodeProviderID: "anthropic"))
    }

    func testLegacyDiscoveryUsesConnectedExactIDsOnlyAndDoesNotCarrySecrets() {
        let store = ModelConfigurationStore()
        let secret = "synthetic-key-must-not-propagate"
        store.applyProviderState(.init(
            all: [
                provider(id: "openai", name: "Codex candidate", source: "api", key: secret),
                provider(id: "openrouter", name: "Disconnected", source: "api", key: "synthetic-other"),
                provider(id: "custom-openai", name: "OpenAI", source: "api", key: "synthetic-fuzzy"),
            ],
            connected: ["openai", "custom-openai"],
            default: [:]
        ))

        let result = discover(.legacy, legacy: ProviderUsageDiscovery.legacyState(from: store))

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertEqual(result.candidates.map(\.provider), [.codex])
        XCTAssertEqual(result.candidates.map(\.expectedCredentialKind), [.oauthAccessToken])
        XCTAssertEqual(result.candidates.map(\.id.source), [.legacyProvider(providerID: "openai")])
        XCTAssertEqual(
            result.candidates.first?.availability,
            .available(sourceKind: .openCodeAuth, credentialKind: .oauthAccessToken)
        )
        XCTAssertFalse(String(reflecting: result).contains(secret))
        XCTAssertFalse(String(reflecting: result).contains("synthetic-fuzzy"))
    }

    func testLegacyReadinessDistinguishesNotHydratedFromHydratedEmptyAndReset() {
        let store = ModelConfigurationStore()

        let pending = discover(.legacy, legacy: ProviderUsageDiscovery.legacyState(from: store))
        XCTAssertEqual(pending.readiness, .notHydrated)
        XCTAssertTrue(pending.candidates.isEmpty)

        store.applyProviderState(.init(all: [], connected: [], default: [:]))
        let empty = discover(.legacy, legacy: ProviderUsageDiscovery.legacyState(from: store))
        XCTAssertEqual(empty.readiness, .ready)
        XCTAssertTrue(empty.candidates.isEmpty)

        store.reset()
        XCTAssertEqual(ProviderUsageDiscovery.legacyState(from: store).readiness, .notHydrated)
    }

    func testLegacySupportedProvidersAreSelectableRegardlessOfDefinitionSource() {
        let sources: [ProviderUsageLegacySource] = [.api, .custom, .environment, .config, .unspecified]
        let descriptors = sources.flatMap { source in
            [
                ProviderUsageLegacyProviderDescriptor(id: "openai", label: "OpenAI", source: source),
                ProviderUsageLegacyProviderDescriptor(id: "openrouter", label: "OpenRouter", source: source),
            ]
        }
        let result = discover(
            .legacy,
            legacy: .init(
                readiness: .ready,
                connectedProviders: descriptors + [
                    .init(id: "custom-openai", label: "Unsupported", source: .api),
                    .init(id: "anthropic", label: "Unsupported", source: .api),
                ]
            )
        )

        XCTAssertEqual(result.candidates.count, descriptors.count)
        XCTAssertTrue(result.candidates.allSatisfy { candidate in
            candidate.availability == .available(
                sourceKind: .openCodeAuth,
                credentialKind: candidate.provider.legacyCredentialKind
            )
        })
        XCTAssertTrue(result.candidates.allSatisfy {
            ["openai", "openrouter"].contains($0.provider.openCodeProviderID)
        })
    }

    func testV2IncludesConfiguredCredentialConnectionsOnlyAndFailsClosedOnCredentialKind() {
        let integration = OpenCodeV2Integration(
            id: "openrouter",
            name: "OpenRouter",
            methods: [.key(label: nil, form: [])],
            connections: [
                .credential(id: "credential-one", label: "Same label"),
                .credential(id: "credential-two", label: "Same label"),
                .env(name: "OPENROUTER_API_KEY"),
            ],
            metadata: ["arbitrary": .string("synthetic-metadata-must-not-propagate")]
        )
        let catalogOnly = OpenCodeV2Integration(
            id: "openai",
            name: "OpenAI",
            methods: [.oauth(id: "oauth", label: "OAuth", form: [])],
            connections: [],
            metadata: nil
        )
        let fuzzyNameOnly = OpenCodeV2Integration(
            id: "custom-openrouter",
            name: "OpenRouter",
            methods: [.key(label: nil, form: [])],
            connections: [.credential(id: "credential-fuzzy", label: "Same label")],
            metadata: nil
        )
        let store = V2ProviderStore()
        store.integrations = [integration, catalogOnly, fuzzyNameOnly]
        store.isReady = true

        let result = discover(.v2, v2: ProviderUsageDiscovery.v2State(from: store))

        XCTAssertEqual(result.readiness, .ready)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(Set(result.candidates.map(\.sourceLabel)), ["Same label"])
        XCTAssertEqual(
            Set(result.candidates.map(\.id.source)),
            [
                .v2Credential(integrationID: "openrouter", credentialID: "credential-one"),
                .v2Credential(integrationID: "openrouter", credentialID: "credential-two"),
            ]
        )
        XCTAssertTrue(result.candidates.allSatisfy { $0.availability == .unavailable(.v2CredentialKindUnknown) })
        XCTAssertTrue(result.candidates.allSatisfy { $0.expectedCredentialKind == nil })
        XCTAssertFalse(String(reflecting: result).contains("synthetic-metadata-must-not-propagate"))
    }

    func testV2NotHydratedAndEnvironmentOnlyDoNotBecomeCandidates() {
        let store = V2ProviderStore()
        store.integrations = [OpenCodeV2Integration(
            id: "openai",
            name: "OpenAI",
            methods: [.env(names: ["OPENAI_API_KEY"])],
            connections: [.env(name: "OPENAI_API_KEY")],
            metadata: nil
        )]

        XCTAssertEqual(ProviderUsageDiscovery.v2State(from: store).readiness, .notHydrated)
        store.isReady = true
        let result = discover(.v2, v2: ProviderUsageDiscovery.v2State(from: store))
        XCTAssertEqual(result.readiness, .ready)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testCandidateIdentityIsDeterministicAndConnectionLifetimeIsSeparate() throws {
        let firstContext = context(profile: .legacy, lifetime: uuid("11111111-1111-1111-1111-111111111111"))
        let reconnectedContext = context(profile: .legacy, lifetime: uuid("22222222-2222-2222-2222-222222222222"))
        let state = ProviderUsageLegacyProviderState(
            readiness: .ready,
            connectedProviders: [.init(id: "openai", label: "OpenAI", source: .api)]
        )

        let first = try XCTUnwrap(ProviderUsageDiscovery.discover(
            context: firstContext,
            legacy: state,
            v2: emptyV2
        ).candidates.first)
        let recomposed = try XCTUnwrap(ProviderUsageDiscovery.discover(
            context: firstContext,
            legacy: state,
            v2: emptyV2
        ).candidates.first)
        let reconnected = try XCTUnwrap(ProviderUsageDiscovery.discover(
            context: reconnectedContext,
            legacy: state,
            v2: emptyV2
        ).candidates.first)

        XCTAssertEqual(first.id, recomposed.id)
        XCTAssertEqual(first.id, reconnected.id)
        XCTAssertEqual(first.context.backend, reconnected.context.backend)
        XCTAssertNotEqual(first.context.connectionLifetimeID, reconnected.context.connectionLifetimeID)
    }

    func testIdentityDistinguishesScopeProfileAndStableBackend() throws {
        let state = ProviderUsageLegacyProviderState(
            readiness: .ready,
            connectedProviders: [.init(id: "openrouter", label: "OpenRouter", source: .api)]
        )
        let base = context(profile: .legacy)
        let otherScope = context(profile: .legacy, scope: .init(projectID: "project-two", directory: "/workspace/two", workspaceID: "workspace-two"))
        let otherBackend = context(profile: .legacy, backendID: "backend-two")
        let first = try XCTUnwrap(ProviderUsageDiscovery.discover(context: base, legacy: state, v2: emptyV2).candidates.first)
        let scoped = try XCTUnwrap(ProviderUsageDiscovery.discover(context: otherScope, legacy: state, v2: emptyV2).candidates.first)
        let backend = try XCTUnwrap(ProviderUsageDiscovery.discover(context: otherBackend, legacy: state, v2: emptyV2).candidates.first)
        let v2 = ProviderUsageDiscovery.discover(
            context: context(profile: .v2),
            legacy: state,
            v2: .init(readiness: .ready, integrations: [
                .init(id: "openrouter", label: "OpenRouter", credentialConnections: [.init(id: "credential", label: "Credential")]),
            ])
        ).candidates.first

        XCTAssertNotEqual(first.id, scoped.id)
        XCTAssertNotEqual(first.id, backend.id)
        XCTAssertNotEqual(first.id.apiProfile, v2?.id.apiProfile)
    }

    func testStoreRejectsUnverifiedAndStaleCandidates() {
        let current = context(profile: .legacy, lifetime: uuid("11111111-1111-1111-1111-111111111111"))
        let stale = context(profile: .legacy, lifetime: uuid("22222222-2222-2222-2222-222222222222"))
        let source = ProviderUsageCandidateSourceIdentity.legacyProvider(providerID: "openrouter")
        let identity = ProviderUsageCandidateIdentity(
            backendDescriptorID: current.backend.id,
            apiProfile: current.apiProfile,
            scope: current.scope,
            source: source
        )
        let available = ProviderUsageDiscoveryCandidate(
            id: identity,
            provider: .openRouter,
            expectedCredentialKind: .apiKey,
            context: current,
            sourceLabel: "OpenRouter",
            availability: .available(sourceKind: .openCodeAuth, credentialKind: .apiKey)
        )
        let unverified = ProviderUsageDiscoveryCandidate(
            id: identity,
            provider: .openRouter,
            expectedCredentialKind: .apiKey,
            context: current,
            sourceLabel: "OpenRouter",
            availability: .unavailable(.sourceExtractionUnverified)
        )
        let store = ProviderUsageStore()

        store.replaceCandidates(with: .init(readiness: .ready, context: current, candidates: [unverified]))
        XCTAssertNil(store.setupCandidate(from: unverified, in: current))

        store.replaceCandidates(with: .init(readiness: .ready, context: current, candidates: [available]))
        let setup = store.setupCandidate(from: available, in: current)
        XCTAssertEqual(setup?.discoveryContext, current)
        XCTAssertEqual(setup?.sourceIdentity, source)
        XCTAssertEqual(setup?.sourceConnectionID, current.backend.id)
        XCTAssertNil(store.setupCandidate(from: available, in: stale))
    }

    func testDiscoveryIsAClosedPureProjectionWithNoSideEffectDependency() {
        let result = ProviderUsageDiscovery.discover(
            context: context(profile: .legacy),
            legacy: .init(
                readiness: .ready,
                connectedProviders: [.init(id: "openai", label: "OpenAI", source: .api)]
            ),
            v2: emptyV2
        )

        XCTAssertEqual(result.candidates.count, 1)
        // The discovery API accepts only value snapshots and has no client, repository, or importer dependency.
    }

    private var emptyLegacy: ProviderUsageLegacyProviderState {
        .init(readiness: .ready, connectedProviders: [])
    }

    private var emptyV2: ProviderUsageV2ProviderState {
        .init(readiness: .ready, integrations: [])
    }

    private func discover(
        _ profile: ProviderUsageAPIProfile,
        legacy: ProviderUsageLegacyProviderState? = nil,
        v2: ProviderUsageV2ProviderState? = nil
    ) -> ProviderUsageDiscoveryResult {
        ProviderUsageDiscovery.discover(
            context: context(profile: profile),
            legacy: legacy ?? emptyLegacy,
            v2: v2 ?? emptyV2
        )
    }

    private func context(
        profile: ProviderUsageAPIProfile,
        lifetime: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        backendID: String = "backend-one",
        scope: BackendScope = .init(projectID: "project-one", directory: "/workspace/one", workspaceID: "workspace-one")
    ) -> ProviderUsageDiscoveryContext {
        .init(
            backend: .init(id: backendID, name: "Synthetic Backend", version: "1"),
            connectionLifetimeID: lifetime,
            apiProfile: profile,
            scope: scope
        )
    }

    private func provider(id: String, name: String, source: String?, key: String) -> OpenCodeProvider {
        .init(
            id: id,
            name: name,
            models: [:],
            source: source,
            env: ["SYNTHETIC_ENV"],
            key: key,
            options: ["synthetic-option": .string(key)]
        )
    }

    private func uuid(_ value: String) -> UUID { UUID(uuidString: value)! }
}
