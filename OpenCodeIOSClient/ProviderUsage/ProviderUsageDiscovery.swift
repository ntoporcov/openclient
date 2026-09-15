import Foundation

enum ProviderUsageDiscovery {
    static func discover(
        context: ProviderUsageDiscoveryContext,
        legacy: ProviderUsageLegacyProviderState,
        v2: ProviderUsageV2ProviderState
    ) -> ProviderUsageDiscoveryResult {
        switch context.apiProfile {
        case .legacy:
            guard legacy.readiness == .ready else {
                return .init(readiness: .notHydrated, context: context, candidates: [])
            }
            return .init(
                readiness: .ready,
                context: context,
                candidates: legacy.connectedProviders.compactMap { provider in
                    guard let usageProvider = ProviderUsageProvider(openCodeProviderID: provider.id) else { return nil }
                    let source = ProviderUsageCandidateSourceIdentity.legacyProvider(providerID: provider.id)
                    return ProviderUsageDiscoveryCandidate(
                        id: identity(context: context, source: source),
                        provider: usageProvider,
                        expectedCredentialKind: usageProvider.legacyCredentialKind,
                        context: context,
                        sourceLabel: provider.label,
                        availability: .available(
                            sourceKind: .openCodeAuth,
                            credentialKind: usageProvider.legacyCredentialKind
                        )
                    )
                }
            )
        case .v2:
            guard v2.readiness == .ready else {
                return .init(readiness: .notHydrated, context: context, candidates: [])
            }
            let candidates = v2.integrations.flatMap { integration -> [ProviderUsageDiscoveryCandidate] in
                guard let usageProvider = ProviderUsageProvider(openCodeProviderID: integration.id) else { return [] }
                return integration.credentialConnections.map { credential in
                    let source = ProviderUsageCandidateSourceIdentity.v2Credential(
                        integrationID: integration.id,
                        credentialID: credential.id
                    )
                    return ProviderUsageDiscoveryCandidate(
                        id: identity(context: context, source: source),
                        provider: usageProvider,
                        expectedCredentialKind: nil,
                        context: context,
                        sourceLabel: credential.label,
                        availability: .unavailable(.v2CredentialKindUnknown)
                    )
                }
            }
            return .init(readiness: .ready, context: context, candidates: candidates)
        }
    }

    @MainActor
    static func legacyState(from store: ModelConfigurationStore) -> ProviderUsageLegacyProviderState {
        guard store.isProviderStateReady else {
            return .init(readiness: .notHydrated, connectedProviders: [])
        }
        let providers = store.connectedProviderIDs.sorted().map { id in
            let provider = store.allProviders.first { $0.id == id }
            return ProviderUsageLegacyProviderDescriptor(
                id: id,
                label: provider?.name ?? id,
                source: legacySource(provider?.source)
            )
        }
        return .init(readiness: .ready, connectedProviders: providers)
    }

    @MainActor
    static func v2State(from store: V2ProviderStore) -> ProviderUsageV2ProviderState {
        guard store.isReady else { return .init(readiness: .notHydrated, integrations: []) }
        return .init(
            readiness: .ready,
            integrations: store.integrations.map { integration in
                ProviderUsageV2IntegrationDescriptor(
                    id: integration.id,
                    label: integration.name,
                    credentialConnections: integration.connections.compactMap { connection in
                        guard case .credential(let id, let label) = connection else { return nil }
                        return .init(id: id, label: label)
                    }
                )
            }
        )
    }

    private static func legacySource(_ source: String?) -> ProviderUsageLegacySource {
        switch source {
        case "api": return .api
        case "env": return .environment
        case "config": return .config
        case "custom": return .custom
        case nil: return .unspecified
        default: return .unsupported
        }
    }

    private static func identity(
        context: ProviderUsageDiscoveryContext,
        source: ProviderUsageCandidateSourceIdentity
    ) -> ProviderUsageCandidateIdentity {
        .init(
            backendDescriptorID: context.backend.id,
            apiProfile: context.apiProfile,
            scope: context.scope,
            source: source
        )
    }
}
