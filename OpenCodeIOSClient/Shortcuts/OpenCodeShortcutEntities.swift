import AppIntents
import Foundation

enum OpenCodeShortcutEntityID {
    static func make(kind: String, components: [String]) -> String {
        ([kind] + components.map(encode)).joined(separator: ".")
    }

    static func components(from id: String, kind: String) -> [String]? {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.first == kind else { return nil }
        let decoded = parts.dropFirst().compactMap(decode)
        guard decoded.count == parts.count - 1 else { return nil }
        return decoded
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: 4 - padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct OpenCodeShortcutConnectionEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenClient Connection")
    static let defaultQuery = OpenCodeShortcutConnectionQuery()

    let id: String
    let displayName: String
    let baseURL: String
    let username: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle = username.isEmpty ? baseURL : "\(username) · \(baseURL)"
        return DisplayRepresentation(title: "\(displayName)", subtitle: "\(subtitle)")
    }
}

struct OpenCodeShortcutProjectEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenClient Project")
    static let defaultQuery = OpenCodeShortcutProjectQuery()

    let id: String
    let connectionID: String
    let projectID: String
    let title: String
    let directory: String?

    var displayRepresentation: DisplayRepresentation {
        if let directory {
            DisplayRepresentation(title: "\(title)", subtitle: "\(directory)")
        } else {
            DisplayRepresentation(title: "\(title)")
        }
    }
}

struct OpenCodeShortcutSessionEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenClient Session")
    static let defaultQuery = OpenCodeShortcutSessionQuery()

    let id: String
    let connectionID: String
    let projectID: String
    let sessionID: String
    let title: String
    let directory: String?
    let workspaceID: String?
    let providerID: String?
    let modelID: String?
    let reasoningVariant: String?

    var displayRepresentation: DisplayRepresentation {
        if let directory {
            DisplayRepresentation(title: "\(title)", subtitle: "\(directory)")
        } else {
            DisplayRepresentation(title: "\(title)")
        }
    }

    var modelReference: OpenCodeModelReference? {
        guard let providerID, let modelID else { return nil }
        return OpenCodeModelReference(providerID: providerID, modelID: modelID)
    }

    func applying(model: OpenCodeShortcutModelEntity?, reasoning: String?) -> OpenCodeShortcutSessionEntity {
        OpenCodeShortcutSessionEntity(
            id: id,
            connectionID: connectionID,
            projectID: projectID,
            sessionID: sessionID,
            title: title,
            directory: directory,
            workspaceID: workspaceID,
            providerID: model?.providerID ?? providerID,
            modelID: model?.modelID ?? modelID,
            reasoningVariant: OpenCodeShortcutService.normalizedReasoning(reasoning) ?? reasoningVariant
        )
    }
}

struct OpenCodeShortcutModelEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenClient Model")
    static let defaultQuery = OpenCodeShortcutModelQuery()

    let id: String
    let connectionID: String
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let reasoningVariants: [String]

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(modelName)", subtitle: "\(providerName)")
    }

    var modelReference: OpenCodeModelReference {
        OpenCodeModelReference(providerID: providerID, modelID: modelID)
    }
}

struct OpenCodeShortcutConnectionQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeShortcutConnectionEntity.ID]) async throws -> [OpenCodeShortcutConnectionEntity] {
        let requested = Set(identifiers)
        return await OpenCodeShortcutService().connections().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [OpenCodeShortcutConnectionEntity] {
        await OpenCodeShortcutService().connections()
    }

    func defaultResult() async -> OpenCodeShortcutConnectionEntity? {
        await OpenCodeShortcutService().connections().first
    }
}

struct OpenCodeShortcutProjectQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeShortcutProjectEntity.ID]) async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(matching: identifiers)
    }

    func suggestedEntities() async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(connection: nil)
    }

    func defaultResult() async -> OpenCodeShortcutProjectEntity? {
        try? await OpenCodeShortcutService().projects(connection: nil).first
    }
}

struct OpenCodeShortcutSessionQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeShortcutSessionEntity.ID]) async throws -> [OpenCodeShortcutSessionEntity] {
        try await OpenCodeShortcutService().sessions(matching: identifiers)
    }

    func suggestedEntities() async throws -> [OpenCodeShortcutSessionEntity] {
        []
    }
}

struct OpenCodeShortcutModelQuery: EntityQuery {
    func entities(for identifiers: [OpenCodeShortcutModelEntity.ID]) async throws -> [OpenCodeShortcutModelEntity] {
        try await OpenCodeShortcutService().models(matching: identifiers)
    }

    func suggestedEntities() async throws -> [OpenCodeShortcutModelEntity] {
        try await OpenCodeShortcutService().models(connection: nil)
    }
}
