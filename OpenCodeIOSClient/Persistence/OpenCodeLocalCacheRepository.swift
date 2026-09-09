import Foundation

enum OpenCodeLocalCacheIdentity {
    // recentServerID is entirely lowercased. This uppercase tag cannot be a legacy
    // ID; length framing keeps arbitrary URL/user text unambiguous. Never hash or
    // change the legacy ID (it is also used outside this cache).
    static func namespace(serverID: String, profile: OpenCodeAPIProfile) -> String {
        profile == .legacy ? serverID : "OpenCodeCacheV2:s\(serverID.utf8.count):\(serverID)"
    }

    static func isV2(_ namespace: String) -> Bool {
        namespace.hasPrefix("OpenCodeCacheV2:")
    }

    static func directory(_ directory: String?, workspaceID: String?, namespace: String) -> String? {
        guard isV2(namespace) else { return directory }
        return [directory, workspaceID].map { value in
            value.map { "s\($0.utf8.count):\($0)" } ?? "n"
        }.joined()
    }
}

/// A best-effort read-through cache. OpenCode server responses remain canonical.
/// serverID is the captured cache namespace, not necessarily a recent-server ID.
protocol OpenCodeLocalCacheRepository: Sendable {
    func loadProjects(serverID: String) async throws -> OpenCodeCachedProjectsSnapshot?
    func saveProjects(
        _ projects: [OpenCodeProject],
        serverID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws

    func loadDirectorySessions(
        serverID: String,
        directory: String?
    ) async throws -> OpenCodeCachedDirectorySessionsSnapshot?
    func saveDirectorySessions(
        _ sessions: [OpenCodeSession],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws
    func saveDirectoryMetadata(
        statuses: [String: String],
        permissions: [OpenCodePermission],
        questions: [OpenCodeQuestionRequest],
        serverID: String,
        directory: String?,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws

    func loadChat(
        serverID: String,
        sessionID: String
    ) async throws -> OpenCodeCachedChatSnapshot?
    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date,
        coverage: OpenCodeLocalCacheTranscriptCoverage
    ) async throws
    func saveTodos(
        _ todos: [OpenCodeTodo],
        serverID: String,
        sessionID: String,
        refreshedAt: Date,
        writtenAt: Date
    ) async throws

    func removeSession(serverID: String, sessionID: String, removedAt: Date) async throws
    func clear(serverID: String) async throws
}

enum OpenCodeLocalCacheTranscriptCoverage: Sendable {
    case partial
    case newestPage(hasOlder: Bool)
    case olderPage(beforeMessageID: String)
}

enum OpenCodeLocalCacheEventWritePolicy {
    static func writesChatSnapshot(for event: OpenCodeTypedEvent) -> Bool {
        switch event {
        case .messageUpdated,
             .messageRemoved,
             .messagePartRemoved,
             .todoUpdated,
             .sessionIdle:
            return true
        case .messagePartUpdated,
             .messagePartDelta:
            return false
        default:
            return false
        }
    }
}

extension OpenCodeLocalCacheRepository {
    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope], serverID: String, sessionID: String,
        refreshedAt: Date, writtenAt: Date
    ) async throws {
        try await saveChatMessages(messages, serverID: serverID, sessionID: sessionID,
            refreshedAt: refreshedAt, writtenAt: writtenAt, coverage: .partial)
    }

    func saveProjects(_ projects: [OpenCodeProject], serverID: String) async throws {
        let now = Date()
        try await saveProjects(projects, serverID: serverID, refreshedAt: now, writtenAt: now)
    }

    func saveProjects(
        _ projects: [OpenCodeProject],
        serverID: String,
        refreshedAt: Date
    ) async throws {
        try await saveProjects(projects, serverID: serverID, refreshedAt: refreshedAt, writtenAt: Date())
    }

    func saveDirectorySessions(
        _ sessions: [OpenCodeSession],
        serverID: String,
        directory: String?
    ) async throws {
        let now = Date()
        try await saveDirectorySessions(
            sessions,
            serverID: serverID,
            directory: directory,
            refreshedAt: now,
            writtenAt: now
        )
    }

    func saveDirectorySessions(
        _ sessions: [OpenCodeSession],
        serverID: String,
        directory: String?,
        refreshedAt: Date
    ) async throws {
        try await saveDirectorySessions(
            sessions,
            serverID: serverID,
            directory: directory,
            refreshedAt: refreshedAt,
            writtenAt: Date()
        )
    }

    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope],
        serverID: String,
        sessionID: String
    ) async throws {
        let now = Date()
        try await saveChatMessages(
            messages,
            serverID: serverID,
            sessionID: sessionID,
            refreshedAt: now,
            writtenAt: now
        )
    }

    func saveChatMessages(
        _ messages: [OpenCodeMessageEnvelope],
        serverID: String,
        sessionID: String,
        refreshedAt: Date
    ) async throws {
        try await saveChatMessages(
            messages,
            serverID: serverID,
            sessionID: sessionID,
            refreshedAt: refreshedAt,
            writtenAt: Date()
        )
    }

    func saveTodos(
        _ todos: [OpenCodeTodo],
        serverID: String,
        sessionID: String
    ) async throws {
        let now = Date()
        try await saveTodos(
            todos,
            serverID: serverID,
            sessionID: sessionID,
            refreshedAt: now,
            writtenAt: now
        )
    }

    func saveTodos(
        _ todos: [OpenCodeTodo],
        serverID: String,
        sessionID: String,
        refreshedAt: Date
    ) async throws {
        try await saveTodos(
            todos,
            serverID: serverID,
            sessionID: sessionID,
            refreshedAt: refreshedAt,
            writtenAt: Date()
        )
    }

    func removeSession(serverID: String, sessionID: String) async throws {
        try await removeSession(serverID: serverID, sessionID: sessionID, removedAt: Date())
    }
}

struct OpenCodeCachedProjectsSnapshot: Sendable {
    let projects: [OpenCodeProject]
    let refreshedAt: Date

    func isFresh(
        at date: Date = Date(),
        maxAge: TimeInterval = OpenCodeLocalCacheFreshness.initialMaxAge
    ) -> Bool {
        OpenCodeLocalCacheFreshness.isFresh(refreshedAt, at: date, maxAge: maxAge)
    }
}

struct OpenCodeCachedDirectorySessionsSnapshot: Sendable {
    let sessions: [OpenCodeSession]
    let statuses: [String: String]?
    let permissions: [OpenCodePermission]?
    let questions: [OpenCodeQuestionRequest]?
    let refreshedAt: Date

    func isFresh(
        at date: Date = Date(),
        maxAge: TimeInterval = OpenCodeLocalCacheFreshness.initialMaxAge
    ) -> Bool {
        OpenCodeLocalCacheFreshness.isFresh(refreshedAt, at: date, maxAge: maxAge)
    }
}

struct OpenCodeCachedChatSnapshot: Sendable {
    let preparedMessages: OpenCodeCachedMessageState
    let todos: [OpenCodeTodo]
    let messagesRefreshedAt: Date?
    let todosRefreshedAt: Date?

    var messages: [OpenCodeMessageEnvelope] {
        preparedMessages.envelopes
    }

    func areMessagesFresh(
        at date: Date = Date(),
        maxAge: TimeInterval = OpenCodeLocalCacheFreshness.initialMaxAge
    ) -> Bool {
        OpenCodeLocalCacheFreshness.isFresh(messagesRefreshedAt, at: date, maxAge: maxAge)
    }

    func areTodosFresh(
        at date: Date = Date(),
        maxAge: TimeInterval = OpenCodeLocalCacheFreshness.initialMaxAge
    ) -> Bool {
        OpenCodeLocalCacheFreshness.isFresh(todosRefreshedAt, at: date, maxAge: maxAge)
    }
}

struct OpenCodeCachedMessageState: Sendable {
    let messages: [OpenCodeMessage]
    let partsByMessageID: [String: [OpenCodePart]]
    let immediateMessages: [OpenCodeMessageEnvelope]

    var envelopes: [OpenCodeMessageEnvelope] {
        messages.map { message in
            OpenCodeMessageEnvelope(info: message, parts: partsByMessageID[message.id] ?? [])
        }
    }

    init(envelopes: [OpenCodeMessageEnvelope], sessionID: String, preservingOrder: Bool = false) {
        var state = OpenCodeDirectorySyncState()
        if preservingOrder {
            state.replaceMessagesPreservingOrder(envelopes, forSessionID: sessionID)
        } else {
            state.replaceMessages(envelopes, forSessionID: sessionID)
        }
        messages = state.messagesBySessionID[sessionID] ?? []
        partsByMessageID = state.partsByMessageID
        immediateMessages = Self.immediateTranscript(in: state.messageEnvelopes(forSessionID: sessionID))
    }

    private static func immediateTranscript(in messages: [OpenCodeMessageEnvelope]) -> [OpenCodeMessageEnvelope] {
        guard !messages.isEmpty else { return [] }
        if let latestUserIndex = messages.lastIndex(where: {
            ($0.info.role ?? "").lowercased() == "user"
        }) {
            return Array(messages[latestUserIndex...].suffix(12))
        }
        return Array(messages.suffix(12))
    }
}

enum OpenCodeLocalCacheFreshness {
    static let initialMaxAge: TimeInterval = 5 * 60

    static func isFresh(
        _ refreshedAt: Date?,
        at date: Date = Date(),
        maxAge: TimeInterval = initialMaxAge
    ) -> Bool {
        guard let refreshedAt, maxAge >= 0 else { return false }
        let age = date.timeIntervalSince(refreshedAt)
        return age >= 0 && age <= maxAge
    }
}
