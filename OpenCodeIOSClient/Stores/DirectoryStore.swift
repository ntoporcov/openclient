import Combine
import Foundation

struct OpenClientSessionSwitcherPresentation: Equatable {
    let sessions: [OpenCodeSession]
    let selectedSessionID: String
}

struct DirectorySessionSnapshot {
    let session: OpenCodeSession?
    let status: String?
    let messages: [OpenCodeMessageEnvelope]
    let todos: [OpenCodeTodo]
    let permissions: [OpenCodePermission]
    let questions: [OpenCodeQuestionRequest]
}

@MainActor
final class DirectoryStoreRegistry: ObservableObject {
    static let globalKey = "global"

    @Published private(set) var activeStore: DirectoryStore
    @Published private(set) var activeKey: String
    @Published private(set) var generation: Int
    @Published private(set) var storeCollectionRevision: Int
    private var storesByKey: [String: DirectoryStore]
    private var openedSessionIDs: [String] = []
    private(set) var v2PendingSessionIDs: Set<String> = []
    private(set) var v2NeedsReconnectHydration = false
    private var v2LifecycleRevisions: [String: UInt] = [:]
    private(set) var v2ProjectRevision: UInt = 0
    @Published private(set) var v2DeletedSessionIDs: Set<String> = []

    func isV2SessionDeleted(_ id: String) -> Bool { v2DeletedSessionIDs.contains(id) }

    func markV2SessionDeleted(_ id: String) {
        openedSessionIDs.removeAll { $0 == id }
        v2DeletedSessionIDs.insert(id)
        v2LifecycleRevisions[id, default: 0] &+= 1
        v2PendingSessionIDs.remove(id)
    }

    func recordV2LifecycleEvent(_ event: OpenCodeV2ManagedEvent) {
        if event.type.hasPrefix("project.") || event.type.hasPrefix("worktree.") { v2ProjectRevision &+= 1 }
        guard let id = event.sessionID,
              ["session.created", "session.deleted", "session.moved", "session.renamed", "session.forked"].contains(event.type) else { return }
        if event.type == "session.deleted" {
            markV2SessionDeleted(id)
            return
        }
        if event.type == "session.created" || event.type == "session.forked" { v2DeletedSessionIDs.remove(id) }
        v2LifecycleRevisions[id, default: 0] &+= 1
    }

    func v2LifecycleRevision(sessionID: String) -> UInt {
        v2LifecycleRevisions[sessionID, default: 0]
    }

    var v2LifecycleSnapshot: [String: UInt] { v2LifecycleRevisions }

    func unchangedV2Sessions(_ sessions: [OpenCodeSession], since snapshot: [String: UInt]) -> [OpenCodeSession] {
        sessions.filter { !isV2SessionDeleted($0.id) && v2LifecycleRevision(sessionID: $0.id) == (snapshot[$0.id] ?? 0) }
    }

    var allStores: [DirectoryStore] { Array(storesByKey.values) }

    func targetStore(forV2Event event: OpenCodeV2ManagedEvent) -> DirectoryStore {
        if let location = event.routingLocation {
            if let id = event.sessionID, let owner = knownV2Owner(sessionID: id, directory: location.directory, workspaceID: location.workspaceID) {
                return owner
            }
            if let parentID = event.data.objectValue?["parentID"]?.literalStringValue,
               let owner = knownV2Owner(sessionID: parentID, directory: location.directory, workspaceID: location.workspaceID) {
                return owner
            }
            return store(for: location.directory)
        }
        if let sessionID = event.sessionID, let owner = ownerStore(forSessionID: sessionID) {
            return owner
        }
        return store(for: nil)
    }

    func targetStore(forV2Session session: OpenCodeSession) -> DirectoryStore {
        if let owner = knownV2Owner(sessionID: session.id, directory: session.directory, workspaceID: session.workspaceID) { return owner }
        if let parentID = session.parentID,
           let owner = knownV2Owner(sessionID: parentID, directory: session.directory, workspaceID: session.workspaceID) { return owner }
        return store(for: session.directory)
    }

    private func knownV2Owner(sessionID: String, directory: String?, workspaceID: String?) -> DirectoryStore? {
        guard let owner = ownerStore(forSessionID: sessionID),
              let previous = owner.sessions.first(where: { $0.id == sessionID })
                ?? (owner.selectedSession?.id == sessionID ? owner.selectedSession : nil),
              Self.key(for: previous.directory) == Self.key(for: directory),
              previous.workspaceID == workspaceID else { return nil }
        // A global/project list is an ownership scope, not necessarily the session's location.
        return owner
    }

    func requestV2Reconciliation(sessionID: String? = nil, reconnect: Bool = false) {
        if let sessionID, !isV2SessionDeleted(sessionID) { v2PendingSessionIDs.insert(sessionID) }
        v2NeedsReconnectHydration = v2NeedsReconnectHydration || reconnect
        if reconnect {
            for store in storesByKey.values {
                v2PendingSessionIDs.formUnion(store.sessions.map(\.id))
                v2PendingSessionIDs.formUnion(store.syncState.messagesBySessionID.keys)
                v2PendingSessionIDs.formUnion(store.sessionStatuses.keys)
                if let selected = store.selectedSession { v2PendingSessionIDs.insert(selected.id) }
            }
        }
    }

    func takeV2Reconciliation() -> (sessionIDs: Set<String>, reconnect: Bool) {
        let result = (v2PendingSessionIDs.subtracting(v2DeletedSessionIDs), v2NeedsReconnectHydration)
        v2PendingSessionIDs.removeAll()
        v2NeedsReconnectHydration = false
        return result
    }

    init(activeDirectory: String? = nil) {
        let key = Self.key(for: activeDirectory)
        let store = DirectoryStore()
        activeKey = key
        activeStore = store
        generation = 0
        storeCollectionRevision = 0
        storesByKey = [key: store]
        observeSessionOpenings(in: store)
    }

    private func observeSessionOpenings(in store: DirectoryStore) {
        store.onSessionOpened = { [weak self, weak store] session in
            guard let self, let store, self.activeStore === store,
                  self.openedSessionIDs.first != session.id else { return }
            self.openedSessionIDs.removeAll { $0 == session.id }
            self.openedSessionIDs.insert(session.id, at: 0)
        }
    }

    func orderedSessionSwitcherCandidates(
        _ candidates: [OpenCodeSession], currentSession: OpenCodeSession?
    ) -> [OpenCodeSession] {
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = currentSession.map { [$0] } ?? []
        var seen = Set<String>()
        return (ordered + openedSessionIDs.compactMap { byID[$0] } + candidates).filter {
            !$0.isArchived && !isV2SessionDeleted($0.id) && seen.insert($0.id).inserted
        }
    }

    static func key(for directory: String?) -> String {
        guard var directory, !directory.isEmpty, directory != globalKey else {
            return globalKey
        }
        directory = directory.replacingOccurrences(of: "\\", with: "/")
        while directory.count > 1, directory.hasSuffix("/") {
            directory.removeLast()
        }
        return directory
    }

    static func directory(forKey key: String) -> String? {
        key == globalKey ? nil : key
    }

    @discardableResult
    func activate(_ directory: String?) -> DirectoryStore {
        let key = Self.key(for: directory)
        let store = self.store(for: directory)
        guard key != activeKey || store !== activeStore else { return store }
        activeKey = key
        activeStore = store
        return store
    }

    func store(for directory: String?) -> DirectoryStore {
        let key = Self.key(for: directory)
        if let store = storesByKey[key] {
            return store
        }
        let store = DirectoryStore()
        storesByKey[key] = store
        observeSessionOpenings(in: store)
        storeCollectionRevision &+= 1
        return store
    }

    func existingStore(for directory: String?) -> DirectoryStore? {
        storesByKey[Self.key(for: directory)]
    }

    func key(for store: DirectoryStore) -> String? {
        storesByKey.first { $0.value === store }?.key
    }

    func contains(_ store: DirectoryStore, forKey key: String) -> Bool {
        storesByKey[key] === store
    }

    func stores(containingSessionID sessionID: String) -> [DirectoryStore] {
        storesByKey.values.filter { containsSessionState(sessionID, in: $0) }
    }

    private func containsSessionState(_ sessionID: String, in store: DirectoryStore) -> Bool {
        store.syncState.messagesBySessionID[sessionID] != nil
            || store.syncState.todosBySessionID[sessionID] != nil
            || store.syncState.permissionsBySessionID[sessionID] != nil
            || store.syncState.questionsBySessionID[sessionID] != nil
            || store.sessionStatuses[sessionID] != nil
            || store.sessions.contains { $0.id == sessionID }
    }

    func stores(containingMessageID messageID: String) -> [DirectoryStore] {
        storesByKey.values.filter { store in
            store.syncState.messagesBySessionID.values.contains { messages in
                messages.contains { $0.id == messageID }
            }
        }
    }

    func ownerStore(forSessionID sessionID: String) -> DirectoryStore? {
        if activeStore.syncState.messagesBySessionID[sessionID] != nil
            || activeStore.selectedSession?.id == sessionID
            || activeStore.sessions.contains(where: { $0.id == sessionID }) {
            return activeStore
        }
        return storesByKey.values.first { containsSessionState(sessionID, in: $0) }
    }

    func session(matching sessionID: String) -> OpenCodeSession? {
        if let owner = ownerStore(forSessionID: sessionID),
           let session = owner.sessions.first(where: { $0.id == sessionID })
            ?? (owner.selectedSession?.id == sessionID ? owner.selectedSession : nil) { return session }
        for store in storesByKey.values {
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                return session
            }
        }
        return nil
    }

    func snapshot(forSessionID sessionID: String) -> DirectorySessionSnapshot? {
        guard let store = ownerStore(forSessionID: sessionID) else { return nil }
        return DirectorySessionSnapshot(
            session: store.sessions.first(where: { $0.id == sessionID })
                ?? (store.selectedSession?.id == sessionID ? store.selectedSession : nil),
            status: store.sessionStatuses[sessionID] ?? store.syncState.sessionStatusesBySessionID[sessionID],
            messages: store.syncState.messageEnvelopes(forSessionID: sessionID),
            todos: store.syncState.todosBySessionID[sessionID] ?? [],
            permissions: store.syncState.permissionsBySessionID[sessionID] ?? [],
            questions: store.syncState.questionsBySessionID[sessionID] ?? []
        )
    }

    func reset() {
        openedSessionIDs = []
        v2PendingSessionIDs.removeAll()
        v2NeedsReconnectHydration = false
        let store = DirectoryStore()
        v2LifecycleRevisions = [:]
        v2ProjectRevision = 0
        v2DeletedSessionIDs = []
        storesByKey = [Self.globalKey: store]
        activeKey = Self.globalKey
        activeStore = store
        observeSessionOpenings(in: store)
        generation &+= 1
        storeCollectionRevision &+= 1
    }
}

@MainActor
final class DirectorySyncStore: ObservableObject {
    @Published private(set) var version: Int = 0
    var state: OpenCodeDirectorySyncState {
        didSet { version &+= 1 }
    }

    init(state: OpenCodeDirectorySyncState = OpenCodeDirectorySyncState()) {
        self.state = state
    }

    func messageCount(forSessionID sessionID: String) -> Int {
        state.messageCount(forSessionID: sessionID)
    }

    func messageEnvelopes(forSessionID sessionID: String, suffix count: Int) -> [OpenCodeMessageEnvelope] {
        state.messageEnvelopes(forSessionID: sessionID, suffix: count)
    }

    func userMessageCount(forSessionID sessionID: String) -> Int {
        state.userMessageCount(forSessionID: sessionID)
    }

    func latestUserMessageEnvelope(
        beforeSuffixCount suffixCount: Int,
        forSessionID sessionID: String
    ) -> OpenCodeMessageEnvelope? {
        state.latestUserMessageEnvelope(
            beforeSuffixCount: suffixCount,
            forSessionID: sessionID
        )
    }

    func messageCountIncludingLatestUserRounds(
        _ roundCount: Int,
        fallbackMessageCount: Int,
        forSessionID sessionID: String
    ) -> Int {
        state.messageCountIncludingLatestUserRounds(
            roundCount,
            fallbackMessageCount: fallbackMessageCount,
            forSessionID: sessionID
        )
    }

    func containsMessage(id messageID: String, forSessionID sessionID: String) -> Bool {
        state.messagesBySessionID[sessionID]?.contains { $0.id == messageID } == true
    }
}

enum OpenCodeSessionPaginationState: Equatable, Sendable {
    case limit
    case cursor(next: String?)
}

@MainActor
final class DirectoryStore: ObservableObject {
    private static let immediateTranscriptRoundLimit = 1
    private static let immediateTranscriptMessageLimit = 12
    private static let openedSessionHistoryLimit = 12

    @Published var isLoadingSessions: Bool
    @Published var sessions: [OpenCodeSession]
    @Published var sessionTotal: Int
    @Published var sessionLimit: Int
    @Published private(set) var sessionPagination: OpenCodeSessionPaginationState
    @Published var selectedSession: OpenCodeSession? {
        didSet {
            if let selectedSession {
                recordOpenedSession(selectedSession)
                if selectedSession.id != oldValue?.id { onSessionOpened?(selectedSession) }
            }
        }
    }
    fileprivate var onSessionOpened: ((OpenCodeSession) -> Void)?
    @Published private(set) var openedSessionHistory: [OpenCodeSession]
    @Published private(set) var sessionSwitcherPresentation: OpenClientSessionSwitcherPresentation?
    @Published var commands: [OpenCodeCommand]
    @Published var sessionStatuses: [String: String]
    let syncStore: DirectorySyncStore
    private(set) var permissionRevision: UInt = 0
    private(set) var questionRevision: UInt = 0
    private(set) var statusRevision: UInt = 0
    private var statusRevisionsBySessionID: [String: UInt] = [:]
    private(set) var v2SessionRevision: UInt = 0
    let sessionFormStore = SessionFormStore()
    var v2FormsByID: [String: OpenCodeV2Form] {
        Dictionary(sessionFormStore.forms.values.map { form in
            (form.id, OpenCodeV2Form(id: form.id, sessionID: form.sessionID, title: form.title,
                metadata: form.metadata, fields: form.fields.map(\.raw)))
        }, uniquingKeysWith: { first, _ in first })
    }
    private var sessionSwitcherCandidates: [OpenCodeSession] = []
    private var sessionSwitcherSelectedSessionID: String?

    var syncState: OpenCodeDirectorySyncState {
        get { syncStore.state }
        set { syncStore.state = newValue }
    }

    init(
        isLoadingSessions: Bool = false,
        sessions: [OpenCodeSession] = [],
        sessionTotal: Int = 0,
        sessionLimit: Int = 100,
        sessionPagination: OpenCodeSessionPaginationState = .limit,
        selectedSession: OpenCodeSession? = nil,
        commands: [OpenCodeCommand] = [],
        sessionStatuses: [String: String] = [:],
        syncState: OpenCodeDirectorySyncState = OpenCodeDirectorySyncState()
    ) {
        self.isLoadingSessions = isLoadingSessions
        self.sessions = sessions
        self.sessionTotal = sessionTotal
        self.sessionLimit = sessionLimit
        self.sessionPagination = sessionPagination
        self.selectedSession = selectedSession
        self.openedSessionHistory = selectedSession.map { [$0] } ?? []
        self.sessionSwitcherPresentation = nil
        self.commands = commands
        self.sessionStatuses = sessionStatuses
        self.syncStore = DirectorySyncStore(state: syncState)
        sessionFormStore.onCanonicalChange = { [weak self] in self?.objectWillChange.send() }
    }

    func reset() {
        isLoadingSessions = false
        sessions = []
        sessionTotal = 0
        sessionLimit = 100
        sessionPagination = .limit
        selectedSession = nil
        openedSessionHistory = []
        sessionSwitcherPresentation = nil
        sessionSwitcherCandidates = []
        sessionSwitcherSelectedSessionID = nil
        commands = []
        sessionStatuses = [:]
        syncStore.state = OpenCodeDirectorySyncState()
        permissionRevision = 0
        questionRevision = 0
        statusRevision = 0
        statusRevisionsBySessionID = [:]
        v2SessionRevision = 0
        sessionFormStore.reset()
    }

    func previouslyOpenedSession(excluding sessionID: String) -> OpenCodeSession? {
        let availableSessionIDs = Set(sessions.map(\.id))
        return openedSessionHistory.first { session in
            session.id != sessionID && availableSessionIDs.contains(session.id)
        }
    }

    func advanceSessionSwitcher(
        from sessionID: String,
        candidates providedCandidates: [OpenCodeSession]? = nil
    ) -> OpenCodeSession? {
        let candidates: [OpenCodeSession]
        let selectedSessionID: String
        if !sessionSwitcherCandidates.isEmpty, let sessionSwitcherSelectedSessionID {
            candidates = sessionSwitcherCandidates
            selectedSessionID = sessionSwitcherSelectedSessionID
        } else {
            if let providedCandidates {
                var seenIDs = Set<String>()
                candidates = providedCandidates.filter { seenIDs.insert($0.id).inserted }
            } else {
                let availableSessionIDs = Set(sessions.map(\.id))
                candidates = Array(openedSessionHistory.filter { availableSessionIDs.contains($0.id) }.prefix(6))
            }
            guard candidates.contains(where: { $0.id != sessionID }) else { return nil }
            selectedSessionID = sessionID
            sessionSwitcherCandidates = candidates
        }

        let currentIndex = candidates.firstIndex { $0.id == selectedSessionID }
            ?? candidates.firstIndex { $0.id == sessionID }
            ?? -1
        let target = candidates[(currentIndex + 1) % candidates.count]
        sessionSwitcherSelectedSessionID = target.id
        if sessionSwitcherPresentation != nil {
            sessionSwitcherPresentation = OpenClientSessionSwitcherPresentation(
                sessions: candidates,
                selectedSessionID: target.id
            )
        }
        return target
    }

    func revealSessionSwitcher() {
        guard !sessionSwitcherCandidates.isEmpty,
              let sessionSwitcherSelectedSessionID else { return }
        sessionSwitcherPresentation = OpenClientSessionSwitcherPresentation(
            sessions: sessionSwitcherCandidates,
            selectedSessionID: sessionSwitcherSelectedSessionID
        )
    }

    @discardableResult
    func finishSessionSwitcher() -> OpenCodeSession? {
        let selectedSession = sessionSwitcherCandidates.first { $0.id == sessionSwitcherSelectedSessionID }
        sessionSwitcherPresentation = nil
        sessionSwitcherCandidates = []
        sessionSwitcherSelectedSessionID = nil
        return selectedSession
    }

    private func recordOpenedSession(_ session: OpenCodeSession) {
        openedSessionHistory.removeAll { $0.id == session.id }
        openedSessionHistory.insert(session, at: 0)
        if openedSessionHistory.count > Self.openedSessionHistoryLimit {
            openedSessionHistory.removeLast(openedSessionHistory.count - Self.openedSessionHistoryLimit)
        }
    }

    @discardableResult
    func applyDirectoryReload(
        bootstrap: OpenCodeDirectoryBootstrap,
        statuses: [String: String],
        scopedSessions: [OpenCodeSession],
        permissionRevisionAtRequestStart: UInt? = nil,
        questionRevisionAtRequestStart: UInt? = nil
    ) -> Bool {
        var changed = false
        let knownChildren = sessions.filter { !$0.isRootSession && !$0.isArchived }
        let reconciledSessions = Self.deduplicatedSessions(scopedSessions + knownChildren)

        if isLoadingSessions {
            isLoadingSessions = false
            changed = true
        }
        if sessions != reconciledSessions {
            sessions = reconciledSessions
            changed = true
        }
        if sessionTotal != bootstrap.sessionTotal {
            sessionTotal = bootstrap.sessionTotal
            changed = true
        }
        if sessionLimit != bootstrap.sessionLimit {
            sessionLimit = bootstrap.sessionLimit
            changed = true
        }
        if sessionPagination != .limit {
            sessionPagination = .limit
            changed = true
        }
        if commands != bootstrap.commands {
            commands = bootstrap.commands
            changed = true
        }
        if sessionStatuses != statuses {
            sessionStatuses = statuses
            changed = true
        }

        var nextSyncState = syncStore.state
        nextSyncState.sessionStatusesBySessionID = statuses
        if permissionRevisionAtRequestStart == nil || permissionRevisionAtRequestStart == permissionRevision {
            nextSyncState.permissionsBySessionID = Dictionary(grouping: bootstrap.permissions, by: \.sessionID)
        }
        if questionRevisionAtRequestStart == nil || questionRevisionAtRequestStart == questionRevision {
            nextSyncState.questionsBySessionID = Dictionary(grouping: bootstrap.questions, by: \.sessionID)
        }
        if nextSyncState != syncStore.state {
            syncStore.state = nextSyncState
            changed = true
        }

        return changed
    }

    @discardableResult
    func applySessionSelection(
        _ session: OpenCodeSession,
        cachedMessages: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        let syncedMessageCount = syncStore.messageCount(forSessionID: session.id)
        let syncedVisibleMessageCount = syncStore.messageCountIncludingLatestUserRounds(
            Self.immediateTranscriptRoundLimit,
            fallbackMessageCount: Self.immediateTranscriptMessageLimit,
            forSessionID: session.id
        )
        let syncedMessages = syncStore.messageEnvelopes(
            forSessionID: session.id,
            suffix: min(syncedVisibleMessageCount, Self.immediateTranscriptMessageLimit)
        )
        let cachedTail = Self.immediateTranscript(in: cachedMessages)
        let visibleMessages = syncedMessages.isEmpty ? cachedTail : syncedMessages

        if syncedMessageCount == 0, !cachedMessages.isEmpty {
            syncStore.state.replaceMessages(cachedMessages, forSessionID: session.id)
        }
        selectedSession = session

        return visibleMessages
    }

    private static func immediateTranscript(
        in messages: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        guard !messages.isEmpty else { return [] }
        var remainingRounds = immediateTranscriptRoundLimit
        var oldestUserIndex: Int?
        for index in messages.indices.reversed() where (messages[index].info.role ?? "").lowercased() == "user" {
            oldestUserIndex = index
            remainingRounds -= 1
            if remainingRounds == 0 {
                return Array(messages[index...].suffix(immediateTranscriptMessageLimit))
            }
        }
        if let oldestUserIndex {
            return Array(messages[oldestUserIndex...].suffix(immediateTranscriptMessageLimit))
        }
        return Array(messages.suffix(immediateTranscriptMessageLimit))
    }

    func applyTodos(_ todos: [OpenCodeTodo], forSessionID sessionID: String) {
        guard syncStore.state.todosBySessionID[sessionID] != todos else { return }
        syncStore.state.todosBySessionID[sessionID] = todos
    }

    @discardableResult
    func applySessionStatuses(_ statuses: [String: String]) -> Bool {
        var changed = false
        if sessionStatuses != statuses {
            sessionStatuses = statuses
            changed = true
        }
        if syncStore.state.sessionStatusesBySessionID != statuses {
            syncStore.state.sessionStatusesBySessionID = statuses
            changed = true
        }
        return changed
    }

    func applySessionStatus(_ status: String, forSessionID sessionID: String) {
        statusRevision &+= 1
        statusRevisionsBySessionID[sessionID] = statusRevision
        guard sessionStatuses[sessionID] != status
                || syncStore.state.sessionStatusesBySessionID[sessionID] != status else { return }
        sessionStatuses[sessionID] = status
        syncStore.state.sessionStatusesBySessionID[sessionID] = status
    }

    func applyV2ActiveStatuses(_ statuses: [String: String], requestedAtRevision revision: UInt) {
        let ids = Set(sessions.map(\.id)).union(sessionStatuses.keys)
        for id in ids where (statusRevisionsBySessionID[id] ?? 0) <= revision {
            applySessionStatus(statuses[id] ?? "idle", forSessionID: id)
        }
    }

    func applyCanonicalMessages(_ messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) {
        var nextState = syncStore.state
        nextState.replaceMessages(messages, forSessionID: sessionID)
        guard nextState != syncStore.state else { return }
        syncStore.state = nextState
    }

    func applyV2Messages(_ messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) {
        var nextState = syncStore.state
        nextState.replaceMessagesPreservingOrder(messages, forSessionID: sessionID)
        guard nextState != syncStore.state else { return }
        syncStore.state = nextState
    }

    func applyCachedMessageState(_ cached: OpenCodeCachedMessageState, forSessionID sessionID: String) {
        var nextState = syncStore.state
        let previousMessageIDs = Set(nextState.messagesBySessionID[sessionID]?.map(\.id) ?? [])
        let nextMessageIDs = Set(cached.messages.map(\.id))
        for messageID in previousMessageIDs.subtracting(nextMessageIDs) {
            nextState.partsByMessageID[messageID] = nil
        }
        nextState.messagesBySessionID[sessionID] = cached.messages
        for (messageID, parts) in cached.partsByMessageID {
            nextState.partsByMessageID[messageID] = parts
        }
        syncStore.state = nextState
    }

    @discardableResult
    func applyCachedSessions(_ cachedSessions: [OpenCodeSession]) -> Bool {
        var changed = false
        if isLoadingSessions {
            isLoadingSessions = false
            changed = true
        }
        if sessions != cachedSessions {
            sessions = cachedSessions
            changed = true
        }
        let cachedRootCount = cachedSessions.lazy.filter(\.isRootSession).count
        if sessionTotal < cachedRootCount {
            sessionTotal = cachedRootCount
            changed = true
        }
        return changed
    }

    @discardableResult
    func upsertSessions(_ incomingSessions: [OpenCodeSession]) -> Bool {
        var nextSessions = sessions
        for incoming in incomingSessions {
            if let index = nextSessions.firstIndex(where: { $0.id == incoming.id }) {
                nextSessions[index] = nextSessions[index].merged(with: incoming)
            } else {
                nextSessions.append(incoming)
            }
        }
        guard nextSessions != sessions else { return false }
        sessions = nextSessions
        sessionTotal = max(sessionTotal, nextSessions.lazy.filter(\.isRootSession).count)
        return true
    }

    var hasMoreSessions: Bool {
        switch sessionPagination {
        case .limit:
            return sessionTotal > sessions.lazy.filter(\.isRootSession).count
        case let .cursor(next):
            return next != nil
        }
    }

    var nextSessionCursor: String? {
        guard case let .cursor(next) = sessionPagination else { return nil }
        return next
    }

    func applyV2SessionPage(
        _ page: OpenCodeV2SessionPage,
        replacing: Bool,
        requestedCursor: String?,
        limit: Int
    ) {
        let pageIDs = Set(page.sessions.map(\.id))
        let children = sessions.filter { !$0.isRootSession && !$0.isArchived && !pageIDs.contains($0.id) }
        let nextSessions = replacing ? page.sessions + children : Self.deduplicatedSessions(sessions + page.sessions)
        sessions = nextSessions
        sessionLimit = limit
        sessionTotal = nextSessions.filter(\.isRootSession).count
        let nextCursor = page.nextCursor == requestedCursor ? nil : page.nextCursor
        sessionPagination = .cursor(next: nextCursor)
        isLoadingSessions = false
    }

    func insertV2Session(_ session: OpenCodeSession) {
        v2SessionRevision &+= 1
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessionTotal = max(sessionTotal, sessions.filter(\.isRootSession).count)
        if selectedSession?.id == session.id { selectedSession = session }
    }

    func applyV2DiscoveredSessions(_ incoming: [OpenCodeSession], ifUnchangedSince snapshot: [OpenCodeSession]? = nil) {
        let page = incoming.filter { session in
            guard let snapshot else { return true }
            return sessions.first(where: { $0.id == session.id }) == snapshot.first(where: { $0.id == session.id })
        }
        let ids = Set(page.map(\.id))
        v2SessionRevision &+= 1
        sessions = page + sessions.filter { !ids.contains($0.id) }
        sessionTotal = max(sessionTotal, sessions.filter(\.isRootSession).count)
        if let id = selectedSession?.id, let updated = page.first(where: { $0.id == id }) { selectedSession = updated }
    }

    @discardableResult
    func applyV2Event(_ event: OpenCodeV2ManagedEvent) -> Bool {
        guard let sessionID = event.sessionID, let data = event.data.objectValue else { return false }
        if event.isExecutionStarted || event.isExecutionTerminal || event.type == "session.retry.scheduled" {
            applySessionStatus(event.isExecutionTerminal ? "idle" : "busy", forSessionID: sessionID)
            return true
        }
        switch event.type {
        case "session.forked":
            // parentID identifies the fork source, not a subagent parent. Hydrate Session.Info.
            v2SessionRevision &+= 1
            return false
        case "session.created", "session.renamed", "session.moved":
            v2SessionRevision &+= 1
            let previous = sessions.first { $0.id == sessionID } ?? (selectedSession?.id == sessionID ? selectedSession : nil)
            guard event.type == "session.created" || previous != nil else { return false }
            let location = event.routingLocation
            var session = OpenCodeSession(
                id: sessionID,
                title: data["title"]?.stringValue ?? previous?.title,
                workspaceID: event.type == "session.moved" ? location?.workspaceID : location?.workspaceID ?? previous?.workspaceID,
                directory: location?.directory ?? previous?.directory,
                projectID: data["projectID"]?.stringValue ?? previous?.projectID,
                parentID: data["parentID"]?.stringValue ?? previous?.parentID
            )
            session.time = OpenCodeMessageTime(created: previous?.time?.created ?? event.created, updated: event.created)
            insertV2Session(session)
            return true
        case "session.deleted":
            removeV2Session(sessionID: sessionID)
            return true
        case "permission.asked":
            guard let id = data["id"]?.stringValue, let action = data["action"]?.stringValue,
                  let resources = data["resources"]?.arrayValue else { return false }
            let source = data["source"]?.objectValue
            let permission = OpenCodePermission(
                id: id, sessionID: sessionID, permission: action,
                patterns: resources.compactMap(\.stringValue),
                always: data["save"]?.arrayValue?.compactMap(\.stringValue),
                metadata: data["metadata"]?.objectValue,
                tool: source.map { OpenCodePermissionTool(messageID: $0["messageID"]?.stringValue, callID: $0["id"]?.stringValue, name: nil) }
            )
            permissionRevision &+= 1
            var requests = syncState.permissionsBySessionID[sessionID] ?? []
            requests.removeAll { $0.id == id }
            requests.append(permission)
            syncStore.state.permissionsBySessionID[sessionID] = requests
            return true
        case "permission.replied":
            guard let id = data["requestID"]?.stringValue else { return false }
            removeV2Permission(id: id, sessionID: sessionID)
            return true
        case "form.created":
            guard let value = data["form"], let encoded = try? JSONEncoder().encode(value),
                  let form = try? JSONDecoder().decode(OpenCodeV2Form.self, from: encoded) else { return false }
            applySessionFormCreated(form.backendForm)
            return true
        case "form.replied", "form.cancelled":
            guard let id = data["id"]?.stringValue else { return false }
            removeV2Question(id: id, sessionID: sessionID)
            return true
        default:
            return false
        }
    }

    func removeV2Session(sessionID: String) {
        v2SessionRevision &+= 1
        permissionRevision &+= 1
        questionRevision &+= 1
        statusRevision &+= 1
        statusRevisionsBySessionID[sessionID] = statusRevision
        sessions.removeAll { $0.id == sessionID }
        sessionTotal = sessions.filter(\.isRootSession).count
        openedSessionHistory.removeAll { $0.id == sessionID }
        sessionSwitcherCandidates.removeAll { $0.id == sessionID }
        if sessionSwitcherSelectedSessionID == sessionID { _ = finishSessionSwitcher() }
        if selectedSession?.id == sessionID { selectedSession = nil }
        sessionStatuses[sessionID] = nil
        syncStore.state.removeMessages(forSessionID: sessionID)
        syncStore.state.sessionStatusesBySessionID[sessionID] = nil
        syncStore.state.todosBySessionID[sessionID] = nil
        syncStore.state.permissionsBySessionID[sessionID] = nil
        syncStore.state.questionsBySessionID[sessionID] = nil
        syncStore.state.sessionDiffsBySessionID[sessionID] = nil
        sessionFormStore.removeSession(sessionID)
    }

    func applyV2Interactions(
        permissions: [OpenCodePermission], questions: [OpenCodeQuestionRequest],
        permissionRevisionAtRequestStart: UInt? = nil, questionRevisionAtRequestStart: UInt? = nil
    ) {
        let nextPermissions = Dictionary(grouping: permissions, by: \.sessionID)
        let nextQuestions = Dictionary(grouping: questions, by: \.sessionID)
        if (permissionRevisionAtRequestStart == nil || permissionRevisionAtRequestStart == permissionRevision),
           syncStore.state.permissionsBySessionID != nextPermissions {
            syncStore.state.permissionsBySessionID = nextPermissions
        }
        if (questionRevisionAtRequestStart == nil || questionRevisionAtRequestStart == questionRevision),
           syncStore.state.questionsBySessionID != nextQuestions {
            syncStore.state.questionsBySessionID = nextQuestions
        }
    }

    func applyV2SessionInteractions(
        sessionID: String, permissions: [OpenCodePermission], forms: [OpenCodeV2Form],
        permissionRevisionAtRequestStart: UInt, questionRevisionAtRequestStart: UInt
    ) {
        if permissionRevision == permissionRevisionAtRequestStart {
            permissionRevision &+= 1
            syncStore.state.permissionsBySessionID[sessionID] = permissions.filter { $0.sessionID == sessionID }
        }
        if questionRevision == questionRevisionAtRequestStart {
            questionRevision &+= 1
            let scoped = forms.filter { $0.sessionID == sessionID }
            sessionFormStore.replacePendingForms(scoped.map(\.backendForm), sessionID: sessionID)
            syncStore.state.questionsBySessionID[sessionID] = nil
        }
    }

    func removeV2Permission(id: String, sessionID: String) {
        permissionRevision &+= 1
        guard var requests = syncStore.state.permissionsBySessionID[sessionID] else { return }
        requests.removeAll { $0.id == id }
        syncStore.state.permissionsBySessionID[sessionID] = requests.isEmpty ? nil : requests
    }

    func removeV2Question(id: String, sessionID: String) {
        questionRevision &+= 1
        sessionFormStore.settle(.init(sessionID: sessionID, formID: id))
        guard var requests = syncStore.state.questionsBySessionID[sessionID] else { return }
        requests.removeAll { $0.id == id }
        syncStore.state.questionsBySessionID[sessionID] = requests.isEmpty ? nil : requests
    }

    /// Generic optional-service hydration. Capture sessionFormStore.revision before the read.
    func applySessionForms(_ forms: [BackendForm], sessionID: String, ifUnchangedSince revision: UInt) {
        guard sessionFormStore.revision == revision else { return }
        questionRevision &+= 1
        sessionFormStore.replacePendingForms(forms, sessionID: sessionID, ifUnchangedSince: revision)
        syncStore.state.questionsBySessionID[sessionID] = nil
    }

    func applySessionFormCreated(_ form: BackendForm) {
        questionRevision &+= 1
        sessionFormStore.upsert(form)
        syncStore.state.questionsBySessionID[form.sessionID]?.removeAll { $0.id == form.id }
    }

    func applySessionFormSettled(_ key: BackendFormKey) {
        removeV2Question(id: key.formID, sessionID: key.sessionID)
    }

    func applySessionFormEvent(_ event: BackendSessionFormsEvent) {
        switch event {
        case .created(let form): applySessionFormCreated(form)
        case .answered(let key, _), .cancelled(let key): applySessionFormSettled(key)
        }
    }

    func appendMessage(_ message: OpenCodeMessageEnvelope, forSessionID sessionID: String) {
        syncStore.state.appendMessageEnvelope(message, forSessionID: sessionID)
    }

    @discardableResult
    func removeMessage(sessionID: String, messageID: String) -> Bool {
        syncStore.state.removeMessage(sessionID: sessionID, messageID: messageID)
    }

    @discardableResult
    func applyPermissions(_ permissions: [OpenCodePermission], ifUnchangedSince revision: UInt) -> Bool {
        guard permissionRevision == revision else { return false }
        let grouped = Dictionary(grouping: permissions, by: \.sessionID)
        guard syncStore.state.permissionsBySessionID != grouped else { return true }
        syncStore.state.permissionsBySessionID = grouped
        return true
    }

    func clearPermissions() {
        guard !syncStore.state.permissionsBySessionID.isEmpty else { return }
        syncStore.state.permissionsBySessionID = [:]
    }

    @discardableResult
    func applyQuestions(_ questions: [OpenCodeQuestionRequest], ifUnchangedSince revision: UInt) -> Bool {
        guard questionRevision == revision else { return false }
        let grouped = Dictionary(grouping: questions, by: \.sessionID)
        guard syncStore.state.questionsBySessionID != grouped else { return true }
        syncStore.state.questionsBySessionID = grouped
        return true
    }

    func clearQuestions() {
        guard !syncStore.state.questionsBySessionID.isEmpty else { return }
        syncStore.state.questionsBySessionID = [:]
    }

    func recordInteractionEvent(_ event: OpenCodeTypedEvent) {
        switch event {
        case .permissionAsked, .permissionReplied:
            permissionRevision &+= 1
        case .questionAsked, .questionReplied, .questionRejected:
            questionRevision &+= 1
        default:
            break
        }
    }

    @discardableResult
    func applySelectedSessionAfterReload(_ nextSelectedSession: OpenCodeSession?) -> Bool {
        guard selectedSession != nextSelectedSession else { return false }
        selectedSession = nextSelectedSession
        return true
    }

    @discardableResult
    func applyReducedEventState(
        _ state: OpenCodeDirectoryEventState,
        scopedSessions: [OpenCodeSession]
    ) -> Bool {
        var changed = false

        let deduplicatedSessions = Self.deduplicatedSessions(scopedSessions)
        if deduplicatedSessions != sessions {
            sessions = deduplicatedSessions
            changed = true
        }
        if state.selectedSession != selectedSession {
            selectedSession = state.selectedSession
            changed = true
        }
        if state.sessionStatuses != sessionStatuses {
            sessionStatuses = state.sessionStatuses
            changed = true
        }
        if state.syncState != syncStore.state {
            syncStore.state = state.syncState
            changed = true
        }

        return changed
    }

    private static func deduplicatedSessions(_ sessions: [OpenCodeSession]) -> [OpenCodeSession] {
        var result: [OpenCodeSession] = []
        var indexByID: [String: Int] = [:]
        for session in sessions {
            if let index = indexByID[session.id] {
                result[index] = result[index].merged(with: session)
            } else {
                indexByID[session.id] = result.count
                result.append(session)
            }
        }
        return result
    }
}
