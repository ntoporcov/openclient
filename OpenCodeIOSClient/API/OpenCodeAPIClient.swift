import Foundation

struct OpenCodeMessagePage: Sendable {
    let messages: [OpenCodeMessageEnvelope]
    let nextCursor: String?
}

// Transport contract: anomalyco/opencode@41cb354c3eac138959b1a6c4690385b7c3a6d666.
struct OpenCodeV2Health: Decodable, Equatable, Sendable {
    let healthy: Bool
    let version: String
    let pid: Int
}

private struct OpenCodeV2Info: Decodable, Sendable {
    let version: String
    let pid: Int
}

enum OpenCodeV2ProbeResult: Equatable, Sendable {
    case available(OpenCodeV2Health)
    case unavailable
}

struct OpenCodeV2ProjectBootstrap: Equatable, Sendable {
    let projects: [OpenCodeProject]
    let currentProject: OpenCodeProject?
    let selectedDirectory: String?
}

struct OpenCodeV2SessionPage: Equatable, Sendable {
    let sessions: [OpenCodeSession]
    let nextCursor: String?
}

struct OpenCodeV2MessagePage: Equatable, Sendable {
    let messages: [OpenCodeMessageEnvelope]
    let olderCursor: String?
}

struct OpenCodeV2PromptReceipt: Equatable, Sendable {
    let id: String
    let sessionID: String
    let timeCreated: Double
    let delivery: String
}

enum OpenCodeV2PendingInputEndpoint: String, Sendable {
    case inbox
    case pending
}

enum OpenCodeV2Contract: Equatable, Sendable {
    case preview17155
    case release
}

private struct OpenCodeV2Project: Decodable, Sendable {
    let id: String
    let canonical: String
    let vcs: String?
    let name: String?
    let icon: OpenCodeProject.Icon?
    let time: OpenCodeProject.Time?
    let sandboxes: [String]

    func normalized(primaryDirectory: String, directories: [String]) -> OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: primaryDirectory,
            vcs: vcs,
            name: name,
            sandboxes: directories.filter { $0 != primaryDirectory },
            icon: icon,
            time: time
        )
    }
}

struct OpenCodeV2Location: Decodable, Equatable, Sendable {
    struct Project: Decodable, Equatable, Sendable {
        let id: String
        let directory: String
        let canonical: String
    }

    let directory: String
    let workspaceID: String?
    let project: Project
}

private struct OpenCodeV2DataResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value
}

struct OpenCodeV2ResponseLocation: Decodable, Equatable, Sendable {
    let directory: String
}

private struct OpenCodeV2LocationResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let location: OpenCodeV2ResponseLocation
    let data: Value
}

enum OpenCodeV2TransportError: Error {
    case invalidPageLimit
    case invalidPermissionReply
    case invalidFormAnswer(String)
    case unsupportedFormField(String)
    case unsupportedCommandAdmission
    case unsupportedPausedCommand
    case unsupportedCommandSelection
    case invalidTimelineRecord
}

private struct OpenCodeV2Session: Decodable, Sendable {
    struct Location: Decodable, Sendable {
        let directory: String
        let workspaceID: String?
    }

    struct Time: Decodable, Sendable {
        let created: Double
        let updated: Double
        let archived: Double?
    }

    let id: String
    let projectID: String
    let parentID: String?
    let title: String?
    let location: Location
    let time: Time
    let agent: String?
    let model: OpenCodeV2ModelReference?

    func normalized() -> OpenCodeSession {
        var session = OpenCodeSession(
            id: id,
            title: title,
            workspaceID: location.workspaceID,
            directory: location.directory,
            projectID: projectID,
            parentID: parentID
        )
        session.time = OpenCodeMessageTime(created: time.created, updated: time.updated, archived: time.archived)
        session.agent = agent
        session.model = model.map { OpenCodeMessageModelReference(providerID: $0.providerID, modelID: $0.id, variant: $0.variant) }
        return session
    }
}

private struct OpenCodeV2SessionPageResponse: Decodable, Sendable {
    struct Cursor: Decodable, Sendable {
        let previous: String?
        let next: String?
    }

    let data: [OpenCodeV2Session]
    let cursor: Cursor?
}

private struct OpenCodeV2SessionResponse: Decodable, Sendable {
    let data: OpenCodeV2Session
}

private struct OpenCodeV2CreateSessionRequest: Encodable, Sendable {
    struct Location: Encodable, Sendable {
        let directory: String
        let workspaceID: String?
    }

    let title: String?
    let location: Location
    let agent: String?
    let model: OpenCodeV2ModelReference?
}

private struct OpenCodeV2ModelReference: Codable, Sendable {
    let providerID: String
    let id: String
    let variant: String?
}

private struct OpenCodeV2Agent: Decodable, Sendable {
    let id: String
    let description: String?
    let mode: String
    let hidden: Bool
    let model: OpenCodeV2ModelReference?

    func normalized() -> OpenCodeAgent {
        // Selections and prompt mentions use Agent.ID, not its display name.
        OpenCodeAgent(name: id, description: description, mode: mode, hidden: hidden,
                      model: model.map { .init(providerID: $0.providerID, modelID: $0.id) }, variant: model?.variant)
    }
}

private struct OpenCodeV2Command: Decodable, Sendable {
    let name: String
    let description: String?
    // The pinned contract only has name/description. next-17155 also returns these fields.
    let template: String?
    let agent: String?
    let model: OpenCodeV2ModelReference?
    let subtask: Bool?

    func normalized() -> OpenCodeCommand {
        OpenCodeCommand(
            name: name, description: description, agent: agent,
            model: model.map { "\($0.providerID)/\($0.id)" + ($0.variant.map { "#\($0)" } ?? "") },
            source: nil, template: template ?? "", subtask: subtask, hints: []
        )
    }
}

private struct OpenCodeV2Model: Decodable, Sendable {
    struct Time: Decodable, Sendable {
        let released: Double
    }

    struct Capabilities: Decodable, Sendable {
        let tools: Bool
        let input: [String]
        let output: [String]
    }
    let id: String
    let providerID: String
    let name: String
    let capabilities: Capabilities
    let variants: [[String: OpenCodeJSONValue]]
    let limit: OpenCodeModelLimit
    let family: String?
    let status: String
    let enabled: Bool
    let cost: [[String: OpenCodeJSONValue]]
    let time: Time?

    func normalized() -> OpenCodeModel {
        var variantsByID: [String: OpenCodeJSONValue] = [:]
        for variant in variants {
            if let id = variant.string("id") { variantsByID[id] = .object(variant) }
        }
        let baseCost = cost.first { $0["tier"] == nil }.flatMap {
            try? JSONDecoder().decode(OpenCodeModelCost.self, from: JSONEncoder().encode($0))
        }
        let releaseDate = time.map {
            Date(timeIntervalSince1970: $0.released / 1000)
                .ISO8601Format(.init(includingFractionalSeconds: true))
        }
        return OpenCodeModel(
            id: id, providerID: providerID, name: name,
            capabilities: .init(reasoning: capabilities.output.contains("reasoning"), attachment: capabilities.input.contains { $0 != "text" }, toolcall: capabilities.tools),
            variants: variantsByID, limit: limit, family: family, status: status,
            releaseDate: releaseDate, cost: baseCost, catalogVariantIDs: variantsByID.keys.sorted()
        )
    }
}

private struct OpenCodeV2Provider: Decodable, Sendable {
    let id: String
    let name: String
    let activation: String?
    // next-17155 predates activation and uses an optional disabled flag.
    let disabled: Bool?

    var isAvailable: Bool {
        activation.map { $0 != "disabled" } ?? (disabled != true)
    }
}

private struct OpenCodeV2FileEntry: Decodable, Sendable {
    let path: String
    let type: String

    func normalized(directory: String) -> OpenCodeFileNode {
        OpenCodeFileNode(name: URL(fileURLWithPath: path).lastPathComponent, path: path,
                         absolute: URL(fileURLWithPath: directory).appendingPathComponent(path).standardizedFileURL.path,
                         type: type, ignored: nil)
    }
}

private struct OpenCodeV2MessagePageResponse: Decodable, Sendable {
    struct Cursor: Decodable, Sendable {
        let previous: String?
        let next: String?
    }

    let data: [OpenCodeV2TimelineRecord]
    let cursor: Cursor?
}

private struct OpenCodeV2PromptRequest: Encodable, Sendable {
    struct File: Encodable, Sendable {
        let uri: String
        let name: String
    }

    struct Agent: Encodable, Sendable {
        struct Mention: Encodable, Sendable {
            let start: Int
            let end: Int
            let text: String
        }
        let name: String
        let mention: Mention
    }

    let id: String
    let text: String
    let resume: Bool
    let files: [File]?
    let agents: [Agent]?
}

private struct OpenCodeV2PromptResponse: Decodable, Sendable {
    struct Receipt: Decodable, Sendable {
        struct Time: Decodable, Sendable { let created: Double }

        let id: String
        let sessionID: String
        let delivery: String
        private let time: Time?
        private let timeCreated: Double?

        var created: Double? { time?.created ?? timeCreated }
    }

    let data: Receipt
}

private struct OpenCodeV2PermissionListResponse: Decodable, Sendable {
    struct Request: Decodable, Sendable {
        struct Source: Decodable, Sendable {
            let type: String
            let messageID: String?
            let id: String?
        }

        let id: String
        let sessionID: String
        let action: String
        let resources: [String]
        let save: [String]?
        let metadata: [String: OpenCodeJSONValue]?
        let source: Source?
        let message: String?

        func normalized() -> OpenCodePermission {
            var metadata = self.metadata
            if let message { metadata = (metadata ?? [:]).merging(["description": .string(message)]) { existing, _ in existing } }
            return OpenCodePermission(
                id: id,
                sessionID: sessionID,
                permission: action,
                patterns: resources,
                always: save,
                metadata: metadata,
                tool: source.map { OpenCodePermissionTool(messageID: $0.messageID, callID: $0.id, name: nil) }
            )
        }
    }

    let data: [Request]
}

// Preserve every field constraint for a native form UI. The question adapter below only
// represents required, unconditional scalar/multiselect fields without defaults.
struct OpenCodeV2Form: Decodable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let title: String
    let metadata: [String: OpenCodeJSONValue]?
    let fields: [[String: OpenCodeJSONValue]]
    let state: OpenCodeV2FormState?

    init(
        id: String, sessionID: String, title: String,
        metadata: [String: OpenCodeJSONValue]?, fields: [[String: OpenCodeJSONValue]],
        state: OpenCodeV2FormState? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.title = title
        self.metadata = metadata
        self.fields = fields
        self.state = state
    }

    var backendForm: BackendForm {
        .init(id: id, sessionID: sessionID, title: title, metadata: metadata, fields: fields.map(BackendFormField.init(raw:)))
    }

    func normalized() throws -> OpenCodeQuestionRequest {
        let questions = try fields.map { field -> OpenCodeQuestion in
            let type = field.string("type") ?? ""
            guard ["string", "multiselect", "number", "integer", "boolean"].contains(type),
                  field.boolean("required") == true,
                  field["default"] == nil,
                  (field.array("when") ?? []).isEmpty else {
                throw OpenCodeV2TransportError.unsupportedFormField(field.string("key") ?? type)
            }
            let options: [OpenCodeQuestionOption] = type == "boolean"
                ? [OpenCodeQuestionOption(label: "true", description: ""), OpenCodeQuestionOption(label: "false", description: "")]
                : (field.array("options") ?? []).compactMap { option in
                    guard let option = option.objectValue, let label = option.string("label") else { return nil }
                    return OpenCodeQuestionOption(label: label, description: option.string("description") ?? "")
                }
            guard Set(options.map(\.label)).count == options.count else {
                throw OpenCodeV2TransportError.unsupportedFormField(field.string("key") ?? type)
            }
            return OpenCodeQuestion(
                question: field.string("description") ?? field.string("title") ?? field.string("key") ?? title,
                header: field.string("title") ?? title,
                options: options,
                multiple: type == "multiselect",
                custom: type == "boolean" ? false : field.boolean("custom") ?? (type == "string" ? field["options"] == nil : type != "multiselect")
            )
        }
        return OpenCodeQuestionRequest(id: id, sessionID: sessionID, questions: questions, tool: nil)
    }

    func answer(from answers: [[String]]) throws -> [String: OpenCodeJSONValue] {
        _ = try normalized()
        guard answers.count == fields.count else { throw OpenCodeV2TransportError.invalidFormAnswer(id) }
        var result: [String: OpenCodeJSONValue] = [:]
        for (field, selections) in zip(fields, answers) {
            guard let key = field.string("key"), let type = field.string("type") else {
                throw OpenCodeV2TransportError.invalidFormAnswer(id)
            }
            guard !selections.isEmpty else { throw OpenCodeV2TransportError.invalidFormAnswer(key) }
            let options = (field.array("options") ?? []).compactMap(\.objectValue)
            let values = selections.map { selection in
                options.first { $0.string("label") == selection }?.string("value") ?? selection
            }
            if type == "multiselect" {
                result[key] = .array(values.map(OpenCodeJSONValue.string))
                continue
            }
            guard values.count == 1, let value = values.first else {
                throw OpenCodeV2TransportError.invalidFormAnswer(key)
            }
            switch type {
            case "boolean":
                guard let boolean = Bool(value) else { throw OpenCodeV2TransportError.invalidFormAnswer(key) }
                result[key] = .bool(boolean)
            default:
                result[key] = .string(value)
            }
        }
        do { return try backendForm.contract.answer(values: result).mapValues(\.jsonValue) }
        catch { throw OpenCodeV2TransportError.invalidFormAnswer(id) }
    }
}

enum OpenCodeV2FormState: Decodable, Equatable, Sendable {
    case pending, answered(BackendFormAnswer), cancelled

    private enum CodingKeys: CodingKey { case status, answer }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "pending": self = .pending
        case "answered": self = .answered(try container.decode(BackendFormAnswer.self, forKey: .answer))
        case "cancelled": self = .cancelled
        default: throw DecodingError.dataCorruptedError(forKey: .status, in: container, debugDescription: "Unknown form state")
        }
    }

    var status: String {
        switch self {
        case .pending: return "pending"
        case .answered: return "answered"
        case .cancelled: return "cancelled"
        }
    }

    var answer: [String: OpenCodeJSONValue]? {
        if case .answered(let answer) = self { return answer.mapValues(\.jsonValue) }
        return nil
    }

    var backendState: BackendFormState {
        switch self {
        case .pending: return .pending
        case .answered(let answer): return .answered(answer)
        case .cancelled: return .cancelled
        }
    }
}

private struct OpenCodeV2TimelineRecord: Decodable, Sendable {
    let value: [String: OpenCodeJSONValue]

    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode([String: OpenCodeJSONValue].self)
    }

    func normalized(sessionID: String) -> OpenCodeMessageEnvelope? {
        guard let id = value.string("id"), let type = value.string("type") else { return nil }
        let time = value.object("time")
        let created = time?.number("created")

        switch type {
        case "user":
            guard let text = value.string("text") else { return nil }
            var parts = [textPart(id: "\(id):v2:text:0", messageID: id, sessionID: sessionID, type: "text", text: text)]
            for (index, file) in (value.array("files") ?? []).compactMap(\.objectValue).enumerated() {
                // Projected files are materialized bytes, not PromptInput URI references.
                guard let data = file.string("data"), let mime = file.string("mime") else { return nil }
                let url = "data:\(mime);base64,\(data)"
                parts.append(
                    OpenCodePart(
                        id: "\(id):v2:file:\(index)",
                        messageID: id,
                        sessionID: sessionID,
                        type: "file",
                        mime: file.string("mime"),
                        filename: file.string("name"),
                        url: url,
                        reason: nil,
                        tool: nil,
                        callID: nil,
                        state: nil,
                        text: nil
                    )
                )
            }
            for (index, agent) in (value.array("agents") ?? []).compactMap(\.objectValue).enumerated() {
                guard let name = agent.string("name") else { continue }
                let mention = agent.object("mention")
                parts.append(OpenCodePart(
                    id: "\(id):v2:agent:\(index)", messageID: id, sessionID: sessionID,
                    type: "agent", mime: nil, filename: nil, name: name, url: nil,
                    source: mention.map {
                        OpenCodePartSource(value: $0.string("text"), start: $0.number("start").flatMap { Int(exactly: $0) },
                                           end: $0.number("end").flatMap { Int(exactly: $0) }, type: nil, text: nil, path: nil)
                    },
                    reason: nil, tool: nil, callID: nil, state: nil, text: nil
                ))
            }
            return envelope(id: id, role: "user", sessionID: sessionID, created: created, parts: parts)

        case "assistant":
            let modelObject = value.object("model")
            let model = modelObject.flatMap { model -> OpenCodeMessageModelReference? in
                guard let providerID = model.string("providerID"), let modelID = model.string("id") else { return nil }
                return OpenCodeMessageModelReference(providerID: providerID, modelID: modelID, variant: model.string("variant"))
            }
            var ordinals: [String: Int] = [:]
            let parts = (value.array("content") ?? []).compactMap { content -> OpenCodePart? in
                guard let type = content.objectValue?.string("type") else { return nil }
                let ordinal = ordinals[type, default: 0]
                ordinals[type] = ordinal + 1
                return projectedPart(content, index: ordinal, messageID: id, sessionID: sessionID)
            }
            guard parts.count == (value.array("content") ?? []).count else { return nil }
            let tokens = projectedTokens(value.object("tokens"))
            let error = projectedError(value.object("error"))
            return OpenCodeMessageEnvelope(
                info: OpenCodeMessage(
                    id: id,
                    role: "assistant",
                    sessionID: sessionID,
                    time: OpenCodeMessageTime(created: created, completed: time?.number("completed"), streamed: time?.number("streamed")),
                    agent: value.string("agent"),
                    model: model,
                    finish: value.string("finish"),
                    providerID: model?.providerID,
                    modelID: model?.modelID,
                    error: error,
                    cost: value.number("cost"),
                    tokens: tokens
                ),
                parts: parts
            )

        case "compaction":
            let summary = [value.string("summary"), value.string("recent")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            return OpenCodeMessageEnvelope(
                info: OpenCodeMessage(
                    id: id,
                    role: "assistant",
                    sessionID: sessionID,
                    time: OpenCodeMessageTime(created: created),
                    agent: "compaction",
                    model: nil,
                    mode: "compaction",
                    summary: true,
                    error: projectedError(value.object("error"))
                ),
                parts: [textPart(id: "\(id):v2:text:0", messageID: id, sessionID: sessionID, type: "text", text: summary)]
            )

        case "shell":
            let state = OpenCodeToolState(
                status: value.string("status") == "running" ? "running" : (value.string("status") == "exited" && value.number("exit") == 0 ? "completed" : "error"),
                title: value.string("command"),
                error: nil,
                input: OpenCodeToolInput(
                    command: value.string("command"),
                    description: nil,
                    filePath: nil,
                    name: nil,
                    path: nil,
                    query: nil,
                    pattern: nil,
                    subagentType: nil,
                    url: nil
                ),
                output: value.object("output")?.string("output"),
                metadata: nil
            )
            let part = OpenCodePart(
                id: value.string("shellID") ?? "\(id):shell",
                messageID: id,
                sessionID: sessionID,
                type: "tool",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: "shell",
                callID: value.string("shellID"),
                state: state,
                text: nil
            )
            return envelope(id: id, role: "assistant", sessionID: sessionID, created: created, completed: time?.number("completed"), parts: [part])

        case "synthetic", "system", "skill", "agent-switched", "model-switched", "location-switched":
            let text = value.string("text")
                ?? value.string("description")
                ?? value.string("name")
                ?? value.string("agent")
                ?? value.object("model")?.string("id")
                ?? value.object("location")?.string("directory")
            guard let text else { return nil }
            let part = textPart(id: "\(id):v2:text:0", messageID: id, sessionID: sessionID, type: type, text: text, synthetic: true)
            return envelope(
                id: id,
                role: "assistant",
                sessionID: sessionID,
                created: created,
                parts: [part]
            )
        default:
            return nil
        }
    }

    var isDisplayableType: Bool {
        guard let type = value.string("type") else { return false }
        return ["user", "assistant", "compaction", "shell", "synthetic", "system", "skill",
                "agent-switched", "model-switched", "location-switched"].contains(type)
    }

    var hasType: Bool { value.string("type") != nil }

    private func projectedPart(
        _ value: OpenCodeJSONValue,
        index: Int,
        messageID: String,
        sessionID: String
    ) -> OpenCodePart? {
        guard let content = value.objectValue, let type = content.string("type") else { return nil }
        if type == "text" || type == "reasoning" {
            guard let text = content.string("text") else { return nil }
            let time = content.object("time")
            return textPart(
                id: "\(messageID):v2:\(type):\(index)",
                messageID: messageID,
                sessionID: sessionID,
                type: type,
                text: text,
                time: time?.number("created").map { OpenCodePartTime(start: $0, end: time?.number("completed")) }
            )
        }
        guard type == "tool", let toolID = content.string("id") else { return nil }
        let stateObject = content.object("state") ?? [:]
        let inputObject = stateObject.object("input")
        let output = (stateObject.array("content") ?? []).compactMap { item -> String? in
            guard let item = item.objectValue else { return nil }
            if item.string("type") == "text" { return item.string("text") }
            if item.string("type") == "file" { return item.string("name") ?? item.string("uri") }
            return nil
        }.joined(separator: "\n")
        let error = stateObject.object("error")?.string("message")
        let input = inputObject.map {
            OpenCodeToolInput(
                command: $0.string("command"),
                description: $0.string("description"),
                filePath: $0.string("filePath"),
                name: $0.string("name"),
                path: $0.string("path"),
                query: $0.string("query"),
                pattern: $0.string("pattern"),
                subagentType: $0.string("subagent_type"),
                url: $0.string("url"),
                clientID: $0.string("client_id"),
                toolID: $0.string("tool_id"),
                arguments: $0
            )
        }
        var metadataObject = stateObject.object("metadata") ?? [:]
        let files = (stateObject.array("content") ?? []).filter { $0.objectValue?.string("type") == "file" }
        if !files.isEmpty { metadataObject["files"] = .array(files) }
        let metadata = try? JSONDecoder().decode(OpenCodeToolMetadata.self, from: JSONEncoder().encode(metadataObject))
        let state = OpenCodeToolState(
            status: stateObject.string("status") == "streaming" ? "pending" : stateObject.string("status"),
            title: content.string("name"),
            error: error,
            input: input,
            output: output.isEmpty ? nil : output,
            metadata: metadata,
            raw: stateObject.string("input")
        )
        return OpenCodePart(
            id: toolID,
            messageID: messageID,
            sessionID: sessionID,
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: content.string("name"),
            callID: toolID,
            state: state,
            text: nil
        )
    }

    private func projectedTokens(_ value: [String: OpenCodeJSONValue]?) -> OpenCodeMessageTokens? {
        guard let value else { return nil }
        let cache = value.object("cache")
        return OpenCodeMessageTokens(
            input: Int(exactly: (value.number("input") ?? 0).rounded(.towardZero)) ?? 0,
            output: Int(exactly: (value.number("output") ?? 0).rounded(.towardZero)) ?? 0,
            reasoning: Int(exactly: (value.number("reasoning") ?? 0).rounded(.towardZero)) ?? 0,
            cache: OpenCodeMessageTokenCache(
                read: Int(exactly: (cache?.number("read") ?? 0).rounded(.towardZero)) ?? 0,
                write: Int(exactly: (cache?.number("write") ?? 0).rounded(.towardZero)) ?? 0
            )
        )
    }

    private func projectedError(_ value: [String: OpenCodeJSONValue]?) -> OpenCodeSessionErrorPayload? {
        guard let value else { return nil }
        return OpenCodeSessionErrorPayload(
            name: value.string("type"),
            data: OpenCodeSessionErrorData(message: value.string("message"))
        )
    }

    private func envelope(
        id: String,
        role: String,
        sessionID: String,
        created: Double?,
        completed: Double? = nil,
        parts: [OpenCodePart]
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: OpenCodeMessageTime(created: created, completed: completed),
                agent: nil,
                model: nil
            ),
            parts: parts
        )
    }

    private func textPart(
        id: String,
        messageID: String,
        sessionID: String,
        type: String,
        text: String,
        time: OpenCodePartTime? = nil,
        synthetic: Bool? = nil
    ) -> OpenCodePart {
        OpenCodePart(
            id: id,
            messageID: messageID,
            sessionID: sessionID,
            type: type,
            mime: nil,
            filename: nil,
            url: nil,
            reason: type == "reasoning" ? "reasoning" : nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: text,
            synthetic: synthetic,
            time: time
        )
    }
}

private extension Dictionary where Key == String, Value == OpenCodeJSONValue {
    func boolean(_ key: String) -> Bool? {
        guard case let .bool(value) = self[key] else { return nil }
        return value
    }
    func string(_ key: String) -> String? { self[key]?.literalStringValue }
    func number(_ key: String) -> Double? { self[key]?.doubleValue }
    func object(_ key: String) -> [String: OpenCodeJSONValue]? { self[key]?.objectValue }
    func array(_ key: String) -> [OpenCodeJSONValue]? { self[key]?.arrayValue }
}

struct OpenCodeAPIClient: Sendable {
    let config: OpenCodeServerConfig
    var session: URLSession = .shared
    var v2Contract: OpenCodeV2Contract = .release

    func health() async throws -> HealthResponse {
        try await send(path: "/global/health", method: "GET")
    }

    func probeV2() async throws -> OpenCodeV2ProbeResult {
        let request = try makeRequest(path: "/api/health", method: "GET", queryItems: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: request, body: data)

        if http.statusCode == 404 || http.statusCode == 405 {
            return try await probeV2Info()
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let body = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if contentType.contains("text/html") || body.hasPrefix("<!doctype html") || body.hasPrefix("<html") {
            return try await probeV2Info()
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["healthy"] as? Bool == true, object["version"] == nil, object["pid"] == nil {
            return .unavailable
        }
        let health = try JSONDecoder().decode(OpenCodeV2Health.self, from: data)
        guard health.healthy, health.pid >= 0 else {
            throw OpenCodeAPIError.invalidResponse
        }
        return .available(health)
    }

    private func probeV2Info() async throws -> OpenCodeV2ProbeResult {
        let request = try makeRequest(path: "/api/info", method: "GET", queryItems: [])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeAPIError.invalidResponse }
        debugLog(response: http, for: request, body: data)
        if http.statusCode == 404 || http.statusCode == 405 { return .unavailable }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if contentType.contains("text/html") || body.hasPrefix("<!doctype html") || body.hasPrefix("<html") {
            return .unavailable
        }
        let info = try JSONDecoder().decode(OpenCodeV2Info.self, from: data)
        guard !info.version.isEmpty, info.pid >= 0 else { throw OpenCodeAPIError.invalidResponse }
        return .available(OpenCodeV2Health(healthy: true, version: info.version, pid: info.pid))
    }

    func bootstrapV2Projects() async throws -> OpenCodeV2ProjectBootstrap {
        // Resolve first: location discovery can register the current project before listing it.
        let location = try await getV2Location()
        let listed: [OpenCodeV2Project] = try await send(path: "/api/project", method: "GET")
        var resolvedProjects = listed.map { project in
            project.normalized(
                primaryDirectory: project.id == location.project.id ? location.project.directory : project.canonical,
                directories: project.sandboxes
            )
        }
        if !resolvedProjects.contains(where: { $0.id == location.project.id }) {
            resolvedProjects.append(OpenCodeProject(id: location.project.id, worktree: location.project.directory, vcs: nil, name: nil, sandboxes: [], icon: nil, time: nil))
        }
        let selected = resolvedProjects.first { $0.id == location.project.id }
        return OpenCodeV2ProjectBootstrap(
            projects: resolvedProjects,
            currentProject: selected,
            selectedDirectory: location.directory
        )
    }

    func getV2Location(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeV2Location {
        try await send(path: "/api/location", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
    }

    func currentV2Project(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeProject {
        let location = try await getV2Location(directory: directory, workspaceID: workspaceID)
        return try await project(for: location)
    }

    func project(for location: OpenCodeV2Location) async throws -> OpenCodeProject {
        let projects: [OpenCodeV2Project] = try await send(path: "/api/project", method: "GET")
        if let project = projects.first(where: { $0.id == location.project.id }) {
            return project.normalized(primaryDirectory: location.project.directory, directories: project.sandboxes)
        }
        return OpenCodeProject(id: location.project.id, worktree: location.project.directory, vcs: nil, name: nil, sandboxes: [], icon: nil, time: nil)
    }

    func updateV2Project(projectID: String, directory: String? = nil, name: String? = nil, icon: OpenCodeProject.Icon? = nil) async throws -> OpenCodeProject {
        let project: OpenCodeV2Project = try await send(path: "/api/project/\(projectID)", method: "PATCH", body: UpdateProjectRequest(name: name, icon: icon))
        return project.normalized(primaryDirectory: directory ?? project.canonical, directories: project.sandboxes)
    }

    func getV2Session(sessionID: String) async throws -> OpenCodeSession {
        let response: OpenCodeV2SessionResponse = try await send(path: "/api/session/\(sessionID)", method: "GET")
        return response.data.normalized()
    }

    func deleteV2Session(sessionID: String) async throws {
        try await sendNoContent(path: "/api/session/\(sessionID)", method: "DELETE")
    }

    func updateV2SessionTitle(sessionID: String, title: String) async throws -> OpenCodeSession {
        struct Rename: Encodable { let title: String }
        let path = v2Contract == .preview17155
            ? "/api/session/\(sessionID)/rename"
            : "/api/session/\(sessionID)"
        try await sendNoContent(path: path, method: v2Contract == .preview17155 ? "POST" : "PATCH", body: Rename(title: title))
        return try await getV2Session(sessionID: sessionID)
    }

    func forkV2Session(sessionID: String, messageID: String? = nil) async throws -> OpenCodeSession {
        let response: OpenCodeV2SessionResponse
        if v2Contract == .preview17155 {
            struct Fork: Encodable {
                struct Boundary: Encodable { let type: String; let messageID: String? }
                let boundary: Boundary
            }
            response = try await send(path: "/api/session/\(sessionID)/fork", method: "POST",
                body: Fork(boundary: .init(type: messageID == nil ? "through" : "before", messageID: messageID)))
        } else {
            struct Fork: Encodable { let before: String? }
            response = try await send(path: "/api/session/\(sessionID)/fork", method: "POST", body: Fork(before: messageID))
        }
        return response.data.normalized()
    }

    func switchV2SessionAgent(sessionID: String, agent: String) async throws {
        struct Selection: Encodable { let agent: String }
        try await sendNoContent(path: "/api/session/\(sessionID)/agent", method: "POST", body: Selection(agent: agent))
    }

    func switchV2SessionModel(sessionID: String, model: OpenCodeModelReference, variant: String? = nil) async throws {
        struct Selection: Encodable { let model: OpenCodeV2ModelReference }
        try await sendNoContent(path: "/api/session/\(sessionID)/model", method: "POST", body: Selection(model: .init(providerID: model.providerID, id: model.modelID, variant: variant)))
    }

    func listV2SessionStatuses() async throws -> [String: String] {
        let response: OpenCodeV2DataResponse<[String: OpenCodeSessionStatus]> = try await send(path: "/api/session/active", method: "GET")
        return response.data.mapValues { $0.type == "running" ? "busy" : $0.type }
    }

    func getV2Message(sessionID: String, messageID: String) async throws -> OpenCodeMessageEnvelope {
        let response: OpenCodeV2DataResponse<OpenCodeV2TimelineRecord> = try await send(path: "/api/session/\(sessionID)/message/\(messageID)", method: "GET")
        guard let message = response.data.normalized(sessionID: sessionID) else { throw OpenCodeV2TransportError.invalidTimelineRecord }
        return message
    }

    // Select from a verified server contract: pinned upstream uses inbox; next-17155
    // uses pending. Never reinterpret a failed request as an empty queue or try another route.
    func listV2PendingInputIDs(sessionID: String, endpoint: OpenCodeV2PendingInputEndpoint) async throws -> Set<String> {
        struct Input: Decodable, Sendable { let id: String }
        let response: OpenCodeV2DataResponse<[Input]> = try await send(path: "/api/session/\(sessionID)/\(endpoint.rawValue)", method: "GET")
        return Set(response.data.map(\.id))
    }

    func compactV2Session(sessionID: String) async throws {
        if v2Contract == .preview17155 {
            try await sendNoContent(path: "/api/session/\(sessionID)/compact", method: "POST", body: [String: String]())
            return
        }
        struct Compact: Encodable { let id: String; let delivery: String }
        let id = OpenCodeIdentifier.message()
        let response: OpenCodeV2PromptResponse = try await send(
            path: "/api/session/\(sessionID)/compact", method: "POST",
            body: Compact(id: id, delivery: "steer")
        )
        guard response.data.id == id, response.data.sessionID == sessionID else {
            throw OpenCodeAPIError.invalidResponse
        }
    }

    func sendV2Command(sessionID: String, command: String, arguments: String = "", attachments: [OpenCodeComposerAttachment] = []) async throws {
        if v2Contract == .preview17155 {
            let messageID = OpenCodeIdentifier.message()
            let receipt = try await admitV2Command(sessionID: sessionID, messageID: messageID, command: command,
                arguments: arguments, attachments: attachments)
            guard receipt.id == messageID, receipt.sessionID == sessionID else { throw OpenCodeAPIError.invalidResponse }
            return
        }
        struct Command: Encodable {
            let name: String
            let text: String
            let files: [OpenCodeV2PromptRequest.File]?
        }
        try await sendNoContent(
            path: "/api/session/\(sessionID)/command", method: "POST",
            body: Command(name: command, text: arguments,
                files: attachments.isEmpty ? nil : attachments.map { .init(uri: $0.dataURL, name: $0.filename) })
        )
    }

    func admitV2Command(
        sessionID: String, messageID: String, command: String, arguments: String = "",
        agent: String? = nil, model: OpenCodeModelReference? = nil, variant: String? = nil,
        attachments: [OpenCodeComposerAttachment] = [], resume: Bool = true
    ) async throws -> OpenCodeV2PromptReceipt {
        if v2Contract == .preview17155 {
            struct Command: Encodable {
                let id: String
                let command: String
                let arguments: String
                let agent: String?
                let model: OpenCodeV2ModelReference?
                let files: [OpenCodeV2PromptRequest.File]?
                let resume: Bool
            }
            let response: OpenCodeV2PromptResponse = try await send(
                path: "/api/session/\(sessionID)/command", method: "POST",
                body: Command(id: messageID, command: command, arguments: arguments, agent: agent,
                    model: model.map { .init(providerID: $0.providerID, id: $0.modelID, variant: variant) },
                    files: attachments.isEmpty ? nil : attachments.map { .init(uri: $0.dataURL, name: $0.filename) },
                    resume: resume)
            )
            guard let created = response.data.created else { throw OpenCodeAPIError.invalidResponse }
            return .init(id: response.data.id, sessionID: response.data.sessionID,
                timeCreated: created, delivery: response.data.delivery)
        }
        guard resume else { throw OpenCodeV2TransportError.unsupportedPausedCommand }
        guard agent == nil, model == nil, variant == nil else {
            throw OpenCodeV2TransportError.unsupportedCommandSelection
        }
        _ = (sessionID, messageID, command, arguments, attachments)
        throw OpenCodeV2TransportError.unsupportedCommandAdmission
    }

    func listV2Commands(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeCommand] {
        let response: OpenCodeV2DataResponse<[OpenCodeV2Command]> = try await send(path: "/api/command", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data.map { $0.normalized() }
    }

    func listV2Agents(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeAgent] {
        let response: OpenCodeV2DataResponse<[OpenCodeV2Agent]> = try await send(path: "/api/agent", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data.map { $0.normalized() }
    }

    func listV2Providers(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeProvider] {
        let query = v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
        async let providers: OpenCodeV2DataResponse<[OpenCodeV2Provider]> = send(path: "/api/provider", method: "GET", queryItems: query)
        async let models: OpenCodeV2DataResponse<[OpenCodeV2Model]> = send(path: "/api/model", method: "GET", queryItems: query)
        let (providerResponse, modelResponse) = try await (providers, models)
        return providerResponse.data.filter(\.isAvailable).map { provider in
            var modelsByID: [String: OpenCodeModel] = [:]
            for model in modelResponse.data where model.providerID == provider.id && model.enabled {
                modelsByID[model.id] = model.normalized()
            }
            return OpenCodeProvider(id: provider.id, name: provider.name, models: modelsByID)
        }
    }

    func defaultV2Model(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeModel? {
        struct Response: Decodable { let data: OpenCodeV2Model? }
        let response: Response = try await send(path: "/api/model/default", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data?.normalized()
    }

    func listV2ConfigurationEntries(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeJSONValue] {
        try await send(path: "/api/config", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
    }

    func listV2Files(directory: String, path: String = "", workspaceID: String? = nil) async throws -> [OpenCodeFileNode] {
        let response: OpenCodeV2LocationResponse<[OpenCodeV2FileEntry]> = try await send(path: "/api/fs/list", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID) + [URLQueryItem(name: "path", value: path)])
        return response.data.map { $0.normalized(directory: response.location.directory) }
    }

    func findV2Files(query: String, directory: String, workspaceID: String? = nil) async throws -> [String] {
        let response: OpenCodeV2DataResponse<[OpenCodeV2FileEntry]> = try await send(path: "/api/fs/find", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID) + [URLQueryItem(name: "query", value: query), URLQueryItem(name: "type", value: "file")])
        return response.data.map(\.path)
    }

    func readV2FileContent(directory: String, path: String, workspaceID: String? = nil) async throws -> OpenCodeFileContent {
        var request = try makeRequest(path: "/api/fs/read/\(path)", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeAPIError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let mime = http.mimeType
        if mime?.hasPrefix("image/") != true, let text = String(data: data, encoding: .utf8) {
            return OpenCodeFileContent(type: "text", content: text, diff: nil, encoding: nil, mimeType: mime)
        }
        return OpenCodeFileContent(type: "binary", content: data.base64EncodedString(), diff: nil, encoding: "base64", mimeType: mime)
    }

    func getV2VCSInfo(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeVCSInfo {
        struct Info: Decodable, Sendable {
            struct Branch: Decodable, Sendable { let current: String?; let `default`: String? }
            let branch: Branch
        }
        let response: OpenCodeV2DataResponse<Info> = try await send(path: "/api/vcs", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return OpenCodeVCSInfo(branch: response.data.branch.current, defaultBranch: response.data.branch.default)
    }

    func listV2FileStatus(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeVCSFileStatus] {
        struct Status: Decodable, Sendable {
            let file: String
            let additions: Int
            let deletions: Int
            let status: String
        }
        let response: OpenCodeV2DataResponse<[Status]> = try await send(path: "/api/vcs/status", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data.map { OpenCodeVCSFileStatus(path: $0.file, added: $0.additions, removed: $0.deletions, status: $0.status) }
    }

    func getV2VCSDiff(mode: OpenCodeVCSDiffMode, directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeVCSFileDiff] {
        let response: OpenCodeV2DataResponse<[OpenCodeVCSFileDiff]> = try await send(path: "/api/vcs/diff", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID) + [URLQueryItem(name: "mode", value: mode == .git ? "working" : "branch")])
        return response.data
    }

    func listV2MCPStatus(directory: String? = nil, workspaceID: String? = nil) async throws -> [String: OpenCodeMCPStatus] {
        struct Server: Decodable, Sendable { let name: String; let status: OpenCodeMCPStatus }
        let response: OpenCodeV2DataResponse<[Server]> = try await send(path: "/api/mcp", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        var statuses: [String: OpenCodeMCPStatus] = [:]
        for server in response.data { statuses[server.name] = server.status }
        return statuses
    }

    func connectV2MCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/api/mcp/\(encodedPathComponent(name))/connect", method: "POST", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: nil)
    }

    func disconnectV2MCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/api/mcp/\(encodedPathComponent(name))/disconnect", method: "POST", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: nil)
    }

    func listV2SessionPermissions(sessionID: String) async throws -> [OpenCodePermission] {
        let response: OpenCodeV2PermissionListResponse = try await send(path: "/api/session/\(sessionID)/permission", method: "GET")
        return response.data.map { $0.normalized() }
    }

    func listV2SessionForms(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeV2Form] {
        let response: OpenCodeV2DataResponse<[OpenCodeV2Form]> = try await send(path: "/api/session/\(sessionID)/form", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data
    }

    func listV2Sessions(
        projectID: String,
        directory: String?,
        cursor: String? = nil,
        limit: Int = 50,
        workspaceID: String? = nil,
        roots: Bool = true
    ) async throws -> OpenCodeV2SessionPage {
        guard limit > 0 else { throw OpenCodeV2TransportError.invalidPageLimit }
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.insert(URLQueryItem(name: "cursor", value: cursor), at: 0)
        } else {
            queryItems.insert(contentsOf: [
                URLQueryItem(name: "order", value: "desc"),
            ], at: 0)
            if let directory, !directory.isEmpty {
                queryItems.insert(URLQueryItem(name: "directory", value: directory), at: 0)
            } else {
                queryItems.insert(URLQueryItem(name: "project", value: projectID), at: 0)
            }
            if roots {
                queryItems.insert(URLQueryItem(name: "parentID", value: "null"), at: 1)
            }
            if let workspaceID, !workspaceID.isEmpty {
                queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
            }
        }

        let response: OpenCodeV2SessionPageResponse = try await send(
            path: "/api/session",
            method: "GET",
            queryItems: queryItems
        )
        // Session.list applies all filters before SQL LIMIT. next-17155 nevertheless
        // emits cursors on terminal pages, so only full pages need an existence check.
        var nextCursor = response.data.count < limit || response.cursor?.next == cursor ? nil : response.cursor?.next
        if response.data.count == limit, let next = nextCursor {
            do {
                try Task.checkCancellation()
                let probe: OpenCodeV2SessionPageResponse = try await send(
                    path: "/api/session",
                    method: "GET",
                    queryItems: [
                        URLQueryItem(name: "cursor", value: next),
                        URLQueryItem(name: "limit", value: "1"),
                    ]
                )
                if probe.data.isEmpty { nextCursor = nil }
                // Keep the original boundary and its server-owned filters; consume no probe rows.
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                #if DEBUG
                print("[OpenCodeResponse] session list lookahead failed; preserving continuation")
                #endif
            }
        }
        try Task.checkCancellation()
        return OpenCodeV2SessionPage(sessions: response.data.map { $0.normalized() }, nextCursor: nextCursor)
    }

    func createV2Session(title: String?, directory: String, workspaceID: String? = nil, agent: String? = nil, model: OpenCodeModelReference? = nil, variant: String? = nil) async throws -> OpenCodeSession {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = OpenCodeV2CreateSessionRequest(
            title: trimmedTitle?.isEmpty == false ? trimmedTitle : nil,
            location: .init(directory: directory, workspaceID: workspaceID),
            agent: agent,
            model: model.map { OpenCodeV2ModelReference(providerID: $0.providerID, id: $0.modelID, variant: variant) }
        )
        let response: OpenCodeV2SessionResponse = try await send(path: "/api/session", method: "POST", body: request)
        return response.data.normalized()
    }

    func listV2Messages(
        sessionID: String,
        cursor: String? = nil,
        limit: Int = 200
    ) async throws -> OpenCodeV2MessagePage {
        guard (1 ... 200).contains(limit) else { throw OpenCodeV2TransportError.invalidPageLimit }
        let queryItems: [URLQueryItem]
        if let cursor {
            queryItems = [
                URLQueryItem(name: "cursor", value: cursor),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        } else {
            queryItems = [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        }
        let response: OpenCodeV2MessagePageResponse = try await send(
            path: "/api/session/\(sessionID)/message",
            method: "GET",
            queryItems: queryItems
        )
        let messages: [OpenCodeMessageEnvelope] = try response.data.reversed().compactMap { record -> OpenCodeMessageEnvelope? in
            guard record.hasType else { throw OpenCodeV2TransportError.invalidTimelineRecord }
            guard record.isDisplayableType else { return nil }
            guard let message = record.normalized(sessionID: sessionID) else {
                throw OpenCodeV2TransportError.invalidTimelineRecord
            }
            return message
        }
        // next-17155 applies the SQL limit without filtering, but emits cursors even
        // on terminal pages. Only a full page needs a bounded existence check.
        var olderCursor = response.data.count < limit || response.cursor?.next == cursor ? nil : response.cursor?.next
        if response.data.count == limit, let next = olderCursor {
            do {
                try Task.checkCancellation()
                let probe: OpenCodeV2MessagePageResponse = try await send(
                    path: "/api/session/\(sessionID)/message",
                    method: "GET",
                    queryItems: [
                        URLQueryItem(name: "cursor", value: next),
                        URLQueryItem(name: "limit", value: "1"),
                    ]
                )
                if probe.data.isEmpty { olderCursor = nil }
                // Do not consume the probe row or advance the original page boundary.
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                #if DEBUG
                print("[OpenCodeResponse] message history lookahead failed; preserving continuation")
                #endif
            }
        }
        try Task.checkCancellation()
        return OpenCodeV2MessagePage(messages: messages, olderCursor: olderCursor)
    }

    func admitV2TextPrompt(sessionID: String, messageID: String, text: String, attachments: [OpenCodeComposerAttachment] = [], agentMentions: [OpenCodeAgentMention] = [], resume: Bool = true) async throws -> OpenCodeV2PromptReceipt {
        let response: OpenCodeV2PromptResponse = try await send(
            path: "/api/session/\(sessionID)/prompt",
            method: "POST",
            body: OpenCodeV2PromptRequest(
                id: messageID, text: text, resume: resume,
                files: attachments.isEmpty ? nil : attachments.map { .init(uri: $0.dataURL, name: $0.filename) },
                agents: agentMentions.isEmpty ? nil : agentMentions.map {
                    .init(name: $0.name, mention: .init(start: $0.start, end: $0.end, text: $0.content))
                }
            )
        )
        guard let created = response.data.created else { throw OpenCodeAPIError.invalidResponse }
        return OpenCodeV2PromptReceipt(
            id: response.data.id,
            sessionID: response.data.sessionID,
            timeCreated: created,
            delivery: response.data.delivery
        )
    }

    func waitForV2Session(sessionID: String) async throws {
        let prefix = v2Contract == .preview17155 ? "/api/session" : "/api/experimental/session"
        try await sendNoContent(path: "\(prefix)/\(sessionID)/wait", method: "POST")
    }

    func interruptV2Session(sessionID: String) async throws {
        try await sendNoContent(path: "/api/session/\(sessionID)/interrupt", method: "POST")
    }

    func listV2PendingPermissions(directory: String?, workspaceID: String? = nil) async throws -> [OpenCodePermission] {
        let response: OpenCodeV2PermissionListResponse = try await send(
            path: "/api/permission/request",
            method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
        )
        return response.data.map { $0.normalized() }
    }

    func listV2PendingForms(directory: String?, workspaceID: String? = nil) async throws -> [OpenCodeV2Form] {
        let response = try await listV2FormInventory(directory: directory, workspaceID: workspaceID)
        return response.data
    }

    func listV2GlobalForms(directory: String?, workspaceID: String? = nil) async throws -> BackendGlobalFormInventory {
        let response = try await listV2FormInventory(directory: directory, workspaceID: workspaceID)
        return .init(location: .init(directory: response.location.directory, workspaceID: nil),
                     forms: response.data.filter { $0.sessionID == "global" }.map(\.backendForm))
    }

    private func listV2FormInventory(directory: String?, workspaceID: String?) async throws -> OpenCodeV2LocationResponse<[OpenCodeV2Form]> {
        let queryItems = v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
        do {
            return try await send(path: "/api/form", method: "GET", queryItems: queryItems)
        } catch let OpenCodeAPIError.httpError(status, _) where status == 404 || status == 405 {
            return try await send(path: "/api/form/request", method: "GET", queryItems: queryItems)
        }
    }

    func listV2PendingQuestions(directory: String?, workspaceID: String? = nil) async throws -> [OpenCodeQuestionRequest] {
        try await listV2PendingForms(directory: directory, workspaceID: workspaceID).map { try $0.normalized() }
    }

    func replyToV2Permission(sessionID: String, requestID: String, reply: String, message: String? = nil) async throws {
        guard ["once", "always", "reject"].contains(reply) else { throw OpenCodeV2TransportError.invalidPermissionReply }
        let path = "/api/session/\(sessionID)/permission/\(requestID)/reply"
        if v2Contract == .preview17155 {
            try await sendNoContent(path: path, method: "POST", body: OpenCodePermissionReplyRequest(reply: reply, message: message))
        } else {
            struct Decision: Encodable { let decision: String; let message: String? }
            try await sendNoContent(path: path, method: "POST", body: Decision(decision: reply, message: message))
        }
    }

    func replyToV2Question(sessionID: String, requestID: String, answers: [[String]]) async throws {
        let form = try await getV2Form(sessionID: sessionID, formID: requestID)
        try await replyToV2Form(sessionID: sessionID, formID: requestID, answer: form.answer(from: answers))
    }

    func getV2Form(sessionID: String, formID: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeV2Form {
        let response: OpenCodeV2DataResponse<OpenCodeV2Form> = try await send(path: "/api/session/\(sessionID)/form/\(formID)", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data
    }

    func createV2Form(sessionID: String, title: String, fields: [[String: OpenCodeJSONValue]], metadata: [String: OpenCodeJSONValue]? = nil) async throws -> OpenCodeV2Form {
        struct Create: Encodable {
            let title: String
            let fields: [[String: OpenCodeJSONValue]]
            let metadata: [String: OpenCodeJSONValue]?
        }
        let response: OpenCodeV2DataResponse<OpenCodeV2Form> = try await send(path: "/api/session/\(sessionID)/form", method: "POST", body: Create(title: title, fields: fields, metadata: metadata))
        return response.data
    }

    func getV2FormState(sessionID: String, formID: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeV2FormState {
        let form = try await getV2Form(sessionID: sessionID, formID: formID, directory: directory, workspaceID: workspaceID)
        if let state = form.state { return state }
        let response: OpenCodeV2DataResponse<OpenCodeV2FormState> = try await send(
            path: "/api/session/\(sessionID)/form/\(formID)/state", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data
    }

    func replyToV2Form(sessionID: String, formID: String, answer: [String: OpenCodeJSONValue], directory: String? = nil, workspaceID: String? = nil) async throws {
        struct Reply: Encodable { let answer: [String: OpenCodeJSONValue] }
        for (key, value) in answer {
            do { _ = try BackendFormValue(jsonValue: value) }
            catch { throw OpenCodeV2TransportError.invalidFormAnswer(key) }
        }
        try await sendNoContent(
            path: "/api/session/\(sessionID)/form/\(formID)/reply",
            method: "POST",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID),
            body: Reply(answer: answer)
        )
    }

    func rejectV2Question(sessionID: String, requestID: String) async throws {
        try await cancelV2Form(sessionID: sessionID, formID: requestID)
    }

    func cancelV2Form(sessionID: String, formID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        let suffix = v2Contract == .preview17155 ? "/cancel" : ""
        try await sendNoContent(path: "/api/session/\(sessionID)/form/\(formID)\(suffix)",
            method: v2Contract == .preview17155 ? "POST" : "DELETE",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: nil)
    }

    func v2LocationQueryItems(directory: String?, workspaceID: String? = nil) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let directory, !directory.isEmpty { items.append(URLQueryItem(name: "location[directory]", value: directory)) }
        if v2Contract == .preview17155, let workspaceID, !workspaceID.isEmpty {
            items.append(URLQueryItem(name: "location[workspace]", value: workspaceID))
        }
        return items
    }

    func v2EventURL() -> URL? {
        resolvedURL(path: "/api/event", queryItems: [])
    }

    func listPTYs(
        directory: String,
        workspaceID: String? = nil
    ) async throws -> [OpenCodePTY] {
        try await send(
            path: "/pty",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func createPTY(
        title: String? = nil,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await createPTY(
            request: OpenCodePTYCreateRequest(title: title),
            directory: directory,
            workspaceID: workspaceID
        )
    }

    func createPTY(
        request: OpenCodePTYCreateRequest,
        directory: String?,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: request,
            directoryHeader: directory
        )
    }

    func getPTY(
        id: String,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty/\(id)",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func updatePTY(
        id: String,
        title: String? = nil,
        rows: Int? = nil,
        columns: Int? = nil,
        directory: String,
        workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        try await send(
            path: "/pty/\(id)",
            method: "PUT",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: OpenCodePTYUpdateRequest(title: title, rows: rows, columns: columns),
            directoryHeader: directory
        )
    }

    func deletePTY(
        id: String,
        directory: String?,
        workspaceID: String? = nil
    ) async throws {
        try await sendNoContent(
            path: "/pty/\(id)",
            method: "DELETE",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func ptyConnectRequest(
        id: String,
        directory: String?,
        workspaceID: String? = nil,
        cursor: Int
    ) throws -> URLRequest {
        var queryItems = scopedQueryItems(directory: directory, workspaceID: workspaceID)
        queryItems.append(URLQueryItem(name: "cursor", value: String(cursor)))
        guard let url = resolvedURL(path: "/pty/\(id)/connect", queryItems: queryItems),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeAPIError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            throw OpenCodeAPIError.invalidURL
        }
        guard let webSocketURL = components.url else {
            throw OpenCodeAPIError.invalidURL
        }

        var request = URLRequest(url: webSocketURL)
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        if let directoryHeader = explicitDirectoryHeader(directory) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }
        return request
    }

    func listSessions(directory: String? = nil, roots: Bool? = nil, limit: Int? = nil) async throws -> [OpenCodeSession] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let roots {
            queryItems.append(URLQueryItem(name: "roots", value: roots ? "true" : "false"))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        return try await send(path: "/session", method: "GET", queryItems: queryItems)
    }

    func listSessionStatuses(directory: String? = nil) async throws -> [String: String] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        let response: [String: OpenCodeSessionStatus] = try await send(path: "/session/status", method: "GET", queryItems: queryItems)
        return response.mapValues { $0.type }
    }

    func getSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func deleteSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(
            path: "/session/\(sessionID)",
            method: "DELETE",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func updateSessionTitle(sessionID: String, title: String, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "PATCH",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: UpdateSessionRequest(title: title),
            directoryHeader: directory
        )
    }

    func archiveSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil, archivedAt: Date = Date()) async throws -> OpenCodeSession {
        try await send(
            path: "/session/\(sessionID)",
            method: "PATCH",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: UpdateSessionRequest(
                title: nil,
                time: UpdateSessionTimeRequest(archived: archivedAt.timeIntervalSince1970 * 1000)
            ),
            directoryHeader: directory
        )
    }

    func createSession(title: String?, directory: String? = nil) async throws -> OpenCodeSession {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session", method: "POST", queryItems: queryItems, body: CreateSessionRequest(title: title))
    }

    func forkSession(sessionID: String, messageID: String?, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeSession {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(
            path: "/session/\(sessionID)/fork",
            method: "POST",
            queryItems: queryItems,
            body: ForkSessionRequest(messageID: messageID),
            directoryHeader: directory
        )
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await send(path: "/project", method: "GET")
    }

    func currentProject() async throws -> OpenCodeProject {
        try await send(path: "/project/current", method: "GET")
    }

    func currentProject(directory: String) async throws -> OpenCodeProject {
        try await send(path: "/project/current", method: "GET", queryItems: [URLQueryItem(name: "directory", value: directory)])
    }

    func updateProject(projectID: String, directory: String? = nil, name: String? = nil, icon: OpenCodeProject.Icon? = nil) async throws -> OpenCodeProject {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/project/\(projectID)", method: "PATCH", queryItems: queryItems, body: UpdateProjectRequest(name: name, icon: icon))
    }

    func listWorktrees(directory: String) async throws -> [String] {
        try await send(path: "/experimental/worktree", method: "GET", queryItems: [URLQueryItem(name: "directory", value: directory)])
    }

    func createWorktree(directory: String, name: String? = nil, startCommand: String? = nil) async throws -> OpenCodeWorktree {
        try await send(
            path: "/experimental/worktree",
            method: "POST",
            queryItems: [URLQueryItem(name: "directory", value: directory)],
            body: WorktreeCreateRequest(name: name, startCommand: startCommand)
        )
    }

    func removeWorktree(rootDirectory: String, worktreeDirectory: String) async throws -> Bool {
        try await send(
            path: "/experimental/worktree",
            method: "DELETE",
            queryItems: [URLQueryItem(name: "directory", value: rootDirectory)],
            body: WorktreeDirectoryRequest(directory: worktreeDirectory)
        )
    }

    func resetWorktree(rootDirectory: String, worktreeDirectory: String) async throws -> Bool {
        try await send(
            path: "/experimental/worktree/reset",
            method: "POST",
            queryItems: [URLQueryItem(name: "directory", value: rootDirectory)],
            body: WorktreeDirectoryRequest(directory: worktreeDirectory)
        )
    }

    func disposeInstance(directory: String? = nil, workspaceID: String? = nil) async throws -> Bool {
        try await send(
            path: "/instance/dispose",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func findFiles(query: String, directory: String) async throws -> [String] {
        return try await send(path: "/find/file", method: "GET", queryItems: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "directory", value: directory),
        ])
    }

    func listFiles(directory: String, path: String = "") async throws -> [OpenCodeFileNode] {
        return try await send(path: "/file", method: "GET", queryItems: [
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "path", value: path),
        ])
    }

    func readFileContent(directory: String, path: String) async throws -> OpenCodeFileContent {
        return try await send(path: "/file/content", method: "GET", queryItems: [
            URLQueryItem(name: "directory", value: directory),
            URLQueryItem(name: "path", value: path),
        ])
    }

    func getVCSInfo(directory: String? = nil) async throws -> OpenCodeVCSInfo {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/vcs", method: "GET", queryItems: queryItems)
    }

    func listFileStatus(directory: String? = nil) async throws -> [OpenCodeVCSFileStatus] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/file/status", method: "GET", queryItems: queryItems)
    }

    func getVCSDiff(mode: OpenCodeVCSDiffMode, directory: String? = nil) async throws -> [OpenCodeVCSFileDiff] {
        var queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        if let directory {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        return try await send(path: "/vcs/diff", method: "GET", queryItems: queryItems)
    }

    func listMessages(sessionID: String, limit: Int? = nil, directory: String? = nil) async throws -> [OpenCodeMessageEnvelope] {
        try await listMessagePage(sessionID: sessionID, limit: limit, directory: directory).messages
    }

    func listMessagePage(
        sessionID: String,
        limit: Int? = nil,
        before: String? = nil,
        directory: String? = nil
    ) async throws -> OpenCodeMessagePage {
        var queryItems: [URLQueryItem] = []
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let before {
            queryItems.append(URLQueryItem(name: "before", value: before))
        }
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        let request = try makeRequest(
            path: "/session/\(sessionID)/message",
            method: "GET",
            queryItems: queryItems,
            directoryHeader: directory
        )
        let (data, response) = try await session.data(for: request)
        let messages: [OpenCodeMessageEnvelope] = try decode(data: data, response: response)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        return OpenCodeMessagePage(
            messages: messages,
            nextCursor: http.value(forHTTPHeaderField: "X-Next-Cursor")
        )
    }

    func getMessage(sessionID: String, messageID: String, directory: String? = nil) async throws -> OpenCodeMessageEnvelope {
        try await send(path: "/session/\(sessionID)/message/\(messageID)", method: "GET",
            queryItems: directory.map { [.init(name: "directory", value: $0)] } ?? [], directoryHeader: directory)
    }

    func getTodos(sessionID: String) async throws -> [OpenCodeTodo] {
        try await send(path: "/session/\(sessionID)/todo", method: "GET")
    }

    func listAgents(directory: String? = nil) async throws -> [OpenCodeAgent] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/agent", method: "GET", queryItems: queryItems)
    }

    func listCommands(directory: String? = nil) async throws -> [OpenCodeCommand] {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/command", method: "GET", queryItems: queryItems)
    }

    func listProviders(directory: String? = nil) async throws -> [OpenCodeProvider] {
        try await providerState(directory: directory).all
    }

    func providerDefaults(directory: String? = nil) async throws -> [String: String] {
        try await providerState(directory: directory).default
    }

    func providerConfiguration(directory: String? = nil) async throws -> OpenCodeProvidersResponse {
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/config/providers", method: "GET", queryItems: queryItems)
    }

    func providerState(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeProviderListResponse {
        try await send(path: "/provider", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func providerAuthMethods(directory: String? = nil, workspaceID: String? = nil) async throws -> [String: [OpenCodeProviderAuthMethod]] {
        try await send(path: "/provider/auth", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func setProviderAPIKey(providerID: String, key: String) async throws {
        _ = try await send(path: "/auth/\(encodedPathComponent(providerID))", method: "PUT", body: SetProviderAuthRequest(type: "api", key: key)) as Bool
    }

    func authorizeProviderOAuth(providerID: String, method: Int, inputs: [String: String]? = nil, directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeProviderAuthAuthorization? {
        try await send(
            path: "/provider/\(encodedPathComponent(providerID))/oauth/authorize",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: ProviderOAuthAuthorizeRequest(method: method, inputs: inputs),
            directoryHeader: directory
        )
    }

    func completeProviderOAuth(providerID: String, method: Int, code: String? = nil, directory: String? = nil, workspaceID: String? = nil) async throws -> Bool {
        try await send(
            path: "/provider/\(encodedPathComponent(providerID))/oauth/callback",
            method: "POST",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            body: ProviderOAuthCallbackRequest(method: method, code: code),
            directoryHeader: directory
        )
    }

    func removeProviderAuth(providerID: String) async throws {
        _ = try await send(path: "/auth/\(encodedPathComponent(providerID))", method: "DELETE") as Bool
    }

    func updateGlobalConfig(_ patch: OpenCodeGlobalConfigPatch) async throws {
        _ = try await send(path: "/global/config", method: "PATCH", body: patch) as OpenCodeJSONValue
    }

    func globalConfig() async throws -> OpenCodeJSONValue {
        try await send(path: "/global/config", method: "GET")
    }

    func resolvedConfig(directory: String? = nil, workspaceID: String? = nil) async throws -> OpenCodeResolvedConfig {
        try await send(
            path: "/config",
            method: "GET",
            queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func disposeGlobal() async throws {
        try await sendNoContent(path: "/global/dispose", method: "POST")
    }

    func listMCPStatus(directory: String? = nil, workspaceID: String? = nil) async throws -> [String: OpenCodeMCPStatus] {
        try await send(path: "/mcp", method: "GET", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func connectMCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/mcp/\(encodedPathComponent(name))/connect", method: "POST", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func disconnectMCPServer(name: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        try await sendNoContent(path: "/mcp/\(encodedPathComponent(name))/disconnect", method: "POST", queryItems: scopedQueryItems(directory: directory, workspaceID: workspaceID), directoryHeader: directory)
    }

    func listPermissions(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodePermission] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(path: "/permission", method: "GET", queryItems: queryItems)
    }

    func listQuestions(directory: String? = nil, workspaceID: String? = nil) async throws -> [OpenCodeQuestionRequest] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return try await send(path: "/question", method: "GET", queryItems: queryItems)
    }

    func getNextControlRequest(directory: String?) async throws -> OpenCodeControlRequest {
        var path = "/tui/control/next"
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            path += "?directory=\(directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory)"
        }
        return try await send(path: path, method: "GET")
    }

    func respondToPermission(sessionID: String, permissionID: String, response: String, remember: Bool = false) async throws {
        struct PermissionResponse: Encodable {
            let response: String
            let remember: Bool
        }

        try await sendNoContent(path: "/session/\(sessionID)/permissions/\(permissionID)", method: "POST", body: PermissionResponse(response: response, remember: remember))
    }

    func replyToPermission(requestID: String, reply: String, message: String? = nil, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/permission/\(requestID)/reply",
            method: "POST",
            queryItems: queryItems,
            body: OpenCodePermissionReplyRequest(reply: reply, message: message),
            directoryHeader: directory
        )
    }

    func replyToQuestion(requestID: String, answers: [[String]], directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/question/\(requestID)/reply",
            method: "POST",
            queryItems: queryItems,
            body: OpenCodeQuestionReplyRequest(answers: answers),
            directoryHeader: directory
        )
    }

    func rejectQuestion(requestID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }

        try await sendNoContent(
            path: "/question/\(requestID)/reject",
            method: "POST",
            queryItems: queryItems,
            directoryHeader: explicitDirectoryHeader(directory)
        )
    }

    func sendMessage(
        sessionID: String,
        text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        messageID: String? = nil,
        partID: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws -> OpenCodeMessageEnvelope {
        let payload = makePromptRequest(text: text, agentMentions: agentMentions, attachments: attachments, messageID: messageID, partID: partID, model: model, agent: agent, variant: variant)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        return try await send(path: "/session/\(sessionID)/message", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func sendMessageAsync(
        sessionID: String,
        text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        messageID: String? = nil,
        partID: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let payload = makePromptRequest(text: text, agentMentions: agentMentions, attachments: attachments, messageID: messageID, partID: partID, model: model, agent: agent, variant: variant)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/prompt_async", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func sendCommand(
        sessionID: String,
        command: String,
        arguments: String = "",
        attachments: [OpenCodeComposerAttachment] = [],
        directory: String? = nil,
        model: OpenCodeModelReference? = nil,
        agent: String? = nil,
        variant: String? = nil
    ) async throws {
        let payload = SendCommandRequest(
            agent: agent,
            model: model.map { "\($0.providerID)/\($0.modelID)" },
            arguments: arguments,
            command: command,
            variant: variant,
            parts: attachments.map(makeFilePart)
        )
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/command", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func summarizeSession(
        sessionID: String,
        directory: String? = nil,
        model: OpenCodeModelReference,
        auto: Bool = false
    ) async throws {
        let payload = SummarizeSessionRequest(providerID: model.providerID, modelID: model.modelID, auto: auto)
        let queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        try await sendNoContent(path: "/session/\(sessionID)/summarize", method: "POST", queryItems: queryItems, body: payload, directoryHeader: directory)
    }

    func abortSession(sessionID: String, directory: String? = nil, workspaceID: String? = nil) async throws {
        var queryItems = directory.map { [URLQueryItem(name: "directory", value: $0)] } ?? []
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        try await sendNoContent(path: "/session/\(sessionID)/abort", method: "POST", queryItems: queryItems, directoryHeader: directory)
    }

    func eventURLs(directory: String?) throws -> [URL] {
        var urls: [URL] = []

        if var eventURL = resolvedURL(path: "/event", queryItems: []),
           let directory,
           !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var components = URLComponents(url: eventURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "directory", value: directory)]
            if let scopedURL = components?.url {
                eventURL = scopedURL
            }
            urls.append(eventURL)
        } else if let eventURL = resolvedURL(path: "/event", queryItems: []) {
            urls.append(eventURL)
        }

        if let globalURL = resolvedURL(path: "/global/event", queryItems: []) {
            urls.append(globalURL)
        }

        guard !urls.isEmpty else {
            throw OpenCodeAPIError.invalidURL
        }
        return urls
    }

    func globalEventURL() -> URL? {
        resolvedURL(path: "/global/event", queryItems: [])
    }

    private func send<T: Decodable>(path: String, method: String) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [])
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func send<T: Decodable>(path: String, method: String, queryItems: [URLQueryItem]) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<T: Decodable>(path: String, method: String, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, body: Body) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, body: Body, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body, directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func send<Body: Encodable, T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String?) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body, directoryHeader: directoryHeader)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    func send<Body: Encodable, T: Decodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body) async throws -> T {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body)
        let (data, response) = try await session.data(for: request)
        return try decode(data: data, response: response)
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, body: Body) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body)
        try await sendNoContent(request: request)
    }

    private func sendNoContent(request: URLRequest) async throws {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: request, body: data)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw OpenCodeAPIError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, body: Body, directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [], body: body, directoryHeader: directoryHeader)
        try await sendNoContent(request: request)
    }

    private func sendNoContent<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body, directoryHeader: directoryHeader)
        try await sendNoContent(request: request)
    }

    func sendNoContent(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String?) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader)
        try await sendNoContent(request: request)
    }

    func sendNoContent<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: queryItems, body: body)
        try await sendNoContent(request: request)
    }

    private func sendNoContent(path: String, method: String) async throws {
        let request = try makeRequest(path: path, method: method, queryItems: [])
        try await sendNoContent(request: request)
    }

    func makeRequest(path: String, method: String, queryItems: [URLQueryItem], directoryHeader: String? = nil, logRequest: Bool = true) throws -> URLRequest {
        guard let url = resolvedURL(path: path, queryItems: queryItems) else {
            throw OpenCodeAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(basicAuthHeader(), forHTTPHeaderField: "Authorization")
        if let directoryHeader = explicitDirectoryHeader(directoryHeader) ?? encodedDirectoryHeader(from: queryItems) {
            request.setValue(directoryHeader, forHTTPHeaderField: "x-opencode-directory")
        }

        if logRequest {
            debugLog(request: request)
        }

        return request
    }

    private func makeRequest<Body: Encodable>(path: String, method: String, queryItems: [URLQueryItem], body: Body, directoryHeader: String? = nil) throws -> URLRequest {
        var request = try makeRequest(path: path, method: method, queryItems: queryItems, directoryHeader: directoryHeader, logRequest: false)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        debugLog(request: request)

        return request
    }

    private func decode<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeAPIError.invalidResponse
        }
        debugLog(response: http, for: nil, body: data)
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeAPIError.httpError(http.statusCode, body)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            guard let repairedData = Self.repairingInvalidUnicodeEscapes(in: data) else {
                throw error
            }
            return try JSONDecoder().decode(T.self, from: repairedData)
        }
    }

    private static func repairingInvalidUnicodeEscapes(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8), text.contains("\\u") else { return nil }

        var repaired = ""
        repaired.reserveCapacity(text.count)
        var index = text.startIndex
        var changed = false

        while index < text.endIndex {
            guard isActiveUnicodeEscapeStart(at: index, in: text),
                  let escape = unicodeEscape(at: index, in: text) else {
                repaired.append(text[index])
                index = text.index(after: index)
                continue
            }

            if isHighSurrogate(escape.value) {
                let nextIndex = escape.endIndex
                if let nextEscape = unicodeEscape(at: nextIndex, in: text), isLowSurrogate(nextEscape.value) {
                    repaired.append(contentsOf: text[index ..< nextEscape.endIndex])
                    index = nextEscape.endIndex
                } else {
                    repaired.append("\\uFFFD")
                    index = escape.endIndex
                    changed = true
                }
                continue
            }

            if isLowSurrogate(escape.value) {
                repaired.append("\\uFFFD")
                index = escape.endIndex
                changed = true
                continue
            }

            repaired.append(contentsOf: text[index ..< escape.endIndex])
            index = escape.endIndex
        }

        guard changed else { return nil }
        return repaired.data(using: .utf8)
    }

    private static func isActiveUnicodeEscapeStart(at index: String.Index, in text: String) -> Bool {
        guard text[index] == "\\" else { return false }
        let next = text.index(after: index)
        guard next < text.endIndex, text[next] == "u" else { return false }

        var backslashCount = 0
        var cursor = index
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            guard text[previous] == "\\" else { break }
            backslashCount += 1
            cursor = previous
        }

        return backslashCount.isMultiple(of: 2)
    }

    private static func unicodeEscape(at index: String.Index, in text: String) -> (value: Int, endIndex: String.Index)? {
        guard index < text.endIndex, text[index] == "\\" else { return nil }
        let uIndex = text.index(after: index)
        guard uIndex < text.endIndex, text[uIndex] == "u" else { return nil }

        var cursor = text.index(after: uIndex)
        var value = 0
        for _ in 0 ..< 4 {
            guard cursor < text.endIndex, let digit = text[cursor].hexDigitValue else { return nil }
            value = value * 16 + digit
            cursor = text.index(after: cursor)
        }
        return (value, cursor)
    }

    private static func isHighSurrogate(_ value: Int) -> Bool {
        (0xD800 ... 0xDBFF).contains(value)
    }

    private static func isLowSurrogate(_ value: Int) -> Bool {
        (0xDC00 ... 0xDFFF).contains(value)
    }

    private func resolvedURL(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard let baseURL = config.sanitizedBaseURL else { return nil }
        let url = baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !queryItems.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        return components?.url
    }

    private func basicAuthHeader() -> String {
        let credentials = "\(config.username):\(config.password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private func debugLog(request: URLRequest) {
        #if DEBUG
        var headers = request.allHTTPHeaderFields ?? [:]
        if headers["Authorization"] != nil {
            headers["Authorization"] = "<redacted>"
        }

        let sortedHeaders = headers.keys.sorted().map { key in
            "\(key)=\(headers[key] ?? "")"
        }.joined(separator: ", ")

        let body = Self.debugBodyDescription(request.httpBody, url: request.url)

        print("[OpenCodeRequest] method=\(request.httpMethod ?? "na") url=\(Self.debugURLDescription(request.url)) headers=[\(sortedHeaders)] body=\(body)")
        #endif
    }

    private func debugLog(response: HTTPURLResponse, for request: URLRequest?, body: Data?) {
        #if DEBUG
        let responseBody = Self.debugBodyDescription(body, url: request?.url ?? response.url)

        print(
            "[OpenCodeResponse] status=\(response.statusCode) url=\(Self.debugURLDescription(request?.url ?? response.url)) body=\(responseBody)"
        )
        #endif
    }

    static func debugURLDescription(_ url: URL?) -> String {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "nil" }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.map { item in
            let sensitive = ["token", "auth_token", "ticket", "code", "key", "apikey", "api_key", "password", "authorization"]
            return sensitive.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "redacted") : item
        }
        return components.url?.absoluteString ?? "<redacted URL>"
    }

    static func debugBodyDescription(_ body: Data?, url: URL? = nil) -> String {
        // Provider payloads can include resolved keys/options, while auth and validation
        // responses can echo keys, answers, codes, or OAuth URLs.
        let path = url?.path.lowercased() ?? ""
        if ["auth", "oauth", "provider", "integration", "credential", "config", "form", "question", "pty"].contains(where: { path.split(separator: "/").contains(Substring($0)) }) {
            return "<redacted authentication/configuration body>"
        }
        let limit = 2_048
        guard let body, !body.isEmpty else { return "<empty>" }
        guard let text = String(data: body, encoding: .utf8) else {
            return "<\(body.count) bytes binary>"
        }
        guard text.count > limit else { return text }
        return "\(String(text.prefix(limit)))... <truncated \(body.count) bytes>"
    }

    private func encodedDirectoryHeader(from queryItems: [URLQueryItem]) -> String? {
        guard let directory = queryItems.first(where: { $0.name == "directory" })?.value,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
    }

    private func explicitDirectoryHeader(_ directory: String?) -> String? {
        guard let directory,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return directory.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? directory
    }

    private func scopedQueryItems(directory: String?, workspaceID: String?) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            queryItems.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspaceID, !workspaceID.isEmpty {
            queryItems.append(URLQueryItem(name: "workspace", value: workspaceID))
        }
        return queryItems
    }

    private func encodedPathComponent(_ value: String) -> String {
        value
    }

    private func makePromptRequest(
        text: String,
        agentMentions: [OpenCodeAgentMention],
        attachments: [OpenCodeComposerAttachment],
        messageID: String?,
        partID: String?,
        model: OpenCodeModelReference?,
        agent: String?,
        variant: String?
    ) -> SendMessageRequest {
        var parts: [SendMessagePart] = []
        if !text.isEmpty || attachments.isEmpty {
            parts.append(SendMessagePart(
                id: partID,
                type: "text",
                text: text,
                name: nil,
                mime: nil,
                filename: nil,
                url: nil,
                source: nil,
                synthetic: nil,
                metadata: nil
            ))
        }
        parts.append(contentsOf: agentMentions.map(makeAgentPart))
        parts.append(contentsOf: attachments.map(makeFilePart))
        return SendMessageRequest(
            messageID: messageID,
            model: model,
            agent: agent,
            variant: variant,
            parts: parts
        )
    }

    private func makeFilePart(_ attachment: OpenCodeComposerAttachment) -> SendMessagePart {
        SendMessagePart(
            id: attachment.id,
            type: "file",
            text: nil,
            name: nil,
            mime: attachment.mime,
            filename: attachment.filename,
            url: attachment.dataURL,
            source: nil,
            synthetic: nil,
            metadata: nil
        )
    }

    private func makeAgentPart(_ mention: OpenCodeAgentMention) -> SendMessagePart {
        SendMessagePart(
            id: OpenCodeIdentifier.part(),
            type: "agent",
            text: nil,
            name: mention.name,
            mime: nil,
            filename: nil,
            url: nil,
            source: SendMessagePartSource(value: mention.content, start: mention.start, end: mention.end),
            synthetic: nil,
            metadata: nil
        )
    }
}

private struct UpdateProjectRequest: Encodable {
    let name: String?
    let icon: OpenCodeProject.Icon?
}

private struct SetProviderAuthRequest: Encodable {
    let type: String
    let key: String
}

private struct ProviderOAuthAuthorizeRequest: Encodable {
    let method: Int
    let inputs: [String: String]?
}

private struct ProviderOAuthCallbackRequest: Encodable {
    let method: Int
    let code: String?
}

private struct WorktreeCreateRequest: Encodable {
    let name: String?
    let startCommand: String?
}

private struct WorktreeDirectoryRequest: Encodable {
    let directory: String
}

private struct SendCommandRequest: Encodable {
    let agent: String?
    let model: String?
    let arguments: String
    let command: String
    let variant: String?
    let parts: [SendMessagePart]
}

private struct SummarizeSessionRequest: Encodable {
    let providerID: String
    let modelID: String
    let auto: Bool
}
