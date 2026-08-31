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

struct HealthResponse: Codable, Sendable {
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
    var time: OpenCodeMessageTime? = nil

    var isRootSession: Bool {
        parentID == nil
    }

    var isArchived: Bool {
        time?.archived != nil
    }

    var isGlobalScopeSession: Bool {
        if projectID == "global" { return true }
        guard let directory, !directory.isEmpty else { return true }
        return directory == "/"
    }

    var defaultGeneratedTitleDisplayName: String? {
        guard let title else { return nil }
        if title.range(of: #"^New session - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil {
            return String(localized: "New session")
        }
        if title.range(of: #"^Child session - \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#, options: .regularExpression) != nil {
            return String(localized: "Child session")
        }
        return nil
    }

    var isDefaultGeneratedTitle: Bool {
        defaultGeneratedTitleDisplayName != nil
    }

    func displayTitle(fallback: String = String(localized: "Untitled Session")) -> String {
        if let defaultGeneratedTitleDisplayName { return defaultGeneratedTitleDisplayName }
        if let title, !title.isEmpty { return title }
        return fallback
    }

    func merged(with incoming: OpenCodeSession) -> OpenCodeSession {
        var session = OpenCodeSession(
            id: incoming.id,
            title: incoming.title ?? title,
            workspaceID: incoming.workspaceID ?? workspaceID,
            directory: incoming.directory ?? directory,
            projectID: incoming.projectID ?? projectID,
            parentID: incoming.parentID ?? parentID
        )
        session.time = incoming.time ?? time
        return session
    }
}

struct OpenCodeAction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var commandName: String
    var iconName: String

    init(id: UUID = UUID(), commandName: String, iconName: String) {
        self.id = id
        self.commandName = commandName
        self.iconName = iconName
    }
}

enum OpenCodeActionRunPhase: String, Equatable, Sendable {
    case runningCommand
    case checkingResult

    var title: String {
        switch self {
        case .runningCommand:
            return String(localized: "Running command")
        case .checkingResult:
            return String(localized: "Checking result")
        }
    }
}

struct PendingOpenCodeActionRun: Identifiable, Equatable, Sendable {
    var id: String { sessionID }

    let sessionID: String
    let actionID: UUID
    let commandName: String
    let runID: String
    var phase: OpenCodeActionRunPhase
}

struct OpenCodeProject: Codable, Identifiable, Hashable, Sendable {
    struct Icon: Codable, Hashable, Sendable {
        let url: String?
        let override: String?
        let color: String?

        init(url: String? = nil, override: String? = nil, color: String? = nil) {
            self.url = url
            self.override = override
            self.color = color
        }
    }

    struct Time: Codable, Hashable, Sendable {
        let created: Double?
        let updated: Double?
    }

    let id: String
    let worktree: String
    let vcs: String?
    let name: String?
    let sandboxes: [String]?
    let icon: Icon?
    let time: Time?
}

struct OpenCodeWorkspaceSessionState: Codable, Equatable, Sendable {
    var isLoading = false
    var sessions: [OpenCodeSession] = []
    var sessionTotal = 0
    var limit = 5

    var rootSessions: [OpenCodeSession] {
        sessions.filter(\.isRootSession)
    }

    var hasMore: Bool {
        sessionTotal > rootSessions.count
    }
}

struct OpenCodeWorktree: Codable, Hashable, Sendable {
    let name: String
    let branch: String
    let directory: String
}

enum NewSessionWorkspaceSelection: Codable, Hashable, Sendable {
    case main
    case directory(String)
    case createNew
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

enum OpenCodeFilePreviewSupport {
    static func isImagePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif":
            return true
        default:
            return false
        }
    }

    static func imageData(from content: OpenCodeFileContent) -> Data? {
        let payload: String
        if let comma = content.content.firstIndex(of: ","), content.content[..<comma].contains("base64") {
            payload = String(content.content[content.content.index(after: comma)...])
        } else {
            payload = content.content
        }

        guard content.encoding == "base64" || content.type == "binary" || content.mimeType?.hasPrefix("image/") == true else {
            return nil
        }
        return Data(base64Encoded: payload)
    }
}

struct OpenCodeMessageEnvelope: Codable, Identifiable, Hashable, Sendable {
    var info: OpenCodeMessage
    var parts: [OpenCodePart]

    var id: String { info.id }

    static func local(
        role: String,
        text: String,
        agentMentions: [OpenCodeAgentMention] = [],
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

        parts.append(contentsOf: agentMentions.map { mention in
            OpenCodePart(
                id: OpenCodeIdentifier.part(),
                messageID: messageID,
                sessionID: sessionID,
                type: "agent",
                mime: nil,
                filename: nil,
                name: mention.name,
                url: nil,
                source: OpenCodePartSource(value: mention.content, start: mention.start, end: mention.end, type: nil, text: nil, path: nil),
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: nil
            )
        })

        parts.append(contentsOf: attachments.map { attachment in
            OpenCodePart(
                id: attachment.id,
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

    func upsertingPart(_ part: OpenCodePart) -> OpenCodeMessageEnvelope {
        var copy = self

        if let partID = part.id,
           let index = copy.parts.firstIndex(where: { $0.id == partID }) {
            copy.parts[index] = part
            return copy
        }

        copy.parts.append(part)
        return copy
    }

    func applyingDelta(partID: String, field: String, delta: String) -> OpenCodeMessageEnvelope {
        guard field == "text" else {
            return self
        }

        var copy = self

        guard let index = copy.parts.firstIndex(where: { $0.id == partID }) else {
            return copy
        }

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

    func debugJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func copiedTextContent() -> String? {
        var segments = parts
            .compactMap(\ .text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let errorText = info.error?.displayMessage {
            segments.append("Error: \(errorText)")
        }

        let text = segments.joined(separator: "\n\n")

        return text.isEmpty ? nil : text
    }
}

struct OpenCodeDirectorySyncState: Equatable, Sendable {
    private static let skippedPartTypes: Set<String> = ["patch", "step-start", "step-finish"]

    var messagesBySessionID: [String: [OpenCodeMessage]] = [:]
    var partsByMessageID: [String: [OpenCodePart]] = [:]
    var todosBySessionID: [String: [OpenCodeTodo]] = [:]
    var permissionsBySessionID: [String: [OpenCodePermission]] = [:]
    var questionsBySessionID: [String: [OpenCodeQuestionRequest]] = [:]
    var sessionStatusesBySessionID: [String: String] = [:]
    var sessionDiffsBySessionID: [String: [OpenCodeVCSFileDiff]] = [:]

    mutating func replaceMessages(_ envelopes: [OpenCodeMessageEnvelope], forSessionID sessionID: String) {
        let previousMessageIDs = Set(messagesBySessionID[sessionID]?.map(\.id) ?? [])
        var envelopeByID: [String: OpenCodeMessageEnvelope] = [:]
        for envelope in envelopes {
            envelopeByID[envelope.info.id] = envelope
        }
        let canonicalEnvelopes = envelopeByID.values.sorted {
            OpenCodeMessage.isOrderedBefore($0.info, $1.info)
        }
        let canonicalMessageIDs = Set(canonicalEnvelopes.map(\.id))
        for messageID in previousMessageIDs.subtracting(canonicalMessageIDs) {
            partsByMessageID[messageID] = nil
        }

        messagesBySessionID[sessionID] = canonicalEnvelopes.map(\.info)
        for envelope in canonicalEnvelopes {
            let filteredParts = envelope.parts.filter { !Self.skippedPartTypes.contains($0.type) }
            var parts: [OpenCodePart] = []
            var partIndexByID: [String: Int] = [:]
            for part in filteredParts {
                guard let partID = part.id else {
                    parts.append(part)
                    continue
                }
                if let index = partIndexByID[partID] {
                    parts[index] = part
                } else {
                    partIndexByID[partID] = parts.count
                    parts.append(part)
                }
            }
            partsByMessageID[envelope.info.id] = parts.isEmpty ? nil : parts
        }
    }

    mutating func appendMessageEnvelope(_ envelope: OpenCodeMessageEnvelope, forSessionID sessionID: String) {
        var messages = messagesBySessionID[sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == envelope.info.id }) {
            messages[index] = envelope.info
        } else {
            messages.append(envelope.info)
        }
        messagesBySessionID[sessionID] = messages

        let parts = envelope.parts.filter { !Self.skippedPartTypes.contains($0.type) }
        if !parts.isEmpty {
            partsByMessageID[envelope.info.id] = parts
        }
    }

    mutating func removeMessages(forSessionID sessionID: String) {
        for message in messagesBySessionID[sessionID] ?? [] {
            partsByMessageID[message.id] = nil
        }
        messagesBySessionID[sessionID] = nil
    }

    func messageEnvelopes(forSessionID sessionID: String) -> [OpenCodeMessageEnvelope] {
        let messages = messagesBySessionID[sessionID] ?? []
        return envelopes(from: messages)
    }

    func messageCount(forSessionID sessionID: String) -> Int {
        messagesBySessionID[sessionID]?.count ?? 0
    }

    func userMessageCount(forSessionID sessionID: String) -> Int {
        messagesBySessionID[sessionID]?.reduce(into: 0) { count, message in
            if (message.role ?? "").lowercased() == "user" {
                count += 1
            }
        } ?? 0
    }

    func messageCountIncludingLatestUserRounds(
        _ roundCount: Int,
        fallbackMessageCount: Int,
        forSessionID sessionID: String
    ) -> Int {
        let messages = messagesBySessionID[sessionID] ?? []
        guard !messages.isEmpty else { return 0 }
        guard roundCount > 0 else { return min(messages.count, max(0, fallbackMessageCount)) }

        var remainingRounds = roundCount
        var oldestUserIndex: Int?
        for index in messages.indices.reversed() where (messages[index].role ?? "").lowercased() == "user" {
            oldestUserIndex = index
            remainingRounds -= 1
            if remainingRounds == 0 {
                return messages.count - index
            }
        }

        if let oldestUserIndex {
            return messages.count - oldestUserIndex
        }
        return min(messages.count, max(0, fallbackMessageCount))
    }

    func messageEnvelopes(forSessionID sessionID: String, suffix count: Int) -> [OpenCodeMessageEnvelope] {
        guard count > 0 else { return [] }
        let messages = messagesBySessionID[sessionID] ?? []
        return envelopes(from: messages.suffix(count))
    }

    func latestUserMessageEnvelope(
        beforeSuffixCount suffixCount: Int,
        forSessionID sessionID: String
    ) -> OpenCodeMessageEnvelope? {
        let messages = messagesBySessionID[sessionID] ?? []
        let visibleCount = min(messages.count, max(0, suffixCount))
        let hiddenMessages = messages.dropLast(visibleCount)
        guard let message = hiddenMessages.last(where: {
            ($0.role ?? "").lowercased() == "user"
        }) else { return nil }
        return OpenCodeMessageEnvelope(info: message, parts: partsByMessageID[message.id] ?? [])
    }

    private func envelopes(from messages: some Sequence<OpenCodeMessage>) -> [OpenCodeMessageEnvelope] {
        messages.map { message in
            OpenCodeMessageEnvelope(info: message, parts: partsByMessageID[message.id] ?? [])
        }
    }

    mutating func applyMessageUpdated(_ message: OpenCodeMessage) -> Bool {
        guard let sessionID = message.sessionID else { return false }
        var messages = messagesBySessionID[sessionID] ?? []
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        messagesBySessionID[sessionID] = messages.sorted(by: OpenCodeMessage.isOrderedBefore)
        return true
    }

    mutating func applyPartUpdated(_ rawPart: OpenCodePart) -> Bool {
        guard !Self.skippedPartTypes.contains(rawPart.type) else { return false }
        guard let messageID = rawPart.messageID else { return false }

        var parts = partsByMessageID[messageID] ?? []
        if let partID = rawPart.id,
           let index = parts.firstIndex(where: { $0.id == partID }) {
            parts[index] = mergedPartUpdate(rawPart, existing: parts[index])
        } else {
            // Preserve live part arrival order. On-device streaming has been
            // validated against this behavior; sorting by part id can move the
            // active text part and prevent visible streaming from updating.
            parts.append(rawPart)
        }
        partsByMessageID[messageID] = parts
        materializeAssistantShellIfNeeded(for: rawPart)
        return true
    }

    private func mergedPartUpdate(_ rawPart: OpenCodePart, existing: OpenCodePart) -> OpenCodePart {
        guard let existingText = existing.text,
              !existingText.isEmpty else {
            return rawPart
        }

        guard let updatedText = rawPart.text,
              !updatedText.isEmpty else {
            var merged = rawPart
            merged.text = existingText
            return merged
        }

        guard existingText.hasPrefix(updatedText) else {
            return rawPart
        }

        var merged = rawPart
        merged.text = existingText
        return merged
    }

    mutating func applyPartDelta(messageID: String, partID: String, field: String, delta: String) -> Bool {
        guard field == "text" else { return false }
        guard var parts = partsByMessageID[messageID],
              let index = parts.firstIndex(where: { $0.id == partID }) else {
            return false
        }

        var part = parts[index]
        part.text = (part.text ?? "") + delta
        parts[index] = part
        partsByMessageID[messageID] = parts
        materializeAssistantShellIfNeeded(for: part)
        return true
    }

    private mutating func materializeAssistantShellIfNeeded(for part: OpenCodePart) {
        guard let sessionID = part.sessionID,
              let messageID = part.messageID else { return }

        var messages = messagesBySessionID[sessionID] ?? []
        guard !messages.contains(where: { $0.id == messageID }) else { return }

        let parentID = messages
            .filter { ($0.role ?? "").lowercased() == "user" }
            .max(by: OpenCodeMessage.isOrderedBefore)?
            .id
        messages.append(
            OpenCodeMessage(
                id: messageID,
                role: "assistant",
                sessionID: sessionID,
                time: nil,
                agent: nil,
                model: nil,
                parentID: parentID
            )
        )
        messagesBySessionID[sessionID] = messages.sorted(by: OpenCodeMessage.isOrderedBefore)
    }

    mutating func removeMessage(sessionID: String, messageID: String) -> Bool {
        guard var messages = messagesBySessionID[sessionID] else { return false }
        messages.removeAll { $0.id == messageID }
        messagesBySessionID[sessionID] = messages
        partsByMessageID[messageID] = nil
        return true
    }

    mutating func removePart(messageID: String, partID: String) -> Bool {
        guard var parts = partsByMessageID[messageID] else { return false }
        let oldCount = parts.count
        parts.removeAll { $0.id == partID }
        guard parts.count != oldCount else { return false }
        partsByMessageID[messageID] = parts.isEmpty ? nil : parts
        return true
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
    let error: OpenCodeSessionErrorPayload?
    let cost: Double?
    let tokens: OpenCodeMessageTokens?
    let system: String?

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
        case error
        case cost
        case tokens
        case system
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
        modelID: String? = nil,
        error: OpenCodeSessionErrorPayload? = nil,
        cost: Double? = nil,
        tokens: OpenCodeMessageTokens? = nil,
        system: String? = nil
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
        self.error = error
        self.cost = cost
        self.tokens = tokens
        self.system = system
    }

    static func isOrderedBefore(_ lhs: OpenCodeMessage, _ rhs: OpenCodeMessage) -> Bool {
        // Server messages have creation times; timestamp-free optimistic messages stay at the tail.
        switch (lhs.time?.created, rhs.time?.created) {
        case let (lhsCreated?, rhsCreated?) where lhsCreated != rhsCreated:
            return lhsCreated < rhsCreated
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
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
        error = try container.decodeIfPresent(OpenCodeSessionErrorPayload.self, forKey: .error)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try container.decodeIfPresent(OpenCodeMessageTokens.self, forKey: .tokens)
        system = try container.decodeIfPresent(String.self, forKey: .system)
    }
}

struct OpenCodeMessageModelReference: Codable, Hashable, Sendable {
    let providerID: String
    let modelID: String
    let variant: String?

    enum CodingKeys: String, CodingKey {
        case providerID
        case modelID
        case id
        case variant
    }

    init(providerID: String, modelID: String, variant: String?) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(String.self, forKey: .providerID)
        if let modelID = try container.decodeIfPresent(String.self, forKey: .modelID) {
            self.modelID = modelID
        } else if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            modelID = id
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.modelID,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected modelID or id")
            )
        }
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providerID, forKey: .providerID)
        try container.encode(modelID, forKey: .modelID)
        try container.encodeIfPresent(variant, forKey: .variant)
    }
}

struct OpenCodeMessageTime: Codable, Hashable, Sendable {
    let created: Double?
    let updated: Double?
    let completed: Double?
    let archived: Double?

    init(created: Double? = nil, updated: Double? = nil, completed: Double? = nil, archived: Double? = nil) {
        self.created = created
        self.updated = updated
        self.completed = completed
        self.archived = archived
    }
}

struct OpenCodeMessageTokenCache: Codable, Hashable, Sendable {
    let read: Int
    let write: Int

    enum CodingKeys: String, CodingKey {
        case read
        case write
    }

    init(read: Int = 0, write: Int = 0) {
        self.read = read
        self.write = write
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = Self.decodeInt(container, forKey: .read)
        write = Self.decodeInt(container, forKey: .write)
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        return 0
    }
}

struct OpenCodeMessageTokens: Codable, Hashable, Sendable {
    let total: Int?
    let input: Int
    let output: Int
    let reasoning: Int
    let cache: OpenCodeMessageTokenCache

    enum CodingKeys: String, CodingKey {
        case total
        case input
        case output
        case reasoning
        case cache
    }

    init(total: Int? = nil, input: Int = 0, output: Int = 0, reasoning: Int = 0, cache: OpenCodeMessageTokenCache = OpenCodeMessageTokenCache()) {
        self.total = total
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cache = cache
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = Self.decodeOptionalInt(container, forKey: .total)
        input = Self.decodeInt(container, forKey: .input)
        output = Self.decodeInt(container, forKey: .output)
        reasoning = Self.decodeInt(container, forKey: .reasoning)
        cache = (try? container.decode(OpenCodeMessageTokenCache.self, forKey: .cache)) ?? OpenCodeMessageTokenCache()
    }

    var computedTotal: Int {
        input + output + reasoning + cache.read + cache.write
    }

    private static func decodeInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int {
        decodeOptionalInt(container, forKey: key) ?? 0
    }

    private static func decodeOptionalInt(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
        return nil
    }
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
    let error: OpenCodeSessionErrorPayload?
    let cost: Double?
    let tokens: OpenCodeMessageTokens?
    let system: String?
    let command: String?
    let args: [String]?
    let cwd: String?
    let ptyStatus: String?
    let pid: Int?

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
        case error
        case cost
        case tokens
        case system
        case command
        case args
        case cwd
        case ptyStatus = "status"
        case pid
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
        error = message.error
        cost = message.cost
        tokens = message.tokens
        system = message.system
        command = nil
        args = nil
        cwd = nil
        ptyStatus = nil
        pid = nil
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
            modelID: modelID,
            error: error,
            cost: cost,
            tokens: tokens,
            system: system
        )
    }

    func asSession() -> OpenCodeSession {
        var session = OpenCodeSession(id: id, title: title, workspaceID: nil, directory: directory, projectID: projectID, parentID: parentID)
        session.time = time
        return session
    }

    func asPTY() -> OpenCodePTY? {
        guard let title, let command, let cwd, let ptyStatus, let pid else { return nil }
        return OpenCodePTY(
            id: id,
            title: title,
            command: command,
            args: args ?? [],
            cwd: cwd,
            status: ptyStatus,
            pid: pid
        )
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
        error = try container.decodeIfPresent(OpenCodeSessionErrorPayload.self, forKey: .error)
        cost = try container.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try container.decodeIfPresent(OpenCodeMessageTokens.self, forKey: .tokens)
        system = try container.decodeIfPresent(String.self, forKey: .system)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        ptyStatus = try container.decodeIfPresent(String.self, forKey: .ptyStatus)
        pid = try container.decodeIfPresent(Int.self, forKey: .pid)
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
    let temperature: Bool?
    let attachment: Bool?
    let toolcall: Bool?

    init(reasoning: Bool, temperature: Bool? = nil, attachment: Bool? = nil, toolcall: Bool? = nil) {
        self.reasoning = reasoning
        self.temperature = temperature
        self.attachment = attachment
        self.toolcall = toolcall
    }
}

struct OpenCodeModelLimit: Codable, Hashable, Sendable {
    let context: Int?
    let input: Int?
    let output: Int?

    init(context: Int? = nil, input: Int? = nil, output: Int? = nil) {
        self.context = context
        self.input = input
        self.output = output
    }
}

struct OpenCodeModelCostCache: Codable, Hashable, Sendable {
    let read: Double?
    let write: Double?
}

struct OpenCodeModelCost: Codable, Hashable, Sendable {
    let input: Double?
    let output: Double?
    let cache: OpenCodeModelCostCache?
}

struct OpenCodeModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let providerID: String
    let name: String
    let capabilities: OpenCodeModelCapabilities
    let variants: [String: OpenCodeJSONValue]?
    let limit: OpenCodeModelLimit?
    let family: String?
    let status: String?
    let releaseDate: String?
    let cost: OpenCodeModelCost?

    init(
        id: String,
        providerID: String,
        name: String,
        capabilities: OpenCodeModelCapabilities,
        variants: [String: OpenCodeJSONValue]? = nil,
        limit: OpenCodeModelLimit? = nil,
        family: String? = nil,
        status: String? = nil,
        releaseDate: String? = nil,
        cost: OpenCodeModelCost? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.capabilities = capabilities
        self.variants = variants
        self.limit = limit
        self.family = family
        self.status = status
        self.releaseDate = releaseDate
        self.cost = cost
    }

    enum CodingKeys: String, CodingKey {
        case id
        case providerID
        case name
        case capabilities
        case variants
        case limit
        case family
        case status
        case releaseDate = "release_date"
        case cost
    }
}

struct OpenCodeProvider: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let models: [String: OpenCodeModel]
    let source: String?
    let env: [String]?
    let key: String?
    let options: [String: OpenCodeJSONValue]?

    init(
        id: String,
        name: String,
        models: [String: OpenCodeModel],
        source: String? = nil,
        env: [String]? = nil,
        key: String? = nil,
        options: [String: OpenCodeJSONValue]? = nil
    ) {
        self.id = id
        self.name = name
        self.models = models
        self.source = source
        self.env = env
        self.key = key
        self.options = options
    }
}

struct OpenCodeSessionContextMetrics: Hashable, Sendable {
    let totalCost: Double
    let messageCount: Int
    let userMessageCount: Int
    let assistantMessageCount: Int
    let context: OpenCodeSessionContextSnapshot?
    let breakdown: [OpenCodeSessionContextBreakdownSegment]
    let systemPrompt: String?
}

struct OpenCodeSessionContextSnapshot: Hashable, Sendable {
    let messageID: String
    let messageCreatedAt: Double?
    let providerLabel: String
    let modelLabel: String
    let limit: Int?
    let input: Int
    let output: Int
    let reasoning: Int
    let cacheRead: Int
    let cacheWrite: Int
    let total: Int
    let usage: Int?
}

struct OpenCodeSessionContextBreakdownSegment: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case system
        case user
        case assistant
        case tool
        case other
    }

    let kind: Kind
    let tokens: Int
    let percent: Double

    var id: String { kind.rawValue }
}

enum OpenCodeSessionContextMetricsBuilder {
    static func metrics(messages: [OpenCodeMessageEnvelope], providers: [OpenCodeProvider]) -> OpenCodeSessionContextMetrics {
        let totalCost = messages.reduce(0) { sum, message in
            guard message.info.role?.lowercased() == "assistant" else { return sum }
            return sum + (message.info.cost ?? 0)
        }
        let messageCount = messages.count
        let userMessageCount = messages.filter { $0.info.role?.lowercased() == "user" }.count
        let assistantMessageCount = messages.filter { $0.info.role?.lowercased() == "assistant" }.count
        let systemPrompt = latestSystemPrompt(in: messages)

        guard let message = latestAssistantMessageWithTokens(in: messages),
              let tokens = message.info.tokens else {
            return OpenCodeSessionContextMetrics(
                totalCost: totalCost,
                messageCount: messageCount,
                userMessageCount: userMessageCount,
                assistantMessageCount: assistantMessageCount,
                context: nil,
                breakdown: [],
                systemPrompt: systemPrompt
            )
        }

        let modelReference = effectiveModelReference(for: message.info)
        let provider = providers.first { $0.id == modelReference.providerID }
        let model = modelReference.modelID.flatMap { provider?.models[$0] }
        let limit = model?.limit?.context
        let total = tokens.computedTotal
        let usage = limit.flatMap { limit -> Int? in
            guard limit > 0 else { return nil }
            return Int((Double(total) / Double(limit) * 100).rounded())
        }
        let context = OpenCodeSessionContextSnapshot(
            messageID: message.id,
            messageCreatedAt: message.info.time?.created,
            providerLabel: provider?.name ?? modelReference.providerID ?? "—",
            modelLabel: model?.name ?? modelReference.modelID ?? "—",
            limit: limit,
            input: tokens.input,
            output: tokens.output,
            reasoning: tokens.reasoning,
            cacheRead: tokens.cache.read,
            cacheWrite: tokens.cache.write,
            total: total,
            usage: usage
        )

        return OpenCodeSessionContextMetrics(
            totalCost: totalCost,
            messageCount: messageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            context: context,
            breakdown: estimateBreakdown(messages: messages, input: tokens.input, systemPrompt: systemPrompt),
            systemPrompt: systemPrompt
        )
    }

    private static func latestAssistantMessageWithTokens(in messages: [OpenCodeMessageEnvelope]) -> OpenCodeMessageEnvelope? {
        for message in messages.reversed() {
            guard message.info.role?.lowercased() == "assistant" else { continue }
            guard let tokens = message.info.tokens, tokens.computedTotal > 0 else { continue }
            return message
        }
        return nil
    }

    private static func effectiveModelReference(for message: OpenCodeMessage) -> (providerID: String?, modelID: String?) {
        let providerID = message.model?.providerID ?? message.providerID
        let modelID = message.model?.modelID ?? message.modelID
        return (providerID, modelID)
    }

    private static func latestSystemPrompt(in messages: [OpenCodeMessageEnvelope]) -> String? {
        for message in messages.reversed() {
            guard message.info.role?.lowercased() == "user" else { continue }
            let trimmed = message.info.system?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func estimateBreakdown(messages: [OpenCodeMessageEnvelope], input: Int, systemPrompt: String?) -> [OpenCodeSessionContextBreakdownSegment] {
        guard input > 0 else { return [] }

        var counts = (system: systemPrompt?.count ?? 0, user: 0, assistant: 0, tool: 0)
        for message in messages {
            switch message.info.role?.lowercased() {
            case "user":
                counts.user += message.parts.reduce(0) { $0 + userCharacterCount(for: $1) }
            case "assistant":
                let assistantCounts = message.parts.reduce((assistant: 0, tool: 0)) { partial, part in
                    let next = assistantCharacterCount(for: part)
                    return (partial.assistant + next.assistant, partial.tool + next.tool)
                }
                counts.assistant += assistantCounts.assistant
                counts.tool += assistantCounts.tool
            default:
                break
            }
        }

        var tokens = (
            system: estimateTokens(forCharacters: counts.system),
            user: estimateTokens(forCharacters: counts.user),
            assistant: estimateTokens(forCharacters: counts.assistant),
            tool: estimateTokens(forCharacters: counts.tool)
        )
        let estimated = tokens.system + tokens.user + tokens.assistant + tokens.tool
        if estimated > input, estimated > 0 {
            let scale = Double(input) / Double(estimated)
            tokens = (
                system: Int(floor(Double(tokens.system) * scale)),
                user: Int(floor(Double(tokens.user) * scale)),
                assistant: Int(floor(Double(tokens.assistant) * scale)),
                tool: Int(floor(Double(tokens.tool) * scale))
            )
        }

        let known = tokens.system + tokens.user + tokens.assistant + tokens.tool
        return buildBreakdownSegments(
            tokens: [
                .system: tokens.system,
                .user: tokens.user,
                .assistant: tokens.assistant,
                .tool: tokens.tool,
                .other: max(0, input - known)
            ],
            input: input
        )
    }

    private static func buildBreakdownSegments(tokens: [OpenCodeSessionContextBreakdownSegment.Kind: Int], input: Int) -> [OpenCodeSessionContextBreakdownSegment] {
        let kinds: [OpenCodeSessionContextBreakdownSegment.Kind] = [.system, .user, .assistant, .tool, .other]
        return kinds
            .compactMap { kind in
                let count = tokens[kind] ?? 0
                guard count > 0 else { return nil }
                let percent = (Double(count) / Double(input) * 1000).rounded() / 10
                return OpenCodeSessionContextBreakdownSegment(kind: kind, tokens: count, percent: percent)
            }
    }

    private static func userCharacterCount(for part: OpenCodePart) -> Int {
        switch part.type {
        case "text":
            return part.text?.count ?? 0
        case "file":
            return part.source?.text?.value.count ?? part.source?.value?.count ?? 0
        case "agent":
            return part.source?.value?.count ?? 0
        default:
            return 0
        }
    }

    private static func assistantCharacterCount(for part: OpenCodePart) -> (assistant: Int, tool: Int) {
        switch part.type {
        case "text", "reasoning":
            return (part.text?.count ?? 0, 0)
        case "tool":
            let input = (part.state?.input?.estimatedKeyCount ?? 0) * 16
            let status = part.state?.status?.lowercased()
            if status == "pending" {
                return (0, input + (part.state?.raw?.count ?? 0))
            }
            if status == "completed" {
                return (0, input + (part.state?.output?.count ?? 0))
            }
            if status == "error" {
                return (0, input + (part.state?.error?.count ?? 0))
            }
            return (0, input)
        default:
            return (0, 0)
        }
    }

    private static func estimateTokens(forCharacters count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(ceil(Double(count) / 4))
    }
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

extension OpenCodeCommand {
    enum CodingKeys: String, CodingKey {
        case name
        case description
        case agent
        case model
        case source
        case template
        case subtask
        case hints
    }

    // opencode returns `template: {}` (an object) for MCP-sourced commands. Decode it
    // leniently so one such command can't fail the entire `/command` response array.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        template = (try? container.decode(String.self, forKey: .template)) ?? ""
        subtask = try container.decodeIfPresent(Bool.self, forKey: .subtask)
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
    }
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
    var agentMentions: [OpenCodeAgentMention]

    init(text: String, agentMentions: [OpenCodeAgentMention] = []) {
        self.text = text
        self.agentMentions = agentMentions
    }

    enum CodingKeys: String, CodingKey {
        case text
        case agentMentions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        agentMentions = try container.decodeIfPresent([OpenCodeAgentMention].self, forKey: .agentMentions) ?? []
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agentMentions.isEmpty
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

struct OpenCodeProviderListResponse: Codable, Hashable, Sendable {
    let all: [OpenCodeProvider]
    let connected: [String]
    let `default`: [String: String]
}

struct OpenCodeProviderAuthMethod: Codable, Hashable, Sendable, Identifiable {
    struct Prompt: Codable, Hashable, Sendable, Identifiable {
        struct Condition: Codable, Hashable, Sendable {
            let key: String
            let op: String
            let value: String
        }

        struct Option: Codable, Hashable, Sendable, Identifiable {
            let label: String
            let value: String
            let hint: String?

            var id: String { value }
        }

        let type: String
        let key: String
        let message: String
        let placeholder: String?
        let options: [Option]?
        let when: Condition?

        var id: String { key }
    }

    let type: String
    let label: String
    let prompts: [Prompt]?

    var id: String { "\(type):\(label)" }
}

struct OpenCodeProviderAuthAuthorization: Codable, Hashable, Sendable {
    let url: String
    let method: String
    let instructions: String
}

struct OpenCodeProviderConfig: Codable, Hashable, Sendable {
    struct Model: Codable, Hashable, Sendable {
        let name: String?
    }

    let npm: String?
    let name: String?
    let env: [String]?
    let options: [String: OpenCodeJSONValue]?
    let models: [String: Model]?
}

struct OpenCodeGlobalConfigPatch: Encodable, Sendable {
    let provider: [String: OpenCodeProviderConfig]?
    let disabledProviders: [String]?

    enum CodingKeys: String, CodingKey {
        case provider
        case disabledProviders = "disabled_providers"
    }
}

struct OpenCodeResolvedConfig: Decodable, Hashable, Sendable {
    let plugins: [OpenCodeConfiguredPlugin]

    enum CodingKeys: String, CodingKey {
        case plugins = "plugin"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plugins = try container.decodeIfPresent([OpenCodeConfiguredPlugin].self, forKey: .plugins) ?? []
    }
}

struct OpenCodeConfiguredPlugin: Decodable, Hashable, Identifiable, Sendable {
    let specifier: String

    var id: String { specifier }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let specifier = try? container.decode(String.self) {
            self.specifier = specifier
            return
        }

        var tuple = try decoder.unkeyedContainer()
        specifier = try tuple.decode(String.self)
        if !tuple.isAtEnd {
            _ = try tuple.decode(OpenCodeJSONValue.self)
        }
    }
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
            return String(localized: "Connected")
        case "disabled":
            return String(localized: "Disabled")
        case "failed":
            return String(localized: "Failed")
        case "needs_auth":
            return String(localized: "Needs Auth")
        case "needs_client_registration":
            return String(localized: "Needs Registration")
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

enum AppBackendMode: String, Codable, Sendable {
    case none
    case server
    case cachedServer
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
            sandboxes: nil,
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
            return String(localized: "Changes")
        case .tree:
            return String(localized: "Tree")
        }
    }
}

enum OpenCodeVCSDiffMode: String, CaseIterable, Codable, Hashable, Sendable {
    case git
    case branch

    var title: String {
        switch self {
        case .git:
            return String(localized: "Working Tree")
        case .branch:
            return String(localized: "Branch")
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

typealias OpenCodeSnapshotFileDiff = OpenCodeVCSFileDiff

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

struct OpenCodePermission: Codable, Hashable, Identifiable, Sendable {
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
    let name: String?

    init(messageID: String?, callID: String?, name: String? = nil) {
        self.messageID = messageID
        self.callID = callID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
            callID = try container.decodeIfPresent(String.self, forKey: .callID)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            return
        }

        // Some message part events use a top-level `tool` string. Preserve it
        // so live tool cards can render before canonical message hydration.
        name = try? decoder.singleValueContainer().decode(String.self)
        messageID = nil
        callID = nil
    }
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
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

struct OpenCodePartTime: Codable, Hashable, Sendable {
    let start: Double
    let end: Double?

    init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

struct OpenCodePart: Codable, Hashable, Sendable {
    let id: String?
    let messageID: String?
    let sessionID: String?
    let type: String
    let mime: String?
    let filename: String?
    let name: String?
    let url: String?
    let source: OpenCodePartSource?
    let reason: String?
    let tool: String?
    let callID: String?
    let state: OpenCodeToolState?
    var text: String?
    let synthetic: Bool?
    let ignored: Bool?
    let time: OpenCodePartTime?
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
        case name
        case url
        case source
        case reason
        case tool
        case callID
        case state
        case text
        case synthetic
        case ignored
        case time
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
        name: String? = nil,
        url: String?,
        source: OpenCodePartSource? = nil,
        reason: String?,
        tool: String?,
        callID: String?,
        state: OpenCodeToolState?,
        text: String?,
        synthetic: Bool? = nil,
        ignored: Bool? = nil,
        time: OpenCodePartTime? = nil,
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
        self.name = name
        self.url = url
        self.source = source
        self.reason = reason
        self.tool = tool
        self.callID = callID
        self.state = state
        self.text = text
        self.synthetic = synthetic
        self.ignored = ignored
        self.time = time
        self.auto = auto
        self.overflow = overflow
        self.tailStartID = tailStartID
    }

    func applyingEventFallbacks(sessionID: String?, messageID: String?, partID: String?) -> OpenCodePart {
        let isToolLikeTextPart = type == "text" && (tool != nil || callID != nil || state != nil)
        let isReasoningLikeTextPart = type == "text" && reason?.lowercased().contains("reasoning") == true
        return OpenCodePart(
            id: id ?? partID,
            messageID: self.messageID ?? messageID,
            sessionID: self.sessionID ?? sessionID,
            type: isToolLikeTextPart ? "tool" : (isReasoningLikeTextPart ? "reasoning" : type),
            mime: mime,
            filename: filename,
            name: name,
            url: url,
            source: source,
            reason: reason,
            tool: tool,
            callID: callID,
            state: state,
            text: isToolLikeTextPart ? nil : text,
            synthetic: synthetic,
            ignored: ignored,
            time: time,
            auto: auto,
            overflow: overflow,
            tailStartID: tailStartID
        )
    }

    var isCompaction: Bool {
        type == "compaction"
    }
}

struct OpenCodePartSource: Codable, Hashable, Sendable {
    let value: String?
    let start: Int?
    let end: Int?
    let type: String?
    let text: OpenCodePartSourceText?
    let path: String?
}

struct OpenCodePartSourceText: Codable, Hashable, Sendable {
    let value: String
    let start: Int
    let end: Int
}

struct OpenCodeAgentMention: Codable, Hashable, Sendable, Identifiable {
    let name: String
    let content: String
    let start: Int
    let end: Int

    var id: String { "\(name):\(start):\(end):\(content)" }

    func shifted(by offset: Int) -> OpenCodeAgentMention? {
        let nextStart = start + offset
        let nextEnd = end + offset
        guard nextStart >= 0, nextEnd >= nextStart else { return nil }
        return OpenCodeAgentMention(name: name, content: content, start: nextStart, end: nextEnd)
    }

    static func reconciled(_ mentions: [OpenCodeAgentMention], in text: String) -> [OpenCodeAgentMention] {
        var searchStart = text.startIndex
        var result: [OpenCodeAgentMention] = []
        for mention in mentions.sorted(by: { $0.start < $1.start }) {
            guard let range = text.range(of: mention.content, range: searchStart ..< text.endIndex) else { continue }
            let start = text.utf16Offset(of: range.lowerBound)
            let end = text.utf16Offset(of: range.upperBound)
            result.append(OpenCodeAgentMention(name: mention.name, content: mention.content, start: start, end: end))
            searchStart = range.upperBound
        }
        return result
    }

    static func trimmingTextAndMentions(
        text: String,
        mentions: [OpenCodeAgentMention]
    ) -> (text: String, mentions: [OpenCodeAgentMention]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (trimmed, []) }

        let firstContentIndex = text.firstIndex { !$0.isWhitespace } ?? text.startIndex
        let leadingOffset = text.utf16Offset(of: firstContentIndex)
        let shifted = mentions.compactMap { $0.shifted(by: -leadingOffset) }
        return (trimmed, reconciled(shifted, in: trimmed))
    }
}

extension String {
    func utf16Offset(of index: String.Index) -> Int {
        utf16.distance(from: utf16.startIndex, to: index.samePosition(in: utf16) ?? utf16.endIndex)
    }

    func rangeFromUTF16Offsets(start: Int, end: Int) -> Range<String.Index>? {
        guard start >= 0, end >= start,
              let utf16Start = utf16.index(utf16.startIndex, offsetBy: start, limitedBy: utf16.endIndex),
              let utf16End = utf16.index(utf16.startIndex, offsetBy: end, limitedBy: utf16.endIndex),
              let stringStart = String.Index(utf16Start, within: self),
              let stringEnd = String.Index(utf16End, within: self) else {
            return nil
        }
        return stringStart ..< stringEnd
    }
}

struct OpenCodeToolState: Codable, Hashable, Sendable {
    let status: String?
    let title: String?
    let error: String?
    let input: OpenCodeToolInput?
    let output: String?
    let metadata: OpenCodeToolMetadata?
    let raw: String?

    init(
        status: String?,
        title: String?,
        error: String?,
        input: OpenCodeToolInput?,
        output: String?,
        metadata: OpenCodeToolMetadata?,
        raw: String? = nil
    ) {
        self.status = status
        self.title = title
        self.error = error
        self.input = input
        self.output = output
        self.metadata = metadata
        self.raw = raw
    }
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
    let clientID: String?
    let toolID: String?
    let arguments: [String: OpenCodeJSONValue]?

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
        case clientID = "client_id"
        case toolID = "tool_id"
        case arguments
    }

    init(
        command: String?,
        description: String?,
        filePath: String?,
        name: String?,
        path: String?,
        query: String?,
        pattern: String?,
        subagentType: String?,
        url: String?,
        clientID: String? = nil,
        toolID: String? = nil,
        arguments: [String: OpenCodeJSONValue]? = nil
    ) {
        self.command = command
        self.description = description
        self.filePath = filePath
        self.name = name
        self.path = path
        self.query = query
        self.pattern = pattern
        self.subagentType = subagentType
        self.url = url
        self.clientID = clientID
        self.toolID = toolID
        self.arguments = arguments
    }

    var estimatedKeyCount: Int {
        let scalarCount = [command, description, filePath, name, path, query, pattern, subagentType, url, clientID, toolID]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .count
        return scalarCount + (arguments?.isEmpty == false ? 1 : 0)
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
    let clientID: String?
    let toolID: String?
    let renderer: String?
    let schemaVersion: Int?
    let payload: OpenCodeJSONValue?

    enum CodingKeys: String, CodingKey {
        case output
        case description
        case exit
        case filediff
        case loaded
        case sessionId
        case truncated
        case files
        case clientID
        case toolID
        case renderer
        case schemaVersion
        case payload
    }

    init(
        output: String?,
        description: String?,
        exit: Int?,
        filediff: OpenCodeJSONValue?,
        loaded: [String]?,
        sessionId: String?,
        truncated: Bool?,
        files: [OpenCodeJSONValue]?,
        clientID: String? = nil,
        toolID: String? = nil,
        renderer: String? = nil,
        schemaVersion: Int? = nil,
        payload: OpenCodeJSONValue? = nil
    ) {
        self.output = output
        self.description = description
        self.exit = exit
        self.filediff = filediff
        self.loaded = loaded
        self.sessionId = sessionId
        self.truncated = truncated
        self.files = files
        self.clientID = clientID
        self.toolID = toolID
        self.renderer = renderer
        self.schemaVersion = schemaVersion
        self.payload = payload
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

    var displayMessage: String? {
        let message = data?.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty {
            return message
        }

        let fallback = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback?.isEmpty == false ? fallback : nil
    }
}

enum OpenCodeTypedEvent: Sendable {
    case projectUpdated(OpenCodeProject)
    case serverInstanceDisposed(directory: String)
    case serverConnected
    case globalDisposed
    case lspUpdated
    case fileEdited(file: String)
    case installationUpdated(version: String)
    case installationUpdateAvailable(version: String)
    case worktreeReady(name: String, branch: String)
    case worktreeFailed(message: String)
    case sessionCreated(OpenCodeSession)
    case sessionUpdated(OpenCodeSession)
    case sessionDeleted(OpenCodeSession)
    case sessionStatus(sessionID: String, status: String)
    case sessionIdle(sessionID: String)
    case sessionError(sessionID: String?, message: String?)
    case sessionDiff(sessionID: String, diff: [OpenCodeSnapshotFileDiff])
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
    case ptyCreated(OpenCodePTY)
    case ptyUpdated(OpenCodePTY)
    case ptyExited(id: String, exitCode: Int)
    case ptyDeleted(id: String)
    case vcsBranchUpdated(branch: String?)
    case fileWatcherUpdated(file: String)
    case unknown(String)

    init?(envelope: OpenCodeEventEnvelope) {
        switch envelope.type {
        case "project.updated":
            guard let data = try? JSONDecoder().decode(OpenCodeProject.self, from: try JSONEncoder().encode(envelope.properties)) else { return nil }
            self = .projectUpdated(data)
        case "server.instance.disposed":
            guard let directory = envelope.properties.directory else { return nil }
            self = .serverInstanceDisposed(directory: directory)
        case "server.connected":
            self = .serverConnected
        case "global.disposed":
            self = .globalDisposed
        case "lsp.updated":
            self = .lspUpdated
        case "file.edited":
            guard let file = envelope.properties.file else { return nil }
            self = .fileEdited(file: file)
        case "installation.updated":
            guard let version = envelope.properties.version else { return nil }
            self = .installationUpdated(version: version)
        case "installation.update-available":
            guard let version = envelope.properties.version else { return nil }
            self = .installationUpdateAvailable(version: version)
        case "worktree.ready":
            guard let name = envelope.properties.name,
                  let branch = envelope.properties.branch else { return nil }
            self = .worktreeReady(name: name, branch: branch)
        case "worktree.failed":
            guard let message = envelope.properties.message else { return nil }
            self = .worktreeFailed(message: message)
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
            self = .sessionDiff(sessionID: sessionID, diff: envelope.properties.diff ?? [])
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
            guard let part = envelope.properties.part ?? envelope.properties.reconstructedPartFromFlatEvent() else { return nil }
            self = .messagePartUpdated(
                part.applyingEventFallbacks(
                    sessionID: envelope.properties.sessionID,
                    messageID: envelope.properties.messageID,
                    partID: envelope.properties.partID
                )
            )
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
        case "pty.created":
            guard let pty = envelope.properties.info?.asPTY() else { return nil }
            self = .ptyCreated(pty)
        case "pty.updated":
            guard let pty = envelope.properties.info?.asPTY() else { return nil }
            self = .ptyUpdated(pty)
        case "pty.exited":
            guard let id = envelope.properties.id,
                  let exitCode = envelope.properties.exitCode else { return nil }
            self = .ptyExited(id: id, exitCode: exitCode)
        case "pty.deleted":
            guard let id = envelope.properties.id else { return nil }
            self = .ptyDeleted(id: id)
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
    let worktree: String?
    let vcs: String?
    let name: String?
    let sandboxes: [String]?
    let icon: OpenCodeProject.Icon?
    let time: OpenCodeProject.Time?
    let sessionID: String?
    let info: OpenCodeEventInfo?
    let part: OpenCodePart?
    let state: OpenCodeToolState?
    let text: String?
    let mime: String?
    let filename: String?
    let url: String?
    let source: OpenCodePartSource?
    let reason: String?
    let status: OpenCodeSessionStatus?
    let todos: [OpenCodeTodo]?
    let diff: [OpenCodeSnapshotFileDiff]?
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
    let directory: String?
    let version: String?
    let exitCode: Int?

    init(
        worktree: String? = nil,
        vcs: String? = nil,
        name: String? = nil,
        sandboxes: [String]? = nil,
        icon: OpenCodeProject.Icon? = nil,
        time: OpenCodeProject.Time? = nil,
        sessionID: String? = nil,
        info: OpenCodeEventInfo? = nil,
        part: OpenCodePart? = nil,
        state: OpenCodeToolState? = nil,
        text: String? = nil,
        mime: String? = nil,
        filename: String? = nil,
        url: String? = nil,
        source: OpenCodePartSource? = nil,
        reason: String? = nil,
        status: OpenCodeSessionStatus? = nil,
        todos: [OpenCodeTodo]? = nil,
        diff: [OpenCodeSnapshotFileDiff]? = nil,
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
        file: String? = nil,
        directory: String? = nil,
        version: String? = nil,
        exitCode: Int? = nil
    ) {
        self.worktree = worktree
        self.vcs = vcs
        self.name = name
        self.sandboxes = sandboxes
        self.icon = icon
        self.time = time
        self.sessionID = sessionID
        self.info = info
        self.part = part
        self.state = state
        self.text = text
        self.mime = mime
        self.filename = filename
        self.url = url
        self.source = source
        self.reason = reason
        self.status = status
        self.todos = todos
        self.diff = diff
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
        self.directory = directory
        self.version = version
        self.exitCode = exitCode
    }

    enum CodingKeys: String, CodingKey {
        case worktree
        case vcs
        case name
        case sandboxes
        case icon
        case time
        case sessionID
        case info
        case part
        case state
        case text
        case mime
        case filename
        case url
        case source
        case reason
        case status
        case todos
        case diff
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
        case directory
        case version
        case exitCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        worktree = Self.decode(String.self, from: container, forKey: .worktree)
        vcs = Self.decode(String.self, from: container, forKey: .vcs)
        name = Self.decode(String.self, from: container, forKey: .name)
        sandboxes = Self.decode([String].self, from: container, forKey: .sandboxes)
        icon = Self.decode(OpenCodeProject.Icon.self, from: container, forKey: .icon)
        time = Self.decode(OpenCodeProject.Time.self, from: container, forKey: .time)
        sessionID = Self.decode(String.self, from: container, forKey: .sessionID)
        info = Self.decode(OpenCodeEventInfo.self, from: container, forKey: .info)
        part = Self.decode(OpenCodePart.self, from: container, forKey: .part)
        state = Self.decode(OpenCodeToolState.self, from: container, forKey: .state)
        text = Self.decode(String.self, from: container, forKey: .text)
        mime = Self.decode(String.self, from: container, forKey: .mime)
        filename = Self.decode(String.self, from: container, forKey: .filename)
        url = Self.decode(String.self, from: container, forKey: .url)
        source = Self.decode(OpenCodePartSource.self, from: container, forKey: .source)
        reason = Self.decode(String.self, from: container, forKey: .reason)
        status = Self.decode(OpenCodeSessionStatus.self, from: container, forKey: .status)
        todos = Self.decode([OpenCodeTodo].self, from: container, forKey: .todos)
        diff = Self.decode([OpenCodeSnapshotFileDiff].self, from: container, forKey: .diff)
        messageID = Self.decode(String.self, from: container, forKey: .messageID)
        partID = Self.decode(String.self, from: container, forKey: .partID)
        field = Self.decode(String.self, from: container, forKey: .field)
        delta = Self.decode(String.self, from: container, forKey: .delta)
        id = Self.decode(String.self, from: container, forKey: .id)
        permission = Self.decode(String.self, from: container, forKey: .permission)
        permissionType = Self.decode(String.self, from: container, forKey: .permissionType)
        patterns = Self.decode([String].self, from: container, forKey: .patterns)
        pattern = Self.decode(OpenCodePermissionPattern.self, from: container, forKey: .pattern)
        always = Self.decode([String].self, from: container, forKey: .always)
        tool = Self.decode(OpenCodePermissionTool.self, from: container, forKey: .tool)
        callID = Self.decode(String.self, from: container, forKey: .callID)
        title = Self.decode(String.self, from: container, forKey: .title)
        metadata = Self.decode([String: OpenCodeJSONValue].self, from: container, forKey: .metadata)
        questions = Self.decode([OpenCodeQuestion].self, from: container, forKey: .questions)
        requestID = Self.decode(String.self, from: container, forKey: .requestID)
        permissionID = Self.decode(String.self, from: container, forKey: .permissionID)
        response = Self.decode(String.self, from: container, forKey: .response)
        reply = Self.decode(String.self, from: container, forKey: .reply)
        message = Self.decode(String.self, from: container, forKey: .message)
        error = Self.decode(OpenCodeSessionErrorPayload.self, from: container, forKey: .error)
        branch = Self.decode(String.self, from: container, forKey: .branch)
        file = Self.decode(String.self, from: container, forKey: .file)
        directory = Self.decode(String.self, from: container, forKey: .directory)
        version = Self.decode(String.self, from: container, forKey: .version)
        exitCode = Self.decode(Int.self, from: container, forKey: .exitCode)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> T? {
        try? container.decodeIfPresent(type, forKey: key)
    }

    func reconstructedPartFromFlatEvent() -> OpenCodePart? {
        let toolName = tool?.name
        let inferredType: String?
        if let permissionType, !permissionType.isEmpty {
            inferredType = permissionType
        } else if toolName != nil || callID != nil || tool?.callID != nil || state != nil {
            inferredType = "tool"
        } else if text != nil {
            inferredType = "text"
        } else {
            inferredType = nil
        }

        guard let type = inferredType else { return nil }

        return OpenCodePart(
            id: partID ?? id,
            messageID: messageID ?? tool?.messageID,
            sessionID: sessionID,
            type: type,
            mime: mime,
            filename: filename,
            name: name,
            url: url,
            source: source,
            reason: reason,
            tool: toolName,
            callID: callID ?? tool?.callID,
            state: state,
            text: text,
            auto: nil,
            overflow: nil,
            tailStartID: nil
        )
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
        sandboxes: nil,
        icon: OpenCodeProject.Icon(color: nil),
        time: OpenCodeProject.Time(created: nil, updated: nil)
    )

    static let repoProject = OpenCodeProject(
        id: "preview-project",
        worktree: "/path/to/opencode-ios-client",
        vcs: "git",
        name: "opencode-ios-client",
        sandboxes: nil,
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
            guard let rawPart = payload.properties.part else {
                result.reason = "missing part/message id"
                return result
            }

            let part = rawPart.applyingEventFallbacks(
                sessionID: payload.properties.sessionID,
                messageID: payload.properties.messageID,
                partID: payload.properties.partID
            )

            guard let messageID = part.messageID else {
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
                result.reason = "missing delta target"
                return result
            }

            guard result.messages[index].parts.contains(where: { $0.id == partID }) else {
                result.reason = "missing delta part"
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

struct UpdateSessionRequest: Encodable {
    let title: String?
    let time: UpdateSessionTimeRequest?

    init(title: String? = nil, time: UpdateSessionTimeRequest? = nil) {
        self.title = title
        self.time = time
    }
}

struct UpdateSessionTimeRequest: Encodable {
    let archived: Double?
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
    let name: String?
    let mime: String?
    let filename: String?
    let url: String?
    let source: SendMessagePartSource?
    let synthetic: Bool?
    let metadata: [String: OpenCodeJSONValue]?
}

struct SendMessagePartSource: Encodable {
    let value: String
    let start: Int
    let end: Int
}

enum OpenCodeAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "The server URL is invalid.")
        case .invalidResponse:
            return String(localized: "The server returned an invalid response.")
        case .timedOut:
            return String(localized: "The server took too long to respond. Check that the URL is reachable, then try again.")
        case let .httpError(code, body):
            if body.isEmpty {
                return String(localized: "The server request failed with status \(code).")
            }
            return String(localized: "The server request failed with status \(code): \(body)")
        }
    }
}
