import Foundation

struct OpenRouterUsageAdapter: Sendable {
    private static let origin = URL(string: "https://openrouter.ai")!
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/key")!
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

    func fetch(apiKey: String) async throws -> ProviderUsageSnapshot {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderUsageError.invalidCredential
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenClient", forHTTPHeaderField: "User-Agent")

        let response = try await transport.send(
            request,
            allowedOrigin: Self.origin,
            maximumResponseBytes: Self.maximumResponseBytes
        )
        switch response.statusCode {
        case 200:
            return try decode(response.body)
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

    private func decode(_ data: Data) throws -> ProviderUsageSnapshot {
        let payload: OpenRouterKeyResponse
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            payload = try decoder.decode(OpenRouterKeyResponse.self, from: data)
        } catch {
            throw ProviderUsageError.malformedResponse
        }

        let key = payload.data
        var metrics = [
            spendMetric(id: "openrouter.spend.lifetime", amount: key.usage, period: .lifetime),
            spendMetric(id: "openrouter.spend.day", amount: key.usageDaily, period: .day),
            spendMetric(id: "openrouter.spend.week", amount: key.usageWeekly, period: .week),
            spendMetric(id: "openrouter.spend.month", amount: key.usageMonthly, period: .month),
        ]
        metrics.append(contentsOf: [
            ("openrouter.byok-spend.lifetime", key.byokUsage, ProviderUsagePeriod.lifetime),
            ("openrouter.byok-spend.day", key.byokUsageDaily, ProviderUsagePeriod.day),
            ("openrouter.byok-spend.week", key.byokUsageWeekly, ProviderUsagePeriod.week),
            ("openrouter.byok-spend.month", key.byokUsageMonthly, ProviderUsagePeriod.month),
        ].compactMap { id, amount, period in
            amount.map { spendMetric(id: id, amount: $0, period: period, kind: .externalSpend) }
        })
        if let limit = key.limit {
            metrics.append(limitMetric(key: key, limit: limit))
        }

        return ProviderUsageSnapshot(
            provider: .openRouter,
            accountLabel: key.label,
            fetchedAt: now(),
            credentialExpiresAt: key.expiresAt.flatMap(Self.parseISO8601),
            metrics: metrics
        )
    }

    private func spendMetric(
        id: String,
        amount: Decimal,
        period: ProviderUsagePeriod,
        kind: ProviderUsageMetricKind = .spend
    ) -> ProviderUsageMetric {
        ProviderUsageMetric(
            id: id,
            kind: kind,
            period: period,
            used: amount,
            remaining: nil,
            limit: nil,
            percentUsed: nil,
            unit: .currency("USD"),
            resetAt: nil
        )
    }

    private func limitMetric(key: OpenRouterKeyData, limit: Decimal) -> ProviderUsageMetric {
        let period = Self.period(from: key.limitReset)
        let derivedUsage = Self.usage(for: period, key: key).flatMap { usage -> Decimal? in
            guard key.includeByokInLimit else { return usage }
            return Self.byokUsage(for: period, key: key).map { usage + $0 }
        }
        let remaining = key.limitRemaining ?? derivedUsage.map { limit - $0 }
        let used = remaining.map { limit - $0 }
        let percentUsed = used.flatMap { used in
            limit > 0 ? NSDecimalNumber(decimal: used / limit * 100).doubleValue : nil
        }
        return ProviderUsageMetric(
            id: "openrouter.spending-limit",
            kind: .spendingLimit,
            period: period,
            used: used,
            remaining: remaining,
            limit: limit,
            percentUsed: percentUsed,
            unit: .currency("USD"),
            resetAt: nil
        )
    }

    private static func period(from value: String?) -> ProviderUsagePeriod? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "daily": return .day
        case "weekly": return .week
        case "monthly": return .month
        default: return .other(value)
        }
    }

    private static func usage(for period: ProviderUsagePeriod?, key: OpenRouterKeyData) -> Decimal? {
        switch period {
        case .day: key.usageDaily
        case .week: key.usageWeekly
        case .month: key.usageMonthly
        case .lifetime, nil: key.usage
        case .rolling, .other: nil
        }
    }

    private static func byokUsage(for period: ProviderUsagePeriod?, key: OpenRouterKeyData) -> Decimal? {
        switch period {
        case .day: key.byokUsageDaily
        case .week: key.byokUsageWeekly
        case .month: key.byokUsageMonthly
        case .lifetime, nil: key.byokUsage
        case .rolling, .other: nil
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

}

private struct OpenRouterKeyResponse: Decodable {
    let data: OpenRouterKeyData
}

private struct OpenRouterKeyData: Decodable {
    let label: String
    let limit: Decimal?
    let limitRemaining: Decimal?
    let limitReset: String?
    let usage: Decimal
    let usageDaily: Decimal
    let usageWeekly: Decimal
    let usageMonthly: Decimal
    let byokUsage: Decimal?
    let byokUsageDaily: Decimal?
    let byokUsageWeekly: Decimal?
    let byokUsageMonthly: Decimal?
    let includeByokInLimit: Bool
    let expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case label
        case limit
        case limitRemaining
        case limitReset
        case usage
        case usageDaily
        case usageWeekly
        case usageMonthly
        case byokUsage
        case byokUsageDaily
        case byokUsageWeekly
        case byokUsageMonthly
        case includeByokInLimit
        case expiresAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        limit = try container.decodeIfPresent(Decimal.self, forKey: .limit)
        limitRemaining = try container.decodeIfPresent(Decimal.self, forKey: .limitRemaining)
        limitReset = try container.decodeIfPresent(String.self, forKey: .limitReset)
        usage = try container.decode(Decimal.self, forKey: .usage)
        usageDaily = try container.decode(Decimal.self, forKey: .usageDaily)
        usageWeekly = try container.decode(Decimal.self, forKey: .usageWeekly)
        usageMonthly = try container.decode(Decimal.self, forKey: .usageMonthly)
        byokUsage = try container.decodeIfPresent(Decimal.self, forKey: .byokUsage)
        byokUsageDaily = try container.decodeIfPresent(Decimal.self, forKey: .byokUsageDaily)
        byokUsageWeekly = try container.decodeIfPresent(Decimal.self, forKey: .byokUsageWeekly)
        byokUsageMonthly = try container.decodeIfPresent(Decimal.self, forKey: .byokUsageMonthly)
        includeByokInLimit = try container.decode(Bool.self, forKey: .includeByokInLimit)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}
