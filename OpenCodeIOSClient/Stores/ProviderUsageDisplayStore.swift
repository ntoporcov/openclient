import Foundation
import Observation

@MainActor
@Observable
final class ProviderUsageDisplayStore {
    private(set) var selections: [OpenCodeProviderUsageMetricSelection]
    private(set) var availableMetrics: [OpenCodeProviderUsageDisplayMetric] = []
    private(set) var widgetPayload: OpenCodeProviderUsageWidgetPayload
    private(set) var displayMode: OpenCodeProviderUsageDisplayMode

    private let persistence: OpenCodeProviderUsageDisplayPersistence
    private let widgetTimelineReloader: ProviderUsageWidgetTimelineReloading

    var orderedAvailableMetrics: [OpenCodeProviderUsageDisplayMetric] {
        let metricsByID = Dictionary(uniqueKeysWithValues: availableMetrics.map { ($0.identity, $0) })
        return selections.compactMap { metricsByID[$0.identity] }
    }

    init(
        persistence: OpenCodeProviderUsageDisplayPersistence = .init(),
        widgetTimelineReloader: ProviderUsageWidgetTimelineReloading = SystemWidgetTimelineReloader()
    ) {
        self.persistence = persistence
        self.widgetTimelineReloader = widgetTimelineReloader
        selections = persistence.loadSelections().selections
        widgetPayload = persistence.loadWidgetPayload()
        displayMode = persistence.loadDisplayMode()
    }

    func reconcile(accounts: [ProviderUsageAccount], snapshots: [UUID: ProviderUsageSnapshot], now: Date = Date()) {
        let accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var metrics: [OpenCodeProviderUsageDisplayMetric] = []
        var seen: Set<OpenCodeProviderUsageMetricIdentity> = []

        for account in accounts {
            guard let snapshot = snapshots[account.id] else { continue }
            for metric in snapshot.metrics {
                let identity = OpenCodeProviderUsageMetricIdentity(accountID: account.id, metricID: metric.id)
                guard !metric.id.isEmpty, metric.id.count <= 256,
                      !metric.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      seen.insert(identity).inserted else { continue }
                metrics.append(Self.displayMetric(account: accountsByID[account.id] ?? account, snapshot: snapshot, metric: metric))
            }
        }
        availableMetrics = metrics

        let known = Set(selections.map(\.identity))
        let additions = metrics.compactMap { metric -> OpenCodeProviderUsageMetricSelection? in
            guard !known.contains(metric.identity) else { return nil }
            return .init(identity: metric.identity, showsOnHome: false, showsInActivity: false)
        }
        if !additions.isEmpty {
            selections.append(contentsOf: additions)
            persistSelections()
        }
        publishWidgetPayload(now: now)
    }

    func metrics(for destination: OpenCodeProviderUsageDestination) -> [OpenCodeProviderUsageDisplayMetric] {
        let availableByID = Dictionary(uniqueKeysWithValues: availableMetrics.map { ($0.identity, $0) })
        return selections.compactMap { selection in
            guard selection.isVisible(in: destination) else { return nil }
            return availableByID[selection.identity]
        }
    }

    var previewMetrics: [OpenCodeProviderUsageDisplayMetric] {
        let selected = orderedAvailableMetrics.filter { metric in
            selections.first(where: { $0.identity == metric.identity }).map {
                $0.showsOnHome || $0.showsInActivity
            } ?? false
        }
        return Array((selected.isEmpty ? orderedAvailableMetrics : selected).prefix(8))
    }

    func setDisplayMode(_ mode: OpenCodeProviderUsageDisplayMode) {
        guard displayMode != mode else { return }
        displayMode = mode
        persistence.saveDisplayMode(mode)
    }

    func selectedAccountIDs(for destination: OpenCodeProviderUsageDestination) -> [UUID] {
        var seen: Set<UUID> = []
        return selections.compactMap {
            $0.isVisible(in: destination) && seen.insert($0.identity.accountID).inserted ? $0.identity.accountID : nil
        }
    }

    func isVisible(_ identity: OpenCodeProviderUsageMetricIdentity, in destination: OpenCodeProviderUsageDestination) -> Bool {
        selections.first(where: { $0.identity == identity })?.isVisible(in: destination) ?? false
    }

    func setVisible(
        _ isVisible: Bool,
        identity: OpenCodeProviderUsageMetricIdentity,
        destination: OpenCodeProviderUsageDestination
    ) {
        guard let index = selections.firstIndex(where: { $0.identity == identity }) else { return }
        switch destination {
        case .home: selections[index].showsOnHome = isVisible
        case .activity: selections[index].showsInActivity = isVisible
        }
        persistSelections()
        publishWidgetPayload()
    }

    func removeSelections(accountID: UUID) {
        selections.removeAll { $0.identity.accountID == accountID }
        availableMetrics.removeAll { $0.identity.accountID == accountID }
        persistSelections()
        publishWidgetPayload()
    }

    func moveAvailableMetrics(fromOffsets: IndexSet, toOffset: Int) {
        let availableIDs = orderedAvailableMetrics.map(\.identity)
        var orderedAvailable = selections.map(\.identity).filter(Set(availableIDs).contains)
        let moving = fromOffsets.sorted().map { orderedAvailable[$0] }
        for index in fromOffsets.sorted(by: >) { orderedAvailable.remove(at: index) }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        orderedAvailable.insert(
            contentsOf: moving,
            at: min(max(toOffset - removedBeforeDestination, 0), orderedAvailable.count)
        )
        var iterator = orderedAvailable.makeIterator()
        let availableSet = Set(availableIDs)
        let selectionsByID = Dictionary(uniqueKeysWithValues: selections.map { ($0.identity, $0) })
        selections = selections.map { selection in
            guard availableSet.contains(selection.identity), let identity = iterator.next() else { return selection }
            return selectionsByID[identity] ?? selection
        }
        persistSelections()
        publishWidgetPayload()
    }

    private func persistSelections() {
        persistence.saveSelections(selections)
    }

    private func publishWidgetPayload(now: Date = Date()) {
        let orderedByID = Dictionary(uniqueKeysWithValues: availableMetrics.map { ($0.identity, $0) })
        let metrics = selections.compactMap { orderedByID[$0.identity] }
        guard widgetPayload.metrics != metrics else { return }
        widgetPayload = .init(
            version: OpenCodeProviderUsageWidgetPayload.currentVersion,
            metrics: metrics,
            generatedAt: now
        )
        persistence.saveWidgetPayload(widgetPayload)
        widgetTimelineReloader.reloadProviderUsageTimelines()
    }

    private static func displayMetric(
        account: ProviderUsageAccount,
        snapshot: ProviderUsageSnapshot,
        metric: ProviderUsageMetric
    ) -> OpenCodeProviderUsageDisplayMetric {
        let percent = metric.percentUsed.flatMap { $0.isFinite ? min(max($0, 0), 10_000) : nil }
        let candidateValue = metric.remaining ?? metric.used ?? metric.limit
        let value = candidateValue?.isNaN == true ? nil : candidateValue
        return .init(
            identity: .init(accountID: account.id, metricID: metric.id),
            providerID: account.provider.openCodeProviderID,
            providerName: String(localized: account.provider.displayTitle),
            accountLabel: sanitized(snapshot.accountLabel)
                ?? String(localized: "Account \(account.id.uuidString.prefix(4))"),
            metricLabel: sanitized(metric.sourceLabel) ?? String(localized: metric.kind.displayTitle),
            value: value,
            percentUsed: percent,
            unit: metric.unit.displayUnit,
            period: metric.period?.displayPeriod,
            resetAt: metric.resetAt,
            isUnlimited: metric.isUnlimited,
            fetchedAt: snapshot.fetchedAt
        )
    }

    private static func sanitized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
    }
}

extension ProviderUsageProvider {
    var displayTitle: LocalizedStringResource {
        switch self {
        case .codex: "OpenAI"
        case .openRouter: "OpenRouter"
        }
    }
}

extension ProviderUsageMetricKind {
    var displayTitle: LocalizedStringResource {
        switch self {
        case .spend: "Spend"
        case .externalSpend: "External spend"
        case .spendingLimit: "Spending limit"
        case .quota: "Usage limit"
        case .balance: "Balance"
        }
    }
}

private extension ProviderUsageUnit {
    var displayUnit: OpenCodeProviderUsageValueUnit {
        switch self {
        case .currency(let code): .currency(code)
        case .count: .count
        case .credits: .credits
        case .percentage: .percentage
        }
    }
}

private extension ProviderUsagePeriod {
    var displayPeriod: OpenCodeProviderUsageDisplayPeriod {
        switch self {
        case .lifetime: .lifetime
        case .day: .day
        case .week: .week
        case .month: .month
        case .rolling(let seconds): .rolling(seconds: seconds)
        case .other(let value): .other(value)
        }
    }
}
