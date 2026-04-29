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
        var timeBytes = [UInt8](repeating: 0, count: 6)
        for index in 0 ..< 6 {
            let shift = UInt64(40 - (8 * index))
            timeBytes[index] = UInt8((value >> shift) & 0xFF)
        }

        let timeComponent = timeBytes
            .map { String($0, radix: 16, uppercase: false).leftPadded(to: 2, with: "0") }
            .joined()
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
    let workspaceID: String?
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
            workspaceID: incoming.workspaceID ?? workspaceID,
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

    var isDirectory: Bool {
        type == "directory"
    }
}

struct OpenCodeFileContent: Codable, Hashable, Sendable {
    let type: String
    let content: String
    let diff: String?
    let encoding: String?
    let mimeType: String?
}

struct OpenCodeMessageEnvelope: Codable, Identifiable, Hashable, Sendable {
    var info: OpenCodeMessage
    var parts: [OpenCodePart]

    var id: String { info.id }

    static func local(
        role: String,
        text: String,
        attachments: [OpenCodeComposerAttachment] = [],
        messageID: String = OpenCodeIdentifier.message(),
        sessionID: String? = nil,
        partID: String = OpenCodeIdentifier.part(),
        agent: String? = nil,
        model: OpenCodeMessageModelReference? = nil
    ) -> OpenCodeMessageEnvelope {
        var parts: [OpenCodePart] = []

        if !text.isEmpty || attachments.isEmpty {
            parts.append(
                OpenCodePart(
                    id: partID,
                    messageID: messageID,
                    sessionID: sessionID,
                    type: "text",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: nil,
                    callID: nil,
                    state: nil,
                    text: text
                )
            )
        }

        parts.append(contentsOf: attachments.map { attachment in
            OpenCodePart(
                id: OpenCodeIdentifier.part(),
                messageID: messageID,
                sessionID: sessionID,
                type: "file",
                mime: attachment.mime,
                filename: attachment.filename,
                url: attachment.dataURL,
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: nil
            )
        })

        return OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: messageID, role: role, sessionID: sessionID, time: nil, agent: agent, model: model),
            parts: parts
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

    func debugJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func copiedTextContent() -> String? {
        let text = parts
            .compactMap(\ .text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        return text.isEmpty ? nil : text
    }
}

struct OpenCodeMessage: Codable, Hashable, Sendable {
    let id: String
    let role: String?
    let sessionID: String?
    let time: OpenCodeMessageTime?
    let agent: String?
    let model: OpenCodeMessageModelReference?
    let parentID: String?
    let mode: String?
    let summary: Bool?
    let finish: String?
    let providerID: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case sessionID
        case time
        case agent
        case model
        case parentID
        case mode
        case summary
        case finish
        case providerID
        case modelID
    }

    init(
        id: String,
        role: String?,
        sessionID: String?,
        time: OpenCodeMessageTime?,
        agent: String?,
        model: OpenCodeMessageModelReference?,
        parentID: String? = nil,
        mode: String? = nil,
        summary: Bool? = nil,
        finish: String? = nil,
        providerID: String? = nil,
        modelID: String? = nil
    ) {
        self.id = id
        self.role = role
        self.sessionID = sessionID
        self.time = time
        self.agent = agent
        self.model = model
        self.parentID = parentID
        self.mode = mode
        self.summary = summary
        self.finish = finish
        self.providerID = providerID
        self.modelID = modelID
    }

    var isCompactionSummary: Bool {
        (role ?? "").lowercased() == "assistant" && (summary == true || agent == "compaction" || mode == "compaction")
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        time = try container.decodeIfPresent(OpenCodeMessageTime.self, forKey: .time)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        model = try container.decodeIfPresent(OpenCodeMessageModelReference.self, forKey: .model)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        summary = try? container.decode(Bool.self, forKey: .summary)
        finish = try container.decodeIfPresent(String.self, forKey: .finish)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }
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
    let mode: String?
    let summary: Bool?
    let finish: String?
    let providerID: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case sessionID
        case time
        case agent
        case model
        case title
        case directory
        case projectID
        case parentID
        case mode
        case summary
        case finish
        case providerID
        case modelID
    }

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
        parentID = message.parentID
        mode = message.mode
        summary = message.summary
        finish = message.finish
        providerID = message.providerID
        modelID = message.modelID
    }

    func asMessage() -> OpenCodeMessage {
        let effectiveModel = model ?? providerID.flatMap { providerID in
            modelID.map { OpenCodeMessageModelReference(providerID: providerID, modelID: $0, variant: nil) }
        }
        return OpenCodeMessage(
            id: id,
            role: role,
            sessionID: sessionID,
            time: time,
            agent: agent,
            model: effectiveModel,
            parentID: parentID,
            mode: mode,
            summary: summary,
            finish: finish,
            providerID: providerID,
            modelID: modelID
        )
    }

    func asSession() -> OpenCodeSession {
        OpenCodeSession(id: id, title: title, workspaceID: nil, directory: directory, projectID: projectID, parentID: parentID)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        time = try container.decodeIfPresent(OpenCodeMessageTime.self, forKey: .time)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        model = try container.decodeIfPresent(OpenCodeMessageModelReference.self, forKey: .model)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        summary = try? container.decode(Bool.self, forKey: .summary)
        finish = try container.decodeIfPresent(String.self, forKey: .finish)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    }
}

struct SessionPreview: Codable, Hashable, Sendable {
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

struct OpenCodeCommand: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    let agent: String?
    let model: String?
    let source: String?
    let template: String
    let subtask: Bool?
    let hints: [String]

    var id: String { name }
}

struct OpenCodeComposerAttachment: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case image
        case file
    }

    let id: String
    let kind: Kind
    let filename: String
    let mime: String
    let dataURL: String

    var isImage: Bool {
        kind == .image || mime.lowercased().hasPrefix("image/")
    }
}

struct OpenCodeMessageDraft: Codable, Equatable, Sendable {
    var text: String

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct OpenCodeForkableMessage: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    let created: Double?
}

struct OpenCodeChatBreadcrumb: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let event: String
    let sessionID: String?
    let selectedSessionID: String?
    let directory: String?
    let messageID: String?
    let partID: String?
    let messageCount: Int
    let assistantTextLength: Int

    init(
        event: String,
        sessionID: String?,
        selectedSessionID: String?,
        directory: String?,
        messageID: String?,
        partID: String?,
        messageCount: Int,
        assistantTextLength: Int
    ) {
        self.id = UUID()
        self.createdAt = Date()
        self.event = event
        self.sessionID = sessionID
        self.selectedSessionID = selectedSessionID
        self.directory = directory
        self.messageID = messageID
        self.partID = partID
        self.messageCount = messageCount
        self.assistantTextLength = assistantTextLength
    }
}

struct OpenCodeProvidersResponse: Codable, Hashable, Sendable {
    let providers: [OpenCodeProvider]
    let `default`: [String: String]?
}

struct OpenCodeMCPStatus: Codable, Hashable, Sendable {
    let status: String
    let error: String?

    var isConnected: Bool {
        status == "connected"
    }

    var displayStatus: String {
        switch status {
        case "connected":
            return "Connected"
        case "disabled":
            return "Disabled"
        case "failed":
            return "Failed"
        case "needs_auth":
            return "Needs Auth"
        case "needs_client_registration":
            return "Needs Registration"
        default:
            return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct OpenCodeMCPServer: Identifiable, Hashable, Sendable {
    let name: String
    let status: OpenCodeMCPStatus

    var id: String { name }
}

struct OpenCodeDirectoryState: Equatable, Sendable {
    var isLoadingSessions = false
    var sessions: [OpenCodeSession] = []
    var selectedSession: OpenCodeSession?
    var isLoadingSelectedSession = false
    var messages: [OpenCodeMessageEnvelope] = []
    var commands: [OpenCodeCommand] = []
    var sessionStatuses: [String: String] = [:]
    var todos: [OpenCodeTodo] = []
    var permissions: [OpenCodePermission] = []
    var questions: [OpenCodeQuestionRequest] = []
    var mcpStatuses: [String: OpenCodeMCPStatus] = [:]
    var isMCPReady = false
    var isLoadingMCP = false
    var togglingMCPServerNames: Set<String> = []
    var mcpErrorMessage: String?
    var vcsInfo: OpenCodeVCSInfo?
    var vcsFileStatuses: [OpenCodeVCSFileStatus] = []
    var vcsDiffsByMode: [OpenCodeVCSDiffMode: [OpenCodeVCSFileDiff]] = [:]
    var selectedVCSMode: OpenCodeVCSDiffMode = .git
    var selectedVCSFile: String?
    var projectFilesMode: OpenCodeProjectFilesMode = .changes
    var fileTreeRootNodes: [OpenCodeFileNode] = []
    var fileTreeChildrenByParentPath: [String: [OpenCodeFileNode]] = [:]
    var expandedFileTreeDirectories: Set<String> = []
    var selectedProjectFilePath: String?
    var fileContentsByPath: [String: OpenCodeFileContent] = [:]
    var isLoadingFileTree = false
    var isLoadingSelectedFileContent = false
    var fileTreeErrorMessage: String?
    var fileContentErrorMessage: String?
    var isLoadingVCS = false
    var vcsErrorMessage: String?
}

enum AppBackendMode: String, Codable, Sendable {
    case none
    case server
    case appleIntelligence
}

struct AppleIntelligenceWorkspaceRecord: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var bookmarkData: Data
    var lastKnownPath: String
    var sessionID: String
    var messages: [OpenCodeMessageEnvelope]
    var updatedAt: Date

    var session: OpenCodeSession {
        OpenCodeSession(
            id: sessionID,
            title: title,
            workspaceID: nil,
            directory: lastKnownPath,
            projectID: id,
            parentID: nil
        )
    }

    var project: OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: lastKnownPath,
            vcs: nil,
            name: title,
            icon: nil,
            time: nil
        )
    }
}

enum OpenCodeProjectFilesMode: String, CaseIterable, Hashable, Sendable {
    case changes
    case tree

    var title: String {
        switch self {
        case .changes:
            return "Changes"
        case .tree:
            return "Tree"
        }
    }
}

enum OpenCodeVCSDiffMode: String, CaseIterable, Codable, Hashable, Sendable {
    case git
    case branch

    var title: String {
        switch self {
        case .git:
            return "Working Tree"
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

struct OpenCodeVCSAggregateStatus: Hashable, Sendable {
    let fileCount: Int
    let additions: Int
    let deletions: Int

    var hasChanges: Bool {
        fileCount > 0 || additions > 0 || deletions > 0
    }
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
              let permission = eventProperties.permission ?? eventProperties.permissionType else {
            return nil
        }

        return OpenCodePermission(
            id: id,
            sessionID: sessionID,
            permission: permission,
            patterns: eventProperties.patterns ?? {
                switch eventProperties.pattern {
                case let .string(value): return [value]
                case let .array(values): return values
                default: return nil
                }
            }(),
            always: eventProperties.always,
            metadata: eventProperties.metadata,
            tool: eventProperties.tool ?? OpenCodePermissionTool(messageID: eventProperties.messageID, callID: eventProperties.callID)
        )
    }
}

struct OpenCodePermissionTool: Codable, Hashable, Sendable {
    let messageID: String?
    let callID: String?
}

struct OpenCodePermissionReplyEvent: Codable, Hashable, Sendable {
    let sessionID: String
    let requestID: String
    let reply: String?
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

    init(question: String, header: String, options: [OpenCodeQuestionOption], multiple: Bool = false, custom: Bool? = true) {
        self.question = question
        self.header = header
        self.options = options
        self.multiple = multiple
        self.custom = custom
    }

    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case question
            case header
            case options
            case multiple
            case custom
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decode(String.self, forKey: .question)
        header = try container.decode(String.self, forKey: .header)
        options = try container.decode([OpenCodeQuestionOption].self, forKey: .options)
        multiple = try container.decodeIfPresent(Bool.self, forKey: .multiple) ?? false
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? true
    }

    func encode(to encoder: Encoder) throws {
        enum CodingKeys: String, CodingKey {
            case question
            case header
            case options
            case multiple
            case custom
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(header, forKey: .header)
        try container.encode(options, forKey: .options)
        try container.encode(multiple, forKey: .multiple)
        try container.encodeIfPresent(custom, forKey: .custom)
    }
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
    let mime: String?
    let filename: String?
    let url: String?
    let reason: String?
    let tool: String?
    let callID: String?
    let state: OpenCodeToolState?
    var text: String?
    let auto: Bool?
    let overflow: Bool?
    let tailStartID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case messageID
        case sessionID
        case type
        case mime
        case filename
        case url
        case reason
        case tool
        case callID
        case state
        case text
        case auto
        case overflow
        case tailStartID = "tail_start_id"
    }

    init(
        id: String?,
        messageID: String?,
        sessionID: String?,
        type: String,
        mime: String?,
        filename: String?,
        url: String?,
        reason: String?,
        tool: String?,
        callID: String?,
        state: OpenCodeToolState?,
        text: String?,
        auto: Bool? = nil,
        overflow: Bool? = nil,
        tailStartID: String? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.sessionID = sessionID
        self.type = type
        self.mime = mime
        self.filename = filename
        self.url = url
        self.reason = reason
        self.tool = tool
        self.callID = callID
        self.state = state
        self.text = text
        self.auto = auto
        self.overflow = overflow
        self.tailStartID = tailStartID
    }

    var isCompaction: Bool {
        type == "compaction"
    }
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
    let filePath: String?
    let name: String?
    let path: String?
    let query: String?
    let pattern: String?
    let subagentType: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case command
        case description
        case filePath
        case name
        case path
        case query
        case pattern
        case subagentType = "subagent_type"
        case url
    }
}

struct OpenCodeToolMetadata: Codable, Hashable, Sendable {
    let output: String?
    let description: String?
    let exit: Int?
    let filediff: OpenCodeJSONValue?
    let loaded: [String]?
    let sessionId: String?
    let truncated: Bool?
    let files: [OpenCodeJSONValue]?

    enum CodingKeys: String, CodingKey {
        case output
        case description
        case exit
        case filediff
        case loaded
        case sessionId
        case truncated
        case files
    }
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
            if let permission = try? JSONDecoder().decode(OpenCodePermission.self, from: try JSONEncoder().encode(envelope.properties)) {
                self = .permissionAsked(permission)
            } else if let permission = OpenCodePermission.from(eventProperties: envelope.properties) {
                self = .permissionAsked(permission)
            } else {
                return nil
            }
        case "permission.replied":
            if let reply = try? JSONDecoder().decode(OpenCodePermissionReplyEvent.self, from: try JSONEncoder().encode(envelope.properties)) {
                self = .permissionReplied(sessionID: reply.sessionID, requestID: reply.requestID, reply: reply.reply)
            } else if let sessionID = envelope.properties.sessionID,
                      let requestID = envelope.properties.requestID ?? envelope.properties.permissionID {
                self = .permissionReplied(sessionID: sessionID, requestID: requestID, reply: envelope.properties.reply)
            } else {
                return nil
            }
        case "question.asked":
            guard let question = try? JSONDecoder().decode(OpenCodeQuestionRequest.self, from: try JSONEncoder().encode(envelope.properties)) else { return nil }
            self = .questionAsked(question)
        case "question.replied":
            guard let sessionID = envelope.properties.sessionID,
                  let requestID = envelope.properties.requestID ?? envelope.properties.id else { return nil }
            self = .questionReplied(sessionID: sessionID, requestID: requestID)
        case "question.rejected":
            guard let sessionID = envelope.properties.sessionID,
                  let requestID = envelope.properties.requestID ?? envelope.properties.id else { return nil }
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
    let permission: String?
    let permissionType: String?
    let patterns: [String]?
    let pattern: OpenCodePermissionPattern?
    let always: [String]?
    let tool: OpenCodePermissionTool?
    let callID: String?
    let title: String?
    let metadata: [String: OpenCodeJSONValue]?
    let questions: [OpenCodeQuestion]?
    let requestID: String?
    let permissionID: String?
    let response: String?
    let reply: String?
    let message: String?
    let error: OpenCodeSessionErrorPayload?
    let branch: String?
    let file: String?

    init(
        sessionID: String? = nil,
        info: OpenCodeEventInfo? = nil,
        part: OpenCodePart? = nil,
        status: OpenCodeSessionStatus? = nil,
        todos: [OpenCodeTodo]? = nil,
        messageID: String? = nil,
        partID: String? = nil,
        field: String? = nil,
        delta: String? = nil,
        id: String? = nil,
        permission: String? = nil,
        permissionType: String? = nil,
        patterns: [String]? = nil,
        pattern: OpenCodePermissionPattern? = nil,
        always: [String]? = nil,
        tool: OpenCodePermissionTool? = nil,
        callID: String? = nil,
        title: String? = nil,
        metadata: [String: OpenCodeJSONValue]? = nil,
        questions: [OpenCodeQuestion]? = nil,
        requestID: String? = nil,
        permissionID: String? = nil,
        response: String? = nil,
        reply: String? = nil,
        message: String? = nil,
        error: OpenCodeSessionErrorPayload? = nil,
        branch: String? = nil,
        file: String? = nil
    ) {
        self.sessionID = sessionID
        self.info = info
        self.part = part
        self.status = status
        self.todos = todos
        self.messageID = messageID
        self.partID = partID
        self.field = field
        self.delta = delta
        self.id = id
        self.permission = permission
        self.permissionType = permissionType
        self.patterns = patterns
        self.pattern = pattern
        self.always = always
        self.tool = tool
        self.callID = callID
        self.title = title
        self.metadata = metadata
        self.questions = questions
        self.requestID = requestID
        self.permissionID = permissionID
        self.response = response
        self.reply = reply
        self.message = message
        self.error = error
        self.branch = branch
        self.file = file
    }

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
        case permission
        case permissionType = "type"
        case patterns
        case pattern
        case always
        case tool
        case callID
        case title
        case metadata
        case questions
        case requestID
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
        workspaceID: nil,
        directory: repoProject.worktree,
        projectID: repoProject.id,
        parentID: nil
    )

    static let secondarySession = OpenCodeSession(
        id: "session-preview-followup",
        title: "Streaming cleanup",
        workspaceID: nil,
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

    static let commands = [
        OpenCodeCommand(
            name: "compact",
            description: "Summarize the session so far",
            agent: nil,
            model: nil,
            source: "command",
            template: "Compact the current session state.",
            subtask: nil,
            hints: []
        ),
        OpenCodeCommand(
            name: "review",
            description: "Review recent code changes for issues",
            agent: nil,
            model: nil,
            source: "command",
            template: "Review the latest changes.",
            subtask: nil,
            hints: []
        ),
    ]

    static let composerAttachments = [
        OpenCodeComposerAttachment(
            id: "attachment-preview-image",
            kind: .image,
            filename: "chat-layout.png",
            mime: "image/png",
            dataURL: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7Z0l8AAAAASUVORK5CYII="
        ),
        OpenCodeComposerAttachment(
            id: "attachment-preview-file",
            kind: .file,
            filename: "feedback.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,VGhlIGNvbXBvc2VyIHNob3VsZCBmZWVsIG1vcmUgbGlrZSBpTWVzc2FnZS4="
        ),
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
                mime: nil,
                filename: nil,
                url: nil,
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
                mime: nil,
                filename: nil,
                url: nil,
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
                mime: nil,
                filename: nil,
                url: nil,
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
                        filePath: nil,
                        name: nil,
                        path: nil,
                        query: nil,
                        pattern: nil,
                        subagentType: nil,
                        url: nil
                    ),
                    output: "Build Succeeded",
                    metadata: OpenCodeToolMetadata(output: "Build Succeeded", description: "Simulator build", exit: 0, filediff: nil, loaded: nil, sessionId: nil, truncated: false, files: nil)
                ),
                text: nil
            ),
            OpenCodePart(
                id: "part-preview-assistant-text",
                messageID: "message-preview-assistant",
                sessionID: primarySession.id,
                type: "text",
                mime: nil,
                filename: nil,
                url: nil,
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
                mime: nil,
                filename: nil,
                url: nil,
                reason: "completed",
                tool: "todowrite",
                callID: "call-preview-todo",
                state: OpenCodeToolState(
                    status: "completed",
                    title: "Update task list",
                    error: nil,
                    input: OpenCodeToolInput(command: nil, description: "Track preview work", filePath: nil, name: nil, path: nil, query: nil, pattern: nil, subagentType: "explore", url: nil),
                    output: nil,
                    metadata: nil
                ),
                text: "[{\"content\":\"Audit the top-level views\",\"status\":\"pending\",\"priority\":\"high\"}]"
            )
        ]
    )

    static let compactionBoundaryMessage = OpenCodeMessageEnvelope(
        info: OpenCodeMessage(
            id: "message-preview-compaction-user",
            role: "user",
            sessionID: primarySession.id,
            time: OpenCodeMessageTime(created: 1_711_236_090, completed: nil),
            agent: "build",
            model: OpenCodeMessageModelReference(providerID: "openai", modelID: "gpt-5.4", variant: "balanced")
        ),
        parts: [
            OpenCodePart(
                id: "part-preview-compaction",
                messageID: "message-preview-compaction-user",
                sessionID: primarySession.id,
                type: "compaction",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: nil,
                auto: false,
                overflow: nil,
                tailStartID: nil
            )
        ]
    )

    static let compactionSummaryMessage = OpenCodeMessageEnvelope(
        info: OpenCodeMessage(
            id: "message-preview-compaction-summary",
            role: "assistant",
            sessionID: primarySession.id,
            time: OpenCodeMessageTime(created: 1_711_236_091, completed: 1_711_236_120),
            agent: "compaction",
            model: nil,
            parentID: compactionBoundaryMessage.id,
            mode: "compaction",
            summary: true,
            finish: "stop",
            providerID: "openai",
            modelID: "gpt-5.4"
        ),
        parts: [
            OpenCodePart(
                id: "part-preview-compaction-summary-text",
                messageID: "message-preview-compaction-summary",
                sessionID: primarySession.id,
                type: "text",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: """
                ## Goal

                Tighten the native iOS chat experience while keeping behavior aligned with upstream OpenCode.

                ## Accomplished

                - Added preview data and grouped tool activity rows.
                - Verified todo updates should stay visible but disappear when complete.
                - Identified compaction summaries as internal context rather than normal assistant replies.

                ## Relevant files / directories

                - OpenCodeIOSClient/Views/Chat
                - OpenCodeIOSClient/Models/OpenCodeModels.swift
                """
            )
        ]
    )

    static let messages = [userMessage, assistantMessage, todoMessage, compactionBoundaryMessage, compactionSummaryMessage]

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
                    let placeholderPart = OpenCodePart(id: partID, messageID: messageID, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: delta)
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

struct ForkSessionRequest: Encodable {
    let messageID: String?
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
    let mime: String?
    let filename: String?
    let url: String?
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
