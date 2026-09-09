import XCTest
import SwiftData
@testable import OpenClient

final class OpenCodeLocalCacheRepositoryTests: XCTestCase {
    @MainActor
    func testOlderPagesOverPersistedHistoryKeepPrefixSuffixAndCapacityOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "https://cache.invalid|user", profile: .v2)
        for count in [6, 2_002] {
            let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema,
                url: folder.appendingPathComponent("\(count).store"), cloudKitDatabase: .none)
            let messages = (0..<count).map { message(id: "m\($0)", sessionID: "s", text: "Original \($0)") }
            do {
                let repository = SwiftDataOpenCodeLocalCacheRepository(modelContainer:
                    try ModelContainer(for: schema, configurations: [configuration]))
                try await repository.saveChatMessages(messages, serverID: namespace, sessionID: "s")
            }
            let reopened = SwiftDataOpenCodeLocalCacheRepository(modelContainer:
                try ModelContainer(for: schema, configurations: [configuration]))
            try await reopened.saveChatMessages(Array(messages.suffix(2)), serverID: namespace, sessionID: "s",
                refreshedAt: Date(), writtenAt: Date(), coverage: .newestPage(hasOlder: true))
            let older = ((count - 4)..<(count - 2)).map { message(id: "m\($0)", sessionID: "s", text: "Updated \($0)") }
            try await reopened.saveChatMessages(older, serverID: namespace, sessionID: "s",
                refreshedAt: Date(), writtenAt: Date(), coverage: .olderPage(beforeMessageID: "m\(count - 2)"))
            let cached = try await reopened.loadChat(serverID: namespace, sessionID: "s")
            XCTAssertEqual(cached?.messages.map(\.id), messages.suffix(2_000).map(\.id))
            XCTAssertEqual(cached?.messages.filter { older.map(\.id).contains($0.id) }, older)
        }
    }

    func testOlderPageWithoutOverlapUsesItsKnownNewerBoundary() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "https://cache.invalid|user", profile: .v2)
        let messages = ["A", "B", "C", "D", "E", "F"].map { message(id: $0, sessionID: "s", text: $0) }
        try await repository.saveChatMessages([messages[0], messages[1], messages[4], messages[5]], serverID: namespace, sessionID: "s")
        try await repository.saveChatMessages(Array(messages[2...3]), serverID: namespace, sessionID: "s",
            refreshedAt: Date(), writtenAt: Date(), coverage: .olderPage(beforeMessageID: "E"))
        let cached = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertEqual(cached?.messages, messages)
    }

    func testCanonicalCoverageRemovesOnlyProvenSuffixAndCompleteResponseReplacesHistory() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "https://cache.invalid|user", profile: .v2)
        let old = message(id: "old", sessionID: "s", text: "Unloaded")
        let anchor = message(id: "anchor", sessionID: "s", text: "Anchor")
        let removed = message(id: "removed", sessionID: "s", text: "Reverted")
        let latest = message(id: "latest", sessionID: "s", text: "Canonical")
        try await repository.saveChatMessages([old, anchor, removed], serverID: namespace, sessionID: "s")
        try await repository.saveChatMessages([anchor, latest], serverID: namespace, sessionID: "s",
            refreshedAt: Date(), writtenAt: Date(), coverage: .newestPage(hasOlder: true))
        let partial = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertEqual(partial?.messages.map(\.id), ["old", "anchor", "latest"])
        try await repository.saveChatMessages([], serverID: namespace, sessionID: "s",
            refreshedAt: Date(), writtenAt: Date(), coverage: .newestPage(hasOlder: false))
        let empty = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertEqual(empty?.messages, [])
        XCTAssertNil(empty?.messagesRefreshedAt)
    }

    @MainActor
    func testOnDiskV1LegacyRecordsRemainReadableBesideV2AndTombstones() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("cache.store")
        let schema = Schema(versionedSchema: OpenCodeLocalCacheSchemaV1.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let raw = OpenCodeServerConfig(baseURL: "https://CACHE.example", username: "User", password: "secret").recentServerID
        let v2 = OpenCodeLocalCacheIdentity.namespace(serverID: raw, profile: .v2)
        let projects = [project(id: "shared", name: "Legacy")]
        let sessions = [session(id: "shared", title: "Legacy", directory: nil)]
        let legacyMessages = [message(id: "shared", sessionID: "shared", text: "Legacy")]
        let v2Messages = [message(id: "shared", sessionID: "shared", text: "V2")]
        let date = Date(timeIntervalSince1970: 100)
        // Seed the actual V1 store with the original key encoding and old array payload.
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let serverKey = "s\(raw.utf8.count):\(raw)"
            context.insert(OpenCodeCachedProjectsRecord(key: serverKey, serverID: raw,
                payload: try JSONEncoder().encode(projects), refreshedAt: date, writtenAt: date))
            context.insert(OpenCodeCachedDirectorySessionsRecord(key: serverKey + "n", serverID: raw,
                payload: try JSONEncoder().encode(sessions), refreshedAt: date, writtenAt: date))
            context.insert(OpenCodeCachedChatRecord(key: serverKey + "s6:shared", serverID: raw, sessionID: "shared",
                messagesPayload: try JSONEncoder().encode(legacyMessages), messagesRefreshedAt: date, messagesWrittenAt: date))
            try context.save()
        }
        do {
            let container = try ModelContainer(for: schema, migrationPlan: OpenCodeLocalCacheMigrationPlan.self, configurations: [configuration])
            let repository = SwiftDataOpenCodeLocalCacheRepository(modelContainer: container)
            let loadedProjects = try await repository.loadProjects(serverID: raw)
            let loadedSessions = try await repository.loadDirectorySessions(serverID: raw, directory: nil)
            let loadedChat = try await repository.loadChat(serverID: raw, sessionID: "shared")
            XCTAssertEqual(loadedProjects?.projects, projects)
            XCTAssertEqual(loadedSessions?.sessions, sessions)
            XCTAssertEqual(loadedChat?.messages, legacyMessages)
            try await repository.saveChatMessages(v2Messages, serverID: v2, sessionID: "shared", refreshedAt: date, writtenAt: date)
            try await repository.removeSession(serverID: v2, sessionID: "shared", removedAt: date.addingTimeInterval(2))
        }
        let reopened = SwiftDataOpenCodeLocalCacheRepository(modelContainer:
            try ModelContainer(for: schema, migrationPlan: OpenCodeLocalCacheMigrationPlan.self, configurations: [configuration]))
        try await reopened.saveChatMessages(v2Messages, serverID: v2, sessionID: "shared", refreshedAt: date, writtenAt: date.addingTimeInterval(1))
        let tombstone = try await reopened.loadChat(serverID: v2, sessionID: "shared")
        XCTAssertNil(tombstone)
        try await reopened.clear(serverID: v2)
        let legacy = try await reopened.loadChat(serverID: raw, sessionID: "shared")
        XCTAssertEqual(legacy?.messages, legacyMessages)
    }

    func testProfileAndWorkspaceNamespaceEncodingIsDisjoint() {
        let config = OpenCodeServerConfig(baseURL: "https://CACHE.example/path|user", username: "USER", password: "secret")
        let raw = config.recentServerID
        let v2 = OpenCodeLocalCacheIdentity.namespace(serverID: raw, profile: .v2)
        XCTAssertEqual(raw, raw.lowercased())
        XCTAssertEqual(OpenCodeLocalCacheIdentity.namespace(serverID: raw, profile: .legacy), raw)
        XCTAssertNotEqual(v2, v2.lowercased())
        let scopes: [(String?, String?)] = [(nil, nil), ("/", nil), ("global", nil), (nil, "w"), ("/", "w"), ("s1:wn", nil)]
        XCTAssertEqual(Set(scopes.map { OpenCodeLocalCacheIdentity.directory($0.0, workspaceID: $0.1, namespace: v2) }).count, scopes.count)
    }

    func testV2PartialPagesPreserveUnloadedMessagesAndNeverValidateHistoryOrTodos() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "https://cache.example|user", profile: .v2)
        let old = message(id: "m1", sessionID: "s", text: "Older")
        let latest = message(id: "m2", sessionID: "s", text: "Latest")
        try await repository.saveChatMessages([old], serverID: namespace, sessionID: "s")
        try await repository.saveChatMessages([latest], serverID: namespace, sessionID: "s")
        try await repository.saveChatMessages([], serverID: namespace, sessionID: "s")
        try await repository.saveTodos([.init(content: "Must not cache", status: "pending", priority: "high")], serverID: namespace, sessionID: "s")
        let snapshot = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertEqual(Set(snapshot?.messages.map(\.info.id) ?? []), ["m1", "m2"])
        XCTAssertFalse(snapshot?.areMessagesFresh() ?? true)
        XCTAssertEqual(snapshot?.todos, [])
        XCTAssertNil(snapshot?.todosRefreshedAt)
    }

    func testV2BoundsProjectAndSessionSnapshotsAndPreservesCanonicalMessageOrder() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let namespace = OpenCodeLocalCacheIdentity.namespace(serverID: "https://cache.example|user", profile: .v2)
        let projects = (0..<105).map { project(id: "p\($0)", name: "Project") }
        let sessions = (0..<105).map { session(id: "s\($0)", title: "Session", directory: "/project") }
        try await repository.saveProjects(projects, serverID: namespace)
        try await repository.saveDirectorySessions(sessions, serverID: namespace, directory: "/project")
        let loadedProjects = try await repository.loadProjects(serverID: namespace)
        let loadedSessions = try await repository.loadDirectorySessions(serverID: namespace, directory: "/project")
        XCTAssertEqual(loadedProjects?.projects, Array(projects.prefix(100)))
        XCTAssertEqual(loadedSessions?.sessions, Array(sessions.prefix(100)))
        XCTAssertFalse(loadedSessions?.isFresh() ?? true)
        let messages = [message(id: "z", sessionID: "s", text: "First"), message(id: "a", sessionID: "s", text: "Second")]
        try await repository.saveChatMessages(messages, serverID: namespace, sessionID: "s")
        let chat = try await repository.loadChat(serverID: namespace, sessionID: "s")
        XCTAssertEqual(chat?.messages.map(\.info.id), ["z", "a"])
    }

    func testClearingOneProfilePreservesOtherProfilesLatestWriteGuard() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let raw = "https://cache.example|user"
        let v2 = OpenCodeLocalCacheIdentity.namespace(serverID: raw, profile: .v2)
        let original = [message(id: "m", sessionID: "s", text: "Current")]
        let stale = [message(id: "m", sessionID: "s", text: "Stale")]
        let date = Date(timeIntervalSince1970: 100)
        try await repository.saveChatMessages(original, serverID: v2, sessionID: "s", refreshedAt: date, writtenAt: date)
        try await repository.saveChatMessages(original, serverID: v2, sessionID: "s", refreshedAt: date, writtenAt: date.addingTimeInterval(2))
        try await repository.clear(serverID: raw)
        try await repository.saveChatMessages(stale, serverID: v2, sessionID: "s", refreshedAt: date, writtenAt: date.addingTimeInterval(1))
        try await repository.removeSession(serverID: v2, sessionID: "s", removedAt: date.addingTimeInterval(1))
        let snapshot = try await repository.loadChat(serverID: v2, sessionID: "s")
        XCTAssertEqual(snapshot?.messages, original)
        try await repository.clear(serverID: v2)
        try await repository.saveChatMessages(stale, serverID: v2, sessionID: "s", refreshedAt: date, writtenAt: date)
        let cleared = try await repository.loadChat(serverID: v2, sessionID: "s")
        XCTAssertNil(cleared)
    }

    func testStreamDeltasWaitForCanonicalEventBeforeWritingChatSnapshot() {
        XCTAssertFalse(OpenCodeLocalCacheEventWritePolicy.writesChatSnapshot(for: .messagePartDelta(
            sessionID: "ses_cache",
            messageID: "msg_cache",
            partID: "prt_cache",
            field: "text",
            delta: "Streaming"
        )))
        XCTAssertFalse(OpenCodeLocalCacheEventWritePolicy.writesChatSnapshot(for: .messagePartUpdated(
            OpenCodePart(
                id: "prt_cache",
                messageID: "msg_cache",
                sessionID: "ses_cache",
                type: "text",
                mime: nil,
                filename: nil,
                url: nil,
                reason: nil,
                tool: nil,
                callID: nil,
                state: nil,
                text: "Complete"
            )
        )))
        XCTAssertTrue(OpenCodeLocalCacheEventWritePolicy.writesChatSnapshot(for: .sessionIdle(sessionID: "ses_cache")))
    }

    func testUnchangedNewerChatWriteStillRejectsAnOlderChangedSnapshot() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let original = [message(id: "message-1", sessionID: "session-1", text: "Original")]
        let stale = [message(id: "message-1", sessionID: "session-1", text: "Stale")]
        let initialRefreshedAt = Date(timeIntervalSince1970: 100)

        try await repository.saveChatMessages(
            original,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: initialRefreshedAt,
            writtenAt: Date(timeIntervalSince1970: 1)
        )
        try await repository.saveChatMessages(
            original,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: Date(timeIntervalSince1970: 200),
            writtenAt: Date(timeIntervalSince1970: 3)
        )
        try await repository.saveChatMessages(
            stale,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: Date(timeIntervalSince1970: 150),
            writtenAt: Date(timeIntervalSince1970: 2)
        )

        let snapshot = try await repository.loadChat(serverID: "server", sessionID: "session-1")
        XCTAssertEqual(snapshot?.messages, original)
        XCTAssertEqual(snapshot?.messagesRefreshedAt, initialRefreshedAt)
    }

    func testUnchangedNewerTodoWriteDoesNotRewriteRefreshMetadata() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let todos = [OpenCodeTodo(content: "Persist efficiently", status: "pending", priority: "high")]
        let initialRefreshedAt = Date(timeIntervalSince1970: 100)

        try await repository.saveTodos(
            todos,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: initialRefreshedAt,
            writtenAt: Date(timeIntervalSince1970: 1)
        )
        try await repository.saveTodos(
            todos,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: Date(timeIntervalSince1970: 200),
            writtenAt: Date(timeIntervalSince1970: 2)
        )

        let snapshot = try await repository.loadChat(serverID: "server", sessionID: "session-1")
        XCTAssertEqual(snapshot?.todos, todos)
        XCTAssertEqual(snapshot?.todosRefreshedAt, initialRefreshedAt)
    }

    func testRoundTripPreservesSnapshotValuesAndRefreshDates() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let projectsDate = Date(timeIntervalSince1970: 1_000)
        let sessionsDate = Date(timeIntervalSince1970: 2_000)
        let messagesDate = Date(timeIntervalSince1970: 3_000)
        let todosDate = Date(timeIntervalSince1970: 4_000)
        let metadataDate = Date(timeIntervalSince1970: 5_000)
        let projects = [project(id: "project-1", name: "Project One")]
        let sessions = [session(id: "session-1", title: "Session One", directory: "/project")]
        let messages = [message(id: "message-1", sessionID: "session-1", text: "Hello")]
        let todos = [OpenCodeTodo(content: "Cache snapshots", status: "pending", priority: "high")]
        let statuses = ["session-1": "busy"]
        let permissions = [
            OpenCodePermission(
                id: "permission-1",
                sessionID: "session-1",
                permission: "bash",
                patterns: ["xcodebuild test"],
                always: nil,
                metadata: nil,
                tool: nil
            ),
        ]
        let questions = [
            OpenCodeQuestionRequest(
                id: "question-1",
                sessionID: "session-1",
                questions: [
                    OpenCodeQuestion(
                        question: "Continue?",
                        header: "Next step",
                        options: [OpenCodeQuestionOption(label: "Yes", description: "Continue")]
                    ),
                ],
                tool: nil
            ),
        ]

        try await repository.saveProjects(projects, serverID: "server", refreshedAt: projectsDate)
        try await repository.saveDirectorySessions(
            sessions,
            serverID: "server",
            directory: "/project",
            refreshedAt: sessionsDate
        )
        try await repository.saveChatMessages(
            messages,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: messagesDate
        )
        try await repository.saveTodos(
            todos,
            serverID: "server",
            sessionID: "session-1",
            refreshedAt: todosDate
        )
        try await repository.saveDirectoryMetadata(
            statuses: statuses,
            permissions: permissions,
            questions: questions,
            serverID: "server",
            directory: "/project",
            refreshedAt: metadataDate,
            writtenAt: Date()
        )

        let projectsSnapshot = try await repository.loadProjects(serverID: "server")
        let sessionsSnapshot = try await repository.loadDirectorySessions(
            serverID: "server",
            directory: "/project"
        )
        let chatSnapshot = try await repository.loadChat(serverID: "server", sessionID: "session-1")
        let loadedProjects = try XCTUnwrap(projectsSnapshot)
        let loadedSessions = try XCTUnwrap(sessionsSnapshot)
        let loadedChat = try XCTUnwrap(chatSnapshot)

        XCTAssertEqual(loadedProjects.projects, projects)
        XCTAssertEqual(loadedProjects.refreshedAt, projectsDate)
        XCTAssertEqual(loadedSessions.sessions, sessions)
        XCTAssertEqual(loadedSessions.statuses, statuses)
        XCTAssertEqual(loadedSessions.permissions, permissions)
        XCTAssertEqual(loadedSessions.questions, questions)
        XCTAssertEqual(loadedSessions.refreshedAt, metadataDate)
        XCTAssertEqual(loadedChat.messages, messages)
        XCTAssertEqual(loadedChat.todos, todos)
        XCTAssertEqual(loadedChat.messagesRefreshedAt, messagesDate)
        XCTAssertEqual(loadedChat.todosRefreshedAt, todosDate)
    }

    func testGlobalAndLiteralGlobalDirectoryScopesDoNotCollide() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let globalSessions = [session(id: "global-session", title: "Global", directory: nil)]
        let literalGlobalSessions = [session(id: "literal-session", title: "Literal", directory: "global")]

        try await repository.saveDirectorySessions(
            globalSessions,
            serverID: "server",
            directory: nil,
            refreshedAt: Date(timeIntervalSince1970: 1)
        )
        try await repository.saveDirectorySessions(
            literalGlobalSessions,
            serverID: "server",
            directory: "global",
            refreshedAt: Date(timeIntervalSince1970: 2)
        )

        let global = try await repository.loadDirectorySessions(serverID: "server", directory: nil)
        let literalGlobal = try await repository.loadDirectorySessions(serverID: "server", directory: "global")

        XCTAssertEqual(global?.sessions, globalSessions)
        XCTAssertEqual(literalGlobal?.sessions, literalGlobalSessions)
    }

    func testSameSessionAndMessageIDsRemainIsolatedAcrossServers() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let sessionA = session(id: "shared-session", title: "Server A", directory: nil)
        let sessionB = session(id: "shared-session", title: "Server B", directory: nil)
        let messageA = message(id: "shared-message", sessionID: sessionA.id, text: "A")
        let messageB = message(id: "shared-message", sessionID: sessionB.id, text: "B")

        try await repository.saveDirectorySessions(
            [sessionA],
            serverID: "server-a",
            directory: nil,
            refreshedAt: Date()
        )
        try await repository.saveDirectorySessions(
            [sessionB],
            serverID: "server-b",
            directory: nil,
            refreshedAt: Date()
        )
        try await repository.saveChatMessages(
            [messageA],
            serverID: "server-a",
            sessionID: sessionA.id,
            refreshedAt: Date()
        )
        try await repository.saveChatMessages(
            [messageB],
            serverID: "server-b",
            sessionID: sessionB.id,
            refreshedAt: Date()
        )

        let sessionsA = try await repository.loadDirectorySessions(serverID: "server-a", directory: nil)
        let sessionsB = try await repository.loadDirectorySessions(serverID: "server-b", directory: nil)
        let chatA = try await repository.loadChat(serverID: "server-a", sessionID: sessionA.id)
        let chatB = try await repository.loadChat(serverID: "server-b", sessionID: sessionB.id)

        XCTAssertEqual(sessionsA?.sessions, [sessionA])
        XCTAssertEqual(sessionsB?.sessions, [sessionB])
        XCTAssertEqual(chatA?.messages, [messageA])
        XCTAssertEqual(chatB?.messages, [messageB])
    }

    func testTodoDuplicatesAndOrderArePreserved() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let todos = [
            OpenCodeTodo(content: "Repeated", status: "pending", priority: "high"),
            OpenCodeTodo(content: "Repeated", status: "completed", priority: "low"),
            OpenCodeTodo(content: "Last", status: "in_progress", priority: "medium"),
        ]

        try await repository.saveTodos(
            todos,
            serverID: "server",
            sessionID: "session",
            refreshedAt: Date()
        )

        let chat = try await repository.loadChat(serverID: "server", sessionID: "session")
        XCTAssertEqual(chat?.todos, todos)
    }

    func testLoadedChatPreparesOnlyTheLatestUserRoundForImmediatePresentation() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let messages = [
            message(id: "msg-01", sessionID: "session", role: "user", text: "First"),
            message(id: "msg-02", sessionID: "session", text: "First answer"),
            message(id: "msg-03", sessionID: "session", role: "user", text: "Second"),
            message(id: "msg-04", sessionID: "session", text: "Second answer"),
            message(id: "msg-05", sessionID: "session", text: "More work"),
        ]

        try await repository.saveChatMessages(
            messages,
            serverID: "server",
            sessionID: "session",
            refreshedAt: Date()
        )

        let loadedSnapshot = try await repository.loadChat(serverID: "server", sessionID: "session")
        let snapshot = try XCTUnwrap(loadedSnapshot)

        XCTAssertEqual(snapshot.preparedMessages.messages.map(\.id), messages.map(\.id))
        XCTAssertEqual(
            snapshot.preparedMessages.immediateMessages.map(\.id),
            ["msg-03", "msg-04", "msg-05"]
        )
    }

    func testRemoveSessionRemovesItFromAllScopesAndDeletesOnlyItsChat() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let removed = session(id: "removed", title: "Removed", directory: nil)
        let retained = session(id: "retained", title: "Retained", directory: "/project")

        try await repository.saveDirectorySessions(
            [removed],
            serverID: "server",
            directory: nil,
            refreshedAt: Date()
        )
        try await repository.saveDirectorySessions(
            [removed, retained],
            serverID: "server",
            directory: "/project",
            refreshedAt: Date()
        )
        try await repository.saveChatMessages(
            [message(id: "removed-message", sessionID: removed.id, text: "Remove")],
            serverID: "server",
            sessionID: removed.id,
            refreshedAt: Date()
        )
        try await repository.saveChatMessages(
            [message(id: "retained-message", sessionID: retained.id, text: "Keep")],
            serverID: "server",
            sessionID: retained.id,
            refreshedAt: Date()
        )

        try await repository.removeSession(serverID: "server", sessionID: removed.id)

        let global = try await repository.loadDirectorySessions(serverID: "server", directory: nil)
        let project = try await repository.loadDirectorySessions(serverID: "server", directory: "/project")
        let removedChat = try await repository.loadChat(serverID: "server", sessionID: removed.id)
        let retainedChat = try await repository.loadChat(serverID: "server", sessionID: retained.id)

        XCTAssertEqual(global?.sessions, [])
        XCTAssertEqual(project?.sessions, [retained])
        XCTAssertNil(removedChat)
        XCTAssertEqual(retainedChat?.messages.map(\.id), ["retained-message"])
    }

    func testSnapshotFreshnessRejectsStaleDates() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = OpenCodeCachedProjectsSnapshot(
            projects: [],
            refreshedAt: now.addingTimeInterval(-OpenCodeLocalCacheFreshness.initialMaxAge - 1)
        )

        XCTAssertFalse(snapshot.isFresh(at: now))
        XCTAssertTrue(
            OpenCodeLocalCacheFreshness.isFresh(
                now.addingTimeInterval(-OpenCodeLocalCacheFreshness.initialMaxAge),
                at: now
            )
        )
        XCTAssertFalse(OpenCodeLocalCacheFreshness.isFresh(nil, at: now))
        XCTAssertFalse(OpenCodeLocalCacheFreshness.isFresh(now.addingTimeInterval(1), at: now))
    }

    func testOlderWriteCannotOverwriteNewerSnapshot() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let older = [session(id: "older", title: "Older", directory: nil)]
        let newer = [session(id: "newer", title: "Newer", directory: nil)]

        try await repository.saveDirectorySessions(
            newer,
            serverID: "server",
            directory: nil,
            refreshedAt: Date(timeIntervalSince1970: 20),
            writtenAt: Date(timeIntervalSince1970: 20)
        )
        try await repository.saveDirectorySessions(
            older,
            serverID: "server",
            directory: nil,
            refreshedAt: Date(timeIntervalSince1970: 10),
            writtenAt: Date(timeIntervalSince1970: 10)
        )

        let snapshot = try await repository.loadDirectorySessions(serverID: "server", directory: nil)
        XCTAssertEqual(snapshot?.sessions, newer)
    }

    func testDelayedChatWriteCannotResurrectRemovedSession() async throws {
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let cachedMessage = message(id: "message", sessionID: "session", text: "Cached")

        try await repository.removeSession(
            serverID: "server",
            sessionID: "session",
            removedAt: Date(timeIntervalSince1970: 20)
        )
        try await repository.saveChatMessages(
            [cachedMessage],
            serverID: "server",
            sessionID: "session",
            refreshedAt: Date(timeIntervalSince1970: 10),
            writtenAt: Date(timeIntervalSince1970: 10)
        )

        let chat = try await repository.loadChat(serverID: "server", sessionID: "session")
        XCTAssertNil(chat)
    }

    private func project(id: String, name: String) -> OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: "/\(id)",
            vcs: "git",
            name: name,
            sandboxes: nil,
            icon: nil,
            time: nil
        )
    }

    private func session(id: String, title: String, directory: String?) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            title: title,
            workspaceID: nil,
            directory: directory,
            projectID: nil,
            parentID: nil
        )
    }

    private func message(
        id: String,
        sessionID: String,
        role: String = "assistant",
        text: String
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: nil,
                agent: nil,
                model: nil
            ),
            parts: [
                OpenCodePart(
                    id: "part-\(id)",
                    messageID: id,
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
            ]
        )
    }
}
