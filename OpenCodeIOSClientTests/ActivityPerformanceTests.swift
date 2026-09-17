import Combine
import Foundation
import XCTest
@testable import OpenClient

@MainActor
private struct ActivityPerformanceBackend: BackendFactory {
    func connect() async throws -> BackendConnection {
        XCTFail("Activity snapshot tests must not connect to a backend")
        throw BackendError.disconnected
    }
}

@MainActor
final class ActivityPerformanceTests: XCTestCase {
    private struct Fixture {
        let model: AppViewModel
        let facade: ActivityFacade
        let sessions: [OpenCodeSession]
        let owners: [DirectoryStore]
    }

    func testFourStreamingSessionsCoalescePublicationsWithoutLosingTokens() async throws {
        let fixture = try makeFixture()
        defer { fixture.facade.resetForConnectionChange() }
        var publications: [(time: ContinuousClock.Instant, snapshot: ActivityFacade.Snapshot)] = []
        let observation = fixture.facade.$snapshot.dropFirst().sink {
            publications.append((.now, $0))
        }
        defer { observation.cancel() }
        let start = ContinuousClock.now
        var expected = fixture.sessions.map { "Answer \($0.id)" }

        for token in 0..<64 {
            for index in fixture.sessions.indices {
                let session = fixture.sessions[index]
                let delta = " s\(index)t\(token)"
                expected[index] += delta
                let owner = fixture.owners[index]
                owner.syncState.partsByMessageID["\(session.id)-assistant"]?[0].text?.append(delta)
                XCTAssertEqual(owner.syncState.partsByMessageID["\(session.id)-assistant"]?.first?.text,
                    expected[index], "Presentation throttling must not throttle canonical writes")
            }
            try await Task.sleep(for: .milliseconds(12))
        }
        let streamEnded = ContinuousClock.now
        // One last burst with no subsequent notification must still receive trailing delivery.
        for index in fixture.sessions.indices {
            let delta = " final\(index)"
            expected[index] += delta
            fixture.owners[index].syncState.partsByMessageID["\(fixture.sessions[index].id)-assistant"]?[0].text?.append(delta)
        }
        await waitForSnapshot(fixture.facade, description: "All four final previews arrive") { snapshot in
            fixture.sessions.indices.allSatisfy {
                self.row(in: snapshot, id: fixture.sessions[$0].id)?.latestAssistantText == expected[$0]
            }
        }

        let elapsed = start.duration(to: .now)
        XCTAssertGreaterThanOrEqual(publications.filter { $0.time < streamEnded }.count, 2,
            "Continuous input must publish progress, not debounce until the stream ends")
        XCTAssertLessThanOrEqual(publications.count, Int(elapsed / .milliseconds(200)) + 2,
            "Four sessions should share a bounded publication cadence")
        for (previous, next) in zip(publications, publications.dropFirst()) {
            XCTAssertGreaterThanOrEqual(previous.time.duration(to: next.time), .milliseconds(150),
                "Text-only snapshots must not publish once per 50ms metadata check")
        }
        for index in fixture.sessions.indices {
            let session = fixture.sessions[index]
            XCTAssertEqual(fixture.owners[index].syncState.messageEnvelopes(forSessionID: session.id)
                .last?.parts.first?.text, expected[index])
            XCTAssertEqual(row(in: fixture.facade.snapshot, id: session.id)?.latestAssistantText, expected[index])
            var previousText = "Answer \(session.id)"
            for publication in publications {
                let published = try XCTUnwrap(row(in: publication.snapshot, id: session.id))
                let text = try XCTUnwrap(published.latestAssistantText)
                XCTAssertTrue(text.hasPrefix(previousText), "Published text must not roll back or cross session boundaries")
                XCTAssertTrue(expected[index].hasPrefix(text))
                XCTAssertEqual(published.latestUserText, "Prompt \(session.id)")
                previousText = text
            }
        }
    }

    func testPermissionNativeFormAndStatusBypassAPendingTextRefresh() async throws {
        for change in ["permission", "native-form", "status"] {
            let fixture = try makeFixture()
            defer { fixture.facade.resetForConnectionChange() }
            let target = fixture.sessions[0]
            let owner = fixture.owners[0]
            var publications: [(time: ContinuousClock.Instant, snapshot: ActivityFacade.Snapshot)] = []
            let observation = fixture.facade.$snapshot.dropFirst().sink {
                publications.append((.now, $0))
            }
            defer { observation.cancel() }

            // A no-op preference assignment refreshes synchronously without writing preferences.
            fixture.facade.setShowsLastUserMessage(fixture.facade.showsLastUserMessage)
            let refreshedAt = ContinuousClock.now
            for index in fixture.sessions.indices {
                let id = fixture.sessions[index].id
                fixture.owners[index].syncState.partsByMessageID["\(id)-assistant"]?[0].text = "Pending \(id)"
            }
            try await Task.sleep(for: .milliseconds(75))
            guard refreshedAt.duration(to: .now) < .milliseconds(110) else {
                throw XCTSkip("Executor stalled before the metadata event could enter the text-throttle window")
            }
            XCTAssertTrue(publications.isEmpty, "The text refresh should still be pending")
            switch change {
            case "permission":
                owner.syncState.permissionsBySessionID[target.id] = [permission(sessionID: target.id)]
            case "native-form":
                // Exercise the native form owner's notification, not a question compatibility write.
                owner.sessionFormStore.upsert(.init(id: "native", sessionID: target.id, title: "Confirm", fields: []))
            default:
                owner.applySessionStatus("idle", forSessionID: target.id)
            }
            await waitForSnapshot(fixture.facade, description: "\(change) takes priority over text") { snapshot in
                guard let row = self.row(in: snapshot, id: target.id) else { return false }
                return change == "status" ? !row.isWorking : row.pendingInteractionCount == 1
            }
            let publication = try XCTUnwrap(publications.first)
            // Normally ~125ms from refresh; allow 65ms of scheduling slack, but not the 200ms text deadline.
            XCTAssertLessThan(refreshedAt.duration(to: publication.time), .milliseconds(190),
                "\(change) must bypass the text-only throttle")
            let changedRow = try XCTUnwrap(row(in: publication.snapshot, id: target.id))
            XCTAssertEqual(changedRow.needsInput, change != "status")
            XCTAssertEqual(changedRow.pendingInteractionCount, change == "status" ? 0 : 1)
            for session in fixture.sessions {
                XCTAssertEqual(row(in: publication.snapshot, id: session.id)?.latestAssistantText, "Pending \(session.id)")
            }

            // Clearing metadata must invalidate cached counts and cancel any stale trailing publication.
            owner.clearPermissions()
            owner.applySessionFormSettled(.init(sessionID: target.id, formID: "native"))
            owner.applySessionStatus("busy", forSessionID: target.id)
            await waitForSnapshot(fixture.facade, description: "Cleared metadata restores the working row") {
                self.row(in: $0, id: target.id)?.pendingInteractionCount == 0
                    && self.row(in: $0, id: target.id)?.isWorking == true
            }
            owner.syncState.partsByMessageID["\(target.id)-assistant"]?[0].text = "After metadata"
            await waitForSnapshot(fixture.facade, description: "Text delivery resumes after metadata") {
                self.row(in: $0, id: target.id)?.latestAssistantText == "After metadata"
            }
            XCTAssertEqual(row(in: fixture.facade.snapshot, id: target.id)?.pendingInteractionCount, 0)
        }
    }

    func testCachedPreviewFallsBackAfterRemovalAndKeepsReasoningSeparateFromText() async throws {
        let fixture = try makeFixture()
        defer { fixture.facade.resetForConnectionChange() }
        let session = fixture.sessions[0]
        let owner = fixture.owners[0]
        let user = message(sessionID: session.id, id: "user", role: "user", text: "User stays separate")
        let older = message(sessionID: session.id, id: "older", text: "Older answer")
        let reasoning = message(sessionID: session.id, id: "newer", text: "Reasoning only", type: "reasoning")
        owner.applyV2Messages([user, older, reasoning], forSessionID: session.id)
        await waitForSnapshot(fixture.facade, description: "Reasoning is a fallback when no text part exists") {
            self.row(in: $0, id: session.id)?.latestAssistantText == "Reasoning only"
        }

        var answer = reasoning
        answer.parts += message(sessionID: session.id, id: "newer", text: "  Final\n answer  ").parts
        owner.applyV2Messages([user, older, answer], forSessionID: session.id)
        await waitForSnapshot(fixture.facade, description: "Text wins over reasoning in the same message") {
            self.row(in: $0, id: session.id)?.latestAssistantText == "Final \u{00B7} answer"
        }
        XCTAssertEqual(owner.syncState.partsByMessageID["newer"]?.map(\.text), ["Reasoning only", "  Final\n answer  "])
        XCTAssertEqual(row(in: fixture.facade.snapshot, id: session.id)?.latestUserText, "User stays separate")

        XCTAssertTrue(owner.removeMessage(sessionID: session.id, messageID: "newer"))
        await waitForSnapshot(fixture.facade, description: "Removing the cached latest message reveals older text") {
            self.row(in: $0, id: session.id)?.latestAssistantText == "Older answer"
        }
        var blank = message(sessionID: session.id, id: "blank", text: " \n ")
        blank.parts += message(sessionID: session.id, id: "blank", text: "Do not leak reasoning", type: "reasoning").parts
        owner.applyV2Messages([user, older, blank], forSessionID: session.id)
        owner.syncState.partsByMessageID["older"]?[0].text = "Updated older answer"
        await waitForSnapshot(fixture.facade, description: "Blank newer text falls back to updated older text") {
            self.row(in: $0, id: session.id)?.latestAssistantText == "Updated older answer"
        }
        XCTAssertTrue(owner.removeMessage(sessionID: session.id, messageID: "older"))
        await waitForSnapshot(fixture.facade, description: "No usable assistant text clears the cached preview") {
            self.row(in: $0, id: session.id)?.latestAssistantText == nil
        }
        XCTAssertEqual(row(in: fixture.facade.snapshot, id: session.id)?.latestUserText, "User stays separate")
    }

    func testOwnerMovementInvalidatesPreviewAndInteractionCachesAndRebindsStreaming() async throws {
        let fixture = try makeFixture()
        defer { fixture.facade.resetForConnectionChange() }
        let original = fixture.sessions[0]
        let oldOwner = fixture.owners[0]
        oldOwner.syncState.permissionsBySessionID[original.id] = [permission(sessionID: original.id)]
        await waitForSnapshot(fixture.facade, description: "Old owner's interaction count is cached") {
            self.row(in: $0, id: original.id)?.pendingInteractionCount == 1
        }

        let destination = project(id: "moved-project")
        let moved = OpenCodeSession(id: original.id, title: "Moved", workspaceID: nil,
            directory: destination.worktree, projectID: destination.id, parentID: nil)
        oldOwner.removeV2Session(sessionID: original.id)
        fixture.model.sessionListStore.setRecentSessions(oldOwner.sessions, for: original.directory)
        let newOwner = fixture.model.directoryStoreRegistry.store(for: moved.directory)
        newOwner.insertV2Session(moved)
        newOwner.applyV2Messages([
            message(sessionID: moved.id, id: "\(moved.id)-assistant", text: "New owner answer"),
        ], forSessionID: moved.id)
        newOwner.sessionFormStore.upsert(.init(id: "one", sessionID: moved.id, title: "One", fields: []))
        newOwner.sessionFormStore.upsert(.init(id: "two", sessionID: moved.id, title: "Two", fields: []))
        fixture.model.projects.append(destination)
        fixture.model.sessionListStore.setRecentSessions([moved], for: moved.directory)
        // A synchronous refresh may beat the queued notifications for the new directory.
        fixture.facade.setShowsLastUserMessage(fixture.facade.showsLastUserMessage)
        await waitForSnapshot(fixture.facade, description: "New owner replaces old preview and counts") {
            let row = self.row(in: $0, id: moved.id)
            return row?.projectID == destination.id && row?.latestAssistantText == "New owner answer"
                && row?.pendingInteractionCount == 2
        }
        XCTAssertTrue(fixture.model.directoryStoreRegistry.ownerStore(forSessionID: moved.id) === newOwner)
        XCTAssertEqual(fixture.facade.sessionSwitcherTarget(id: moved.id)?.directory, destination.worktree)
        XCTAssertEqual((fixture.facade.snapshot.needsInputRows + fixture.facade.snapshot.workingRows
            + fixture.facade.snapshot.recentRows).filter { $0.recent.session.id == moved.id }.count, 1)

        newOwner.syncState.partsByMessageID["\(moved.id)-assistant"]?[0].text = "New owner streaming"
        await waitForSnapshot(fixture.facade, description: "New owner is monitored after movement") {
            self.row(in: $0, id: moved.id)?.latestAssistantText == "New owner streaming"
        }
        newOwner.applySessionFormSettled(.init(sessionID: moved.id, formID: "one"))
        newOwner.applySessionFormSettled(.init(sessionID: moved.id, formID: "two"))
        await waitForSnapshot(fixture.facade, description: "New owner's cached interaction counts clear") {
            self.row(in: $0, id: moved.id)?.pendingInteractionCount == 0
        }
    }

    func testResetCancelsCoalescedAndTrailingRefreshesAndAllowsSameIDOnNewOwner() async throws {
        for resetDelay in [Duration.milliseconds(15), .milliseconds(80)] {
            let fixture = try makeFixture()
            defer { fixture.facade.resetForConnectionChange() }
            let target = fixture.sessions[0]
            let oldOwner = fixture.owners[0]
            oldOwner.syncState.permissionsBySessionID[target.id] = [permission(sessionID: target.id)]
            await waitForSnapshot(fixture.facade, description: "Warm old connection's interaction cache") {
                self.row(in: $0, id: target.id)?.pendingInteractionCount == 1
            }
            let staleRow = try XCTUnwrap(row(in: fixture.facade.snapshot, id: target.id))
            let staleContext = fixture.facade.selectionContextID
            fixture.facade.setShowsLastUserMessage(fixture.facade.showsLastUserMessage)
            let refreshedAt = ContinuousClock.now
            oldOwner.syncState.partsByMessageID["\(target.id)-assistant"]?[0].text = "Never publish after reset"
            try await Task.sleep(for: resetDelay)
            guard refreshedAt.duration(to: .now) < .milliseconds(150) else {
                throw XCTSkip("Executor stalled before reset could cancel the pending refresh")
            }
            XCTAssertEqual(row(in: fixture.facade.snapshot, id: target.id)?.latestAssistantText, staleRow.latestAssistantText)
            fixture.facade.resetForConnectionChange()
            XCTAssertEqual(fixture.facade.snapshot, .empty)
            let resurrected = expectation(description: "Cancelled refresh must not resurrect rows")
            resurrected.isInverted = true
            let observation = fixture.facade.$snapshot.dropFirst().filter { !$0.isEmpty }.sink { _ in resurrected.fulfill() }
            await fulfillment(of: [resurrected], timeout: 0.4)
            observation.cancel()

            fixture.model.directoryStoreRegistry.reset()
            fixture.model.sessionListStore.recentSessionsByDirectory = [:]
            let destination = project(id: "replacement")
            let replacement = OpenCodeSession(id: target.id, title: "Replacement", workspaceID: nil,
                directory: destination.worktree, projectID: destination.id, parentID: nil)
            let owner = fixture.model.directoryStoreRegistry.store(for: replacement.directory)
            owner.insertV2Session(replacement)
            owner.applyV2Messages([
                message(sessionID: target.id, id: "\(target.id)-user", role: "user", text: "Replacement prompt"),
                message(sessionID: target.id, id: "\(target.id)-assistant", text: "Replacement answer"),
            ], forSessionID: target.id)
            fixture.model.projects = [destination]
            fixture.model.sessionListStore.setRecentSessions([replacement], for: replacement.directory)
            await waitForSnapshot(fixture.facade, description: "Same IDs on a new owner do not reuse stale caches") {
                let row = self.row(in: $0, id: target.id)
                return row?.latestAssistantText == "Replacement answer" && row?.pendingInteractionCount == 0
            }
            XCTAssertEqual(fixture.facade.sessionSwitcherTarget(id: target.id), replacement)
            XCTAssertEqual(row(in: fixture.facade.snapshot, id: target.id)?.latestUserText, "Replacement prompt")
            XCTAssertFalse(fixture.facade.canSelect(staleRow, context: staleContext))
            owner.syncState.partsByMessageID["\(target.id)-assistant"]?[0].text = "Replacement final"
            await waitForSnapshot(fixture.facade, description: "Replacement owner's trailing updates still work") {
                self.row(in: $0, id: target.id)?.latestAssistantText == "Replacement final"
            }
        }
    }

    func testMeasureRepeatedSnapshotRefreshWithLongColdHistories() throws {
        let fixture = try makeFixture(historyCount: 1_000)
        defer { fixture.facade.resetForConnectionChange() }
        var publications = 0
        let observation = fixture.facade.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        // Exercise real snapshot construction while old transcripts remain untouched. No wall-time threshold.
        measure {
            for _ in 0..<30 {
                fixture.facade.setShowsLastUserMessage(fixture.facade.showsLastUserMessage)
            }
        }
        XCTAssertEqual(publications, 0, "Unchanged refreshes must not republish equivalent snapshots")
        for index in fixture.sessions.indices {
            let session = fixture.sessions[index]
            XCTAssertEqual(fixture.owners[index].syncStore.messageCount(forSessionID: session.id), 1_002)
            XCTAssertEqual(row(in: fixture.facade.snapshot, id: session.id)?.latestAssistantText, "Answer \(session.id)")
        }
    }

    private func makeFixture(historyCount: Int = 0) throws -> Fixture {
        // Never connect or prepare: all canonical state is injected and no API compatibility client exists.
        let model = AppViewModel(backendFactory: ActivityPerformanceBackend())
        model.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let projects = [project(id: "activity-a"), project(id: "activity-b")]
        model.projects = projects
        var sessions: [OpenCodeSession] = []
        var owners: [DirectoryStore] = []
        let coldText = String(repeating: "Cold history with **markdown** and whitespace.\n", count: 100)
        for index in 0..<4 {
            let project = projects[index / 2]
            var session = OpenCodeSession(id: "stream-\(index)", title: "Stream \(index)", workspaceID: nil,
                directory: project.worktree, projectID: project.id, parentID: nil)
            session.time = .init(created: 1_000 + Double(index), updated: 2_000 + Double(index))
            let owner = model.directoryStoreRegistry.store(for: project.worktree)
            owner.insertV2Session(session)
            owner.applySessionStatus("busy", forSessionID: session.id)
            let history = (0..<historyCount).map {
                message(sessionID: session.id, id: "\(session.id)-cold-\($0)",
                    role: $0.isMultiple(of: 2) ? "user" : "assistant", text: coldText)
            }
            owner.applyV2Messages(history + [
                message(sessionID: session.id, id: "\(session.id)-user", role: "user", text: "Prompt \(session.id)"),
                message(sessionID: session.id, id: "\(session.id)-assistant", text: "Answer \(session.id)"),
            ], forSessionID: session.id)
            sessions.append(session)
            owners.append(owner)
        }
        for project in projects {
            model.sessionListStore.setRecentSessions(sessions.filter { $0.projectID == project.id }, for: project.worktree)
        }
        let facade = ActivityFacade(viewModel: model)
        XCTAssertEqual(facade.snapshot.workingRows.count, 4)
        XCTAssertNil(model.backendConnection)
        return Fixture(model: model, facade: facade, sessions: sessions, owners: owners)
    }

    private func project(id: String) -> OpenCodeProject {
        .init(id: id, worktree: "/activity-performance/\(id)", vcs: "git", name: id,
            sandboxes: nil, icon: nil, time: nil)
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

    private func row(in snapshot: ActivityFacade.Snapshot, id: String) -> ActivityFacade.RowSnapshot? {
        (snapshot.needsInputRows + snapshot.workingRows + snapshot.recentRows).first { $0.recent.session.id == id }
    }

    private func waitForSnapshot(_ facade: ActivityFacade, description: String,
        matching predicate: @escaping (ActivityFacade.Snapshot) -> Bool) async {
        let delivered = expectation(description: description)
        let observation = facade.$snapshot.filter(predicate).prefix(1).sink { _ in delivered.fulfill() }
        await fulfillment(of: [delivered], timeout: 2)
        withExtendedLifetime(observation) {}
    }
}
