import Foundation
import OSLog

#if canImport(UIKit) && os(iOS)
import UIKit
#endif

@MainActor
protocol LiveActivityBackgroundTaskManaging: AnyObject {
    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> UUID?
    func end(_ token: UUID)
}

@MainActor
final class LiveActivityBackgroundBridge {
    struct Intent: Hashable {
        fileprivate let id: UUID
        fileprivate let sessionID: String
        fileprivate let lifetime: LiveActivityStore.Lifetime
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ntoporcov.openclient",
        category: "LiveActivityBackgroundBridge"
    )

    private let manager: any LiveActivityBackgroundTaskManaging
    private let completionDelay: Duration
    private let log: (String) -> Void
    private var activeSessionIDs: Set<String> = []
    private var pendingIntentIDsBySession: [String: Set<UUID>] = [:]
    private var terminalSessionIDs: Set<String> = []
    private var taskToken: UUID?
    private var delayedEndTask: Task<Void, Never>?
    private(set) var lifetime: LiveActivityStore.Lifetime?

    func bind(_ lifetime: LiveActivityStore.Lifetime) {
        guard self.lifetime != lifetime else { return }
        cancelAll(reason: "Connection lifetime changed")
        self.lifetime = lifetime
    }

    init(
        manager: (any LiveActivityBackgroundTaskManaging)? = nil,
        completionDelay: Duration = .milliseconds(750),
        log: ((String) -> Void)? = nil
    ) {
        self.manager = manager ?? Self.makeSystemManager()
        self.completionDelay = completionDelay
        self.log = log ?? { message in
            Self.logger.debug("\(message, privacy: .public)")
        }
    }

    var trackedSessionIDs: Set<String> {
        activeSessionIDs.union(pendingIntentIDsBySession.keys)
    }

    var hasActiveAssertion: Bool {
        taskToken != nil
    }

    func arm(sessionID: String) -> Intent? {
        guard let lifetime else { return nil }
        if !activeSessionIDs.contains(sessionID), pendingIntentIDsBySession[sessionID] == nil {
            terminalSessionIDs.remove(sessionID)
        }
        let intent = Intent(id: UUID(), sessionID: sessionID, lifetime: lifetime)
        pendingIntentIDsBySession[sessionID, default: []].insert(intent.id)
        log("armed session=\(sessionID)")
        return intent
    }

    func resolve(_ intent: Intent?, accepted: Bool, hasLiveActivity: Bool) {
        guard let intent,
              intent.lifetime == lifetime,
              pendingIntentIDsBySession[intent.sessionID]?.contains(intent.id) == true else { return }
        removePendingIntent(intent)

        guard accepted, hasLiveActivity, !terminalSessionIDs.contains(intent.sessionID) else {
            clearTerminalIfUnused(sessionID: intent.sessionID)
            scheduleEndIfNeeded()
            log("discarded session=\(intent.sessionID) accepted=\(accepted) live=\(hasLiveActivity)")
            return
        }

        activeSessionIDs.insert(intent.sessionID)
        terminalSessionIDs.remove(intent.sessionID)
        ensureAssertion()
    }

    func consume(_ managed: OpenCodeManagedEvent, lifetime: LiveActivityStore.Lifetime? = nil) {
        consume(managed.typed, lifetime: lifetime)
    }

    // The caller captures the event subscription's lifetime, not the current UI owner.
    // This remains a finite UIKit assertion, with no push/SSE survival guarantee.
    func consume(_ event: OpenCodeTypedEvent, lifetime: LiveActivityStore.Lifetime?) {
        guard let lifetime, self.lifetime == lifetime else { return }
        switch event {
        case let .sessionIdle(sessionID):
            finish(sessionID: sessionID, reason: "idle")
        case let .sessionStatus(sessionID, status) where status == "idle":
            finish(sessionID: sessionID, reason: "idle status")
        case let .sessionError(sessionID, _):
            if let sessionID {
                finish(sessionID: sessionID, reason: "error")
            }
        case let .sessionDeleted(session):
            cancel(sessionID: session.id, reason: "deleted", lifetime: lifetime)
        default:
            break
        }
    }

    func cancel(sessionID: String, reason: String, lifetime: LiveActivityStore.Lifetime? = nil) {
        guard let lifetime, self.lifetime == lifetime else { return }
        activeSessionIDs.remove(sessionID)
        pendingIntentIDsBySession.removeValue(forKey: sessionID)
        terminalSessionIDs.remove(sessionID)
        scheduleEndIfNeeded()
        log("cancelled session=\(sessionID) reason=\(reason)")
    }

    func cancelAll(reason: String) {
        lifetime = nil
        activeSessionIDs.removeAll()
        pendingIntentIDsBySession.removeAll()
        terminalSessionIDs.removeAll()
        endAssertionNow()
        log("cancelled all reason=\(reason)")
    }

    private func finish(sessionID: String, reason: String) {
        guard activeSessionIDs.contains(sessionID) || pendingIntentIDsBySession[sessionID] != nil else { return }
        activeSessionIDs.remove(sessionID)
        if pendingIntentIDsBySession[sessionID] != nil {
            terminalSessionIDs.insert(sessionID)
        } else {
            terminalSessionIDs.remove(sessionID)
        }
        scheduleEndIfNeeded()
        log("finished session=\(sessionID) reason=\(reason)")
    }

    private func ensureAssertion() {
        delayedEndTask?.cancel()
        delayedEndTask = nil
        guard taskToken == nil else { return }
        taskToken = manager.begin(name: "Keep Live Activity Updated") { [weak self] token in
            self?.expire(token: token)
        }
        if taskToken != nil {
            log("background assertion started")
        } else {
            log("background assertion unavailable")
        }
    }

    private func expire(token: UUID) {
        guard taskToken == token else { return }
        delayedEndTask?.cancel()
        delayedEndTask = nil
        activeSessionIDs.removeAll()
        pendingIntentIDsBySession.removeAll()
        terminalSessionIDs.removeAll()
        manager.end(token)
        taskToken = nil
        log("background assertion expired")
    }

    private func scheduleEndIfNeeded() {
        guard activeSessionIDs.isEmpty,
              pendingIntentIDsBySession.isEmpty,
              taskToken != nil else { return }
        delayedEndTask?.cancel()
        guard completionDelay != .zero else {
            endAssertionNow()
            return
        }
        delayedEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.completionDelay ?? .zero)
            guard !Task.isCancelled else { return }
            self?.endAssertionNow()
        }
    }

    private func endAssertionNow() {
        delayedEndTask?.cancel()
        delayedEndTask = nil
        guard let taskToken else { return }
        manager.end(taskToken)
        self.taskToken = nil
        log("background assertion ended")
    }

    private func removePendingIntent(_ intent: Intent) {
        pendingIntentIDsBySession[intent.sessionID]?.remove(intent.id)
        if pendingIntentIDsBySession[intent.sessionID]?.isEmpty == true {
            pendingIntentIDsBySession.removeValue(forKey: intent.sessionID)
        }
    }

    private func clearTerminalIfUnused(sessionID: String) {
        guard !activeSessionIDs.contains(sessionID), pendingIntentIDsBySession[sessionID] == nil else { return }
        terminalSessionIDs.remove(sessionID)
    }

    private static func makeSystemManager() -> any LiveActivityBackgroundTaskManaging {
        #if canImport(UIKit) && os(iOS)
        return SystemLiveActivityBackgroundTaskManager()
        #else
        return UnavailableLiveActivityBackgroundTaskManager()
        #endif
    }
}

@MainActor
private final class UnavailableLiveActivityBackgroundTaskManager: LiveActivityBackgroundTaskManaging {
    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> UUID? {
        nil
    }

    func end(_ token: UUID) {}
}

#if canImport(UIKit) && os(iOS)
@MainActor
private final class SystemLiveActivityBackgroundTaskManager: LiveActivityBackgroundTaskManaging {
    private var identifiersByToken: [UUID: UIBackgroundTaskIdentifier] = [:]

    func begin(
        name: String,
        expirationHandler: @escaping @MainActor @Sendable (UUID) -> Void
    ) -> UUID? {
        let token = UUID()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            Task { @MainActor in
                expirationHandler(token)
            }
        }
        guard identifier != .invalid else { return nil }
        identifiersByToken[token] = identifier
        return token
    }

    func end(_ token: UUID) {
        guard let identifier = identifiersByToken.removeValue(forKey: token) else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
}
#endif
