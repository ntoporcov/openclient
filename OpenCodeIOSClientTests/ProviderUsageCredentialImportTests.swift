import CryptoKit
import Foundation
import XCTest
@testable import OpenClient

final class ProviderUsageCredentialImportTests: XCTestCase {
    // Values are pinned from Node's built-in crypto using explicit PKCS8/SPKI X25519 prefixes.
    func testPinnedNodeX25519HKDFAndChaChaVectors() throws {
        let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"))
        let psk = data("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f")
        let operationID = try XCTUnwrap(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
        let selection = try ProviderUsageCredentialImportProtocol.Selection(candidate: candidate(provider: .openRouter))
        XCTAssertEqual(client.publicKey.rawRepresentation.hex, "8f40c5adb68f25624ae5b214ea767a6ec94d829d3d7b5e1ad1ba6f3e2138285f")
        XCTAssertEqual(server.publicKey.rawRepresentation.hex, "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
        let transcript = ProviderUsageCredentialImportProtocol.transcript(
            operationID: operationID, selection: selection, clientPublicKey: client.publicKey.rawRepresentation,
            serverPublicKey: server.publicKey.rawRepresentation
        )
        let ready = ["OCPI", "1", "READY", operationID.uuidString.lowercased(), "openrouter",
                     "legacy-opencode-auth-v1", "0", server.publicKey.rawRepresentation.base64EncodedString(),
                      data("1d1d3b0de89ca8cdbb49c603416507b2e9737c63ae7f4050fe4c10cad24e0a56").base64EncodedString()]
            .joined(separator: "|")
        XCTAssertEqual(try ProviderUsageCredentialImportProtocol.authenticateReady(
            ready, operationID: operationID, selection: selection,
            clientPublicKey: client.publicKey.rawRepresentation, psk: psk
        ).transcript, transcript)
        let keys = try ProviderUsageCredentialImportProtocol.deriveKeys(
            privateKey: client, peerPublicKey: server.publicKey.rawRepresentation, psk: psk, transcript: transcript
        )
        XCTAssertEqual(keys.clientToServer.withUnsafeBytes { Data($0).hex }, "68c5e53fdad51c9f38d21479b04f15f33b673391a6b301985c9635eee16379c2")
        XCTAssertEqual(keys.serverToClient.withUnsafeBytes { Data($0).hex }, "a8950097492b0c3e0e38554a176796cae6129f8b3efc422e5f4deaaac1166a2f")
        let start = try ProviderUsageCredentialImportProtocol.startFrame(
            operationID: operationID, selection: selection, transcript: transcript,
            key: keys.clientToServer, nonce: data("606162636465666768696a6b")
        )
        XCTAssertEqual(String(start.split(separator: "|").last ?? ""), "EVM5XRW9In2OqXjELBVYMhJx")
        try ProviderUsageCredentialImportProtocol.openStart(
            start, operationID: operationID, selection: selection, transcript: transcript, key: keys.clientToServer
        )
        var forgedStartFields = start.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let replacement = forgedStartFields[8].last == "A" ? "B" : "A"
        forgedStartFields[8].removeLast()
        forgedStartFields[8].append(replacement)
        XCTAssertThrowsError(try ProviderUsageCredentialImportProtocol.openStart(
            forgedStartFields.joined(separator: "|"), operationID: operationID,
            selection: selection, transcript: transcript, key: keys.clientToServer
        )) { XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .authenticationFailed) }
        XCTAssertThrowsError(try ProviderUsageCredentialImportProtocol.openStart(
            start.replacingOccurrences(of: "|openrouter|", with: "|openai|"), operationID: operationID,
            selection: selection, transcript: transcript, key: keys.clientToServer
        ))
        let result = "OCPI|1|RESULT|00112233-4455-6677-8899-aabbccddeeff|openrouter|legacy-opencode-auth-v1|1|cHFyc3R1dnd4eXp7|3GwpjM6WAEPJ3uYqbZ8w12YGSP/bzw+umRk8jGDc8KtkgW5o0F8Brti7LgZYQI2j8ctzeaEiLOk="
        let opened = try ProviderUsageCredentialImportProtocol.openResult(
            result, operationID: operationID, selection: selection, transcript: transcript, key: keys.serverToClient
        )
        XCTAssertEqual(opened.credential, "synthetic-key")
        XCTAssertThrowsError(try ProviderUsageCredentialImportProtocol.openResult(
            result.replacingOccurrences(of: operationID.uuidString.lowercased(), with: UUID().uuidString.lowercased()),
            operationID: operationID, selection: selection, transcript: transcript, key: keys.serverToClient
        ))
    }

    func testAuthenticatedHandshakeReadsOnlyAfterStartAndReturnsRedactedReview() async throws {
        let context = context()
        let box = ImportContextBox(context)
        let transport = SyntheticImportTransport(mode: .success)
        let importer = deterministicImporter(transport: transport, box: box)
        let review = try await importer.importCredential(for: candidate(context: context, provider: .codex))
        XCTAssertEqual(review.secret.value, "synthetic-access")
        XCTAssertEqual(review.providerAccountID, "synthetic-account")
        XCTAssertTrue(review.description.contains("<redacted>"))
        XCTAssertFalse(review.description.contains("synthetic-access"))
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.authenticatedStart)
        XCTAssertTrue(snapshot.sourceRead)
        XCTAssertEqual(snapshot.created, 1)
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
    }

    func testAuthenticatedResultStopsAConnectionThatOtherwiseStaysOpen() async throws {
        let current = context()
        let transport = SyntheticImportTransport(mode: .keepOpenAfterResult)
        let importer = deterministicImporter(
            transport: transport, box: ImportContextBox(current), timeout: .milliseconds(500)
        )
        let started = ContinuousClock.now

        let review = try await importer.importCredential(for: candidate(context: current, provider: .codex))

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertEqual(review.secret.value, "synthetic-access")
        XCTAssertTrue(review.description.contains("<redacted>"))
        XCTAssertFalse(review.description.contains("synthetic-access"))
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.callbackRequestedStop)
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
    }

    func testRenewalActionIsAuthenticatedAndReturnsAccessOnly() async throws {
        let current = context()
        let setup = candidate(context: current, provider: .codex)
        let readSelection = try ProviderUsageCredentialImportProtocol.Selection(candidate: setup)
        let renewSelection = try ProviderUsageCredentialImportProtocol.Selection(
            candidate: setup,
            action: .renew,
            expectedAccountID: "synthetic-account",
            currentAccessToken: "current-access"
        )
        XCTAssertNotEqual(readSelection.source, renewSelection.source)
        XCTAssertEqual(renewSelection.expectedAccountBinding.count, 64)
        XCTAssertEqual(renewSelection.currentAccessBinding.count, 64)
        XCTAssertFalse(renewSelection.expectedAccountBinding.contains("synthetic-account"))
        XCTAssertFalse(renewSelection.currentAccessBinding.contains("current-access"))
        let readTranscript = ProviderUsageCredentialImportProtocol.transcript(
                operationID: UUID(uuidString: "10101010-1010-1010-1010-101010101010")!,
                selection: readSelection,
                clientPublicKey: Data(repeating: 1, count: 32),
                serverPublicKey: Data(repeating: 2, count: 32)
            )
        let renewTranscript = ProviderUsageCredentialImportProtocol.transcript(
                operationID: UUID(uuidString: "10101010-1010-1010-1010-101010101010")!,
                selection: renewSelection,
                clientPublicKey: Data(repeating: 1, count: 32),
                serverPublicKey: Data(repeating: 2, count: 32)
            )
        XCTAssertNotEqual(readTranscript, renewTranscript)
        XCTAssertTrue(renewTranscript.contains(renewSelection.expectedAccountBinding))
        XCTAssertTrue(renewTranscript.contains(renewSelection.currentAccessBinding))
        XCTAssertFalse(renewTranscript.contains("synthetic-account"))
        XCTAssertFalse(renewTranscript.contains("current-access"))
        let transport = SyntheticImportTransport(mode: .success)
        let importer = deterministicImporter(transport: transport, box: ImportContextBox(current))

        let renewal = try await importer.renewCredential(
            for: setup,
            expectedAccountID: "synthetic-account",
            currentAccessToken: "current-access"
        )

        XCTAssertEqual(renewal.secret.value, "synthetic-access")
        XCTAssertEqual(renewal.providerAccountID, "synthetic-account")
        XCTAssertEqual(renewal.expiresAt, Date(timeIntervalSince1970: 123))
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.authenticatedStart)
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("legacy-opencode-auth-renew-v1"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("fs.promises.rename(temp,file)"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("new URLSearchParams"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("const merged={...latest.root"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("currentEntry.access!==entry.access||currentEntry.refresh!==entry.refresh"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("verified.bytes.equals(latest.bytes)"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains(".auth.json.ocpi-renew.lock"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("return currentResult(currentEntry)"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("handle.chmod(0o600)"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("redirect:'error'"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("ACCOUNT_MISMATCH"))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.source.contains("refreshToken:"))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.source.contains("credential:entry.refresh"))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.source.contains("credential:tokens.refresh_token"))
        let helper = ProviderUsageCredentialImportHelper.source
        let modeBeforeRename = try XCTUnwrap(helper.range(of: "handle.chmod(0o600)"))
        let compareBeforeRename = try XCTUnwrap(helper.range(of: "verified.bytes.equals(latest.bytes)"))
        let rename = try XCTUnwrap(helper.range(of: "fs.promises.rename(temp,file)"))
        XCTAssertLessThan(modeBeforeRename.lowerBound, rename.lowerBound)
        XCTAssertLessThan(compareBeforeRename.lowerBound, rename.lowerBound)
    }

    func testForgedReadyAndResultAndDuplicateFramesAreRejectedAndCleaned() async {
        for mode in [SyntheticImportTransport.Mode.forgedReady, .forgedResult, .duplicateResult, .extraResult, .truncatedResult] {
            let context = context()
            let box = ImportContextBox(context)
            let transport = SyntheticImportTransport(mode: mode)
            let importer = deterministicImporter(transport: transport, box: box)
            await assertImportFails(importer, candidate: candidate(context: context, provider: .openRouter))
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.deleted, ["pty_import"], "\(mode)")
            if mode == .forgedReady { XCTAssertFalse(snapshot.sourceRead) }
        }
    }

    func testFragmentedCRLFControlNoiseWorksAndOversizedOutputFails() async throws {
        let current = context()
        let box = ImportContextBox(current)
        let fragmented = SyntheticImportTransport(mode: .fragmented)
        let review = try await deterministicImporter(transport: fragmented, box: box)
            .importCredential(for: candidate(context: current, provider: .openRouter))
        XCTAssertEqual(review.secret.value, "synthetic-key")

        let oversized = SyntheticImportTransport(mode: .oversizedOutput)
        await assertImportFails(deterministicImporter(transport: oversized, box: box),
                                candidate: candidate(context: current, provider: .openRouter), expected: .outputTooLarge)

        let shellNoise = SyntheticImportTransport(mode: .shellMarkerNoise)
        _ = try await deterministicImporter(transport: shellNoise, box: box)
            .importCredential(for: candidate(context: current, provider: .openRouter))

        let helperError = SyntheticImportTransport(mode: .helperError)
        await assertImportFails(deterministicImporter(transport: helperError, box: box),
                                candidate: candidate(context: current, provider: .openRouter), expected: .helperProviderInvalid)
    }

    func testFixtureExtractionNeverReturnsRefreshAndLeavesOpenRouterUnchanged() throws {
        let codex = try ProviderUsageCredentialImportProtocol.Selection(candidate: candidate(provider: .codex))
        let source = Data(#"{"openai":{"type":"oauth","access":"synthetic-access","refresh":"synthetic-refresh","expires":123000,"accountId":"acct"}}"#.utf8)
        let result = try ProviderUsageCredentialImportFixtureExtractor.extract(source, selection: codex)
        XCTAssertEqual(result.credential, "synthetic-access")
        XCTAssertEqual(result.accountID, "acct")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("synthetic-refresh"))
        let accessOnly = try ProviderUsageCredentialImportFixtureExtractor.extract(
            Data(#"{"openai":{"type":"oauth","access":"legacy-access"}}"#.utf8), selection: codex
        )
        XCTAssertEqual(accessOnly.credential, "legacy-access")

        let router = try ProviderUsageCredentialImportProtocol.Selection(candidate: candidate(provider: .openRouter))
        XCTAssertEqual(try ProviderUsageCredentialImportFixtureExtractor.extract(
            Data(#"{"openrouter":{"type":"api","key":"synthetic-key"},"other":{"key":"ignored"}}"#.utf8), selection: router
        ).credential, "synthetic-key")
        XCTAssertEqual(try ProviderUsageCredentialImportFixtureExtractor.extract(
            Data(#"{"openrouter":{"type":"api","key":"synthetic-key","refresh":"ignored"}}"#.utf8), selection: router
        ).credential, "synthetic-key")
        XCTAssertThrowsError(try ProviderUsageCredentialImportFixtureExtractor.extract(Data("{}".utf8), selection: router)) {
            XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .entryMissing)
        }
        XCTAssertThrowsError(try ProviderUsageCredentialImportFixtureExtractor.extract(
            Data(#"{"openrouter":[{"type":"api","key":"a"},{"type":"api","key":"b"}]}"#.utf8), selection: router
        )) { XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .multipleEntries) }
        XCTAssertThrowsError(try ProviderUsageCredentialImportFixtureExtractor.extract(Data("{".utf8), selection: router)) {
            XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .malformedSource)
        }
        XCTAssertThrowsError(try ProviderUsageCredentialImportFixtureExtractor.extract(
            Data(repeating: 0x20, count: ProviderUsageCredentialImportProtocol.maximumSourceBytes + 1), selection: router
        )) { XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .sourceTooLarge) }
        let largeSecret = String(repeating: "x", count: ProviderUsageCredentialImportProtocol.maximumSelectedPayloadBytes)
        let largeSource = try JSONSerialization.data(withJSONObject: ["openrouter": ["type": "api", "key": largeSecret]])
        XCTAssertThrowsError(try ProviderUsageCredentialImportFixtureExtractor.extract(largeSource, selection: router)) {
            XCTAssertEqual($0 as? ProviderUsageCredentialImportError, .selectedPayloadTooLarge)
        }
    }

    func testContextProfileAndTransportPolicyFailClosedBeforeCreate() async throws {
        let original = context()
        let switched = context(lifetime: UUID())
        let box = ImportContextBox(switched)
        let transport = SyntheticImportTransport(mode: .success, serverURL: URL(string: "https://example.com")!)
        await assertImportFails(deterministicImporter(transport: transport, box: box),
                                candidate: candidate(context: original, provider: .openRouter), expected: .contextChanged)
        let rejectedSnapshot = await transport.snapshot()
        XCTAssertEqual(rejectedSnapshot.created, 0)

        await box.set(original)
        let http = SyntheticImportTransport(mode: .success, serverURL: URL(string: "http://example.com")!)
        await assertImportFails(deterministicImporter(transport: http, box: box),
                                candidate: candidate(context: original, provider: .openRouter), expected: .insecureTransport)
        let httpSnapshot = await http.snapshot()
        XCTAssertEqual(httpSnapshot.created, 0)
        let optedIn = deterministicImporter(transport: http, box: box, allowsInsecureTransport: true)
        _ = try await optedIn.importCredential(for: candidate(context: original, provider: .openRouter))
        do {
            _ = try await deterministicImporter(transport: http, box: box)
                .renewCredential(
                    for: candidate(context: original, provider: .codex),
                    expectedAccountID: "synthetic-account",
                    currentAccessToken: "current-access"
                )
            XCTFail("Expected insecure renewal rejection")
        } catch let error as ProviderUsageCredentialImportError {
            XCTAssertEqual(error, .insecureTransport)
        }

        var v2 = original
        v2 = .init(backend: v2.backend, connectionLifetimeID: v2.connectionLifetimeID, apiProfile: .v2, scope: v2.scope)
        await box.set(v2)
        await assertImportFails(deterministicImporter(transport: transport, box: box),
                                candidate: candidate(context: v2, provider: .openRouter), expected: .unsupportedProfile)
    }

    func testLifetimeProfileAndScopeSwitchDuringOperationDropResultAndDeleteExactPTY() async {
        let original = context()
        let profile = ProviderUsageDiscoveryContext(
            backend: original.backend, connectionLifetimeID: original.connectionLifetimeID,
            apiProfile: .v2, scope: original.scope
        )
        for switched in [context(lifetime: UUID()), profile, context(directory: "/tmp/other")] {
            let box = ImportContextBox(original)
            let transport = SyntheticImportTransport(mode: .switchContext { await box.set(switched) })
            await assertImportFails(deterministicImporter(transport: transport, box: box),
                                    candidate: candidate(context: original, provider: .openRouter), expected: .contextChanged)
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.deleted, ["pty_import"])
        }
    }

    func testTimeoutCreateConnectDeleteMissingAndCleanupFailureAreSanitized() async throws {
        let current = context()
        let box = ImportContextBox(current)
        let hanging = SyntheticImportTransport(mode: .hang)
        await assertImportFails(deterministicImporter(transport: hanging, box: box, timeout: .milliseconds(1)),
                                candidate: candidate(context: current, provider: .openRouter), expected: .timedOut)
        let hangingSnapshot = await hanging.snapshot()
        XCTAssertEqual(hangingSnapshot.deleted, ["pty_import"])

        for mode in [SyntheticImportTransport.Mode.createFailure, .createHTTPFailure, .connectFailure, .deleteMissing] {
            let transport = SyntheticImportTransport(mode: mode)
            if mode == .createFailure {
                await assertImportFails(deterministicImporter(transport: transport, box: box),
                                        candidate: candidate(context: current, provider: .openRouter), expected: .ptyCreateFailed)
            } else if mode == .createHTTPFailure {
                await assertImportFails(deterministicImporter(transport: transport, box: box),
                                        candidate: candidate(context: current, provider: .openRouter), expected: .ptyCreateHTTPStatus(422))
            } else if mode == .connectFailure {
                await assertImportFails(deterministicImporter(transport: transport, box: box),
                                        candidate: candidate(context: current, provider: .openRouter), expected: .ptyConnectFailed)
            } else {
                _ = try await deterministicImporter(transport: transport, box: box)
                    .importCredential(for: candidate(context: current, provider: .openRouter))
            }
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.deleted, [.createFailure, .createHTTPFailure].contains(mode) ? [] : ["pty_import"])
        }
        let cleanup = SyntheticImportTransport(mode: .cleanupFailure)
        await assertImportFails(deterministicImporter(transport: cleanup, box: box),
                                candidate: candidate(context: current, provider: .openRouter), expected: .cleanupFailed)
    }

    func testCancellationAndLateCreateStillDeleteOnlyCreatedPTY() async {
        for mode in [SyntheticImportTransport.Mode.hang, .createLate] {
            let current = context()
            let box = ImportContextBox(current)
            let transport = SyntheticImportTransport(mode: mode)
            let importer = deterministicImporter(transport: transport, box: box, timeout: .seconds(5))
            let setupCandidate = candidate(context: current, provider: .openRouter)
            let task = Task { try await importer.importCredential(for: setupCandidate) }
            await transport.waitUntilCreated()
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Cancellation must not publish a review")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let snapshot = await transport.snapshot()
            XCTAssertEqual(snapshot.deleted, ["pty_import"])
        }
    }

    func testRenewalIgnoresCancellationAndContextInvalidationAfterStart() async throws {
        let original = context()
        let box = ImportContextBox(original)
        let transport = SyntheticImportTransport(mode: .deferredRenewalResult)
        let importer = deterministicImporter(transport: transport, box: box)
        let setup = candidate(context: original, provider: .codex)
        let task = Task {
            try await importer.renewCredential(
                for: setup,
                expectedAccountID: "synthetic-account",
                currentAccessToken: "current-access"
            )
        }

        await transport.waitUntilStartSent()
        await box.set(context(directory: "/tmp/other", lifetime: UUID()))
        task.cancel()
        await transport.releaseDeferredResult()

        let renewal = try await task.value
        XCTAssertEqual(renewal.secret.value, "synthetic-access")
        XCTAssertEqual(renewal.providerAccountID, "synthetic-account")
        let snapshot = await transport.snapshot()
        XCTAssertTrue(snapshot.authenticatedStart)
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
    }

    func testRenewalRemainsCancellableBeforeStart() async {
        let current = context()
        let transport = SyntheticImportTransport(mode: .hang)
        let importer = deterministicImporter(transport: transport, box: ImportContextBox(current))
        let setup = candidate(context: current, provider: .codex)
        let task = Task {
            try await importer.renewCredential(
                for: setup,
                expectedAccountID: "synthetic-account",
                currentAccessToken: "current-access"
            )
        }

        await transport.waitUntilCreated()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation before START must stop renewal")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let snapshot = await transport.snapshot()
        XCTAssertFalse(snapshot.authenticatedStart)
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
    }

    func testTimeoutDoesNotWaitForUnresponsiveCleanup() async {
        let current = context()
        let transport = SyntheticImportTransport(mode: .cleanupHang)
        let importer = deterministicImporter(transport: transport, box: ImportContextBox(current), timeout: .milliseconds(1))
        let started = ContinuousClock.now

        await assertImportFails(importer, candidate: candidate(context: current, provider: .openRouter), expected: .timedOut)

        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.deleted, ["pty_import"])
    }

    @MainActor
    func testDedicatedImporterDoesNotMutateExistingTerminalStore() async throws {
        let current = context()
        let store = TerminalStore()
        store.activate(directory: "/tmp/project")
        store.append(.init(id: "existing", title: "Existing", command: "/bin/zsh", args: [], cwd: "/tmp/project",
                           status: "running", pid: 7), directory: "/tmp/project")
        let transport = SyntheticImportTransport(mode: .success)
        _ = try await deterministicImporter(transport: transport, box: ImportContextBox(current))
            .importCredential(for: candidate(context: current, provider: .openRouter))
        XCTAssertEqual(store.activeWorkspace.terminals.map(\.id), ["existing"])

        let helper = OpenCodePTY(
            id: "pty_import",
            title: ProviderUsageCredentialImportHelper.title,
            command: "/bin/zsh",
            args: ProviderUsageCredentialImportHelper.arguments,
            cwd: "/tmp/project",
            status: "running",
            pid: 42
        )
        XCTAssertTrue(ProviderUsageCredentialImportHelper.owns(helper))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.owns(
            .init(id: "user", title: helper.title, command: "node", args: ["-e", "user script"],
                  cwd: helper.cwd, status: "running", pid: 43)
        ))
    }

    func testPTYDiagnosticsRedactCreateBodiesForLegacyAndV2() {
        let secret = "synthetic-psk-never-log"
        let body = Data("{\"env\":{\"OCPI_PSK\":\"\(secret)\"},\"args\":[\"-e\",\"synthetic-helper-body\"]}".utf8)
        for path in ["https://example.com/pty", "https://example.com/api/pty"] {
            let output = OpenCodeAPIClient.debugBodyDescription(body, url: URL(string: path))
            XCTAssertTrue(output.contains("<redacted"))
            XCTAssertFalse(output.contains(secret))
            XCTAssertFalse(output.contains("synthetic-helper-body"))
        }
        let request = OpenCodePTYCreateRequest(command: "node", args: ["-e", "synthetic-helper-body"],
                                               env: ["OCPI_PSK": secret])
        XCTAssertFalse(String(describing: request).contains(secret))
        XCTAssertFalse(String(reflecting: request).contains("synthetic-helper-body"))
        XCTAssertTrue(ProviderUsageCredentialImportHelper.source.contains("OPENCODE_AUTH_CONTENT"))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.launchCommand.contains("OCPI_PSK"))
        XCTAssertFalse(ProviderUsageCredentialImportHelper.launchCommand.contains("node:crypto"))
        XCTAssertEqual(ProviderUsageCredentialImportHelper.arguments.first, "-lic")
        let sanitized = ProviderUsageCredentialImportError.ptyCreateHTTPStatus(422)
        XCTAssertEqual(sanitized.code, "PTY_CREATE_HTTP_422")
        XCTAssertFalse(sanitized.description.contains("synthetic-helper-body"))
    }

    private func deterministicImporter(
        transport: SyntheticImportTransport, box: ImportContextBox,
        allowsInsecureTransport: Bool = false, timeout: Duration = .seconds(1)
    ) -> PTYProviderUsageCredentialImporter {
        PTYProviderUsageCredentialImporter(
            transport: transport, currentContext: { await box.get() },
            allowsInsecureTransport: allowsInsecureTransport, timeout: timeout,
            randomBytes: { count in Data(repeating: count == 32 ? 0x44 : 0x66, count: count) },
            privateKeyFactory: { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32)) }
        )
    }

    private func assertImportFails(
        _ importer: PTYProviderUsageCredentialImporter, candidate: ProviderUsageSetupCandidate,
        expected: ProviderUsageCredentialImportError? = nil
    ) async {
        do {
            _ = try await importer.importCredential(for: candidate)
            XCTFail("Expected import failure")
        } catch {
            if let expected { XCTAssertEqual(error as? ProviderUsageCredentialImportError, expected) }
            XCTAssertFalse(String(describing: error).contains("synthetic-key"))
        }
    }

    private func context(directory: String = "/tmp/project", lifetime: UUID = UUID()) -> ProviderUsageDiscoveryContext {
        .init(backend: .init(id: "server", name: "Server", version: "1"), connectionLifetimeID: lifetime,
              apiProfile: .legacy, scope: .init(projectID: "project", directory: directory, workspaceID: "workspace"))
    }

    private func candidate(
        context: ProviderUsageDiscoveryContext? = nil, provider: ProviderUsageProvider
    ) -> ProviderUsageSetupCandidate {
        let context = context ?? self.context()
        return .init(id: UUID(), provider: provider, discoveryContext: context,
                     sourceIdentity: .legacyProvider(providerID: provider == .codex ? "openai" : "openrouter"),
                     sourceKind: .openCodeAuth, credentialKind: provider == .codex ? .oauthAccessToken : .apiKey,
                     replacingAccountID: nil)
    }

    private func data(_ hex: String) -> Data { Data(stride(from: 0, to: hex.count, by: 2).map {
        UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)!
    }) }
}

private actor ImportContextBox {
    private var value: ProviderUsageDiscoveryContext?
    init(_ value: ProviderUsageDiscoveryContext?) { self.value = value }
    func get() -> ProviderUsageDiscoveryContext? { value }
    func set(_ value: ProviderUsageDiscoveryContext?) { self.value = value }
}

private actor SyntheticImportTransport: ProviderUsagePTYTransport {
    enum Mode: Sendable, Equatable {
        case success, keepOpenAfterResult, deferredRenewalResult, fragmented, shellMarkerNoise, helperError
        case forgedReady, forgedResult, duplicateResult, extraResult, truncatedResult
        case oversizedOutput, hang, createLate, createFailure, createHTTPFailure, connectFailure, deleteMissing, cleanupFailure, cleanupHang
        case switchContext(@Sendable () async -> Void)

        static func == (lhs: Mode, rhs: Mode) -> Bool {
            String(describing: lhs) == String(describing: rhs)
        }
    }

    struct Snapshot: Sendable {
        let created: Int
        let deleted: [String]
        let authenticatedStart: Bool
        let sourceRead: Bool
        let callbackRequestedStop: Bool
    }
    nonisolated let serverURL: URL
    private let mode: Mode
    private var request: OpenCodePTYCreateRequest?
    private var receiver: (@Sendable (OpenCodePTYSocketEvent) async -> Bool)?
    private var created = 0
    private var deleted: [String] = []
    private var authenticatedStart = false
    private var sourceRead = false
    private var callbackRequestedStop = false
    private var selection: ProviderUsageCredentialImportProtocol.Selection?
    private var operationID: UUID?
    private var transcript: String?
    private var keys: ProviderUsageCredentialImportProtocol.Keys?
    private var createWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var deferredResultContinuation: CheckedContinuation<Void, Never>?

    init(mode: Mode, serverURL: URL = URL(string: "https://example.com")!) {
        self.mode = mode
        self.serverURL = serverURL
    }

    func create(request: OpenCodePTYCreateRequest, scope: BackendScope) async throws -> OpenCodePTY {
        created += 1
        createWaiters.forEach { $0.resume() }
        createWaiters.removeAll()
        self.request = request
        if case let .switchContext(action) = mode { await action() }
        if mode == .createFailure { throw URLError(.cannotConnectToHost) }
        if mode == .createHTTPFailure { throw OpenCodeAPIError.httpError(422, "synthetic-helper-body") }
        if mode == .createLate {
            do { try await Task.sleep(for: .seconds(60)) } catch {}
        }
        return .init(id: "pty_import", title: "Importer", command: "/bin/zsh", args: request.args ?? [], cwd: scope.directory ?? "",
                     status: "running", pid: 42)
    }

    func connect(
        id: String, scope: BackendScope,
        receive: @escaping @Sendable (OpenCodePTYSocketEvent) async -> Bool
    ) async throws {
        if mode == .connectFailure { throw URLError(.cannotConnectToHost) }
        receiver = receive
        if mode == .oversizedOutput {
            _ = await receive(.output(String(repeating: "x", count: 65_537), cursor: 65_537))
            return
        }
        if mode == .hang || mode == .cleanupHang {
            try await Task.sleep(for: .seconds(60))
            return
        }
        if mode == .shellMarkerNoise {
            _ = await receive(.output(
                "shell: const fail=code=>{process.stdout.write('OCPI|1|ERROR|'+code+'\\r\\n')}\r\n",
                cursor: 81
            ))
        }
        if mode == .helperError {
            _ = await receive(.output("OCPI|1|ERROR|INVALID_PROVIDER\r\n", cursor: 39))
            return
        }
        let ready = try prepareReady(forged: mode == .forgedReady)
        if mode == .fragmented {
            _ = await receive(.cursor(20))
            _ = await receive(.output("startup noise\r\n\u{1B}[?25l" + String(ready.prefix(17)), cursor: 17))
            _ = await receive(.output(String(ready.dropFirst(17)) + "\r\r\n", cursor: ready.utf16.count + 1))
        } else {
            _ = await receive(.output(ready + "\r\n", cursor: ready.utf16.count + 2))
        }
        if mode == .keepOpenAfterResult, !callbackRequestedStop {
            try await Task.sleep(for: .seconds(60))
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard let operationID, let selection, let transcript, let keys else { throw ProviderUsageCredentialImportError.invalidFrame }
        try ProviderUsageCredentialImportProtocol.openStart(
            line, operationID: operationID, selection: selection, transcript: transcript, key: keys.clientToServer
        )
        authenticatedStart = true
        sourceRead = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        if mode == .deferredRenewalResult {
            await withCheckedContinuation { deferredResultContinuation = $0 }
        }
        let payload: ProviderUsageCredentialImportProtocol.ResultPayload = selection.provider == "openai"
            ? .init(ok: true, credential: "synthetic-access", accountID: "synthetic-account", expires: 123_000, error: nil)
            : .init(ok: true, credential: "synthetic-key", accountID: nil, expires: nil, error: nil)
        let key = mode == .forgedResult ? SymmetricKey(data: Data(repeating: 0x99, count: 32)) : keys.serverToClient
        let result = try ProviderUsageCredentialImportProtocol.resultFrame(
            payload, operationID: operationID, selection: selection, transcript: transcript,
            key: key, nonce: Data(repeating: 0x77, count: 12)
        )
        guard let receiver else { return }
        if mode == .truncatedResult {
            _ = await receiver(.output(String(result.dropLast(8)), cursor: result.utf16.count - 8))
            return
        }
        if !(await receiver(.output(result + "\r\r\n", cursor: result.utf16.count + 3))) {
            callbackRequestedStop = true
        }
        if mode == .duplicateResult || mode == .extraResult {
            _ = await receiver(.output(result + "\n", cursor: result.utf16.count * 2 + 3))
        }
    }

    func delete(id: String, scope: BackendScope) async throws -> ProviderUsagePTYDeleteResult {
        deleted.append(id)
        if mode == .cleanupFailure { throw ProviderUsageCredentialImportError.cleanupFailed }
        if mode == .cleanupHang {
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
        }
        return mode == .deleteMissing ? .alreadyMissing : .deleted
    }

    func snapshot() -> Snapshot {
        .init(created: created, deleted: deleted, authenticatedStart: authenticatedStart,
              sourceRead: sourceRead, callbackRequestedStop: callbackRequestedStop)
    }

    func waitUntilCreated() async {
        if created > 0 { return }
        await withCheckedContinuation { createWaiters.append($0) }
    }

    func waitUntilStartSent() async {
        if authenticatedStart { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseDeferredResult() {
        deferredResultContinuation?.resume()
        deferredResultContinuation = nil
    }

    private func prepareReady(forged: Bool) throws -> String {
        guard let env = request?.env,
              let operationID = UUID(uuidString: env["OCPI_OPERATION_ID"] ?? ""),
              let clientPublic = Data(base64Encoded: env["OCPI_CLIENT_PUBLIC_KEY"] ?? ""),
              let psk = Data(base64Encoded: env["OCPI_PSK"] ?? "") else {
            throw ProviderUsageCredentialImportError.invalidFrame
        }
        let server = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let provider = env["OCPI_PROVIDER"]!
        let source = env["OCPI_SOURCE"]!
        let credentialKind: ProviderUsageCredentialKind = provider == "openai" ? .oauthAccessToken : .apiKey
        let candidate = ProviderUsageSetupCandidate(
            id: UUID(), provider: provider == "openai" ? .codex : .openRouter,
            discoveryContext: .init(backend: .init(id: "server", name: "", version: ""), connectionLifetimeID: UUID(),
                                    apiProfile: .legacy, scope: .init()),
            sourceIdentity: .legacyProvider(providerID: provider), sourceKind: .openCodeAuth,
            credentialKind: credentialKind, replacingAccountID: nil
        )
        let action: ProviderUsageCredentialImportProtocol.Selection.Action = source.contains("renew") ? .renew : .read
        let selection = try ProviderUsageCredentialImportProtocol.Selection(
            candidate: candidate,
            action: action,
            expectedAccountID: action == .renew ? "synthetic-account" : nil,
            currentAccessToken: action == .renew ? "current-access" : nil
        )
        let transcript = ProviderUsageCredentialImportProtocol.transcript(
            operationID: operationID, selection: selection, clientPublicKey: clientPublic,
            serverPublicKey: server.publicKey.rawRepresentation
        )
        var auth = Data(HMAC<SHA256>.authenticationCode(
            for: Data("\(transcript)|READY|0".utf8), using: SymmetricKey(data: psk)
        ))
        if forged { auth[0] ^= 1 }
        self.operationID = operationID
        self.selection = selection
        self.transcript = transcript
        keys = try ProviderUsageCredentialImportProtocol.deriveKeys(
            privateKey: server, peerPublicKey: clientPublic, psk: psk, transcript: transcript
        )
        return ["OCPI", "1", "READY", operationID.uuidString.lowercased(), provider, source, "0",
                server.publicKey.rawRepresentation.base64EncodedString(), auth.base64EncodedString()].joined(separator: "|")
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
