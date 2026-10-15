import Foundation

/// Backend-owned canonical metadata, separate from optional session-list hints.
/// An empty, non-current wrapper explicitly invalidates previously displayed metrics.
struct BackendSessionMetadata: Codable, Hashable, Sendable {
    var projections: [String: OpenCodeJSONValue]
    var isCurrent: Bool = true
    var createdAt: Double? = nil
    var origin: String? = nil
    var isSeeded: Bool? = nil
    var delegationDepth: Int? = nil
    var version: Int? = nil
    var parentSession: String? = nil

    init(projections: [String: OpenCodeJSONValue], isCurrent: Bool = true,
         createdAt: Double? = nil, origin: String? = nil, isSeeded: Bool? = nil,
         delegationDepth: Int? = nil, version: Int? = nil, parentSession: String? = nil) {
        self.projections = projections
        self.isCurrent = isCurrent
        self.createdAt = createdAt
        self.origin = origin
        self.isSeeded = isSeeded
        self.delegationDepth = delegationDepth
        self.version = version
        self.parentSession = parentSession
    }

    private enum CodingKeys: String, CodingKey {
        case projections, isCurrent, createdAt, origin, isSeeded, delegationDepth, version, parentSession
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projections = (try? values.decode([String: OpenCodeJSONValue].self, forKey: .projections)) ?? [:]
        isCurrent = (try? values.decode(Bool.self, forKey: .isCurrent)) ?? true
        createdAt = try? values.decode(Double.self, forKey: .createdAt)
        origin = try? values.decode(String.self, forKey: .origin)
        isSeeded = try? values.decode(Bool.self, forKey: .isSeeded)
        delegationDepth = try? values.decode(Int.self, forKey: .delegationDepth)
        version = try? values.decode(Int.self, forKey: .version)
        parentSession = try? values.decode(String.self, forKey: .parentSession)
    }
}
