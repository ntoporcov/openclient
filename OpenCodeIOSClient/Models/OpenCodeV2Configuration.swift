import Foundation

// HttpAPI next-17155 and anomalyco/opencode@41cb354c. These are not legacy provider auth methods.
struct OpenCodeV2Integration: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let methods: [OpenCodeV2IntegrationMethod]
    let connections: [OpenCodeV2IntegrationConnection]
    let metadata: [String: OpenCodeJSONValue]?
}

enum OpenCodeV2IntegrationMethod: Decodable, Equatable, Identifiable, Sendable {
    case key(label: String?, form: [OpenCodeV2IntegrationField])
    case oauth(id: String, label: String, form: [OpenCodeV2IntegrationField])
    case env(names: [String])
    case command(id: String, label: String, command: [String])
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey { case type, id, label, form, names, command }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "key": self = .key(label: try c.decodeIfPresent(String.self, forKey: .label),
                                form: try c.decodeIfPresent([OpenCodeV2IntegrationField].self, forKey: .form) ?? [])
        case "oauth": self = .oauth(id: try c.decode(String.self, forKey: .id), label: try c.decode(String.self, forKey: .label),
                                    form: try c.decodeIfPresent([OpenCodeV2IntegrationField].self, forKey: .form) ?? [])
        case "env": self = .env(names: try c.decode([String].self, forKey: .names))
        case "command": self = .command(id: try c.decode(String.self, forKey: .id), label: try c.decode(String.self, forKey: .label),
                                        command: try c.decode([String].self, forKey: .command))
        default: self = .unsupported(type: type)
        }
    }

    var id: String {
        switch self {
        case .key: return "key"
        case .oauth(let id, _, _): return "oauth:\(id)"
        case .command(let id, _, _): return "command:\(id)"
        case .env: return "env"
        case .unsupported(let type): return "unsupported:\(type)"
        }
    }

    var fields: [OpenCodeV2IntegrationField] {
        switch self {
        case .key(_, let form), .oauth(_, _, let form): return form
        default: return []
        }
    }

    var isSupported: Bool {
        switch self {
        case .key, .oauth:
            return BackendFormContract(fields: fields).isSupported(policy: .provider)
        default: return false
        }
    }

    func answer(values: [String: OpenCodeJSONValue]) throws -> [String: OpenCodeJSONValue] {
        guard isSupported else { throw OpenCodeV2ConfigurationError.unsupportedForm }
        do {
            return try BackendFormContract(fields: fields).answer(values: values, policy: .provider).mapValues(\.jsonValue)
        } catch BackendFormError.invalidField(let title) {
            throw OpenCodeV2ConfigurationError.invalidField(title)
        } catch {
            throw OpenCodeV2ConfigurationError.unsupportedForm
        }
    }

    func activeFields(values: [String: OpenCodeJSONValue]) -> [OpenCodeV2IntegrationField] {
        guard isSupported else { return [] }
        return BackendFormContract(fields: fields).activeFields(values: values, policy: .provider)
    }
}

enum OpenCodeV2IntegrationConnection: Decodable, Equatable, Identifiable, Sendable {
    case credential(id: String, label: String)
    case env(name: String)
    case unsupported(type: String)

    private enum CodingKeys: String, CodingKey { case type, id, label, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "credential": self = .credential(id: try c.decode(String.self, forKey: .id), label: try c.decode(String.self, forKey: .label))
        case "env": self = .env(name: try c.decode(String.self, forKey: .name))
        default: self = .unsupported(type: type)
        }
    }

    var id: String {
        switch self {
        case .credential(let id, _): return id
        case .env(let name): return "env:\(name)"
        case .unsupported(let type): return "unsupported:\(type)"
        }
    }
}

extension OpenCodeV2IntegrationMethod {
    var displayTitle: String {
        switch self {
        case .key(let label, _): return label.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "API Key")
        case .oauth(_, let label, _): return label.isEmpty ? String(localized: "OAuth") : label
        case .env: return String(localized: "Environment")
        case .command(_, let label, _): return label
        case .unsupported(let type): return type
        }
    }
}

extension OpenCodeV2IntegrationConnection {
    var removableCredentialID: String? {
        if case .credential(let id, _) = self { return id }
        return nil
    }
}

typealias OpenCodeV2IntegrationField = BackendFormField

struct OpenCodeV2OAuthAttempt: Decodable, Equatable, Sendable {
    enum Mode: String, Decodable, Sendable { case auto, code }
    struct Time: Decodable, Equatable, Sendable {
        let created: Double
        let expires: Double
        var expiration: Date { Date(timeIntervalSince1970: expires / 1_000) }
    }
    let attemptID: String
    let url: String
    let instructions: String
    let mode: Mode
    let time: Time

    var browserURL: URL? {
        guard let url = URL(string: url), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct OpenCodeV2OAuthStatus: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable { case pending, complete, failed, expired }
    let status: Status
    let time: OpenCodeV2OAuthAttempt.Time
    let message: String?
}

struct OpenCodeV2Plugin: Decodable, Equatable, Sendable {
    struct Source: Decodable, Equatable, Sendable {
        let type: String
        let target: String?
        let version: String?
        let path: String?
        let outdated: Bool?
        let updating: Bool?
    }
    struct State: Decodable, Equatable, Sendable {
        let status: String
        let error: String?
        let ref: String?
    }
    let id: String?
    let source: Source?
    let features: [String: Bool]?
    // next-17155 only supplies id. Absence is not evidence of successful activation.
    let state: State?

    var specifier: String { source?.target ?? source?.path ?? id ?? source?.type ?? "" }
}

extension OpenCodeJSONValue {
    var v2ConfigurationString: String? {
        if case .string(let value) = self { return value }
        return nil
    }
}

enum OpenCodeV2ConfigurationError: LocalizedError, Equatable {
    case unsupportedForm, invalidField(String), expired, requestFailed, invalidIdentifier

    var errorDescription: String? {
        switch self {
        case .unsupportedForm: return String(localized: "This authentication form is not supported in OpenClient. Use the OpenCode web app.")
        case .invalidField(let title): return String(localized: "Check the value for \(title).")
        case .expired: return String(localized: "This authorization attempt expired. Start a new connection.")
        case .requestFailed: return String(localized: "The provider request failed. Refresh connection status before trying again.")
        case .invalidIdentifier: return String(localized: "The server returned an invalid integration identifier.")
        }
    }
}
