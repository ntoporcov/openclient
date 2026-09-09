import Foundation

public enum OpenClientSharePayloadStore {
    public static let appGroupID = "group.com.ntoporcov.openclient"
    public static let recentServerConfigsKey = "recentServerConfigs"

    private static let directoryName = "SharedPayloads"

    public static func save(_ payload: OpenClientSharePayload) throws {
        let directory = try payloadDirectory()
        let data = try JSONEncoder().encode(payload)
        try data.write(to: directory.appendingPathComponent(payload.id).appendingPathExtension("json"), options: [.atomic])
    }

    public static func load(id: String, deletesAfterLoad: Bool = true) throws -> OpenClientSharePayload {
        let url = try payloadDirectory().appendingPathComponent(id).appendingPathExtension("json")
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(OpenClientSharePayload.self, from: data)
        if deletesAfterLoad {
            try FileManager.default.removeItem(at: url)
        }
        return payload
    }

    public static func recentSavedServers() -> [OpenClientShareSavedServer] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: recentServerConfigsKey),
              let servers = try? JSONDecoder().decode([OpenClientShareSavedServer].self, from: data) else {
            return []
        }
        return servers
    }

    public static func mirrorRecentServersData(_ data: Data?) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        if let data {
            defaults.set(data, forKey: recentServerConfigsKey)
        } else {
            defaults.removeObject(forKey: recentServerConfigsKey)
        }
    }

    private static func payloadDirectory() throws -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let directory = containerURL.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public struct OpenClientSharePayload: Codable, Equatable, Sendable {
    public var id: String
    public var serverID: String?
    public var text: String
    public var attachments: [OpenClientShareAttachment]

    public init(id: String, serverID: String?, text: String, attachments: [OpenClientShareAttachment]) {
        self.id = id
        self.serverID = serverID
        self.text = text
        self.attachments = attachments
    }
}

public struct OpenClientShareAttachment: Codable, Equatable, Sendable {
    public var filename: String
    public var mime: String
    public var dataURL: String

    public init(filename: String, mime: String, dataURL: String) {
        self.filename = filename
        self.mime = mime
        self.dataURL = dataURL
    }
}

public struct OpenClientShareSavedServer: Codable, Equatable, Sendable, Identifiable {
    public var name: String?
    public var iconName: String?
    public var baseURL: String
    public var username: String

    public init(name: String? = nil, iconName: String? = nil, baseURL: String, username: String) {
        self.name = name
        self.iconName = iconName
        self.baseURL = baseURL
        self.username = username
    }

    public var id: String { recentServerID }

    public var recentServerID: String {
        "\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    public var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        return URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host() ?? baseURL
    }
}
