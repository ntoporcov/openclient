import Combine
import Foundation

@MainActor
final class TerminalFacade: ObservableObject {
    typealias ConnectionRunner = @Sendable (
        OpenCodePTYConnection, URLRequest, Int,
        @escaping @Sendable (OpenCodePTYSocketEvent) async -> Void
    ) async throws -> Void

    enum SpecialKey {
        case escape
        case tab
        case interrupt
        case left
        case down
        case up
        case right
    }

    struct RendererInput {
        let insertText: (String) -> Void
        let pasteText: (String) -> Void
        let setControlModifier: (Bool) -> Void
        let setAltModifier: (Bool) -> Void
        let sendSpecialKey: (SpecialKey) -> Void
        let focus: () -> Void
        let dismissKeyboard: () -> Void
    }

    struct Snapshot: Equatable {
        let directory: String?
        let terminals: [OpenClientTerminalTab]
        let activeTerminalID: String?
        let isLoadingTerminals: Bool
        let isCreatingTerminal: Bool
        let connectionState: OpenClientTerminalConnectionState
        let errorMessage: String?
        let fontSize: Float
        let isControlModifierActive: Bool
        let isAltModifierActive: Bool

        var activeTerminal: OpenClientTerminalTab? {
            guard let activeTerminalID else { return nil }
            return terminals.first { $0.id == activeTerminalID }
        }
    }

    private let store: TerminalStore
    private let clientProvider: () -> OpenCodeAPIClient?
    private let directoryProvider: () -> String?
    private let apiProfileProvider: () -> OpenCodeAPIProfile?
    private let generationProvider: () -> UInt
    private let workspaceIDProvider: () -> String?
    private let connectionRunner: ConnectionRunner
    private struct Identity: Equatable, Sendable {
        let config: OpenCodeServerConfig?
        let profile: OpenCodeAPIProfile?
        let generation: UInt
    }
    private struct Context: Equatable, Sendable {
        let identity: Identity
        let directory: String
        let workspaceID: String?
        let epoch: UInt

        var key: String { TerminalStore.workspaceKey(directory: directory, workspaceID: workspaceID) }
        var isV2: Bool { identity.profile == .v2 }
    }
    private var identity: Identity?
    private var epoch: UInt = 0
    private var inventoryRevision: UInt = 0
    private var connection = OpenCodePTYConnection()
    private var observation: AnyCancellable?
    private var connectionTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var pendingResize: (id: UUID, terminalID: String, rows: Int, columns: Int)?
    private var rendererOutputHandlers: [UUID: (String) -> Void] = [:]
    private var rendererInput: RendererInput?
    private var attachedTerminalID: String?
    private var attachedRendererID: UUID?
    private var attachedContext: Context?
    private var hydratedScopes: Set<String> = []
    private var removedTerminalKeys: Set<String> = []
    @Published private(set) var isControlModifierActive = false
    @Published private(set) var isAltModifierActive = false

    init(
        store: TerminalStore,
        clientProvider: @escaping () -> OpenCodeAPIClient?,
        directoryProvider: @escaping () -> String?,
        apiProfileProvider: @escaping () -> OpenCodeAPIProfile? = { .legacy },
        generationProvider: @escaping () -> UInt = { 0 },
        workspaceIDProvider: @escaping () -> String? = { nil },
        connectionRunner: @escaping ConnectionRunner = { connection, request, cursor, onEvent in
            try await connection.run(request: request, initialCursor: cursor, onEvent: onEvent)
        }
    ) {
        self.store = store
        self.clientProvider = clientProvider
        self.directoryProvider = directoryProvider
        self.apiProfileProvider = apiProfileProvider
        self.generationProvider = generationProvider
        self.workspaceIDProvider = workspaceIDProvider
        self.connectionRunner = connectionRunner
        observation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var snapshot: Snapshot {
        let workspace = store.activeWorkspace
        return Snapshot(
            directory: store.activeDirectory,
            terminals: workspace.terminals,
            activeTerminalID: workspace.activeTerminalID,
            isLoadingTerminals: store.isLoadingTerminals,
            isCreatingTerminal: store.isCreatingTerminal,
            connectionState: store.connectionState,
            errorMessage: store.errorMessage,
            fontSize: store.fontSize,
            isControlModifierActive: isControlModifierActive,
            isAltModifierActive: isAltModifierActive
        )
    }

    nonisolated static func softwareInputBytes(for text: String) -> [UInt8] {
        if text == "\n" || text == "\r" || text == "\r\n" {
            return [0x0D]
        }
        return Array(text.utf8)
    }

    nonisolated static func connectionCursor(
        initialCursor: Int,
        latestCursor: Int?,
        attempt: Int
    ) -> Int {
        attempt == 0 ? initialCursor : latestCursor ?? initialCursor
    }

    func prepareForPresentation() {
        guard let context = synchronizeScope(), !hydratedScopes.contains(context.key) else { return }
        Task { [weak self] in
            guard let self, self.isCurrent(context) else { return }
            await self.refreshTerminals()
        }
    }

    func resetForConnectionChange() {
        epoch &+= 1
        inventoryRevision &+= 1
        detachRenderer()
        identity = nil
        hydratedScopes.removeAll()
        removedTerminalKeys.removeAll()
        store.reset()
    }

    func refreshAfterEventReconnect() async {
        hydratedScopes.removeAll()
        inventoryRevision &+= 1
        guard store.activeDirectory != nil else { return }
        await refreshTerminals()
    }

    private var currentIdentity: Identity {
        Identity(config: clientProvider()?.config, profile: apiProfileProvider(), generation: generationProvider())
    }

    private func synchronizeScope() -> Context? {
        let next = currentIdentity
        if let identity, identity != next { resetForConnectionChange() }
        identity = next
        guard next.profile != nil, let directory = directoryProvider(), !directory.isEmpty else {
            resetForConnectionChange()
            return nil
        }
        let workspaceID = workspaceIDProvider().flatMap { $0.isEmpty ? nil : $0 }
        if store.activeDirectory != directory || store.activeWorkspaceID != workspaceID {
            epoch &+= 1
            detachRenderer()
            store.activate(directory: directory, workspaceID: workspaceID)
        }
        return Context(identity: next, directory: directory, workspaceID: workspaceID, epoch: epoch)
    }

    private func isCurrent(_ context: Context) -> Bool {
        context.epoch == epoch && context.identity == currentIdentity
            && context.directory == directoryProvider()
            && context.workspaceID == workspaceIDProvider().flatMap { $0.isEmpty ? nil : $0 }
            && store.activeDirectory == context.directory && store.activeWorkspaceID == context.workspaceID
    }

    func refreshTerminals() async {
        guard let context = synchronizeScope(), let client = clientProvider(),
              store.beginLoadingTerminals() else { return }
        defer {
            if isCurrent(context) {
                store.finishLoadingTerminals()
            }
        }
#if DEBUG
        if isTerminalScreenshotFixture {
            hydratedScopes.insert(context.key)
            return
        }
#endif
        do {
            while isCurrent(context), !Task.isCancelled {
                let revision = inventoryRevision
                let terminals = try await (context.isV2
                    ? client.listV2PTYs(directory: context.directory, workspaceID: context.workspaceID)
                    : client.listPTYs(directory: context.directory, workspaceID: context.workspaceID))
                guard isCurrent(context), !Task.isCancelled else { return }
                // An event or reconnect during the read invalidates that snapshot.
                guard revision == inventoryRevision else { continue }
                let visible = terminals.filter {
                    !ProviderUsageCredentialImportHelper.owns($0)
                        && !removedTerminalKeys.contains(context.key + "\u{0000}" + $0.id)
                }
                store.replaceTerminals(visible, directory: context.directory, workspaceID: context.workspaceID)
                if let id = attachedTerminalID, !store.activeWorkspace.terminals.contains(where: { $0.id == id }) {
                    detachRenderer()
                }
                hydratedScopes.insert(context.key)
                return
            }
        } catch {
            guard isCurrent(context), !Task.isCancelled else { return }
            store.setError(error)
        }
    }

    func createTerminal() {
        guard let context = synchronizeScope(), let client = clientProvider(),
              store.beginCreatingTerminal() else { return }
        let title: String
#if DEBUG
        title = ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_TERMINAL_TITLE"]
            ?? "Terminal \(store.activeWorkspace.terminals.count + 1)"
#else
        title = "Terminal \(store.activeWorkspace.terminals.count + 1)"
#endif

        Task { [weak self] in
            guard let self, isCurrent(context) else { return }
            defer { if isCurrent(context) { store.finishCreatingTerminal() } }
            do {
                let terminal = try await (context.isV2
                    ? client.createV2PTY(title: title, directory: context.directory, workspaceID: context.workspaceID)
                    : client.createPTY(title: title, directory: context.directory, workspaceID: context.workspaceID))
                guard isCurrent(context), !Task.isCancelled,
                      !removedTerminalKeys.contains(context.key + "\u{0000}" + terminal.id) else { return }
                _ = apply(.ptyCreated(terminal), directory: context.directory, workspaceID: context.workspaceID)
            } catch {
                guard isCurrent(context), !Task.isCancelled else { return }
                store.setError(error)
            }
        }
    }

    func selectTerminal(id: String) {
        guard let context = synchronizeScope() else { return }
        if store.activeWorkspace.activeTerminalID != id {
            detachRenderer()
        }
        store.select(id: id, directory: context.directory, workspaceID: context.workspaceID)
    }

    func closeTerminal(id: String) {
        guard let context = synchronizeScope(), let client = clientProvider() else { return }
        removeTerminal(id: id, directory: context.directory, workspaceID: context.workspaceID)
        Task { [weak self] in
            guard let self, isCurrent(context) else { return }
            do {
                if context.isV2 {
                    try await client.deleteV2PTY(id: id, directory: context.directory, workspaceID: context.workspaceID)
                } else {
                    try await client.deletePTY(id: id, directory: context.directory, workspaceID: context.workspaceID)
                }
            } catch {
                guard isCurrent(context), !Task.isCancelled else { return }
                removedTerminalKeys.remove(context.key + "\u{0000}" + id)
                hydratedScopes.remove(context.key)
                inventoryRevision &+= 1
                store.setError(error)
            }
        }
    }

    func attachRenderer(
        rendererID: UUID,
        terminalID: String,
        output: @escaping (String) -> Void,
        input: RendererInput
    ) {
        guard let context = synchronizeScope(),
              store.activeWorkspace.activeTerminalID == terminalID else { return }
#if DEBUG
        if isTerminalScreenshotFixture {
            attachedTerminalID = terminalID
            attachedRendererID = rendererID
            attachedContext = context
            rendererOutputHandlers[rendererID] = output
            rendererInput = input
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.attachedTerminalID == terminalID,
                      self.attachedRendererID == rendererID,
                      self.isCurrent(context) else { return }
                self.store.setConnectionState(.connected)
                self.rendererOutputHandlers.values.forEach { $0(Self.screenshotFixtureTranscript) }
            }
            return
        }
#endif
        if attachedTerminalID == terminalID, attachedRendererID == rendererID {
            rendererOutputHandlers[rendererID] = output
            rendererInput = input
            return
        }

        let previousConnection = connection
        disconnectRendererResources()
        Task {
            await previousConnection.disconnect()
        }
        attachedTerminalID = terminalID
        attachedRendererID = rendererID
        attachedContext = context
        rendererOutputHandlers[rendererID] = output
        rendererInput = input
        // A new Ghostty surface has no screen state. Replay the server buffer so
        // terminal contents, modes, and cursor position are reconstructed.
        let initialCursor = 0
        let rendererConnection = connection
        connectionTask = Task { [weak self] in
            await self?.runConnection(
                terminalID: terminalID,
                rendererID: rendererID,
                context: context,
                initialCursor: initialCursor,
                connection: rendererConnection
            )
        }
    }

    func detachRenderer(terminalID: String? = nil, rendererID: UUID? = nil) {
        if let terminalID, attachedTerminalID != terminalID { return }
        if let rendererID, attachedRendererID != rendererID { return }
        let detachedConnection = connection
        disconnectRendererResources()
        if isControlModifierActive {
            isControlModifierActive = false
        }
        if isAltModifierActive {
            isAltModifierActive = false
        }
        if store.connectionState != .disconnected {
            store.setConnectionState(.disconnected)
        }
        Task {
            await detachedConnection.disconnect()
        }
    }

    @discardableResult
    func send(_ bytes: [UInt8], terminalID: String, rendererID: UUID) -> Bool {
        guard attachedTerminalID == terminalID,
              attachedRendererID == rendererID,
              let context = attachedContext, isCurrent(context),
              store.connectionState == .connected else { return false }
        let activeConnection = connection
        Task { [weak self] in
            guard let self, isCurrent(context), attachedRendererID == rendererID,
                  connection === activeConnection else { return }
            do {
                try await activeConnection.send(bytes)
            } catch where error is CancellationError {
            } catch {
                guard isCurrent(context), attachedRendererID == rendererID,
                      connection === activeConnection else { return }
                store.setError(error)
            }
        }
        return true
    }

    func insertText(_ text: String) {
        rendererInput?.insertText(text)
        rendererInput?.focus()
    }

    func pasteText(_ text: String) {
        rendererInput?.pasteText(text)
        rendererInput?.focus()
    }

    func sendSpecialKey(_ key: SpecialKey) {
        rendererInput?.sendSpecialKey(key)
        rendererInput?.focus()
    }

    func toggleControlModifier() {
        isControlModifierActive.toggle()
        rendererInput?.setControlModifier(isControlModifierActive)
        rendererInput?.focus()
    }

    func toggleAltModifier() {
        isAltModifierActive.toggle()
        rendererInput?.setAltModifier(isAltModifierActive)
        rendererInput?.focus()
    }

    func syncModifierState(control: Bool, alt: Bool) {
        isControlModifierActive = control
        isAltModifierActive = alt
    }

    func dismissKeyboard() {
        rendererInput?.dismissKeyboard()
    }

    func setFontSize(_ fontSize: Float) {
        store.setFontSize(fontSize)
    }

    func resize(terminalID: String, rows: Int, columns: Int) {
#if DEBUG
        if isTerminalScreenshotFixture {
            return
        }
#endif
        guard rows > 0, columns > 0,
              let context = synchronizeScope(), let client = clientProvider(),
              store.activeWorkspace.activeTerminalID == terminalID else { return }
        if let pendingResize, pendingResize.terminalID == terminalID,
           pendingResize.rows == rows, pendingResize.columns == columns { return }
        let terminal = store.activeWorkspace.terminals.first { $0.id == terminalID }
        guard pendingResize != nil || terminal?.rows != rows || terminal?.columns != columns else { return }
        resizeTask?.cancel()
        let resizeID = UUID()
        pendingResize = (resizeID, terminalID, rows, columns)
        // A canceled PUT may still reach the server. Treat dimensions as unknown until
        // the latest request is acknowledged, including across renderer replacement.
        store.updateSize(rows: nil, columns: nil, id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self, isCurrent(context),
                  store.activeWorkspace.activeTerminalID == terminalID else { return }
            defer {
                if pendingResize?.id == resizeID {
                    pendingResize = nil
                    resizeTask = nil
                }
            }
            do {
                let info = try await (context.isV2
                    ? client.updateV2PTY(id: terminalID, rows: rows, columns: columns, directory: context.directory, workspaceID: context.workspaceID)
                    : client.updatePTY(id: terminalID, rows: rows, columns: columns, directory: context.directory, workspaceID: context.workspaceID))
                guard isCurrent(context), !Task.isCancelled,
                      store.activeWorkspace.activeTerminalID == terminalID else { return }
                _ = apply(.ptyUpdated(info), directory: context.directory, workspaceID: context.workspaceID)
                store.updateSize(rows: rows, columns: columns, id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
            } catch where error is CancellationError {
            } catch {
                guard isCurrent(context), !Task.isCancelled else { return }
                store.setError(error)
            }
        }
    }

    @discardableResult
    func consume(_ event: OpenCodeManagedEvent) -> Bool {
        guard event.envelope.type.hasPrefix("pty."),
              apiProfileProvider() == .legacy, synchronizeScope() != nil else { return false }
        return apply(event.typed, directory: event.directory, workspaceID: nil)
    }

    @discardableResult
    func consumeV2(_ event: OpenCodeV2ManagedEvent, generation: UInt? = nil) -> Bool {
        guard apiProfileProvider() == .v2,
              generation == nil || generation == generationProvider(),
              ["pty.created", "pty.updated", "pty.exited", "pty.deleted"].contains(event.type),
              let location = event.location else { return false }
        struct Payload: Decodable {
            let info: OpenCodePTY?
            let id: String?
            let exitCode: Int?
        }
        guard let encoded = try? JSONEncoder().encode(event.data),
              let payload = try? JSONDecoder().decode(Payload.self, from: encoded),
              synchronizeScope() != nil else { return false }
        let typed: OpenCodeTypedEvent
        switch event.type {
        case "pty.created":
            guard let info = payload.info else { return false }
            typed = .ptyCreated(info)
        case "pty.updated":
            guard let info = payload.info else { return false }
            typed = .ptyUpdated(info)
        case "pty.exited":
            guard let id = payload.id, let exitCode = payload.exitCode else { return false }
            typed = .ptyExited(id: id, exitCode: exitCode)
        case "pty.deleted":
            guard let id = payload.id else { return false }
            typed = .ptyDeleted(id: id)
        default: return false
        }
        return apply(typed, directory: location.directory, workspaceID: location.workspaceID)
    }

    private func removeTerminal(id: String, directory: String, workspaceID: String?) {
        inventoryRevision &+= 1
        removedTerminalKeys.insert(TerminalStore.workspaceKey(directory: directory, workspaceID: workspaceID) + "\u{0000}" + id)
        if store.remove(id: id, directory: directory, workspaceID: workspaceID) {
            detachRenderer()
        }
    }

    private func apply(_ event: OpenCodeTypedEvent, directory: String, workspaceID: String?) -> Bool {
        switch event {
        case let .ptyCreated(info):
            inventoryRevision &+= 1
            guard !ProviderUsageCredentialImportHelper.owns(info) else { return true }
            let key = TerminalStore.workspaceKey(directory: directory, workspaceID: workspaceID) + "\u{0000}" + info.id
            if info.status == "exited" {
                removeTerminal(id: info.id, directory: directory, workspaceID: workspaceID)
            } else if !removedTerminalKeys.contains(key) {
                store.upsert(info, directory: directory, workspaceID: workspaceID)
            }
            return true
        case let .ptyUpdated(info):
            inventoryRevision &+= 1
            if ProviderUsageCredentialImportHelper.owns(info) {
                removeTerminal(id: info.id, directory: directory, workspaceID: workspaceID)
                return true
            }
            if info.status == "exited" {
                removeTerminal(id: info.id, directory: directory, workspaceID: workspaceID)
            } else {
                store.update(info: info, directory: directory, workspaceID: workspaceID)
            }
            return true
        case let .ptyExited(id, _):
            removeTerminal(id: id, directory: directory, workspaceID: workspaceID)
            return true
        case let .ptyDeleted(id):
            removeTerminal(id: id, directory: directory, workspaceID: workspaceID)
            return true
        default:
            return false
        }
    }

    private func runConnection(
        terminalID: String,
        rendererID: UUID,
        context: Context,
        initialCursor: Int,
        connection: OpenCodePTYConnection
    ) async {
        guard isCurrent(context), let client = clientProvider() else { return }
        var attempt = 0

        while !Task.isCancelled,
              attachedTerminalID == terminalID,
              attachedRendererID == rendererID,
              self.connection === connection, isCurrent(context) {
            do {
                store.setConnectionState(attempt == 0 ? .connecting : .reconnecting)
                let cursor = Self.connectionCursor(
                    initialCursor: initialCursor,
                    latestCursor: store.activeWorkspace.terminals.first(where: { $0.id == terminalID })?.cursor,
                    attempt: attempt
                )
                let request = try (context.isV2
                    ? client.v2PTYConnectRequest(id: terminalID, directory: context.directory, workspaceID: context.workspaceID, cursor: cursor)
                    : client.ptyConnectRequest(id: terminalID, directory: context.directory, workspaceID: context.workspaceID, cursor: cursor))
                try await connectionRunner(connection, request, cursor) { [weak self] event in
                    await MainActor.run {
                        guard let self,
                              self.attachedTerminalID == terminalID,
                              self.attachedRendererID == rendererID,
                              self.connection === connection,
                              self.isCurrent(context) else { return }
                        switch event {
                        case .connected:
                            self.store.setConnectionState(.connected)
                        case .closed:
                            self.store.setConnectionState(.disconnected)
                        case let .output(text, nextCursor):
                            self.store.updateCursor(nextCursor, id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
                            self.rendererOutputHandlers.values.forEach { $0(text) }
                        case let .cursor(nextCursor):
                            self.store.updateCursor(nextCursor, id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
                        }
                    }
                }
                return
            } catch where error is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      attachedTerminalID == terminalID,
                      attachedRendererID == rendererID, self.connection === connection,
                      isCurrent(context) else { return }
                store.setConnectionState(.reconnecting)
                do {
                    let info = try await (context.isV2
                        ? client.getV2PTY(id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
                        : client.getPTY(id: terminalID, directory: context.directory, workspaceID: context.workspaceID))
                    guard !Task.isCancelled, isCurrent(context), attachedRendererID == rendererID,
                          self.connection === connection else { return }
                    if info.status == "exited" {
                        removeTerminal(id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
                        return
                    }
                } catch let OpenCodeAPIError.httpError(code, _) where code == 404 {
                    guard !Task.isCancelled, isCurrent(context), attachedRendererID == rendererID,
                          self.connection === connection else { return }
                    if context.isV2 {
                        removeTerminal(id: terminalID, directory: context.directory, workspaceID: context.workspaceID)
                    } else {
                        await replaceStaleTerminal(id: terminalID, context: context, client: client)
                    }
                    return
                } catch {
                    guard !Task.isCancelled, isCurrent(context), attachedRendererID == rendererID,
                          self.connection === connection else { return }
                    store.setError(error)
                }

                attempt = min(attempt + 1, 5)
                store.setConnectionState(.reconnecting)
                let delay = 250 * Int(pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(for: .milliseconds(min(delay, 4_000)))
            }
        }
    }

    private func disconnectRendererResources() {
        attachedTerminalID = nil
        attachedRendererID = nil
        attachedContext = nil
        rendererOutputHandlers.removeAll()
        rendererInput = nil
        connectionTask?.cancel()
        connectionTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        pendingResize = nil
        connection = OpenCodePTYConnection()
    }

    private func replaceStaleTerminal(id: String, context: Context, client: OpenCodeAPIClient) async {
        guard isCurrent(context), let old = store.activeWorkspace.terminals.first(where: { $0.id == id }) else { return }
        do {
            let replacement = try await client.createPTY(title: old.title, directory: context.directory, workspaceID: context.workspaceID)
            guard isCurrent(context), !Task.isCancelled else { return }
            store.replace(id: id, with: replacement, directory: context.directory, workspaceID: context.workspaceID)
        } catch {
            guard isCurrent(context), !Task.isCancelled else { return }
            store.setError(error)
        }
    }

#if DEBUG
    private var isTerminalScreenshotFixture: Bool {
        let scene = ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"]
        return scene == "terminal" || scene == "terminal-showcase"
    }

    private static let screenshotFixtureTranscript: String = {
        let progress = (1 ... 145).map { index in
            let percent = min(99, 24 + index / 2)
            return "\u{001B}[90m  compiling OpenClient module \(String(format: "%03d", index))  \(percent)%\u{001B}[0m"
        }
        let summary = [
            "",
            "\u{001B}[1;36mOpenClient 1.0.13 · Release validation\u{001B}[0m",
            "",
            "\u{001B}[32m✓\u{001B}[0m Swift release build",
            "\u{001B}[32m✓\u{001B}[0m Plugin bridge tools",
            "\u{001B}[32m✓\u{001B}[0m Browser automation",
            "\u{001B}[32m✓\u{001B}[0m Visual tool renderers",
            "\u{001B}[32m✓\u{001B}[0m Unit and UI tests",
            "",
            "\u{001B}[1;35mReady for TestFlight\u{001B}[0m  \u{001B}[90m1.0.13 (15)\u{001B}[0m",
            "",
            "\u{001B}[1;34mopenclient\u{001B}[0m \u{001B}[90m…/openclient\u{001B}[0m % ",
        ]
        return "\u{001B}[2J\u{001B}[H" + (progress + summary).joined(separator: "\r\n")
    }()
#endif
}
