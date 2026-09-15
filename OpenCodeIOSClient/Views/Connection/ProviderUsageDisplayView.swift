import SwiftUI

struct ProviderUsageDisplayConfigurationView: View {
    let facade: ProviderUsageFacade

    private var store: ProviderUsageDisplayStore { facade.displayStore }

    var body: some View {
        List {
            Section {
                Picker("Usage Display Style", selection: displayModeBinding) {
                    Text("Bars").tag(OpenCodeProviderUsageDisplayMode.progressBar)
                    Text("Rings").tag(OpenCodeProviderUsageDisplayMode.progressRing)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Display Style")
            } footer: {
                Text("One style is shared by Projects and Activity.")
            }

            Section {
                if store.availableMetrics.isEmpty {
                    ContentUnavailableView(
                        "No Usage Preview",
                        systemImage: "gauge.with.dots.needle.0percent",
                        description: Text("Refresh a saved usage account to preview its metrics.")
                    )
                } else {
                    ProviderUsageMetricCollection(metrics: store.previewMetrics, mode: store.displayMode)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Preview")
            } footer: {
                if !store.availableMetrics.isEmpty,
                   store.orderedAvailableMetrics.allSatisfy({
                       !store.isVisible($0.identity, in: .home) && !store.isVisible($0.identity, in: .activity)
                   }) {
                    Text("Showing available metrics until you choose Home or Activity.")
                }
            }

            if store.orderedAvailableMetrics.isEmpty {
                ContentUnavailableView(
                    "No Usage Metrics",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text("Refresh a saved usage account to choose metrics for Home and Activity.")
                )
            } else {
                Section {
                    ForEach(store.orderedAvailableMetrics) { metric in
                        ProviderUsageDisplayConfigurationRow(metric: metric, store: store)
                    }
                    .onMove(perform: store.moveAvailableMetrics)
                } footer: {
                    Text("Drag metrics into one shared order. Home and Activity visibility can be chosen independently.")
                }
            }
        }
        .navigationTitle("Displayed Usage")
        .opencodeInlineNavigationTitle()
        .toolbar { EditButton() }
        .task { await facade.prepareDisplayConfiguration() }
    }

    private var displayModeBinding: Binding<OpenCodeProviderUsageDisplayMode> {
        Binding(
            get: { store.displayMode },
            set: { store.setDisplayMode($0) }
        )
    }
}

private struct ProviderUsageDisplayConfigurationRow: View {
    let metric: OpenCodeProviderUsageDisplayMetric
    let store: ProviderUsageDisplayStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(metric.metricLabel)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    if let period = metric.period {
                        Text(providerUsageDisplayPeriodLabel(period))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(verbatim: "\(metric.providerName) · \(metric.accountLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(spacing: 14) {
                Toggle("Home", isOn: visibilityBinding(.home))
                Toggle("Activity", isOn: visibilityBinding(.activity))
            }
            .toggleStyle(.switch)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private func visibilityBinding(_ destination: OpenCodeProviderUsageDestination) -> Binding<Bool> {
        Binding(
            get: { store.isVisible(metric.identity, in: destination) },
            set: { store.setVisible($0, identity: metric.identity, destination: destination) }
        )
    }
}

struct ProviderUsageDisplayRows: View {
    enum Presentation {
        case standard
        case card
    }

    let metrics: [OpenCodeProviderUsageDisplayMetric]
    var presentation: Presentation = .standard
    var mode: OpenCodeProviderUsageDisplayMode = .progressBar

    var body: some View {
        if !metrics.isEmpty {
            Section {
                ProviderUsageMetricCollection(metrics: metrics, mode: mode)
                    .modifier(ProviderUsageDisplayListRowModifier(presentation: presentation))
            } header: {
                sectionHeader
            }
        }
    }

    @ViewBuilder
    private var sectionHeader: some View {
        switch presentation {
        case .standard:
            Label("Usage", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
                .textCase(nil)
                .padding(.leading, -16)
        case .card:
            Label("Usage", systemImage: "gauge.with.dots.needle.67percent")
                .font(.headline)
                .textCase(nil)
        }
    }

}

struct ProviderUsageMetricCollection: View {
    let metrics: [OpenCodeProviderUsageDisplayMetric]
    let mode: OpenCodeProviderUsageDisplayMode

    var body: some View {
        switch mode {
        case .progressBar:
            VStack(spacing: 0) {
                ForEach(metrics) { metric in
                    ProviderUsageCompactMetricRow(metric: metric)
                    if metric.id != metrics.last?.id { Divider() }
                }
            }
        case .progressRing:
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                alignment: .center,
                spacing: 14
            ) {
                ForEach(metrics) { ProviderUsageRingMetric(metric: $0) }
            }
        }
    }
}

private struct ProviderUsageDisplayListRowModifier: ViewModifier {
    let presentation: ProviderUsageDisplayRows.Presentation

    func body(content: Content) -> some View {
        switch presentation {
        case .standard:
            content
        case .card:
            content
                .padding(15)
                .background(
                    OpenCodePlatformColor.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }
}

private struct ProviderUsageCompactMetricRow: View {
    let metric: OpenCodeProviderUsageDisplayMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 8) {
                    ProviderLogo(providerID: metric.providerID, size: 24)
                    Text(metric.providerName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    metricValue
                        .font(.caption.monospacedDigit().weight(.medium))
                    if let resetAt = metric.resetAt {
                        HStack(spacing: 4) {
                            Text("Reset")
                            Text(resetAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            Text(verbatim: "·")
                            Text(resetAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                }
            }
            metricTrack
                .frame(height: 3)
                .clipShape(Capsule())
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var metricValue: some View {
        if metric.isUnlimited {
            Text("Unlimited")
        } else if let percent = metric.percentUsed {
            Text(percent / 100, format: .percent.precision(.fractionLength(0...1)))
        } else if let value = metric.value {
            switch metric.unit {
            case .currency(let code): Text(value, format: .currency(code: code))
            case .percentage: Text(Double(truncating: value as NSNumber) / 100, format: .percent)
            case .count: Text(value, format: .number)
            case .credits: Text("\(value, format: .number) credits")
            }
        } else {
            Text("Unavailable")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var metricTrack: some View {
        if let percent = metric.percentUsed, !metric.isUnlimited {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Color.secondary.opacity(0.14)
                    (percent > 100 ? Color.red : Color.accentColor)
                        .frame(width: geometry.size.width * min(max(percent / 100, 0), 1))
                }
            }
        } else {
            Color.secondary.opacity(0.14)
        }
    }

    private var accessibilityLabel: Text {
        providerUsageAccessibilityLabel(metric)
    }
}

private struct ProviderUsageRingMetric: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let metric: OpenCodeProviderUsageDisplayMetric

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.14), lineWidth: ringWidth)
                if case .progress(let fraction, let isOverLimit) = metric.renderState {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            isOverLimit ? Color.red : Color.accentColor,
                            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                ProviderLogo(providerID: metric.providerID, size: logoSize, style: .plain)
            }
            .frame(width: ringSize, height: ringSize)

            providerUsageMetricValue(metric)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(contextLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(providerUsageAccessibilityLabel(metric))
    }

    private var contextLabel: String {
        if let resetAt = metric.resetAt {
            return providerUsageCompactResetLabel(resetAt)
        }
        if let period = metric.period { return providerUsageDisplayPeriodLabel(period) }
        return metric.metricLabel
    }

    private var ringSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 58 : 54 }
    private var logoSize: CGFloat { dynamicTypeSize.isAccessibilitySize ? 36 : 32 }
    private var ringWidth: CGFloat { dynamicTypeSize.isAccessibilitySize ? 6 : 5 }
}

private func providerUsageCompactResetLabel(_ resetAt: Date) -> String {
    let seconds = resetAt.timeIntervalSinceNow
    guard seconds >= 60 else { return String(localized: "Now") }

    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 1
    if seconds >= 86_400 {
        formatter.allowedUnits = [.day]
    } else if seconds >= 3_600 {
        formatter.allowedUnits = [.hour]
    } else {
        formatter.allowedUnits = [.minute]
    }

    guard let duration = formatter.string(from: seconds) else {
        return String(localized: "Now")
    }
    return String(localized: "In \(duration)")
}

@ViewBuilder
private func providerUsageMetricValue(_ metric: OpenCodeProviderUsageDisplayMetric) -> some View {
    if metric.isUnlimited {
        Text("Unlimited")
    } else if let percent = metric.percentUsed, percent.isFinite {
        Text(percent / 100, format: .percent.precision(.fractionLength(0...1)))
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

private func providerUsageAccessibilityLabel(_ metric: OpenCodeProviderUsageDisplayMetric) -> Text {
    Text(verbatim: "\(metric.providerName), \(metric.metricLabel), \(metric.period.map(providerUsageDisplayPeriodLabel) ?? ""), \(providerUsageAccessibilityValue(metric))")
}

private func providerUsageAccessibilityValue(_ metric: OpenCodeProviderUsageDisplayMetric) -> String {
    if metric.isUnlimited { return String(localized: "Unlimited") }
    if let percent = metric.percentUsed, percent.isFinite {
        return (percent / 100).formatted(.percent.precision(.fractionLength(0...1)))
    }
    guard let value = metric.value else { return String(localized: "Unavailable") }
    switch metric.unit {
    case .currency(let code): return value.formatted(.currency(code: code))
    case .percentage: return (Double(truncating: value as NSNumber) / 100).formatted(.percent)
    case .count: return value.formatted(.number)
    case .credits: return String(localized: "\(value, format: .number) credits")
    }
}

private func providerUsageDisplayPeriodLabel(_ period: OpenCodeProviderUsageDisplayPeriod) -> String {
    switch period {
    case .lifetime:
        return String(localized: "Lifetime")
    case .day:
        return String(localized: "Daily")
    case .week:
        return String(localized: "Weekly")
    case .month:
        return String(localized: "Monthly")
    case .rolling(let seconds):
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        if seconds.isMultiple(of: 86_400) {
            formatter.allowedUnits = [.day]
        } else if seconds.isMultiple(of: 3_600) {
            formatter.allowedUnits = [.hour]
        } else {
            formatter.allowedUnits = [.minute]
        }
        return formatter.string(from: TimeInterval(seconds)) ?? String(localized: "Rolling window")
    case .other(let value):
        return value
    }
}
