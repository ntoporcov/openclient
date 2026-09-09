import Foundation
import XCTest
@testable import OpenClient

@MainActor
final class LiveActivityBackgroundBridgeTests: XCTestCase {
    private let lifetime = LiveActivityStore.Lifetime(
        owner: .init(profile: .legacy, serverID: "server"), connectionID: UUID(), generation: 1)
    func testAcceptedRequestRequiresActiveLiveActivity() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")

        bridge.resolve(intent, accepted: true, hasLiveActivity: false)

        XCTAssertTrue(bridge.trackedSessionIDs.isEmpty)
        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.beginCount, 0)
    }

    func testRejectedRequestDoesNotStartAssertion() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")

        bridge.resolve(intent, accepted: false, hasLiveActivity: true)

        XCTAssertTrue(bridge.trackedSessionIDs.isEmpty)
        XCTAssertEqual(manager.beginCount, 0)
    }

    func testAcceptedRequestStartsSingleAssertion() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let first = bridge.arm(sessionID: "ses_1")
        bridge.resolve(first, accepted: true, hasLiveActivity: true)
        let second = bridge.arm(sessionID: "ses_1")
        bridge.resolve(second, accepted: true, hasLiveActivity: true)

        XCTAssertEqual(manager.beginCount, 1)
        XCTAssertTrue(bridge.hasActiveAssertion)
        XCTAssertEqual(bridge.trackedSessionIDs, ["ses_1"])
    }

    func testConcurrentSessionsShareAssertionUntilBothFinish() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let first = bridge.arm(sessionID: "ses_1")
        let second = bridge.arm(sessionID: "ses_2")
        bridge.resolve(first, accepted: true, hasLiveActivity: true)
        bridge.resolve(second, accepted: true, hasLiveActivity: true)

        bridge.consume(managedEvent(type: "session.idle", typed: .sessionIdle(sessionID: "ses_1")), lifetime: lifetime)
        XCTAssertTrue(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.endedTokens.count, 0)

        bridge.consume(managedEvent(type: "session.idle", typed: .sessionIdle(sessionID: "ses_2")), lifetime: lifetime)
        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    func testErrorEndsLastAssertion() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")
        bridge.resolve(intent, accepted: true, hasLiveActivity: true)

        bridge.consume(managedEvent(
            type: "session.error",
            typed: .sessionError(sessionID: "ses_1", message: "Failed")
        ), lifetime: lifetime)

        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    func testTerminalEventBeforeAcceptanceDoesNotStartAssertion() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")
        bridge.consume(managedEvent(type: "session.idle", typed: .sessionIdle(sessionID: "ses_1")), lifetime: lifetime)

        bridge.resolve(intent, accepted: true, hasLiveActivity: true)

        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.beginCount, 0)
    }

    func testExpirationEndsAssertionAndClearsSessions() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")
        bridge.resolve(intent, accepted: true, hasLiveActivity: true)

        manager.expireCurrent()

        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertTrue(bridge.trackedSessionIDs.isEmpty)
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    func testCancellationEndsLastAssertion() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let intent = bridge.arm(sessionID: "ses_1")
        bridge.resolve(intent, accepted: true, hasLiveActivity: true)

        bridge.cancel(sessionID: "ses_1", reason: "Stopped", lifetime: lifetime)

        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.endedTokens.count, 1)
    }

    private func makeBridge(
        manager: FakeLiveActivityBackgroundTaskManager
    ) -> LiveActivityBackgroundBridge {
        let bridge = LiveActivityBackgroundBridge(
            manager: manager,
            completionDelay: .zero,
            log: { _ in }
        )
        bridge.bind(lifetime)
        return bridge
    }

    func testEqualSessionIDsAcrossProfilesAndServersRejectLateCallbacks() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let old = bridge.arm(sessionID: "same")
        let next = LiveActivityStore.Lifetime(owner: .init(profile: .v2, serverID: "other"), connectionID: UUID(), generation: 2)
        bridge.bind(next)
        let current = bridge.arm(sessionID: "same")
        bridge.resolve(old, accepted: true, hasLiveActivity: true)
        XCTAssertEqual(manager.beginCount, 0)
        bridge.resolve(current, accepted: true, hasLiveActivity: true)
        bridge.consume(.sessionIdle(sessionID: "same"), lifetime: lifetime)
        bridge.cancel(sessionID: "same", reason: "Late stop", lifetime: lifetime)
        bridge.consume(managedEvent(type: "session.idle", typed: .sessionIdle(sessionID: "same")))
        XCTAssertTrue(bridge.hasActiveAssertion)
        bridge.consume(.sessionIdle(sessionID: "same"), lifetime: next)
        XCTAssertFalse(bridge.hasActiveAssertion)
    }

    func testReconnectSameOwnerRejectsLateAdmissionAndExpirationStaysFinite() {
        let manager = FakeLiveActivityBackgroundTaskManager()
        let bridge = makeBridge(manager: manager)
        let old = bridge.arm(sessionID: "same")
        bridge.bind(.init(owner: lifetime.owner, connectionID: UUID(), generation: lifetime.generation))
        bridge.resolve(old, accepted: true, hasLiveActivity: true)
        XCTAssertFalse(bridge.hasActiveAssertion)
        let current = bridge.arm(sessionID: "same")
        bridge.resolve(current, accepted: true, hasLiveActivity: true)
        manager.expireCurrent()
        bridge.resolve(current, accepted: true, hasLiveActivity: true)
        XCTAssertFalse(bridge.hasActiveAssertion)
        XCTAssertEqual(manager.beginCount, 1)
    }

    private func managedEvent(type: String, typed: OpenCodeTypedEvent) -> OpenCodeManagedEvent {
        OpenCodeManagedEvent(
            directory: "/tmp/project",
            envelope: OpenCodeEventEnvelope(type: type, properties: OpenCodeEventProperties()),
            typed: typed
        )
    }
}

@MainActor
private final class FakeLiveActivityBackgroundTaskManager: LiveActivityBackgroundTaskManaging {
    private(set) var beginCount = 0
    private(set) var endedTokens: [UUID] = []
    private var currentToken: UUID?
    private var expirationHandler: (@MainActor @Sendable (UUID) -> Void)?

    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> UUID? {
        beginCount += 1
        let token = UUID()
        currentToken = token
        self.expirationHandler = expirationHandler
        return token
    }

    func end(_ token: UUID) {
        endedTokens.append(token)
        if currentToken == token {
            currentToken = nil
            expirationHandler = nil
        }
    }

    func expireCurrent() {
        guard let currentToken else { return }
        expirationHandler?(currentToken)
    }
}
