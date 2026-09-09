import XCTest
@testable import OpenClient

@MainActor
final class ConnectionNoticeTests: XCTestCase {
    func testV2NoticeIsArmedOnlyAfterSuccessfulBootstrapAndHiddenWhileLoading() async {
        let model = AppViewModel(backendFactory: HomeTestBackend())
        let facade = model.connectionFacade
        let store = model.connectionStore
        let connection = makeConnection()
        defer { connection.close() }

        await ConnectionCoordinator(connectionStore: store).connect(
            factory: NoticeFactory(connection: connection),
            applyConnection: { opened in
                model.backendConnection = opened
                XCTAssertEqual(store.apiProfile, .v2)
                XCTAssertTrue(store.isLoading)
                XCTAssertNil(store.v2NoticeConnectionID)
                XCTAssertNil(facade.v2NoticeConnectionID)
            },
            handleFailure: { XCTFail("Bootstrap should succeed") }
        )

        XCTAssertEqual(store.v2NoticeConnectionID, connection.id)
        XCTAssertEqual(facade.v2NoticeConnectionID, connection.id)
        store.isLoading = true
        XCTAssertNil(facade.v2NoticeConnectionID)
        store.finishConnecting()
        model.isShowingConnectionOverlay = true
        XCTAssertNil(model.appShellFacade.v2NoticeConnectionID)
        model.isShowingConnectionOverlay = false
        XCTAssertEqual(model.appShellFacade.v2NoticeConnectionID, connection.id)
        facade.dismissV2Notice(connectionID: connection.id)
        XCTAssertNil(facade.v2NoticeConnectionID)
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        XCTAssertNil(store.v2NoticeConnectionID)
    }

    func testFailedBootstrapNeverArmsNotice() async {
        let store = ConnectionStore()
        let connection = makeConnection()
        await ConnectionCoordinator(connectionStore: store).connect(
            factory: NoticeFactory(connection: connection),
            applyConnection: { opened in
                store.bindNoticeConnection(opened.id)
                XCTAssertNil(store.v2NoticeConnectionID)
                throw URLError(.cannotLoadFromNetwork)
            },
            handleFailure: {}
        )
        XCTAssertNil(store.v2NoticeConnectionID)
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(connection.isClosed)
    }

    func testStaleBootstrapCannotArmNoticeForNewAttempt() async {
        let store = ConnectionStore()
        let connection = makeConnection()
        var isCurrent = true
        let nextID = UUID()
        await ConnectionCoordinator(connectionStore: store).connect(
            factory: NoticeFactory(connection: connection),
            isCurrentAttempt: { isCurrent },
            applyConnection: { opened in
                store.bindNoticeConnection(opened.id)
                isCurrent = false
                store.beginConnecting()
                store.bindNoticeConnection(nextID)
            },
            handleFailure: { XCTFail("Stale attempt must not fail the new attempt") }
        )
        XCTAssertNil(store.v2NoticeConnectionID)
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(connection.isClosed)
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        XCTAssertEqual(store.v2NoticeConnectionID, nextID)
    }

    func testCancelledBootstrapDoesNotLeaveNoticePending() async {
        let store = ConnectionStore()
        let connection = makeConnection()
        await ConnectionCoordinator(connectionStore: store).connect(
            factory: NoticeFactory(connection: connection),
            applyConnection: { opened in
                store.bindNoticeConnection(opened.id)
                throw CancellationError()
            },
            handleFailure: {}
        )
        XCTAssertNil(store.v2NoticeConnectionID)
        XCTAssertNil(store.apiProfile)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(connection.isClosed)
    }

    func testDismissalIsPerLifetimeAndStaleDismissalCannotDismissReconnect() {
        let store = ConnectionStore()
        let firstID = UUID()
        store.beginConnecting()
        store.bindNoticeConnection(firstID)
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        store.dismissV2Notice(connectionID: firstID)
        XCTAssertNil(store.v2NoticeConnectionID)
        store.beginConnecting()
        XCTAssertNil(store.v2NoticeConnectionID)
        let secondID = UUID()
        store.bindNoticeConnection(secondID)
        store.resolveAPIProfile(.v2)
        XCTAssertNil(store.v2NoticeConnectionID)
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        store.dismissV2Notice(connectionID: firstID)
        XCTAssertEqual(store.v2NoticeConnectionID, secondID)
    }

    func testLifecycleResetsClearNoticeAndSource() {
        let resets: [(ConnectionStore) -> Void] = [
            { $0.beginConnecting() },
            { $0.applyConnectionFailure(URLError(.cannotConnectToHost)) },
            { $0.applyConnectionCancellation() },
            { $0.resetToDisconnected() },
            { $0.applyCachedServerConnection() },
            { $0.offerCachedServerConnection() },
            { $0.applyAppleIntelligenceMode() },
            { $0.applySuccessfulServerConnection(version: "1", healthy: true) },
        ]
        for reset in resets {
            let store = ConnectionStore()
            let id = UUID()
            store.bindNoticeConnection(id)
            store.applySuccessfulV2Connection(version: "next", healthy: true)
            XCTAssertEqual(store.v2NoticeConnectionID, id)
            reset(store)
            XCTAssertNil(store.v2NoticeConnectionID)
            store.applySuccessfulV2Connection(version: "next", healthy: true)
            XCTAssertNil(store.v2NoticeConnectionID)
        }
    }

    func testUnknownLegacyUnhealthyAndSeededConnectionsDoNotShowNotice() async throws {
        let model = AppViewModel(backendFactory: HomeTestBackend())
        let facade = model.connectionFacade
        let store = model.connectionStore
        model.backendConnection = try await HomeTestBackend().connect()
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        XCTAssertNil(facade.v2NoticeConnectionID)
        model.backendConnection?.close()

        let legacy = makeConnection(profile: .legacy)
        model.backendConnection = legacy
        store.applySuccessfulServerConnection(version: "1", healthy: true)
        XCTAssertNil(facade.v2NoticeConnectionID)
        legacy.close()

        let v2 = makeConnection()
        model.backendConnection = v2
        store.applySuccessfulV2Connection(version: "next", healthy: false)
        XCTAssertNil(store.v2NoticeConnectionID)
        store.applySuccessfulV2Connection(version: "next", healthy: true)
        XCTAssertEqual(facade.v2NoticeConnectionID, v2.id)
        v2.close()
        XCTAssertNil(facade.v2NoticeConnectionID)
        XCTAssertNil(ConnectionStore(backendMode: .serverV2, isConnected: true, apiProfile: .v2).v2NoticeConnectionID)
    }

    func testReplacingBackendDoesNotTransferSuccessfulNotice() {
        let model = AppViewModel(backendFactory: HomeTestBackend())
        let facade = model.connectionFacade
        let first = makeConnection()
        let second = makeConnection()
        defer { first.close(); second.close() }
        model.backendConnection = first
        model.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        XCTAssertEqual(facade.v2NoticeConnectionID, first.id)
        model.backendConnection = second
        XCTAssertNil(facade.v2NoticeConnectionID)
    }

    func testReportURLIsCanonicalAndContainsNoConnectionData() {
        XCTAssertEqual(AppSupportURLs.issues.absoluteString, "https://github.com/ntoporcov/openclient/issues")
        XCTAssertNil(AppSupportURLs.issues.query)
        XCTAssertNil(AppSupportURLs.issues.user)
        XCTAssertNil(AppSupportURLs.issues.password)
    }

    private func makeConnection(profile: OpenCodeAPIProfile = .v2) -> BackendConnection {
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://notice.invalid"))
        let adapter = OpenCodeBackendAdapter(client: client, profile: profile)
        return BackendConnection(descriptor: .init(id: "notice-test", name: "OpenCode", version: "next"),
            projects: adapter, sessions: adapter, chat: adapter, models: adapter, events: HomeTestBackend())
    }
}

@MainActor
private struct NoticeFactory: BackendFactory {
    let connection: BackendConnection
    func connect() async throws -> BackendConnection { connection }
}
