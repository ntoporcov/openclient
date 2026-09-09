import XCTest
@testable import OpenClient

@MainActor
final class V2ConfigurationTests: XCTestCase {
    override func setUp() async throws { _ = URLProtocol.registerClass(V2ConfigurationURLProtocol.self) }
    override func tearDown() async throws {
        V2ConfigurationURLProtocol.handler = nil
        URLProtocol.unregisterClass(V2ConfigurationURLProtocol.self)
    }

    func testDiscoveryPreservesMethodIDsAndCredentialIdentity() throws {
        let integration = try decode(OpenCodeV2Integration.self, Self.integration)
        XCTAssertEqual(integration.methods.map(\.id), ["key", "oauth:browser-login", "env", "command:cli-login"])
        XCTAssertEqual(integration.connections, [.credential(id: "cred_saved", label: "Work"), .env(name: "PROVIDER_KEY")])
        guard case .oauth(let id, _, _) = integration.methods[1] else { return XCTFail("Expected typed OAuth") }
        XCTAssertEqual(id, "browser-login")
        XCTAssertFalse(integration.methods[2].isSupported)
        XCTAssertFalse(integration.methods[3].isSupported)
        XCTAssertThrowsError(try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"oauth","label":"Missing ID"}"#))
        XCTAssertFalse(try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"future-auth"}"#).isSupported)
    }

    func testTypedAnswersAndExplicitOmissionPreserveWireTypes() throws {
        let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"tenant","type":"string","required":true},{"key":"count","type":"integer"},{"key":"enabled","type":"boolean","required":true},{"key":"regions","type":"multiselect","options":[{"value":"us","label":"United States"}]},{"key":"optional","type":"string","default":"default-value"}]}"#)
        let values: [String: OpenCodeJSONValue] = ["tenant": .string("work"), "count": .number(2), "enabled": .bool(false), "regions": .array([.string("us")]), "optional": .null]
        let answer = try method.answer(values: values)
        XCTAssertEqual(answer["count"], .number(2))
        XCTAssertEqual(answer["enabled"], .bool(false))
        XCTAssertEqual(answer["regions"], .array([.string("us")]))
        XCTAssertNil(answer["optional"])
        var numericDraft = values
        numericDraft["count"] = .string("12")
        XCTAssertEqual(try method.answer(values: numericDraft)["count"], .number(12))
        XCTAssertThrowsError(try method.answer(values: ["tenant": .string("work")]))
        var invalid = values
        invalid["count"] = .number(2.5)
        XCTAssertThrowsError(try method.answer(values: invalid))
        invalid = values
        invalid["enabled"] = .string("false")
        XCTAssertThrowsError(try method.answer(values: invalid))
    }

    func testComplexFormsAreNotSilentlyFlattened() throws {
        for fields in [
            #"[{"key":"conditional","type":"string","when":[{"key":"earlier","op":"eq","value":true}]}]"#,
            #"[{"key":"external","type":"external","url":"https://example.com"}]"#,
            #"[{"key":"multi","type":"multiselect","custom":true,"options":[]}]"#,
            #"[{"key":"choice","type":"string","options":[{"value":42,"label":"Not a string value"}]}]"#,
            #"[{"key":"same","type":"string"},{"key":"same","type":"boolean"}]"#,
        ] {
            let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":\#(fields)}"#)
            XCTAssertFalse(method.isSupported)
            XCTAssertThrowsError(try method.answer(values: [:]))
        }
    }

    func testPluginRuntimeAndPinnedShapesDoNotInventActiveStatus() throws {
        let runtime = try decode(OpenCodeV2Plugin.self, #"{"id":"openclient"}"#)
        XCTAssertNil(runtime.state)
        XCTAssertEqual(runtime.specifier, "openclient")
        let pinned = try decode(OpenCodeV2Plugin.self, #"{"source":{"type":"package","target":"example-plugin","version":"1.2.3"},"features":{"server":true},"state":{"status":"failed","error":"Activation failed","ref":"package"}}"#)
        XCTAssertEqual(pinned.state?.status, "failed")
        XCTAssertEqual(pinned.specifier, "example-plugin")
        let store = PluginStore()
        store.beginLoading(scope: "one")
        store.apply([runtime, pinned], scope: "one")
        XCTAssertEqual(store.pluginCount, 2)
        store.beginLoading(scope: "two")
        store.apply([runtime], scope: "one")
        XCTAssertEqual(store.pluginCount, 0)
        store.reset()
        XCTAssertTrue(store.v2Plugins.isEmpty)
    }

    func testConfigurationEndpointsUseV2LocationAndTypedBodies() async throws {
        let client = makeClient()
        var requests: [String] = []
        V2ConfigurationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let route = "\(request.httpMethod ?? "") \(url.path)"
            requests.append(route)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "location[directory]" }?.value, "/repo with space")
            XCTAssertNil(query.first { $0.name == "directory" })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            switch route {
            case "GET /api/integration": return (200, Self.response("[\(Self.integration)]"))
            case "GET /api/plugin": return (200, Self.response(#"[{"id":"runtime-plugin"}]"#))
            case "POST /api/integration/provider/connect/key":
                let body = try Self.body(request)
                XCTAssertEqual(body["key"], .string("fixture-key"))
                XCTAssertEqual(body["answer"], .object(["enabled": .bool(false)]))
                XCTAssertNil(body["method"])
                XCTAssertNil(body["methodID"])
                return (204, "")
            case "POST /api/integration/provider/connect/oauth":
                let body = try Self.body(request)
                XCTAssertEqual(body["methodID"], .string("browser-login"))
                XCTAssertNil(body["method"])
                XCTAssertNil(body["answer"])
                return (200, Self.response(Self.attempt(mode: "code")))
            case "GET /api/integration/provider/connect/oauth/con_fixture":
                return (200, Self.response(Self.status("pending")))
            case "POST /api/integration/provider/connect/oauth/con_fixture/complete":
                XCTAssertEqual(try Self.body(request), ["code": .string("fixture-code")])
                return (204, "")
            case "DELETE /api/integration/provider/connect/oauth/con_fixture", "DELETE /api/credential/cred_saved": return (204, "")
            default: XCTFail("Unexpected route: \(route)"); return (404, "")
            }
        }
        let directory = "/repo with space"
        let integrations = try await client.v2Integrations(directory: directory)
        XCTAssertEqual(integrations.count, 1)
        let plugins = try await client.v2Plugins(directory: directory)
        XCTAssertNil(plugins.first?.state)
        try await client.v2ConnectKey(integrationID: "provider", key: "fixture-key", answer: ["enabled": .bool(false)], directory: directory)
        _ = try await client.v2BeginOAuth(integrationID: "provider", methodID: "browser-login", answer: [:], directory: directory)
        _ = try await client.v2OAuthStatus(integrationID: "provider", attemptID: "con_fixture", directory: directory)
        try await client.v2CompleteOAuth(integrationID: "provider", attemptID: "con_fixture", code: "fixture-code", directory: directory)
        try await client.v2CancelOAuth(integrationID: "provider", attemptID: "con_fixture", directory: directory)
        try await client.v2RemoveCredential(credentialID: "cred_saved", directory: directory)
        XCTAssertEqual(requests.count, 8)
    }

    func testAutoOAuthPollsStatusWithoutCallingLegacyCallbackOrComplete() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var modelRefreshes = 0
        var routes: [String] = []
        V2ConfigurationURLProtocol.handler = { request in
            let route = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            routes.append(route)
            switch route {
            case "GET /api/integration": return (200, Self.response("[\(Self.integration)]"))
            case "POST /api/integration/provider/connect/oauth": return (200, Self.response(Self.attempt(mode: "auto")))
            case "GET /api/integration/provider/connect/oauth/con_fixture": return (200, Self.response(Self.status("complete")))
            default: XCTFail("Unexpected route \(route)"); return (404, "")
            }
        }
        await coordinator.load(.init(client: makeClient(), directory: "/repo", isCurrent: { true }, refreshModels: { modelRefreshes += 1 }))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[1], key: "", values: [:])
        await store.operationTask?.value
        await store.pollingTask?.value
        XCTAssertTrue(store.didConnect)
        XCTAssertEqual(store.attemptStatus, .complete)
        XCTAssertNil(store.attempt)
        XCTAssertEqual(modelRefreshes, 1)
        XCTAssertEqual(routes.filter { $0.contains("connect/oauth") }.count, 2)
        store.reset()
    }

    func testExpiredAttemptDoesNotPollOrComplete() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        V2ConfigurationURLProtocol.handler = { request in
            if request.url?.path == "/api/integration" { return (200, Self.response("[\(Self.integration)]")) }
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, Self.response(Self.attempt(mode: "auto", expires: 1)))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: { XCTFail("Must not refresh") }))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[1], key: "", values: [:])
        await store.operationTask?.value
        await store.pollingTask?.value
        XCTAssertEqual(store.attemptStatus, .expired)
        XCTAssertFalse(store.didConnect)
        coordinator.complete(code: "do-not-send")
        store.reset()
    }

    func testGenerationResetDropsLateAuthorizationWithoutFollowups() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var count = 0
        V2ConfigurationURLProtocol.handler = { request in
            count += 1
            if request.httpMethod == "GET" { return (200, Self.response("[\(Self.integration)]")) }
            store.reset() // Same URL can reconnect; generation, not URL equality, fences the old attempt.
            return (200, Self.response(Self.attempt(mode: "auto")))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: { XCTFail("Stale refresh") }))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[1], key: "", values: [:])
        let task = store.operationTask
        await task?.value
        XCTAssertNil(store.attempt)
        XCTAssertNil(store.pollingTask)
        XCTAssertTrue(store.integrations.isEmpty)
        XCTAssertEqual(count, 2)
    }

    func testServerSwitchSuppressesCredentialFollowupAndFurtherWrites() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        let current = V2ConfigurationTestValue(true)
        var count = 0
        V2ConfigurationURLProtocol.handler = { request in
            count += 1
            if request.httpMethod == "GET" { return (200, Self.response("[\(Self.integration)]")) }
            XCTAssertEqual(request.url?.path, "/api/credential/cred_saved")
            current.value = false
            return (204, "")
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { current.value }, refreshModels: { XCTFail("Cross-server refresh") }))
        coordinator.removeCredential(integrationID: "provider", credentialID: "cred_saved")
        await store.operationTask?.value
        coordinator.removeCredential(integrationID: "provider", credentialID: "cred_saved")
        XCTAssertEqual(count, 2)
        XCTAssertFalse(store.didConnect)
        store.reset()
    }

    func testCancelAfterServerSwitchIsLocalOnly() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        let current = V2ConfigurationTestValue(true)
        var count = 0
        V2ConfigurationURLProtocol.handler = { request in
            count += 1
            if request.httpMethod == "GET" { return (200, Self.response("[\(Self.integration)]")) }
            return (200, Self.response(Self.attempt(mode: "code")))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { current.value }, refreshModels: {}))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[1], key: "", values: [:])
        await store.operationTask?.value
        XCTAssertNotNil(store.attempt)
        current.value = false
        coordinator.cancelAttempt()
        XCTAssertNil(store.attempt)
        XCTAssertNil(store.pollingTask)
        XCTAssertEqual(count, 2)
    }

    func testEnvironmentConnectionsCannotBeDeletedAndUnsupportedMethodsDoNotWrite() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var count = 0
        V2ConfigurationURLProtocol.handler = { _ in count += 1; return (200, Self.response("[\(Self.integration)]")) }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: {}))
        coordinator.removeCredential(integrationID: "provider", credentialID: "env:PROVIDER_KEY")
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[3], key: "", values: [:])
        await store.operationTask?.value
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(store.errorMessage)
        store.reset()
    }

    func testFailedKeyMutationIsNotRetriedAndDoesNotExposeServerEchoedSecret() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var mutations = 0
        V2ConfigurationURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, Self.response("[\(Self.integration)]")) }
            mutations += 1
            return (401, "sensitive-fixture-key")
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: { XCTFail("Failed mutation cannot refresh") }))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[0], key: "sensitive-fixture-key", values: [:])
        await store.operationTask?.value
        XCTAssertEqual(mutations, 1)
        XCTAssertFalse(store.didConnect)
        XCTAssertFalse(store.errorMessage?.contains("sensitive-fixture-key") == true)
        store.reset()
    }

    func testCodeCompletionAndExplicitCancellationUseAttemptID() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var completions = 0
        var cancellations = 0
        V2ConfigurationURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/api/integration" { return (200, Self.response("[\(Self.integration)]")) }
            if path.hasSuffix("/complete") {
                completions += 1
                XCTAssertEqual(try Self.body(request)["code"], .string("code-fixture"))
                return (204, "")
            }
            if request.httpMethod == "DELETE" {
                cancellations += 1
                XCTAssertEqual(path, "/api/integration/provider/connect/oauth/con_fixture")
                return (204, "")
            }
            return (200, Self.response(Self.attempt(mode: "code")))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: {}))
        let method = store.integrations[0].methods[1]
        coordinator.connect(integrationID: "provider", method: method, key: "", values: [:])
        await store.operationTask?.value
        coordinator.complete(code: "code-fixture")
        await store.operationTask?.value
        XCTAssertTrue(store.didConnect)
        XCTAssertEqual(completions, 1)
        coordinator.connect(integrationID: "provider", method: method, key: "", values: [:])
        await store.operationTask?.value
        coordinator.cancelAttempt()
        await store.operationTask?.value
        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(store.attempt)
        store.reset()
    }

    func testPendingStatusCannotReviveAttemptAfterLocalCancellation() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var statusReads = 0
        V2ConfigurationURLProtocol.handler = { request in
            if request.url?.path == "/api/integration" { return (200, Self.response("[\(Self.integration)]")) }
            if request.httpMethod == "POST" { return (200, Self.response(Self.attempt(mode: "auto"))) }
            statusReads += 1
            store.stopAttempt()
            return (200, Self.response(Self.status("pending")))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: { XCTFail("Cancelled refresh") }))
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[1], key: "", values: [:])
        await store.operationTask?.value
        await store.pollingTask?.value
        XCTAssertEqual(statusReads, 1)
        XCTAssertNil(store.attemptStatus)
        XCTAssertNil(store.attempt)
        store.reset()
    }

    func testObsoleteDiscoverySuccessAndErrorCannotOverwriteNewerRead() async throws {
        for oldStatus in [200, 500] {
            let store = V2ProviderStore()
            let coordinator = V2ConfigurationCoordinator(store: store)
            let context = V2ConfigurationContext(client: makeClient(), directory: "/repo", isCurrent: { true }, refreshModels: {})
            var reads = 0
            V2ConfigurationURLProtocol.handler = { _ in
                reads += 1
                if reads == 1 {
                    let accepted = await coordinator.load(context)
                    XCTAssertTrue(accepted)
                    return (oldStatus, Self.response("[\(Self.integration)]"))
                }
                return (200, Self.response("[\(Self.integration.replacingOccurrences(of: "Example", with: "Newer"))]"))
            }
            store.errorMessage = "OAuth action error"
            let accepted = await coordinator.load(context)
            XCTAssertFalse(accepted)
            XCTAssertEqual(store.integrations.first?.name, "Newer")
            XCTAssertEqual(store.errorMessage, "OAuth action error")
            XCTAssertNil(store.discoveryErrorMessage)
            XCTAssertTrue(store.isReady)
            XCTAssertFalse(store.isLoading)
            store.reset()
        }
    }

    func testObsoleteDiscoveryDeferCannotClearNewerLoadingState() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        let context = V2ConfigurationContext(client: makeClient(), directory: "/repo", isCurrent: { true }, refreshModels: {})
        let firstStarted = V2ConfigurationGate()
        let firstRelease = V2ConfigurationGate()
        let secondStarted = V2ConfigurationGate()
        let secondRelease = V2ConfigurationGate()
        var reads = 0
        V2ConfigurationURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                firstStarted.open()
                await firstRelease.wait()
                return (500, "Old failure")
            }
            secondStarted.open()
            await secondRelease.wait()
            return (200, Self.response("[\(Self.integration)]"))
        }
        let first = Task { await coordinator.load(context) }
        await firstStarted.wait()
        let second = Task { await coordinator.load(context) }
        await secondStarted.wait()
        firstRelease.open()
        let firstAccepted = await first.value
        XCTAssertFalse(firstAccepted)
        XCTAssertTrue(store.isLoading)
        XCTAssertNil(store.discoveryErrorMessage)
        secondRelease.open()
        let secondAccepted = await second.value
        XCTAssertTrue(secondAccepted)
        XCTAssertFalse(store.isLoading)
        store.reset()
    }

    func testMutationCanonicalDiscoverySharesLatestRequestFence() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        var modelRefreshes = 0
        let context = V2ConfigurationContext(client: makeClient(), directory: "/repo", isCurrent: { true }, refreshModels: { modelRefreshes += 1 })
        var reads = 0
        V2ConfigurationURLProtocol.handler = { request in
            if request.httpMethod == "POST" { return (204, "") }
            reads += 1
            if reads == 2 {
                XCTAssertTrue(store.isBusy)
                await coordinator.load(context)
                XCTAssertTrue(store.isBusy, "Discovery must not finish the credential operation")
                return (500, "Obsolete canonical read")
            }
            let data = reads > 2 ? Self.integration.replacingOccurrences(of: "Example", with: "Event refresh") : Self.integration
            return (200, Self.response("[\(data)]"))
        }
        await coordinator.load(context)
        coordinator.connect(integrationID: "provider", method: store.integrations[0].methods[0], key: "fixture", values: [:])
        await store.operationTask?.value
        XCTAssertEqual(store.integrations.first?.name, "Event refresh")
        XCTAssertNil(store.discoveryErrorMessage)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.didConnect)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(modelRefreshes, 0, "Superseded discovery must not launch a follow-up")
        store.reset()
    }

    func testConfigurationEventsCoalesceWithoutResettingOAuthOrOpeningSheet() async throws {
        let model = makeModel()
        defer { model.connectionStore.beginConnecting() }
        let facade = model.configurationsFacade
        var integrationReads = 0
        var pluginReads = 0
        let failDiscovery = V2ConfigurationTestValue(false)
        V2ConfigurationURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/integration":
                integrationReads += 1
                return failDiscovery.value ? (500, "Read error") : (200, Self.response("[\(Self.integration)]"))
            case "/api/plugin":
                pluginReads += 1
                return (200, Self.response(#"[{"id":"plugin"}]"#))
            case "/api/integration/provider/connect/oauth":
                return (200, Self.response(Self.attempt(mode: "code")))
            default: XCTFail("Unexpected configuration follow-up"); return (404, "")
            }
        }
        await facade.loadV2Integrations()
        await facade.loadPluginsForConfiguration()
        facade.v2Coordinator.connect(integrationID: "provider", method: facade.v2ProviderStore.integrations[0].methods[1], key: "", values: [:])
        await facade.v2ProviderStore.operationTask?.value
        let generation = facade.v2ProviderStore.generation
        let attempt = facade.v2ProviderStore.attempt
        for (type, data) in [
            ("integration.updated", "{}"),
            ("integration.connection.updated", #"{"integrationID":"provider"}"#),
            ("credential.updated", "{}"),
            ("credential.switched", #"{"integrationID":"provider","credentialID":null}"#),
            ("plugin.updated", "{}"),
            ("plugin.added", #"{"id":"plugin"}"#),
        ] {
            XCTAssertTrue(facade.consumeV2(try event(type, data: data)))
        }
        await facade.refreshAfterEventReconnect()
        XCTAssertEqual(integrationReads, 2)
        XCTAssertEqual(pluginReads, 2)
        XCTAssertEqual(facade.v2ProviderStore.generation, generation)
        XCTAssertEqual(facade.v2ProviderStore.attempt, attempt)
        XCTAssertEqual(facade.v2ProviderStore.attemptStatus, .pending)
        XCTAssertFalse(facade.isShowingConfigurationsSheet)

        failDiscovery.value = true
        await facade.refreshAfterEventReconnect()
        XCTAssertNotNil(facade.v2ProviderStore.discoveryErrorMessage)
        XCTAssertNil(facade.v2ProviderStore.errorMessage)
        XCTAssertEqual(facade.v2ProviderStore.attemptStatus, .pending)
        XCTAssertEqual(facade.v2ProviderStore.generation, generation)
    }

    func testIrrelevantEventsAndReconnectDoNotHydrateUnusedConfiguration() async throws {
        let model = makeModel()
        defer { model.connectionStore.beginConnecting() }
        let facade = model.configurationsFacade
        V2ConfigurationURLProtocol.handler = { _ in XCTFail("Unused configuration must not load"); return (404, "") }
        XCTAssertFalse(facade.consumeV2(try event("session.execution.started", data: #"{"sessionID":"ses_test"}"#)))
        XCTAssertFalse(facade.consumeV2(try event("integration.connection.updated")))
        XCTAssertFalse(facade.consumeV2(try event("credential.switched", data: #"{"integrationID":"provider"}"#)))
        XCTAssertFalse(facade.consumeV2(try event("plugin.added")))
        XCTAssertTrue(facade.consumeV2(try event("integration.updated")))
        await facade.refreshAfterEventReconnect()
        XCTAssertNil(facade.v2ProviderStore.context)
        XCTAssertFalse(facade.isShowingConfigurationsSheet)
    }

    func testEventRefreshRejectsOtherDirectoriesAndCannotFollowServerSwitch() async throws {
        let model = makeModel()
        defer { model.connectionStore.beginConnecting() }
        model.selectedDirectory = "/repo"
        let facade = model.configurationsFacade
        var reads = 0
        V2ConfigurationURLProtocol.handler = { _ in
            reads += 1
            return (200, Self.response("[\(Self.integration)]"))
        }
        await facade.loadV2Integrations()
        let requestID = facade.v2ProviderStore.discoveryRequestID
        XCTAssertTrue(facade.consumeV2(try event("integration.updated", directory: "/other")))
        XCTAssertEqual(facade.v2ProviderStore.discoveryRequestID, requestID)
        XCTAssertTrue(facade.consumeV2(try event("integration.updated", directory: "/repo")))
        XCTAssertNotEqual(facade.v2ProviderStore.discoveryRequestID, requestID)
        model.connectionStore.beginConnecting()
        await facade.refreshAfterEventReconnect()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(facade.v2ProviderStore.integrations.isEmpty)
        XCTAssertFalse(facade.v2ProviderStore.isLoading)
    }

    func testEventsDuringDiscoveryDropOldResponseAndQueueAnotherRead() async throws {
        let model = makeModel()
        defer { model.connectionStore.beginConnecting() }
        let facade = model.configurationsFacade
        var reads = 0
        V2ConfigurationURLProtocol.handler = { _ in
            reads += 1
            if reads == 2 {
                XCTAssertTrue(facade.consumeV2(try self.event("integration.updated")))
                return (200, Self.response("[\(Self.integration.replacingOccurrences(of: "Example", with: "Obsolete"))]"))
            }
            return (200, Self.response("[\(Self.integration)]"))
        }
        await facade.loadV2Integrations()
        XCTAssertTrue(facade.consumeV2(try event("integration.updated")))
        await facade.refreshAfterEventReconnect()
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(facade.v2ProviderStore.integrations.first?.name, "Example")
        XCTAssertFalse(facade.v2ProviderStore.isLoading)
    }

    func testSharedDebugLoggingRedactsCredentialBodiesAndSensitiveURLValues() throws {
        let body = Data(#"{"key":"fixture-secret","answer":{"tenant":"private"},"url":"https://example.com?code=secret"}"#.utf8)
        for path in ["/auth/provider", "/provider/provider/oauth/authorize", "/api/integration", "/api/integration/provider/connect/key", "/api/integration/provider/connect/oauth/con_attempt/complete", "/api/credential/cred_fixture", "/config", "/global/config"] {
            let url = try XCTUnwrap(URL(string: "https://example.com\(path)"))
            XCTAssertEqual(OpenCodeAPIClient.debugBodyDescription(body, url: url), "<redacted authentication/configuration body>")
        }
        let url = try XCTUnwrap(URL(string: "https://private-user:private-password@example.com/api/integration?code=secret-code&TOKEN=secret-token&api_key=secret-key&location%5Bdirectory%5D=/repo"))
        let description = OpenCodeAPIClient.debugURLDescription(url)
        for secret in ["private-user", "private-password", "secret-code", "secret-token", "secret-key"] {
            XCTAssertFalse(description.contains(secret))
        }
        let redacted = try XCTUnwrap(URLComponents(string: description))
        XCTAssertEqual(redacted.queryItems?.first { $0.name == "location[directory]" }?.value, "/repo")
        XCTAssertTrue(OpenCodeAPIClient.debugBodyDescription(Data(repeating: 65, count: 3_000)).contains("truncated"))
    }

    func testReconnectRefreshesPreviouslyRequestedEmptyProviderCatalog() async throws {
        let model = makeModel()
        defer { model.connectionStore.beginConnecting() }
        let facade = model.configurationsFacade
        var reads: [String: Int] = [:]
        V2ConfigurationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let path = try XCTUnwrap(request.url?.path)
            XCTAssertTrue(["/api/agent", "/api/provider", "/api/model", "/api/model/default", "/api/command"].contains(path))
            reads[path, default: 0] += 1
            return (200, Self.response(path == "/api/model/default" ? "null" : "[]"))
        }
        XCTAssertFalse(facade.isProviderCatalogReady)
        await facade.loadProvidersForConfiguration()
        XCTAssertTrue(facade.isProviderCatalogReady)
        XCTAssertFalse(facade.isLoadingProviders)
        XCTAssertTrue(facade.sortedConnectedProviders.isEmpty)
        for _ in 0..<10 { XCTAssertTrue(facade.consumeV2(try event("credential.updated"))) }
        await facade.refreshAfterEventReconnect()
        XCTAssertEqual(reads.count, 5)
        XCTAssertTrue(reads.values.allSatisfy { $0 == 2 })
        XCTAssertFalse(facade.isShowingConfigurationsSheet)
        XCTAssertNil(facade.v2ProviderStore.context, "An unused integration screen need not hydrate")
    }

    func testInitialDiscoveryFailureDoesNotClaimReadyOrConnected() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        V2ConfigurationURLProtocol.handler = { _ in (503, "Unavailable") }
        let accepted = await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: {}))
        XCTAssertFalse(accepted)
        XCTAssertFalse(store.isReady)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.didConnect)
        XCTAssertNotNil(store.discoveryErrorMessage)
        XCTAssertNil(store.errorMessage)
        store.reset()
    }

    func testActualCopilotPublicAndEnterpriseFieldsAndAnswers() throws {
        let integration = try decode(OpenCodeV2Integration.self, Self.copilotIntegration)
        let method = try XCTUnwrap(integration.methods.first)
        XCTAssertEqual(method.id, "oauth:device")
        XCTAssertTrue(method.isSupported)
        XCTAssertEqual(method.activeFields(values: [:]).map(\.id), ["deploymentType"])
        let publicValues: [String: OpenCodeJSONValue] = ["deploymentType": .string("github.com"), "enterpriseUrl": .string("stale.ghe.com")]
        XCTAssertEqual(method.activeFields(values: publicValues).map(\.id), ["deploymentType"])
        XCTAssertEqual(try method.answer(values: publicValues), ["deploymentType": .string("github.com")])
        let enterpriseValues: [String: OpenCodeJSONValue] = ["deploymentType": .string("enterprise"), "enterpriseUrl": .string("https://company.ghe.com")]
        XCTAssertEqual(method.activeFields(values: enterpriseValues).map(\.id), ["deploymentType", "enterpriseUrl"])
        XCTAssertEqual(try method.answer(values: enterpriseValues), enterpriseValues)
        XCTAssertThrowsError(try method.answer(values: ["deploymentType": .string("enterprise")]))
        XCTAssertThrowsError(try method.answer(values: ["deploymentType": .string("enterprise"), "enterpriseUrl": .string("")]))
        XCTAssertThrowsError(try method.answer(values: ["deploymentType": .string("unlisted")]))
    }

    func testCopilotCoordinatorSendsDeviceIDAndOnlyActiveAnswers() async throws {
        for deployment in ["github.com", "enterprise"] {
            let store = V2ProviderStore()
            let coordinator = V2ConfigurationCoordinator(store: store)
            let posts = V2ConfigurationTestValue(0)
            let expected: [String: OpenCodeJSONValue] = deployment == "enterprise"
                ? ["deploymentType": .string(deployment), "enterpriseUrl": .string("company.ghe.com")]
                : ["deploymentType": .string(deployment)]
            V2ConfigurationURLProtocol.handler = { request in
                switch request.url?.path {
                case "/api/integration": return (200, Self.response("[\(Self.copilotIntegration)]"))
                case "/api/integration/github-copilot/connect/oauth":
                    XCTAssertEqual(request.httpMethod, "POST")
                    let body = try Self.body(request)
                    XCTAssertEqual(body["methodID"], .string("device"))
                    XCTAssertNil(body["method"])
                    XCTAssertEqual(body["answer"], .object(expected))
                    posts.value += 1
                    return (200, Self.response(Self.attempt(mode: "auto")))
                case "/api/integration/github-copilot/connect/oauth/con_fixture":
                    XCTAssertEqual(request.httpMethod, "GET")
                    return (200, Self.response(Self.status("complete")))
                default: XCTFail("Unexpected Copilot request"); return (404, "")
                }
            }
            await coordinator.load(.init(client: makeClient(), directory: "/repo", isCurrent: { true }, refreshModels: {}))
            let method = try XCTUnwrap(store.integrations.first?.methods.first)
            coordinator.connect(integrationID: "github-copilot", method: method, key: "", values: [
                "deploymentType": .string(deployment), "enterpriseUrl": .string("company.ghe.com"),
            ])
            await store.operationTask?.value
            await store.pollingTask?.value
            XCTAssertEqual(posts.value, 1)
            XCTAssertTrue(store.didConnect)
            store.reset()
        }
    }

    func testCopilotIncompleteEnterpriseDoesNotStartOAuth() async throws {
        let store = V2ProviderStore()
        let coordinator = V2ConfigurationCoordinator(store: store)
        V2ConfigurationURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/integration")
            return (200, Self.response("[\(Self.copilotIntegration)]"))
        }
        await coordinator.load(.init(client: makeClient(), directory: nil, isCurrent: { true }, refreshModels: {}))
        let method = try XCTUnwrap(store.integrations.first?.methods.first)
        coordinator.connect(integrationID: "github-copilot", method: method, key: "", values: ["deploymentType": .string("enterprise")])
        await store.operationTask?.value
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.attempt)
        XCTAssertFalse(store.isBusy)
        store.reset()
    }

    func testConditionsUseDefaultsAndOmitInactiveDefaultsAndStaleDescendants() throws {
        let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"enabled","type":"boolean","default":true},{"key":"host","type":"string","default":"default-host","when":[{"key":"enabled","op":"eq","value":true}]},{"key":"child","type":"string","default":"child-default","when":[{"key":"host","op":"neq","value":"disabled"}]}]}"#)
        XCTAssertTrue(method.isSupported)
        XCTAssertEqual(try method.answer(values: [:]), ["enabled": .bool(true), "host": .string("default-host"), "child": .string("child-default")])
        let hidden: [String: OpenCodeJSONValue] = ["enabled": .bool(false), "host": .string("stale-host"), "child": .string("stale-child")]
        XCTAssertEqual(method.activeFields(values: hidden).map(\.id), ["enabled"])
        XCTAssertEqual(try method.answer(values: hidden), ["enabled": .bool(false)])
        XCTAssertEqual(try method.answer(values: ["enabled": .null]), [:])
        XCTAssertEqual(try method.answer(values: ["host": .null, "child": .string("stale-child")]), ["enabled": .bool(true)])
    }

    func testConditionsAreTypedAndConjunctiveWithMultiselectMembership() throws {
        let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"count","type":"number","default":2.5},{"key":"regions","type":"multiselect","options":[{"value":"eu","label":"Europe"},{"value":"us","label":"America"}],"default":["eu"]},{"key":"extra","type":"string","default":"active","when":[{"key":"count","op":"eq","value":2.5},{"key":"regions","op":"eq","value":"eu"},{"key":"regions","op":"neq","value":"us"}]}]}"#)
        XCTAssertTrue(method.isSupported)
        XCTAssertEqual(try method.answer(values: ["count": .string("2.5")])["extra"], .string("active"))
        XCTAssertNil(try method.answer(values: ["count": .number(3)])["extra"])
        XCTAssertNil(try method.answer(values: ["regions": .array([.string("eu"), .string("us")])])["extra"])
        XCTAssertNil(try method.answer(values: ["regions": .null])["extra"])
        let neq = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"optional","type":"boolean"},{"key":"dependent","type":"string","default":"hidden","when":[{"key":"optional","op":"neq","value":true}]}]}"#)
        XCTAssertEqual(try neq.answer(values: [:]), [:], "Missing is false for neq as well as eq")
        XCTAssertEqual(try neq.answer(values: ["optional": .bool(false)])["dependent"], .string("hidden"))
    }

    func testInvalidConditionReferencesOperatorsAndValueTypesStayUnsupported() throws {
        for fields in [
            #"[{"key":"later","type":"string","when":[{"key":"future","op":"eq","value":"x"}]},{"key":"future","type":"string"}]"#,
            #"[{"key":"self","type":"string","when":[{"key":"self","op":"eq","value":"x"}]}]"#,
            #"[{"key":"flag","type":"boolean"},{"key":"text","type":"string","when":[{"key":"flag","op":"eq","value":"true"}]}]"#,
            #"[{"key":"n","type":"integer"},{"key":"text","type":"string","when":[{"key":"n","op":"gt","value":2}]}]"#,
            #"[{"key":"choice","type":"string","options":[]},{"key":"text","type":"string","when":[{"key":"choice","op":"eq","value":"undeclared"}]}]"#,
            #"[{"key":"text","type":"string","when":{"key":"text","op":"eq","value":"x"}}]"#,
        ] {
            let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":\#(fields)}"#)
            XCTAssertFalse(method.isSupported)
            XCTAssertTrue(method.activeFields(values: [:]).isEmpty)
            XCTAssertThrowsError(try method.answer(values: [:]))
        }
    }

    func testBoundsValidateValuesAndDefaultsButAllowCorrectingInvalidDefaults() throws {
        let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"text","type":"string","minLength":2,"maxLength":3},{"key":"number","type":"number","minimum":-1.5,"maximum":2.5},{"key":"integer","type":"integer","minimum":1,"maximum":3,"default":0},{"key":"list","type":"multiselect","minItems":1,"maxItems":2,"options":[{"value":"a","label":"A"},{"value":"b","label":"B"},{"value":"c","label":"C"}]}]}"#)
        XCTAssertTrue(method.isSupported, "Typed invalid defaults must remain editable")
        XCTAssertThrowsError(try method.answer(values: [:]))
        let valid: [String: OpenCodeJSONValue] = ["text": .string("abc"), "number": .number(-1.5), "integer": .number(3), "list": .array([.string("a"), .string("b")])]
        XCTAssertEqual(try method.answer(values: valid), valid)
        for (key, invalid) in [
            ("text", OpenCodeJSONValue.string("a")), ("text", .string("abcd")),
            ("number", .number(-1.6)), ("number", .number(2.6)), ("number", .number(.infinity)),
            ("integer", .number(1.5)), ("integer", .number(4)),
            ("list", .array([])), ("list", .array([.string("a"), .string("b"), .string("c")])),
        ] {
            var values = valid
            values[key] = invalid
            XCTAssertThrowsError(try method.answer(values: values))
        }
    }

    func testStringConstraintsAndEqualityUseJavaScriptUTF16Semantics() throws {
        let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"text","type":"string","minLength":2,"maxLength":2},{"key":"dependent","type":"string","default":"hit","when":[{"key":"text","op":"eq","value":"\u00e9"}]}]}"#)
        XCTAssertEqual(try method.answer(values: ["text": .string("\u{1F600}")])["text"], .string("\u{1F600}"))
        XCTAssertNil(try method.answer(values: ["text": .string("e\u{0301}")])["dependent"], "JS does not normalize string equality")
        XCTAssertThrowsError(try method.answer(values: ["text": .string("\u{00E9}")]))
        let closed = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"choice","type":"string","options":[{"label":"Accent","value":"\u00e9"}]}]}"#)
        XCTAssertThrowsError(try closed.answer(values: ["choice": .string("e\u{0301}")]))
    }

    func testEmptyClosedOptionsRejectStringsAndOptionalMultiselectCanBeUnset() throws {
        let closed = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"choice","type":"string","options":[]}]}"#)
        XCTAssertTrue(closed.isSupported)
        XCTAssertTrue(try XCTUnwrap(closed.fields.first).hasClosedOptions)
        XCTAssertEqual(try closed.answer(values: ["choice": .null]), [:])
        XCTAssertThrowsError(try closed.answer(values: ["choice": .string("anything")]))
        XCTAssertThrowsError(try closed.answer(values: ["choice": .string("")]))
        let multi = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"regions","type":"multiselect","minItems":1,"options":[{"value":"eu","label":"Europe"}],"default":["eu"]},{"key":"child","type":"string","default":"active","when":[{"key":"regions","op":"eq","value":"eu"}]}]}"#)
        XCTAssertNotNil(try multi.answer(values: [:])["child"])
        XCTAssertThrowsError(try multi.answer(values: ["regions": .array([])]))
        XCTAssertEqual(try multi.answer(values: ["regions": .null]), [:])
        XCTAssertEqual(multi.activeFields(values: ["regions": .null]).map(\.id), ["regions"])
    }

    func testRegexFormatsAndUncontractedSecurityMetadataAreNotMisrendered() throws {
        for field in [
            #"{"key":"x","type":"string","pattern":"(?<=x)y"}"#,
            #"{"key":"x","type":"string","format":"uri"}"#,
            #"{"key":"x","type":"string","secret":true}"#,
            #"{"key":"x","type":"string","sensitive":true}"#,
            #"{"key":"x","type":"number","minimum":"1"}"#,
            #"{"key":"x","type":"string","maxLength":-1}"#,
        ] {
            let method = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[\#(field)]}"#)
            XCTAssertFalse(method.isSupported)
            XCTAssertThrowsError(try method.answer(values: ["x": .string("example")]))
        }
    }

    func testProviderPresentationGroupsAndSearchMatchLegacyOrdering() {
        let providers: [OpenCodeV2Integration] = [
            .init(id: "z-provider", name: "Zebra", methods: [], connections: [], metadata: nil),
            .init(id: "google", name: "Google", methods: [], connections: [], metadata: nil),
            .init(id: "openai", name: "OpenAI", methods: [], connections: [.env(name: "OPENAI_API_KEY")], metadata: nil),
            .init(id: "a-provider", name: "alpha", methods: [], connections: [], metadata: nil),
            .init(id: "opencode", name: "OpenCode", methods: [], connections: [], metadata: nil),
        ]
        let groups = ConfigurationsFacade.v2ProviderGroups(providers, query: " \n ")
        XCTAssertEqual(groups.popular.map(\.id), ["opencode", "openai", "google"])
        XCTAssertEqual(groups.other.map(\.id), ["a-provider", "z-provider"])
        XCTAssertEqual(groups.popular[1].connections, [.env(name: "OPENAI_API_KEY")], "Connected providers remain available for credential management")

        let byName = ConfigurationsFacade.v2ProviderGroups(providers, query: " ALPHA ")
        XCTAssertTrue(byName.popular.isEmpty)
        XCTAssertEqual(byName.other.map(\.id), ["a-provider"])
        let byID = ConfigurationsFacade.v2ProviderGroups(providers, query: " Z-PROVIDER\n")
        XCTAssertEqual(byID.other.map(\.id), ["z-provider"])
        let popular = ConfigurationsFacade.v2ProviderGroups(providers, query: " OPEN ")
        XCTAssertEqual(popular.popular.map(\.id), ["opencode", "openai"])
        XCTAssertTrue(popular.other.isEmpty)
        let missing = ConfigurationsFacade.v2ProviderGroups(providers, query: "missing")
        XCTAssertTrue(missing.popular.isEmpty && missing.other.isEmpty)
    }

    func testSingleMethodPresentationRoutesByTypedIdentityWithoutHidingConnections() throws {
        let copilot = try decode(OpenCodeV2Integration.self, Self.copilotIntegration)
        let route = ConfigurationsFacade.v2ProviderRoute(for: copilot)
        XCTAssertEqual(route, .method(integrationID: "github-copilot", methodID: "oauth:device"))
        guard case .method(_, let methodID) = route else { return XCTFail("Expected single-method shortcut") }
        let method = try XCTUnwrap(copilot.methods.first { $0.id == methodID })
        guard case .oauth(let wireID, _, let form) = method else { return XCTFail("OAuth must remain typed") }
        XCTAssertEqual(wireID, "device")
        XCTAssertEqual(form.map(\.id), ["deploymentType", "enterpriseUrl"])

        for connections: [OpenCodeV2IntegrationConnection] in [
            [.credential(id: "cred_work", label: "Work")], [.env(name: "PROVIDER_KEY")], [.unsupported(type: "future")],
        ] {
            let connected = OpenCodeV2Integration(id: copilot.id, name: copilot.name, methods: copilot.methods, connections: connections, metadata: nil)
            XCTAssertEqual(ConfigurationsFacade.v2ProviderRoute(for: connected), .provider(copilot.id))
        }
        for methods: [OpenCodeV2IntegrationMethod] in [[], [.key(label: nil, form: []), method]] {
            let integration = OpenCodeV2Integration(id: "example", name: "Example", methods: methods, connections: [], metadata: nil)
            XCTAssertEqual(ConfigurationsFacade.v2ProviderRoute(for: integration), .provider("example"))
        }
        for method in [OpenCodeV2IntegrationMethod.key(label: nil, form: []), .env(names: ["KEY"]), .command(id: "cli", label: "CLI", command: ["login"]), .unsupported(type: "future")] {
            let integration = OpenCodeV2Integration(id: "example", name: "Example", methods: [method], connections: [], metadata: nil)
            XCTAssertEqual(ConfigurationsFacade.v2ProviderRoute(for: integration), .method(integrationID: "example", methodID: method.id))
        }
    }

    func testAuthenticationSummaryDeduplicatesLabelsWithoutCollapsingMethodIdentity() {
        let methods: [OpenCodeV2IntegrationMethod] = [
            .key(label: nil, form: []),
            .oauth(id: "personal", label: "Browser", form: []),
            .oauth(id: "work", label: "Browser", form: []),
            .env(names: ["KEY"]),
        ]
        XCTAssertEqual(ConfigurationsFacade.providerAuthenticationSummary(methods.map(\.displayTitle)),
                       [String(localized: "API Key"), "Browser", String(localized: "Environment")].formatted())
        XCTAssertEqual(methods.map(\.id), ["key", "oauth:personal", "oauth:work", "env"])
        XCTAssertEqual(OpenCodeV2IntegrationMethod.key(label: "Tenant token", form: []).displayTitle, "Tenant token")
        XCTAssertEqual(OpenCodeV2IntegrationMethod.oauth(id: "empty", label: "", form: []).displayTitle, String(localized: "OAuth"))
        XCTAssertEqual(ConfigurationsFacade.providerAuthenticationSummary([]), "")
    }

    func testConnectActionCapabilityUsesTypedConditionalFormValidation() throws {
        let key = OpenCodeV2IntegrationMethod.key(label: nil, form: [])
        XCTAssertFalse(ConfigurationsFacade.canConnectV2Provider(method: key, key: " \n", values: [:]))
        XCTAssertTrue(ConfigurationsFacade.canConnectV2Provider(method: key, key: "fixture-key", values: [:]))
        let copilot = try decode(OpenCodeV2Integration.self, Self.copilotIntegration)
        let method = try XCTUnwrap(copilot.methods.first)
        XCTAssertFalse(ConfigurationsFacade.canConnectV2Provider(method: method, key: "", values: [:]))
        XCTAssertTrue(ConfigurationsFacade.canConnectV2Provider(method: method, key: "", values: ["deploymentType": .string("github.com")]))
        XCTAssertFalse(ConfigurationsFacade.canConnectV2Provider(method: method, key: "", values: ["deploymentType": .string("enterprise")]))
        XCTAssertTrue(ConfigurationsFacade.canConnectV2Provider(method: method, key: "", values: ["deploymentType": .string("enterprise"), "enterpriseUrl": .string("company.ghe.com")]))
        XCTAssertFalse(ConfigurationsFacade.canConnectV2Provider(method: method, key: "", values: ["deploymentType": .bool(true)]))
        let unsupportedForm = try decode(OpenCodeV2IntegrationMethod.self, #"{"type":"key","form":[{"key":"secret","type":"string","secret":true}]}"#)
        for method in [unsupportedForm, .env(names: ["KEY"]), .command(id: "cli", label: "CLI", command: ["login"]), .unsupported(type: "future")] {
            XCTAssertFalse(ConfigurationsFacade.canConnectV2Provider(method: method, key: "fixture", values: [:]))
        }
    }

    func testRemovalPresentationTargetsExactCredentialAndNeverEnvironment() {
        let connections: [OpenCodeV2IntegrationConnection] = [
            .credential(id: "cred_personal", label: "Account"),
            .credential(id: "cred_work", label: "Account"),
            .env(name: "PROVIDER_KEY"),
            .unsupported(type: "future"),
        ]
        XCTAssertEqual(connections.compactMap(\.removableCredentialID), ["cred_personal", "cred_work"])
        XCTAssertNil(connections[2].removableCredentialID)
        XCTAssertNil(connections[3].removableCredentialID)
        XCTAssertEqual(OpenCodeV2IntegrationConnection.credential(id: "env:opaque-id", label: "Account").removableCredentialID, "env:opaque-id", "Capability comes from the connection type, not its ID spelling")
    }

    func testInjectedConfigurationLoadsCoreCatalogWithoutProviderAdapter() async throws {
        let drafts = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        defer { UserDefaults.standard.set(drafts, forKey: OpenClientStorageKey.messageDraftsByChat) }
        for capabilities: Set<BackendCapability> in [[], [.providerConfiguration]] {
            let factory = ProviderConfigurationTestFactory(capabilities: capabilities)
            let model = AppViewModel(backendFactory: factory)
            model.config = .init(baseURL: "https://v2-configuration.invalid", apiPreference: .legacy)
            V2ConfigurationURLProtocol.handler = { _ in XCTFail("Injected configuration must not use OpenCode HTTP"); return (500, "") }
            await model.connectionFacade.connect()
            defer { model.disconnect() }
            let connection = try model.requireBackendConnection()
            XCTAssertNil(connection.openCodeCompatibility)
            XCTAssertNil(model.connectionStore.apiProfile)
            XCTAssertEqual(model.config.apiPreference, .legacy)
            let facade = model.configurationsFacade
            XCTAssertFalse(facade.supportsProviderManagement, "A capability name without an actual adapter cannot enable management")

            let readsBeforeOpening = factory.catalogScopes.count
            facade.present()
            await facade.loadProvidersForConfigurationIfNeeded()
            XCTAssertTrue(facade.isShowingConfigurationsSheet)
            XCTAssertGreaterThan(factory.catalogScopes.count, readsBeforeOpening)
            let provider = try XCTUnwrap(facade.sortedConnectedProviders.first)
            XCTAssertEqual(provider.id, "injected-provider")
            XCTAssertEqual(facade.modelEntries(for: provider).map(\.model.id), ["injected-model"])
            XCTAssertEqual(facade.selectableAgents.map(\.name), ["injected-agent"])
            XCTAssertFalse(facade.modelVisibilityStates(for: provider).isEmpty)
            XCTAssertFalse(facade.canDisconnectProvider(provider))
            XCTAssertTrue(facade.authMethods(for: provider).isEmpty)

            let readsBeforeReload = factory.catalogScopes.count
            await facade.loadProvidersForConfiguration()
            XCTAssertGreaterThan(factory.catalogScopes.count, readsBeforeReload)
            XCTAssertEqual(facade.sortedConnectedProviders.map(\.id), ["injected-provider"])

            // Restored destinations and direct calls must be safe even without the visibility gate.
            await facade.loadPluginsForConfiguration()
            await facade.loadV2Integrations()
            XCTAssertFalse(facade.pluginStore.isLoading)
            XCTAssertFalse(facade.pluginStore.isReady)
            XCTAssertNil(facade.v2ProviderStore.context)
            XCTAssertFalse(facade.v2ProviderStore.isLoading)
            XCTAssertFalse(facade.isLoadingProviders)
            XCTAssertNil(facade.providerErrorMessage)
        }
    }

    func testInjectedProviderMutationsRejectLegacyPreferenceWithoutAdapter() async throws {
        let drafts = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        defer { UserDefaults.standard.set(drafts, forKey: OpenClientStorageKey.messageDraftsByChat) }
        let factory = ProviderConfigurationTestFactory(capabilities: [.providerConfiguration])
        let model = AppViewModel(backendFactory: factory)
        model.config = .init(baseURL: "https://v2-configuration.invalid", apiPreference: .legacy)
        V2ConfigurationURLProtocol.handler = { _ in XCTFail("Unsupported mutation must not use OpenCode HTTP"); return (500, "") }
        await model.connectionFacade.connect()
        defer { model.disconnect() }
        let facade = model.configurationsFacade
        await facade.loadProvidersForConfiguration()
        let provider = try XCTUnwrap(facade.sortedConnectedProviders.first)
        let reads = factory.catalogScopes.count

        let connected = await facade.connectProviderWithAPIKey(providerID: provider.id, key: "fixture-key")
        let authorization = await facade.authorizeProviderOAuth(providerID: provider.id, methodIndex: 0, inputs: [:])
        let completed = await facade.completeProviderOAuth(providerID: provider.id, methodIndex: 0, code: "fixture-code")
        await facade.disconnectProvider(provider)
        let saved = await facade.saveCustomProvider(OpenCodeCustomProviderDraft())
        XCTAssertFalse(connected)
        XCTAssertNil(authorization)
        XCTAssertFalse(completed)
        XCTAssertFalse(saved)
        XCTAssertEqual(facade.errorMessage, String(localized: "Provider Unavailable"))
        XCTAssertEqual(factory.catalogScopes.count, reads, "Rejected actions must not trigger follow-up reads")
        XCTAssertEqual(facade.sortedConnectedProviders.map(\.id), [provider.id])
        XCTAssertNil(model.modelConfigurationStore.connectingProviderID)
        XCTAssertNil(model.modelConfigurationStore.disconnectingProviderID)
    }

    func testProviderManagementRemainsAvailableForActualOpenCodeAdapters() {
        for profile: OpenCodeAPIProfile in [.legacy, .v2] {
            let model = AppViewModel(backendFactory: ProviderConfigurationTestFactory(capabilities: []))
            let connection = OpenCodeBackendFactory(client: makeClient(), eventManager: model.eventManager)
                .makeConnection(profile: profile, version: "fixture", healthy: true)
            model.backendConnection = connection
            XCTAssertTrue(model.configurationsFacade.supportsProviderManagement)
            connection.close()
            XCTAssertFalse(model.configurationsFacade.supportsProviderManagement)
        }
    }

    private func makeModel() -> AppViewModel {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://v2-configuration.invalid", username: "opencode", password: "pw", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        model.modelConfigurationStore.allProviders = []
        model.isShowingConfigurationsSheet = false
        return model
    }

    private func event(_ type: String, data: String = "{}", directory: String? = nil) throws -> OpenCodeV2ManagedEvent {
        let location = directory.map { #", "location":{"directory":"\#($0)"}"# } ?? ""
        return try decode(OpenCodeV2ManagedEvent.self, #"{"type":"\#(type)","data":\#(data)\#(location)}"#)
    }

    private func makeClient() -> OpenCodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [V2ConfigurationURLProtocol.self]
        return .init(config: .init(baseURL: "https://v2-configuration.invalid", username: "opencode", password: "pw", apiPreference: .v2),
                     session: URLSession(configuration: configuration))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(type, from: Data(json.utf8)) }

    private static let integration = #"{"id":"provider","name":"Example","methods":[{"type":"key"},{"id":"browser-login","type":"oauth","label":"Browser"},{"type":"env","names":["PROVIDER_KEY"]},{"id":"cli-login","type":"command","label":"CLI","command":["example","login"]}],"connections":[{"type":"credential","id":"cred_saved","label":"Work"},{"type":"env","name":"PROVIDER_KEY"}]}"#

    // next-17155 core/src/plugin/provider/github-copilot.ts, also matched by pinned Form.When.
    private static let copilotIntegration = #"{"id":"github-copilot","name":"GitHub Copilot","methods":[{"id":"device","type":"oauth","label":"Login with GitHub Copilot","form":[{"type":"string","key":"deploymentType","title":"Select GitHub deployment type","required":true,"options":[{"label":"GitHub.com","value":"github.com","description":"Public"},{"label":"GitHub Enterprise","value":"enterprise","description":"Data residency or self-hosted"}]},{"type":"string","key":"enterpriseUrl","title":"Enter your GitHub Enterprise URL or domain","placeholder":"company.ghe.com or https://company.ghe.com","required":true,"when":[{"key":"deploymentType","op":"eq","value":"enterprise"}]}]}],"connections":[]}"#

    private static func response(_ data: String) -> String {
        #"{"location":{"directory":"/repo","project":{"id":"project","directory":"/repo","canonical":"/repo"}},"data":\#(data)}"#
    }

    private static func attempt(mode: String, expires: Double = Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000) -> String {
        #"{"attemptID":"con_fixture","url":"https://example.com/authorize","instructions":"Continue in your browser","mode":"\#(mode)","time":{"created":1,"expires":\#(expires)}}"#
    }

    private static func status(_ status: String) -> String {
        #"{"status":"\#(status)","time":{"created":1,"expires":\#(Date().addingTimeInterval(600).timeIntervalSince1970 * 1_000)}}"#
    }

    private static func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
        if let data = request.httpBody { return try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: data) }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: data)
    }
}

@MainActor
private final class ProviderConfigurationTestFactory: BackendFactory, BackendModelsService {
    let capabilities: Set<BackendCapability>
    let core = HomeTestBackend()
    var catalogScopes: [BackendScope] = []

    init(capabilities: Set<BackendCapability>) { self.capabilities = capabilities }

    func connect() async throws -> BackendConnection {
        BackendConnection(descriptor: .init(id: "provider-configuration-test", name: "Provider Test", version: "1"),
                          capabilities: capabilities, projects: core, sessions: core, chat: core, models: self, events: core)
    }

    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        catalogScopes.append(scope)
        return .init(
            agents: [.init(name: "injected-agent", description: nil, mode: "primary", hidden: false, model: nil, variant: nil)],
            providers: [.init(id: "injected-provider", name: "Injected Provider", models: [
                "injected-model": .init(id: "injected-model", providerID: "injected-provider", name: "Injected Model", capabilities: .init(reasoning: false)),
            ])],
            defaults: ["injected-provider": "injected-model"]
        )
    }
}

@MainActor
private final class V2ConfigurationTestValue<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class V2ConfigurationGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class V2ConfigurationURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: V2ConfigurationURLProtocol }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "v2-configuration.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil,
                                                           headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
