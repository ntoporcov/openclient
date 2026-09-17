import Foundation

enum ProviderUsageProvider: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case codex
    case openRouter = "openrouter"

    static let allCases: [Self] = [.codex, .openRouter]

    var id: String { rawValue }

    var openCodeProviderID: String {
        switch self {
        case .codex: "openai"
        case .openRouter: "openrouter"
        }
    }

    var legacyCredentialKind: ProviderUsageCredentialKind {
        switch self {
        case .codex: .oauthAccessToken
        case .openRouter: .apiKey
        }
    }

    init?(openCodeProviderID: String) {
        guard let provider = Self.allCases.first(where: { $0.openCodeProviderID == openCodeProviderID }) else {
            return nil
        }
        self = provider
    }
}

enum ProviderUsageMetricKind: Hashable, Sendable {
    case spend
    case externalSpend
    case spendingLimit
    case quota
    case balance
}

enum ProviderUsagePeriod: Hashable, Sendable {
    case lifetime
    case day
    case week
    case month
    case rolling(seconds: Int)
    case other(String)
}

enum ProviderUsageUnit: Hashable, Sendable {
    case currency(String)
    case count
    case credits
    case percentage
}

struct ProviderUsageMetric: Identifiable, Hashable, Sendable {
    let id: String
    let kind: ProviderUsageMetricKind
    let period: ProviderUsagePeriod?
    let used: Decimal?
    let remaining: Decimal?
    let limit: Decimal?
    let percentUsed: Double?
    let unit: ProviderUsageUnit
    let resetAt: Date?
    let isUnlimited: Bool
    let sourceLabel: String?

    init(
        id: String,
        kind: ProviderUsageMetricKind,
        period: ProviderUsagePeriod?,
        used: Decimal?,
        remaining: Decimal?,
        limit: Decimal?,
        percentUsed: Double?,
        unit: ProviderUsageUnit,
        resetAt: Date?,
        isUnlimited: Bool = false,
        sourceLabel: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.period = period
        self.used = used
        self.remaining = remaining
        self.limit = limit
        self.percentUsed = percentUsed
        self.unit = unit
        self.resetAt = resetAt
        self.isUnlimited = isUnlimited
        self.sourceLabel = sourceLabel
    }
}

struct ProviderUsageSnapshot: Hashable, Sendable {
    let provider: ProviderUsageProvider
    let accountLabel: String?
    let accountID: String?
    let plan: String?
    let fetchedAt: Date
    let credentialExpiresAt: Date?
    let metrics: [ProviderUsageMetric]

    init(
        provider: ProviderUsageProvider,
        accountLabel: String?,
        accountID: String? = nil,
        plan: String? = nil,
        fetchedAt: Date,
        credentialExpiresAt: Date?,
        metrics: [ProviderUsageMetric]
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.accountID = accountID
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.credentialExpiresAt = credentialExpiresAt
        self.metrics = metrics
    }
}

enum ProviderUsageError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidRequest
    case insecureTransport
    case disallowedOrigin
    case invalidResponse
    case redirectRejected
    case credentialExpired
    case accountMismatch
    case unauthorized
    case forbidden
    case rateLimited(retryAfter: Date?)
    case httpStatus(Int)
    case responseTooLarge
    case malformedResponse
    case network
    case credentialUnavailable
}

enum ProviderUsageAPIProfile: String, Codable, Hashable, Sendable {
    case legacy
    case v2
}

enum ProviderUsageCredentialSourceKind: String, Codable, Hashable, Sendable {
    case openCodeAuth
    case codexCLI
}

enum ProviderUsageCredentialKind: String, Codable, Hashable, Sendable {
    case apiKey
    case oauthAccessToken
}

struct ProviderUsageAccount: Codable, Identifiable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let id: UUID
    let provider: ProviderUsageProvider
    let sourceConnectionID: String
    let apiProfile: ProviderUsageAPIProfile
    let sourceKind: ProviderUsageCredentialSourceKind
    let sourceScope: ProviderUsageSourceScope?
    let credentialKind: ProviderUsageCredentialKind
    let providerAccountID: String?
    let credentialReference: UUID
    let credentialRevision: Int
    let credentialExpiresAt: Date?
    let sourceRenewalApprovedAt: Date?
    let createdAt: Date
    let updatedAt: Date

    init(
        version: Int = Self.currentVersion,
        id: UUID,
        provider: ProviderUsageProvider,
        sourceConnectionID: String,
        apiProfile: ProviderUsageAPIProfile,
        sourceKind: ProviderUsageCredentialSourceKind,
        sourceScope: ProviderUsageSourceScope? = nil,
        credentialKind: ProviderUsageCredentialKind,
        providerAccountID: String? = nil,
        credentialReference: UUID,
        credentialRevision: Int,
        credentialExpiresAt: Date? = nil,
        sourceRenewalApprovedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.version = version
        self.id = id
        self.provider = provider
        self.sourceConnectionID = sourceConnectionID
        self.apiProfile = apiProfile
        self.sourceKind = sourceKind
        self.sourceScope = sourceScope
        self.credentialKind = credentialKind
        self.providerAccountID = providerAccountID
        self.credentialReference = credentialReference
        self.credentialRevision = credentialRevision
        self.credentialExpiresAt = credentialExpiresAt
        self.sourceRenewalApprovedAt = sourceRenewalApprovedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct ProviderUsageSourceScope: Codable, Equatable, Hashable, Sendable {
    let projectID: String?
    let directory: String?
    let workspaceID: String?

    init(_ scope: BackendScope) {
        projectID = scope.projectID
        directory = scope.directory
        workspaceID = scope.workspaceID
    }

    func matches(_ scope: BackendScope) -> Bool {
        self == ProviderUsageSourceScope(scope)
    }
}

struct ProviderUsageSetupCandidate: Identifiable, Hashable, Sendable {
    let id: UUID
    let provider: ProviderUsageProvider
    let discoveryContext: ProviderUsageDiscoveryContext
    let sourceIdentity: ProviderUsageCandidateSourceIdentity
    let sourceKind: ProviderUsageCredentialSourceKind
    let credentialKind: ProviderUsageCredentialKind
    let replacingAccountID: UUID?

    var sourceConnectionID: String { discoveryContext.backend.id }
    var apiProfile: ProviderUsageAPIProfile { discoveryContext.apiProfile }
}

enum ProviderUsageDiscoveryReadiness: Hashable, Sendable {
    case notHydrated
    case ready
}

enum ProviderUsageLegacySource: Hashable, Sendable {
    case api
    case environment
    case config
    case custom
    case unspecified
    case unsupported
}

struct ProviderUsageLegacyProviderDescriptor: Hashable, Sendable {
    let id: String
    let label: String
    let source: ProviderUsageLegacySource
}

struct ProviderUsageLegacyProviderState: Hashable, Sendable {
    let readiness: ProviderUsageDiscoveryReadiness
    let connectedProviders: [ProviderUsageLegacyProviderDescriptor]
}

struct ProviderUsageV2CredentialConnection: Hashable, Sendable {
    let id: String
    let label: String
}

struct ProviderUsageV2IntegrationDescriptor: Hashable, Sendable {
    let id: String
    let label: String
    let credentialConnections: [ProviderUsageV2CredentialConnection]
}

struct ProviderUsageV2ProviderState: Hashable, Sendable {
    let readiness: ProviderUsageDiscoveryReadiness
    let integrations: [ProviderUsageV2IntegrationDescriptor]
}

struct ProviderUsageDiscoveryContext: Hashable, Sendable {
    let backend: BackendDescriptor
    let connectionLifetimeID: UUID
    let apiProfile: ProviderUsageAPIProfile
    let scope: BackendScope
}

enum ProviderUsageCandidateSourceIdentity: Hashable, Sendable {
    case legacyProvider(providerID: String)
    case v2Credential(integrationID: String, credentialID: String)
}

struct ProviderUsageCandidateIdentity: Hashable, Sendable {
    let backendDescriptorID: String
    let apiProfile: ProviderUsageAPIProfile
    let scope: BackendScope
    let source: ProviderUsageCandidateSourceIdentity
}

enum ProviderUsageCandidateUnavailableReason: Hashable, Sendable {
    case sourceExtractionUnverified
    case ambiguousLegacySource
    case v2CredentialKindUnknown
}

enum ProviderUsageCandidateAvailability: Hashable, Sendable {
    case available(sourceKind: ProviderUsageCredentialSourceKind, credentialKind: ProviderUsageCredentialKind)
    case unavailable(ProviderUsageCandidateUnavailableReason)

    var isSelectable: Bool {
        if case .available = self { return true }
        return false
    }
}

struct ProviderUsageDiscoveryCandidate: Identifiable, Hashable, Sendable {
    let id: ProviderUsageCandidateIdentity
    let provider: ProviderUsageProvider
    let expectedCredentialKind: ProviderUsageCredentialKind?
    let context: ProviderUsageDiscoveryContext
    let sourceLabel: String
    let availability: ProviderUsageCandidateAvailability
}

struct ProviderUsageDiscoveryResult: Hashable, Sendable {
    let readiness: ProviderUsageDiscoveryReadiness
    let context: ProviderUsageDiscoveryContext
    let candidates: [ProviderUsageDiscoveryCandidate]
}

struct ProviderUsageTransientSecret: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String

    var description: String { "<redacted provider credential>" }
    var debugDescription: String { description }

    var maskedPreview: String {
        let suffix = value.suffix(4)
        return suffix.isEmpty ? "****" : "****\(suffix)"
    }
}

struct ProviderUsageCredentialRenewal: Equatable, Sendable {
    let secret: ProviderUsageTransientSecret
    let expiresAt: Date
    let providerAccountID: String?

    init(secret: ProviderUsageTransientSecret, expiresAt: Date, providerAccountID: String? = nil) {
        self.secret = secret
        self.expiresAt = expiresAt
        self.providerAccountID = providerAccountID
    }
}

struct ProviderUsageCredentialReview: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let candidate: ProviderUsageSetupCandidate
    let secret: ProviderUsageTransientSecret
    let providerAccountID: String?
    let credentialExpiresAt: Date?

    var maskedPreview: String { secret.maskedPreview }
    var description: String { "ProviderUsageCredentialReview(provider: \(candidate.provider.rawValue), credential: <redacted>)" }
    var debugDescription: String { description }
}

enum ProviderUsageStatus: Equatable, Sendable {
    case savedNotChecked
    case refreshing
    case ready
    case importFailed
    case saveFailed
    case usageFailed(ProviderUsageError)
    case removalFailed
}
