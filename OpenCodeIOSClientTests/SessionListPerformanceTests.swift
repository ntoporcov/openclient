import Combine
import Foundation
import XCTest
@testable import OpenClient

@MainActor
private struct SessionListPerformanceBackend: BackendFactory {
    func connect() async throws -> BackendConnection {
        XCTFail("Session list snapshot tests must not connect to a backend")
        throw BackendError.disconnected
    }
}

@MainActor
final class SessionListPerformanceTests: XCTestCase {
    private struct Fixture {
        let model: AppViewModel
        let facade: SessionListFacade
        let owner: DirectoryStore
        let sessions: [OpenCodeSession]
    }

    func testMeasureRepeatedUnchangedSnapshotsWithLongTranscripts() throws {
        let fixture = try makeFixture(historyCount: 1_000, latestTextRepeats: 200)
        let expected = fixture.facade.snapshot
        var latest = expected
        // Warm the cache, then measure actual snapshot construction, not queued notifications.
        XCTAssertEqual(fixture.facade.makeSnapshot(), expected)
        measure {
            for _ in 0..<30 {
                latest = fixture.facade.makeSnapshot()
            }
        }
        XCTAssertEqual(latest, expected)
        for session in fixture.sessions {
            XCTAssertEqual(fixture.owner.syncStore.messageCount(forSessionID: session.id), 1_002)
            XCTAssertEqual(row(in: latest, id: session.id)?.latestAssistantText,
                opencodePreviewText(String(repeating: "Answer **\(session.id)**.\n", count: 200), limit: nil))
        }
    }

    func testCanonicalPreviewCacheInvalidatesForBodyAndCompletionDateOverStoredPreview() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        let assistantID = "\(id)-assistant"
        let stored = try XCTUnwrap(fixture.model.sessionPreviews[id])
        let initial = SessionPreview(text: "Answer \(id).", date: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(row(in: fixture.facade.snapshot, id: id)?.preview, initial)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, initial)
        XCTAssertNotEqual(initial, stored)

        fixture.owner.syncState.partsByMessageID[assistantID]?[0].text = "Updated **answer**"
        let updated = SessionPreview(text: "Updated answer", date: initial.date)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, updated)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, updated)

        fixture.model.appCustomizationStore.setSessionCardStyle(.simple)
        fixture.owner.selectedSession = fixture.sessions[0]
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, updated)
        let index = try XCTUnwrap(fixture.owner.syncState.messagesBySessionID[id]?.firstIndex { $0.id == assistantID })
        fixture.owner.syncState.messagesBySessionID[id]?[index] = .init(
            id: assistantID, role: "assistant", sessionID: id,
            time: .init(created: 1_000, completed: 2_000), agent: nil, model: nil)
        let completed = SessionPreview(text: updated.text, date: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, completed)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, completed)
        XCTAssertEqual(fixture.model.sessionPreviews[id], stored, "Canonical preview priority must not depend on overwriting the stored preview")
    }

    func testLivePreviewChangesRemovalAndReasoningFallbackStaySessionLocal() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        let assistantID = "\(id)-assistant"
        let userID = "\(id)-user"
        let otherID = fixture.sessions[1].id
        let other = row(in: fixture.facade.snapshot, id: otherID)

        fixture.owner.syncState.partsByMessageID[assistantID]?[0].text = "Updated **answer**"
        fixture.owner.syncState.partsByMessageID[userID]?[0].text = "Updated **prompt**"
        var snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.latestAssistantText, "Updated answer")
        XCTAssertEqual(row(in: snapshot, id: id)?.latestUserText, "Updated prompt")
        XCTAssertEqual(row(in: snapshot, id: otherID), other)

        let reasoning = message(sessionID: id, id: assistantID, text: "Thinking **carefully**", type: "reasoning")
        fixture.owner.syncState.partsByMessageID[assistantID] = reasoning.parts
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Thinking carefully")

        // An empty text string still suppresses reasoning on this message, as before.
        fixture.owner.syncState.partsByMessageID[assistantID] = reasoning.parts
            + message(sessionID: id, id: assistantID, text: " \n ").parts
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Stored \(id)")

        let newer = message(sessionID: id, id: "newer", role: "ASSISTANT", text: "Newest")
        fixture.owner.syncState.messagesBySessionID[id]?.append(newer.info)
        fixture.owner.syncState.partsByMessageID[newer.id] = newer.parts
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Newest")
        fixture.owner.syncState.messagesBySessionID[id]?.removeAll { $0.id == newer.id }
        fixture.owner.syncState.partsByMessageID[assistantID] = reasoning.parts
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Thinking carefully")

        fixture.owner.syncState.partsByMessageID[assistantID] = nil
        fixture.owner.syncState.messagesBySessionID[id]?.removeAll { $0.id == userID }
        snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.latestAssistantText, "Stored \(id)")
        XCTAssertNil(row(in: snapshot, id: id)?.latestUserText)
        XCTAssertEqual(row(in: snapshot, id: otherID), other)
    }

    func testWrongSessionMessagesAreExcludedFromTextToolsAndFallbackPreview() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        let tool = try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: Data("""
            {"info":{"id":"tool-message","sessionID":"\(id)","role":"assistant"},
             "parts":[{"type":"tool","tool":"bash","state":{"status":"running","title":"Run tests","input":{"command":"test"}}}]}
            """.utf8))
        fixture.owner.syncState.messagesBySessionID[id]?.append(tool.info)
        fixture.owner.syncState.partsByMessageID[tool.id] = tool.parts
        let expectedTool = ActivityFacade.ToolSnapshot(id: "tool-message:bash", tool: "bash", title: "Run tests", detail: "test")
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.runningTools, [expectedTool])

        for role in ["user", "assistant"] {
            let wrong = message(sessionID: "wrong-session", id: "wrong-\(role)", role: role, text: "Must not leak")
            fixture.owner.syncState.messagesBySessionID[id]?.append(wrong.info)
            fixture.owner.syncState.partsByMessageID[wrong.id] = wrong.parts
        }
        var snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.latestUserText, "Prompt \(id).")
        XCTAssertEqual(row(in: snapshot, id: id)?.latestAssistantText, "Answer \(id).")
        XCTAssertEqual(row(in: snapshot, id: id)?.runningTools, [expectedTool])
        XCTAssertEqual(row(in: snapshot, id: id)?.preview?.text, "Answer \(id).",
            "Activity rows prefer canonical messages over stored previews")

        fixture.model.sessionPreviews[id] = nil
        let validMessages = fixture.owner.syncState.messageEnvelopes(forSessionID: id).filter { $0.info.sessionID == id }
        snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.preview, fixture.model.buildSessionPreview(from: validMessages))
        fixture.model.appCustomizationStore.setSessionCardStyle(.simple)
        snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.preview, fixture.model.buildSessionPreview(from: validMessages))
        XCTAssertNil(row(in: snapshot, id: id)?.latestAssistantText)
        XCTAssertEqual(row(in: snapshot, id: id)?.runningTools, [])

        fixture.owner.syncState.messagesBySessionID[id]?.removeAll { $0.sessionID == id }
        XCTAssertNil(row(in: fixture.facade.makeSnapshot(), id: id)?.preview)
        fixture.model.appCustomizationStore.setSessionCardStyle(.activity)
        let empty = row(in: fixture.facade.makeSnapshot(), id: id)
        XCTAssertNil(empty?.latestUserText)
        XCTAssertNil(empty?.latestAssistantText)
        XCTAssertEqual(empty?.runningTools, [])
    }

    func testSelectedSimpleRowPrefersCanonicalPreviewAndFallsBackOnlyWithoutMessages() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        let stored = fixture.model.sessionPreviews[id]
        fixture.model.appCustomizationStore.setSessionCardStyle(.simple)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, stored)

        fixture.owner.selectedSession = fixture.sessions[0]
        var snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.preview?.text, "Answer \(id).")
        XCTAssertNil(row(in: snapshot, id: id)?.latestAssistantText)
        XCTAssertEqual(row(in: snapshot, id: fixture.sessions[1].id)?.preview,
            fixture.model.sessionPreviews[fixture.sessions[1].id])

        fixture.owner.syncState.partsByMessageID["\(id)-assistant"] = []
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview?.text, "Prompt \(id).")
        fixture.owner.syncState.partsByMessageID["\(id)-user"] = []
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview,
            fixture.model.buildSessionPreview(from: []),
            "Canonical messages without text must not resurrect a stale stored preview")

        fixture.owner.syncState.messagesBySessionID[id] = []
        snapshot = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: snapshot, id: id)?.preview, stored)
        fixture.model.appCustomizationStore.setSessionCardStyle(.activity)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.preview, stored)
    }

    func testFormCacheInvalidatesForTreeChangesAndDoesNotCachePermissionsOrQuestions() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        let otherID = fixture.sessions[1].id
        var child = session(id: "child", parentID: id)
        fixture.owner.sessions.append(child)
        let rootForm = BackendForm(id: "root-form", sessionID: id, title: "Confirm", fields: [])
        let childForm = BackendForm(id: "child-form", sessionID: child.id, title: "Child", fields: [])
        fixture.owner.sessionFormStore.upsert(rootForm)
        fixture.owner.sessionFormStore.upsert(childForm)
        fixture.owner.sessionFormStore.upsert(.init(id: "global-form", sessionID: "global", title: "Global", fields: []))
        fixture.owner.syncState.questionsBySessionID[id] = [
            .init(id: rootForm.id, sessionID: id, questions: [], tool: nil),
            .init(id: "question", sessionID: id, questions: [], tool: nil),
        ]
        // Descendant forms count, but descendant compatibility questions/permissions do not.
        fixture.owner.syncState.questionsBySessionID[child.id] = [
            .init(id: "child-question", sessionID: child.id, questions: [], tool: nil),
        ]
        var result = row(in: fixture.facade.makeSnapshot(), id: id)
        XCTAssertEqual(result?.pendingInteractionCount, 3)
        XCTAssertEqual(result?.hasPermissionRequest, true)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id), result)

        fixture.owner.syncState.permissionsBySessionID[id] = [permission(sessionID: id)]
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.pendingInteractionCount, 4)
        fixture.owner.syncState.permissionsBySessionID[id] = []
        fixture.owner.syncState.questionsBySessionID[id] = []
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.pendingInteractionCount, 2)

        child = session(id: child.id, parentID: otherID)
        fixture.owner.sessions = fixture.owner.sessions.filter { $0.id != child.id } + [child]
        let reparented = fixture.facade.makeSnapshot()
        XCTAssertEqual(row(in: reparented, id: id)?.pendingInteractionCount, 1)
        XCTAssertEqual(row(in: reparented, id: otherID)?.pendingInteractionCount, 1)
        fixture.owner.sessionFormStore.settle(rootForm.key)
        fixture.owner.syncState.permissionsBySessionID[child.id] = [permission(sessionID: child.id)]
        result = row(in: fixture.facade.makeSnapshot(), id: id)
        XCTAssertEqual(result?.pendingInteractionCount, 0)
        XCTAssertEqual(result?.activityNeedsInput, false)
        XCTAssertEqual(result?.hasPermissionRequest, false)
        fixture.owner.sessionFormStore.settle(childForm.key)
        result = row(in: fixture.facade.makeSnapshot(), id: otherID)
        XCTAssertEqual(result?.pendingInteractionCount, 0)
        XCTAssertEqual(result?.hasPermissionRequest, true, "Child permissions still badge the tree root")
        fixture.owner.syncState.permissionsBySessionID[child.id] = []
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: otherID)?.hasPermissionRequest, false)
    }

    func testScopeChangesAndRegistryResetDoNotReuseAnotherOwnersResults() throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        fixture.owner.sessionFormStore.upsert(.init(id: "form", sessionID: id, title: "Old form", fields: []))
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.pendingInteractionCount, 1)
        let nextOwner = fixture.model.directoryStoreRegistry.activate("/session-list-other")
        nextOwner.sessions = [session(id: id, directory: "/session-list-other")]
        nextOwner.applyV2Messages([
            message(sessionID: id, id: "\(id)-assistant", text: "Other scope"),
        ], forSessionID: id)
        var result = row(in: fixture.facade.makeSnapshot(), id: id)
        XCTAssertEqual(result?.latestAssistantText, "Other scope")
        XCTAssertNil(result?.latestUserText)
        XCTAssertEqual(result?.pendingInteractionCount, 0)

        fixture.owner.syncState.partsByMessageID["\(id)-assistant"]?[0].text = "Old owner changed"
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Other scope")
        fixture.model.directoryStoreRegistry.activate(nil)
        XCTAssertEqual(row(in: fixture.facade.makeSnapshot(), id: id)?.latestAssistantText, "Old owner changed")

        fixture.model.directoryStoreRegistry.reset()
        XCTAssertTrue(fixture.facade.makeSnapshot().unpinnedRows.isEmpty)
        let replacement = fixture.model.directoryStore
        replacement.sessions = [session(id: id)]
        replacement.applyV2Messages([message(sessionID: id, id: "\(id)-assistant", text: "New lifetime")], forSessionID: id)
        result = row(in: fixture.facade.makeSnapshot(), id: id)
        XCTAssertEqual(result?.latestAssistantText, "New lifetime")
        XCTAssertEqual(result?.pendingInteractionCount, 0)
    }

    func testStreamingThrottlesAndDeliversFinalPreviewAndNativeFormChanges() async throws {
        let fixture = try makeFixture()
        let id = fixture.sessions[0].id
        var publications = 0
        let observation = fixture.facade.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let start = ContinuousClock.now
        for token in 0..<30 {
            fixture.owner.syncState.partsByMessageID["\(id)-assistant"]?[0].text = "Token \(token)"
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.owner.syncState.partsByMessageID["\(id)-assistant"]?[0].text = "Final token"
        await waitForSnapshot(fixture.facade) { self.row(in: $0, id: id)?.latestAssistantText == "Final token" }
        XCTAssertGreaterThanOrEqual(publications, 2, "Continuous updates must not debounce until idle")
        XCTAssertLessThanOrEqual(publications, Int(start.duration(to: .now) / .milliseconds(200)) + 2)

        let form = BackendForm(id: "native-form", sessionID: id, title: "Confirm", fields: [])
        fixture.owner.sessionFormStore.upsert(form)
        await waitForSnapshot(fixture.facade) { self.row(in: $0, id: id)?.pendingInteractionCount == 1 }
        fixture.owner.sessionFormStore.settle(form.key)
        await waitForSnapshot(fixture.facade) { self.row(in: $0, id: id)?.pendingInteractionCount == 0 }
    }

    func testDerivedCreateSessionPropertiesStillForwardObservation() async throws {
        let fixture = try makeFixture()
        try await Task.sleep(for: .milliseconds(100))
        let expected = fixture.facade.snapshot
        let changed = expectation(description: "Derived form state notifies views")
        let observation = fixture.facade.objectWillChange.prefix(1).sink { changed.fulfill() }
        fixture.model.draftTitle = "New draft title"
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(fixture.facade.createSessionSnapshot.title, "New draft title")
        XCTAssertEqual(fixture.facade.makeSnapshot(), expected, "Derived state can change without changing the list snapshot")
        withExtendedLifetime(observation) {}
    }

    private func makeFixture(historyCount: Int = 0, latestTextRepeats: Int = 1) throws -> Fixture {
        let model = AppViewModel(backendFactory: SessionListPerformanceBackend())
        model.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let previousStyle = model.appCustomizationStore.sessionCardStyle
        model.appCustomizationStore.setSessionCardStyle(.activity)
        addTeardownBlock { @MainActor in model.appCustomizationStore.setSessionCardStyle(previousStyle) }
        let sessions = (0..<4).map { session(id: "session-list-\($0)") }
        model.allSessions = sessions
        let owner = model.directoryStore
        let coldText = String(repeating: "Cold history with **markdown**.\n", count: 100)
        for session in sessions {
            let id = session.id
            let history = (0..<historyCount).map {
                message(sessionID: id, id: "\(id)-cold-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: coldText)
            }
            owner.applyV2Messages(history + [
                message(sessionID: id, id: "\(id)-user", role: "user", text: String(repeating: "Prompt **\(id)**.\n", count: latestTextRepeats)),
                message(sessionID: id, id: "\(id)-assistant", text: String(repeating: "Answer **\(id)**.\n", count: latestTextRepeats)),
            ], forSessionID: id)
            model.sessionPreviews[id] = SessionPreview(text: "Stored \(id)", date: nil)
        }
        let facade = SessionListFacade(viewModel: model)
        XCTAssertEqual(facade.snapshot.unpinnedRows.count, 4)
        XCTAssertNil(model.backendConnection)
        return Fixture(model: model, facade: facade, owner: owner, sessions: sessions)
    }

    private func session(id: String, directory: String? = nil, parentID: String? = nil) -> OpenCodeSession {
        .init(id: id, title: id, workspaceID: nil, directory: directory, projectID: "global", parentID: parentID)
    }

    private func message(sessionID: String, id: String, role: String = "assistant", text: String,
        type: String = "text") -> OpenCodeMessageEnvelope {
        .init(info: .init(id: id, role: role, sessionID: sessionID, time: .init(created: 1_000), agent: nil, model: nil),
            parts: [.init(id: "\(id)-\(type)", messageID: id, sessionID: sessionID, type: type,
                mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text)])
    }

    private func permission(sessionID: String) -> OpenCodePermission {
        .init(id: "permission-\(sessionID)", sessionID: sessionID, permission: "bash", patterns: ["test"],
            always: nil, metadata: nil, tool: nil)
    }

    private func row(in snapshot: SessionListFacade.Snapshot, id: String) -> SessionListFacade.RowSnapshot? {
        (snapshot.pinnedRows + snapshot.unpinnedRows + snapshot.workspaceSections.flatMap(\.rows)).first { $0.id == id }
    }

    private func waitForSnapshot(_ facade: SessionListFacade,
        matching predicate: @escaping (SessionListFacade.Snapshot) -> Bool) async {
        let delivered = expectation(description: "Session list snapshot updated")
        let observation = facade.$snapshot.filter(predicate).prefix(1).sink { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        withExtendedLifetime(observation) {}
    }
}
