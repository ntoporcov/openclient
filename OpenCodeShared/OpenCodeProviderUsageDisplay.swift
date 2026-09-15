import Foundation

enum OpenCodeProviderUsageDestination: String, Codable, CaseIterable, Hashable, Sendable {
    case home
    case activity
}

enum OpenCodeProviderUsageDisplayMode: String, Codable, CaseIterable, Hashable, Sendable {
    case progressBar
    case progressRing
}

struct OpenCodeProviderUsageDisplayModeRecord: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    let mode: OpenCodeProviderUsageDisplayMode

    init(version: Int = Self.currentVersion, mode: OpenCodeProviderUsageDisplayMode) {
        self.version = version
        self.mode = mode
    }
}

struct OpenCodeProviderUsageMetricIdentity: Codable, Hashable, Sendable {
    let accountID: UUID
    let metricID: String
}

struct OpenCodeProviderUsageMetricSelection: Codable, Hashable, Sendable {
    let identity: OpenCodeProviderUsageMetricIdentity
    var showsOnHome: Bool
    var showsInActivity: Bool

    func isVisible(in destination: OpenCodeProviderUsageDestination) -> Bool {
        switch destination {
        case .home: showsOnHome
        case .activity: showsInActivity
        }
    }
}

struct OpenCodeProviderUsageSelectionRecord: Codable, Hashable, Sendable {
    static let currentVersion = 1

    let version: Int
    var selections: [OpenCodeProviderUsageMetricSelection]

    init(version: Int = Self.currentVersion, selections: [OpenCodeProviderUsageMetricSelection]) {
        self.version = version
        self.selections = selections
    }
}

enum OpenCodeProviderUsageValueUnit: Codable, Hashable, Sendable {
    case currency(String)
    case count
    case credits
    case percentage
}

enum OpenCodeProviderUsageDisplayPeriod: Codable, Hashable, Sendable {
    case lifetime
    case day
    case week
    case month
    case rolling(seconds: Int)
    case other(String)
}

struct OpenCodeProviderUsageDisplayMetric: Codable, Identifiable, Hashable, Sendable {
    var id: OpenCodeProviderUsageMetricIdentity { identity }

    let identity: OpenCodeProviderUsageMetricIdentity
    let providerID: String
    let providerName: String
    let accountLabel: String
    let metricLabel: String
    let value: Decimal?
    let percentUsed: Double?
    let unit: OpenCodeProviderUsageValueUnit
    let period: OpenCodeProviderUsageDisplayPeriod?
    let resetAt: Date?
    let isUnlimited: Bool
    let fetchedAt: Date
}

struct OpenCodeProviderUsageWidgetPayload: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let empty = OpenCodeProviderUsageWidgetPayload(version: currentVersion, metrics: [], generatedAt: .distantPast)

    let version: Int
    let metrics: [OpenCodeProviderUsageDisplayMetric]
    let generatedAt: Date

}

enum OpenCodeProviderUsageWidgetStyle: Hashable, Sendable {
    case bars
    case rings
}

enum OpenCodeProviderUsageWidgetSize: Hashable, Sendable {
    case small
    case medium
    case large
}

enum OpenCodeProviderUsageWidgetMetrics {
    static func stableID(for identity: OpenCodeProviderUsageMetricIdentity) -> String {
        let source = identity.accountID.uuidString.lowercased() + "\u{1f}" + identity.metricID
        let primary = stableHash(source, seed: 14_695_981_039_346_656_037)
        let secondary = stableHash("provider-usage\u{1e}" + source, seed: 10_995_116_282_111)
        return String(format: "usage-%016llx%016llx", primary, secondary)
    }

    static func limit(for style: OpenCodeProviderUsageWidgetStyle, size: OpenCodeProviderUsageWidgetSize) -> Int {
        switch (style, size) {
        case (_, .small): 1
        case (.bars, .medium), (.rings, .medium): 4
        case (.bars, .large): 6
        case (.rings, .large): 8
        }
    }

    static func resolve(
        metrics: [OpenCodeProviderUsageDisplayMetric],
        configuredIDs: [String],
        limit: Int
    ) -> [OpenCodeProviderUsageDisplayMetric] {
        guard limit > 0 else { return [] }
        let uniqueMetrics = metrics.reduce(into: [String: OpenCodeProviderUsageDisplayMetric]()) { result, metric in
            let id = stableID(for: metric.identity)
            if result[id] == nil { result[id] = metric }
        }
        guard !configuredIDs.isEmpty else { return Array(metrics.prefix(limit)) }

        var seen: Set<String> = []
        var resolved: [OpenCodeProviderUsageDisplayMetric] = []
        for id in configuredIDs where resolved.count < limit {
            guard seen.insert(id).inserted, let metric = uniqueMetrics[id] else { continue }
            resolved.append(metric)
        }
        return resolved.isEmpty ? Array(metrics.prefix(limit)) : resolved
    }

    private static func stableHash(_ value: String, seed: UInt64) -> UInt64 {
        value.utf8.reduce(seed) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

enum OpenCodeProviderUsageRenderState: Hashable, Sendable {
    case unavailable
    case unlimited
    case valueOnly
    case progress(fraction: Double, isOverLimit: Bool)
}

extension OpenCodeProviderUsageDisplayMetric {
    var renderState: OpenCodeProviderUsageRenderState {
        if isUnlimited { return .unlimited }
        if let percentUsed, percentUsed.isFinite {
            return .progress(fraction: min(max(percentUsed / 100, 0), 1), isOverLimit: percentUsed > 100)
        }
        if value != nil { return .valueOnly }
        return .unavailable
    }
}

struct OpenCodeProviderUsageDisplayPersistence {
    static let appGroupIdentifier = "group.com.ntoporcov.openclient"

    private let defaults: UserDefaults
    private let selectionKey = "OpenCodeProviderUsageMetricSelections"
    private let widgetPayloadKey = "OpenCodeProviderUsageWidgetPayload"
    private let displayModeKey = "OpenCodeProviderUsageDisplayMode"
    private let maximumBytes = 256_000

    init(defaults: UserDefaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard) {
        self.defaults = defaults
    }

    func loadSelections() -> OpenCodeProviderUsageSelectionRecord {
        guard let data = defaults.data(forKey: selectionKey), data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(OpenCodeProviderUsageSelectionRecord.self, from: data),
              record.version == OpenCodeProviderUsageSelectionRecord.currentVersion else {
            return .init(selections: [])
        }
        var seen: Set<OpenCodeProviderUsageMetricIdentity> = []
        return .init(selections: record.selections.filter {
            !$0.identity.metricID.isEmpty
                && $0.identity.metricID.count <= 256
                && !$0.identity.metricID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && seen.insert($0.identity).inserted
        })
    }

    func saveSelections(_ selections: [OpenCodeProviderUsageMetricSelection]) {
        let record = OpenCodeProviderUsageSelectionRecord(selections: selections)
        guard let data = try? JSONEncoder().encode(record), data.count <= maximumBytes else { return }
        defaults.set(data, forKey: selectionKey)
    }

    func loadDisplayMode() -> OpenCodeProviderUsageDisplayMode {
        guard let data = defaults.data(forKey: displayModeKey), data.count <= maximumBytes,
              let record = try? JSONDecoder().decode(OpenCodeProviderUsageDisplayModeRecord.self, from: data),
              record.version == OpenCodeProviderUsageDisplayModeRecord.currentVersion else {
            return .progressBar
        }
        return record.mode
    }

    func saveDisplayMode(_ mode: OpenCodeProviderUsageDisplayMode) {
        let record = OpenCodeProviderUsageDisplayModeRecord(mode: mode)
        guard let data = try? JSONEncoder().encode(record), data.count <= maximumBytes else { return }
        defaults.set(data, forKey: displayModeKey)
    }

    func loadWidgetPayload() -> OpenCodeProviderUsageWidgetPayload {
        guard let data = defaults.data(forKey: widgetPayloadKey), data.count <= maximumBytes,
              let payload = try? JSONDecoder().decode(OpenCodeProviderUsageWidgetPayload.self, from: data),
              payload.version == OpenCodeProviderUsageWidgetPayload.currentVersion else { return .empty }
        return payload
    }

    func saveWidgetPayload(_ payload: OpenCodeProviderUsageWidgetPayload) {
        guard let data = try? JSONEncoder().encode(payload), data.count <= maximumBytes else { return }
        defaults.set(data, forKey: widgetPayloadKey)
    }
}
