import AppIntents
import SwiftUI
import WidgetKit

struct OpenCodeProviderUsageBarsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: OpenCodeWidgetKind.providerUsageBars,
            intent: OpenCodeProviderUsageWidgetConfiguration.self,
            provider: OpenCodeProviderUsageTimelineProvider(style: .bars)
        ) { entry in
            OpenCodeProviderUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Provider Usage Bars")
        .description("Track provider usage with compact progress bars.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OpenCodeProviderUsageRingsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: OpenCodeWidgetKind.providerUsageRings,
            intent: OpenCodeProviderUsageWidgetConfiguration.self,
            provider: OpenCodeProviderUsageTimelineProvider(style: .rings)
        ) { entry in
            OpenCodeProviderUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Provider Usage Rings")
        .description("Track provider usage with compact progress rings.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OpenCodeProviderUsageEntry: TimelineEntry {
    let date: Date
    let style: OpenCodeProviderUsageWidgetStyle
    let payload: OpenCodeProviderUsageWidgetPayload
    let configuredIDs: [String]
}

struct OpenCodeProviderUsageTimelineProvider: AppIntentTimelineProvider {
    let style: OpenCodeProviderUsageWidgetStyle

    func placeholder(in context: Context) -> OpenCodeProviderUsageEntry {
        .preview(style: style)
    }

    func snapshot(for configuration: OpenCodeProviderUsageWidgetConfiguration, in context: Context) async -> OpenCodeProviderUsageEntry {
        context.isPreview ? .preview(style: style) : entry(for: configuration)
    }

    func timeline(for configuration: OpenCodeProviderUsageWidgetConfiguration, in context: Context) async -> Timeline<OpenCodeProviderUsageEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: OpenCodeProviderUsageWidgetConfiguration) -> OpenCodeProviderUsageEntry {
        OpenCodeProviderUsageEntry(
            date: Date(),
            style: style,
            payload: OpenCodeProviderUsageDisplayPersistence().loadWidgetPayload(),
            configuredIDs: configuration.metrics?.map(\.id) ?? []
        )
    }
}

private struct OpenCodeProviderUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OpenCodeProviderUsageEntry

    var body: some View {
        Group {
            if metrics.isEmpty {
                emptyState
            } else {
                OpenCodeProviderUsageWidgetContent(
                    metrics: metrics,
                    style: entry.style,
                    size: widgetSize,
                    referenceDate: entry.date
                )
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var metrics: [OpenCodeProviderUsageDisplayMetric] {
        OpenCodeProviderUsageWidgetMetrics.resolve(
            metrics: entry.payload.metrics,
            configuredIDs: entry.configuredIDs,
            limit: OpenCodeProviderUsageWidgetMetrics.limit(for: entry.style, size: widgetSize)
        )
    }

    private var widgetSize: OpenCodeProviderUsageWidgetSize {
        switch family {
        case .systemSmall: .small
        case .systemMedium: .medium
        default: .large
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No Usage Data")
                .font(.headline)
            Text("Open OpenClient to sync usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension OpenCodeProviderUsageEntry {
    static func preview(style: OpenCodeProviderUsageWidgetStyle) -> Self {
        let accountID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metrics = [
            OpenCodeProviderUsageDisplayMetric(
                identity: .init(accountID: accountID, metricID: "weekly"), providerID: "openai", providerName: "OpenAI",
                accountLabel: "Plus", metricLabel: "Weekly", value: nil, percentUsed: 42, unit: .percentage,
                period: .week, resetAt: now.addingTimeInterval(6 * 86_400), isUnlimited: false, fetchedAt: now
            ),
            OpenCodeProviderUsageDisplayMetric(
                identity: .init(accountID: accountID, metricID: "spend"), providerID: "openrouter", providerName: "OpenRouter",
                accountLabel: "Personal", metricLabel: "Spend", value: 12.45, percentUsed: 62, unit: .currency("USD"),
                period: .month, resetAt: now.addingTimeInterval(12 * 86_400), isUnlimited: false, fetchedAt: now
            ),
        ]
        return Self(
            date: now,
            style: style,
            payload: .init(version: OpenCodeProviderUsageWidgetPayload.currentVersion, metrics: metrics, generatedAt: now),
            configuredIDs: []
        )
    }
}
