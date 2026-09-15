import AppIntents
import Foundation

struct OpenCodeProviderUsageMetricEntity: AppEntity, Identifiable, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage Metric")
    static let defaultQuery = OpenCodeProviderUsageMetricQuery()

    let id: String
    let providerName: String
    let accountLabel: String
    let metricLabel: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(metricLabel)",
            subtitle: "\(providerName) · \(accountLabel)"
        )
    }
}

struct OpenCodeProviderUsageMetricQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeProviderUsageMetricEntity.ID]) async throws -> [OpenCodeProviderUsageMetricEntity] {
        let available = Dictionary(uniqueKeysWithValues: OpenCodeProviderUsageWidgetOptions.metrics().map { ($0.id, $0) })
        return identifiers.compactMap { available[$0] }
    }

    func suggestedEntities() async throws -> [OpenCodeProviderUsageMetricEntity] {
        OpenCodeProviderUsageWidgetOptions.metrics()
    }
}

struct OpenCodeProviderUsageWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider Usage"
    static let description = IntentDescription("Choose and order usage metrics. Leave empty to use the synced order.")

    @Parameter(title: "Usage Metrics") var metrics: [OpenCodeProviderUsageMetricEntity]?

    init() {}
}

enum OpenCodeProviderUsageWidgetOptions {
    static func metrics() -> [OpenCodeProviderUsageMetricEntity] {
        OpenCodeProviderUsageDisplayPersistence().loadWidgetPayload().metrics.map { metric in
            OpenCodeProviderUsageMetricEntity(
                id: OpenCodeProviderUsageWidgetMetrics.stableID(for: metric.identity),
                providerName: metric.providerName,
                accountLabel: metric.accountLabel,
                metricLabel: metric.metricLabel
            )
        }
    }
}
