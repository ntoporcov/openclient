import CryptoKit
import Foundation

/// Only unresolved operations survive an invocation. Successful intents are not deduplicated.
@MainActor
struct ShortcutPendingOperationStore {
    struct Record: Codable, Equatable, Sendable {
        let requestHash: String
        let operationID: UUID
        let serverNamespace: String
        var sessionID: String?
        let messageID: String?
        var directory: String?
        var workspaceID: String?

        init(requestHash: String, serverNamespace: String, operationID: UUID = UUID(), sessionID: String? = nil,
             messageID: String? = nil, directory: String? = nil, workspaceID: String? = nil) {
            self.requestHash = requestHash
            self.operationID = operationID
            self.serverNamespace = serverNamespace
            self.sessionID = sessionID
            self.messageID = messageID
            self.directory = directory
            self.workspaceID = workspaceID
        }

        fileprivate var sessionKey: SessionKey? {
            sessionID.map { SessionKey(serverNamespace: serverNamespace, sessionID: $0) }
        }

        fileprivate var owner: OperationOwner {
            .init(requestHash: requestHash, operationID: operationID, serverNamespace: serverNamespace)
        }
    }

    fileprivate struct OperationOwner: Hashable, Sendable {
        let requestHash: String
        let operationID: UUID
        let serverNamespace: String
    }

    fileprivate struct SessionKey: Hashable, Sendable {
        let serverNamespace: String
        let sessionID: String
    }

    private struct Waiter {
        let record: Record
        let continuation: CheckedContinuation<Void, any Error>
    }

    // Process-local liveness is intentionally not persisted. After relaunch only read evidence
    // can settle an abandoned record. These locks span service instances and backend lifetimes.
    private static var activeOperations: Set<OperationOwner> = []
    private static var confirmedOperations: Set<OperationOwner> = []
    private static var sessionOwners: [SessionKey: Record] = [:]
    private static var sessionWaiters: [SessionKey: [Waiter]] = [:]

    let defaults: UserDefaults
    let key: String

    init(defaults: UserDefaults = .standard, key: String = "shortcutPendingOperations") {
        self.defaults = defaults
        self.key = key
    }

    static func requestHash(_ components: [String?]) throws -> String {
        let data = try JSONEncoder().encode(components)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func record(for hash: String) throws -> Record? {
        try records()[hash]
    }

    func records(serverNamespace: String, sessionID: String) throws -> [Record] {
        try records().values.filter { $0.serverNamespace == serverNamespace && $0.sessionID == sessionID }
    }

    func isCurrent(_ record: Record) throws -> Bool {
        try records()[record.requestHash]?.owner == record.owner
    }

    func isActive(_ record: Record) -> Bool { Self.activeOperations.contains(record.owner) }
    func isConfirmed(_ record: Record) -> Bool { Self.confirmedOperations.contains(record.owner) }

    @discardableResult
    func claim(_ record: Record) throws -> Bool {
        var values = try records()
        guard values[record.requestHash] == nil else { return false }
        if let sessionKey = record.sessionKey,
           values.values.contains(where: { $0.sessionKey == sessionKey }) { return false }
        values[record.requestHash] = record
        defaults.set(try JSONEncoder().encode(values), forKey: key)
        Self.activeOperations.insert(record.owner)
        return true
    }

    @discardableResult
    func save(_ record: Record) throws -> Bool {
        var values = try records()
        guard values[record.requestHash]?.owner == record.owner else { return false }
        values[record.requestHash] = record
        defaults.set(try JSONEncoder().encode(values), forKey: key)
        return true
    }

    @discardableResult
    func remove(_ record: Record) throws -> Bool {
        var values = try records()
        guard values[record.requestHash]?.owner == record.owner else { return false }
        values.removeValue(forKey: record.requestHash)
        defaults.set(try JSONEncoder().encode(values), forKey: key)
        return true
    }

    func confirm(_ record: Record) throws -> Bool {
        guard try remove(record) else { return false }
        if isActive(record) { Self.confirmedOperations.insert(record.owner) }
        releaseSession(record)
        return true
    }

    func finishInvocation(_ record: Record) {
        Self.activeOperations.remove(record.owner)
        Self.confirmedOperations.remove(record.owner)
        releaseSession(record)
    }

    func acquireSession(_ record: Record) async throws {
        guard let sessionKey = record.sessionKey else { throw OpenCodeShortcutError.uncertainCreation }
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Self.sessionOwners[sessionKey] == nil {
                    Self.sessionOwners[sessionKey] = record
                    continuation.resume()
                } else if Self.sessionOwners[sessionKey]?.requestHash == record.requestHash
                    || Self.sessionWaiters[sessionKey]?.contains(where: { $0.record.requestHash == record.requestHash }) == true {
                    // Cover the small interval between acquiring the session and persisting
                    // the claim: an overlapping identical intent is not a new sequential send.
                    continuation.resume(throwing: OpenCodeShortcutError.uncertainAdmission)
                } else {
                    Self.sessionWaiters[sessionKey, default: []].append(.init(record: record, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = Self.sessionWaiters[sessionKey]?.firstIndex(where: { $0.record.owner == record.owner }),
                      let waiter = Self.sessionWaiters[sessionKey]?.remove(at: index) else { return }
                waiter.continuation.resume(throwing: CancellationError())
            }
        }
        do { try Task.checkCancellation() } catch {
            releaseSession(record)
            throw error
        }
    }

    func ownsSession(_ record: Record) -> Bool {
        guard let key = record.sessionKey else { return false }
        return Self.sessionOwners[key]?.owner == record.owner
    }

    private func releaseSession(_ record: Record) {
        guard let key = record.sessionKey, Self.sessionOwners[key]?.owner == record.owner else { return }
        if var waiters = Self.sessionWaiters.removeValue(forKey: key), !waiters.isEmpty {
            let next = waiters.removeFirst()
            if !waiters.isEmpty { Self.sessionWaiters[key] = waiters }
            Self.sessionOwners[key] = next.record
            next.continuation.resume()
        } else {
            Self.sessionOwners.removeValue(forKey: key)
        }
    }

    private func records() throws -> [String: Record] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        // Pre-ownership records also fail closed: neither ownership nor server namespace can
        // safely be reconstructed from a content hash. Never invent them while decoding.
        return try JSONDecoder().decode([String: Record].self, from: data)
    }
}
