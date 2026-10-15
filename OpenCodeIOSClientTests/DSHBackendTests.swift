import XCTest
@testable import OpenClient

final class DSHBackendTests: XCTestCase {
    @MainActor
    func testPresetRosterKeepsIdentitiesAndOnlyOffersUsablePrimaryAgents() throws {
        let roster: DSHAgentPresetRoster = try json("""
        {"presets":[
          {"id":"standard","isDefault":true,"name":"Standard Agent","description":"Everyday tasks"},
          {"id":"default","isDefault":false},
          {"id":"broken","isDefault":false,"name":"Unavailable","description":"Still readable","broken":"Missing plugin"}
        ]}
        """).dshDecode()
        let store = ModelConfigurationStore(availableAgents: roster.agents)
        XCTAssertEqual(Set(store.selectableAgents.map(\.name)), ["standard", "default"])
        XCTAssertTrue(store.mentionableAgents.isEmpty)
        XCTAssertEqual(roster.agents[0].displayTitle, "Standard Agent")
        XCTAssertEqual(roster.agents[0].name, "standard")
        XCTAssertEqual(roster.agents[1].displayTitle, "default")
        XCTAssertEqual(store.availableAgents.last?.description, "Still readable")
        XCTAssertTrue(roster.presets[0].isDefault)
    }

    func testPresetProjectionUsesCanonicalSelectionAndPreservesOtherValues() throws {
        var row: DSHSessionSummary = try json("""
        {"sessionId":"s","updatedAt":1000,"running":false,
         "projections":{"values":{"agentPreset":"standard","title":"Chat","modelSelection":{"next":{"provider":"p","model":"m"}}}}}
        """).dshDecode()
        XCTAssertEqual(row.agentPreset, "standard")
        row.applyProjectionEvent(try json(#"{"type":"agent-preset/selected","data":{"agentPreset":"custom"}}"#))
        XCTAssertEqual(row.agentPreset, "custom")
        XCTAssertEqual(row.projections?[dsh: "values"][dsh: "title"].dshString, "Chat")
        row.applyProjectionEvent(try json(#"{"type":"session/title","data":{"title":"Renamed"}}"#))
        XCTAssertEqual(row.agentPreset, "custom")
        XCTAssertEqual(row.projections?[dsh: "values"][dsh: "modelSelection"][dsh: "next"][dsh: "model"].dshString, "m")
        // A replacement baseline is canonical, including a deployment with no preset.
        row.projections = try json(#"{"values":{"agentPreset":null}}"#)
        XCTAssertNil(row.agentPreset)
    }

    func testPermissionProjectionRejectsStaleReadsAndKeepsUnknownDistinct() throws {
        let full = try DSHSessionPermissionProjection(baseline: json(#"{"asOfSeq":20,"values":{"permissions":{"currentValue":"danger-full-access"}}}"#))
        let stale = try DSHSessionPermissionProjection(baseline: json(#"{"asOfSeq":19,"values":{"permissions":{"currentValue":"workspace-write"}}}"#))
        XCTAssertEqual(full.accepting(stale), full)
        let off = DSHSessionPermissionProjection(sequence: 21, value: try json(#"{"currentValue":"workspace-write"}"#))
        XCTAssertEqual(full.accepting(off).state.currentPreset, "workspace-write")
        let custom = DSHSessionPermissionProjection(sequence: 22, value: try json(#"{"currentValue":"custom"}"#))
        XCTAssertEqual(off.accepting(custom).state.currentPreset, "custom")
        let missing = try DSHSessionPermissionProjection(baseline: json(#"{"asOfSeq":23,"values":{}}"#))
        XCTAssertNil(custom.accepting(missing).state.currentPreset)
        XCTAssertThrowsError(try DSHSessionPermissionProjection(baseline: json(#"{"values":{}}"#)))
    }

    func testSessionMergeCanExplicitlyInvalidatePermissionState() throws {
        var existing = OpenCodeSession(id: "s", title: nil, workspaceID: nil, directory: "/w", projectID: "w", parentID: nil)
        existing.permissions = .init(currentPreset: "danger-full-access")
        var incoming = OpenCodeSession(id: "s", title: "New title", workspaceID: nil, directory: "/w", projectID: "w", parentID: nil)
        XCTAssertEqual(existing.merged(with: incoming).permissions?.currentPreset, "danger-full-access")
        incoming.permissions = .init(currentPreset: nil)
        let merged = existing.merged(with: incoming)
        XCTAssertNotNil(merged.permissions)
        XCTAssertNil(merged.permissions?.currentPreset)
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(merged)), merged)
    }

    @MainActor
    func testRunningSessionPermissionSwitchUsesCommandAndCanonicalReadOnly() async throws {
        for preset in [BackendSessionPermissionPreset.fullAccess, .workspaceWrite] {
            var endpoints: [String] = []
            let result = try await DSHSessionPermissionWorkflow.apply(sessionID: "already-running", preset: preset) { endpoint, args in
                endpoints.append(endpoint)
                switch endpoint {
                case "commands/execute":
                    XCTAssertEqual(args["agentId"], .string("already-running"))
                    XCTAssertEqual(args["line"], .string("/permission " + preset.rawValue))
                    XCTAssertEqual(args["submittedAttachments"], .array([]))
                    return try self.json(#"{"result":{"kind":"success"}}"#)
                case "session/projections":
                    XCTAssertEqual(args["request"]?[dsh: "sessionId"].dshString, "already-running")
                    return .object(["asOfSeq": .number(20), "values": .object(["permissions": .object(["currentValue": .string(preset.rawValue)])])])
                default:
                    XCTFail("Permission changes cannot send, cancel, recreate, or change global defaults")
                    return .null
                }
            }
            XCTAssertEqual(try DSHSessionPermissionProjection(baseline: result).state.currentPreset, preset.rawValue)
            XCTAssertEqual(endpoints, ["commands/execute", "session/projections"])
        }
    }

    func testPermissionToggleRequiresBothExplicitCatalogOptions() throws {
        let fullOnly: DSHSessionPermissionCatalog = try json(#"{"options":[{"value":"danger-full-access"},{"value":"auto"}]}"#).dshDecode()
        XCTAssertFalse(fullOnly.supportsToggle)
        XCTAssertTrue(fullOnly.supports(.fullAccess))
        let both: DSHSessionPermissionCatalog = try json(#"{"options":[{"value":"workspace-write"},{"value":"danger-full-access"}]}"#).dshDecode()
        XCTAssertTrue(both.supportsToggle)
        XCTAssertNil(BackendSessionCreation(scope: .init()).permissionPreset)
        XCTAssertNil(NewProjectChatComposerSelection(agentName: nil, modelReference: nil, reasoningVariant: nil).permissionPreset)
    }

    @MainActor
    func testSessionCreationConfirmsExplicitPermissionsBeforeReturning() async throws {
        for preset in [BackendSessionPermissionPreset.workspaceWrite, .fullAccess] {
            var endpoints: [String] = []
            let id = try await DSHSessionCreationWorkflow.create(workspaceID: "workspace", agent: "cordis", permissionPreset: preset) { endpoint, args in
                endpoints.append(endpoint)
                switch endpoint {
                case "permissionPresets/catalog":
                    // Even when the host default is Full Access, an off toggle must write Workspace Write.
                    return try self.json(#"{"options":[{"value":"workspace-write"},{"value":"danger-full-access"}],"defaultPreset":"danger-full-access"}"#)
                case "session/create":
                    XCTAssertEqual(args["request"]?[dsh: "workspaceId"].dshString, "workspace")
                    XCTAssertEqual(args["request"]?[dsh: "agentPreset"].dshString, "cordis")
                    return try self.json(#"{"sessionId":"new-session"}"#)
                case "commands/execute":
                    XCTAssertEqual(args["agentId"], .string("new-session"))
                    XCTAssertEqual(args["line"], .string("/permission " + preset.rawValue))
                    XCTAssertEqual(args["submittedAttachments"], .array([]))
                    return try self.json(#"{"commandId":"command","result":{"kind":"success"}}"#)
                case "session/projections":
                    XCTAssertEqual(args["request"]?[dsh: "sessionId"].dshString, "new-session")
                    return .object(["values": .object(["permissions": .object(["currentValue": .string(preset.rawValue)])])])
                default:
                    XCTFail("Unexpected endpoint: \(endpoint)")
                    throw URLError(.unsupportedURL)
                }
            }
            XCTAssertEqual(id, "new-session")
            XCTAssertEqual(endpoints, ["permissionPresets/catalog", "session/create", "commands/execute", "session/projections"])
        }
    }

    @MainActor
    func testUnavailablePermissionFailsBeforeCreatingSession() async throws {
        var endpoints: [String] = []
        do {
            _ = try await DSHSessionCreationWorkflow.create(workspaceID: "w", agent: nil, permissionPreset: .fullAccess) { endpoint, _ in
                endpoints.append(endpoint)
                return try self.json(#"{"options":[{"value":"workspace-write"}]}"#)
            }
            XCTFail("Unavailable permission must fail")
        } catch DSHSessionCreationWorkflow.Failure.permissionsUnavailable {
            XCTAssertEqual(endpoints, ["permissionPresets/catalog"])
        }
    }

    @MainActor
    func testPermissionSetupFailsClosedOnUnmatchedRejectedOrUnconfirmedCommand() async throws {
        for outcome in ["unmatched", "rejected", "mismatch", "transport"] {
            var endpoints: [String] = []
            do {
                _ = try await DSHSessionCreationWorkflow.create(workspaceID: "w", agent: nil, permissionPreset: .fullAccess) { endpoint, _ in
                    endpoints.append(endpoint)
                    switch endpoint {
                    case "permissionPresets/catalog":
                        return try self.json(#"{"options":[{"value":"danger-full-access"}]}"#)
                    case "session/create":
                        return try self.json(#"{"sessionId":"blank"}"#)
                    case "commands/execute":
                        if outcome == "transport" { throw URLError(.networkConnectionLost) }
                        if outcome == "unmatched" { return .null }
                        return try self.json(outcome == "rejected"
                            ? #"{"result":{"kind":"error","text":"not allowed"}}"#
                            : #"{"result":{"kind":"success"}}"#)
                    case "session/projections":
                        return try self.json(#"{"values":{"permissions":{"currentValue":"workspace-write"}}}"#)
                    default:
                        XCTFail("Unexpected endpoint: \(endpoint)")
                        return .null
                    }
                }
                XCTFail("Unconfirmed permission must never return a ready session")
            } catch DSHSessionCreationWorkflow.Failure.permissionsUnconfirmed(let sessionID) {
                XCTAssertEqual(sessionID, "blank")
                XCTAssertEqual(endpoints.last, outcome == "mismatch" ? "session/projections" : "commands/execute")
                XCTAssertFalse(endpoints.contains("session/prompt"))
            }
        }
    }

    @MainActor
    func testAbsentPermissionIntentPreservesExistingCreationContract() async throws {
        var endpoints: [String] = []
        let id = try await DSHSessionCreationWorkflow.create(workspaceID: "w", agent: nil, permissionPreset: nil) { endpoint, args in
            endpoints.append(endpoint)
            XCTAssertNil(args["request"]?.objectValue?["agentPreset"])
            return try self.json(#"{"sessionId":"ordinary"}"#)
        }
        XCTAssertEqual(id, "ordinary")
        XCTAssertEqual(endpoints, ["session/create"])
    }

    func testDirectorySearchUsesServerHomeAndCanonicalEntryPaths() throws {
        let home = DSHDirectoryListing.searchPath(input: "~/Projects/", home: "/remote/user")
        XCTAssertEqual(home.path, "/remote/user/Projects")
        XCTAssertNil(home.partial)
        let search = DSHDirectoryListing.searchPath(input: "/remote/user/Pro", home: "/other")
        XCTAssertEqual(search.path, "/remote/user")
        XCTAssertEqual(search.partial, "Pro")
        let listing: DSHDirectoryListing = try json(#"{"path":"/remote/user","home":"/remote/user","entries":[{"name":"Projects","path":"/canonical/projects"},{"name":"Documents","path":"/remote/user/Documents"}]}"#).dshDecode()
        XCTAssertEqual(listing.searchResult(partial: "Pro").directories, ["/canonical/projects"])
        XCTAssertNil(listing.searchResult(partial: "Pro").selectedDirectory)
        XCTAssertEqual(listing.searchResult(partial: "Projects").selectedDirectory, "/canonical/projects")
        XCTAssertEqual(listing.searchResult(partial: nil).selectedDirectory, "/remote/user")
    }

    func testWorkspaceBaselineOrderMembershipAndRemoval() throws {
        var state = DSHWorkspaceState()
        _ = try state.apply(json("""
        {"type":"baseline","value":{"items":[
          {"workspaceId":"a","path":"/a","title":"A","sessionIds":[]},
          {"workspaceId":"b","path":"/b","title":"B","sessionIds":["moved"]}
        ],"archivedSessionIds":[],"pinnedSessionIds":[]}}
        """))
        XCTAssertEqual(state.workspace(forSession: "moved", cwd: "/a")?.workspaceId, "b")
        try state.apply(json(#"{"type":"order","workspaceIds":["b","a"]}"#))
        XCTAssertEqual(state.snapshot.projects.map(\.id), ["b", "a"])
        try state.apply(json(#"{"type":"upsert","workspace":{"workspaceId":"b","path":"/b","title":"Renamed","sessionIds":["moved"]}}"#))
        XCTAssertEqual(state.snapshot.projects.map(\.name), ["Renamed", "A"])
        try state.apply(json(#"{"type":"remove","workspaceId":"b"}"#))
        XCTAssertEqual(state.snapshot.projects.map(\.id), ["a"])
        try state.apply(json(#"{"type":"baseline","value":{"items":[],"archivedSessionIds":["moved"],"pinnedSessionIds":[]}}"#))
        XCTAssertTrue(state.snapshot.projects.isEmpty)
        XCTAssertTrue(state.archived.contains("moved"))
    }

    private func json(_ text: String) throws -> DSHJSON {
        try JSONDecoder().decode(DSHJSON.self, from: Data(text.utf8))
    }

    func testConfigurationSeparatesLaunchSecretFromNamespaceAndRejectsEmbeddedCredentials() throws {
        let config = try DSHConfiguration(url: XCTUnwrap(URL(string: "https://host.test:443/?token=secret#fragment")))
        XCTAssertEqual(config.baseURL.absoluteString, "https://host.test:443/")
        XCTAssertEqual(config.launchToken, "secret")
        XCTAssertThrowsError(try DSHConfiguration(url: XCTUnwrap(URL(string: "https://user:password@host.test/"))))
        XCTAssertThrowsError(try DSHConfiguration(url: XCTUnwrap(URL(string: "file:///tmp/"))))
    }

    func testCanonicalUserIdentityUsesPromptReceiptAndHidesInjectedContext() throws {
        var transcript = DSHTranscript(sessionID: "session")
        _ = try transcript.apply(json("""
        {"type":"snapshot","header":{"id":"session"},"cursor":1,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":0,"time":1000,"data":{"id":"host-id","source":{"kind":"user","rpcId":"optimistic-id"},"content":[{"type":"text","text":"Hello"}]}}},
          {"type":"event","event":{"type":"user/message","seq":1,"time":1001,"data":{"id":"context-id","source":{"kind":"runtime-context"},"content":[{"type":"text","text":"Internal context"}]}}}
        ],"assistantStream":{"revision":0}}
        """))
        XCTAssertEqual(transcript.messages.map(\.id), ["optimistic-id"])
        XCTAssertEqual(transcript.messages.first?.parts.first?.text, "Hello")
    }

    func testReasoningAndAnswerStreamThenSettleWithoutDuplicateAssistant() throws {
        var transcript = try emptyTranscript()
        _ = try transcript.apply(json("""
        {"type":"assistant-stream","frame":{"type":"start","attemptId":"attempt","revision":1,"startedAfterSeq":-1,"turn":1,"step":1}}
        """))
        let chunks = [
            #"{"type":"block-start","index":0,"blockType":"reasoning"}"#,
            #"{"type":"reasoning-delta","index":0,"text":"Thinking"}"#,
            #"{"type":"block-start","index":1,"blockType":"text"}"#,
            #"{"type":"text-delta","index":1,"text":"OK"}"#
        ]
        for (index, chunk) in chunks.enumerated() {
            _ = try transcript.apply(json("""
            {"type":"assistant-stream","frame":{"type":"chunk","attemptId":"attempt","revision":\(index + 2),"index":\(index),"time":1000,"chunk":\(chunk)}}
            """))
        }
        let liveID = try XCTUnwrap(transcript.messages.first?.id)
        XCTAssertEqual(transcript.messages.first?.parts.map(\.type), ["reasoning", "text"])
        XCTAssertEqual(transcript.messages.first?.parts.map(\.text), ["Thinking", "OK"])
        XCTAssertNil(transcript.messages.first?.info.time?.completed)
        _ = try transcript.apply(json("""
        {"type":"event","event":{"type":"assistant/message","seq":0,"time":1010,"data":{"turn":1,"step":1,"message":{"id":"server-assistant","content":[{"type":"reasoning","text":"Thinking"},{"type":"text","text":"OK"}]}}}}
        """))
        _ = try transcript.apply(json("""
        {"type":"assistant-stream","frame":{"type":"end","attemptId":"attempt","revision":6,"index":4,"outcome":{"kind":"committed","eventType":"assistant/message","seq":0}}}
        """))
        XCTAssertEqual(transcript.messages.map(\.id), [liveID])
        XCTAssertEqual(transcript.messages.first?.info.time?.completed, 1010)
    }

    func testReconnectBaselineReplacesPartialTextInsteadOfAppendingItAgain() throws {
        var transcript = try emptyTranscript()
        let opening = try json("""
        {"type":"snapshot","header":{"id":"session"},"cursor":-1,"records":[],"hasMore":false,"assistantStream":{"revision":4,"activeAttempt":{"attemptId":"attempt","startedAfterSeq":-1,"turn":1,"step":1,"nextIndex":3,"stream":[
          {"type":"chunk","time":1000,"chunk":{"type":"block-start","index":0,"blockType":"text"}},
          {"type":"text-chunks","time0":1000,"index":0,"dt":[1],"texts":["Hel","lo"]}
        ]}}}
        """)
        _ = try transcript.apply(opening)
        let first = transcript.messages
        XCTAssertEqual(first.first?.parts.first?.text, "Hello")
        let changes = try transcript.apply(opening)
        XCTAssertEqual(transcript.messages, first)
        XCTAssertTrue(changes.isEmpty)
        _ = try transcript.apply(json("""
        {"type":"assistant-stream","frame":{"type":"chunk","attemptId":"attempt","revision":5,"index":3,"time":1002,"chunk":{"type":"text-delta","index":0,"text":"!"}}}
        """))
        XCTAssertEqual(transcript.messages.first?.parts.first?.text, "Hello!")
    }

    func testDurableAndLiveGapsAreRejectedInsteadOfSilentlyDroppingContent() throws {
        var transcript = try emptyTranscript()
        XCTAssertThrowsError(try transcript.apply(json("""
        {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}}
        """)))
        XCTAssertThrowsError(try transcript.apply(json("""
        {"type":"assistant-stream","frame":{"type":"start","attemptId":"attempt","revision":3,"startedAfterSeq":-1,"turn":1,"step":1}}
        """)))
    }

    func testToolResultUpdatesTheOriginalToolCard() throws {
        var transcript = DSHTranscript(sessionID: "session")
        _ = try transcript.apply(json("""
        {"type":"snapshot","header":{"id":"session"},"cursor":1,"records":[
          {"type":"event","event":{"type":"assistant/message","seq":0,"time":1000,"data":{"turn":1,"step":1,"message":{"content":[{"type":"tool-call","id":"call","name":"read","arguments":"{\\"file_path\\":\\"README.md\\"}"}]}}}},
          {"type":"event","event":{"type":"tool/result","seq":1,"time":1001,"data":{"message":{"callId":"call","content":[{"type":"text","text":"File contents"}],"isError":false}}}}
        ],"hasMore":false}
        """))
        let part = try XCTUnwrap(transcript.messages.first?.parts.first)
        XCTAssertEqual(part.type, "tool")
        XCTAssertEqual(part.state?.status, "completed")
        XCTAssertEqual(part.state?.output, "File contents")
    }

    private func emptyTranscript() throws -> DSHTranscript {
        var transcript = DSHTranscript(sessionID: "session")
        _ = try transcript.apply(json("""
        {"type":"snapshot","header":{"id":"session"},"cursor":-1,"records":[],"hasMore":false,"assistantStream":{"revision":0}}
        """))
        return transcript
    }
}
