import SwiftUI

/// Renders only prepared rows; no wire JSON or transcript-derived estimates.
struct SessionMetadataSectionsView: View {
    let sections: [SessionMetadataSection]

    var body: some View {
        ForEach(sections) { section in
            Section {
                ForEach(section.rows) { row in
                    LabeledContent {
                        SessionMetadataValueView(value: row.value)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    } label: {
                        if let rawLabel = row.rawLabel {
                            Text(verbatim: rawLabel)
                        } else {
                            Text(row.label)
                        }
                    }
                    .accessibilityIdentifier("chat.metadata.\(section.id).\(row.id)")
                }
            } header: {
                Text(section.title)
            } footer: {
                if let note = section.note {
                    Text(note)
                }
            }
        }
    }
}

struct SessionServerContextSummaryView: View {
    let context: OpenCodeSessionContextSnapshot?

    private var progress: Double? {
        guard let usage = context?.usage else { return nil }
        return min(1, max(0, Double(usage) / 100))
    }

    private var tint: Color {
        guard let usage = context?.usage else { return .secondary }
        if usage >= 90 { return .red }
        if usage >= 70 { return .orange }
        return .blue
    }

    var body: some View {
        HStack(spacing: 16) {
            ContextUsageRing(progress: progress ?? 0, tint: tint, lineWidth: 6)
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if let context {
                    if let usage = context.usage {
                        Text(Double(usage) / 100, format: .percent.precision(.fractionLength(0)))
                            .font(.title2.weight(.semibold))
                    } else {
                        Text("Context limit unavailable")
                            .font(.headline)
                    }
                    Text("\(context.total, format: .number) tokens used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Context usage unavailable")
                        .font(.headline)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.metadata.contextSummary")
    }
}

private struct SessionMetadataValueView: View {
    let value: SessionMetadataValue

    var body: some View {
        switch value {
        case .text(let text):
            Text(verbatim: text)
        case .integer(let number):
            Text(number, format: .number)
        case .currencyUSD(let number):
            if number.isFinite, number >= 0 {
                Text(number, format: .currency(code: "USD").precision(.fractionLength(number > 0 && number < 0.01 ? 4 : 2)))
            } else {
                Text("Unavailable")
            }
        case .decimal(let number):
            if number.isFinite {
                Text(number, format: .number.precision(.fractionLength(0...3)))
            } else {
                Text("Unavailable")
            }
        case .durationMilliseconds(let milliseconds):
            if milliseconds.isFinite, milliseconds >= 0 {
                Text(Duration.seconds(milliseconds / 1000), format: .units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))
            } else {
                Text("Unavailable")
            }
        case .dateMilliseconds(let milliseconds):
            if milliseconds.isFinite {
                Text(Date(timeIntervalSince1970: milliseconds / 1000), format: .dateTime.year().month(.abbreviated).day().hour().minute())
            } else {
                Text("Unavailable")
            }
        case .percent(let percent):
            if percent.isFinite {
                Text(percent / 100, format: .percent.precision(.fractionLength(0...1)))
            } else {
                Text("Unavailable")
            }
        case .boolean(let value):
            if value { Text("Yes") } else { Text("No") }
        case .unavailable:
            Text("Unavailable")
        }
    }
}
