import CryptoKit
import Foundation
import Security

enum ProviderUsagePTYDeleteResult: Sendable {
    case deleted
    case alreadyMissing
}

protocol ProviderUsagePTYTransport: Sendable {
    var serverURL: URL { get }
    func create(request: OpenCodePTYCreateRequest, scope: BackendScope) async throws -> OpenCodePTY
    func connect(
        id: String, scope: BackendScope,
        receive: @escaping @Sendable (OpenCodePTYSocketEvent) async -> Bool
    ) async throws
    func send(_ bytes: [UInt8]) async throws
    func delete(id: String, scope: BackendScope) async throws -> ProviderUsagePTYDeleteResult
}

actor OpenCodeCredentialImportLegacyPTYTransport: ProviderUsagePTYTransport {
    nonisolated let serverURL: URL
    private let client: OpenCodeAPIClient
    private let connection: OpenCodePTYConnection

    init(client: OpenCodeAPIClient, connection: OpenCodePTYConnection = OpenCodePTYConnection()) throws {
        guard let url = client.config.sanitizedBaseURL else { throw OpenCodeAPIError.invalidURL }
        serverURL = url
        self.client = client
        self.connection = connection
    }

    func create(request: OpenCodePTYCreateRequest, scope: BackendScope) async throws -> OpenCodePTY {
        guard let directory = scope.directory, !directory.isEmpty else {
            throw ProviderUsageCredentialImportError.contextChanged
        }
        return try await client.createPTY(request: request, directory: directory, workspaceID: scope.workspaceID)
    }

    func connect(
        id: String, scope: BackendScope,
        receive: @escaping @Sendable (OpenCodePTYSocketEvent) async -> Bool
    ) async throws {
        guard let directory = scope.directory, !directory.isEmpty else {
            throw ProviderUsageCredentialImportError.contextChanged
        }
        let request = try client.ptyConnectRequest(
            id: id, directory: directory, workspaceID: scope.workspaceID, cursor: 0
        )
        let stop = ProviderUsagePTYStopRequest()
        do {
            try await connection.run(request: request, initialCursor: 0) { [connection] event in
                if !(await receive(event)) {
                    await stop.request()
                    await connection.disconnect()
                }
            }
        } catch is CancellationError {
            try Task.checkCancellation()
            guard await stop.wasRequested else { throw CancellationError() }
        }
        try Task.checkCancellation()
    }

    func send(_ bytes: [UInt8]) async throws { try await connection.send(bytes) }

    func delete(id: String, scope: BackendScope) async throws -> ProviderUsagePTYDeleteResult {
        guard let directory = scope.directory, !directory.isEmpty else {
            throw ProviderUsageCredentialImportError.cleanupFailed
        }
        do {
            try await client.deletePTY(id: id, directory: directory, workspaceID: scope.workspaceID)
            return .deleted
        } catch let OpenCodeAPIError.httpError(status, _) where status == 404 {
            return .alreadyMissing
        } catch {
            throw ProviderUsageCredentialImportError.cleanupFailed
        }
    }
}

private actor ProviderUsagePTYStopRequest {
    private var requested = false

    func request() { requested = true }
    var wasRequested: Bool { requested }
}

private final class ProviderUsageRenewalPhaseBoundary: @unchecked Sendable {
    private enum State { case pending, committed, cancelled }

    private let lock = NSLock()
    private let enabled: Bool
    private var state = State.pending

    init(enabled: Bool) { self.enabled = enabled }

    func commit() -> Bool {
        guard enabled else { return true }
        return lock.withLock {
            guard state != .cancelled else { return false }
            state = .committed
            return true
        }
    }

    func cancelUnlessCommitted() -> Bool {
        guard enabled else { return true }
        return lock.withLock {
            guard state != .committed else { return false }
            state = .cancelled
            return true
        }
    }

    var isProtected: Bool { enabled && lock.withLock { state == .committed } }
}

actor ProviderUsageCredentialImportProcessor {
    enum ConsumeOutcome: Sendable {
        case continueReceiving(outbound: [UInt8]?)
        case complete
    }

    private enum State: Equatable { case awaitingReady, startPrepared, awaitingResult, complete, failed }

    private let operationID: UUID
    private let selection: ProviderUsageCredentialImportProtocol.Selection
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let psk: Data
    private let nonce: Data
    private nonisolated let renewalBoundary: ProviderUsageRenewalPhaseBoundary
    private var state = State.awaitingReady
    private var lineBuffer = ""
    private var outputBytes = 0
    private var transcript: String?
    private var keys: ProviderUsageCredentialImportProtocol.Keys?
    private var payload: ProviderUsageCredentialImportProtocol.ResultPayload?
    private var failure: ProviderUsageCredentialImportError?

    init(
        operationID: UUID, selection: ProviderUsageCredentialImportProtocol.Selection,
        privateKey: Curve25519.KeyAgreement.PrivateKey, psk: Data, nonce: Data
    ) {
        self.operationID = operationID
        self.selection = selection
        self.privateKey = privateKey
        self.psk = psk
        self.nonce = nonce
        renewalBoundary = ProviderUsageRenewalPhaseBoundary(enabled: selection.action == .renew)
    }

    func fail(_ error: ProviderUsageCredentialImportError) {
        guard failure == nil else { return }
        failure = error
        state = .failed
    }

    func failureOrConnectionError() -> ProviderUsageCredentialImportError {
        failure ?? .ptyConnectFailed
    }

    func commitStartSend() throws {
        guard state == .startPrepared else { throw ProviderUsageCredentialImportError.invalidFrame }
        guard renewalBoundary.commit() else { throw CancellationError() }
        state = .awaitingResult
    }

    nonisolated func protectsRenewalFromCancellation() -> Bool { renewalBoundary.isProtected }
    nonisolated func shouldCancelOperation() -> Bool { renewalBoundary.cancelUnlessCommitted() }

    func consume(_ text: String) throws -> ConsumeOutcome {
        guard failure == nil else { throw failure! }
        outputBytes += text.utf8.count
        guard outputBytes <= ProviderUsageCredentialImportProtocol.maximumOutputBytes else {
            fail(.outputTooLarge)
            throw ProviderUsageCredentialImportError.outputTooLarge
        }
        lineBuffer.append(text)
        var completed = false
        while let newline = lineBuffer.unicodeScalars.firstIndex(of: "\n") {
            var line = String(lineBuffer[..<newline])
            lineBuffer.removeSubrange(...newline)
            while line.last == "\r" { line.removeLast() }
            guard let frame = Self.protocolFrame(in: line) else { continue }
            line = frame
            if let outbound = try consumeLine(line) {
                return .continueReceiving(outbound: Array("\(outbound)\n".utf8))
            }
            if state == .complete { completed = true }
        }
        return completed ? .complete : .continueReceiving(outbound: nil)
    }

    func finish(candidate: ProviderUsageSetupCandidate) throws -> ProviderUsageCredentialReview {
        if let failure { throw failure }
        if lineBuffer.contains("\(ProviderUsageCredentialImportProtocol.marker)|") {
            throw ProviderUsageCredentialImportError.invalidFrame
        }
        guard state == .complete, let payload else { throw ProviderUsageCredentialImportError.invalidFrame }
        guard payload.ok, let credential = payload.credential, !credential.isEmpty,
              payload.error == nil else {
            throw Self.error(for: payload.error)
        }
        return ProviderUsageCredentialReview(
            candidate: candidate,
            secret: ProviderUsageTransientSecret(value: credential),
            providerAccountID: payload.accountID,
            credentialExpiresAt: payload.expires.map { Date(timeIntervalSince1970: $0 / 1_000) }
        )
    }

    private func consumeLine(_ line: String) throws -> String? {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        if fields.count == 4, fields[0] == ProviderUsageCredentialImportProtocol.marker,
           fields[1] == ProviderUsageCredentialImportProtocol.version, fields[2] == "ERROR" {
            let error = Self.error(for: fields[3])
            fail(error)
            throw error
        }
        switch state {
        case .awaitingReady:
            let ready = try ProviderUsageCredentialImportProtocol.authenticateReady(
                line, operationID: operationID, selection: selection,
                clientPublicKey: privateKey.publicKey.rawRepresentation, psk: psk
            )
            let derived = try ProviderUsageCredentialImportProtocol.deriveKeys(
                privateKey: privateKey, peerPublicKey: ready.serverPublicKey, psk: psk, transcript: ready.transcript
            )
            transcript = ready.transcript
            keys = derived
            state = .startPrepared
            return try ProviderUsageCredentialImportProtocol.startFrame(
                operationID: operationID, selection: selection, transcript: ready.transcript,
                key: derived.clientToServer, nonce: nonce
            )
        case .startPrepared:
            fail(.invalidFrame)
            throw ProviderUsageCredentialImportError.invalidFrame
        case .awaitingResult:
            guard line.contains("|RESULT|"), let transcript, let keys else {
                fail(.invalidFrame)
                throw ProviderUsageCredentialImportError.invalidFrame
            }
            payload = try ProviderUsageCredentialImportProtocol.openResult(
                line, operationID: operationID, selection: selection,
                transcript: transcript, key: keys.serverToClient
            )
            state = .complete
            return nil
        case .complete:
            fail(.replay)
            throw ProviderUsageCredentialImportError.replay
        case .failed:
            throw failure ?? ProviderUsageCredentialImportError.invalidFrame
        }
    }

    private static func error(for code: String?) -> ProviderUsageCredentialImportError {
        switch code {
        case "TIMED_OUT": .timedOut
        case "INVALID_FRAME": .invalidFrame
        case "AUTHENTICATION_FAILED": .authenticationFailed
        case "REPLAY": .replay
        case "INVALID_PROVIDER": .helperProviderInvalid
        case "INVALID_SOURCE": .helperSourceInvalid
        case "INVALID_CLIENT_KEY": .helperClientKeyInvalid
        case "INVALID_PSK": .helperPSKInvalid
        case "SOURCE_MISSING": .sourceMissing
        case "SOURCE_TOO_LARGE": .sourceTooLarge
        case "MALFORMED_SOURCE": .malformedSource
        case "ENTRY_MISSING": .entryMissing
        case "MULTIPLE_ENTRIES": .multipleEntries
        case "UNSUPPORTED_ENTRY": .unsupportedEntry
        case "UNSUPPORTED_SOURCE": .unsupportedSource
        case "SELECTED_PAYLOAD_TOO_LARGE": .selectedPayloadTooLarge
        case "SOURCE_REFRESH_NETWORK": .sourceRefreshNetwork
        case "SOURCE_REFRESH_REJECTED": .sourceRefreshRejected
        case "SOURCE_REFRESH_MALFORMED": .sourceRefreshMalformed
        case "SOURCE_REFRESH_WRITE_FAILED": .sourceRefreshWriteFailed
        case "SOURCE_CHANGED": .sourceChanged
        case "ACCOUNT_MISMATCH": .accountMismatch
        case "UNSUPPORTED_RUNTIME": .unsupportedRuntime
        default: .invalidFrame
        }
    }

    private static func protocolFrame(in line: String) -> String? {
        let marker = ProviderUsageCredentialImportProtocol.marker
        let version = ProviderUsageCredentialImportProtocol.version
        for type in ["READY", "RESULT"] {
            let prefix = "\(marker)|\(version)|\(type)|"
            if let range = line.range(of: prefix) {
                return String(line[range.lowerBound...])
            }
        }

        let errorPrefix = "\(marker)|\(version)|ERROR|"
        guard let range = line.range(of: errorPrefix) else { return nil }
        let candidate = String(line[range.lowerBound...])
        let fields = candidate.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let knownCodes: Set<String> = [
            "TIMED_OUT", "INVALID_FRAME", "AUTHENTICATION_FAILED", "REPLAY",
            "INVALID_PROVIDER", "INVALID_SOURCE", "INVALID_CLIENT_KEY", "INVALID_PSK",
            "SOURCE_MISSING", "SOURCE_TOO_LARGE", "MALFORMED_SOURCE", "ENTRY_MISSING",
            "MULTIPLE_ENTRIES", "UNSUPPORTED_ENTRY", "UNSUPPORTED_SOURCE", "SELECTED_PAYLOAD_TOO_LARGE",
            "SOURCE_REFRESH_NETWORK", "SOURCE_REFRESH_REJECTED", "SOURCE_REFRESH_MALFORMED",
            "SOURCE_REFRESH_WRITE_FAILED", "SOURCE_CHANGED", "ACCOUNT_MISMATCH", "UNSUPPORTED_RUNTIME"
        ]
        guard fields.count == 4, knownCodes.contains(fields[3]) else { return nil }
        return candidate
    }
}

private actor ProviderUsageCreatedPTYBox {
    private var value: OpenCodePTY?
    func set(_ value: OpenCodePTY) { self.value = value }
    func get() -> OpenCodePTY? { value }
}

private actor ProviderUsageCleanupGate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        if let result {
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
        }
    }

    func resolve(_ succeeded: Bool) {
        guard result == nil else { return }
        result = succeeded
        continuation?.resume(returning: succeeded)
        continuation = nil
    }
}

actor PTYProviderUsageCredentialImporter: ProviderUsageCredentialImporter {
    typealias ContextProvider = @Sendable () async -> ProviderUsageDiscoveryContext?
    typealias RandomBytes = @Sendable (Int) throws -> Data
    typealias PrivateKeyFactory = @Sendable () throws -> Curve25519.KeyAgreement.PrivateKey

    private let transport: any ProviderUsagePTYTransport
    private let currentContext: ContextProvider
    private let allowsInsecureTransport: Bool
    private let timeout: Duration
    private let renewalTimeout: Duration
    private let randomBytes: RandomBytes
    private let privateKeyFactory: PrivateKeyFactory
    private let cleanupTimeout: Duration = .milliseconds(250)

    init(
        transport: any ProviderUsagePTYTransport,
        currentContext: @escaping ContextProvider,
        allowsInsecureTransport: Bool = false,
        timeout: Duration = .seconds(15),
        renewalTimeout: Duration = .seconds(20),
        randomBytes: @escaping RandomBytes = { count in
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
            }
            guard status == errSecSuccess else { throw ProviderUsageCredentialImportError.invalidFrame }
            return data
        },
        privateKeyFactory: @escaping PrivateKeyFactory = { Curve25519.KeyAgreement.PrivateKey() }
    ) {
        self.transport = transport
        self.currentContext = currentContext
        self.allowsInsecureTransport = allowsInsecureTransport
        self.timeout = timeout
        self.renewalTimeout = renewalTimeout
        self.randomBytes = randomBytes
        self.privateKeyFactory = privateKeyFactory
    }

    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        try await perform(candidate: candidate, action: .read)
    }

    func renewCredential(
        for candidate: ProviderUsageSetupCandidate,
        expectedAccountID: String,
        currentAccessToken: String
    ) async throws -> ProviderUsageCredentialRenewal {
        let review = try await perform(
            candidate: candidate,
            action: .renew,
            expectedAccountID: expectedAccountID,
            currentAccessToken: currentAccessToken
        )
        guard let expiresAt = review.credentialExpiresAt else {
            throw ProviderUsageCredentialImportError.sourceRefreshMalformed
        }
        return ProviderUsageCredentialRenewal(
            secret: review.secret,
            expiresAt: expiresAt,
            providerAccountID: review.providerAccountID
        )
    }

    private func perform(
        candidate: ProviderUsageSetupCandidate,
        action: ProviderUsageCredentialImportProtocol.Selection.Action,
        expectedAccountID: String? = nil,
        currentAccessToken: String? = nil
    ) async throws -> ProviderUsageCredentialReview {
        guard candidate.apiProfile == .legacy else { throw ProviderUsageCredentialImportError.unsupportedProfile }
        try validateTransport()
        guard await currentContext() == candidate.discoveryContext else {
            throw ProviderUsageCredentialImportError.contextChanged
        }
        let selection = try ProviderUsageCredentialImportProtocol.Selection(
            candidate: candidate,
            action: action,
            expectedAccountID: expectedAccountID,
            currentAccessToken: currentAccessToken
        )
        let operationID = UUID()
        let privateKey = try privateKeyFactory()
        let psk = try randomBytes(32)
        let nonce = try randomBytes(12)
        guard psk.count == 32, nonce.count == 12 else { throw ProviderUsageCredentialImportError.invalidFrame }
        let processor = ProviderUsageCredentialImportProcessor(
            operationID: operationID, selection: selection, privateKey: privateKey, psk: psk, nonce: nonce
        )
        let request = OpenCodePTYCreateRequest(
            command: nil,
            args: ProviderUsageCredentialImportHelper.arguments,
            cwd: candidate.discoveryContext.scope.directory,
            title: ProviderUsageCredentialImportHelper.title,
            env: [
                ProviderUsageCredentialImportHelper.sourceEnvironmentKey: ProviderUsageCredentialImportHelper.source,
                "OCPI_OPERATION_ID": operationID.uuidString.lowercased(),
                "OCPI_PROVIDER": selection.provider,
                "OCPI_SOURCE": selection.source,
                "OCPI_EXPECTED_ACCOUNT_BINDING": selection.expectedAccountBinding,
                "OCPI_CURRENT_ACCESS_BINDING": selection.currentAccessBinding,
                "OCPI_CLIENT_PUBLIC_KEY": privateKey.publicKey.rawRepresentation.base64EncodedString(),
                "OCPI_PSK": psk.base64EncodedString()
            ]
        )

        let createdBox = ProviderUsageCreatedPTYBox()
        var primaryError: Error?
        var review: ProviderUsageCredentialReview?
        let deadline = action == .renew ? renewalTimeout : timeout
        let operationTransport = transport
        let contextProvider = currentContext
        let operationTask = Task.detached {
            try await Self.withTimeout(deadline) {
                try Task.checkCancellation()
                guard await contextProvider() == candidate.discoveryContext else {
                    throw ProviderUsageCredentialImportError.contextChanged
                }
                let pty: OpenCodePTY
                do {
                    pty = try await operationTransport.create(request: request, scope: candidate.discoveryContext.scope)
                } catch is CancellationError {
                    if action == .renew,
                       let result = try? await processor.finish(candidate: candidate) {
                        return result
                    }
                    throw CancellationError()
                } catch let error as ProviderUsageCredentialImportError {
                    throw error
                } catch let OpenCodeAPIError.httpError(status, _) where (100 ... 599).contains(status) {
                    throw ProviderUsageCredentialImportError.ptyCreateHTTPStatus(status)
                } catch {
                    throw ProviderUsageCredentialImportError.ptyCreateFailed
                }
                await createdBox.set(pty)
                try Task.checkCancellation()
                guard await contextProvider() == candidate.discoveryContext else {
                    throw ProviderUsageCredentialImportError.contextChanged
                }
                do {
                    try await operationTransport.connect(id: pty.id, scope: candidate.discoveryContext.scope) { event in
                        let protectedRenewal = processor.protectsRenewalFromCancellation()
                        if !protectedRenewal,
                           await contextProvider() != candidate.discoveryContext {
                            await processor.fail(.contextChanged)
                            return false
                        }
                        guard case let .output(text, _) = event else { return true }
                        do {
                            switch try await processor.consume(text) {
                            case let .continueReceiving(outbound):
                                if let outbound {
                                    guard await contextProvider() == candidate.discoveryContext else {
                                        await processor.fail(.contextChanged)
                                        return false
                                    }
                                    try await processor.commitStartSend()
                                    try await operationTransport.send(outbound)
                                }
                                return true
                            case .complete:
                                return false
                            }
                        } catch is CancellationError {
                            return false
                        } catch let error as ProviderUsageCredentialImportError {
                            await processor.fail(error)
                            return false
                        } catch {
                            await processor.fail(.invalidFrame)
                            return false
                        }
                    }
                } catch is CancellationError {
                    if action == .renew,
                       let result = try? await processor.finish(candidate: candidate) {
                        return result
                    }
                    throw CancellationError()
                } catch {
                    if let result = try? await processor.finish(candidate: candidate) { return result }
                    throw await processor.failureOrConnectionError()
                }
                if !processor.protectsRenewalFromCancellation() {
                    try Task.checkCancellation()
                    guard await contextProvider() == candidate.discoveryContext else {
                        throw ProviderUsageCredentialImportError.contextChanged
                    }
                }
                return try await processor.finish(candidate: candidate)
            }
        }
        do {
            review = try await withTaskCancellationHandler {
                try await operationTask.value
            } onCancel: {
                if processor.shouldCancelOperation() {
                    operationTask.cancel()
                }
            }
            if action == .read { try Task.checkCancellation() }
        } catch is CancellationError {
            primaryError = CancellationError()
        } catch let error as ProviderUsageCredentialImportError {
            primaryError = error
        } catch {
            primaryError = ProviderUsageCredentialImportError.connectionFailed
        }

        if let created = await createdBox.get() {
            let transport = transport
            let scope = candidate.discoveryContext.scope
            let cleanedUp = await bestEffortDelete(id: created.id, transport: transport, scope: scope)
            if !cleanedUp, primaryError == nil {
                primaryError = ProviderUsageCredentialImportError.cleanupFailed
            }
        }
        if let primaryError { throw primaryError }
        guard let review else { throw ProviderUsageCredentialImportError.invalidFrame }
        return review
    }

    private func bestEffortDelete(
        id: String, transport: any ProviderUsagePTYTransport, scope: BackendScope
    ) async -> Bool {
        let gate = ProviderUsageCleanupGate()
        let deleteTask = Task.detached { () -> Bool in
            do {
                _ = try await transport.delete(id: id, scope: scope)
                return true
            } catch {
                return false
            }
        }
        let timeout = cleanupTimeout
        let timeoutTask = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                await gate.resolve(false)
            } catch {
                // The delete completed or the parent resolved the race first.
            }
        }

        let result = await withCheckedContinuation { continuation in
            Task.detached { await gate.install(continuation) }
            Task.detached {
                await gate.resolve(await deleteTask.value)
            }
        }
        deleteTask.cancel()
        timeoutTask.cancel()
        return result
    }

    private func validateTransport() throws {
        switch transport.serverURL.scheme?.lowercased() {
        case "https": return
        case "http" where allowsInsecureTransport: return
        case "http": throw ProviderUsageCredentialImportError.insecureTransport
        default: throw ProviderUsageCredentialImportError.insecureTransport
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        _ duration: Duration, operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ProviderUsageCredentialImportError.timedOut
            }
            guard let result = await group.nextResult() else {
                throw ProviderUsageCredentialImportError.timedOut
            }
            group.cancelAll()
            while await group.nextResult() != nil {}
            return try result.get()
        }
    }
}
