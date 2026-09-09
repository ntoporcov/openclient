import Foundation
import XCTest
@testable import OpenClient

/// Opt-in integration tests. Never target the persistent development servers.
@MainActor
final class BackendFeatureLiveTests: XCTestCase {
    func testNativeCommandEncodingReturnsOwnedPendingReceiptWithoutProviderTurn() async throws {
        let (client, directory, _) = try await context()
        let sessionID = try await ownedSession(client, directory: directory)
        var commands = try await client.listV2Commands(directory: directory)
        // This preview activates built-in catalogs asynchronously on first location access.
        for _ in 0..<40 where !commands.contains(where: { $0.name == "review" }) {
            try await Task.sleep(for: .milliseconds(250))
            commands = try await client.listV2Commands(directory: directory)
        }
        let command = try XCTUnwrap(commands.first { $0.name == "review" }, "Expected the next-17155 built-in review command")
        let messageID = OpenCodeIdentifier.message()
        // Exercise the production encoder, not a parallel hand-written command payload.
        let receipt = try await client.admitV2Command(
            sessionID: sessionID, messageID: messageID, command: command.name, arguments: "", resume: false
        )
        XCTAssertEqual(receipt.id, messageID)
        XCTAssertEqual(receipt.sessionID, sessionID)
        XCTAssertGreaterThan(receipt.timeCreated, 0)
        let pending = try await object(client, "/api/session/\(sessionID)/pending")
        let inputs = try XCTUnwrap(pending["data"]?.arrayValue)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.objectValue?["id"], .string(messageID))
        XCTAssertEqual(inputs.first?.objectValue?["sessionID"], .string(sessionID))
        XCTAssertEqual(inputs.first?.objectValue?["type"], .string("user"))
        let transcript = try await object(client, "/api/session/\(sessionID)/message")
        XCTAssertEqual(transcript["data"]?.arrayValue, [], "Paused command admission must not start a provider turn")
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
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: env["OPENCODE_V2_TEST_GIT_ROOT"] ?? root.appendingPathComponent("git-fixture").path)
            .resolvingSymlinksInPath().standardizedFileURL
        let parent = URL(fileURLWithPath: env["OPENCODE_V2_TEST_WORKTREE_DESTINATION_PARENT"] ?? root.appendingPathComponent("copies").path)
            .resolvingSymlinksInPath().standardizedFileURL
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
                guard worktree.isManaged, worktree.directory.hasPrefix(destinationParent.path + "/backend-live-") else {
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
        XCTAssertEqual(inventory.filter { $0.directory == expectedDirectory }, [created.worktree])
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedDirectory + "/.git"))
        let clean = try await client.listV2FileStatus(directory: expectedDirectory)
        XCTAssertTrue(clean.isEmpty, "Real git status must report a clean created checkout")

        let sessionID = try await ownedSession(client, directory: expectedDirectory)
        let commands = try await client.listV2Commands(directory: expectedDirectory)
        let command = try XCTUnwrap(commands.first { $0.name == "review" })
        let messageID = OpenCodeIdentifier.message()
        let receipt = try await client.admitV2Command(sessionID: sessionID, messageID: messageID,
                                                     command: command.name, arguments: "", resume: false)
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
            _ = await socket.result
        }
        try await waitForWriter("WebSocket handshake") { await output.ready }
        // Write on the server, not through the simulator app's filesystem sandbox.
        // Require the exact physical cwd and a linked checkout; noclobber prevents overwrites.
        let approved = "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass2-VwCj6l/"
        let physicalDirectory = expectedDirectory.hasPrefix(approved) ? "/private" + expectedDirectory : expectedDirectory
        guard physicalDirectory.hasPrefix("/private" + approved + "copies/backend-live-"),
              !physicalDirectory.contains("'"), sameApprovedFixturePath(physicalDirectory, expected: URL(fileURLWithPath: expectedDirectory)) else {
            throw BackendFeatureLiveFailure("Unsafe writer cwd")
        }
        let script = "[ \"$(pwd -P)\" = '\(physicalDirectory)' ] && [ -f .git ] && [ ! -L .git ] && (umask 077; set -C; printf '%s\\n' 'Owned force-removal regression fixture' > '\(filename)') && printf '\\n%s%s\\n' 'BACKEND_WRITTEN_' '\(token)'\r"
        try await connection.send(Array(script.utf8))
        // The contiguous marker is absent from shell input, so terminal echo cannot pass.
        try await waitForWriter("executed file write") { await output.contains("BACKEND_WRITTEN_" + token) }
        let written = try await client.readV2FileContent(directory: expectedDirectory, path: filename)
        XCTAssertEqual(written.content, "Owned force-removal regression fixture\n")
        socket.cancel()
        await connection.disconnect()
        _ = await socket.result
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
        let query = client.v2LocationQueryItems(directory: scope.directory)
        let raw = try await wire(client, "/experimental/project/\(projectID)/copy", method: "DELETE", query: query,
                                 body: ["directory": .string(expectedDirectory), "force": .bool(false)])
        XCTAssertEqual(raw.status, 400)
        let failure = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: raw.data)
        XCTAssertEqual(failure["name"], .string("ProjectCopyError"))
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
        let pending = try await object(client, "/api/session/\(sessionID)/pending")
        XCTAssertEqual(pending["data"]?.arrayValue?.map { $0.objectValue?["id"] }, [.string(messageID)])
    }

    private func context() async throws -> (OpenCodeAPIClient, String, URL) {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let base = env["OPENCODE_V2_TEST_BASE_URL"], !base.isEmpty,
              let username = env["OPENCODE_V2_TEST_USERNAME"], !username.isEmpty,
              let password = env["OPENCODE_V2_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set OPENCODE_V2_TEST_BASE_URL/USERNAME/PASSWORD to opt into isolated live tests")
        }
        guard let url = URL(string: base), url.scheme == "http", url.host == "127.0.0.1", url.port == 14097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw BackendFeatureLiveFailure("Only http://127.0.0.1:14097 is permitted; never use 4096/4097")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: base, username: username, password: password, apiPreference: .v2), session: session)
        let health = try await object(client, "/api/health")
        guard health["healthy"] == .bool(true), health["version"] == .string("0.0.0-next-17155") else {
            throw BackendFeatureLiveFailure("These tests require the verified next-17155 contract")
        }
        let location = try await client.getV2Location()
        let directory = URL(fileURLWithPath: location.directory).resolvingSymlinksInPath().standardizedFileURL
        let root = directory.deletingLastPathComponent()
        let approved = URL(fileURLWithPath: "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode")
            .resolvingSymlinksInPath().standardizedFileURL
        guard location.project.id == "global", directory.lastPathComponent == "workspace",
              root.lastPathComponent == "pass2-VwCj6l", root.deletingLastPathComponent() == approved else {
            throw BackendFeatureLiveFailure("Refusing a server outside the approved disposable pass2 fixture")
        }
        return (client, location.directory, root)
    }

    private func sameApprovedFixturePath(_ actual: String, expected: URL) -> Bool {
        // Simulator Foundation and the host Git process can spell this one approved root differently.
        let approved = "/var/folders/v1/gzrsgbkd24b3l3dslnjtmv700000gq/T/opencode/pass2-VwCj6l/"
        func normalize(_ path: String) -> String {
            path.hasPrefix("/private" + approved) ? String(path.dropFirst("/private".count)) : path
        }
        let target = normalize(expected.path)
        return target.hasPrefix(approved) && normalize(actual) == target
    }

    private func waitForWriter(_ phase: String, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < deadline
        throw BackendFeatureLiveFailure("Timed out waiting for owned writer \(phase)")
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
