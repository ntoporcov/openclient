import Foundation

let openClientBridgeProtocolVersion = 1

enum OpenClientJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenClientJSONValue])
    case array([OpenClientJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenClientJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OpenClientJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var objectValue: [String: OpenClientJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}

struct OpenClientDeviceToolDescriptor: Codable, Equatable, Sendable {
    let id: String
    let description: String
    let inputSchema: [String: OpenClientJSONValue]

    var jsonValue: OpenClientJSONValue {
        .object([
            "id": .string(id),
            "description": .string(description),
            "inputSchema": .object(inputSchema),
        ])
    }
}

struct OpenClientRemoteToolContext: Equatable, Sendable {
    let sessionID: String
    let messageID: String
    let agent: String
    let directory: String
    let worktree: String

    init(jsonValue: OpenClientJSONValue) throws {
        guard let object = jsonValue.objectValue else {
            throw OpenClientBridgeProtocolError.invalidField("context")
        }
        sessionID = try object.requiredString("sessionID")
        messageID = try object.requiredString("messageID")
        agent = try object.requiredString("agent")
        directory = try object.requiredString("directory")
        worktree = try object.requiredString("worktree")
    }
}

struct OpenClientRemoteToolResult: Equatable, Sendable {
    let title: String?
    let output: String
    let metadata: [String: OpenClientJSONValue]?

    var jsonValue: OpenClientJSONValue {
        var object: [String: OpenClientJSONValue] = ["output": .string(output)]
        if let title { object["title"] = .string(title) }
        if let metadata { object["metadata"] = .object(metadata) }
        return .object(object)
    }
}

enum OpenClientBridgeRequestMethod: String, Codable, Sendable {
    case listTools = "list_tools"
    case executeTool = "execute_tool"
}

struct OpenClientBridgeRequest: Equatable, Sendable {
    let id: String
    let method: OpenClientBridgeRequestMethod
    let params: OpenClientJSONValue
}

enum OpenClientBridgeServerMessage: Equatable, Sendable {
    case registered(clientID: String)
    case request(OpenClientBridgeRequest)
    case cancel(id: String)
}

extension OpenClientBridgeServerMessage: Decodable {
    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case type
        case clientID
        case id
        case method
        case params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        guard protocolVersion == openClientBridgeProtocolVersion else {
            throw OpenClientBridgeProtocolError.unsupportedVersion(protocolVersion)
        }
        switch try container.decode(String.self, forKey: .type) {
        case "registered":
            self = .registered(clientID: try container.decode(String.self, forKey: .clientID))
        case "request":
            self = .request(
                OpenClientBridgeRequest(
                    id: try container.decode(String.self, forKey: .id),
                    method: try container.decode(OpenClientBridgeRequestMethod.self, forKey: .method),
                    params: try container.decode(OpenClientJSONValue.self, forKey: .params)
                )
            )
        case "cancel":
            self = .cancel(id: try container.decode(String.self, forKey: .id))
        default:
            throw OpenClientBridgeProtocolError.unsupportedMessage
        }
    }
}

struct OpenClientBridgeHealth: Decodable, Equatable, Sendable {
    let service: String
    let `protocol`: Int
    let port: Int
    let openCodePort: Int
    let notifications: OpenClientBridgeNotificationsAdvertisement?

    init(
        service: String,
        protocol: Int,
        port: Int,
        openCodePort: Int,
        notifications: OpenClientBridgeNotificationsAdvertisement? = nil
    ) {
        self.service = service
        self.protocol = `protocol`
        self.port = port
        self.openCodePort = openCodePort
        self.notifications = notifications
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case `protocol`
        case port
        case openCodePort
        case notifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        service = try container.decode(String.self, forKey: .service)
        `protocol` = try container.decode(Int.self, forKey: .protocol)
        port = try container.decode(Int.self, forKey: .port)
        openCodePort = try container.decode(Int.self, forKey: .openCodePort)
        notifications = (try? container.decodeIfPresent(
            OpenClientBridgeNotificationsAdvertisement.self,
            forKey: .notifications
        )) ?? nil
    }
}

struct OpenClientBridgeNotificationsAdvertisement: Decodable, Equatable, Sendable {
    enum State: Decodable, Equatable, Sendable {
        case ready
        case unconfigured
        case unavailable
        case unknown

        init(from decoder: Decoder) throws {
            switch try decoder.singleValueContainer().decode(String.self) {
            case "ready": self = .ready
            case "unconfigured": self = .unconfigured
            case "unavailable": self = .unavailable
            default: self = .unknown
            }
        }
    }

    let version: Int
    let state: State
    let publicOrigin: String?
    let pairing: OpenClientNotificationPairingLauncher?

    init(
        version: Int,
        state: State,
        publicOrigin: String?,
        pairing: OpenClientNotificationPairingLauncher? = nil
    ) {
        self.version = version
        self.state = state
        self.publicOrigin = publicOrigin
        self.pairing = pairing
    }
}

struct OpenClientNotificationPairingLauncher: Codable, Equatable, Sendable {
    let version: Int
    let cliPath: String
    let dataDir: String

    var isTrustedShape: Bool {
        guard version == 1,
              cliPath.hasPrefix("/"),
              cliPath.hasSuffix("/dist/notifications/src/cli.mjs"),
              dataDir.hasPrefix("/"),
              cliPath.utf8.count <= 4_096,
              dataDir.utf8.count <= 4_096,
              (cliPath as NSString).standardizingPath == cliPath,
              (dataDir as NSString).standardizingPath == dataDir else { return false }
        return !cliPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !dataDir.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

enum OpenClientBridgeNotificationsCapability: Equatable, Sendable {
    case missing
    case ready(publicOrigin: String)
    case unconfigured
    case unavailable
    case unsupportedVersion

    init(advertisement: OpenClientBridgeNotificationsAdvertisement?) {
        guard let advertisement else {
            self = .missing
            return
        }
        guard advertisement.version == 1 else {
            self = .unsupportedVersion
            return
        }
        switch advertisement.state {
        case .ready:
            guard let origin = advertisement.publicOrigin,
                  Self.isValidPublicOrigin(origin) else {
                self = .unavailable
                return
            }
            self = .ready(publicOrigin: origin)
        case .unconfigured:
            self = .unconfigured
        case .unavailable, .unknown:
            self = .unavailable
        }
    }

    private static func isValidPublicOrigin(_ value: String) -> Bool {
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              components.scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil,
              components.url?.absoluteString == value else { return false }
        return true
    }
}

enum OpenClientNotificationSetupError: LocalizedError, Equatable {
    case unavailable
    case invalidConnection
    case invalidResponse
    case invalidExpiry
    case staleSetup
    case browserOpenFailed
    case pairingUnavailable
    case pairingTimedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "OC Notify setup is not available from this plugin.")
        case .invalidConnection:
            String(localized: "The saved OpenCode connection cannot be used for notification setup.")
        case .invalidResponse:
            String(localized: "OC Notify returned an invalid setup response.")
        case .invalidExpiry:
            String(localized: "The OC Notify setup code is expired or invalid.")
        case .staleSetup:
            String(localized: "This OC Notify setup code is no longer valid. Generate a new code.")
        case .browserOpenFailed:
            String(localized: "OC Notify could not be opened. Try again or generate a new code.")
        case .pairingUnavailable:
            String(localized: "OC Notify pairing is not available from this plugin. Update the plugin and try again.")
        case .pairingTimedOut:
            String(localized: "OC Notify pairing timed out. Try again.")
        }
    }
}

struct OpenClientNotificationSetupContext: Equatable, Sendable {
    let connectionID: String
    let baseURL: String
    let username: String
    let profile: OpenCodeAPIProfile
    let savedServerID: String

    init(
        connectionID: String,
        config: OpenCodeServerConfig,
        profile: OpenCodeAPIProfile,
        savedServerID: String
    ) throws {
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !connectionID.isEmpty,
              !baseURL.isEmpty,
              baseURL.utf16.count <= 2_048,
              username.utf16.count <= 128,
              !baseURL.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              savedServerID == config.recentServerID,
              let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url?.absoluteString == baseURL else {
            throw OpenClientNotificationSetupError.invalidConnection
        }
        self.connectionID = connectionID
        self.baseURL = baseURL
        self.username = username
        self.profile = profile
        self.savedServerID = savedServerID
    }
}

struct OpenClientNotificationSetup: Decodable, Equatable, Sendable {
    let url: URL
    let code: String
    let expiresAt: Date
}

enum OpenClientBridgeProtocolError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unsupportedMessage
    case invalidField(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return String(localized: "Unsupported OpenClient bridge protocol version \(version).")
        case .unsupportedMessage:
            return String(localized: "The OpenClient bridge sent an unsupported message.")
        case .invalidField(let field):
            return String(localized: "The OpenClient bridge message has an invalid \(field) field.")
        case .unknownTool(let toolID):
            return String(localized: "This OpenClient app does not support \(toolID).")
        }
    }
}

extension Dictionary where Key == String, Value == OpenClientJSONValue {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue, !value.isEmpty else {
            throw OpenClientBridgeProtocolError.invalidField(key)
        }
        return value
    }

    func object(_ key: String) throws -> [String: OpenClientJSONValue] {
        guard let value = self[key]?.objectValue else {
            throw OpenClientBridgeProtocolError.invalidField(key)
        }
        return value
    }
}
