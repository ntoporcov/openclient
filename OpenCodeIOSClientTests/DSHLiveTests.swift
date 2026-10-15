import XCTest
@testable import OpenClient

/// Explicit opt-in integration check against the development DSH host. Creates
/// one clearly labelled session and sends one bounded, text-only model request.
@MainActor
final class DSHLiveTests: XCTestCase {
    func testPasswordLoginHydratesAndReconnectsWithoutLaunchToken() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["DSH_ACCOUNT_URL"], let username = env["DSH_ACCOUNT_USER"], let password = env["DSH_ACCOUNT_PASSWORD"] else {
            throw XCTSkip("Set DSH_ACCOUNT_URL, DSH_ACCOUNT_USER and DSH_ACCOUNT_PASSWORD for password integration")
        }
        let credential = try DSHCredential(serverURL: server, username: username, password: password)
        for _ in 0..<2 {
            let connection = try await DSHBackendFactory(configuration: credential.configuration).connect()
            defer { connection.close() }
            let projects = try await connection.projects.projectsSnapshot()
            XCTAssertFalse(projects.projects.isEmpty)
            let search = try await connection.projectLifecycle?.searchDirectories(query: "", root: "/")
            XCTAssertFalse(search?.requiresDSHBrowseConfiguration ?? true)
        }
        let wrong = try DSHCredential(serverURL: server, username: username, password: UUID().uuidString)
        do {
            let connection = try await DSHBackendFactory(configuration: wrong.configuration).connect()
            connection.close()
            XCTFail("Invalid credentials must fail")
        } catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
    }

    func testNativeBackendStreamsAndReopensCanonicalHistory() async throws {
        guard let text = ProcessInfo.processInfo.environment["DSH_SMOKE_URL"], let url = URL(string: text) else {
            throw XCTSkip("Set DSH_SMOKE_URL to opt into the DSH integration check")
        }
        let factory = DSHBackendFactory(configuration: try DSHConfiguration(url: url))
        let connection = try await factory.connect()
        defer { connection.close() }
        let projects = try await connection.projects.projectsSnapshot()
        let project = try XCTUnwrap(projects.projects.first)
        let scope = BackendScope(projectID: project.id, directory: project.worktree)
        let catalog = try await connection.models.modelCatalog(scope: scope)
        let provider = try XCTUnwrap(catalog.providers.first { $0.id == "openai-codex" })
        let modelID = try XCTUnwrap(catalog.defaults[provider.id] ?? provider.models.keys.sorted().first)
        let session = try await connection.sessions.createSession(.init(
            title: "OpenClient native DSH smoke test", scope: scope,
            model: .init(providerID: provider.id, modelID: modelID)))
        let messageID = "native-smoke-" + UUID().uuidString
        let canonicalUser = expectation(description: "Canonical user keeps submitted identity")
        let streamedText = expectation(description: "Assistant text arrives through the native mux")
        let settled = expectation(description: "Assistant durably completes")
        var observedUser = false
        var observedText = false
        var observedCompletion = false
        var sawLivePartial = false
        let stream = connection.eventStream()
        let observer = Task {
            for await event in stream {
                guard case let .mutation(_, mutation) = event else { continue }
                switch mutation {
                case let .messageUpdated(message) where message.sessionID == session.id:
                    if message.id == messageID, !observedUser { observedUser = true; canonicalUser.fulfill() }
                    if message.role == "assistant" {
                        if message.time?.completed == nil { sawLivePartial = true }
                        else if !observedCompletion { observedCompletion = true; settled.fulfill() }
                    }
                case let .messagePartUpdated(part) where part.sessionID == session.id && part.type == "text":
                    if part.messageID != messageID, part.text?.isEmpty == false, !observedText {
                        observedText = true
                        streamedText.fulfill()
                    }
                default: break
                }
            }
        }
        defer { observer.cancel() }
        let admission = try await connection.chat.submit(.init(sessionID: session.id, messageID: messageID,
            text: "Reply with exactly OK. Do not use tools.", scope: scope,
            model: .init(providerID: provider.id, modelID: modelID)))
        guard case .accepted = admission else { return XCTFail("DSH did not acknowledge the prompt") }
        await fulfillment(of: [canonicalUser, streamedText, settled], timeout: 90)
        XCTAssertTrue(sawLivePartial, "Streaming must be visible before durable settlement")
        let first = try await connection.chat.transcript(sessionID: session.id, scope: scope, cursor: nil, limit: 100)
        XCTAssertEqual(first.messages.filter { $0.info.role == "user" }.map(\.id), [messageID])
        XCTAssertEqual(first.messages.filter { $0.info.role == "assistant" }.count, 1)

        let reopened = try await factory.connect()
        defer { reopened.close() }
        let restored = try await reopened.chat.transcript(sessionID: session.id, scope: scope, cursor: nil, limit: 100)
        XCTAssertEqual(restored.messages, first.messages, "Reconnect must preserve identities and canonical content")
    }
}
