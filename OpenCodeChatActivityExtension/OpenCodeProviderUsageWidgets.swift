import AppIntents
import SwiftUI
import UIKit
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
                switch entry.style {
                case .bars:
                    bars
                case .rings:
                    rings
                }
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

    private var bars: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 9 : 6) {
            if family == .systemSmall, let metric = metrics.first {
                OpenCodeProviderUsageSingleBar(metric: metric, referenceDate: entry.date)
            } else {
                Text("Usage")
                    .font(.subheadline.weight(.semibold))
                VStack(spacing: family == .systemLarge ? 6 : 4) {
                    ForEach(metrics) { metric in
                        OpenCodeProviderUsageBarRow(
                            metric: metric,
                            showsCaption: family == .systemLarge,
                            referenceDate: entry.date
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rings: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: family == .systemSmall ? 1 : 4),
            spacing: family == .systemLarge ? 16 : 8
        ) {
            ForEach(metrics) { metric in
                OpenCodeProviderUsageRing(metric: metric, family: family, referenceDate: entry.date)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: family == .systemSmall ? .center : .topLeading
        )
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

private struct OpenCodeProviderUsageSingleBar: View {
    let metric: OpenCodeProviderUsageDisplayMetric
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(metric.providerName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                OpenCodeProviderUsageLogo(providerID: metric.providerID, size: 24)
            }

            Spacer(minLength: 6)

            openCodeProviderUsageValue(metric)
                .font(.largeTitle.monospacedDigit().weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .trailing)

            OpenCodeProviderUsageTrack(metric: metric)
                .frame(height: 5)
                .padding(.top, 2)

            if let resetAt = metric.resetAt {
                HStack(spacing: 4) {
                    Text(resetAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Text(verbatim: "•")
                    Text(verbatim: openCodeProviderUsageCompactDuration(resetAt, relativeTo: referenceDate)
                        ?? String(localized: "Now"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OpenCodeProviderUsageBarRow: View {
    let metric: OpenCodeProviderUsageDisplayMetric
    let showsCaption: Bool
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OpenCodeProviderUsageLogo(providerID: metric.providerID, size: 18)
                Text(verbatim: showsCaption ? metric.providerName : "\(metric.providerName) · \(metric.metricLabel)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if !showsCaption, let resetAt = metric.resetAt {
                    Text(openCodeProviderUsageResetLabel(resetAt, relativeTo: referenceDate))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                openCodeProviderUsageValue(metric)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            if showsCaption {
                HStack(spacing: 4) {
                    Text(metric.metricLabel)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let resetAt = metric.resetAt {
                        Text(openCodeProviderUsageResetLabel(resetAt, relativeTo: referenceDate))
                            .lineLimit(1)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            OpenCodeProviderUsageTrack(metric: metric)
            .frame(height: 3)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct OpenCodeProviderUsageTrack: View {
    let metric: OpenCodeProviderUsageDisplayMetric

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.16))
                if case .progress(let fraction, let isOverLimit) = metric.renderState {
                    Capsule()
                        .fill(isOverLimit ? Color.red : Color.accentColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
        }
    }
}

private struct OpenCodeProviderUsageRing: View {
    let metric: OpenCodeProviderUsageDisplayMetric
    let family: WidgetFamily
    let referenceDate: Date

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.16), lineWidth: ringWidth)
                if case .progress(let fraction, let isOverLimit) = metric.renderState {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            isOverLimit ? Color.red : Color.accentColor,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                OpenCodeProviderUsageLogo(providerID: metric.providerID, size: logoSize)
            }
            .frame(width: ringSize, height: ringSize)
            openCodeProviderUsageValue(metric)
                .font(valueFont)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, family == .systemSmall ? 7 : 1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var ringSize: CGFloat { family == .systemSmall ? 76 : 48 }
    private var logoSize: CGFloat { family == .systemSmall ? 42 : 27 }
    private var ringWidth: CGFloat { family == .systemSmall ? 7 : 5 }
    private var valueFont: Font {
        family == .systemSmall
            ? .title2.monospacedDigit().weight(.semibold)
            : .caption2.monospacedDigit().weight(.semibold)
    }

    private var caption: String {
        if let resetAt = metric.resetAt { return openCodeProviderUsageCompactResetLabel(resetAt, relativeTo: referenceDate) }
        if let period = metric.period { return openCodeProviderUsagePeriodLabel(period) }
        return metric.metricLabel
    }
}

private struct OpenCodeProviderUsageLogo: View {
    let providerID: String
    let size: CGFloat

    var body: some View {
        Group {
            if UIImage(named: assetName) != nil {
                Image(assetName).resizable().renderingMode(.template).scaledToFit()
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.62, weight: .semibold))
            }
        }
        .foregroundStyle(.primary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var assetName: String { "ProviderIcon_\(providerID)" }
}

@ViewBuilder
private func openCodeProviderUsageValue(_ metric: OpenCodeProviderUsageDisplayMetric) -> some View {
    if metric.isUnlimited {
        Text("Unlimited")
    } else if let percent = metric.percentUsed, percent.isFinite {
        Text(percent / 100, format: .percent.precision(.fractionLength(0...1)))
            .foregroundStyle(percent > 100 ? Color.red : Color.primary)
    } else if let value = metric.value {
        switch metric.unit {
        case .currency(let code): Text(value, format: .currency(code: code))
        case .percentage: Text(Double(truncating: value as NSNumber) / 100, format: .percent)
        case .count: Text(value, format: .number)
        case .credits: Text("\(value, format: .number) credits")
        }
    } else {
        Text("Unavailable").foregroundStyle(.secondary)
    }
}

private func openCodeProviderUsageResetLabel(_ resetAt: Date, relativeTo now: Date) -> String {
    String(localized: "Reset \(openCodeProviderUsageCompactResetLabel(resetAt, relativeTo: now))")
}

private func openCodeProviderUsageCompactResetLabel(_ resetAt: Date, relativeTo now: Date) -> String {
    guard let duration = openCodeProviderUsageCompactDuration(resetAt, relativeTo: now) else {
        return String(localized: "Now")
    }
    return String(localized: "In \(duration)")
}

private func openCodeProviderUsageCompactDuration(_ resetAt: Date, relativeTo now: Date) -> String? {
    let seconds = resetAt.timeIntervalSince(now)
    guard seconds >= 60 else { return nil }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    formatter.allowedUnits = seconds >= 86_400 ? [.day] : (seconds >= 3_600 ? [.hour] : [.minute])
    return formatter.string(from: seconds)
}

private func openCodeProviderUsagePeriodLabel(_ period: OpenCodeProviderUsageDisplayPeriod) -> String {
    switch period {
    case .lifetime: String(localized: "Lifetime")
    case .day: String(localized: "Daily")
    case .week: String(localized: "Weekly")
    case .month: String(localized: "Monthly")
    case .rolling(let seconds):
        Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 1))
    case .other(let value): value
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
