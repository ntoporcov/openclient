import Foundation
import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct OpenCodeProviderUsageWidgetContent: View {
    let metrics: [OpenCodeProviderUsageDisplayMetric]
    let style: OpenCodeProviderUsageWidgetStyle
    let size: OpenCodeProviderUsageWidgetSize
    let referenceDate: Date

    var body: some View {
        switch style {
        case .bars:
            OpenCodeProviderUsageBarsContent(metrics: metrics, size: size, referenceDate: referenceDate)
        case .rings:
            OpenCodeProviderUsageRingsContent(metrics: metrics, size: size, referenceDate: referenceDate)
        }
    }
}

private struct OpenCodeProviderUsageBarsContent: View {
    let metrics: [OpenCodeProviderUsageDisplayMetric]
    let size: OpenCodeProviderUsageWidgetSize
    let referenceDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: size == .small ? 9 : 6) {
            if size == .small, let metric = metrics.first {
                OpenCodeProviderUsageSingleBar(metric: metric, referenceDate: referenceDate)
            } else {
                Text("Usage")
                    .font(.subheadline.weight(.semibold))
                VStack(spacing: size == .large ? 6 : 4) {
                    ForEach(metrics) { metric in
                        OpenCodeProviderUsageBarRow(
                            metric: metric,
                            showsCaption: size == .large,
                            referenceDate: referenceDate
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OpenCodeProviderUsageRingsContent: View {
    let metrics: [OpenCodeProviderUsageDisplayMetric]
    let size: OpenCodeProviderUsageWidgetSize
    let referenceDate: Date

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: size == .small ? 1 : 4),
            spacing: size == .large ? 16 : 8
        ) {
            ForEach(metrics) { metric in
                OpenCodeProviderUsageRing(metric: metric, size: size, referenceDate: referenceDate)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: size == .small ? .center : .topLeading
        )
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
    let size: OpenCodeProviderUsageWidgetSize
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
                .padding(.top, size == .small ? 7 : 1)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var ringSize: CGFloat { size == .small ? 76 : 48 }
    private var logoSize: CGFloat { size == .small ? 42 : 27 }
    private var ringWidth: CGFloat { size == .small ? 7 : 5 }
    private var valueFont: Font {
        size == .small
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
            if hasAsset {
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
    private var hasAsset: Bool {
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSImage(named: NSImage.Name(assetName)) != nil
#elseif canImport(UIKit)
        UIImage(named: assetName) != nil
#else
        false
#endif
    }
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
