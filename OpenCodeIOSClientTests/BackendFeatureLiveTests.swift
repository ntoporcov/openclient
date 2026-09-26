import Foundation
import XCTest
@testable import OpenClient

/// Opt-in integration tests. Never target the persistent development servers.
@MainActor
final class BackendFeatureLiveTests: XCTestCase {
    func testNativeCommandEncodingRunsFixtureOwnedCommandThroughScriptedProvider() async throws {
        let (client, directory, _) = try await context(timeout: 15)
        let fixture = try OpenCodeV2LiveFixture.load()
        let sessionID = try await ownedSession(client, directory: directory)
        var commands = try await client.listV2Commands(directory: directory)
        // The runtime activates configured catalogs asynchronously on first location access.
        for _ in 0..<40 where !commands.contains(where: { $0.name == "acceptance" }) {
            try await Task.sleep(for: .milliseconds(250))
            commands = try await client.listV2Commands(directory: directory)
        }
        let command = try XCTUnwrap(commands.first { $0.name == "acceptance" }, "Expected the fixture-owned acceptance command")
        let suffix = "command_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let marker = "[[acceptance:stream:\(suffix)]]"
        // Exercise the production encoder and the only configured fixture command. The
        // generated provider is loopback-only and cannot forward to a real provider.
        let completion = BackendFeatureCommandCompletion()
        let commandTask = Task {
            do {
                try await client.sendV2Command(sessionID: sessionID, command: command.name, arguments: suffix)
                await completion.finish()
            } catch {
                await completion.finish(failure: String(describing: error))
            }
        }
        // A later failure must still release the fixture provider. Do not await the
        // command task in teardown because a broken transport could outlive cancellation.
        addTeardownBlock { @MainActor in
            _ = try? await self.control(fixture, path: "/control/finish", body: ["marker": marker])
            commandTask.cancel()
        }
        let firstHold = try await controlEvent(fixture, marker: marker, kind: "held")
        let firstSequence = try XCTUnwrap(firstHold["seq"] as? Int)
        _ = try await control(fixture, path: "/control/advance", body: ["marker": marker])
        _ = try await controlEvent(fixture, marker: marker, kind: "held", after: firstSequence)
        _ = try await control(fixture, path: "/control/finish", body: ["marker": marker])
        _ = try await controlEvent(fixture, marker: marker, kind: "finished")
        try await waitForCommand(completion)
        try await client.waitForV2Session(sessionID: sessionID)

        let transcript = try await client.listV2Messages(sessionID: sessionID, limit: 20)
        let expected = "Acceptance stream/\(suffix): first. Acceptance stream/\(suffix): progress. Acceptance stream/\(suffix): complete."
        // The canonical wire history also includes a model-switched record, which
        // normalization intentionally presents as a synthetic assistant message.
        let meaningfulAssistants = transcript.messages.filter { message in
            message.info.role == "assistant" && message.parts.contains { part in
                part.synthetic != true && !(part.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        XCTAssertEqual(meaningfulAssistants.count, 1)
        let response = try XCTUnwrap(meaningfulAssistants.first)
        XCTAssertEqual(
            response.parts.filter { $0.synthetic != true }.compactMap(\.text).joined(),
            expected
        )
        let status = try await control(fixture, path: "/control/status")
        let events = try XCTUnwrap(status["events"] as? [[String: Any]])
        XCTAssertEqual(events.filter { $0["marker"] as? String == marker && $0["kind"] as? String == "request" }.count, 1)
    }

    func testNativeFormServicePreservesTypedAnswerAndCancellation() async throws {
        let (client, directory, _) = try await context()
        let sessionID = try await ownedSession(client, directory: directory)
        let service = OpenCodeSessionFormsService(client: client)
        let scope = BackendScope(projectID: "global", directory: directory)
        let fields: [[String: OpenCodeJSONValue]] = [
            ["key": .string("optional"), "type": .string("string")],
            ["key": .string("count"), "type": .string("integer"), "default": .number(7)],
            ["key": .string("enabled"), "type": .string("boolean"), "required": .bool(true)],
            ["key": .string("choices"), "type": .string("multiselect"), "custom": .bool(true),
             "options": .array([.object(["value": .string("a"), "label": .string("A")])])],
            ["key": .string("conditional"), "type": .string("string"), "default": .string("visible"),
             "when": .array([.object(["key": .string("enabled"), "op": .string("eq"), "value": .bool(false)])])],
            ["key": .string("hidden"), "type": .string("string"), "default": .string("must not leak"),
             "when": .array([.object(["key": .string("enabled"), "op": .string("eq"), "value": .bool(true)])])],
            ["key": .string("ack"), "type": .string("external"), "url": .string("http://127.0.0.1:14097/never-open")]
        ]
        let formID = "frm_\(UUID().uuidString)"
        _ = try await object(client, "/api/session/\(sessionID)/form", method: "POST", body: [
            "id": .string(formID), "title": .string("Owned typed form"), "fields": .array(fields.map(OpenCodeJSONValue.object))
        ])
        let reference = BackendFormReference(key: .init(sessionID: sessionID, formID: formID), directory: directory)
        let form = try await service.readForm(reference)
        XCTAssertEqual(form.sessionID, sessionID)
        let pending = try await service.pendingForms(sessionID: sessionID, scope: scope)
        XCTAssertEqual(pending.map(\.id), [formID])
        let state = try await service.readState(reference)
        XCTAssertEqual(state, .pending)
        let answer = try form.contract.answer(values: [
            "enabled": .bool(false), "choices": .array([.string("a"), .string("custom")]), "ack": .bool(true)
        ])
        let expected: BackendFormAnswer = [
            "count": .number(7), "enabled": .boolean(false), "choices": .strings(["a", "custom"]),
            "conditional": .string("visible"), "ack": .boolean(true)
        ]
        XCTAssertEqual(answer, expected)
        try await service.reply(reference, answer: answer)
        let answered = try await service.readState(reference)
        XCTAssertEqual(answered, .answered(expected))
        let remaining = try await service.pendingForms(sessionID: sessionID, scope: scope)
        XCTAssertTrue(remaining.isEmpty)

        let cancelID = "frm_\(UUID().uuidString)"
        _ = try await object(client, "/api/session/\(sessionID)/form", method: "POST", body: [
            "id": .string(cancelID), "title": .string("Owned cancellation"), "fields": .array(fields.map(OpenCodeJSONValue.object))
        ])
        let cancellation = BackendFormReference(key: .init(sessionID: sessionID, formID: cancelID), directory: directory)
        try await service.cancel(cancellation)
        let cancelled = try await service.readState(cancellation)
        XCTAssertEqual(cancelled, .cancelled)
        let afterCancel = try await service.pendingForms(sessionID: sessionID, scope: scope)
        XCTAssertTrue(afterCancel.isEmpty)
    }

    func testRealWorktreeLifecycleRequiresForceAndRetainsPausedSession() async throws {
        let (client, _, root) = try await context()
        let fixture = try OpenCodeV2LiveFixture.load()
        let source = fixture.gitRoot
        let parent = fixture.worktreeDestinationParent
        let git = source.appendingPathComponent(".git")
        let gitValues = try git.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard source.path == root.appendingPathComponent("git-fixture").path, parent.path == root.appendingPathComponent("copies").path,
              sourceValues.isDirectory == true, sourceValues.isSymbolicLink == false,
              gitValues.isDirectory == true, gitValues.isSymbolicLink == false,
              !FileManager.default.fileExists(atPath: git.appendingPathComponent("commondir").path),
              parentValues.isDirectory == true, parentValues.isSymbolicLink == false else {
            throw BackendFeatureLiveFailure("Use only the existing disposable git-fixture and sibling copies directory")
        }
        let service = OpenCodeWorktreeServices(client: client, profile: .v2)
        // This GET-based discovery deliberately registers only the approved fixture project.
        let resolution = try await service.resolveProject(directory: source.path)
        let scope = resolution.scope
        let projectID = try XCTUnwrap(scope.projectID)
        let location = try await client.getV2Location(directory: scope.directory, workspaceID: scope.workspaceID)
        guard projectID != "global", scope.directory == source.path, scope.workspaceID == nil,
              location.directory == source.path, location.workspaceID == nil, location.project.id == projectID,
              sameApprovedFixturePath(location.project.directory, expected: source),
              resolution.project.worktree == location.project.directory, resolution.project.vcs == "git",
              resolution.canonicalDirectory == location.project.canonical else {
            throw BackendFeatureLiveFailure("Fixture discovery did not resolve the expected Git root")
        }
        // The catalog canonical may name another clone. Only the independently verified selected root is a source.
        let sourceDirectory = resolution.project.worktree
        let destinationParent = URL(fileURLWithPath: sourceDirectory).deletingLastPathComponent().appendingPathComponent("copies")
        guard sameApprovedFixturePath(destinationParent.path, expected: parent) else {
            throw BackendFeatureLiveFailure("Resolved destination is outside the approved fixture")
        }
        let initial = try await service.inventory(scope: scope)
        guard initial.contains(.init(directory: sourceDirectory, kind: .root)) else {
            throw BackendFeatureLiveFailure("Selected fixture must be registered as an independent Git root")
        }
        let rootStatus = try await client.listV2FileStatus(directory: source.path)
        XCTAssertTrue(rootStatus.isEmpty, "The source fixture must be committed and clean")

        do {
            try await service.remove(scope: scope, directory: sourceDirectory, force: false)
            XCTFail("The server must reject root removal")
        } catch let error as BackendWorktreeError {
            guard case .failed = error else { throw error }
        }
        do {
            _ = try await service.create(.init(scope: scope, name: "invalid-\(UUID().uuidString)", destinationParent: "relative-parent"))
            XCTFail("Relative destination parents must be rejected before mutation")
        } catch { XCTAssertEqual(error as? BackendWorktreeError, .destinationParentRequired) }

        let name = "backend-live-\(UUID().uuidString.lowercased())"
        let expectedDirectory = destinationParent.appendingPathComponent(name).path
        // Register the exact name before POST in case its successful response is lost.
        addTeardownBlock { @MainActor in
            let inventory = try await service.inventory(scope: scope)
            for worktree in inventory where worktree.directory == expectedDirectory {
                guard worktree.directory.hasPrefix(destinationParent.path + "/backend-live-") else {
                    throw BackendFeatureLiveFailure("Refusing removal without exact registered fixture ownership")
                }
                try await service.remove(scope: scope, directory: worktree.directory, force: true)
            }
        }
        let created = try await service.create(.init(scope: scope, name: name, destinationParent: destinationParent.path))
        guard created.directory == expectedDirectory, created.worktree.isManaged else {
            throw BackendFeatureLiveFailure("Unexpected creation path; refusing unowned filesystem writes or removal")
        }
        XCTAssertEqual(created.readiness, .ready)
        let inventory = try await service.inventory(scope: scope)
        guard inventory.filter({ $0.directory == expectedDirectory }) == [created.worktree] else {
            throw BackendFeatureLiveFailure("Created checkout strategy did not normalize to gitCopy")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDirectory + "/.git"))
        let clean = try await client.listV2FileStatus(directory: expectedDirectory)
        XCTAssertTrue(clean.isEmpty, "Real git status must report a clean created checkout")

        let sessionID = try await ownedSession(client, directory: expectedDirectory)
        let messageID = OpenCodeIdentifier.message()
        let receipt = try await client.admitV2TextPrompt(
            sessionID: sessionID, messageID: messageID, text: "Retain this pending worktree input", resume: false
        )
        XCTAssertEqual(receipt.id, messageID)
        XCTAssertEqual(receipt.sessionID, sessionID)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let filename = "backend-live-untracked-\(token).txt"
        let writerTitle = "Backend owned writer \(token)"
        let output = BackendFeatureWriterOutput()
        addTeardownBlock { @MainActor in
            guard await output.needsCleanup else { return }
            for pty in try await client.listV2PTYs(directory: expectedDirectory) where pty.title == writerTitle {
                guard pty.cwd == expectedDirectory, pty.id.hasPrefix("pty_") else {
                    throw BackendFeatureLiveFailure("Refusing cleanup of a writer without exact title/cwd ownership")
                }
                try await client.deleteV2PTY(id: pty.id, directory: expectedDirectory)
            }
        }
        let writer = try await client.createV2PTY(title: writerTitle, directory: expectedDirectory)
        guard writer.title == writerTitle, writer.cwd == expectedDirectory, writer.id.hasPrefix("pty_") else {
            throw BackendFeatureLiveFailure("Writer PTY did not resolve the exact owned checkout")
        }
        let connection = OpenCodePTYConnection()
        let request = try client.v2PTYConnectRequest(id: writer.id, directory: expectedDirectory, cursor: 0)
        let socket = Task {
            try await connection.run(request: request, initialCursor: 0) { await output.receive($0) }
        }
        addTeardownBlock {
            socket.cancel()
            await connection.disconnect()
        }
        try await waitForWriter("WebSocket handshake") { await output.ready }
        // Write on the server, not through the simulator app's filesystem sandbox.
        // Compare filesystem identity because `pwd -P` spells /var as /private/var,
        // while Foundation can preserve the /var spelling for the same directory.
        let physicalDirectory = URL(fileURLWithPath: expectedDirectory).resolvingSymlinksInPath().path
        let gitMetadata = try URL(fileURLWithPath: expectedDirectory).appendingPathComponent(".git")
            .resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: expectedDirectory)
        let device = try XCTUnwrap(directoryAttributes[.systemNumber] as? NSNumber)
        let inode = try XCTUnwrap(directoryAttributes[.systemFileNumber] as? NSNumber)
        let directoryIdentity = "\(device.uint64Value):\(inode.uint64Value)"
        guard physicalDirectory.hasPrefix(parent.path + "/backend-live-"),
              !physicalDirectory.contains("'"), sameApprovedFixturePath(physicalDirectory, expected: URL(fileURLWithPath: expectedDirectory)),
              gitMetadata.isSymbolicLink == false,
              gitMetadata.isRegularFile == true || gitMetadata.isDirectory == true else {
            throw BackendFeatureLiveFailure("Unsafe writer cwd")
        }
        let script = "[ \"$(stat -f '%d:%i' .)\" = '\(directoryIdentity)' ] && [ ! -L .git ] && ( [ -f .git ] || [ -d .git ] ) && (umask 077; set -C; printf '%s\\n' 'Owned force-removal regression fixture' > '\(filename)') && printf '\\n%s%s\\n' 'BACKEND_WRITTEN_' '\(token)'\r"
        try await connection.send(Array(script.utf8))
        // The contiguous marker is absent from shell input, so terminal echo cannot pass.
        try await waitForWriter("executed file write") { await output.contains("BACKEND_WRITTEN_" + token) }
        let written = try await client.readV2FileContent(directory: expectedDirectory, path: filename)
        XCTAssertEqual(written.content, "Owned force-removal regression fixture\n")
        socket.cancel()
        await connection.disconnect()
        let beforeDelete = try await client.getV2PTY(id: writer.id, directory: expectedDirectory)
        guard beforeDelete.id == writer.id, beforeDelete.title == writerTitle, beforeDelete.cwd == expectedDirectory else {
            throw BackendFeatureLiveFailure("Writer ownership changed before shutdown")
        }
        try await client.deleteV2PTY(id: writer.id, directory: expectedDirectory)
        await output.didDeleteWriter()
        let remainingPTYs = try await client.listV2PTYs(directory: expectedDirectory)
        XCTAssertFalse(remainingPTYs.contains { $0.id == writer.id }, "Writer must be deleted before checkout removal")
        let dirty = try await client.listV2FileStatus(directory: expectedDirectory)
        XCTAssertEqual(dirty.map(\.path), [filename], "Only the exact owned untracked file may dirty this checkout")
        let raw = try await wire(client, "/api/worktree", method: "DELETE", body: [
            "projectID": .string(projectID), "directory": .string(expectedDirectory), "force": .bool(false)
        ])
        XCTAssertEqual(raw.status, 400)
        let failure = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: raw.data)
        XCTAssertEqual(failure["name"], .string("WorktreeError"))
        XCTAssertEqual(failure["data"]?.objectValue?["forceRequired"], .bool(true))
        do {
            try await service.remove(scope: scope, directory: expectedDirectory, force: false)
            XCTFail("Dirty removal must require explicit force")
        } catch let error as BackendWorktreeError {
            guard case .forceRequired = error else { throw error }
        }
        let retainedFile = try await client.readV2FileContent(directory: expectedDirectory, path: filename)
        XCTAssertEqual(retainedFile.content, written.content, "Non-force removal must preserve the owned file")
        let stillRegistered = try await service.inventory(scope: scope)
        XCTAssertTrue(stillRegistered.contains(created.worktree))
        try await service.remove(scope: scope, directory: expectedDirectory, force: true)
        let afterRemove = try await service.inventory(scope: scope)
        XCTAssertFalse(afterRemove.contains { $0.directory == expectedDirectory })
        XCTAssertTrue(afterRemove.contains { $0.directory == sourceDirectory && $0.kind == .root })
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedDirectory))
        // Worktree removal must not delete session history or implicitly resume its pending input.
        let retained = try await client.getV2Session(sessionID: sessionID)
        XCTAssertEqual(retained.id, sessionID)
        XCTAssertEqual(retained.directory, expectedDirectory)
        let pending = try await object(client, "/api/session/\(sessionID)/inbox")
        XCTAssertEqual(pending["data"]?.arrayValue?.map { $0.objectValue?["id"] }, [.string(messageID)])
    }

    private func context(timeout: TimeInterval = 8) async throws -> (OpenCodeAPIClient, String, URL) {
        continueAfterFailure = false
        let fixture = try OpenCodeV2LiveFixture.load()
        let base = OpenCodeV2LiveFixture.baseURL
        guard let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw BackendFeatureLiveFailure("Only http://127.0.0.1:14097 is permitted; never use 4096/4097")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: base, username: fixture.username,
                                                      password: fixture.password, apiPreference: .v2), session: session)
        let info = try await object(client, "/api/info")
        guard info["version"] == .string(OpenCodeV2LiveFixture.version) else {
            throw BackendFeatureLiveFailure("These tests require the manifest-pinned v2 contract")
        }
        let location = try await client.getV2Location()
        let directory = URL(fileURLWithPath: location.directory).resolvingSymlinksInPath().standardizedFileURL
        let root = directory.deletingLastPathComponent()
        let projectDirectory = URL(fileURLWithPath: location.project.directory).resolvingSymlinksInPath().standardizedFileURL
        guard directory.lastPathComponent == "workspace", projectDirectory == fixture.workspace,
              root == fixture.root, directory == fixture.workspace, fixture.owns(directory) else {
            throw BackendFeatureLiveFailure("Refusing a server outside the manifest-owned v2 fixture")
        }
        return (client, location.directory, root)
    }

    private func sameApprovedFixturePath(_ actual: String, expected: URL) -> Bool {
        guard let fixture = try? OpenCodeV2LiveFixture.load() else { return false }
        let actualURL = URL(fileURLWithPath: actual).resolvingSymlinksInPath().standardizedFileURL
        let expectedURL = expected.resolvingSymlinksInPath().standardizedFileURL
        return fixture.owns(expectedURL) && actualURL == expectedURL
    }

    private func waitForWriter(_ phase: String, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        throw BackendFeatureLiveFailure("Timed out waiting for owned writer \(phase)")
    }

    private func controlEvent(
        _ fixture: OpenCodeV2LiveFixture, marker: String, kind: String, after: Int = 0
    ) async throws -> [String: Any] {
        let response = try await control(fixture, path: "/control/wait", body: [
            "marker": marker, "kind": kind, "after": after, "timeout": 5,
        ])
        return try XCTUnwrap((response["events"] as? [[String: Any]])?.first)
    }

    private func waitForCommand(_ completion: BackendFeatureCommandCompletion) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if try await completion.isFinished() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw BackendFeatureLiveFailure("Timed out waiting for command HTTP 204 completion")
    }

    private func control(
        _ fixture: OpenCodeV2LiveFixture, path: String, body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard path.hasPrefix("/control/"), !path.contains("..") else {
            throw BackendFeatureLiveFailure("Invalid fixture control path")
        }
        var request = URLRequest(url: fixture.providerURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(fixture.controlToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 7
        configuration.timeoutIntervalForResource = 7
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        guard status == 200 else { throw BackendFeatureLiveFailure("Fixture control returned HTTP \(status)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func ownedSession(_ client: OpenCodeAPIClient, directory: String) async throws -> String {
        let id = "ses_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let title = "Backend Live \(id)"
        addTeardownBlock { @MainActor in
            do {
                let session = try await client.getV2Session(sessionID: id)
                guard session.id == id, session.title == title, session.directory == directory else {
                    throw BackendFeatureLiveFailure("Refusing cleanup without exact session ID/title/directory ownership")
                }
                try await client.deleteV2Session(sessionID: id)
            } catch OpenCodeAPIError.httpError(404, _) { }
        }
        let response = try await object(client, "/api/session", method: "POST", body: [
            "id": .string(id), "title": .string(title), "location": .object(["directory": .string(directory)])
        ])
        XCTAssertEqual(response["data"]?.objectValue?["id"], .string(id))
        return id
    }

    private func object(_ client: OpenCodeAPIClient, _ path: String, method: String = "GET",
                        body: [String: OpenCodeJSONValue]? = nil) async throws -> [String: OpenCodeJSONValue] {
        let response = try await wire(client, path, method: method, body: body)
        guard (200..<300).contains(response.status) else {
            throw BackendFeatureLiveFailure("\(method) \(path) returned HTTP \(response.status); missing routes are failures, not skips")
        }
        return response.data.isEmpty ? [:] : try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: response.data)
    }

    private func wire(_ client: OpenCodeAPIClient, _ path: String, method: String = "GET", query: [URLQueryItem] = [],
                      body: [String: OpenCodeJSONValue]? = nil) async throws -> (status: Int, data: Data) {
        var request = try client.makeRequest(path: path, method: method, queryItems: query)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await client.session.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse).statusCode, data)
    }
}

private struct BackendFeatureLiveFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private actor BackendFeatureCommandCompletion {
    private var finished = false
    private var failure: String?

    func finish(failure: String? = nil) {
        finished = true
        self.failure = failure
    }

    func isFinished() throws -> Bool {
        if let failure { throw BackendFeatureLiveFailure("Command transport failed: \(failure)") }
        return finished
    }
}

private actor BackendFeatureWriterOutput {
    private var connected = false
    private var hasCursor = false
    private var text = ""
    private(set) var needsCleanup = true
    var ready: Bool { connected && hasCursor }

    func didDeleteWriter() { needsCleanup = false }

    func receive(_ event: OpenCodePTYSocketEvent) {
        switch event {
        case .connected: connected = true
        case .closed: connected = false
        case .cursor: hasCursor = true
        case .output(let value, _): text += value
        }
    }

    func contains(_ marker: String) -> Bool { text.contains(marker) }
}
