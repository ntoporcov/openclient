import Combine
import Foundation

/// A presentation lifetime borrowing the app's canonical stores and connection. Never owns SSE.
@MainActor
final class ChatWindowContext: ObservableObject {
    let id = UUID()
    let connectionID: UUID
    let registryGeneration: Int
    let composer = ComposerStore()
    let presentation = ChatPresentationStore()
    let browser = BrowserStore()
    let mcpStore = MCPStore()
    private let connection: BackendConnection
    private let parentContext: ChatWindowContext?
    private let parentNavigationRevision: UInt?
    lazy var mcpFacade = MCPFacade(store: mcpStore, clientProvider: { [weak self] in
        guard let self, self.isCurrent else { return nil }
        return try? self.connection.requireOpenCodeClient(for: .mcp)
    }, directoryProvider: { [weak self] in self?.session.directory },
       apiProfileProvider: { [weak self] in self?.connection.openCodeCompatibility?.profile },
       workspaceIDProvider: { [weak self] in self?.session.workspaceID },
       contextIDProvider: { [weak self] in self?.contextID })
    let commandHoldMonitor = OpenClientCommandHoldMonitor()
    @Published private(set) var session: OpenCodeSession
    @Published private(set) var owner: DirectoryStore
    @Published private(set) var navigationRevision: UInt = 0
    @Published private(set) var isLoading = false
    @Published private(set) var isClosed = false
    @Published var errorMessage: String?
    @Published private(set) var sessionSwitcherPresentation: OpenClientSessionSwitcherPresentation?
    private var switcherCandidates: [OpenCodeSession] = []
    private var switcherTarget: String?
    var stopAudio: (() -> Void)?
    private(set) var history: [OpenCodeSession] = []
    private var drafts: [String: (String, [OpenCodeAgentMention], [OpenCodeComposerAttachment])] = [:]
    private var hydration: Task<Void, Never>?
    private var hydrationID = UUID()
    private var observations: Set<AnyCancellable> = []
    private var formEditors: [ObjectIdentifier: SessionFormStore] = [:]
    unowned let model: AppViewModel

    init(model: AppViewModel, connection: BackendConnection, session: OpenCodeSession, owner: DirectoryStore,
         parentContext: ChatWindowContext? = nil) {
        self.model = model
        self.connection = connection
        self.parentContext = parentContext
        parentNavigationRevision = parentContext?.navigationRevision
        connectionID = connection.id
        registryGeneration = model.directoryStoreRegistry.generation
        self.session = session
        self.owner = owner
        history = [session]
        model.$backendConnection.dropFirst().sink { [weak self] next in
            guard let self, next?.id != self.connectionID else { return }
            self.close()
        }.store(in: &observations)
        model.connectionStore.$isConnected.dropFirst().sink { [weak self] connected in
            if !connected { self?.close() }
        }.store(in: &observations)
        model.directoryStoreRegistry.$generation.dropFirst().sink { [weak self] _ in self?.close() }
            .store(in: &observations)
        parentContext?.$navigationRevision.dropFirst().sink { [weak self] _ in self?.close() }
            .store(in: &observations)
        model.windowSessionInterests[id] = session.id
        model.updateEventInterestSnapshot()
        browser.selectContext(connectionID: connectionID, projectID: session.projectID ?? "global", directory: session.directory)
    }

    var isCurrent: Bool {
        !isClosed && model.connectionStore.isConnected
            && model.backendConnection?.id == connectionID && model.backendConnection?.isClosed == false
            && model.directoryStoreRegistry.generation == registryGeneration
            && model.directoryStoreRegistry.key(for: owner) != nil
            && !model.directoryStoreRegistry.isV2SessionDeleted(session.id)
            && owner.sessions.contains { $0.id == session.id && $0.directory == session.directory && $0.workspaceID == session.workspaceID }
            && (parentContext?.isCurrent ?? true) && parentContext?.navigationRevision == parentNavigationRevision
    }

    var contextID: String { "\(connectionID)|\(registryGeneration)|\(id)|\(navigationRevision)" }

    func saveDraft() {
        drafts[session.id] = (composer.draftMessage, composer.draftAgentMentions, composer.draftAttachments)
    }

    func advanceSessionSwitcher(candidates: [OpenCodeSession]? = nil) -> OpenCodeSession? {
        guard isCurrent else { return nil }
        if switcherCandidates.isEmpty {
            let available = candidates ?? history.reversed().compactMap { model.directoryStoreRegistry.session(matching: $0.id) }
            switcherCandidates = Array(available.filter {
                !$0.isArchived && !model.directoryStoreRegistry.isV2SessionDeleted($0.id)
            }.prefix(6))
        }
        guard switcherCandidates.contains(where: { $0.id != session.id }) else { return nil }
        let index = switcherCandidates.firstIndex { $0.id == (switcherTarget ?? session.id) } ?? -1
        let target = switcherCandidates[(index + 1) % switcherCandidates.count]
        switcherTarget = target.id
        if sessionSwitcherPresentation != nil { revealSessionSwitcher() }
        return target
    }

    func revealSessionSwitcher() {
        guard isCurrent, let switcherTarget else { return }
        sessionSwitcherPresentation = .init(sessions: switcherCandidates, selectedSessionID: switcherTarget)
    }

    func finishSessionSwitcher() -> OpenCodeSession? {
        let target = isCurrent ? switcherCandidates.first { $0.id == switcherTarget } : nil
        sessionSwitcherPresentation = nil
        switcherCandidates = []
        switcherTarget = nil
        return target
    }

    func formEditor(for canonical: SessionFormStore) -> SessionFormStore {
        let key = ObjectIdentifier(canonical)
        if let editor = formEditors[key] { return editor }
        let editor = SessionFormStore(canonical: canonical)
        formEditors[key] = editor
        return editor
    }

    func select(_ session: OpenCodeSession, owner: DirectoryStore) async {
        guard isCurrent else { return }
        if self.session.id != session.id || self.owner !== owner {
            saveDraft()
            hydration?.cancel()
            hydration = nil
            mcpStore.reset()
            navigationRevision &+= 1
            self.session = session
            self.owner = owner
            history.removeAll { $0.id == session.id }
            history.append(session)
            if history.count > 20 { history.removeFirst(history.count - 20) }
            let draft = drafts[session.id]
            composer.resetActiveDraft(text: draft?.0 ?? "", agentMentions: draft?.1 ?? [], attachments: draft?.2 ?? [])
            composer.isStreamingFocused = false
            presentation.isShowingForkSessionSheet = false
            model.windowSessionInterests[id] = session.id
            model.updateEventInterestSnapshot()
            browser.selectContext(connectionID: connectionID, projectID: session.projectID ?? "global", directory: session.directory)
        }
        await hydrate()
    }

    func hydrate() async {
        guard isCurrent else { return }
        if let hydration { await hydration.value; return }
        let requestID = UUID()
        hydrationID = requestID
        let session = session
        let owner = owner
        let revision = navigationRevision
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.hydrationID == requestID {
                    self.hydration = nil
                    self.isLoading = false
                }
            }
            do {
                if self.model.connectionStore.apiProfile == .v2 {
                    await self.model.reconcileV2TimelineFromEvent(sessionID: session.id, presentationIndependent: true)
                } else {
                    try await self.model.loadMessages(for: session, prefetchToolDetails: false,
                        refreshTodos: false, presentationIndependent: true, canonicalOwner: owner)
                }
                guard !Task.isCancelled, self.isCurrent, self.navigationRevision == revision else { return }
                if self.model.connectionStore.apiProfile == .v2 {
                    await self.model.hydrateV2Interactions(for: session)
                } else {
                    await self.model.loadAllPermissions(for: session)
                    await self.model.loadAllQuestions(for: session)
                    guard !Task.isCancelled, self.isCurrent, self.navigationRevision == revision else { return }
                    await self.model.loadTodos(for: session)
                }
            } catch {
                if self.isCurrent, self.navigationRevision == revision, !Task.isCancelled {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
        hydration = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func close() {
        guard !isClosed else { return }
        saveDraft()
        isClosed = true
        commandHoldMonitor.cancel()
        _ = finishSessionSwitcher()
        navigationRevision &+= 1
        hydration?.cancel()
        hydration = nil
        isLoading = false
        composer.isStreamingFocused = false
        stopAudio?()
        stopAudio = nil
        browser.clearAllBrowserSessions()
        mcpStore.reset()
        formEditors.values.forEach { $0.reset() }
        formEditors.removeAll()
        model.windowSessionInterests[id] = nil
        model.updateEventInterestSnapshot()
    }
}

/// AVAudioSession is process-wide; controller-local stop must release only its own lease.
@MainActor
final class ConversationAudioLease {
    static let shared = ConversationAudioLease()
    private(set) var ownerID: UUID?
    private var revoke: (() -> Void)?

    func acquire(_ id: UUID, revoke: @escaping () -> Void) {
        guard ownerID != id else { return }
        self.revoke?()
        ownerID = id
        self.revoke = revoke
    }

    @discardableResult
    func release(_ id: UUID) -> Bool {
        guard ownerID == id else { return false }
        ownerID = nil
        revoke = nil
        return true
    }
}
