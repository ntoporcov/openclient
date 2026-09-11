import Combine
import XCTest
@testable import OpenClient

@MainActor
final class DirectoryStoreTests: XCTestCase {
    func testV2GlobalListedSessionKeepsOwnerAndSelectionAcrossFetchAndLocatedEvents() throws {
        let registry = DirectoryStoreRegistry()
        let global = registry.activeStore
        let original = OpenCodeSession(id: "ses_global", title: "Original", workspaceID: nil, directory: "/tmp/project", projectID: "global", parentID: nil)
        global.insertV2Session(original)
        global.selectedSession = original
        let fetched = OpenCodeSession(id: original.id, title: "Renamed", workspaceID: nil, directory: "/tmp/project/", projectID: "global", parentID: nil)
        let owner = registry.targetStore(forV2Session: fetched)
        XCTAssertTrue(owner === global)
        owner.insertV2Session(fetched)
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.execution.started","location":{"directory":"/tmp/project"},"data":{"sessionID":"ses_global"}}"#))
        XCTAssertTrue(registry.targetStore(forV2Event: event) === global)
        XCTAssertTrue(global.applyV2Event(event))
        XCTAssertEqual(global.selectedSession?.id, original.id)
        XCTAssertEqual(global.selectedSession?.title, "Renamed")
        XCTAssertEqual(registry.activeKey, DirectoryStoreRegistry.globalKey)
        XCTAssertNil(registry.existingStore(for: "/tmp/project"))
    }

    func testV2GlobalOwnerChangesOnlyForActualSessionLocationChange() throws {
        let registry = DirectoryStoreRegistry()
        let original = OpenCodeSession(id: "ses_global", title: nil, workspaceID: nil, directory: "/old", projectID: "global", parentID: nil)
        registry.activeStore.insertV2Session(original)
        let moved = OpenCodeSession(id: original.id, title: nil, workspaceID: nil, directory: "/new", projectID: "global", parentID: nil)
        XCTAssertTrue(registry.targetStore(forV2Session: moved) === registry.store(for: "/new"))
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.moved","location":{"directory":"/old"},"data":{"sessionID":"ses_global","location":{"directory":"/new"},"projectID":"global"}}"#))
        XCTAssertTrue(registry.targetStore(forV2Event: event) === registry.store(for: "/new"))
        let workspaceMove = OpenCodeSession(id: original.id, title: nil, workspaceID: "wrk_new", directory: "/old", projectID: "global", parentID: nil)
        XCTAssertFalse(registry.targetStore(forV2Session: workspaceMove) === registry.activeStore)
    }

    func testV2DiscoveredChildSharesGlobalParentOwnerAndSurvivesRootRefresh() throws {
        let registry = DirectoryStoreRegistry()
        let root = OpenCodeSession(id: "ses_root", title: nil, workspaceID: nil, directory: "/project", projectID: "global", parentID: nil)
        let child = OpenCodeSession(id: "ses_child", title: nil, workspaceID: nil, directory: "/project", projectID: "global", parentID: root.id)
        let store = registry.activeStore
        store.insertV2Session(root)
        store.selectedSession = root
        XCTAssertTrue(registry.targetStore(forV2Session: child) === store)
        store.insertV2Session(child)
        let formEvent = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"form.created","location":{"directory":"/project"},"data":{"form":{"id":"frm_child","sessionID":"ses_child","title":"Child question","fields":[{"key":"answer","type":"string","required":true}]}}}"#))
        XCTAssertTrue(registry.targetStore(forV2Event: formEvent) === store)
        XCTAssertTrue(store.applyV2Event(formEvent))
        store.applyV2SessionPage(.init(sessions: [root], nextCursor: nil), replacing: true, requestedCursor: nil, limit: 50)
        XCTAssertEqual(store.sessions.map(\.id), [root.id, child.id])
        XCTAssertEqual(store.sessionTotal, 1)
        let visible = SessionInteractionStore.forms(forSessionTreeRootID: root.id, sessions: store.sessions,
            forms: Array(store.sessionFormStore.forms.values))
        XCTAssertEqual(visible.map(\.id), ["frm_child"])
        let form = try XCTUnwrap(store.sessionFormStore.forms[.init(sessionID: child.id, formID: "frm_child")])
        XCTAssertEqual(visible, [form])
        XCTAssertEqual(form.fields.map(\.raw), [["key": .string("answer"), "type": .string("string"), "required": .bool(true)]])
        XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
    }

    func testV2LocationWinsOverActiveAndUnknownUnscopedEventsUseGlobalStore() throws {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/active")
        let located = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.execution.started","location":{"directory":"/tmp/other/","workspaceID":"wrk_other"},"data":{"sessionID":"ses_unknown"}}"#))
        XCTAssertTrue(registry.targetStore(forV2Event: located) === registry.store(for: "/tmp/other"))
        let unscoped = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.execution.started","data":{"sessionID":"ses_unknown"}}"#))
        XCTAssertTrue(registry.targetStore(forV2Event: unscoped) === registry.store(for: nil))
        XCTAssertFalse(registry.targetStore(forV2Event: unscoped) === registry.activeStore)
    }

    func testV2LifecycleAndStatusHydrationPreserveNewerLiveTransitions() throws {
        let store = DirectoryStore()
        let created = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"created":1000,"type":"session.created","data":{"sessionID":"ses_new","title":"First","projectID":"proj_1","location":{"directory":"/tmp/project"},"slug":"slug","version":"2"}}"#))
        XCTAssertTrue(store.applyV2Event(created))
        let revision = store.statusRevision
        store.applySessionStatus("busy", forSessionID: "ses_new")
        store.applyV2ActiveStatuses([:], requestedAtRevision: revision)
        XCTAssertEqual(store.sessionStatuses["ses_new"], "busy")
        store.applyV2ActiveStatuses([:], requestedAtRevision: store.statusRevision)
        XCTAssertEqual(store.sessionStatuses["ses_new"], "idle")
        let renamed = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"created":2000,"type":"session.renamed","data":{"sessionID":"ses_new","title":"Renamed"}}"#))
        XCTAssertTrue(store.applyV2Event(renamed))
        XCTAssertEqual(store.sessions.first?.title, "Renamed")
        XCTAssertEqual(store.sessions.first?.time?.created, 1000)
        let deleted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.deleted","data":{"sessionID":"ses_new"}}"#))
        XCTAssertTrue(store.applyV2Event(deleted))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertNil(store.sessionStatuses["ses_new"])
    }

    func testV2FormsUseNestedSessionIdentityAndRevisionsPreventResurrection() throws {
        let store = DirectoryStore()
        let created = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"form.created","data":{"form":{"id":"frm_1","sessionID":"ses_1","title":"Choose","fields":[{"key":"color","type":"string","required":true,"options":[{"label":"Blue","value":"blue-value"}]}]}}}"#))
        XCTAssertEqual(created.sessionID, "ses_1")
        XCTAssertTrue(store.applyV2Event(created))
        let form = try XCTUnwrap(store.v2FormsByID["frm_1"])
        XCTAssertEqual(try form.answer(from: [["Blue"]]), ["color": .string("blue-value")])
        let native = try XCTUnwrap(store.sessionFormStore.forms[form.backendForm.key])
        XCTAssertEqual(native, form.backendForm)
        XCTAssertEqual(try native.contract.answer(values: ["color": .string("blue-value")]), ["color": .string("blue-value")])
        XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
        let revision = store.questionRevision
        let cancelled = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"form.cancelled","data":{"id":"frm_1","sessionID":"ses_1"}}"#))
        XCTAssertTrue(store.applyV2Event(cancelled))
        store.applyV2SessionInteractions(sessionID: "ses_1", permissions: [], forms: [form], permissionRevisionAtRequestStart: store.permissionRevision, questionRevisionAtRequestStart: revision)
        XCTAssertNil(store.v2FormsByID["frm_1"])
        XCTAssertNil(store.sessionFormStore.forms[native.key])
        XCTAssertNil(store.syncState.questionsBySessionID["ses_1"])
    }

    func testV2FormSettlementFromZeroQuestionRevisionInvalidatesDraftAndOperation() throws {
        for eventType in ["form.replied", "form.cancelled"] {
            let registry = DirectoryStoreRegistry()
            let store = registry.activeStore
            let form = BackendForm(id: "frm_1", sessionID: "ses_1", title: "Confirm",
                fields: [.init(raw: ["key": .string("confirm"), "type": .string("boolean"), "required": .bool(true)])])
            store.sessionFormStore.upsert(form)
            store.sessionFormStore.setValue(.bool(false), fieldID: "confirm", for: form.key)
            let reference = BackendFormReference(key: form.key)
            let connectionID = UUID()
            let generation = store.sessionFormStore.generation
            let token = try XCTUnwrap(store.sessionFormStore.begin(.submitting, reference: reference, connectionID: connectionID))
            XCTAssertEqual(store.questionRevision, 0)
            XCTAssertEqual(registry.v2LifecycleRevision(sessionID: form.sessionID), 0)
            XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
            let answer = eventType == "form.replied" ? ",\"answer\":{\"confirm\":false}" : ""
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                "{\"type\":\"\(eventType)\",\"data\":{\"id\":\"frm_1\",\"sessionID\":\"ses_1\"\(answer)}}"))

            XCTAssertTrue(store.applyV2Event(event))

            XCTAssertEqual(store.questionRevision, 1)
            XCTAssertEqual(registry.v2LifecycleRevision(sessionID: form.sessionID), 0)
            XCTAssertTrue(store.sessionFormStore.forms.isEmpty)
            XCTAssertTrue(store.sessionFormStore.editing.isEmpty)
            XCTAssertFalse(store.sessionFormStore.owns(token, reference: reference, connectionID: connectionID, generation: generation))
            let dto = OpenCodeV2Form(id: form.id, sessionID: form.sessionID, title: form.title, metadata: nil, fields: form.fields.map(\.raw))
            store.applyV2SessionInteractions(sessionID: form.sessionID, permissions: [], forms: [dto],
                permissionRevisionAtRequestStart: store.permissionRevision, questionRevisionAtRequestStart: 0)
            XCTAssertTrue(store.sessionFormStore.forms.isEmpty)
            XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
        }
    }

    func testV2FormSettlementBeforeInitialHydrationCannotBeResurrected() {
        let store = DirectoryStore()
        let form = BackendForm(id: "frm_1", sessionID: "ses_1", title: "Confirm",
            fields: [.init(raw: ["key": .string("confirm"), "type": .string("boolean")])])
        let initialRevision = store.sessionFormStore.revision
        XCTAssertEqual(store.questionRevision, 0)
        store.applySessionFormSettled(form.key)
        XCTAssertEqual(store.questionRevision, 1)
        store.applySessionForms([form], sessionID: form.sessionID, ifUnchangedSince: initialRevision)
        store.applySessionFormCreated(form)
        XCTAssertTrue(store.sessionFormStore.forms.isEmpty)
        XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
    }

    func testV2ReconnectQueuesEveryKnownDirectoryAndBackgroundTimeline() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/active")
        registry.activeStore.insertV2Session(session(id: "ses_active", directory: "/tmp/active"))
        registry.store(for: "/tmp/background").insertV2Session(session(id: "ses_background", directory: "/tmp/background"))
        registry.requestV2Reconciliation(reconnect: true)
        let work = registry.takeV2Reconciliation()
        XCTAssertTrue(work.reconnect)
        XCTAssertEqual(work.sessionIDs, ["ses_active", "ses_background"])
        XCTAssertTrue(registry.takeV2Reconciliation().sessionIDs.isEmpty)
    }

    func testV2UnknownSessionDeletionInvalidatesInFlightDiscovery() throws {
        let registry = DirectoryStoreRegistry()
        let revision = registry.v2LifecycleRevision(sessionID: "ses_unknown")
        let deleted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.deleted","data":{"sessionID":"ses_unknown"}}"#))
        registry.recordV2LifecycleEvent(deleted)
        XCTAssertNotEqual(registry.v2LifecycleRevision(sessionID: "ses_unknown"), revision)
        XCTAssertNil(registry.ownerStore(forSessionID: "ses_unknown"))
        XCTAssertTrue(registry.isV2SessionDeleted("ses_unknown"))
        registry.requestV2Reconciliation(sessionID: "ses_unknown")
        XCTAssertTrue(registry.takeV2Reconciliation().sessionIDs.isEmpty)
    }

    func testOwnerLookupKeepsActivePreferenceAndFindsMetadataOnlyStores() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/active")
        let active = registry.activeStore
        let background = registry.store(for: "/tmp/background")
        let shared = session(id: "shared", directory: "/tmp/active")
        active.sessions = [shared]
        background.sessions = [shared]
        XCTAssertTrue(registry.ownerStore(forSessionID: shared.id) === active)
        XCTAssertEqual(registry.stores(containingSessionID: shared.id).count, 2)
        background.sessionStatuses["metadata-only"] = "busy"
        XCTAssertTrue(registry.ownerStore(forSessionID: "metadata-only") === background)
        XCTAssertNil(registry.ownerStore(forSessionID: "missing"))
    }

    func testV2SessionListSnapshotCannotResurrectUnknownSessionDeletedInFlight() throws {
        let registry = DirectoryStoreRegistry(activeDirectory: "/project")
        let snapshot = registry.v2LifecycleSnapshot
        let removed = session(id: "ses_removed", directory: "/project")
        let retained = session(id: "ses_retained", directory: "/project")
        let deleted = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.deleted","data":{"sessionID":"ses_removed"}}"#))
        registry.recordV2LifecycleEvent(deleted)
        registry.activeStore.applyV2DiscoveredSessions(registry.unchangedV2Sessions([removed, retained], since: snapshot))
        XCTAssertEqual(registry.activeStore.sessions.map(\.id), [retained.id])
    }

    func testV2CanonicalSessionRefreshClearsWorkspaceAndPreservesLiveRenameDuringListRequest() {
        let original = OpenCodeSession(id: "ses_1", title: "Original", workspaceID: "wrk_old", directory: "/project", projectID: "project", parentID: nil)
        let renamed = OpenCodeSession(id: "ses_1", title: "Renamed", workspaceID: nil, directory: "/project", projectID: "project", parentID: nil)
        let store = DirectoryStore(sessions: [original])
        let snapshot = store.sessions
        store.insertV2Session(renamed)
        store.applyV2DiscoveredSessions([original], ifUnchangedSince: snapshot)
        XCTAssertEqual(store.sessions, [renamed])
        XCTAssertNil(store.sessions[0].workspaceID)
    }

    func testV2OlderStatusResponseCannotOverwriteAlreadyAcceptedSnapshot() {
        let store = DirectoryStore(sessions: [session(id: "ses_1", directory: "/project")])
        let revision = store.statusRevision
        store.applyV2ActiveStatuses([:], requestedAtRevision: revision)
        store.applyV2ActiveStatuses(["ses_1": "busy"], requestedAtRevision: revision)
        XCTAssertEqual(store.sessionStatuses["ses_1"], "idle")
    }

    func testV2LocatedBackgroundEventUpdatesOnlyItsDirectoryCache() throws {
        let registry = DirectoryStoreRegistry(activeDirectory: "/selected")
        let chat = ChatStore(preparedSessionID: "ses_selected")
        let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"id":"evt_start","created":1000,"type":"session.step.started","durable":{"aggregateID":"ses_other","seq":1,"version":1},"location":{"directory":"/other","workspaceID":"wrk_other"},"data":{"sessionID":"ses_other","assistantMessageID":"msg_other","agent":"build","model":{"providerID":"provider","id":"model"}}}"#))
        let owner = registry.targetStore(forV2Event: event)
        XCTAssertTrue(chat.applyV2StreamEvent(event, sessionID: "ses_other"))
        owner.applyV2Messages(chat.cachedMessagesBySessionID["ses_other"] ?? [], forSessionID: "ses_other")
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: "ses_other").map(\.id), ["msg_other"])
        XCTAssertTrue(registry.activeStore.syncState.messagesBySessionID.isEmpty)
        XCTAssertTrue(chat.messages.isEmpty)
    }

    func testPreviouslyOpenedSessionUsesMostRecentAvailableSelection() {
        let first = session(id: "ses_first", directory: "/tmp/project")
        let second = session(id: "ses_second", directory: "/tmp/project")
        let third = session(id: "ses_third", directory: "/tmp/project")
        let store = DirectoryStore(sessions: [first, second, third], selectedSession: first)

        store.selectedSession = second
        store.selectedSession = third

        XCTAssertEqual(store.previouslyOpenedSession(excluding: third.id)?.id, second.id)

        store.selectedSession = second

        XCTAssertEqual(store.previouslyOpenedSession(excluding: second.id)?.id, third.id)
    }

    func testSessionSwitcherFreezesRecentCandidatesAndAdvancesSelection() {
        let first = session(id: "ses_first", directory: "/tmp/project")
        let second = session(id: "ses_second", directory: "/tmp/project")
        let third = session(id: "ses_third", directory: "/tmp/project")
        let store = DirectoryStore(sessions: [first, second, third], selectedSession: first)
        store.selectedSession = second
        store.selectedSession = third

        XCTAssertEqual(store.advanceSessionSwitcher(from: third.id)?.id, second.id)
        XCTAssertEqual(store.advanceSessionSwitcher(from: second.id)?.id, first.id)
        store.revealSessionSwitcher()
        XCTAssertEqual(store.sessionSwitcherPresentation?.selectedSessionID, first.id)

        let selectedSession = store.finishSessionSwitcher()

        XCTAssertEqual(selectedSession?.id, first.id)
        XCTAssertNil(store.sessionSwitcherPresentation)
    }

    func testUpsertSessionsPreservesExistingSessionsAndMergesUpdates() {
        let existing = OpenCodeSession(id: "existing", title: "Old", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        let updated = OpenCodeSession(id: "existing", title: "Updated", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        let added = OpenCodeSession(id: "added", title: "Added", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        let store = DirectoryStore(sessions: [existing], sessionTotal: 1)

        XCTAssertTrue(store.upsertSessions([updated, added]))
        XCTAssertEqual(store.sessions.map(\.id), [existing.id, added.id])
        XCTAssertEqual(store.sessions.first?.title, "Updated")
        XCTAssertEqual(store.sessionTotal, 2)
    }

    func testApplySessionStatusUpdatesPublishedAndSyncState() {
        let store = DirectoryStore()

        store.applySessionStatus("busy", forSessionID: "ses_1")

        XCTAssertEqual(store.sessionStatuses["ses_1"], "busy")
        XCTAssertEqual(store.syncState.sessionStatusesBySessionID["ses_1"], "busy")
    }

    func testV2InteractionReplacementAndRemovalStaySessionScoped() {
        let store = DirectoryStore()
        let permission = permission(id: "per_1", sessionID: "ses_1")
        let question = questionRequest(id: "que_1", sessionID: "ses_1")

        store.applyV2Interactions(permissions: [permission], questions: [question])

        XCTAssertEqual(store.syncState.permissionsBySessionID["ses_1"], [permission])
        XCTAssertEqual(store.syncState.questionsBySessionID["ses_1"], [question])
        store.removeV2Permission(id: permission.id, sessionID: permission.sessionID)
        store.removeV2Question(id: question.id, sessionID: question.sessionID)
        XCTAssertNil(store.syncState.permissionsBySessionID["ses_1"])
        XCTAssertNil(store.syncState.questionsBySessionID["ses_1"])
    }

    func testApplyDirectoryReloadOwnsSessionsCommandsStatusesAndInteractionSyncMaps() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let permission = permission(id: "perm_1", sessionID: selected.id)
        let question = questionRequest(id: "q_1", sessionID: selected.id)
        let command = OpenCodeCommand(
            name: "review",
            description: "Review changes",
            agent: nil,
            model: nil,
            source: "project",
            template: "review",
            subtask: false,
            hints: []
        )
        let bootstrap = OpenCodeDirectoryBootstrap(
            sessions: [selected],
            sessionTotal: 2,
            sessionLimit: 100,
            commands: [command],
            permissions: [permission],
            questions: [question]
        )
        let store = DirectoryStore(isLoadingSessions: true)

        let changed = store.applyDirectoryReload(
            bootstrap: bootstrap,
            statuses: [selected.id: "busy"],
            scopedSessions: [selected]
        )

        XCTAssertTrue(changed)
        XCTAssertFalse(store.isLoadingSessions)
        XCTAssertEqual(store.sessions, [selected])
        XCTAssertEqual(store.sessionTotal, 2)
        XCTAssertEqual(store.sessionLimit, 100)
        XCTAssertTrue(store.hasMoreSessions)
        XCTAssertEqual(store.commands, [command])
        XCTAssertEqual(store.sessionStatuses, [selected.id: "busy"])
        XCTAssertEqual(store.syncState.sessionStatusesBySessionID, [selected.id: "busy"])
        XCTAssertEqual(store.syncState.permissionsBySessionID[selected.id], [permission])
        XCTAssertEqual(store.syncState.questionsBySessionID[selected.id], [question])
    }

    func testRootReloadPreservesKnownChildSessions() {
        let root = session(id: "ses_root", directory: "/tmp/project")
        let child = OpenCodeSession(
            id: "ses_child",
            title: "Child",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: nil,
            parentID: root.id
        )
        let store = DirectoryStore(sessions: [root, child])
        let bootstrap = OpenCodeDirectoryBootstrap(
            sessions: [root],
            sessionTotal: 1,
            sessionLimit: 100,
            commands: [],
            permissions: [],
            questions: []
        )

        store.applyDirectoryReload(bootstrap: bootstrap, statuses: [:], scopedSessions: [root])

        XCTAssertEqual(store.sessions.map(\.id), [root.id, child.id])
        XCTAssertEqual(store.sessionTotal, 1)
        XCTAssertFalse(store.hasMoreSessions)
    }

    func testV2SessionPagesReplaceAppendDeduplicateAndStopAtBoundary() {
        let first = session(id: "ses_first", directory: "/tmp/project")
        let duplicate = session(id: "ses_duplicate", directory: "/tmp/project")
        let replacement = OpenCodeSession(
            id: duplicate.id,
            title: "Updated",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project-1",
            parentID: nil
        )
        let store = DirectoryStore(isLoadingSessions: true)

        store.applyV2SessionPage(
            OpenCodeV2SessionPage(sessions: [first, duplicate], nextCursor: "next"),
            replacing: true,
            requestedCursor: nil,
            limit: 50
        )

        XCTAssertEqual(store.sessions.map(\.id), [first.id, duplicate.id])
        XCTAssertEqual(store.nextSessionCursor, "next")
        XCTAssertTrue(store.hasMoreSessions)
        XCTAssertFalse(store.isLoadingSessions)

        store.applyV2SessionPage(
            OpenCodeV2SessionPage(sessions: [replacement], nextCursor: nil),
            replacing: false,
            requestedCursor: "next",
            limit: 50
        )

        XCTAssertEqual(store.sessions.map(\.id), [first.id, duplicate.id])
        XCTAssertEqual(store.sessions[1].title, "Updated")
        XCTAssertNil(store.nextSessionCursor)
        XCTAssertFalse(store.hasMoreSessions)
    }

    func testV2SessionPageRejectsUnchangedNextCursor() {
        let store = DirectoryStore()

        store.applyV2SessionPage(
            OpenCodeV2SessionPage(sessions: [session(id: "ses_1", directory: nil)], nextCursor: "same"),
            replacing: false,
            requestedCursor: "same",
            limit: 50
        )

        XCTAssertNil(store.nextSessionCursor)
        XCTAssertFalse(store.hasMoreSessions)
    }

    func testV2MessagesPreserveProjectedTimelineOrder() {
        let store = DirectoryStore()
        let messages = [
            message(id: "msg_z", role: "user", text: "Older", sessionID: "ses_v2"),
            message(id: "msg_a", role: "assistant", text: "Newer", sessionID: "ses_v2"),
        ]

        store.applyV2Messages(messages, forSessionID: "ses_v2")

        XCTAssertEqual(store.syncState.messageEnvelopes(forSessionID: "ses_v2").map(\.id), ["msg_z", "msg_a"])
    }

    func testStaleDirectoryBootstrapDoesNotEraseNewerPermissionOrQuestionEvents() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let permission = permission(id: "perm_live", sessionID: selected.id)
        let question = questionRequest(id: "q_live", sessionID: selected.id)
        let store = DirectoryStore(sessions: [selected], selectedSession: selected)
        let permissionRevision = store.permissionRevision
        let questionRevision = store.questionRevision

        store.recordInteractionEvent(.permissionAsked(permission))
        XCTAssertTrue(store.applyPermissions([permission], ifUnchangedSince: store.permissionRevision))
        store.recordInteractionEvent(.questionAsked(question))
        XCTAssertTrue(store.applyQuestions([question], ifUnchangedSince: store.questionRevision))

        let staleBootstrap = OpenCodeDirectoryBootstrap(
            sessions: [selected],
            sessionTotal: 1,
            sessionLimit: 100,
            commands: [],
            permissions: [],
            questions: []
        )
        store.applyDirectoryReload(
            bootstrap: staleBootstrap,
            statuses: [:],
            scopedSessions: [selected],
            permissionRevisionAtRequestStart: permissionRevision,
            questionRevisionAtRequestStart: questionRevision
        )

        XCTAssertEqual(store.syncState.permissionsBySessionID[selected.id], [permission])
        XCTAssertEqual(store.syncState.questionsBySessionID[selected.id], [question])
    }

    func testCanonicalMessagesDeduplicateMessageAndPartIDs() {
        let selectedID = "ses_selected"
        let first = message(id: "msg_duplicate", role: "assistant", text: "First", sessionID: selectedID)
        let replacement = message(id: "msg_duplicate", role: "assistant", text: "Replacement", sessionID: selectedID)
        var duplicatePartReplacement = replacement
        duplicatePartReplacement.parts.append(replacement.parts[0])
        let store = DirectoryStore()

        store.applyCanonicalMessages([first, duplicatePartReplacement], forSessionID: selectedID)

        let messages = store.syncState.messageEnvelopes(forSessionID: selectedID)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].parts.count, 1)
        XCTAssertEqual(messages[0].parts[0].text, "Replacement")
    }

    func testApplySelectedSessionAfterReloadUpdatesOnlyWhenSelectionChanges() {
        let selected = session(id: "ses_selected", directory: nil)
        let store = DirectoryStore(selectedSession: selected)

        XCTAssertFalse(store.applySelectedSessionAfterReload(selected))
        XCTAssertTrue(store.applySelectedSessionAfterReload(nil))
        XCTAssertNil(store.selectedSession)
    }

    func testApplySessionSelectionUsesSyncedMessagesBeforeCachedMessages() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let synced = message(id: "msg_synced", role: "assistant", text: "Synced", sessionID: selected.id)
        let cached = message(id: "msg_cached", role: "assistant", text: "Cached", sessionID: selected.id)
        let store = DirectoryStore()
        store.syncState.replaceMessages([synced], forSessionID: selected.id)

        let visible = store.applySessionSelection(selected, cachedMessages: [cached])

        XCTAssertEqual(store.selectedSession, selected)
        XCTAssertEqual(visible.map(\.id), ["msg_synced"])
        XCTAssertEqual(store.syncState.messageEnvelopes(forSessionID: selected.id).map(\.id), ["msg_synced"])
    }

    func testApplySessionSelectionSeedsSyncStateFromCacheWhenSyncedMessagesAreEmpty() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let cached = message(id: "msg_cached", role: "assistant", text: "Cached", sessionID: selected.id)
        let store = DirectoryStore()

        let visible = store.applySessionSelection(selected, cachedMessages: [cached])

        XCTAssertEqual(store.selectedSession, selected)
        XCTAssertEqual(visible.map(\.id), ["msg_cached"])
        XCTAssertEqual(store.syncState.messageEnvelopes(forSessionID: selected.id).map(\.id), ["msg_cached"])
    }

    func testApplySessionSelectionSeedsFullSyncStateWhileShowingOnlyLatestCachedRound() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let cached = (0..<8).flatMap { round in
            [
                message(id: "msg_\(round)_user", role: "user", text: "Prompt \(round)", sessionID: selected.id),
                message(id: "msg_\(round)_assistant", role: "assistant", text: "Answer \(round)", sessionID: selected.id),
            ]
        }
        let store = DirectoryStore()

        let visible = store.applySessionSelection(selected, cachedMessages: cached)

        XCTAssertEqual(visible.count, 2)
        XCTAssertEqual(store.syncState.messageCount(forSessionID: selected.id), cached.count)
    }

    func testApplySessionSelectionPreparesOnlyLatestUserRound() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        var messages: [OpenCodeMessageEnvelope] = []
        for round in 0..<20 {
            messages.append(message(id: String(format: "msg_%03d_user", round * 2), role: "user", text: "Prompt \(round)", sessionID: selected.id))
            messages.append(message(id: String(format: "msg_%03d_assistant", round * 2 + 1), role: "assistant", text: "Answer \(round)", sessionID: selected.id))
        }
        let store = DirectoryStore()
        store.syncState.replaceMessages(messages, forSessionID: selected.id)

        let visible = store.applySessionSelection(selected, cachedMessages: [])

        XCTAssertEqual(visible.map(\.id), [
            "msg_038_user", "msg_039_assistant",
        ])
        XCTAssertEqual(store.syncState.messageCount(forSessionID: selected.id), 40)
    }

    func testApplySessionSelectionCapsAnOversizedLatestRound() {
        let selected = session(id: "ses_selected", directory: "/tmp/project")
        let messages = [
            message(id: "msg_000_user", role: "user", text: "Prompt", sessionID: selected.id),
        ] + (1...20).map { index in
            message(
                id: String(format: "msg_%03d_assistant", index),
                role: "assistant",
                text: "Step \(index)",
                sessionID: selected.id
            )
        }
        let store = DirectoryStore()
        store.syncState.replaceMessages(messages, forSessionID: selected.id)

        let visible = store.applySessionSelection(selected, cachedMessages: [])

        XCTAssertEqual(visible.count, 12)
        XCTAssertEqual(visible.last?.id, "msg_020_assistant")
        XCTAssertEqual(store.syncState.messageCount(forSessionID: selected.id), 21)
    }

    func testApplyInteractionHydrationResultsUpdatesSyncState() {
        let selectedID = "ses_selected"
        let otherID = "ses_other"
        let selectedTodo = OpenCodeTodo(content: "Selected", status: "pending", priority: "high")
        let selectedPermission = permission(id: "perm_selected", sessionID: selectedID)
        let otherPermission = permission(id: "perm_other", sessionID: otherID)
        let selectedQuestion = questionRequest(id: "q_selected", sessionID: selectedID)
        let otherQuestion = questionRequest(id: "q_other", sessionID: otherID)
        let store = DirectoryStore()

        store.applyTodos([selectedTodo], forSessionID: selectedID)
        store.applyPermissions([selectedPermission, otherPermission], ifUnchangedSince: store.permissionRevision)
        store.applyQuestions([selectedQuestion, otherQuestion], ifUnchangedSince: store.questionRevision)

        XCTAssertEqual(store.syncState.todosBySessionID[selectedID], [selectedTodo])
        XCTAssertEqual(store.syncState.permissionsBySessionID[selectedID], [selectedPermission])
        XCTAssertEqual(store.syncState.permissionsBySessionID[otherID], [otherPermission])
        XCTAssertEqual(store.syncState.questionsBySessionID[selectedID], [selectedQuestion])
        XCTAssertEqual(store.syncState.questionsBySessionID[otherID], [otherQuestion])

        store.clearPermissions()
        store.clearQuestions()

        XCTAssertTrue(store.syncState.permissionsBySessionID.isEmpty)
        XCTAssertTrue(store.syncState.questionsBySessionID.isEmpty)
    }

    func testApplySessionStatusesMirrorsDirectoryAndSyncState() {
        let store = DirectoryStore(sessionStatuses: ["ses_stale": "busy"])

        XCTAssertTrue(store.applySessionStatuses(["ses_selected": "idle"]))

        XCTAssertEqual(store.sessionStatuses, ["ses_selected": "idle"])
        XCTAssertEqual(store.syncState.sessionStatusesBySessionID, ["ses_selected": "idle"])
    }

    func testApplySessionStatusesDoesNotPublishWhenStateIsUnchanged() {
        let store = DirectoryStore()
        XCTAssertTrue(store.applySessionStatuses(["ses_selected": "idle"]))
        var publicationCount = 0
        let observation = store.objectWillChange.sink { publicationCount += 1 }

        XCTAssertFalse(store.applySessionStatuses(["ses_selected": "idle"]))

        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testApplyCanonicalMessagesReplacesSessionTranscriptInSyncState() {
        let selectedID = "ses_selected"
        let initial = message(id: "msg_initial", role: "assistant", text: "Initial", sessionID: selectedID)
        let loaded = message(id: "msg_loaded", role: "assistant", text: "Loaded", sessionID: selectedID)
        let store = DirectoryStore()
        store.syncState.replaceMessages([initial], forSessionID: selectedID)

        store.applyCanonicalMessages([loaded], forSessionID: selectedID)

        XCTAssertEqual(store.syncState.messageEnvelopes(forSessionID: selectedID).map(\.id), ["msg_loaded"])
    }

    func testAppendAndRemoveMessageUpdatesSessionTranscriptInSyncState() {
        let sessionID = "ses_selected"
        let message = message(id: "msg_optimistic", role: "user", text: "Hello", sessionID: sessionID)
        let store = DirectoryStore()

        store.appendMessage(message, forSessionID: sessionID)
        XCTAssertEqual(store.syncState.messageEnvelopes(forSessionID: sessionID).map(\.id), ["msg_optimistic"])

        XCTAssertTrue(store.removeMessage(sessionID: sessionID, messageID: message.id))
        XCTAssertTrue(store.syncState.messageEnvelopes(forSessionID: sessionID).isEmpty)
    }

    func testRegistryNormalizesDirectoryKeysWithoutConflatingRootAndGlobal() {
        XCTAssertEqual(DirectoryStoreRegistry.key(for: nil), "global")
        XCTAssertEqual(DirectoryStoreRegistry.key(for: ""), "global")
        XCTAssertEqual(DirectoryStoreRegistry.key(for: "global"), "global")
        XCTAssertEqual(DirectoryStoreRegistry.key(for: "/tmp/project/"), "/tmp/project")
        XCTAssertEqual(DirectoryStoreRegistry.key(for: "\\tmp\\project\\"), "/tmp/project")
        XCTAssertEqual(DirectoryStoreRegistry.key(for: "/"), "/")
    }

    func testRegistryRetainsDirectoryStateAcrossActivation() {
        let registry = DirectoryStoreRegistry()
        let projectA = registry.activate("/tmp/a")
        projectA.sessions = [session(id: "ses_a", directory: "/tmp/a")]

        let projectB = registry.activate("/tmp/b")
        projectB.sessions = [session(id: "ses_b", directory: "/tmp/b")]

        XCTAssertTrue(registry.activate("/tmp/a") === projectA)
        XCTAssertEqual(registry.activeStore.sessions.map(\.id), ["ses_a"])
        XCTAssertTrue(registry.activate("/tmp/b") === projectB)
        XCTAssertEqual(registry.activeStore.sessions.map(\.id), ["ses_b"])
    }

    func testRegistryRestoresSelectionAndTranscriptAcrossDirectoryActivation() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/a")
        let sessionA = session(id: "ses_a", directory: "/tmp/a")
        let messageA = message(id: "msg_a", role: "assistant", text: "Project A", sessionID: sessionA.id)
        registry.activeStore.sessions = [sessionA]
        _ = registry.activeStore.applySessionSelection(sessionA, cachedMessages: [messageA])

        let sessionB = session(id: "ses_b", directory: "/tmp/b")
        let messageB = message(id: "msg_b", role: "assistant", text: "Project B", sessionID: sessionB.id)
        let storeB = registry.activate("/tmp/b")
        storeB.sessions = [sessionB]
        _ = storeB.applySessionSelection(sessionB, cachedMessages: [messageB])

        let restoredA = registry.activate("/tmp/a")

        XCTAssertEqual(restoredA.selectedSession?.id, sessionA.id)
        XCTAssertEqual(restoredA.syncState.messageEnvelopes(forSessionID: sessionA.id), [messageA])
        XCTAssertEqual(storeB.selectedSession?.id, sessionB.id)
        XCTAssertEqual(storeB.syncState.messageEnvelopes(forSessionID: sessionB.id), [messageB])
    }

    func testRegistryFindsSessionAndMessageOwners() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/a")
        let owner = registry.activeStore
        let ownedSession = session(id: "ses_a", directory: "/tmp/a")
        owner.sessions = [ownedSession]
        owner.applyCanonicalMessages(
            [message(id: "msg_a", role: "assistant", text: "A", sessionID: ownedSession.id)],
            forSessionID: ownedSession.id
        )

        XCTAssertTrue(registry.ownerStore(forSessionID: ownedSession.id) === owner)
        XCTAssertEqual(registry.stores(containingMessageID: "msg_a").count, 1)
    }

    func testDirectorySyncFacadeRoutesKnownSessionOnlyToExistingOwner() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/project")
        let owner = registry.activeStore
        let ownedSession = session(id: "ses_project", directory: "/tmp/project")
        owner.sessions = [ownedSession]
        let global = registry.store(for: nil)
        let facade = DirectorySyncFacade(registry: registry, coordinator: EventSyncCoordinator())
        let managed = OpenCodeManagedEvent(
            directory: DirectoryStoreRegistry.globalKey,
            envelope: OpenCodeEventEnvelope(
                type: "session.status",
                properties: OpenCodeEventProperties(sessionID: ownedSession.id)
            ),
            typed: .sessionStatus(sessionID: ownedSession.id, status: "busy")
        )

        let targets = facade.targetStores(
            for: managed,
            selectedSessionID: nil,
            selectedSessionDirectory: nil,
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        )

        XCTAssertEqual(targets.count, 1)
        XCTAssertTrue(targets.first === owner)
        XCTAssertFalse(targets.contains { $0 === global })
    }

    func testDirectorySyncFacadeUsesEventDirectoryStoreWhenSessionHasNoOwner() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/a")
        let eventStore = registry.store(for: "/tmp/b")
        let created = session(id: "ses_b", directory: "/tmp/b")
        let facade = DirectorySyncFacade(registry: registry, coordinator: EventSyncCoordinator())
        let managed = OpenCodeManagedEvent(
            directory: "/tmp/b",
            envelope: OpenCodeEventEnvelope(
                type: "session.created",
                properties: OpenCodeEventProperties(sessionID: created.id)
            ),
            typed: .sessionCreated(created)
        )

        let targets = facade.targetStores(
            for: managed,
            selectedSessionID: nil,
            selectedSessionDirectory: nil,
            effectiveSelectedDirectory: "/tmp/a",
            activeLiveActivitySessionIDs: []
        )

        XCTAssertEqual(targets.count, 1)
        XCTAssertTrue(targets.first === eventStore)
        XCTAssertFalse(targets.contains { $0 === registry.activeStore })
    }

    func testRegistryResetDropsRetainedStoresAndReturnsToGlobal() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/tmp/a")
        let oldStore = registry.activeStore
        oldStore.sessions = [session(id: "ses_a", directory: "/tmp/a")]

        registry.reset()

        XCTAssertEqual(registry.activeKey, DirectoryStoreRegistry.globalKey)
        XCTAssertFalse(registry.activeStore === oldStore)
        XCTAssertEqual(registry.generation, 1)
        XCTAssertTrue(registry.activeStore.sessions.isEmpty)
        XCTAssertNil(registry.existingStore(for: "/tmp/a"))
        XCTAssertFalse(registry.contains(oldStore, forKey: "/tmp/a"))
    }

    private func session(id: String, directory: String?) -> OpenCodeSession {
        OpenCodeSession(id: id, title: "Session", workspaceID: nil, directory: directory, projectID: nil, parentID: nil)
    }

    private func message(id: String, role: String, text: String, sessionID: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text)
            ]
        )
    }

    private func permission(id: String, sessionID: String) -> OpenCodePermission {
        OpenCodePermission(
            id: id,
            sessionID: sessionID,
            permission: "bash",
            patterns: ["bash"],
            always: nil,
            metadata: nil,
            tool: nil
        )
    }

    private func questionRequest(id: String, sessionID: String) -> OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(
            id: id,
            sessionID: sessionID,
            questions: [
                OpenCodeQuestion(
                    question: "Choose",
                    header: "Question",
                    options: [OpenCodeQuestionOption(label: "Yes", description: "Continue")]
                )
            ],
            tool: nil
        )
    }
}
