import Foundation

enum OpenCodeIdentifier {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastTimestamp = 0
    nonisolated(unsafe) private static var counter = 0
    private static let base62Characters = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func message() -> String {
        prefixedAscending("msg")
    }

    static func part() -> String {
        prefixedAscending("prt")
    }

    private static func prefixedAscending(_ prefix: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        if timestamp != lastTimestamp {
            lastTimestamp = timestamp
            counter = 0
        }

        counter += 1

        let value = UInt64(timestamp) << 12 | UInt64(counter & 0x0FFF)
        let timeComponent = String(value, radix: 16, uppercase: false).leftPadded(to: 12, with: "0")
        let randomComponent = String((0 ..< 14).map { _ in
            base62Characters.randomElement() ?? "0"
        })

        return "\(prefix)_\(timeComponent)\(randomComponent)"
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }
}

struct HealthResponse: Codable {
    let healthy: Bool
    let version: String
}

struct OpenCodeSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    let directory: String?
    let projectID: String?
    let parentID: String?

    var isRootSession: Bool {
        parentID == nil
    }

    func merged(with incoming: OpenCodeSession) -> OpenCodeSession {
        OpenCodeSession(
            id: incoming.id,
            title: incoming.title ?? title,
            directory: incoming.directory ?? directory,
            projectID: incoming.projectID ?? projectID,
            parentID: incoming.parentID ?? parentID
        )
    }
}

struct OpenCodeProject: Codable, Identifiable, Hashable, Sendable {
    struct Icon: Codable, Hashable {
        let color: String?
    }

    struct Time: Codable, Hashable {
        let created: Double?
        let updated: Double?
    }

    let id: String
    let worktree: String
    let vcs: String?
    let name: String?
    let icon: Icon?
    let time: Time?
}

struct OpenCodeFileNode: Codable, Hashable, Sendable {
    let name: String
    let path: String
    let absolute: String
    let type: String
    let ignored: Bool?
}

struct OpenCodeMessageEnvelope: Codable, Identifiable, Hashable, Sendable {
    var info: OpenCodeMessage
    var parts: [OpenCodePart]

    var id: String { info.id }

    static func local(
        role: String,
        text: String,
        messageID: String = OpenCodeIdentifier.message(),
        sessionID: String? = nil,
        partID: String = OpenCodeIdentifier.part(),
        agent: String? = nil,
        model: OpenCodeMessageModelReference? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: messageID, role: role, sessionID: sessionID, time: nil, agent: agent, model: model),
            parts: [OpenCodePart(id: partID, messageID: messageID, sessionID: sessionID, type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: text)]
        )
    }

    func updatingInfo(_ info: OpenCodeMessage) -> OpenCodeMessageEnvelope {
        var copy = self
        copy.info = info
        return copy
    }

    func mergedWithCanonical(_ incoming: OpenCodeMessageEnvelope) -> OpenCodeMessageEnvelope {
        var merged = incoming

        for existingPart in parts {
            guard let existingPartID = existingPart.id,
                  let incomingIndex = merged.parts.firstIndex(where: { $0.id == existingPartID }) else {
                continue
            }

            var incomingPart = merged.parts[incomingIndex]

            if shouldPreserveStreamedText(existing: existingPart.text, incoming: incomingPart.text) {
                incomingPart.text = existingPart.text
            }

            merged.parts[incomingIndex] = incomingPart
        }

        return merged
    }

    func upsertingPart(_ part: OpenCodePart) -> OpenCodeMessageEnvelope {
        var copy = self

        if let partID = part.id,
           let index = copy.parts.firstIndex(where: { $0.id == partID }) {
            var merged = part
            let existing = copy.parts[index]

            // OpenCode can emit a later part update with empty text after many deltas.
            // Preserve the accumulated streamed text instead of wiping it out.
            if (merged.text == nil || merged.text?.isEmpty == true),
               let existingText = existing.text,
               !existingText.isEmpty {
                merged.text = existingText
            }

            copy.parts[index] = merged
            return copy
        }

        copy.parts.append(part)
        return copy
    }

    func applyingDelta(partID: String, field: String, delta: String) -> OpenCodeMessageEnvelope {
        guard field == "text",
              let index = parts.firstIndex(where: { $0.id == partID }) else {
            return self
        }

        var copy = self
        var part = copy.parts[index]
        part.text = (part.text ?? "") + delta
        copy.parts[index] = part
        return copy
    }

    func removingPart(partID: String) -> OpenCodeMessageEnvelope {
        var copy = self
        copy.parts.removeAll { $0.id == partID }
        return copy
    }

    private func shouldPreserveStreamedText(existing: String?, incoming: String?) -> Bool {
        guard let existing, !existing.isEmpty else { return false }

        guard let incoming else { return true }
        if incoming.isEmpty { return true }

        return existing.count > incoming.count && existing.hasPrefix(incoming)
    }
}

struct OpenCodeMessage: Codable, Hashable, Sendable {
    let id: String
    let role: String?
    let sessionID: String?
    let time: OpenCodeMessageTime?
    let agent: String?
    let model: OpenCodeMessageModelReference?
}

struct OpenCodeMessageModelReference: Codable, Hashable, Sendable {
    let providerID: String
    let modelID: String
    let variant: String?
}

struct OpenCodeMessageTime: Codable, Hashable, Sendable {
    let created: Double?
    let completed: Double?
}

struct OpenCodeEventInfo: Codable, Hashable, Sendable {
    let id: String
    let role: String?
    let sessionID: String?
    let time: OpenCodeMessageTime?
    let agent: String?
    let model: OpenCodeMessageModelReference?
    let title: String?
    let directory: String?
    let projectID: String?
    let parentID: String?

    init(message: OpenCodeMessage) {
        id = message.id
        role = message.role
        sessionID = message.sessionID
        time = message.time
        agent = message.agent
        model = message.model
        title = nil
        directory = nil
        projectID = nil
        parentID = nil
    }

    func asMessage() -> OpenCodeMessage {
        OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: time, agent: agent, model: model)
    }

    func asSession() -> OpenCodeSession {
        OpenCodeSession(id: id, title: title, directory: directory, projectID: projectID, parentID: parentID)
    }
}

struct SessionPreview: Hashable, Sendable {
    let text: String
    let date: Date?
}

struct OpenCodeModelReference: Codable, Hashable, Sendable {
    let providerID: String
    let modelID: String
}

struct OpenCodeAgent: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    let mode: String
    let hidden: Bool?
    let model: OpenCodeModelReference?
    let variant: String?

    var id: String { name }
}

struct OpenCodeModelCapabilities: Codable, Hashable, Sendable {
    let reasoning: Bool
}

struct OpenCodeModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    let name: String
    let capabilities: OpenCodeModelCapabilities
    let variants: [String: OpenCodeJSONValue]?
}

struct OpenCodeProvider: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let models: [String: OpenCodeModel]
}

struct OpenCodeProvidersResponse: Codable, Hashable, Sendable {
    let providers: [OpenCodeProvider]
    let `default`: [String: String]?
}

struct OpenCodeDirectoryState: Equatable, Sendable {
    var sessions: [OpenCodeSession] = []
    var selectedSession: OpenCodeSession?
    var messages: [OpenCodeMessageEnvelope] = []
    var sessionStatuses: [String: String] = [:]
    var todos: [OpenCodeTodo] = []
    var permissions: [OpenCodePermission] = []
    var questions: [OpenCodeQuestionRequest] = []
    var vcsInfo: OpenCodeVCSInfo?
    var vcsFileStatuses: [OpenCodeVCSFileStatus] = []
    var vcsDiffsByMode: [OpenCodeVCSDiffMode: [OpenCodeVCSFileDiff]] = [:]
    var selectedVCSMode: OpenCodeVCSDiffMode = .git
    var selectedVCSFile: String?
    var isLoadingVCS = false
    var vcsErrorMessage: String?
}

enum OpenCodeVCSDiffMode: String, CaseIterable, Codable, Hashable, Sendable {
    case git
    case branch

    var title: String {
        switch self {
        case .git:
            return "Git"
        case .branch:
            return "Branch"
        }
    }
}

struct OpenCodeVCSInfo: Codable, Hashable, Sendable {
    let branch: String?
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case branch
        case defaultBranch = "default_branch"
    }
}

struct OpenCodeVCSFileStatus: Codable, Hashable, Identifiable, Sendable {
    let path: String
    let added: Int
    let removed: Int
    let status: String

    var id: String { path }
}

struct OpenCodeVCSFileDiff: Codable, Hashable, Identifiable, Sendable {
    let file: String
    let patch: String
    let additions: Int
    let deletions: Int
    let status: String?

    var id: String { file }
}

struct OpenCodeVCSSummary: Hashable, Sendable {
    let fileCount: Int
    let additions: Int
    let deletions: Int
}

struct OpenCodeVCSIntensityFile: Hashable, Identifiable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let relativePath: String
    let score: Int

    var id: String { path }
}

struct OpenCodeTodo: Codable, Hashable, Identifiable, Sendable {
    let content: String
    let status: String
    let priority: String

    var id: String { content }

    var isComplete: Bool {
        status == "completed"
    }

    var isInProgress: Bool {
        status == "in_progress"
    }
}

enum OpenCodePermissionPattern: Codable, Hashable {
    case string(String)
    case array([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .array(try container.decode([String].self))
    }

    var summary: String? {
        switch self {
        case let .string(value):
            return value
        case let .array(values):
            return values.joined(separator: ", ")
        }
    }
}

struct OpenCodePermission: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]?
    let always: [String]?
    let metadata: [String: OpenCodeJSONValue]?
    let tool: OpenCodePermissionTool?

    var messageID: String {
        tool?.messageID ?? ""
    }

    var callID: String? {
        tool?.callID
    }

    var type: String {
        permission
    }

    var title: String {
        permission.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var summary: String {
        patterns?.first ?? metadataSummary ?? type.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var metadataSummary: String? {
        guard let metadata else { return nil }
        for key in ["description", "path", "command", "target", "directory"] {
            if let value = metadata[key]?.stringValue, !value.isEmpty {
                return value
            }
        }
        return metadata.values.compactMap(\.stringValue).first
    }

    static func from(eventProperties: OpenCodeEventProperties) -> OpenCodePermission? {
        guard let id = eventProperties.id,
              let sessionID = eventProperties.sessionID,
              let messageID = eventProperties.messageID,
              let permission = eventProperties.permissionType else {
            return nil
        }

        return OpenCodePermission(
            id: id,
            sessionID: sessionID,
            permission: permission,
            patterns: {
                switch eventProperties.pattern {
                case let .string(value): return [value]
                case let .array(values): return values
                default: return nil
                }
            }(),
            always: nil,
            metadata: eventProperties.metadata,
            tool: OpenCodePermissionTool(messageID: messageID, callID: eventProperties.callID)
        )
    }
}

struct OpenCodePermissionTool: Codable, Hashable, Sendable {
    let messageID: String?
    let callID: String?
}

struct OpenCodePermissionReplyRequest: Encodable {
    let reply: String
    let message: String?
}

struct OpenCodeQuestionRequest: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let questions: [OpenCodeQuestion]
    let tool: OpenCodeQuestionTool?
}

struct OpenCodeQuestion: Codable, Hashable, Sendable {
    let question: String
    let header: String
    let options: [OpenCodeQuestionOption]
    let multiple: Bool
    let custom: Bool?
}

struct OpenCodeQuestionOption: Codable, Hashable, Identifiable, Sendable {
    let label: String
    let description: String

    var id: String { label }
}

struct OpenCodeQuestionTool: Codable, Hashable, Sendable {
    let messageID: String?
    let callID: String?
}

struct OpenCodeQuestionReplyRequest: Encodable {
    let answers: [[String]]
}

enum OpenCodeJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenCodeJSONValue])
    case array([OpenCodeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: OpenCodeJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([OpenCodeJSONValue].self))
        }
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return value ? "true" : "false"
        case let .array(values):
            return values.compactMap(\.stringValue).joined(separator: ", ")
        case let .object(values):
            return values.values.compactMap(\.stringValue).first
        case .null:
            return nil
        }
    }

    var objectValue: [String: OpenCodeJSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    var arrayValue: [OpenCodeJSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }
}

struct OpenCodeControlRequest: Decodable, Hashable, Sendable {
    let path: String
    let body: OpenCodeJSONValue
}

struct OpenCodePart: Codable, Hashable, Sendable {
    let id: String?
    let messageID: String?
    let sessionID: String?
    let type: String
    let reason: String?
    let tool: String?
    let callID: String?
    let state: OpenCodeToolState?
    var text: String?
}

struct OpenCodeToolState: Codable, Hashable, Sendable {
    let status: String?
    let title: String?
    let error: String?
    let input: OpenCodeToolInput?
    let output: String?
    let metadata: OpenCodeToolMetadata?
}

struct OpenCodeToolInput: Codable, Hashable, Sendable {
    let command: String?
    let description: String?
    let path: String?
    let query: String?
    let pattern: String?
    let url: String?
}

struct OpenCodeToolMetadata: Codable, Hashable, Sendable {
    let output: String?
    let description: String?
    let exit: Int?
    let truncated: Bool?
    let files: [OpenCodeJSONValue]?
}

struct OpenCodeEventEnvelope: Codable, Sendable {
    let type: String
    let properties: OpenCodeEventProperties
}

struct OpenCodeGlobalEventEnvelope: Codable, Sendable {
    let directory: String?
    let project: String?
    let payload: OpenCodeEventEnvelope?
    let type: String?
    let properties: OpenCodeEventProperties?

    var event: OpenCodeEventEnvelope? {
        if let payload {
            return payload
        }
        guard let type, let properties else { return nil }
        return OpenCodeEventEnvelope(type: type, properties: properties)
    }
}

struct OpenCodeSessionStatus: Codable, Hashable {
    let type: String
}

struct OpenCodeSessionErrorData: Codable, Hashable, Sendable {
    let message: String?
}

struct OpenCodeSessionErrorPayload: Codable, Hashable, Sendable {
    let name: String?
    let data: OpenCodeSessionErrorData?
}

enum OpenCodeTypedEvent: Sendable {
    case projectUpdated(OpenCodeProject)
    case serverConnected
    case globalDisposed
    case sessionCreated(OpenCodeSession)
    case sessionUpdated(OpenCodeSession)
    case sessionDeleted(OpenCodeSession)
    case sessionStatus(sessionID: String, status: String)
    case sessionIdle(sessionID: String)
    case sessionError(sessionID: String?, message: String?)
    case sessionDiff(sessionID: String)
    case todoUpdated(sessionID: String, todos: [OpenCodeTodo])
    case messageUpdated(OpenCodeMessage)
    case messageRemoved(sessionID: String, messageID: String)
    case messagePartUpdated(OpenCodePart)
    case messagePartRemoved(messageID: String, partID: String)
    case messagePartDelta(sessionID: String, messageID: String, partID: String, field: String, delta: String)
    case permissionAsked(OpenCodePermission)
    case permissionReplied(sessionID: String, requestID: String, reply: String?)
    case questionAsked(OpenCodeQuestionRequest)
    case questionReplied(sessionID: String, requestID: String)
    case questionRejected(sessionID: String, requestID: String)
    case vcsBranchUpdated(branch: String?)
    case fileWatcherUpdated(file: String)
    case unknown(String)

    init?(envelope: OpenCodeEventEnvelope) {
        switch envelope.type {
        case "project.updated":
            guard let data = try? JSONDecoder().decode(OpenCodeProject.self, from: try JSONEncoder().encode(envelope.properties)) else { return nil }
            self = .projectUpdated(data)
        case "server.connected":
            self = .serverConnected
        case "global.disposed":
            self = .globalDisposed
        case "session.created":
            guard let info = envelope.properties.info else { return nil }
            self = .sessionCreated(info.asSession())
        case "session.updated":
            guard let info = envelope.properties.info else { return nil }
            self = .sessionUpdated(info.asSession())
        case "session.deleted":
            guard let info = envelope.properties.info else { return nil }
            self = .sessionDeleted(info.asSession())
        case "session.status":
            guard let sessionID = envelope.properties.sessionID,
                  let status = envelope.properties.status?.type else { return nil }
            self = .sessionStatus(sessionID: sessionID, status: status)
        case "session.idle":
            guard let sessionID = envelope.properties.sessionID else { return nil }
            self = .sessionIdle(sessionID: sessionID)
        case "session.error":
            self = .sessionError(sessionID: envelope.properties.sessionID, message: envelope.properties.error?.data?.message)
        case "session.diff":
            guard let sessionID = envelope.properties.sessionID else { return nil }
            self = .sessionDiff(sessionID: sessionID)
        case "todo.updated":
            guard let sessionID = envelope.properties.sessionID,
                  let todos = envelope.properties.todos else { return nil }
            self = .todoUpdated(sessionID: sessionID, todos: todos)
        case "message.updated":
            guard let info = envelope.properties.info else { return nil }
            self = .messageUpdated(info.asMessage())
        case "message.removed":
            guard let sessionID = envelope.properties.sessionID,
                  let messageID = envelope.properties.messageID else { return nil }
            self = .messageRemoved(sessionID: sessionID, messageID: messageID)
        case "message.part.updated":
            guard let part = envelope.properties.part else { return nil }
            self = .messagePartUpdated(part)
        case "message.part.removed":
            guard let messageID = envelope.properties.messageID,
                  let partID = envelope.properties.partID else { return nil }
            self = .messagePartRemoved(messageID: messageID, partID: partID)
        case "message.part.delta":
            guard let sessionID = envelope.properties.sessionID,
                  let messageID = envelope.properties.messageID,
                  let partID = envelope.properties.partID,
                  let field = envelope.properties.field,
                  let delta = envelope.properties.delta else { return nil }
            self = .messagePartDelta(sessionID: sessionID, messageID: messageID, partID: partID, field: field, delta: delta)
        case "permission.asked":
            guard let permission = OpenCodePermission.from(eventProperties: envelope.properties) else { return nil }
            self = .permissionAsked(permission)
        case "permission.replied":
            guard let sessionID = envelope.properties.sessionID,
                  let requestID = envelope.properties.permissionID else { return nil }
            self = .permissionReplied(sessionID: sessionID, requestID: requestID, reply: envelope.properties.reply)
        case "question.asked":
            guard let question = try? JSONDecoder().decode(OpenCodeQuestionRequest.self, from: try JSONEncoder().encode(envelope.properties)) else { return nil }
            self = .questionAsked(question)
        case "question.replied":
            guard let sessionID = envelope.properties.sessionID,
                  let requestID = envelope.properties.id else { return nil }
            self = .questionReplied(sessionID: sessionID, requestID: requestID)
        case "question.rejected":
            guard let sessionID = envelope.properties.sessionID,
                  let requestID = envelope.properties.id else { return nil }
            self = .questionRejected(sessionID: sessionID, requestID: requestID)
        case "vcs.branch.updated":
            self = .vcsBranchUpdated(branch: envelope.properties.branch)
        case "file.watcher.updated":
            guard let file = envelope.properties.file else { return nil }
            self = .fileWatcherUpdated(file: file)
        default:
            self = .unknown(envelope.type)
        }
    }
}

struct OpenCodeEventProperties: Codable, Sendable {
    let sessionID: String?
    let info: OpenCodeEventInfo?
    let part: OpenCodePart?
    let status: OpenCodeSessionStatus?
    let todos: [OpenCodeTodo]?
    let messageID: String?
    let partID: String?
    let field: String?
    let delta: String?
    let id: String?
    let permissionType: String?
    let pattern: OpenCodePermissionPattern?
    let callID: String?
    let title: String?
    let metadata: [String: OpenCodeJSONValue]?
    let permissionID: String?
    let response: String?
    let reply: String?
    let message: String?
    let error: OpenCodeSessionErrorPayload?
    let branch: String?
    let file: String?

    enum CodingKeys: String, CodingKey {
        case sessionID
        case info
        case part
        case status
        case todos
        case messageID
        case partID
        case field
        case delta
        case id
        case permissionType = "type"
        case pattern
        case callID
        case title
        case metadata
        case permissionID
        case response
        case reply
        case message
        case error
        case branch
        case file
    }
}

struct OpenCodeStreamUpdate {
    var messages: [OpenCodeMessageEnvelope]
    var shouldReload: Bool = false
    var applied: Bool = false
    var reason: String = ""
}

#if DEBUG
enum OpenCodePreviewData {
    static let config = OpenCodeServerConfig(
        baseURL: "http://127.0.0.1:4096",
        username: "opencode",
        password: "preview-token"
    )

    static let globalProject = OpenCodeProject(
        id: "global",
        worktree: "Global",
        vcs: nil,
        name: nil,
        icon: OpenCodeProject.Icon(color: nil),
        time: OpenCodeProject.Time(created: nil, updated: nil)
    )

    static let repoProject = OpenCodeProject(
        id: "preview-project",
        worktree: "/path/to/opencode-ios-client",
        vcs: "git",
        name: "opencode-ios-client",
        icon: OpenCodeProject.Icon(color: "#4F46E5"),
        time: OpenCodeProject.Time(created: 1_711_234_567, updated: 1_711_235_678)
    )

    static let projects = [globalProject, repoProject]

    static let primarySession = OpenCodeSession(
        id: "session-preview-main",
        title: "Preview polish pass",
        directory: repoProject.worktree,
        projectID: repoProject.id,
        parentID: nil
    )

    static let secondarySession = OpenCodeSession(
        id: "session-preview-followup",
        title: "Streaming cleanup",
        directory: repoProject.worktree,
        projectID: repoProject.id,
        parentID: nil
    )

    static let sessions = [primarySession, secondarySession]

    static let sessionPreviews: [String: SessionPreview] = [
        primarySession.id: SessionPreview(text: "Added reusable preview fixtures and view-level previews.", date: Date().addingTimeInterval(-420)),
        secondarySession.id: SessionPreview(text: "Need to verify tool activity rows against live messages.", date: Date().addingTimeInterval(-3_600)),
    ]

    static let todoPending = OpenCodeTodo(content: "Audit the top-level views", status: "pending", priority: "high")
    static let todoActive = OpenCodeTodo(content: "Add inline previews for chat subviews", status: "in_progress", priority: "high")
    static let todoDone = OpenCodeTodo(content: "Keep previews offline-safe", status: "completed", priority: "medium")
    static let todos = [todoPending, todoActive, todoDone]

    static let permission = OpenCodePermission(
        id: "permission-preview-1",
        sessionID: primarySession.id,
        permission: "bash",
        patterns: ["xcodebuild -project OpenCodeIOSClient.xcodeproj build"],
        always: nil,
        metadata: ["command": .string("xcodebuild -project OpenCodeIOSClient.xcodeproj build")],
        tool: OpenCodePermissionTool(messageID: "message-preview-assistant", callID: "call-preview-build")
    )

    static let questionRequest = OpenCodeQuestionRequest(
        id: "question-preview-1",
        sessionID: primarySession.id,
        questions: [
            OpenCodeQuestion(
                question: "Which preview surface do you want to tweak first?",
                header: "Preview Focus",
                options: [
                    OpenCodeQuestionOption(label: "Chat", description: "Inspect message spacing and composer layout."),
                    OpenCodeQuestionOption(label: "Sessions", description: "Tune list density, avatars, and metadata."),
                    OpenCodeQuestionOption(label: "Projects", description: "Adjust sidebar selection and search rows."),
                ],
                multiple: false,
                custom: true
            )
        ],
        tool: OpenCodeQuestionTool(messageID: "message-preview-assistant", callID: "call-preview-question")
    )

    static let agents = [
        OpenCodeAgent(name: "build", description: "General coding agent", mode: "default", hidden: false, model: nil, variant: nil),
        OpenCodeAgent(name: "planner", description: "Breaks down UI work", mode: "default", hidden: false, model: nil, variant: nil),
    ]

    static let previewModel = OpenCodeModel(
        id: "gpt-5.4",
        providerID: "openai",
        name: "GPT-5.4",
        capabilities: OpenCodeModelCapabilities(reasoning: true),
        variants: ["balanced": .bool(true), "deep_think": .bool(true)]
    )

    static let providers = [
        OpenCodeProvider(id: "openai", name: "OpenAI", models: [previewModel.id: previewModel])
    ]

    static let defaultModelsByProviderID = ["openai": "gpt-5.4"]

    static let userMessage = OpenCodeMessageEnvelope(
        info: OpenCodeMessage(
            id: "message-preview-user",
            role: "user",
            sessionID: primarySession.id,
            time: OpenCodeMessageTime(created: 1_711_236_000, completed: 1_711_236_005),
            agent: "build",
            model: OpenCodeMessageModelReference(providerID: "openai", modelID: "gpt-5.4", variant: "balanced")
        ),
        parts: [
            OpenCodePart(
                id: "part-preview-user-text",
                messageID: "message-preview-user",
                sessionID: primarySession.id,
                type: "text",
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: "Can you add previews to every SwiftUI component so I can iterate faster?"
            )
        ]
    )

    static let assistantMessage = OpenCodeMessageEnvelope(
        info: OpenCodeMessage(
            id: "message-preview-assistant",
            role: "assistant",
            sessionID: primarySession.id,
            time: OpenCodeMessageTime(created: 1_711_236_010, completed: 1_711_236_060),
            agent: nil,
            model: nil
        ),
        parts: [
            OpenCodePart(
                id: "part-preview-reasoning",
                messageID: "message-preview-assistant",
                sessionID: primarySession.id,
                type: "reasoning",
                reason: "running",
                tool: nil,
                callID: nil,
                state: OpenCodeToolState(status: "running", title: nil, error: nil, input: nil, output: nil, metadata: nil),
                text: "Mapping the UI surface first, then adding previews with shared fixtures so the previews stay realistic and cheap to maintain."
            ),
            OpenCodePart(
                id: "part-preview-tool",
                messageID: "message-preview-assistant",
                sessionID: primarySession.id,
                type: "bash",
                reason: "completed",
                tool: "bash",
                callID: "call-preview-build",
                state: OpenCodeToolState(
                    status: "completed",
                    title: "Build for simulator",
                    error: nil,
                    input: OpenCodeToolInput(
                        command: "xcodebuild -quiet -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient -destination 'platform=iOS Simulator,name=iPhone 17' build",
                        description: "Builds the app for preview validation",
                        path: nil,
                        query: nil,
                        pattern: nil,
                        url: nil
                    ),
                    output: "Build Succeeded",
                    metadata: OpenCodeToolMetadata(output: "Build Succeeded", description: "Simulator build", exit: 0, truncated: false, files: nil)
                ),
                text: nil
            ),
            OpenCodePart(
                id: "part-preview-assistant-text",
                messageID: "message-preview-assistant",
                sessionID: primarySession.id,
                type: "text",
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: "I added `#Preview` blocks for the main views and the chat subcomponents so you can jump straight into UI tweaks without bootstrapping the full app."
            ),
        ]
    )

    static let todoMessage = OpenCodeMessageEnvelope(
        info: OpenCodeMessage(
            id: "message-preview-todo",
            role: "assistant",
            sessionID: primarySession.id,
            time: OpenCodeMessageTime(created: 1_711_236_080, completed: 1_711_236_081),
            agent: nil,
            model: nil
        ),
        parts: [
            OpenCodePart(
                id: "part-preview-todo-tool",
                messageID: "message-preview-todo",
                sessionID: primarySession.id,
                type: "tool",
                reason: "completed",
                tool: "todowrite",
                callID: "call-preview-todo",
                state: OpenCodeToolState(
                    status: "completed",
                    title: "Update task list",
                    error: nil,
                    input: OpenCodeToolInput(command: nil, description: "Track preview work", path: nil, query: nil, pattern: nil, url: nil),
                    output: nil,
                    metadata: nil
                ),
                text: "[{\"content\":\"Audit the top-level views\",\"status\":\"pending\",\"priority\":\"high\"}]"
            )
        ]
    )

    static let messages = [userMessage, assistantMessage, todoMessage]

    static let toolMessageDetails: [String: OpenCodeMessageEnvelope] = [
        assistantMessage.id: assistantMessage,
        todoMessage.id: todoMessage,
    ]
}
#endif

enum OpenCodeStreamReducer {
    static func apply(
        payload: OpenCodeEventEnvelope,
        selectedSessionID: String,
        messages: [OpenCodeMessageEnvelope]
    ) -> OpenCodeStreamUpdate {
        guard payload.properties.sessionID == selectedSessionID else {
            return OpenCodeStreamUpdate(messages: messages, reason: "session mismatch")
        }

        var result = OpenCodeStreamUpdate(messages: messages, reason: "no-op")

        switch payload.type {
        case "message.updated":
            guard let info = payload.properties.info else {
                result.reason = "missing info"
                return result
            }
            let message = info.asMessage()
            if let index = result.messages.firstIndex(where: { $0.info.id == info.id }) {
                result.messages[index] = result.messages[index].updatingInfo(message)
            } else {
                result.messages.append(OpenCodeMessageEnvelope(info: message, parts: []))
            }
            result.applied = true
            result.reason = "message updated"
        case "message.part.updated":
            guard let part = payload.properties.part,
                  let messageID = part.messageID else {
                result.reason = "missing part/message id"
                return result
            }
            if let index = result.messages.firstIndex(where: { $0.info.id == messageID }) {
                result.messages[index] = result.messages[index].upsertingPart(part)
            } else {
                let placeholder = OpenCodeMessage(id: messageID, role: "assistant", sessionID: part.sessionID, time: nil, agent: nil, model: nil)
                result.messages.append(OpenCodeMessageEnvelope(info: placeholder, parts: [part]))
            }
            result.applied = true
            result.reason = "part updated"
        case "message.part.delta":
            guard let messageID = payload.properties.messageID,
                  let partID = payload.properties.partID,
                  let field = payload.properties.field,
                  let delta = payload.properties.delta else {
                result.reason = "missing delta target"
                return result
            }

            guard let index = result.messages.firstIndex(where: { $0.info.id == messageID }) else {
                if let sessionID = payload.properties.sessionID {
                    let placeholder = OpenCodeMessage(id: messageID, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil)
                    let placeholderPart = OpenCodePart(id: partID, messageID: messageID, sessionID: sessionID, type: "text", reason: nil, tool: nil, callID: nil, state: nil, text: delta)
                    result.messages.append(OpenCodeMessageEnvelope(info: placeholder, parts: [placeholderPart]))
                    result.applied = true
                    result.reason = "delta placeholder created"
                } else {
                    result.reason = "missing delta target"
                }
                return result
            }

            result.messages[index] = result.messages[index].applyingDelta(partID: partID, field: field, delta: delta)
            result.applied = true
            result.reason = "delta applied"
        case "session.idle":
            result.shouldReload = true
            result.reason = "session idle"
        default:
            result.reason = "ignored \(payload.type)"
            break
        }

        return result
    }
}

struct CreateSessionRequest: Encodable {
    let title: String?
}

struct SendMessageRequest: Encodable {
    let messageID: String?
    let model: OpenCodeModelReference?
    let agent: String?
    let variant: String?
    let parts: [SendMessagePart]
}

struct SendMessagePart: Encodable {
    let id: String?
    let type: String
    let text: String?
    let synthetic: Bool?
    let metadata: [String: OpenCodeJSONValue]?
}

enum OpenCodeAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The server URL is invalid."
        case .invalidResponse:
            return "The server returned an invalid response."
        case let .httpError(code, body):
            if body.isEmpty {
                return "The server request failed with status \(code)."
            }
            return "The server request failed with status \(code): \(body)"
        }
    }
}
