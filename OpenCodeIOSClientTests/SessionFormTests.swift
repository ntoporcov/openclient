import XCTest
@testable import OpenClient

@MainActor
final class SessionFormTests: XCTestCase {
    private func form(_ fields: String, id: String = "frm_test", sessionID: String = "ses_test") throws -> BackendForm {
        try JSONDecoder().decode(OpenCodeV2Form.self, from: Data("""
        {"id":"\(id)","sessionID":"\(sessionID)","title":"Settings","fields":\(fields)}
        """.utf8)).backendForm
    }

    func testSharedProviderAndSessionDefaultsAndConditionalResolution() throws {
        let fields = #"[{"key":"enabled","type":"boolean","default":true},{"key":"host","type":"string","default":"default-host","when":[{"key":"enabled","op":"eq","value":true}]},{"key":"child","type":"string","default":"child-default","when":[{"key":"host","op":"neq","value":"disabled"}]}]"#
        let session = try form(fields)
        let provider = try JSONDecoder().decode(OpenCodeV2IntegrationMethod.self, from: Data("{\"type\":\"key\",\"form\":\(fields)}".utf8))
        for values: BackendFormDraft in [[:], ["enabled": .bool(false), "host": .string("stale"), "child": .string("stale")], ["enabled": .null]] {
            XCTAssertEqual(try session.contract.answer(values: values).mapValues(\.jsonValue), try provider.answer(values: values))
            XCTAssertEqual(session.contract.activeFields(values: values), provider.activeFields(values: values))
        }
        XCTAssertEqual(try session.contract.answer(values: ["enabled": .bool(false)]), ["enabled": .boolean(false)])
        XCTAssertEqual(try session.contract.answer(values: ["enabled": .null]), [:])
    }

    func testDuplicateLabelsRemainDistinctWireValuesAndCustomStringsAreNotTrimmed() throws {
        let session = try form(#"[{"key":"choice","type":"string","required":true,"options":[{"value":"a","label":"Same"},{"value":"b","label":"Same"}]},{"key":"free","type":"string","options":[{"value":"known","label":"Known"}],"custom":true}]"#)
        XCTAssertTrue(session.contract.isSupported())
        XCTAssertEqual(try session.contract.answer(values: ["choice": .string("b"), "free": .string("  arbitrary  ")]),
            ["choice": .string("b"), "free": .string("  arbitrary  ")])
        XCTAssertThrowsError(try session.contract.answer(values: ["choice": .string("Same")]))
    }

    func testNativeCustomMultiselectMembershipAndMissingNeq() throws {
        let session = try form(#"[{"key":"regions","type":"multiselect","options":[{"value":"eu","label":"Europe"}],"custom":true,"minItems":1,"maxItems":3},{"key":"count","type":"integer","default":2},{"key":"extra","type":"string","default":"active","when":[{"key":"regions","op":"eq","value":"custom"},{"key":"regions","op":"neq","value":"us"},{"key":"count","op":"eq","value":2}]}]"#)
        XCTAssertTrue(session.contract.isSupported())
        XCTAssertFalse(BackendFormContract(fields: session.fields).isSupported(policy: .provider))
        XCTAssertEqual(try session.contract.answer(values: ["regions": .array([.string("eu"), .string("custom")])])["extra"], .string("active"))
        XCTAssertNil(try session.contract.answer(values: [:])["extra"])
        XCTAssertNil(try session.contract.answer(values: ["regions": .array([.string("custom"), .string("us")])])["extra"])
        XCTAssertThrowsError(try session.contract.answer(values: ["regions": .array([])]))
    }

    func testFiniteNumbersIntegersBoundsAndFalseVersusUnset() throws {
        let session = try form(#"[{"key":"count","type":"integer","required":true,"minimum":1,"maximum":3},{"key":"ratio","type":"number","minimum":-1.5,"maximum":2.5},{"key":"flag","type":"boolean","required":true}]"#)
        XCTAssertEqual(try session.contract.answer(values: ["count": .string("2"), "ratio": .string("0.5"), "flag": .bool(false)]),
            ["count": .number(2), "ratio": .number(0.5), "flag": .boolean(false)])
        for invalid: OpenCodeJSONValue in [.string("2.5"), .number(.infinity), .number(.nan), .number(0), .number(4), .string("wrong")] {
            XCTAssertThrowsError(try session.contract.answer(values: ["count": invalid, "flag": .bool(false)]))
        }
        XCTAssertThrowsError(try session.contract.answer(values: ["count": .number(2), "flag": .null]))
        XCTAssertThrowsError(try session.contract.answer(values: ["count": .number(2), "flag": .string("false")]))
    }

    func testPatternAndFormatRemainNativeWithServerAuthoritativeValidation() throws {
        let session = try form(#"[{"key":"url","type":"string","pattern":"(?<=x)y","format":"uri","minLength":2,"maxLength":20}]"#)
        XCTAssertTrue(session.contract.isSupported())
        XCTAssertFalse(session.contract.isSupported(policy: .provider))
        XCTAssertEqual(session.fields[0].raw["pattern"], .string("(?<=x)y"))
        XCTAssertEqual(try session.contract.answer(values: ["url": .string("not-a-uri")]), ["url": .string("not-a-uri")])
        XCTAssertThrowsError(try session.contract.answer(values: ["url": .string("x")]))
    }

    func testUTF16LengthAndEqualityDoNotNormalizeWireStrings() throws {
        let session = try form(#"[{"key":"text","type":"string","minLength":2,"maxLength":2},{"key":"child","type":"string","default":"hit","when":[{"key":"text","op":"eq","value":"\u00e9"}]}]"#)
        XCTAssertEqual(try session.contract.answer(values: ["text": .string("\u{1F600}")])["text"], .string("\u{1F600}"))
        XCTAssertNil(try session.contract.answer(values: ["text": .string("e\u{0301}")])["child"])
        XCTAssertThrowsError(try session.contract.answer(values: ["text": .string("\u{00E9}")]))
    }

    func testInvalidConditionReferencesAndUnknownMetadataDoNotFlatten() throws {
        for fields in [
            #"[{"key":"x","type":"string","when":[{"key":"later","op":"eq","value":"x"}]},{"key":"later","type":"string"}]"#,
            #"[{"key":"x","type":"boolean"},{"key":"y","type":"string","when":[{"key":"x","op":"eq","value":"true"}]}]"#,
            #"[{"key":"x","type":"boolean"},{"key":"y","type":"string","when":[{"key":"x","op":"gt","value":true}]}]"#,
            #"[{"key":"x","type":"string","secret":true}]"#,
            #"[{"key":"x","type":"string"},{"key":"x","type":"number"}]"#,
        ] {
            XCTAssertFalse(try form(fields).contract.isSupported())
        }
    }

    func testExternalRequiresExplicitTrueAndSafeBrowserURL() throws {
        let session = try form(#"[{"key":"auth","type":"external","url":"https://example.com/authorize?code=private"},{"key":"name","type":"string","default":"Alice"}]"#)
        XCTAssertTrue(session.contract.isSupported())
        XCTAssertNotNil(session.fields[0].browserURL)
        XCTAssertThrowsError(try session.contract.answer(values: [:]))
        XCTAssertThrowsError(try session.contract.answer(values: ["auth": .bool(false)]))
        XCTAssertEqual(try session.contract.answer(values: ["auth": .bool(true)]), ["auth": .boolean(true), "name": .string("Alice")])
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:password@example.com", "relative/path"] {
            let field = BackendFormField(raw: ["key": .string("auth"), "type": .string("external"), "url": .string(url)])
            XCTAssertNil(field.browserURL)
            XCTAssertFalse(field.accepts(.bool(true)))
        }
    }

    func testAnswerAndStateWireTypesAreStrict() throws {
        let answer: BackendFormAnswer = ["text": .string("a"), "count": .number(2), "enabled": .boolean(false), "list": .strings(["a", "custom"])]
        XCTAssertEqual(try JSONDecoder().decode(BackendFormAnswer.self, from: JSONEncoder().encode(answer)), answer)
        for json in [#"{"x":null}"#, #"{"x":{}}"#, #"{"x":[true]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(BackendFormAnswer.self, from: Data(json.utf8)))
        }
        XCTAssertThrowsError(try JSONEncoder().encode(BackendFormValue.number(.infinity)))
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeV2FormState.self, from: Data(#"{"status":"answered"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeV2FormState.self, from: Data(#"{"status":"new-state"}"#.utf8)))
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeV2FormState.self, from: Data(#"{"status":"answered","answer":{"x":false}}"#.utf8)).backendState,
            .answered(["x": .boolean(false)]))
    }

    func testNativeHydrationDoesNotAlsoCreateLegacyQuestionsAndRejectsStaleLists() throws {
        let owner = DirectoryStore()
        let dto = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"frm_1","sessionID":"ses_1","title":"Settings","fields":[{"key":"x","type":"string","required":true}]}"#.utf8))
        owner.applyV2SessionInteractions(sessionID: "ses_1", permissions: [], forms: [dto], permissionRevisionAtRequestStart: 0, questionRevisionAtRequestStart: 0)
        XCTAssertEqual(owner.sessionFormStore.forms.count, 1)
        XCTAssertTrue(owner.syncState.questionsBySessionID["ses_1"]?.isEmpty ?? true)
        let revision = owner.questionRevision
        owner.removeV2Question(id: "frm_1", sessionID: "ses_1")
        owner.applyV2SessionInteractions(sessionID: "ses_1", permissions: [], forms: [dto], permissionRevisionAtRequestStart: owner.permissionRevision, questionRevisionAtRequestStart: revision)
        XCTAssertTrue(owner.sessionFormStore.forms.isEmpty)
        owner.sessionFormStore.upsert(dto.backendForm)
        XCTAssertTrue(owner.sessionFormStore.forms.isEmpty, "A late created event cannot resurrect settlement")
    }

    func testValidationErrorRetainsDraftAndDoesNotPublishSubmittedSecret() async throws {
        let f = try form(#"[{"key":"x","type":"string","required":true,"format":"uri"}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        store.setValue(.string("secret-value"), fieldID: "x", for: f.key)
        let service = FormFakeService()
        service.replyError = .invalidAnswer(message: "Expected URI for form field: secret-value")
        await SessionFormCoordinator(store: store).submit(context(service, f))
        XCTAssertEqual(store.state(for: f.key).draft["x"], .string("secret-value"))
        XCTAssertEqual(store.state(for: f.key).phase, .ready)
        XCTAssertNotNil(store.state(for: f.key).errorMessage)
        XCTAssertFalse(store.state(for: f.key).errorMessage?.contains("secret-value") == true)
        XCTAssertEqual(service.stateReads, 0)
        service.replyError = .invalidAnswer(message: "secret-value")
        await SessionFormCoordinator(store: store).submit(context(service, f))
        XCTAssertFalse(store.state(for: f.key).errorMessage?.contains("secret-value") == true)
    }

    func testInvalidLocalAnswerShowsErrorWithoutSendingAndCanStillCancel() async throws {
        let f = try form(#"[{"key":"count","type":"integer","required":true}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        store.setValue(.string("1.5"), fieldID: "count", for: f.key)
        let service = FormFakeService()
        let ctx = context(service, f)
        let coordinator = SessionFormCoordinator(store: store)
        await coordinator.submit(ctx)
        XCTAssertTrue(service.replies.isEmpty)
        XCTAssertNotNil(store.state(for: f.key).errorMessage)
        XCTAssertEqual(store.state(for: f.key).draft["count"], .string("1.5"))
        await coordinator.cancel(ctx)
        XCTAssertEqual(service.cancelCount, 1)
        XCTAssertNil(store.forms[f.key])
    }

    func testOperationTokenIsBoundToConnectionScopeAndGeneration() throws {
        let f = try form(#"[{"key":"x","type":"string"}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        let reference = BackendFormReference(key: f.key, directory: "/one", workspaceID: "wrk_one")
        let connectionID = UUID()
        let generation = store.generation
        let token = try XCTUnwrap(store.begin(.checking, reference: reference, connectionID: connectionID))
        XCTAssertTrue(store.owns(token, reference: reference, connectionID: connectionID, generation: generation))
        XCTAssertFalse(store.owns(token, reference: reference, connectionID: UUID(), generation: generation))
        XCTAssertFalse(store.owns(token, reference: .init(key: f.key, directory: "/two", workspaceID: "wrk_two"), connectionID: connectionID, generation: generation))
        store.reset()
        store.upsert(f)
        XCTAssertFalse(store.owns(token, reference: reference, connectionID: connectionID, generation: generation))
    }

    func testDuplicateSubmitAndCancelAreBlockedWhileReplyIsInFlight() async throws {
        let f = try form(#"[{"key":"x","type":"boolean","default":false}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        let service = FormFakeService()
        let gate = FormRequestGate()
        service.replyGate = gate
        let coordinator = SessionFormCoordinator(store: store)
        let ctx = context(service, f)
        let task = Task { await coordinator.submit(ctx) }
        await gate.waitUntilStarted()
        await coordinator.submit(ctx)
        await coordinator.cancel(ctx)
        XCTAssertEqual(service.replies.count, 1)
        XCTAssertEqual(service.cancelCount, 0)
        gate.resume()
        await task.value
        XCTAssertNil(store.forms[f.key])
    }

    func testExternalSettlementWinsBeforeHTTPErrorAndStaleRead() async throws {
        for reply in [true, false] {
            let f = try form(#"[{"key":"x","type":"boolean","default":true}]"#)
            let store = SessionFormStore()
            store.upsert(f)
            let service = FormFakeService()
            let gate = FormRequestGate()
            if reply { service.replyGate = gate; service.replyError = .invalidAnswer(message: "private") }
            else { service.stateGate = gate }
            let coordinator = SessionFormCoordinator(store: store)
            let ctx = context(service, f)
            let task = Task {
                if reply { await coordinator.submit(ctx) } else { await coordinator.refresh(ctx) }
            }
            await gate.waitUntilStarted()
            store.settle(f.key)
            gate.resume()
            await task.value
            XCTAssertNil(store.forms[f.key])
            XCTAssertNil(store.editing[f.key])
        }
    }

    func testConflictAndUncertainAdmissionReconcileWithoutResending() async throws {
        for error: BackendSessionFormsError in [.alreadySettled, .uncertain] {
            let f = try form(#"[{"key":"x","type":"boolean","default":true}]"#)
            let store = SessionFormStore()
            store.upsert(f)
            let service = FormFakeService()
            service.replyError = error
            service.serverState = .answered(["x": .boolean(false)])
            await SessionFormCoordinator(store: store).submit(context(service, f))
            XCTAssertEqual(service.replies.count, 1)
            XCTAssertEqual(service.stateReads, 1)
            XCTAssertNil(store.forms[f.key])
        }
    }

    func testUnauthorizedAndFailedStateReadRemainUnknownUntilExplicitRecovery() async throws {
        let f = try form(#"[{"key":"x","type":"string","default":"draft"}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        let service = FormFakeService()
        service.replyError = .unauthorized
        service.stateError = .unauthorized
        let coordinator = SessionFormCoordinator(store: store)
        let ctx = context(service, f)
        await coordinator.submit(ctx)
        XCTAssertEqual(store.state(for: f.key).phase, .uncertain)
        await coordinator.submit(ctx)
        await coordinator.cancel(ctx)
        XCTAssertEqual(service.replies.count, 1)
        XCTAssertEqual(service.cancelCount, 0)
        XCTAssertNotNil(store.forms[f.key])
        service.stateError = nil
        await coordinator.refresh(ctx)
        XCTAssertEqual(store.state(for: f.key).phase, .ready)
        XCTAssertEqual(service.replies.count, 1)
    }

    func testReconnectAndStaleScopeCannotApplyOldCompletion() async throws {
        let f = try form(#"[{"key":"x","type":"boolean","default":true}]"#)
        for reset in [true, false] {
            let store = SessionFormStore()
            store.upsert(f)
            let service = FormFakeService()
            let gate = FormRequestGate()
            service.replyGate = gate
            let lifetime = FormContextLifetime()
            let ctx = context(service, f, isCurrent: { lifetime.current })
            let task = Task { await SessionFormCoordinator(store: store).submit(ctx) }
            await gate.waitUntilStarted()
            if reset {
                store.reset()
                store.upsert(f)
                store.setValue(.bool(false), fieldID: "x", for: f.key)
            } else { lifetime.current = false }
            gate.resume()
            await task.value
            XCTAssertNotNil(store.forms[f.key])
            XCTAssertEqual(store.state(for: f.key).phase, reset ? .ready : .uncertain)
            if reset { XCTAssertEqual(store.state(for: f.key).draft["x"], .bool(false)) }
        }
    }

    func testNavigationToAnotherFormDoesNotRedirectReplyOrClearItsDraft() async throws {
        let first = try form(#"[{"key":"x","type":"string","default":"first"}]"#)
        let other = try form(#"[{"key":"x","type":"string"}]"#, id: "frm_other", sessionID: "ses_other")
        let store = SessionFormStore()
        store.upsert(first)
        store.upsert(other)
        let service = FormFakeService()
        let gate = FormRequestGate()
        service.replyGate = gate
        let ctx = context(service, first)
        let task = Task { await SessionFormCoordinator(store: store).submit(ctx) }
        await gate.waitUntilStarted()
        store.setValue(.string("other draft"), fieldID: "x", for: other.key)
        gate.resume()
        await task.value
        XCTAssertNil(store.forms[first.key])
        XCTAssertEqual(store.state(for: other.key).draft["x"], .string("other draft"))
        XCTAssertEqual(service.replies.first?.0.key, first.key)
    }

    func testUnavailableFormDoesNotDeleteOtherSessionState() async throws {
        let f = try form(#"[{"key":"x","type":"boolean","default":true}]"#)
        let store = SessionFormStore()
        store.upsert(f)
        let service = FormFakeService()
        service.replyError = .unavailable
        await SessionFormCoordinator(store: store).submit(context(service, f))
        XCTAssertNotNil(store.forms[f.key])
        XCTAssertEqual(store.state(for: f.key).phase, .unavailable)
    }

    func testSessionTreeProjectionIncludesChildrenButNeverGlobalElicitations() throws {
        let root = OpenCodeSession(id: "ses_root", title: nil, workspaceID: nil, directory: "/repo", projectID: "p", parentID: nil)
        let child = OpenCodeSession(id: "ses_child", title: nil, workspaceID: nil, directory: "/repo", projectID: "p", parentID: root.id)
        let fields = #"[{"key":"x","type":"boolean"}]"#
        let forms = try [form(fields, id: "frm_root", sessionID: root.id),
                         form(fields, id: "frm_child", sessionID: child.id),
                         form(fields, id: "frm_global", sessionID: "global"),
                         form(fields, id: "frm_other", sessionID: "ses_other")]
        XCTAssertEqual(SessionInteractionStore.forms(forSessionTreeRootID: root.id, sessions: [root, child], forms: forms).map(\.id),
            ["frm_child", "frm_root"])
        XCTAssertTrue(SessionInteractionStore.forms(forSessionTreeRootID: "global", sessions: [root, child], forms: forms).isEmpty)
    }

    func testInjectedFormEventsNeedNoOpenCodeDTOOrCompatibilityClient() async throws {
        let f = try form(#"[{"key":"x","type":"boolean","default":true}]"#)
        let owner = DirectoryStore()
        owner.applySessionFormEvent(.created(f))
        let service = FormFakeService()
        let gate = FormRequestGate()
        service.replyGate = gate
        let ctx = context(service, f)
        let task = Task { await SessionFormCoordinator(store: owner.sessionFormStore).submit(ctx) }
        await gate.waitUntilStarted()
        owner.applySessionFormEvent(.answered(f.key, ["x": .boolean(false)]))
        gate.resume()
        await task.value
        XCTAssertTrue(owner.sessionFormStore.forms.isEmpty)
        XCTAssertTrue(owner.sessionFormStore.editing.isEmpty)
        XCTAssertTrue(owner.syncState.questionsBySessionID.isEmpty)
        owner.applySessionFormEvent(.created(f))
        XCTAssertTrue(owner.sessionFormStore.forms.isEmpty)
    }

    func testOpenCodeServiceUsesTypedReplyAndOriginLocationForGlobalForms() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionFormURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SessionFormURLProtocol.handler = nil }
        let service = OpenCodeSessionFormsService(client: OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "https://forms.invalid", password: "test"), session: session))
        let reference = BackendFormReference(key: .init(sessionID: "global", formID: "frm_test"), directory: "/origin", workspaceID: "wrk_origin")
        SessionFormURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query, [URLQueryItem(name: "location[directory]", value: "/origin")])
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            switch url.path {
            case "/api/form":
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, #"{"location":{"directory":"/canonical","workspaceID":"wrk_canonical","project":{"id":"global","directory":"/canonical","canonical":"/canonical"}},"data":[{"id":"frm_g","sessionID":"global","title":"Global","fields":[{"key":"v","type":"boolean"}]},{"id":"frm_s","sessionID":"ses_real","title":"Session","fields":[{"key":"v","type":"boolean"}]}]}"#)
            case "/api/session/global/form":
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, #"{"data":[]}"#)
            case "/api/session/global/form/frm_test":
                if request.httpMethod == "DELETE" {
                    XCTAssertTrue(SessionFormURLProtocol.body(request).isEmpty)
                    return (204, "")
                }
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, #"{"data":{"id":"frm_test","sessionID":"global","title":"External","fields":[{"key":"ack","type":"external","url":"https://external.invalid"}],"state":{"status":"answered","answer":{"enabled":false,"count":2,"tags":["a","custom"],"ack":true}}}}"#)
            case "/api/session/global/form/frm_test/reply":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try JSONDecoder().decode([String: BackendFormAnswer].self, from: SessionFormURLProtocol.body(request))
                XCTAssertEqual(body, ["answer": ["enabled": .boolean(false), "count": .number(2), "tags": .strings(["a", "custom"]), "ack": .boolean(true)]])
                return (204, "")
            default: XCTFail("Unexpected form endpoint"); return (404, "")
            }
        }
        let pending = try await service.pendingForms(sessionID: "global", scope: .init(directory: "/origin", workspaceID: "wrk_origin"))
        let inventory = try await service.pendingGlobalForms(scope: .init(directory: "/origin", workspaceID: "wrk_origin"))
        XCTAssertEqual(inventory.location, .init(directory: "/canonical", workspaceID: nil))
        XCTAssertEqual(inventory.forms.map(\.id), ["frm_g"])
        XCTAssertTrue(pending.isEmpty)
        let definition = try await service.readForm(reference)
        XCTAssertEqual(definition.sessionID, "global")
        let answer: BackendFormAnswer = ["enabled": .boolean(false), "count": .number(2), "tags": .strings(["a", "custom"]), "ack": .boolean(true)]
        try await service.reply(reference, answer: answer)
        let state = try await service.readState(reference)
        XCTAssertEqual(state, .answered(answer))
        try await service.cancel(reference)
    }

    func testOpenCodeServiceTranslatesTaggedValidationAndConflictErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionFormURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); SessionFormURLProtocol.handler = nil }
        let service = OpenCodeSessionFormsService(client: OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "https://forms.invalid", password: "test"), session: session))
        let reference = BackendFormReference(key: .init(sessionID: "ses_test", formID: "frm_test"))
        SessionFormURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/reply") == true {
                return (400, #"{"_tag":"FormInvalidAnswerError","id":"frm_test","message":"Expected URI for form field: x"}"#)
            }
            return (409, #"{"_tag":"FormAlreadySettledError","id":"frm_test","message":"Form already settled"}"#)
        }
        do { try await service.reply(reference, answer: ["x": .string("bad")]); XCTFail("Expected validation failure") }
        catch { XCTAssertEqual(error as? BackendSessionFormsError, .invalidAnswer(message: "Expected URI for form field: x")) }
        do { try await service.cancel(reference); XCTFail("Expected conflict") }
        catch { XCTAssertEqual(error as? BackendSessionFormsError, .alreadySettled) }
    }

    private func context(_ service: FormFakeService, _ form: BackendForm,
                         isCurrent: @escaping @MainActor () -> Bool = { true }) -> SessionFormContext {
        .init(connectionID: UUID(), service: service,
            reference: .init(key: form.key, directory: "/repo", workspaceID: "wrk_test"), isCurrent: isCurrent)
    }
}

@MainActor
private final class FormContextLifetime { var current = true }

@MainActor
private final class FormRequestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var isStarted = false

    func suspend() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isStarted = true
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { started = $0 }
    }

    func resume() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class FormFakeService: BackendSessionFormsService {
    var replies: [(BackendFormReference, BackendFormAnswer)] = []
    var cancelCount = 0
    var stateReads = 0
    var serverState: BackendFormState = .pending
    var replyError: BackendSessionFormsError?
    var stateError: BackendSessionFormsError?
    var replyGate: FormRequestGate?
    var stateGate: FormRequestGate?

    func pendingForms(sessionID: String, scope: BackendScope) async throws -> [BackendForm] { [] }
    func readForm(_ reference: BackendFormReference) async throws -> BackendForm { throw BackendSessionFormsError.unavailable }
    func readState(_ reference: BackendFormReference) async throws -> BackendFormState {
        stateReads += 1
        await stateGate?.suspend()
        if let stateError { throw stateError }
        return serverState
    }
    func reply(_ reference: BackendFormReference, answer: BackendFormAnswer) async throws {
        replies.append((reference, answer))
        await replyGate?.suspend()
        if let replyError { throw replyError }
    }
    func cancel(_ reference: BackendFormReference) async throws { cancelCount += 1 }
}

private final class SessionFormURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}

    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
