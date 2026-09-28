import XCTest
@testable import OpenClient

@MainActor
final class ConnectionAppearanceRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "ConnectionAppearanceRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        try await super.tearDown()
    }

    private var legacy: AppCustomizationPreferences {
        .init(chatBubbleStyle: .solid, accentColor: .pink,
              showsChatActivityShimmer: false, showsToolCalls: false, showsReasoningBlocks: false,
              showsActivityLastUserMessage: false, isTodoStripMinimized: true,
              sessionCardStyle: .activity, composerStyle: .assistant,
              autoConnectServerID: "one", autoConnectLandingDestination: .activity)
    }

    private func registry(_ initial: AppCustomizationPreferences? = nil) -> ConnectionAppearanceRegistry {
        ConnectionAppearanceRegistry(defaults: defaults, storageKey: "appearance", legacyPreferences: initial ?? legacy)
    }

    func testMigrationCopiesEveryAppearanceSettingAndKeepsAutoConnectGlobal() throws {
        defaults.set(try JSONEncoder().encode(legacy), forKey: "appCustomizationPreferences")
        let global = AppCustomizationStore(defaults: defaults)
        let appearances = global.makeConnectionAppearanceRegistry()
        appearances.migrateSavedServers(["one", "two"])

        XCTAssertEqual(appearances.store(for: "one").preferences, legacy.appearanceOnly)
        XCTAssertEqual(appearances.store(for: "two").preferences, legacy.appearanceOnly)
        XCTAssertFalse(appearances.store(for: "one") === appearances.store(for: "two"))
        appearances.store(for: "one").setAccentColor(.inverted)
        XCTAssertEqual(global.preferences, legacy)
        XCTAssertEqual(AppCustomizationStore(defaults: defaults).preferences, legacy)
    }

    func testMigrationRunsOnceAndPreservesExistingOverrides() {
        let appearances = registry()
        appearances.store(for: "one").setAccentColor(.clear)
        appearances.migrateSavedServers(["one", "two"])
        appearances.store(for: "two").setComposerStyle(.messenger)

        let reopened = registry(.init(accentColor: .green))
        reopened.migrateSavedServers(["one", "two"])
        XCTAssertEqual(reopened.store(for: "one").accentColor, .clear)
        XCTAssertEqual(reopened.store(for: "two").composerStyle, .messenger)
        XCTAssertEqual(reopened.store(for: "two").accentColor, .pink)
        // Future connections start with the original appearance, not another server's edits.
        XCTAssertEqual(reopened.store(for: "three").preferences, legacy.appearanceOnly)
    }

    func testConnectionsStayIndependentAndRestoreAllChanges() {
        let appearances = registry()
        appearances.migrateSavedServers(["one", "two"])
        let one = appearances.store(for: "one")
        let two = appearances.store(for: "two")
        one.setChatBubbleStyle(.glass)
        one.setAccentColor(.teal)
        one.setShowsToolCalls(true)
        one.setShowsReasoningBlocks(true)
        one.setShowsChatActivityShimmer(true)
        one.setShowsActivityLastUserMessage(true)
        one.setTodoStripMinimized(false)
        one.setSessionCardStyle(.compact)
        one.setComposerStyle(.messenger)
        XCTAssertTrue(one === appearances.store(for: "one"))
        XCTAssertEqual(two.preferences, legacy.appearanceOnly)
        let reopened = registry()
        XCTAssertEqual(reopened.store(for: "one").preferences, one.preferences)
        XCTAssertEqual(reopened.store(for: "two").preferences, two.preferences)
    }

    func testServerEditMovesStoreIdentityAndPersistsLaterEditsUnderNewID() {
        let appearances = registry()
        let lifetime = UUID()
        let original = appearances.store(for: "old-url", connectionID: lifetime)
        original.setAccentColor(.orange)
        // Connection bootstrap can ask for the new scope before the server edit is saved.
        _ = appearances.store(for: "new-url")
        appearances.migrateServerID(from: "old-url", to: "new-url")
        XCTAssertTrue(original === appearances.store(for: "new-url"))
        XCTAssertTrue(original === appearances.store(for: "old-url", connectionID: lifetime))
        XCTAssertFalse(original === appearances.store(for: "old-url", connectionID: UUID()))
        original.setChatBubbleStyle(.glass)
        let reopened = registry()
        XCTAssertEqual(reopened.store(for: "new-url").accentColor, .orange)
        XCTAssertEqual(reopened.store(for: "new-url").chatBubbleStyle, .glass)
        XCTAssertEqual(reopened.store(for: "old-url").preferences, legacy.appearanceOnly)
    }

    func testServerEditDoesNotOverwriteCustomizedDestination() {
        let appearances = registry()
        appearances.store(for: "old").setAccentColor(.orange)
        let destination = appearances.store(for: "destination")
        destination.setAccentColor(.purple)
        appearances.migrateServerID(from: "old", to: "destination")
        XCTAssertTrue(destination === appearances.store(for: "destination"))
        XCTAssertEqual(destination.accentColor, .purple)
        XCTAssertEqual(registry().store(for: "destination").accentColor, .purple)
    }

    func testRemovingConnectionDoesNotChangeOtherConnectionsOrDefaults() {
        let appearances = registry()
        appearances.store(for: "one").setAccentColor(.green)
        appearances.store(for: "two").setAccentColor(.blue)
        appearances.removeServer("one")
        let reopened = registry()
        XCTAssertEqual(reopened.store(for: "two").accentColor, .blue)
        XCTAssertEqual(reopened.store(for: "one").preferences, legacy.appearanceOnly)
    }

    func testFacadesUseLiveConnectionAndWindowScopeInsteadOfEditableServerDraft() {
        let backend = HomeTestBackend()
        let model = AppViewModel(backendFactory: backend, appCustomizationStore: AppCustomizationStore(defaults: defaults))
        let first = BackendConnection(descriptor: .init(id: "first", name: "First", version: "1"),
            projects: backend, sessions: backend, chat: backend, models: backend, events: backend)
        let second = BackendConnection(descriptor: .init(id: "second", name: "Second", version: "1"),
            projects: backend, sessions: backend, chat: backend, models: backend, events: backend)
        model.backendConnection = first
        model.connectionStore.isConnected = true
        let firstAppearance = model.connectionAppearances.store(for: "first")
        firstAppearance.setAccentColor(.pink)
        model.connectionAppearances.store(for: "second").setAccentColor(.teal)

        let session = backend.storedSessions[0]
        let owner = model.directoryStoreRegistry.store(for: session.directory)
        let context = ChatWindowContext(model: model, connection: first, session: session, owner: owner)
        defer { context.close() }
        let window = ChatFacade(viewModel: model, windowContext: context)
        model.config = OpenCodeServerConfig(name: "Editing another server", baseURL: "https://draft.example", username: "user")
        XCTAssertTrue(model.connectionFacade.appCustomizationStore === firstAppearance)
        XCTAssertTrue(model.chatFacade.appCustomizationStore === firstAppearance)

        model.backendConnection = second
        XCTAssertEqual(model.chatFacade.appCustomizationStore.accentColor, .teal)
        XCTAssertEqual(model.connectionFacade.shellAppearanceStore.accentColor, .teal)
        XCTAssertTrue(window.appCustomizationStore === firstAppearance)
    }
}
