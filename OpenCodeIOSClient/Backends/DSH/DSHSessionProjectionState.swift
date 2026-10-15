import Foundation

/// One session's canonical projection fold within a control-stream generation.
/// Sequence numbers are per key; a complete baseline also fences previously absent keys.
struct DSHSessionProjectionState: Sendable {
    private struct Entry: Sendable {
        var sequence: Int
        var value: DSHJSON?
    }

    private var entries: [String: Entry] = [:]
    private var baselineSequence: Int?
    private(set) var isCurrent = false
    private(set) var header = Header()

    struct Header: Sendable {
        var createdAt: Double?
        var cwd: String?
        var parentSession: String?
        var origin: String?
        var isSeeded: Bool?
        var delegationDepth: Int?
        var version: Int?
    }

    var values: [String: DSHJSON] {
        guard isCurrent else { return [:] }
        return entries.compactMapValues(\.value)
    }

    var metadata: BackendSessionMetadata {
        .init(projections: values, isCurrent: isCurrent, createdAt: header.createdAt,
              origin: header.origin, isSeeded: header.isSeeded,
              delegationDepth: header.delegationDepth, version: header.version, parentSession: header.parentSession)
    }

    mutating func applyBaseline(_ baseline: DSHJSON) throws {
        guard let sequence = baseline[dsh: "asOfSeq"].intValue, sequence >= -1,
              let values = baseline[dsh: "values"].objectValue else { throw URLError(.cannotParseResponse) }
        if let baselineSequence, sequence < baselineSequence { return }
        // Omission is a tombstone; explicit null stays in the canonical dictionary.
        // Neither permits restoring an older hint or delta.
        for key in Set(entries.keys).union(values.keys) {
            guard (entries[key]?.sequence ?? Int.min) <= sequence else { continue }
            entries[key] = Entry(sequence: sequence, value: values[key])
        }
        baselineSequence = sequence
        isCurrent = true
    }

    @discardableResult
    mutating func applyDelta(key: String, value: DSHJSON, sequence: Int) -> Bool {
        guard !key.isEmpty, sequence >= -1,
              sequence > max(entries[key]?.sequence ?? Int.min, baselineSequence ?? Int.min) else { return false }
        entries[key] = Entry(sequence: sequence, value: value)
        isCurrent = true
        return true
    }

    /// Fold the host's loaded-session baseline into this connection generation.
    /// Reconnect already invalidates old state. Independently reopened follow streams
    /// may have supplied newer data, including cold sessions omitted by control.
    static func applyingControlBaseline(_ baselines: [String: DSHJSON],
                                        to current: [String: Self],
                                        startsNewGeneration: Bool) throws -> [String: Self] {
        var states = current
        if startsNewGeneration {
            for id in Array(states.keys) { states[id]?.invalidate() }
        }
        for (id, baseline) in baselines {
            try states[id, default: .init()].applyBaseline(baseline)
        }
        return states
    }

    /// An explicitly new generation replaces, rather than merges, old state.
    mutating func replaceGeneration(with baseline: DSHJSON) throws {
        var next = Self()
        next.header = header
        try next.applyBaseline(baseline)
        self = next
    }

    /// Keep immutable header identity, but never show stale live metrics while reconnecting.
    mutating func invalidate() {
        entries.removeAll()
        baselineSequence = nil
        isCurrent = false
    }

    /// A permission write can time out after being applied. Mark only that key unknown,
    /// retaining its fence; a subsequent full read at the same cursor can reconcile it.
    mutating func invalidate(key: String) {
        entries[key] = Entry(sequence: max(entries[key]?.sequence ?? -1, baselineSequence ?? -1), value: .null)
    }

    /// Follow headers are canonical but optional malformed metadata is simply unavailable.
    mutating func applyHeader(_ value: DSHJSON) {
        var next = Header()
        if let created = value[dsh: "createdAt"].doubleValue, created.isFinite, created >= 0 { next.createdAt = created }
        next.cwd = value[dsh: "cwd"].dshString
        next.parentSession = value[dsh: "parentSession"].dshString
        next.origin = value[dsh: "origin"].dshString
        if case let .bool(seeded) = value[dsh: "isSeeded"] { next.isSeeded = seeded }
        if let depth = value[dsh: "delegationDepth"].intValue, depth >= 0 { next.delegationDepth = depth }
        if let version = value[dsh: "version"].intValue, version >= 0 { next.version = version }
        header = next
    }
}
