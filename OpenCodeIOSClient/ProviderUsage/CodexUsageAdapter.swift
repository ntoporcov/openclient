import Foundation

struct CodexUsageAdapter: Sendable {
    private static let origin = URL(string: "https://chatgpt.com")!
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let maximumResponseBytes = 1_048_576

    private let transport: any ProviderUsageHTTPTransport
    private let now: @Sendable () -> Date

    init(
        transport: any ProviderUsageHTTPTransport = ProviderUsageHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(
        accessToken: String,
        accountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        let accessToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              !Self.containsControlCharacters(accessToken) else {
            throw ProviderUsageError.invalidCredential
        }
        if let credentialExpiresAt, credentialExpiresAt <= now() {
            throw ProviderUsageError.credentialExpired
        }

        let accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accountID.map(Self.containsControlCharacters) != true else {
            throw ProviderUsageError.invalidCredential
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenClient", forHTTPHeaderField: "User-Agent")
        if let accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let response = try await transport.send(
            request,
            allowedOrigin: Self.origin,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        switch response.statusCode {
        case 200:
            return try decode(
                response.body,
                requestedAccountID: accountID,
                credentialExpiresAt: credentialExpiresAt
            )
        case 300..<400:
            throw ProviderUsageError.redirectRejected
        case 401:
            throw ProviderUsageError.unauthorized
        case 403:
            throw ProviderUsageError.forbidden
        case 429:
            throw ProviderUsageError.rateLimited(retryAfter: response.retryDate(relativeTo: now()))
        default:
            throw ProviderUsageError.httpStatus(response.statusCode)
        }
    }

    private func decode(
        _ data: Data,
        requestedAccountID: String?,
        credentialExpiresAt: Date?
    ) throws -> ProviderUsageSnapshot {
        let payload: CodexUsageResponse
        do {
            payload = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        } catch {
            throw ProviderUsageError.malformedResponse
        }

        let responseAccountID = Self.nonEmpty(payload.accountID)
        let requestedAccountID = Self.nonEmpty(requestedAccountID)
        if let responseAccountID, let requestedAccountID,
           responseAccountID != requestedAccountID {
            throw ProviderUsageError.accountMismatch
        }

        var metrics: [ProviderUsageMetric] = []
        if let primary = payload.rateLimit?.primaryWindow {
            metrics.append(Self.quotaMetric(
                id: "codex.rate-limit.primary",
                window: primary
            ))
        }
        if let secondary = payload.rateLimit?.secondaryWindow {
            metrics.append(Self.quotaMetric(
                id: "codex.rate-limit.secondary",
                window: secondary
            ))
        }
        var additionalIdentityCounts: [String: Int] = [:]
        for (index, limit) in payload.additionalRateLimits.enumerated() {
            let identityBase = Self.additionalLimitIdentity(limit, fallbackIndex: index)
            let occurrence = additionalIdentityCounts[identityBase, default: 0]
            additionalIdentityCounts[identityBase] = occurrence + 1
            let identity = occurrence == 0 ? identityBase : "\(identityBase).\(occurrence)"
            if let primary = limit.rateLimit?.primaryWindow {
                metrics.append(Self.quotaMetric(
                    id: "codex.additional.\(identity).primary",
                    window: primary,
                    sourceLabel: limit.limitName ?? limit.meteredFeature
                ))
            }
            if let secondary = limit.rateLimit?.secondaryWindow {
                metrics.append(Self.quotaMetric(
                    id: "codex.additional.\(identity).secondary",
                    window: secondary,
                    sourceLabel: limit.limitName ?? limit.meteredFeature
                ))
            }
        }
        if let credits = payload.credits, credits.hasCredits || credits.unlimited {
            metrics.append(ProviderUsageMetric(
                id: "codex.credits.balance",
                kind: .balance,
                period: nil,
                used: nil,
                remaining: credits.balance,
                limit: nil,
                percentUsed: nil,
                unit: .credits,
                resetAt: nil,
                isUnlimited: credits.unlimited
            ))
        }

        return ProviderUsageSnapshot(
            provider: .codex,
            accountLabel: nil,
            accountID: responseAccountID ?? requestedAccountID,
            plan: payload.planType,
            fetchedAt: now(),
            credentialExpiresAt: credentialExpiresAt,
            metrics: metrics
        )
    }

    private static func quotaMetric(
        id: String,
        window: CodexUsageWindow,
        sourceLabel: String? = nil
    ) -> ProviderUsageMetric {
        ProviderUsageMetric(
            id: id,
            kind: .quota,
            period: .rolling(seconds: window.limitWindowSeconds),
            used: nil,
            remaining: nil,
            limit: nil,
            percentUsed: NSDecimalNumber(decimal: window.usedPercent).doubleValue,
            unit: .percentage,
            resetAt: Date(timeIntervalSince1970: TimeInterval(window.resetAt)),
            sourceLabel: sourceLabel
        )
    }

    private static func additionalLimitIdentity(_ limit: CodexAdditionalRateLimit, fallbackIndex: Int) -> String {
        let name = nonEmpty(limit.limitName) ?? ""
        let feature = nonEmpty(limit.meteredFeature) ?? ""
        guard !name.isEmpty || !feature.isEmpty else { return "index-\(fallbackIndex)" }
        return String(opencodeStableHash("name:\(name)\u{1F}feature:\(feature)"), radix: 16)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

private struct CodexUsageResponse: Decodable {
    let accountID: String?
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
    let credits: CodexUsageCredits?
    let additionalRateLimits: [CodexAdditionalRateLimit]

    private enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accountIDCamel = "accountId"
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
        case additionalRateLimits = "additional_rate_limits"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = (try? container.decodeIfPresent(String.self, forKey: .accountID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .accountIDCamel))
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(CodexUsageRateLimit.self, forKey: .rateLimit)
        credits = try? container.decodeIfPresent(CodexUsageCredits.self, forKey: .credits)
        additionalRateLimits = (try? container.decodeIfPresent(
            [LossyCodexAdditionalRateLimit].self,
            forKey: .additionalRateLimits
        ))?.compactMap(\.value) ?? []
    }
}

private struct CodexUsageRateLimit: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryWindow = try? container.decodeIfPresent(CodexUsageWindow.self, forKey: .primaryWindow)
        secondaryWindow = try? container.decodeIfPresent(CodexUsageWindow.self, forKey: .secondaryWindow)
    }
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Decimal
    let resetAt: Int64
    let limitWindowSeconds: Int

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Decimal.self, forKey: .usedPercent)
        resetAt = try container.decode(Int64.self, forKey: .resetAt)
        limitWindowSeconds = try container.decode(Int.self, forKey: .limitWindowSeconds)
        guard usedPercent >= 0, resetAt >= 0, limitWindowSeconds > 0 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid Codex usage window"
            ))
        }
    }
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexUsageRateLimit?

    private enum CodingKeys: String, CodingKey {
        case limitName = "limit_name"
        case meteredFeature = "metered_feature"
        case rateLimit = "rate_limit"
    }
}

private struct LossyCodexAdditionalRateLimit: Decodable {
    let value: CodexAdditionalRateLimit?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(CodexAdditionalRateLimit.self)
    }
}

private struct CodexUsageCredits: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Decimal?

    private enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
        unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
        if let decimal = try? container.decode(Decimal.self, forKey: .balance) {
            balance = decimal
        } else if let string = try? container.decode(String.self, forKey: .balance) {
            balance = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
        } else {
            balance = nil
        }
    }
}
