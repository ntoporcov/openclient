import XCTest
@testable import OpenClient

final class OpenCodeAPIClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
    }

    func testProbeV2RequiresVersionAndPID() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"healthy":true,"version":"0.0.0-next-17055","pid":24062}"#.utf8)
            )
        }

        let result = try await client.probeV2()

        XCTAssertEqual(result, .available(OpenCodeV2Health(healthy: true, version: "0.0.0-next-17055", pid: 24062)))
    }

    func testProbeV2UsesInfoWhenHealthRouteWasRemoved() async throws {
        let client = makeProbeClient()
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            if request.url?.path == "/api/health" {
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            XCTAssertEqual(request.url?.path, "/api/info")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"version":"2.0.16","pid":24062,"urls":["http://127.0.0.1:4096"],"paths":{"tmp":"/tmp"}}"#.utf8)
            )
        }

        let result = try await client.probeV2()

        XCTAssertEqual(result, .available(OpenCodeV2Health(healthy: true, version: "2.0.16", pid: 24062)))
        XCTAssertEqual(paths, ["/api/health", "/api/info"])
    }

    func testProbeV2InfoDoesNotHideAuthenticationFailure() async throws {
        MockURLProtocol.requestHandler = { request in
            let status = request.url?.path == "/api/health" ? 404 : 401
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }

        do {
            _ = try await makeProbeClient().probeV2()
            XCTFail("Expected authentication failure")
        } catch let OpenCodeAPIError.httpError(statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        }
    }

    func testProbeV2DoesNotFallbackAfterHealthServerFailure() async throws {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("starting".utf8))
        }

        do {
            _ = try await makeProbeClient().probeV2()
            XCTFail("Expected server failure")
        } catch let OpenCodeAPIError.httpError(statusCode, body) {
            XCTAssertEqual(statusCode, 503)
            XCTAssertEqual(body, "starting")
        }
        XCTAssertEqual(paths, ["/api/health"])
    }

    func testProbeV2InfoSurfacesServerAndDecodeFailures() async throws {
        for (status, body) in [(500, #"{"version":"2.0.16","pid":1,"urls":[]}"#), (200, #"{"version":"2.0.16","pid":"invalid","urls":[]}"#)] {
            var paths: [String] = []
            MockURLProtocol.requestHandler = { request in
                paths.append(try XCTUnwrap(request.url?.path))
                if request.url?.path == "/api/health" {
                    return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                }
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }

            do {
                _ = try await makeProbeClient().probeV2()
                XCTFail("Expected strict info failure")
            } catch let OpenCodeAPIError.httpError(statusCode, _) {
                XCTAssertEqual(statusCode, 500)
            } catch is DecodingError {
                XCTAssertEqual(status, 200)
            }
            XCTAssertEqual(paths, ["/api/health", "/api/info"])
        }
    }

    func testProbeV2TreatsLegacyHealthShapeAsUnavailable() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"healthy":true}"#.utf8)
            )
        }

        let result = try await client.probeV2()
        XCTAssertEqual(result, .unavailable)
    }

    func testProbeV2TreatsMissingRouteAndHTMLFallbackAsUnavailable() async throws {
        let client = makeProbeClient()
        var returnsHTML = false
        MockURLProtocol.requestHandler = { request in
            if returnsHTML {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!,
                    Data("<!doctype html><html></html>".utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        let missingRouteResult = try await client.probeV2()
        XCTAssertEqual(missingRouteResult, .unavailable)
        returnsHTML = true
        let htmlResult = try await client.probeV2()
        XCTAssertEqual(htmlResult, .unavailable)
    }

    func testProbeV2DoesNotFallbackAfterAuthenticationFailure() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        do {
            _ = try await client.probeV2()
            XCTFail("Expected authentication failure")
        } catch let OpenCodeAPIError.httpError(statusCode, _) {
            XCTAssertEqual(statusCode, 401)
        }
    }

    func testBootstrapV2ProjectsUsesLocationAndProjectSandboxesWithoutRemovedDirectoryRoute() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")

            let body: String
            switch url.path {
            case "/api/project":
                body = #"[{"id":"project-1","canonical":"/repo","vcs":"git","name":"OpenClient","sandboxes":["/repo-worktree"],"time":{"created":1,"updated":2}},{"id":"global","canonical":"/","name":"Global","sandboxes":[],"time":{"created":1,"updated":2}}]"#
            case "/api/location":
                body = #"{"directory":"/repo/subdir","project":{"id":"project-1","directory":"/repo","canonical":"/repo"}}"#
            default:
                XCTFail("Unexpected v2 project request: \(url.path)")
                body = "[]"
            }
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let bootstrap = try await client.bootstrapV2Projects()

        XCTAssertEqual(bootstrap.projects.map(\.id), ["project-1", "global"])
        XCTAssertEqual(bootstrap.projects[0].worktree, "/repo")
        XCTAssertEqual(bootstrap.projects[0].sandboxes, ["/repo-worktree"])
        XCTAssertEqual(bootstrap.projects[1].worktree, "/")
        XCTAssertEqual(bootstrap.currentProject?.id, "project-1")
        XCTAssertEqual(bootstrap.selectedDirectory, "/repo/subdir")
    }

    func testListV2SessionsUsesProjectLocationAndCursorPagination() async throws {
        let client = makeProbeClient()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)
            let queryItems = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            if requestCount == 1 {
                XCTAssertEqual(queryItems, [
                    URLQueryItem(name: "directory", value: "/repo"),
                    URLQueryItem(name: "parentID", value: "null"),
                    URLQueryItem(name: "order", value: "desc"),
                    URLQueryItem(name: "limit", value: "1"),
                ])
            } else {
                XCTAssertEqual(queryItems, [
                    URLQueryItem(name: "cursor", value: "next-page"),
                    URLQueryItem(name: "limit", value: "1"),
                ])
            }
            let body = requestCount == 1
                ? #"{"data":[{"id":"ses_1","projectID":"project-1","title":"First","location":{"directory":"/repo"},"time":{"created":1000,"updated":2000}}],"cursor":{"previous":"previous-page","next":"next-page"}}"#
                : #"{"data":[{"id":"ses_2","projectID":"project-1","title":"Second","location":{"directory":"/repo","workspaceID":"wrk_1"},"time":{"created":3000,"updated":4000,"archived":5000}}],"cursor":{"previous":"previous-page","next":null}}"#
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let first = try await client.listV2Sessions(projectID: "project-1", directory: "/repo", limit: 1)
        let second = try await client.listV2Sessions(projectID: "project-1", directory: "/repo", cursor: XCTUnwrap(first.nextCursor), limit: 1)

        XCTAssertEqual(first.sessions.map(\.id), ["ses_1"])
        XCTAssertEqual(first.sessions[0].directory, "/repo")
        XCTAssertEqual(first.sessions[0].time?.updated, 2000)
        XCTAssertEqual(first.nextCursor, "next-page")
        XCTAssertEqual(second.sessions.map(\.id), ["ses_2"])
        XCTAssertEqual(second.sessions[0].workspaceID, "wrk_1")
        XCTAssertEqual(second.sessions[0].time?.archived, 5000)
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(requestCount, 3, "Lookahead must not consume the next session")
    }

    func testV2SessionShortPagesPreserveScopeAndRootFilterWithoutProbing() async throws {
        for directory in [nil, "", "/", "/repo"] as [String?] {
            for roots in [false, true] {
                var requests = 0
                MockURLProtocol.requestHandler = { request in
                    requests += 1
                    var expected = [URLQueryItem(name: directory?.isEmpty == false ? "directory" : "project", value: directory?.isEmpty == false ? directory : "global")]
                    if roots { expected.append(.init(name: "parentID", value: "null")) }
                    expected += [.init(name: "order", value: "desc"), .init(name: "limit", value: "50"), .init(name: "workspace", value: "wrk_1")]
                    XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, expected)
                    return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2SessionPage(count: 2, next: "terminal-cursor"))
                }
                let page = try await makeProbeClient().listV2Sessions(projectID: "global", directory: directory, workspaceID: "wrk_1", roots: roots)
                XCTAssertEqual(page.sessions.map(\.id), ["ses_0", "ses_1"])
                XCTAssertNil(page.nextCursor)
                XCTAssertEqual(requests, 1)
            }
        }
    }

    func testV2SessionFullPageChecksTerminalAndLimitPlusOneWithoutLosingSessions() async throws {
        for limit in [1, 50, 100, 101] {
            for hasMore in [false, true] {
                var requests = 0
                let opaque = "opaque-search-project-workspace+/=?&"
                MockURLProtocol.requestHandler = { request in
                    requests += 1
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(request.url?.path, "/api/session")
                    let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                    if requests == 1 {
                        XCTAssertEqual(query, [.init(name: "project", value: "p"), .init(name: "parentID", value: "null"), .init(name: "order", value: "desc"), .init(name: "limit", value: String(limit))])
                    } else {
                        XCTAssertEqual(query, [.init(name: "cursor", value: opaque), .init(name: "limit", value: requests == 2 ? "1" : String(limit))])
                    }
                    let body = requests == 1 ? Self.v2SessionPage(count: limit, next: opaque)
                        : Self.v2SessionPage(count: hasMore ? 1 : 0, next: nil, start: limit)
                    return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
                }
                let client = makeProbeClient()
                let first = try await client.listV2Sessions(projectID: "p", directory: nil, limit: limit)
                XCTAssertEqual(requests, 2)
                XCTAssertEqual(first.sessions.map(\.id), (0 ..< limit).map { "ses_\($0)" })
                XCTAssertEqual(first.nextCursor, hasMore ? opaque : nil)
                if hasMore {
                    let next = try await client.listV2Sessions(projectID: "changed", directory: "/changed", cursor: XCTUnwrap(first.nextCursor), limit: limit, workspaceID: "changed", roots: false)
                    XCTAssertEqual(next.sessions.map(\.id), ["ses_\(limit)"])
                    XCTAssertNil(next.nextCursor)
                    XCTAssertEqual(requests, 3)
                }
            }
        }
    }

    func testV2SessionEmptyRepeatedAndMissingCursorPagesDoNotProbe() async throws {
        for (count, next) in [(0, "different"), (2, "requested"), (2, "")] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "cursor", value: "requested"), .init(name: "limit", value: "2")])
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2SessionPage(count: count, next: next.isEmpty ? nil : next))
            }
            let page = try await makeProbeClient().listV2Sessions(projectID: "p", directory: "/repo", cursor: "requested", limit: 2)
            XCTAssertEqual(page.sessions.count, count)
            XCTAssertNil(page.nextCursor)
            XCTAssertEqual(requests, 1)
        }
    }

    func testV2SessionLookaheadFailurePreservesUnknownHistoryAndCancellationPropagates() async throws {
        for failure in ["http", "decode", "network", "cancel"] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    .init(name: "cursor", value: requests == 1 ? "opaque-with-search" : "older"), .init(name: "limit", value: "1"),
                ])
                if requests == 2, failure == "network" { throw URLError(.timedOut) }
                if requests == 2, failure == "cancel" { throw URLError(.cancelled) }
                let body = requests == 1 ? Self.v2SessionPage(count: 1, next: "older") : Data("invalid JSON".utf8)
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: requests == 2 && failure == "http" ? 503 : 200, httpVersion: nil, headerFields: nil)!, body)
            }
            do {
                let page = try await makeProbeClient().listV2Sessions(projectID: "ignored", directory: "/ignored", cursor: "opaque-with-search", limit: 1, workspaceID: "ignored")
                XCTAssertNotEqual(failure, "cancel")
                XCTAssertEqual(page.sessions.map(\.id), ["ses_0"])
                XCTAssertEqual(page.nextCursor, "older")
            } catch {
                XCTAssertEqual(failure, "cancel")
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
            XCTAssertEqual(requests, 2)
        }
    }

    func testV2SessionTaskCancellationDuringLookaheadDoesNotReturnPage() async throws {
        let probeStarted = expectation(description: "session lookahead started")
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        MockURLProtocol.requestHandler = { request in
            if request.url?.query?.contains("cursor=") == true {
                probeStarted.fulfill()
                guard releaseProbe.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2SessionPage(count: 1, next: "older"))
        }
        let client = makeProbeClient()
        let task = Task { try await client.listV2Sessions(projectID: "p", directory: nil, limit: 1) }
        defer { task.cancel() }
        await fulfillment(of: [probeStarted], timeout: 5)
        task.cancel()
        releaseProbe.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled lookahead must not return a successful session page")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private static func v2SessionPage(count: Int, next: String?, start: Int = 0) -> Data {
        let sessions: [[String: Any]] = (start ..< start + count).map {
            ["id": "ses_\($0)", "projectID": "p", "location": ["directory": "/repo"], "time": ["created": 1, "updated": 2]]
        }
        var cursor = ["previous": "never-follow-previous"]
        cursor["next"] = next
        return try! JSONSerialization.data(withJSONObject: ["data": sessions, "cursor": cursor])
    }

    func testCreateV2SessionUsesNestedLocationAndNormalizesResponse() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["title"] as? String, "New session")
            XCTAssertEqual((json["location"] as? [String: Any])?["directory"] as? String, "/repo")
            XCTAssertEqual((json["location"] as? [String: Any])?["workspaceID"] as? String, "wrk_1")
            XCTAssertEqual(json["agent"] as? String, "build")
            XCTAssertEqual(json["model"] as? [String: String], ["providerID": "openai", "id": "gpt-5", "variant": "high"])
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"data":{"id":"ses_created","projectID":"project-1","title":"New session","location":{"directory":"/repo","workspaceID":"wrk_1"},"time":{"created":1000,"updated":1000}}}"#.utf8)
            )
        }

        let session = try await client.createV2Session(title: "  New session  ", directory: "/repo", workspaceID: "wrk_1", agent: "build", model: .init(providerID: "openai", modelID: "gpt-5"), variant: "high")

        XCTAssertEqual(session.id, "ses_created")
        XCTAssertEqual(session.projectID, "project-1")
        XCTAssertEqual(session.directory, "/repo")
        XCTAssertEqual(session.title, "New session")
        XCTAssertEqual(session.workspaceID, "wrk_1")
    }

    func testListV2MessagesProjectsTimelineIntoChronologicalCanonicalMessages() async throws {
        let client = makeProbeClient()
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/message")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "limit", value: "200"),
            ])
            let body = #"{"data":[{"id":"msg_assistant","type":"assistant","agent":"build","model":{"id":"gpt-5","providerID":"openai","variant":"high"},"time":{"created":2000,"completed":3000},"finish":"stop","tokens":{"input":10,"output":20,"reasoning":5,"cache":{"read":2,"write":1}},"content":[{"type":"reasoning","text":"Think"},{"type":"tool","id":"call_1","name":"read","state":{"status":"completed","input":{"filePath":"README.md"},"content":[{"type":"text","text":"contents"}]}},{"type":"text","text":"Answer"}]},{"id":"msg_user","type":"user","time":{"created":1000},"text":"Question"}],"cursor":{"previous":"newer","next":"older"}}"#
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let page = try await client.listV2Messages(sessionID: "ses_1")

        XCTAssertEqual(page.messages.map(\.id), ["msg_user", "msg_assistant"])
        XCTAssertEqual(page.messages[0].info.sessionID, "ses_1")
        XCTAssertEqual(page.messages[0].parts.first?.text, "Question")
        XCTAssertEqual(page.messages[1].parts.map(\.type), ["reasoning", "tool", "text"])
        XCTAssertEqual(page.messages[1].parts.map(\.id), ["msg_assistant:v2:reasoning:0", "call_1", "msg_assistant:v2:text:0"])
        XCTAssertEqual(page.messages[1].parts[1].state?.output, "contents")
        XCTAssertEqual(page.messages[1].info.model?.modelID, "gpt-5")
        XCTAssertEqual(page.messages[1].info.tokens?.computedTotal, 38)
        XCTAssertNil(page.olderCursor, "A short terminal page can still contain both runtime cursors")
        XCTAssertEqual(requests, 1, "Ordinary short chats must not trigger lookahead")
    }

    func testV2ContextRecordsRetainTypesForCardsInHistoryAndSingleMessageHydration() async throws {
        let client = makeProbeClient()
        for kind in OpenCodeTimelineContextType.allCases {
            let record: [String: Any] = [
                "id": "msg_context", "type": kind.rawValue,
                "text": "Instructions from: /repo/AGENTS.md\n# Context", "time": ["created": 1000]
            ]
            MockURLProtocol.requestHandler = { request in
                let isSingle = request.url?.lastPathComponent == "msg_context"
                let payload: Any = isSingle ? record as Any : [record] as Any
                let data = try JSONSerialization.data(withJSONObject: ["data": payload])
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"])!, data)
            }
            let page = try await client.listV2Messages(sessionID: "ses_1")
            let single = try await client.getV2Message(sessionID: "ses_1", messageID: "msg_context")
            XCTAssertEqual(page.messages, [single])
            let part = try XCTUnwrap(single.parts.first)
            XCTAssertEqual(part.type, kind.rawValue)
            XCTAssertEqual(part.timelineContextType, kind)
            XCTAssertTrue(part.synthetic == true)
            XCTAssertFalse(OpenCodeToolActivityPolicy.isToolCall(part))
            XCTAssertTrue(MessageBubbleMessageVisibilityPolicy.shouldDisplay(single,
                showsToolCalls: false, showsReasoningBlocks: false))
            let cached = try JSONDecoder().decode(OpenCodeMessageEnvelope.self,
                from: JSONEncoder().encode(single))
            XCTAssertEqual(cached.parts.first?.timelineContextType, kind)
        }
    }

    func testListV2MessagesCursorRequestOmitsOrderAndStopsOnEmptyPage() async throws {
        let client = makeProbeClient()
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "cursor", value: "older"),
                URLQueryItem(name: "limit", value: "200"),
            ])
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"data":[],"cursor":{"previous":null,"next":"same"}}"#.utf8)
            )
        }

        let page = try await client.listV2Messages(sessionID: "ses_1", cursor: "older")

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertNil(page.olderCursor)
        XCTAssertEqual(requests, 1)
    }

    func testListV2MessagesFullPageProbesOnceWithoutConsumingOpaqueContinuation() async throws {
        let opaqueCursor = "opaque+/= next?&"
        for hasOlder in [false, true] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/session/ses_1/message")
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                if requests == 1 {
                    XCTAssertEqual(query, [.init(name: "order", value: "desc"), .init(name: "limit", value: "200")])
                } else {
                    XCTAssertEqual(query, [.init(name: "cursor", value: opaqueCursor), .init(name: "limit", value: "1")])
                }
                XCTAssertLessThanOrEqual(requests, 2, "Lookahead must not recurse")
                let probeBody = hasOlder
                    ? Data(#"{"data":[{"id":"msg_older","type":"user","text":"Older"}],"cursor":{"previous":"unused","next":"do-not-follow-probe-cursor"}}"#.utf8)
                    : Self.v2HistoryPage(count: 0, next: "do-not-follow-probe-cursor")
                let body = requests == 1
                    ? Self.v2HistoryPage(count: 200, next: opaqueCursor)
                    : probeBody
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }

            let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1")

            XCTAssertEqual(requests, 2)
            XCTAssertEqual(page.messages.map(\.id), (0 ..< 200).map { "msg_\($0)" })
            XCTAssertEqual(page.olderCursor, hasOlder ? opaqueCursor : nil)
        }
    }

    func testListV2MessagesContinuationSkipsProbeForShortRepeatedAndMissingCursors() async throws {
        for (count, next) in [(1, "older"), (2, "requested"), (2, "")] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    .init(name: "cursor", value: "requested"), .init(name: "limit", value: "2"),
                ])
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2HistoryPage(count: count, next: next.isEmpty ? nil : next))
            }

            let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1", cursor: "requested", limit: 2)

            XCTAssertEqual(requests, 1)
            XCTAssertEqual(page.messages.count, count)
            XCTAssertNil(page.olderCursor)
        }
    }

    func testListV2MessagesLookaheadFailurePreservesValidPageAndOriginalCursor() async throws {
        for failure in ["http", "decode", "network"] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    .init(name: "cursor", value: requests == 1 ? "requested" : "older"),
                    .init(name: "limit", value: "1"),
                ])
                if requests == 2, failure == "network" { throw URLError(.timedOut) }
                let body = requests == 2 ? Data("invalid JSON".utf8) : Self.v2HistoryPage(count: 1, next: "older")
                let status = requests == 2 && failure == "http" ? 503 : 200
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!, body)
            }

            let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1", cursor: "requested", limit: 1)

            XCTAssertEqual(requests, 2)
            XCTAssertEqual(page.messages.map(\.id), ["msg_0"])
            XCTAssertEqual(page.olderCursor, "older", failure)
        }
    }

    func testListV2MessagesLookaheadPropagatesURLCancellation() async throws {
        var requests = 0
        MockURLProtocol.requestHandler = { request in
            requests += 1
            if requests == 2 { throw URLError(.cancelled) }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2HistoryPage(count: 1, next: "older"))
        }
        do {
            _ = try await makeProbeClient().listV2Messages(sessionID: "ses_1", limit: 1)
            XCTFail("Lookahead cancellation must not become a successful partial read")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(requests, 2)
    }

    func testListV2MessagesCancelledTaskDuringLookaheadDoesNotReturnValidPage() async throws {
        let probeStarted = expectation(description: "lookahead started")
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        MockURLProtocol.requestHandler = { request in
            if request.url?.query?.contains("cursor=") == true {
                probeStarted.fulfill()
                guard releaseProbe.wait(timeout: .now() + 5) == .success else { throw URLError(.timedOut) }
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Self.v2HistoryPage(count: 1, next: "older"))
        }
        let client = makeProbeClient()
        let task = Task { try await client.listV2Messages(sessionID: "ses_1", limit: 1) }
        defer { task.cancel() }
        await fulfillment(of: [probeStarted], timeout: 5)
        task.cancel()
        releaseProbe.signal()
        do {
            _ = try await task.value
            XCTFail("A cancelled task must not return the valid first page")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private static func v2HistoryPage(count: Int, next: String?) -> Data {
        let records = (0 ..< count).reversed().map { index in
            ["id": "msg_\(index)", "type": "user", "text": "Message \(index)"]
        }
        var cursor = ["previous": "never-follow-previous"]
        cursor["next"] = next
        return try! JSONSerialization.data(withJSONObject: ["data": records, "cursor": cursor])
    }

    func testAdmitV2TextPromptUsesPromptEndpointAndDecodesReceipt() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/prompt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["id"] as? String, "msg_client")
            XCTAssertEqual(json["text"] as? String, "Hello v2")
            XCTAssertEqual(json["resume"] as? Bool, true)
            XCTAssertNil(json["parts"])
            XCTAssertNil(json["model"])
            XCTAssertNil(json["agent"])
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(#"{"data":{"id":"msg_client","sessionID":"ses_1","time":{"created":1234},"type":"user","payload":{"text":"Hello v2","files":[],"agents":[],"skills":[],"metadata":{}},"delivery":"steer"}}"#.utf8)
            )
        }

        let receipt = try await client.admitV2TextPrompt(sessionID: "ses_1", messageID: "msg_client", text: "Hello v2")

        XCTAssertEqual(receipt, OpenCodeV2PromptReceipt(id: "msg_client", sessionID: "ses_1", timeCreated: 1234, delivery: "steer"))
    }

    func testWaitForV2SessionUsesWaitEndpoint() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/experimental/session/ses_1/wait")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(Self.requestBodyData(request))
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.waitForV2Session(sessionID: "ses_1")
    }

    func testInterruptV2SessionUsesInterruptEndpoint() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/interrupt")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(Self.requestBodyData(request))
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"interrupted":true}"#.utf8)
            )
        }

        try await client.interruptV2Session(sessionID: "ses_1")
    }

    func testV2EventURLUsesNativeEventEndpoint() throws {
        let client = makeProbeClient()

        XCTAssertEqual(try XCTUnwrap(client.v2EventURL()).path, "/api/event")
        XCTAssertNil(try XCTUnwrap(URLComponents(url: XCTUnwrap(client.v2EventURL()), resolvingAgainstBaseURL: false)).query)
    }

    func testListV2PendingInteractionsNormalizesLocationEnvelopes() async throws {
        let client = makeProbeClient()
        var requestedPaths: [String] = []
        MockURLProtocol.requestHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            let body: String
            switch request.url?.path {
            case "/api/permission/request":
                body = #"{"location":{"directory":"/tmp/project","project":{"id":"project","directory":"/tmp/project","canonical":"/tmp/project"}},"data":[{"id":"per_1","sessionID":"ses_1","action":"bash","resources":["git status*"],"save":["git status*"],"metadata":{"command":"git status --short"},"source":{"type":"tool","messageID":"msg_1","id":"call_1"}}]}"#
            case "/api/form":
                body = #"{"location":{"directory":"/tmp/project"},"data":[{"id":"frm_1","sessionID":"ses_1","title":"Confirm","fields":[{"key":"proceed","type":"string","description":"Proceed?","required":true,"options":[{"value":"yes","label":"Yes","description":"Continue"}]}]}]}"#
            default:
                XCTFail("Unexpected path \(request.url?.path ?? "nil")")
                body = "{}"
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(body.utf8)
            )
        }

        let loadedPermissions = try await client.listV2PendingPermissions(directory: "/tmp/project")
        let loadedQuestions = try await client.listV2PendingQuestions(directory: "/tmp/project")

        XCTAssertEqual(Set(requestedPaths), ["/api/permission/request", "/api/form"])
        XCTAssertEqual(loadedPermissions.first?.permission, "bash")
        XCTAssertEqual(loadedPermissions.first?.patterns, ["git status*"])
        XCTAssertEqual(loadedPermissions.first?.callID, "call_1")
        XCTAssertEqual(loadedQuestions.first?.questions.first?.question, "Proceed?")
        XCTAssertEqual(loadedQuestions.first?.id, "frm_1")
        XCTAssertNil(loadedQuestions.first?.tool)
    }

    func testListV2PendingFormsOnlyFallsBackToOldRouteWhenNewRouteIsUnavailable() async throws {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            paths.append(try XCTUnwrap(request.url?.path))
            if request.url?.path == "/api/form" {
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = #"{"location":{"directory":"/tmp/project"},"data":[]}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let forms = try await makeProbeClient().listV2PendingForms(directory: "/tmp/project")

        XCTAssertTrue(forms.isEmpty)
        XCTAssertEqual(paths, ["/api/form", "/api/form/request"])
    }

    func testV2InteractionRepliesUseSessionScopedEndpoints() async throws {
        let client = makeProbeClient()
        var requests: [(String, Data?)] = []
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "GET" {
                XCTAssertEqual(request.url?.path, "/api/session/ses_1/form/frm_1")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"id":"frm_1","sessionID":"ses_1","title":"Confirm","fields":[{"key":"proceed","type":"string","required":true,"options":[{"value":"yes","label":"Yes"}]}]}}"#.utf8)
                )
            }
            requests.append((request.url?.path ?? "", Self.requestBodyData(request)))
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.replyToV2Permission(sessionID: "ses_1", requestID: "per_1", reply: "once")
        try await client.replyToV2Question(sessionID: "ses_1", requestID: "frm_1", answers: [["Yes"]])
        try await client.rejectV2Question(sessionID: "ses_1", requestID: "frm_1")

        XCTAssertEqual(requests.map(\.0), [
            "/api/session/ses_1/permission/per_1/reply",
            "/api/session/ses_1/form/frm_1/reply",
            "/api/session/ses_1/form/frm_1",
        ])
        let permissionBody = try XCTUnwrap(requests[0].1)
        let permissionJSON = try JSONSerialization.jsonObject(with: permissionBody) as? [String: Any]
        XCTAssertEqual(permissionJSON?["decision"] as? String, "once")
        XCTAssertNil(permissionJSON?["reply"])
        let questionBody = try XCTUnwrap(requests[1].1)
        XCTAssertEqual(try (JSONSerialization.jsonObject(with: questionBody) as? [String: Any])?["answer"] as? [String: String], ["proceed": "yes"])
        XCTAssertNil(requests[2].1)
    }

    func testV2ProbeAcceptsProcesslessRuntimeAndRejectsMalformedSuccesses() async throws {
        let client = makeProbeClient()
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(#"{"healthy":true,"version":"next","pid":0}"#.utf8))
        }
        let health = try await client.probeV2()
        XCTAssertEqual(health, .available(.init(healthy: true, version: "next", pid: 0)))

        for body in ["{}", "[]", "not JSON", #"{"healthy":true,"pid":1}"#,
                     #"{"healthy":false,"version":"next","pid":1}"#,
                     #"{"healthy":true,"version":"next","pid":-1}"#,
                     #"{"healthy":true,"version":"next","pid":"1"}"#] {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            do {
                _ = try await client.probeV2()
                XCTFail("Malformed v2 health must fail rather than select legacy: \(body)")
            } catch {}
        }
    }

    func testV2ProbePreservesForbiddenAndServerFailures() async throws {
        for status in [403, 500, 503] {
            MockURLProtocol.requestHandler = { request in
                (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!, Data("failure".utf8))
            }
            do {
                _ = try await makeProbeClient().probeV2()
                XCTFail("Expected HTTP failure")
            } catch let OpenCodeAPIError.httpError(code, body) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(body, "failure")
            }
        }
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await makeProbeClient().probeV2()
            XCTFail("Expected transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    func testV2LocationUsesDeepObjectScopeAndPreservesServerBasePath() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://example.com/relay/server", username: "opencode", password: "pw"), session: URLSession(configuration: configuration))
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/relay/server/api/location")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "location[directory]", value: "/repo with spaces/a&b"),
            ])
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"directory":"/repo with spaces/a&b","workspaceID":"wrk_1","project":{"id":"p","directory":"/repo with spaces","canonical":"/repo with spaces"}}"#.utf8))
        }
        let location = try await client.getV2Location(directory: "/repo with spaces/a&b", workspaceID: "wrk_1")
        XCTAssertEqual(location.workspaceID, "wrk_1")
        XCTAssertEqual(location.project.directory, "/repo with spaces")
    }

    func testV2ProjectScopeAndRepeatedSessionCursor() async throws {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            if requestCount == 1 {
                XCTAssertEqual(query, [URLQueryItem(name: "project", value: "p"), URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "limit", value: "1")])
            } else {
                XCTAssertEqual(query, [URLQueryItem(name: "cursor", value: "same"), URLQueryItem(name: "limit", value: "1")])
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":[{"id":"ses_1","projectID":"p","location":{"directory":"/repo"},"time":{"created":1,"updated":2},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}],"cursor":{"next":"same"}}"#.utf8))
        }
        let client = makeProbeClient()
        let first = try await client.listV2Sessions(projectID: "p", directory: nil, limit: 1, roots: false)
        let second = try await client.listV2Sessions(projectID: "p", directory: nil, cursor: first.nextCursor, limit: 1, roots: false)
        XCTAssertEqual(first.nextCursor, "same")
        XCTAssertNil(second.nextCursor)
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertEqual(requestCount, 3, "Repeated continuation does not trigger another probe")
    }

    func testV2RejectsOutOfContractLimitsWithoutNetworking() async throws {
        MockURLProtocol.requestHandler = { _ in
            XCTFail("Invalid limits must not be sent")
            throw URLError(.badURL)
        }
        let client = makeProbeClient()
        for limit in [0, -1, 201] {
            do {
                _ = try await client.listV2Messages(sessionID: "ses_1", limit: limit)
                XCTFail("Expected invalid limit")
            } catch OpenCodeV2TransportError.invalidPageLimit {}
        }
        do {
            _ = try await client.listV2Sessions(projectID: "p", directory: nil, limit: 0)
            XCTFail("Expected invalid limit")
        } catch OpenCodeV2TransportError.invalidPageLimit {}
    }

    func testV2ProjectedAttachmentsUseMaterializedDataEvenWithRemoteSource() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"data":[{"id":"msg_1","type":"user","time":{"created":1},"text":"Inspect","files":[{"data":"aGVsbG8=","mime":"text/plain","name":"notes.txt","source":{"type":"inline"}},{"data":"aW1hZ2U=","mime":"image/png","source":{"type":"uri","uri":"file:///private/server/image.png"}}]}],"cursor":{}}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1")
        let parts = try XCTUnwrap(page.messages.first?.parts)
        XCTAssertEqual(parts.map(\.id), ["msg_1:v2:text:0", "msg_1:v2:file:0", "msg_1:v2:file:1"])
        XCTAssertEqual(parts[1].filename, "notes.txt")
        XCTAssertEqual(parts[1].url, "data:text/plain;base64,aGVsbG8=")
        XCTAssertEqual(parts[2].url, "data:image/png;base64,aW1hZ2U=")
        XCTAssertEqual(parts[2].mime, "image/png")
    }

    func testV2PromptAttachmentsUseInputURIsAndMentionRanges() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Self.requestBodyData(request))) as? [String: Any])
            let file = try XCTUnwrap((json["files"] as? [[String: Any]])?.first)
            XCTAssertEqual(file["uri"] as? String, "data:text/plain;base64,aGk=")
            XCTAssertEqual(file["name"] as? String, "notes.txt")
            XCTAssertNil(file["data"])
            XCTAssertNil(file["mime"])
            let agent = try XCTUnwrap((json["agents"] as? [[String: Any]])?.first)
            XCTAssertEqual(agent["name"] as? String, "explore")
            let mention = try XCTUnwrap(agent["mention"] as? [String: Any])
            XCTAssertEqual(mention["text"] as? String, "@explore")
            XCTAssertEqual(mention["start"] as? Int, 4)
            XCTAssertEqual(mention["end"] as? Int, 12)
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{"id":"msg_1","sessionID":"ses_1","time":{"created":1},"delivery":"queue","type":"user","payload":{"text":"ask @explore","metadata":{}}}}"#.utf8))
        }
        _ = try await makeProbeClient().admitV2TextPrompt(sessionID: "ses_1", messageID: "msg_1", text: "ask @explore", attachments: [.init(id: "a", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")], agentMentions: [.init(name: "explore", content: "@explore", start: 4, end: 12)])
    }

    func testV2TranscriptUsesPerTypeOrdinalsAndPreservesStreamingInputAndToolFiles() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"data":[{"id":"msg_a","type":"assistant","agent":"build","model":{"providerID":"openai","id":"gpt-5"},"time":{"created":1},"content":[{"type":"text","text":"Before"},{"type":"reasoning","text":"Think"},{"type":"tool","id":"call_1","name":"read","time":{"created":1},"state":{"status":"streaming","input":"{\"path\":"}},{"type":"reasoning","text":"Again"},{"type":"tool","id":"call_2","name":"render","time":{"created":1,"completed":2},"state":{"status":"completed","input":{},"content":[{"type":"file","uri":"data:image/png;base64,aGk=","mime":"image/png","name":"image.png"}],"metadata":{"renderer":"chart","schemaVersion":1,"payload":{"values":[1,2]}}}},{"type":"text","text":"After"}]}],"cursor":{"next":"repeat"}}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1", cursor: "repeat")
        let parts = try XCTUnwrap(page.messages.first?.parts)
        XCTAssertEqual(parts.map(\.id), ["msg_a:v2:text:0", "msg_a:v2:reasoning:0", "call_1", "msg_a:v2:reasoning:1", "call_2", "msg_a:v2:text:1"])
        XCTAssertEqual(parts[2].state?.status, "pending")
        XCTAssertEqual(parts[2].state?.raw, #"{"path":"#)
        XCTAssertEqual(parts[4].state?.metadata?.renderer, "chart")
        XCTAssertEqual(parts[4].state?.metadata?.files?.first?.objectValue?["uri"]?.stringValue, "data:image/png;base64,aGk=")
        XCTAssertNil(page.olderCursor)
    }

    func testV2FormsPreserveTypedKeysOptionsAndUnsupportedConstraints() throws {
        let form = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"frm_1","sessionID":"ses_1","title":"Settings","fields":[{"key":"choice","type":"string","required":true,"options":[{"value":"wire-value","label":"Display Label"}]},{"key":"tags","type":"multiselect","required":true,"options":[{"value":"a","label":"Alpha"}]},{"key":"count","type":"integer","required":true,"minimum":1},{"key":"ratio","type":"number","required":true},{"key":"enabled","type":"boolean","required":true}]}"#.utf8))
        let answer = try form.answer(from: [["Display Label"], ["Alpha"], ["2"], ["0.5"], ["true"]])
        XCTAssertEqual(answer, ["choice": .string("wire-value"), "tags": .array([.string("a")]), "count": .number(2), "ratio": .number(0.5), "enabled": .bool(true)])
        XCTAssertThrowsError(try form.answer(from: [["Display Label"], ["Alpha"], ["2.5"], ["0.5"], ["true"]]))
        XCTAssertThrowsError(try form.answer(from: []))
        let external = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"frm_external","sessionID":"global","title":"Authenticate","fields":[{"key":"auth","type":"external","url":"https://example.com"}]}"#.utf8))
        XCTAssertEqual(external.fields.first?["url"], .string("https://example.com"))
        XCTAssertThrowsError(try external.normalized())
        let conditional = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(#"{"id":"frm_conditional","sessionID":"ses_1","title":"Conditional","fields":[{"key":"mode","type":"boolean","required":true},{"key":"value","type":"string","required":true,"when":[{"key":"mode","op":"eq","value":true}]}]}"#.utf8))
        XCTAssertThrowsError(try conditional.normalized())
    }

    func testV2FormReplySendsKeyedTypedAnswerWithoutFetchingSchema() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_1/form/frm_1/reply")
            XCTAssertEqual(request.httpMethod, "POST")
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Self.requestBodyData(request))) as? [String: Any])
            let answer = try XCTUnwrap(json["answer"] as? [String: Any])
            XCTAssertEqual(answer["count"] as? Int, 2)
            XCTAssertEqual(answer["enabled"] as? Bool, true)
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await makeProbeClient().replyToV2Form(sessionID: "ses_1", formID: "frm_1", answer: ["count": .number(2), "enabled": .bool(true)])
    }

    func testV2PermissionsAndFormsUseLocationQueryNotLegacyHeader() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "location[directory]", value: "/repo")])
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"location":{"directory":"/repo"},"data":[]}"#.utf8))
        }
        _ = try await makeProbeClient().listV2PendingPermissions(directory: "/repo", workspaceID: "wrk_1")
        _ = try await makeProbeClient().listV2PendingForms(directory: "/repo", workspaceID: "wrk_1")
    }

    func testV2CatalogNormalizesSeparateProviderModelAndAgentSchemas() async throws {
        let model = #"{"id":"gpt-5","modelID":"gpt-5-provider","providerID":"openai","name":"GPT-5","capabilities":{"tools":true,"input":["text","image"],"output":["text","reasoning"]},"variants":[{"id":"high","settings":{"reasoningEffort":"high"}}],"time":{"released":1700000000000},"cost":[{"input":1,"output":2,"cache":{"read":0.1,"write":0.2}}],"status":"active","enabled":true,"limit":{"context":200000,"output":32000}}"#
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "location[directory]", value: "/repo")])
            let body: String
            switch request.url?.path {
            case "/api/provider": body = #"{"data":[{"id":"openai","name":"OpenAI","activation":"enabled","package":"@ai-sdk/openai"},{"id":"disabled","name":"Disabled","activation":"disabled","package":"test"}]}"#
            case "/api/model": body = "{\"data\":[\(model)]}"
            case "/api/model/default": body = "{\"data\":\(model)}"
            case "/api/agent": body = #"{"data":[{"id":"build","name":"Builder Display Name","mode":"primary","hidden":false,"model":{"providerID":"openai","id":"gpt-5","variant":"high"},"request":{"settings":{},"headers":{},"body":{}},"permissions":[]}]}"#
            case "/api/command": body = #"{"data":[{"name":"init","description":"Initialize"}]}"#
            default: XCTFail("Unexpected catalog route"); body = "{}"
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = makeProbeClient()
        let providers = try await client.listV2Providers(directory: "/repo")
        XCTAssertEqual(providers.map(\.id), ["openai"])
        let normalized = try XCTUnwrap(providers.first?.models["gpt-5"])
        XCTAssertEqual(normalized.id, "gpt-5")
        XCTAssertTrue(normalized.capabilities.reasoning)
        XCTAssertEqual(normalized.capabilities.attachment, true)
        XCTAssertEqual(normalized.variants?["high"]?.objectValue?["settings"]?.objectValue?["reasoningEffort"], .string("high"))
        XCTAssertEqual(normalized.cost?.input, 1)
        let defaultModel = try await client.defaultV2Model(directory: "/repo")
        XCTAssertEqual(defaultModel?.id, "gpt-5")
        let agents = try await client.listV2Agents(directory: "/repo")
        XCTAssertEqual(agents.first?.name, "build")
        XCTAssertEqual(agents.first?.model?.modelID, "gpt-5")
        XCTAssertEqual(agents.first?.variant, "high")
        let commands = try await client.listV2Commands(directory: "/repo")
        XCTAssertEqual(commands.first?.name, "init")
        XCTAssertEqual(commands.first?.template, "")
    }

    @MainActor
    func testV2TextOnlyCatalogVariantsReachStoreAndChatToolbarWithoutClaimingReasoning() async throws {
        // Model fields captured from next-17155 /api/model, not inferred from output modalities.
        let model = #"""
        {"id":"gpt-5.6-sol","providerID":"openai","name":"GPT-5.6 Sol",
         "capabilities":{"tools":true,"input":["text","image","pdf"],"output":["text"]},
         "variants":[
           {"id":"none","settings":{"reasoningEffort":"none","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}},
           {"id":"low","settings":{"reasoningEffort":"low","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}},
           {"id":"medium","settings":{"reasoningEffort":"medium","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}},
           {"id":"high","settings":{"reasoningEffort":"high","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}},
           {"id":"xhigh","settings":{"reasoningEffort":"xhigh","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}},
           {"id":"max","settings":{"reasoningEffort":"max","reasoningSummary":"auto","include":["reasoning.encrypted_content"]}}
         ],
         "time":{"released":1783555200000},"limit":{"context":400000,"input":272000,"output":128000},
         "family":"gpt-sol","status":"active","enabled":true,"cost":[]}
        """#
        let generic = #"{"id":"style","providerID":"fixture","name":"Style","capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[{"id":"concise","settings":{"verbosity":"low"}}],"time":{"released":1577836800000},"limit":{"context":1000,"output":100},"status":"active","enabled":true,"cost":[]}"#
        let plain = #"{"id":"plain","providerID":"fixture","name":"Plain","capabilities":{"tools":true,"input":["text"],"output":["text"]},"variants":[],"limit":{"context":1000,"output":100},"status":"active","enabled":true,"cost":[]}"#
        MockURLProtocol.requestHandler = { request in
            let body: String
            switch request.url?.path {
            case "/api/provider":
                body = #"{"data":[{"id":"openai","name":"OpenAI","disabled":false},{"id":"fixture","name":"Fixture","disabled":false}]}"#
            case "/api/model":
                body = "{\"data\":[\(model),\(generic),\(plain)]}"
            default:
                XCTFail("Unexpected catalog request")
                body = "{}"
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let providers = try await makeProbeClient().listV2Providers(directory: "/repo")
        let normalized = try XCTUnwrap(providers.first { $0.id == "openai" }?.models["gpt-5.6-sol"])
        XCTAssertFalse(normalized.capabilities.reasoning)
        XCTAssertEqual(normalized.variants?["high"]?.objectValue?["settings"]?.objectValue?["reasoningSummary"], .string("auto"))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.date(from: try XCTUnwrap(normalized.releaseDate))?.timeIntervalSince1970, 1783555200)
        let roundTrip = try JSONDecoder().decode(OpenCodeModel.self, from: JSONEncoder().encode(normalized))
        XCTAssertEqual(roundTrip, normalized)

        let viewModel = AppViewModel()
        let store = viewModel.modelConfigurationStore
        store.applyComposerOptions(agents: [], providers: providers, defaults: ["openai": "gpt-5.6-sol"])
        let session = OpenCodeSession(id: "ses_catalog", title: nil, workspaceID: nil, directory: "/repo", projectID: nil, parentID: nil)
        let reference = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.6-sol")
        let choices = ["high", "low", "max", "medium", "none", "xhigh"]
        store.selectModel(reference, forSessionID: session.id)
        store.selectVariant("high", forSessionID: session.id)
        store.sanitizeComposerSelections(validSessionIDs: [session.id])
        XCTAssertEqual(store.reasoningVariants(for: reference), choices)
        XCTAssertEqual(store.reasoningVariants(forSessionID: session.id), choices)
        XCTAssertEqual(store.configurationReasoningVariants, choices)
        let toolbar = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(toolbar.reasoningVariants.map(\.id), choices)
        XCTAssertEqual(toolbar.selectedReasoningVariant, "high")

        let genericReference = OpenCodeModelReference(providerID: "fixture", modelID: "style")
        XCTAssertEqual(store.reasoningVariants(for: genericReference), ["concise"])
        XCTAssertFalse(try XCTUnwrap(store.model(for: genericReference)).capabilities.reasoning)
        XCTAssertEqual(store.model(for: genericReference)?.releaseDate, "2020-01-01T00:00:00.000Z")
        XCTAssertFalse(store.isModelVisible(genericReference), "Old catalog models must not lose their release age")
        let plainReference = OpenCodeModelReference(providerID: "fixture", modelID: "plain")
        store.selectModel(plainReference, forSessionID: session.id)
        XCTAssertTrue(store.reasoningVariants(for: plainReference).isEmpty)
        XCTAssertNil(store.model(for: plainReference)?.releaseDate)
        XCTAssertTrue(viewModel.chatFacade.toolbarSnapshot(for: session).reasoningVariants.isEmpty)
        XCTAssertNil(store.selectedVariant(for: session.id))
    }

    @MainActor
    func testLegacyModelVariantsStillRequireReasoningCapability() throws {
        let data = Data(#"[{"id":"plain","providerID":"fixture","name":"Plain","capabilities":{"reasoning":false},"variants":{"high":{}}},{"id":"reasoner","providerID":"fixture","name":"Reasoner","capabilities":{"reasoning":true},"variants":{"high":{}}}]"#.utf8)
        let models = try JSONDecoder().decode([OpenCodeModel].self, from: data)
        let store = ModelConfigurationStore()
        store.applyComposerOptions(agents: [], providers: [OpenCodeProvider(id: "fixture", name: "Fixture", models: Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) }))], defaults: [:])
        XCTAssertNil(models.first?.catalogVariantIDs)
        XCTAssertTrue(store.reasoningVariants(for: .init(providerID: "fixture", modelID: "plain")).isEmpty)
        XCTAssertEqual(store.reasoningVariants(for: .init(providerID: "fixture", modelID: "reasoner")), ["high"])
    }

    @MainActor
    func testV2SubagentHTTPAndLiveMetadataRouteTheSameChildWithoutOutputParsing() async throws {
        // A completed background tool may still describe a running child session.
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_parent/message")
            let body = #"{"data":[{"id":"msg_assistant","type":"assistant","time":{"created":1000},"content":[{"type":"tool","id":"call_child","name":"subagent","state":{"status":"completed","input":{"agent":"explore","description":"Inspect fixture","prompt":"Synthetic fixture","background":true},"content":[{"type":"text","text":""}],"metadata":{"sessionID":"ses_child","status":"running"}}}]}]}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let page = try await makeProbeClient().listV2Messages(sessionID: "ses_parent")
        let hydrated = try XCTUnwrap(page.messages.first?.parts.first)
        XCTAssertEqual(hydrated.tool, "subagent")
        XCTAssertEqual(hydrated.state?.input?.subagentType, "explore")
        XCTAssertEqual(hydrated.state?.metadata?.sessionId, "ses_child")
        XCTAssertNil(hydrated.state?.output)
        let resolve: (OpenCodePart) -> String? = { part in
            MessageBubbleTaskNavigation.sessionID(for: part, currentSessionID: "ses_parent") { _, _ in
                XCTFail("V2 must not use legacy child-title heuristics")
                return "wrong_child"
            }
        }
        XCTAssertEqual(resolve(hydrated), "ses_child")
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("subagent").icon, OpenCodeToolActivityAppearance.resolve("task").icon)

        let store = ChatStore()
        store.beginV2TranscriptHydration(sessionID: "ses_parent")
        store.applyInitialV2Transcript([], olderCursor: nil, sessionID: "ses_parent")
        let events = [
            #"{"type":"session.tool.input.started","data":{"sessionID":"ses_parent","assistantMessageID":"msg_assistant","id":"call_child","name":"subagent"}}"#,
            #"{"type":"session.tool.called","data":{"sessionID":"ses_parent","assistantMessageID":"msg_assistant","id":"call_child","input":{"agent":"explore","description":"Inspect fixture","prompt":"Synthetic fixture","background":true},"executed":false}}"#,
            #"{"type":"session.tool.progress","data":{"sessionID":"ses_parent","assistantMessageID":"msg_assistant","id":"call_child","metadata":{"sessionID":"ses_child","status":"running"}}}"#,
            #"{"type":"session.tool.success","data":{"sessionID":"ses_parent","assistantMessageID":"msg_assistant","id":"call_child","content":[{"type":"text","text":""}],"metadata":{"sessionID":"ses_child","status":"running"},"executed":false}}"#,
        ]
        for (index, raw) in events.enumerated() {
            let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: raw))
            XCTAssertTrue(store.applyV2StreamEvent(event, sessionID: "ses_parent"))
            let part = try XCTUnwrap(store.messages.first?.parts.first)
            XCTAssertEqual(resolve(part), index < 2 ? nil : "ses_child")
            if index >= 1 { XCTAssertEqual(part.state?.input, hydrated.state?.input) }
        }
        let streamed = try XCTUnwrap(store.messages.first?.parts.first)
        XCTAssertEqual(streamed.state?.status, "completed")
        XCTAssertEqual(streamed.state?.metadata, hydrated.state?.metadata)

        let foreground = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: #"{"type":"session.message.content.updated","data":{"sessionID":"ses_parent","messageID":"msg_assistant","content":[{"type":"tool","id":"call_child","name":"subagent","state":{"status":"completed","input":{"agent":"explore"},"content":[{"type":"text","text":"Synthetic result"}],"metadata":{"sessionID":"ses_child","status":"completed"}}}]}}"#))
        XCTAssertTrue(store.applyV2StreamEvent(foreground, sessionID: "ses_parent"))
        XCTAssertEqual(resolve(try XCTUnwrap(store.messages.first?.parts.first)), "ses_child")

        let unlinked = try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"tool","tool":"subagent","state":{"status":"completed","output":"<subagent sessionID=\"ses_wrong\">result</subagent>"}}"#.utf8))
        XCTAssertNil(resolve(unlinked), "Output text is not a child-navigation contract")

        let legacy = try JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"type":"tool","tool":"task","state":{"status":"completed","input":{"subagent_type":"explore"},"metadata":{"sessionId":"ses_legacy"}}}"#.utf8))
        XCTAssertEqual(legacy.state?.input?.subagentType, "explore")
        XCTAssertEqual(MessageBubbleTaskNavigation.sessionID(for: legacy, currentSessionID: "ses_parent") { part, _ in part.state?.metadata?.sessionId }, "ses_legacy")
        let metadata = try XCTUnwrap(hydrated.state?.metadata)
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeToolMetadata.self, from: JSONEncoder().encode(metadata)), metadata)
    }

    func testV2SessionActionsUseRenameForkSelectionAndCompactContracts() async throws {
        var paths: [String] = []
        MockURLProtocol.requestHandler = { request in
            let path = try XCTUnwrap(request.url?.path)
            paths.append(path)
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            let body = try Self.requestBodyData(request).map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
            var response = ""
            switch path {
            case "/api/session/ses_1/fork":
                XCTAssertEqual(body?["before"] as? String, "msg_1")
                response = #"{"data":{"id":"ses_fork","projectID":"p","location":{"directory":"/repo"},"time":{"created":1,"updated":2}}}"#
            case "/api/session/ses_1/agent":
                XCTAssertEqual(body?["agent"] as? String, "build")
            case "/api/session/ses_1/model":
                XCTAssertEqual(body?["model"] as? [String: String], ["providerID": "openai", "id": "gpt-5", "variant": "high"])
            case "/api/session/ses_1/compact":
                XCTAssertEqual(body?["delivery"] as? String, "steer")
                let id = try XCTUnwrap(body?["id"] as? String)
                response = "{\"data\":{\"id\":\"\(id)\",\"sessionID\":\"ses_1\",\"time\":{\"created\":1},\"type\":\"compaction\",\"payload\":{},\"delivery\":\"steer\"}}"
            case "/api/session/ses_1/command":
                XCTAssertEqual(body?["name"] as? String, "init")
                XCTAssertEqual(body?["text"] as? String, "README.md")
                XCTAssertEqual(body?["files"] as? [[String: String]], [["uri": "data:text/plain;base64,YQ==", "name": "notes.txt"]])
                XCTAssertNil(body?["delivery"])
                XCTAssertNil(body?["id"])
            case "/api/session/active":
                response = #"{"data":{"ses_1":{"type":"running"}}}"#
            case "/api/session/ses_1":
                if request.httpMethod == "GET" {
                    response = #"{"data":{"id":"ses_1","projectID":"p","title":"Renamed","location":{"directory":"/repo"},"time":{"created":1,"updated":2}}}"#
                } else if request.httpMethod == "PATCH" {
                    XCTAssertEqual(body?["title"] as? String, "Renamed")
                } else { XCTAssertEqual(request.httpMethod, "DELETE") }
            default: XCTFail("Unexpected session action \(path)")
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: response.isEmpty ? 204 : 200, httpVersion: nil, headerFields: nil)!, Data(response.utf8))
        }
        let client = makeProbeClient()
        let renamed = try await client.updateV2SessionTitle(sessionID: "ses_1", title: "Renamed")
        XCTAssertEqual(renamed.title, "Renamed")
        let fork = try await client.forkV2Session(sessionID: "ses_1", messageID: "msg_1")
        XCTAssertEqual(fork.id, "ses_fork")
        XCTAssertNil(fork.parentID)
        try await client.switchV2SessionAgent(sessionID: "ses_1", agent: "build")
        try await client.switchV2SessionModel(sessionID: "ses_1", model: .init(providerID: "openai", modelID: "gpt-5"), variant: "high")
        try await client.compactV2Session(sessionID: "ses_1")
        try await client.sendV2Command(sessionID: "ses_1", command: "init", arguments: "README.md",
            attachments: [.init(id: "file", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,YQ==")])
        let statuses = try await client.listV2SessionStatuses()
        XCTAssertEqual(statuses, ["ses_1": "busy"])
        try await client.deleteV2Session(sessionID: "ses_1")
        XCTAssertEqual(paths.count, 9)
    }

    func testPreviewV2MutationsUseDetectedContractWithoutTryingReleaseRoutes() async throws {
        var client = makeProbeClient()
        client.v2Contract = .preview17155
        var requests: [(String, String, [String: Any])] = []
        MockURLProtocol.requestHandler = { request in
            let body = Self.requestBodyData(request)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            requests.append((request.httpMethod ?? "", request.url?.path ?? "", body))
            if request.httpMethod == "GET" {
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"id":"ses_1","projectID":"p","title":"Renamed","location":{"directory":"/repo"},"time":{"created":1,"updated":2}}}"#.utf8))
            }
            if request.url?.path == "/api/session/ses_1/fork" {
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"id":"ses_fork","projectID":"p","location":{"directory":"/repo"},"time":{"created":1,"updated":2}}}"#.utf8))
            }
            if request.url?.path == "/api/session/ses_1/command" {
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"data":{"id":"msg_command","sessionID":"ses_1","timeCreated":3,"delivery":"queue"}}"#.utf8))
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }

        _ = try await client.updateV2SessionTitle(sessionID: "ses_1", title: "Renamed")
        _ = try await client.forkV2Session(sessionID: "ses_1", messageID: "msg_1")
        try await client.compactV2Session(sessionID: "ses_1")
        _ = try await client.admitV2Command(sessionID: "ses_1", messageID: "msg_command", command: "init")
        try await client.waitForV2Session(sessionID: "ses_1")
        try await client.replyToV2Permission(sessionID: "ses_1", requestID: "per_1", reply: "once")
        try await client.cancelV2Form(sessionID: "ses_1", formID: "frm_1", directory: "/repo", workspaceID: "wrk_1")

        XCTAssertEqual(requests.map { "\($0.0) \($0.1)" }, [
            "POST /api/session/ses_1/rename",
            "GET /api/session/ses_1",
            "POST /api/session/ses_1/fork",
            "POST /api/session/ses_1/compact",
            "POST /api/session/ses_1/command",
            "POST /api/session/ses_1/wait",
            "POST /api/session/ses_1/permission/per_1/reply",
            "POST /api/session/ses_1/form/frm_1/cancel",
        ])
        XCTAssertEqual((requests[2].2["boundary"] as? [String: Any])?["type"] as? String, "before")
        XCTAssertTrue(requests[3].2.isEmpty)
        XCTAssertEqual(requests[4].2["id"] as? String, "msg_command")
        XCTAssertEqual(requests[6].2["reply"] as? String, "once")
        XCTAssertNil(requests[6].2["decision"])
    }

    func testV2FileAndVCSTransportsNormalizeCurrentShapes() async throws {
        MockURLProtocol.requestHandler = { request in
            let body: String
            switch request.url?.path {
            case "/api/fs/list":
                body = #"{"location":{"directory":"/resolved"},"data":[{"path":"Sources/main.swift","type":"file"}]}"#
            case "/api/fs/read/Sources/main.swift":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "*/*")
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!, Data("let value = 1".utf8))
            case "/api/vcs": body = #"{"data":{"branch":{"current":"feature","default":"main"}}}"#
            case "/api/vcs/status": body = #"{"data":[{"file":"Sources/main.swift","additions":2,"deletions":1,"status":"modified"}]}"#
            case "/api/vcs/diff":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.last, URLQueryItem(name: "mode", value: "working"))
                body = #"{"data":[{"file":"Sources/main.swift","patch":"@@ -1 +1 @@\n-a\n+b","additions":1,"deletions":1,"status":"modified"}]}"#
            case "/api/mcp": body = #"{"data":[{"name":"tools","status":{"status":"connected"}}]}"#
            default: XCTFail("Unexpected supporting route"); body = "{}"
            }
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = makeProbeClient()
        let files = try await client.listV2Files(directory: "/requested")
        XCTAssertEqual(files.first?.name, "main.swift")
        XCTAssertEqual(files.first?.absolute, "/resolved/Sources/main.swift")
        let content = try await client.readV2FileContent(directory: "/requested", path: "Sources/main.swift")
        XCTAssertEqual(content.type, "text")
        XCTAssertEqual(content.content, "let value = 1")
        let vcs = try await client.getV2VCSInfo(directory: "/requested")
        XCTAssertEqual(vcs.branch, "feature")
        XCTAssertEqual(vcs.defaultBranch, "main")
        let statuses = try await client.listV2FileStatus(directory: "/requested")
        XCTAssertEqual(statuses.first?.path, "Sources/main.swift")
        XCTAssertEqual(statuses.first?.added, 2)
        let diffs = try await client.getV2VCSDiff(mode: .git, directory: "/requested")
        XCTAssertEqual(diffs.first?.additions, 1)
        let mcp = try await client.listV2MCPStatus(directory: "/requested")
        XCTAssertEqual(mcp["tools"]?.status, "connected")
    }

    func testV2TranscriptPreservesMentionReasoningTimingAndShellCompletion() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"data":[{"id":"msg_shell","type":"shell","shellID":"sh_1","command":"pwd","status":"exited","exit":0,"output":{"output":"/repo","cursor":5,"size":5,"truncated":false},"time":{"created":3,"completed":4}},{"id":"msg_reasoning","type":"assistant","agent":"build","model":{"providerID":"openai","id":"gpt-5"},"content":[{"type":"reasoning","text":"Think","time":{"created":2,"completed":3}}],"time":{"created":2,"completed":3}},{"id":"msg_user","type":"user","text":"@build","agents":[{"name":"build","mention":{"start":0,"end":6,"text":"@build"}}],"time":{"created":1}}],"cursor":{}}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1")
        XCTAssertEqual(page.messages.map(\.id), ["msg_user", "msg_reasoning", "msg_shell"])
        XCTAssertEqual(page.messages[0].parts.last?.id, "msg_user:v2:agent:0")
        XCTAssertEqual(page.messages[0].parts.last?.source?.value, "@build")
        XCTAssertEqual(page.messages[0].parts.last?.source?.end, 6)
        XCTAssertEqual(page.messages[1].parts.first?.time, OpenCodePartTime(start: 2, end: 3))
        XCTAssertEqual(page.messages[2].parts.first?.state?.status, "completed")
        XCTAssertEqual(page.messages[2].parts.first?.state?.output, "/repo")
        XCTAssertEqual(page.messages[2].info.time?.completed, 4)
    }

    func testV2TranscriptDoesNotSilentlyDropMalformedKnownRecordsOrOldAttachmentContract() async throws {
        for record in [
            #"{"id":"msg_1","type":"user","text":"File","files":[{"uri":"file:///tmp/a","name":"a"}]}"#,
            #"{"id":"msg_1","type":"user"}"#,
            #"{"id":"msg_1","type":"assistant","content":[{"type":"text"}]}"#,
            #"{"id":"msg_1","type":"assistant","content":[{"type":"reasoning","text":42}]}"#,
            #"{"id":"msg_1","type":"assistant","content":[{"type":"future","text":"Not an answer"}]}"#,
        ] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("{\"data\":[\(record)],\"cursor\":{\"next\":\"older\"}}".utf8))
            }
            do {
                _ = try await makeProbeClient().listV2Messages(sessionID: "ses_1", limit: 1)
                XCTFail("Expected a surfaced projection error")
            } catch OpenCodeV2TransportError.invalidTimelineRecord {}
            XCTAssertEqual(requests, 1, "Invalid primary records must fail before lookahead")
        }
    }

    func testV2TranscriptSkipsIdleAndUnknownRecordsButKeepsDisplayableHistory() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = #"{"data":[{"type":"idle","time":{"created":3}},{"id":"future_1","type":"future-record","value":true},{"id":"msg_1","type":"user","text":"Hello","time":{"created":1}}],"cursor":{}}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let page = try await makeProbeClient().listV2Messages(sessionID: "ses_1")

        XCTAssertEqual(page.messages.map(\.id), ["msg_1"])
    }

    func testV2GlobalBootstrapRetainsConcreteServerDirectory() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = request.url?.path == "/api/location"
                ? #"{"directory":"/isolated/workspace","project":{"id":"global","directory":"/","canonical":"/"}}"#
                : #"[{"id":"global","canonical":"/","time":{"created":1,"updated":1},"sandboxes":[]}]"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let bootstrap = try await makeProbeClient().bootstrapV2Projects()
        XCTAssertEqual(bootstrap.currentProject?.id, "global")
        XCTAssertEqual(bootstrap.selectedDirectory, "/isolated/workspace")
    }

    func testV2ProvidersAcceptNext17155DisabledFlagAndCurrentActivation() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = request.url?.path == "/api/provider"
                ? #"{"data":[{"id":"opencode","name":"OpenCode Zen","package":"test"},{"id":"old-disabled","name":"Old Disabled","disabled":true,"package":"test"},{"id":"new-disabled","name":"New Disabled","activation":"disabled","package":"test"}]}"#
                : #"{"data":[]}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let providers = try await makeProbeClient().listV2Providers()
        XCTAssertEqual(providers.map(\.id), ["opencode"])
    }

    func testV2PromptCanBeAdmittedWithoutResumingExecution() async throws {
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["resume"] as? Bool, false)
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"data":{"id":"msg_paused","sessionID":"ses_1","time":{"created":1},"delivery":"steer","type":"user","payload":{"text":"Paused"}}}"#.utf8))
        }
        let receipt = try await makeProbeClient().admitV2TextPrompt(sessionID: "ses_1", messageID: "msg_paused", text: "Paused", resume: false)
        XCTAssertEqual(receipt.id, "msg_paused")
    }

    func testV2FormValidationResponseBodyIsPreserved() async throws {
        let body = #"{"_tag":"FormInvalidAnswerError","id":"frm_1","message":"Invalid option for form field: choice"}"#
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        do {
            try await makeProbeClient().replyToV2Form(sessionID: "ses_1", formID: "frm_1", answer: ["choice": .string("wrong")])
            XCTFail("Expected validation failure")
        } catch let OpenCodeAPIError.httpError(status, responseBody) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(responseBody, body)
        }
    }

    func testV2SessionConfigurationSurvivesGetAndListNormalization() async throws {
        let fixture = #"{"id":"ses_config","projectID":"p","title":"Configured","agent":"plan","model":{"id":"model/configured","providerID":"provider","variant":"high"},"location":{"directory":"/repo"},"time":{"created":1,"updated":2}}"#
        MockURLProtocol.requestHandler = { request in
            let body = request.url?.path == "/api/session"
                ? "{\"data\":[\(fixture)],\"cursor\":{}}"
                : "{\"data\":\(fixture)}"
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let client = makeProbeClient()
        let session = try await client.getV2Session(sessionID: "ses_config")
        XCTAssertEqual(session.agent, "plan")
        XCTAssertEqual(session.model?.providerID, "provider")
        XCTAssertEqual(session.model?.modelID, "model/configured")
        XCTAssertEqual(session.model?.variant, "high")
        let page = try await client.listV2Sessions(projectID: "p", directory: "/repo")
        XCTAssertEqual(page.sessions.first, session)
    }

    func testSessionConfigurationIsBackwardCompatibleAndRoundTripsInCache() throws {
        var session = try JSONDecoder().decode(OpenCodeSession.self, from: Data(#"{"id":"ses_cached","title":"Cached","directory":"/repo","projectID":"p","time":{"created":1}}"#.utf8))
        XCTAssertNil(session.agent)
        XCTAssertNil(session.model)
        session.agent = "plan"
        session.model = .init(providerID: "provider", modelID: "configured", variant: "high")
        let restored = try JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored, session)

        let partial = OpenCodeSession(id: session.id, title: "Updated title", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        XCTAssertEqual(restored.merged(with: partial).model, session.model)
        XCTAssertEqual(restored.merged(with: partial).agent, "plan")
        var changed = partial
        changed.agent = "build"
        changed.model = .init(providerID: "other", modelID: "replacement", variant: nil)
        let merged = restored.merged(with: changed)
        XCTAssertEqual(merged.agent, "build")
        XCTAssertEqual(merged.model?.providerID, "other")
        XCTAssertEqual(merged.model?.modelID, "replacement")
        XCTAssertNil(merged.model?.variant, "A new model reference must not inherit an old variant")
    }

    func testV2CommandsNormalizeObjectModelReferencesWithoutBreakingCatalog() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/command")
            let body = #"{"data":[{"name":"configured","template":"Inspect $ARGUMENTS","agent":"plan","model":{"id":"model/with/slashes","providerID":"provider","variant":"high"},"subtask":true},{"name":"simple","model":{"id":"simple","providerID":"provider"},"template":"Run"},{"name":"current-contract","description":"Only name and description"}]}"#
            return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let commands = try await makeProbeClient().listV2Commands()
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0].model, "provider/model/with/slashes#high")
        XCTAssertEqual(commands[0].agent, "plan")
        XCTAssertEqual(commands[0].template, "Inspect $ARGUMENTS")
        XCTAssertEqual(commands[0].subtask, true)
        XCTAssertEqual(commands[1].model, "provider/simple")
        XCTAssertNil(commands[2].model)
        XCTAssertEqual(commands[2].template, "")
    }

    func testV2QuestionAdapterRejectsOptionalFieldsAndDefaultsWithoutDroppingThem() throws {
        for field in [
            #"{"key":"value","type":"string"}"#,
            #"{"key":"value","type":"string","required":false}"#,
            #"{"key":"value","type":"string","required":true,"default":""}"#,
            #"{"key":"value","type":"number","required":true,"default":0}"#,
            #"{"key":"value","type":"boolean","required":true,"default":false}"#,
            #"{"key":"value","type":"multiselect","required":true,"options":[],"default":[]}"#,
        ] {
            let body = "{\"id\":\"frm_1\",\"sessionID\":\"ses_1\",\"title\":\"Form\",\"fields\":[\(field)]}"
            let form = try JSONDecoder().decode(OpenCodeV2Form.self, from: Data(body.utf8))
            let originalField = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data(field.utf8))
            XCTAssertEqual(form.fields, [originalField])
            XCTAssertThrowsError(try form.normalized()) { error in
                guard case OpenCodeV2TransportError.unsupportedFormField("value") = error else {
                    return XCTFail("Expected an explicit unsupported-field result, got \(error)")
                }
            }
            XCTAssertThrowsError(try form.answer(from: [["value"]]))
        }
    }

    func testV2PendingInputIDsUseExplicitVerifiedEndpointAndPayloadIndependentIDs() async throws {
        let client = makeProbeClient()
        for endpoint in [OpenCodeV2PendingInputEndpoint.inbox, .pending] {
            MockURLProtocol.requestHandler = { request in
                XCTAssertEqual(request.url?.path, "/api/session/ses_1/\(endpoint.rawValue)")
                XCTAssertEqual(request.httpMethod, "GET")
                let payloadKey = endpoint == .inbox ? "payload" : "data"
                let body = "{\"data\":[{\"id\":\"msg_pending\",\"sessionID\":\"ses_1\",\"type\":\"user\",\"timeCreated\":1,\"delivery\":\"steer\",\"\(payloadKey)\":{\"text\":\"Paused\"}}]}"
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
            }
            let ids = try await client.listV2PendingInputIDs(sessionID: "ses_1", endpoint: endpoint)
            XCTAssertEqual(ids, ["msg_pending"])
        }
    }

    func testV2PendingInputLookupDoesNotFallbackOrInterpretFailureAsEmpty() async throws {
        for status in [401, 404, 500] {
            var requests = 0
            MockURLProtocol.requestHandler = { request in
                requests += 1
                XCTAssertEqual(request.url?.path, "/api/session/ses_1/inbox")
                return (HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!, Data("failure".utf8))
            }
            do {
                _ = try await makeProbeClient().listV2PendingInputIDs(sessionID: "ses_1", endpoint: .inbox)
                XCTFail("Expected queue lookup failure")
            } catch let OpenCodeAPIError.httpError(code, body) {
                XCTAssertEqual(code, status)
                XCTAssertEqual(body, "failure")
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testSendMessageAsyncUsesPromptAsyncEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/prompt_async")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic b3BlbmNvZGU6cHc=")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.sendMessageAsync(sessionID: "ses_test", text: "hello", directory: "/tmp/project")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSendMessageAsyncEncodesAgentMentionParts() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let parts = try XCTUnwrap(json["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0]["type"] as? String, "text")
            XCTAssertEqual(parts[0]["text"] as? String, "ask @explore about this")
            XCTAssertEqual(parts[1]["type"] as? String, "agent")
            XCTAssertEqual(parts[1]["name"] as? String, "explore")
            let source = try XCTUnwrap(parts[1]["source"] as? [String: Any])
            XCTAssertEqual(source["value"] as? String, "@explore")
            XCTAssertEqual(source["start"] as? Int, 4)
            XCTAssertEqual(source["end"] as? Int, 12)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.sendMessageAsync(
            sessionID: "ses_test",
            text: "ask @explore about this",
            agentMentions: [OpenCodeAgentMention(name: "explore", content: "@explore", start: 4, end: 12)]
        )
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDecodesAgentPartSource() throws {
        let data = """
        {
          "info": { "id": "msg_1", "role": "user", "sessionID": "ses_1" },
          "parts": [
            {
              "id": "prt_agent",
              "sessionID": "ses_1",
              "messageID": "msg_1",
              "type": "agent",
              "name": "explore",
              "source": { "value": "@explore", "start": 4, "end": 12 }
            }
          ]
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(OpenCodeMessageEnvelope.self, from: data)
        let part = try XCTUnwrap(message.parts.first)
        XCTAssertEqual(part.type, "agent")
        XCTAssertEqual(part.name, "explore")
        XCTAssertEqual(part.source?.value, "@explore")
        XCTAssertEqual(part.source?.start, 4)
        XCTAssertEqual(part.source?.end, 12)
    }

    func testDecodesCommandsWhenMCPSourceReturnsObjectTemplate() throws {
        // opencode returns `template: {}` for MCP-sourced commands; the whole `/command`
        // array must still decode instead of failing with a DecodingError.typeMismatch.
        let data = """
        [
          { "name": "init", "description": "Init", "source": "command", "template": "Create AGENTS.md", "hints": ["$ARGUMENTS"] },
          { "name": "websearch:web_search_help", "description": "Get help with web search", "source": "mcp", "template": {}, "hints": [] }
        ]
        """.data(using: .utf8)!

        let commands = try JSONDecoder().decode([OpenCodeCommand].self, from: data)

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].template, "Create AGENTS.md")
        XCTAssertEqual(commands[1].name, "websearch:web_search_help")
        XCTAssertEqual(commands[1].source, "mcp")
        XCTAssertEqual(commands[1].template, "")
    }

    func testListMessagesRepairsUnpairedUnicodeEscapesInToolOutput() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            expectation.fulfill()

            let data = #"[{"info":{"id":"msg_user","role":"user","sessionID":"ses_test","model":{"providerID":"openai","modelID":"gpt-5.5","variant":"medium"}},"parts":[{"id":"prt_user","messageID":"msg_user","sessionID":"ses_test","type":"text","text":"Use the previous model"}]},{"info":{"id":"msg_assistant","role":"assistant","sessionID":"ses_test"},"parts":[{"id":"prt_tool","messageID":"msg_assistant","sessionID":"ses_test","type":"tool","tool":"bash","state":{"status":"completed","output":"valid pair \ud83d\ude96 and bad scalar \ude80"}}]}]"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let messages = try await client.listMessages(sessionID: "ses_test")

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.info.model?.modelID, "gpt-5.5")
        let output = try XCTUnwrap(messages.last?.parts.first?.state?.output)
        XCTAssertTrue(output.unicodeScalars.contains(UnicodeScalar(0x1F696)!))
        XCTAssertTrue(output.unicodeScalars.contains(UnicodeScalar(0xFFFD)!))
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMessagesUsesLimitAndDirectoryQueryItems() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            expectation.fulfill()
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        _ = try await client.listMessages(sessionID: "ses_test", limit: 20, directory: "/tmp/project")

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMessagePageUsesCursorAndReturnsNextCursorHeader() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/message")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "limit", value: "12"),
                URLQueryItem(name: "before", value: "cursor-1"),
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            expectation.fulfill()
            let data = #"[{"info":{"id":"msg_old","role":"user","sessionID":"ses_test"},"parts":[]}]"#.data(using: .utf8)!
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["X-Next-Cursor": "cursor-2"]
                )!,
                data
            )
        }

        let page = try await client.listMessagePage(
            sessionID: "ses_test",
            limit: 12,
            before: "cursor-1",
            directory: "/tmp/project"
        )

        XCTAssertEqual(page.messages.map(\.id), ["msg_old"])
        XCTAssertEqual(page.nextCursor, "cursor-2")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testGetSessionUsesExactScopedEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_child")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "workspace-1"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()
            let data = #"{"id":"ses_child","title":"Child","workspaceID":"workspace-1","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let loaded = try await client.getSession(
            sessionID: "ses_child",
            directory: "/tmp/project",
            workspaceID: "workspace-1"
        )

        XCTAssertEqual(loaded.id, "ses_child")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDirectoryBootstrapWarmsChildSessionForPendingPermission() async throws {
        let childRequest = expectation(description: "child session requested")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            let data: Data
            switch request.url?.path {
            case "/session":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "directory", value: "/tmp/project"),
                    URLQueryItem(name: "roots", value: "true"),
                    URLQueryItem(name: "limit", value: "100"),
                ])
                data = #"[{"id":"ses_parent","title":"Parent","directory":"/tmp/project","projectID":"proj_1"}]"#.data(using: .utf8)!
            case "/permission":
                data = #"[{"id":"perm_child","sessionID":"ses_child","permission":"bash","patterns":["xcodebuild test"]}]"#.data(using: .utf8)!
            case "/question", "/command":
                data = Data("[]".utf8)
            case "/session/ses_child":
                childRequest.fulfill()
                data = #"{"id":"ses_child","title":"Child","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#.data(using: .utf8)!
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                data = Data("[]".utf8)
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let bootstrap = try await OpenCodeBootstrap.bootstrapDirectory(
            client: client,
            directory: "/tmp/project",
            sessionLimit: 100
        )

        XCTAssertEqual(bootstrap.sessions.map(\.id), ["ses_parent", "ses_child"])
        XCTAssertEqual(bootstrap.sessions.last?.parentID, "ses_parent")
        XCTAssertEqual(bootstrap.sessionTotal, 1)
        await fulfillment(of: [childRequest], timeout: 1)
    }

    func testUpdateProjectEncodesIconPreferences() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/project/proj_123")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "PATCH")

            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["name"] as? String, "Project")
            let icon = try XCTUnwrap(json["icon"] as? [String: Any])
            XCTAssertEqual(icon["color"] as? String, "purple")
            XCTAssertEqual(icon["override"] as? String, "data:image/png;base64,AAA")
            expectation.fulfill()

            let data = """
            {
              "id": "proj_123",
              "worktree": "/tmp/project",
              "name": "Project",
              "icon": { "color": "purple", "override": "data:image/png;base64,AAA" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let project = try await client.updateProject(
            projectID: "proj_123",
            directory: "/tmp/project",
            name: "Project",
            icon: OpenCodeProject.Icon(override: "data:image/png;base64,AAA", color: "purple")
        )
        XCTAssertEqual(project.icon?.color, "purple")
        XCTAssertEqual(project.icon?.override, "data:image/png;base64,AAA")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testRemoveWorktreeUsesRootDirectoryQueryAndTargetBody() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/experimental/worktree")
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")

            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["directory"] as? String, "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let removed = try await client.removeWorktree(rootDirectory: "/tmp/project", worktreeDirectory: "/tmp/project-worktree")
        XCTAssertTrue(removed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResetWorktreeUsesResetEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/experimental/worktree/reset")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["directory"] as? String, "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let reset = try await client.resetWorktree(rootDirectory: "/tmp/project", worktreeDirectory: "/tmp/project-worktree")
        XCTAssertTrue(reset)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDisposeInstanceUsesDirectoryScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/instance/dispose")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project-worktree"),
            ])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project-worktree")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let disposed = try await client.disposeInstance(directory: "/tmp/project-worktree")
        XCTAssertTrue(disposed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testProviderStateUsesProviderEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            let data = #"{"all":[{"id":"openai","name":"OpenAI","source":"api","env":[],"options":{},"models":{"gpt-5":{"id":"gpt-5","providerID":"openai","name":"GPT-5","capabilities":{"reasoning":true},"status":"active","release_date":"2026-01-01"}}}],"connected":["openai"],"default":{"openai":"gpt-5"}}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let state = try await client.providerState(directory: "/tmp/project")

        XCTAssertEqual(state.connected, ["openai"])
        XCTAssertEqual(state.default["openai"], "gpt-5")
        XCTAssertEqual(state.all.first?.models["gpt-5"]?.releaseDate, "2026-01-01")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResolvedConfigLoadsDirectoryPluginsInServerOrder() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/config")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            let data = #"{"plugin":["opencode-example@1.2.3",["file:///tmp/project/.opencode/plugins/local.ts",{"option":true}]]}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let config = try await client.resolvedConfig(directory: "/tmp/project")

        XCTAssertEqual(config.plugins.map(\.specifier), [
            "opencode-example@1.2.3",
            "file:///tmp/project/.opencode/plugins/local.ts",
        ])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testResolvedConfigDefaultsMissingPluginListToEmpty() throws {
        let config = try JSONDecoder().decode(OpenCodeResolvedConfig.self, from: Data(#"{"model":"openai/gpt-5"}"#.utf8))

        XCTAssertEqual(config.plugins, [])
    }

    func testSetProviderAPIKeyUsesAuthEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/auth/openai")
            XCTAssertEqual(request.httpMethod, "PUT")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["type"] as? String, "api")
            XCTAssertEqual(json["key"] as? String, "sk-test")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.setProviderAPIKey(providerID: "openai", key: "sk-test")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testAuthorizeProviderOAuthUsesProviderOAuthEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider/openai/oauth/authorize")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["method"] as? Int, 1)
            XCTAssertEqual((json["inputs"] as? [String: String])?["account"], "pro")
            expectation.fulfill()

            let data = #"{"url":"https://auth.example.com","method":"auto","instructions":"Enter code: ABCD-EFGH"}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let authorization = try await client.authorizeProviderOAuth(providerID: "openai", method: 1, inputs: ["account": "pro"], directory: "/tmp/project")
        XCTAssertEqual(authorization?.method, "auto")
        XCTAssertEqual(authorization?.instructions, "Enter code: ABCD-EFGH")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testCompleteProviderOAuthUsesProviderOAuthCallbackEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/provider/github-copilot/oauth/callback")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["method"] as? Int, 0)
            XCTAssertEqual(json["code"] as? String, "oauth-code")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        let completed = try await client.completeProviderOAuth(providerID: "github-copilot", method: 0, code: "oauth-code")
        XCTAssertTrue(completed)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testUpdateGlobalConfigEncodesDisabledProviders() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/global/config")
            XCTAssertEqual(request.httpMethod, "PATCH")
            let body = try XCTUnwrap(Self.requestBodyData(request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["disabled_providers"] as? [String], ["custom"])
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }

        try await client.updateGlobalConfig(OpenCodeGlobalConfigPatch(provider: nil, disabledProviders: ["custom"]))
        await fulfillment(of: [expectation], timeout: 1)
    }

    private static func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    func testAbortSessionUsesAbortEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_test/abort")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 204, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }

        try await client.abortSession(sessionID: "ses_test", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListSessionStatusesUsesStatusEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/status")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            let data = """
            {
              \"ses_busy\": { \"type\": \"busy\" },
              \"ses_idle\": { \"type\": \"idle\" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let statuses = try await client.listSessionStatuses(directory: "/tmp/project")
        XCTAssertEqual(statuses, ["ses_busy": "busy", "ses_idle": "idle"])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListQuestionsUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let questions = try await client.listQuestions(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(questions, [])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListPermissionsUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/permission")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("[]".utf8)
            )
        }

        let permissions = try await client.listPermissions(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(permissions, [])
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testListMCPStatusUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/mcp")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            let data = """
            {
              \"github\": { \"status\": \"connected\" },
              \"broken\": { \"status\": \"failed\", \"error\": \"boom\" },
              \"oauth\": { \"status\": \"needs_client_registration\", \"error\": \"register first\" }
            }
            """.data(using: .utf8)!

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }

        let statuses = try await client.listMCPStatus(directory: "/tmp/project", workspaceID: "ws_123")
        XCTAssertEqual(statuses["github"]?.status, "connected")
        XCTAssertEqual(statuses["broken"]?.error, "boom")
        XCTAssertEqual(statuses["oauth"]?.displayStatus, "Needs Registration")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testConnectMCPServerUsesScopedConnectEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path(percentEncoded: true), "/mcp/local%20server/connect")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.connectMCPServer(name: "local server", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testDisconnectMCPServerUsesScopedDisconnectEndpoint() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/mcp/github/disconnect")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.disconnectMCPServer(name: "github", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testReplyToPermissionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/permission/p_123/reply")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"reply":"once"}"#)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.replyToPermission(requestID: "p_123", reply: "once", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testReplyToQuestionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question/q_123/reply")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"answers":[["Build"],["Ship"]]}"#)
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.replyToQuestion(requestID: "q_123", answers: [["Build"], ["Ship"]], directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testRejectQuestionUsesDirectoryAndWorkspaceScope() async throws {
        let expectation = expectation(description: "request captured")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: session
        )

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/question/q_123/reject")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("true".utf8)
            )
        }

        try await client.rejectQuestion(requestID: "q_123", directory: "/tmp/project", workspaceID: "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testEventURLsBuildScopedAndGlobalEndpoints() throws {
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"))
        let urls = try client.eventURLs(directory: "/tmp/project")
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://127.0.0.1:4096/event?directory=/tmp/project",
            "http://127.0.0.1:4096/global/event",
        ])
    }

    func testV2PTYConnectUsesV2EndpointAndLocationScope() throws {
        var client = makeProbeClient()
        client.v2Contract = .preview17155

        let request = try client.v2PTYConnectRequest(
            id: "pty-1", directory: "/repo", workspaceID: "workspace-1", cursor: 7
        )

        XCTAssertEqual(request.url?.path, "/api/pty/pty-1/connect")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value { result[item.name] = value }
            }
        XCTAssertEqual(query, ["location[directory]": "/repo", "location[workspace]": "workspace-1", "cursor": "7"])
        XCTAssertNil(request.url?.path.range(of: #"^/pty/"#, options: .regularExpression))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/repo")
    }

    func testLegacyPTYConnectKeepsLegacyEndpointAndWorkspaceScope() throws {
        let client = makeProbeClient()
        let request = try client.ptyConnectRequest(
            id: "pty-1", directory: "/repo", workspaceID: "workspace-1", cursor: 7
        )

        XCTAssertEqual(request.url?.path, "/pty/pty-1/connect")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            .reduce(into: [String: String]()) { result, item in
                if let value = item.value { result[item.name] = value }
            }
        XCTAssertEqual(query, ["directory": "/repo", "workspace": "workspace-1", "cursor": "7"])
    }

    private func makeProbeClient() -> OpenCodeAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4097", username: "opencode", password: "pw"),
            session: URLSession(configuration: configuration)
        )
    }
}

// Opt in only when explicitly validating the user's local server. Prompt fixtures
// remain paused so they cannot invoke inference; mutations use UUID-owned sessions.
@MainActor
final class OpenCodeRealServerAPIClientTests: XCTestCase {
    private struct Context {
        let client: OpenCodeAPIClient
        let connection: BackendConnection
        let snapshot: BackendProjectsSnapshot
        let scope: BackendScope
    }

    func testAutomaticDetectionBootstrapAndReadOnlySurfacesAgainstRealServer() async throws {
        let context = try await makeContext()
        defer { context.connection.close() }

        XCTAssertTrue(context.connection.healthy)
        XCTAssertEqual(context.connection.descriptor.version, "0.0.0-next-17155")
        XCTAssertFalse(context.snapshot.projects.isEmpty)
        XCTAssertEqual(context.snapshot.currentProject?.id, context.scope.projectID)
        XCTAssertEqual(context.snapshot.defaultDirectory, context.scope.directory)

        let adapter = try XCTUnwrap(context.connection.openCodeCompatibility)
        XCTAssertEqual(adapter.profile, .v2)
        XCTAssertEqual(adapter.client.config.apiPreference, .automatic)
        XCTAssertEqual(adapter.client.v2Contract, .preview17155)

        _ = try await context.connection.models.modelCatalog(scope: context.scope)
        _ = try await adapter.client.listV2ConfigurationEntries(directory: context.scope.directory)
        _ = try await adapter.client.listV2PendingPermissions(directory: context.scope.directory)
        let globalForms = try XCTUnwrap(context.connection.globalForms)
        let forms = try await globalForms.pendingGlobalForms(scope: context.scope)
        XCTAssertEqual(forms.location.directory, context.scope.directory)
    }

    func testOwnedSessionLifecycleAgainstRealServer() async throws {
        let context = try await makeContext()
        defer { context.connection.close() }
        let marker = "OpenClient real API \(UUID().uuidString)"

        let created = try await context.connection.sessions.createSession(.init(title: marker, scope: context.scope))
        cleanUpOwnedSession(created.id, marker: marker, client: context.client)
        XCTAssertEqual(created.title, marker)
        XCTAssertEqual(created.directory, context.scope.directory)

        let loaded = try await context.connection.sessions.session(id: created.id, scope: context.scope)
        XCTAssertEqual(loaded.id, created.id)
        XCTAssertEqual(loaded.title, marker)

        let renamedTitle = "\(marker) renamed"
        let renamed = try await context.connection.sessions.renameSession(id: created.id, title: renamedTitle, scope: context.scope)
        XCTAssertEqual(renamed.title, renamedTitle)
        let reloaded = try await context.connection.sessions.session(id: created.id, scope: context.scope)
        XCTAssertEqual(reloaded.title, renamedTitle)

        let transcript = try await context.connection.chat.transcript(sessionID: created.id, scope: context.scope, cursor: nil, limit: 20)
        XCTAssertTrue(transcript.messages.isEmpty)
        let permissions = try await context.client.listV2SessionPermissions(sessionID: created.id)
        XCTAssertTrue(permissions.isEmpty)
        let sessionForms = try XCTUnwrap(context.connection.sessionForms)
        let forms = try await sessionForms.pendingForms(sessionID: created.id, scope: context.scope)
        XCTAssertTrue(forms.isEmpty)

        let messageID = OpenCodeIdentifier.message()
        let receipt = try await context.client.admitV2TextPrompt(
            sessionID: created.id, messageID: messageID, text: "Fork boundary fixture", resume: false
        )
        XCTAssertEqual(receipt.id, messageID)
        XCTAssertEqual(receipt.sessionID, created.id)
        let pending = try await context.client.listV2PendingInputIDs(sessionID: created.id, endpoint: .pending)
        XCTAssertTrue(pending.contains(messageID))
        let stillEmpty = try await context.connection.chat.transcript(sessionID: created.id, scope: context.scope, cursor: nil, limit: 20)
        XCTAssertTrue(stillEmpty.messages.isEmpty, "Paused admission must not execute inference or create a transcript message")
        do {
            _ = try await context.client.forkV2Session(sessionID: created.id)
            XCTFail("The preview contract must reject a fork without a delivered transcript boundary")
        } catch let OpenCodeAPIError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            XCTAssertEqual(payload["kind"] as? String, "empty_session")
        }

        try await context.connection.sessions.deleteSession(id: created.id, scope: context.scope)
        try await assertMissing(created.id, client: context.client)
    }

    private func makeContext() async throws -> Context {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["OPENCODE_API_TEST_BASE_URL"], !baseURL.isEmpty else {
            throw XCTSkip("Set OPENCODE_API_TEST_BASE_URL to opt in to real-server API tests")
        }
        guard let url = URL(string: baseURL), url.scheme == "http", url.host == "127.0.0.1", url.port == 4097,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw OpenCodeRealServerTestError("Only http://127.0.0.1:4097 is permitted")
        }
        guard let username = environment["OPENCODE_API_TEST_USERNAME"], !username.isEmpty,
              let password = environment["OPENCODE_API_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set OPENCODE_API_TEST_USERNAME and OPENCODE_API_TEST_PASSWORD")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(
            baseURL: baseURL,
            username: username,
            password: password,
            apiPreference: .automatic
        ), session: session)
        let connection = try await OpenCodeBackendFactory(client: client, eventManager: OpenCodeEventManager()).connect()
        guard connection.descriptor.version == "0.0.0-next-17155" else {
            connection.close()
            throw OpenCodeRealServerTestError("Expected the authorized preview17155 server on port 4097")
        }
        let snapshot = try await connection.projects.projectsSnapshot()
        guard let project = snapshot.currentProject,
              let directory = snapshot.defaultDirectory, !directory.isEmpty else {
            connection.close()
            throw OpenCodeRealServerTestError("Real server bootstrap did not resolve a current project and directory")
        }
        return Context(client: try XCTUnwrap(connection.openCodeCompatibility?.client), connection: connection,
                       snapshot: snapshot, scope: .init(projectID: project.id, directory: directory))
    }

    private func cleanUpOwnedSession(_ sessionID: String, marker: String, client: OpenCodeAPIClient) {
        addTeardownBlock {
            do {
                let session = try await client.getV2Session(sessionID: sessionID)
                guard session.title?.hasPrefix(marker) == true else {
                    XCTFail("Refusing to delete a session not owned by this test: \(sessionID)")
                    return
                }
                try await client.deleteV2Session(sessionID: sessionID)
            } catch let OpenCodeAPIError.httpError(status, _) where status == 404 {
                // The successful lifecycle path already deleted this owned session.
            }
        }
    }

    private func assertMissing(_ sessionID: String, client: OpenCodeAPIClient) async throws {
        do {
            _ = try await client.getV2Session(sessionID: sessionID)
            XCTFail("Deleted session remained readable: \(sessionID)")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 404)
        }
    }
}

private struct OpenCodeRealServerTestError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// Opt in only against a disposable server. Prompts stay paused and imported fixtures
// exercise transcript reads without contacting a model provider.
final class OpenCodeV2LiveAPIClientTests: XCTestCase {
    private func makeClient() throws -> OpenCodeAPIClient {
        let fixture = try OpenCodeV2LiveFixture.load()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return OpenCodeAPIClient(config: .init(
            baseURL: OpenCodeV2LiveFixture.baseURL,
            username: fixture.username,
            password: fixture.password,
            apiPreference: .v2
        ), session: session)
    }

    private func cleanUpSession(_ sessionID: String, client: OpenCodeAPIClient) {
        addTeardownBlock {
            do {
                try await client.deleteV2Session(sessionID: sessionID)
            } catch let OpenCodeAPIError.httpError(status, _) where status == 404 {
                // A lifecycle test may already have deleted this exact session.
            }
        }
    }

    func testBootstrapAndCatalogsAgainstV2Backend() async throws {
        let client = try makeClient()
        guard case let .available(health) = try await client.probeV2() else {
            return XCTFail("The opted-in server must expose v2.")
        }
        XCTAssertTrue(health.healthy)
        let location = try await client.getV2Location()
        let bootstrap = try await client.bootstrapV2Projects()
        XCTAssertEqual(bootstrap.currentProject?.id, location.project.id)
        XCTAssertEqual(bootstrap.selectedDirectory, location.directory)
        let scopedLocation = try await client.getV2Location(directory: location.directory)
        XCTAssertEqual(scopedLocation.directory, location.directory)
        let project = try await client.currentV2Project(directory: location.directory)
        XCTAssertEqual(project.id, location.project.id)
        _ = try await client.listV2Agents(directory: location.directory)
        _ = try await client.listV2Commands(directory: location.directory)
        _ = try await client.listV2Providers(directory: location.directory)
        _ = try await client.defaultV2Model(directory: location.directory)
        _ = try await client.listV2ConfigurationEntries(directory: location.directory)
        _ = try await client.listV2MCPStatus(directory: location.directory)
        _ = try await client.listV2Files(directory: location.directory)
        _ = try await client.getV2VCSInfo(directory: location.directory)
        _ = try await client.listV2FileStatus(directory: location.directory)
    }

    func testSessionLifecycleAndPausedAdmissionAgainstV2Backend() async throws {
        let client = try makeClient()
        let location = try await client.getV2Location()
        let first = try await client.createV2Session(title: "OpenClient live API \(UUID().uuidString)", directory: location.directory, agent: "plan", model: .init(providerID: "test", modelID: "test-model"), variant: "high")
        cleanUpSession(first.id, client: client)
        let permissions = try await client.listV2SessionPermissions(sessionID: first.id)
        XCTAssertTrue(permissions.isEmpty)
        XCTAssertEqual(first.agent, "plan")
        XCTAssertEqual(first.model, .init(providerID: "test", modelID: "test-model", variant: "high"))
        let second = try await client.createV2Session(title: "OpenClient pagination \(UUID().uuidString)", directory: location.directory)
        cleanUpSession(second.id, client: client)
        let renamed = try await client.updateV2SessionTitle(sessionID: first.id, title: "Renamed API fixture")
        XCTAssertEqual(renamed.title, "Renamed API fixture")
        XCTAssertEqual(renamed.directory, location.directory)
        XCTAssertEqual(renamed.agent, first.agent)
        XCTAssertEqual(renamed.model, first.model)

        var cursor: String?
        var found = Set<String>()
        var cursors = Set<String>()
        for _ in 0 ..< 100 {
            let page = try await client.listV2Sessions(projectID: location.project.id, directory: location.directory, cursor: cursor, limit: 1)
            found.formUnion(page.sessions.map(\.id))
            if found.contains(first.id), found.contains(second.id) { break }
            guard let next = page.nextCursor else { break }
            XCTAssertTrue(cursors.insert(next).inserted)
            cursor = next
        }
        XCTAssertTrue(found.contains(first.id))
        XCTAssertTrue(found.contains(second.id))

        let messageID = OpenCodeIdentifier.message()
        let receipt = try await client.admitV2TextPrompt(
            sessionID: first.id, messageID: messageID, text: "Paused transport fixture",
            attachments: [.init(id: "attachment", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGVsbG8=")],
            resume: false
        )
        XCTAssertEqual(receipt.id, messageID)
        XCTAssertEqual(receipt.sessionID, first.id)
        let pendingIDs = try await client.listV2PendingInputIDs(sessionID: first.id, endpoint: .inbox)
        XCTAssertTrue(pendingIDs.contains(messageID))
        do {
            _ = try await client.getV2Message(sessionID: first.id, messageID: messageID)
            XCTFail("Paused admission should not yet be projected")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 404)
        }
        // Admission is durable pending input, not a delivered transcript message.
        let transcript = try await client.listV2Messages(sessionID: first.id)
        XCTAssertTrue(transcript.messages.isEmpty)
        let statuses = try await client.listV2SessionStatuses()
        XCTAssertNil(statuses[first.id])
        try await client.waitForV2Session(sessionID: first.id)

        do {
            _ = try await client.listV2Messages(sessionID: first.id, cursor: "not-a-valid-cursor")
            XCTFail("Expected invalid cursor rejection")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 400)
        }
        try await client.deleteV2Session(sessionID: first.id)
        do {
            _ = try await client.getV2Session(sessionID: first.id)
            XCTFail("Deleted session remained readable")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 404)
        }
    }

    func testFormLifecycleAgainstV2Backend() async throws {
        let client = try makeClient()
        let location = try await client.getV2Location()
        let session = try await client.createV2Session(title: "OpenClient form fixture", directory: location.directory)
        cleanUpSession(session.id, client: client)
        let form = try await client.createV2Form(sessionID: session.id, title: "Transport form", fields: [
            ["key": .string("choice"), "type": .string("string"), "required": .bool(true), "options": .array([.object(["label": .string("Display Label"), "value": .string("wire-value")])])],
            ["key": .string("count"), "type": .string("integer"), "required": .bool(true), "minimum": .number(1)],
        ])
        addTeardownBlock {
            let state = try await client.getV2FormState(sessionID: session.id, formID: form.id)
            if state.status == "pending" { try await client.cancelV2Form(sessionID: session.id, formID: form.id) }
        }
        let pending = try await client.listV2PendingForms(directory: location.directory)
        XCTAssertTrue(pending.contains { $0.id == form.id })
        let sessionForms = try await client.listV2SessionForms(sessionID: session.id)
        XCTAssertEqual(sessionForms.map(\.id), [form.id])
        let loadedForm = try await client.getV2Form(sessionID: session.id, formID: form.id)
        XCTAssertEqual(try loadedForm.normalized().questions.first?.options.first?.label, "Display Label")
        let initialState = try await client.getV2FormState(sessionID: session.id, formID: form.id)
        XCTAssertEqual(initialState.status, "pending")
        do {
            try await client.replyToV2Form(sessionID: session.id, formID: form.id, answer: ["choice": .string("Display Label")])
            XCTFail("Server must validate option values, not labels")
        } catch let OpenCodeAPIError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("choice"))
        }
        try await client.replyToV2Question(sessionID: session.id, requestID: form.id, answers: [["Display Label"], ["2"]])
        let answered = try await client.getV2FormState(sessionID: session.id, formID: form.id)
        XCTAssertEqual(answered.status, "answered")
        XCTAssertEqual(answered.answer, ["choice": .string("wire-value"), "count": .number(2)])
        let remaining = try await client.listV2SessionForms(sessionID: session.id)
        XCTAssertTrue(remaining.isEmpty)

        let cancelled = try await client.createV2Form(sessionID: session.id, title: "Cancel fixture", fields: [["key": .string("enabled"), "type": .string("boolean")]])
        addTeardownBlock {
            let state = try await client.getV2FormState(sessionID: session.id, formID: cancelled.id)
            if state.status == "pending" { try await client.cancelV2Form(sessionID: session.id, formID: cancelled.id) }
        }
        try await client.rejectV2Question(sessionID: session.id, requestID: cancelled.id)
        let cancelledState = try await client.getV2FormState(sessionID: session.id, formID: cancelled.id)
        XCTAssertEqual(cancelledState.status, "cancelled")
    }

    func testTranscriptPaginationAndForkAgainstV2Backend() async throws {
        let client = try makeClient()
        let location = try await client.getV2Location()
        let sessionID = "ses_openclient_fixture_\(UUID().uuidString)"
        let userID = OpenCodeIdentifier.message()
        let assistantID = OpenCodeIdentifier.message()
        // Import is test setup only. All reads, pagination, fork, and deletion below
        // exercise the production wrappers without executing an agent loop.
        let fixture: [String: Any] = [
            "info": ["id": sessionID, "projectID": location.project.id, "title": "Imported API fixture", "cost": 0,
                     "tokens": ["input": 0, "output": 0, "reasoning": 0, "cache": ["read": 0, "write": 0]],
                     "time": ["created": 1000, "updated": 2000], "location": ["directory": location.directory]],
            "messages": [
                ["id": userID, "type": "user", "time": ["created": 1000], "text": "Fixture",
                 "files": [["data": "aGVsbG8=", "mime": "text/plain", "name": "notes.txt", "source": ["type": "inline"]]]],
                ["id": assistantID, "type": "assistant", "agent": "build", "model": ["providerID": "fixture", "id": "fixture"],
                 "time": ["created": 2000, "completed": 2200], "finish": "stop",
                 "content": [["type": "reasoning", "text": "Fixture reasoning"], ["type": "text", "text": "Fixture answer"]]],
            ],
        ]
        var request = URLRequest(url: try XCTUnwrap(client.config.sanitizedBaseURL).appendingPathComponent("api/experimental/session/import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credentials = Data("\(client.config.username):\(client.config.password)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: fixture)
        cleanUpSession(sessionID, client: client)
        let (_, response) = try await client.session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)

        let first = try await client.listV2Messages(sessionID: sessionID, limit: 1)
        XCTAssertEqual(first.messages.map(\.id), [assistantID])
        XCTAssertEqual(first.messages.first?.parts.map(\.id), ["\(assistantID):v2:reasoning:0", "\(assistantID):v2:text:0"])
        let second = try await client.listV2Messages(sessionID: sessionID, cursor: XCTUnwrap(first.olderCursor), limit: 1)
        XCTAssertEqual(second.messages.map(\.id), [userID])
        XCTAssertEqual(second.messages.first?.parts.last?.url, "data:text/plain;base64,aGVsbG8=")
        let message = try await client.getV2Message(sessionID: sessionID, messageID: userID)
        XCTAssertEqual(message, second.messages.first)
        let fork = try await client.forkV2Session(sessionID: sessionID, messageID: assistantID)
        cleanUpSession(fork.id, client: client)
        XCTAssertNil(fork.parentID, "Fork provenance is distinct from subagent parentID")
        let forkMessages = try await client.listV2Messages(sessionID: fork.id)
        XCTAssertEqual(forkMessages.messages.count, 1)
        XCTAssertEqual(forkMessages.messages.first?.parts.first?.text, "Fixture")
    }

    func testAuthenticationFailureAgainstV2Backend() async throws {
        let client = try makeClient()
        var invalidConfig = client.config
        invalidConfig.username = "openclient-invalid-\(UUID().uuidString)"
        invalidConfig.password = UUID().uuidString
        let invalidClient = OpenCodeAPIClient(config: invalidConfig, session: client.session)
        do {
            _ = try await invalidClient.probeV2()
            XCTFail("This opt-in test requires an authenticated v2 server")
        } catch let OpenCodeAPIError.httpError(status, _) {
            XCTAssertEqual(status, 401)
        }
    }

    @MainActor
    func testSSELifecycleAndPausedAdmissionAgainstV2Backend() async throws {
        let client = try makeClient()
        guard case let .available(health) = try await client.probeV2() else {
            return XCTFail("The opted-in server must expose v2.")
        }
        guard health.version == OpenCodeV2LiveFixture.version else {
            throw XCTSkip("This live SSE vocabulary requires the manifest-pinned v2 runtime.")
        }
        let location = try await client.getV2Location()
        let manager = OpenCodeEventManager()
        let recorder = OpenCodeV2LiveSSERecorder()
        defer {
            manager.stop()
            recorder.debugReport()
        }
        manager.startV2(
            client: client,
            onStatus: { await recorder.recordStatus($0) },
            onDroppedEvent: { await recorder.recordDrop($0) },
            consume: { client, url, status, activity, event in
                await recorder.consumerStarted()
                // Instrument the real stream without replacing its parser or the
                // manager's canonical decode/generation/cancellation pipeline.
                await OpenCodeEventStream.consume(
                    client: client, url: url, onStatus: status, onActivity: activity,
                    onRawLine: { await recorder.recordRawLine($0) },
                    onEvent: event
                )
                await recorder.consumerEnded()
            },
            onEvent: { await recorder.recordEvent($0) }
        )

        do {
            let connected = try await recorder.waitFor(type: "server.connected")
            XCTAssertNotNil(connected.id)
            let session = try await client.createV2Session(title: "OpenClient SSE \(UUID().uuidString)", directory: location.directory)
            cleanUpSession(session.id, client: client)
            let created = try await recorder.waitFor(type: "session.created", sessionID: session.id)
            XCTAssertEqual(created.routingLocation?.directory, session.directory)
            XCTAssertEqual(recorder.directory.sessions.first { $0.id == session.id }?.title, session.title)

            let form = try await client.createV2Form(sessionID: session.id, title: "SSE confirmation", fields: [
                ["key": .string("confirm"), "type": .string("boolean"), "required": .bool(true)],
            ])
            addTeardownBlock {
                do {
                    let state = try await client.getV2FormState(sessionID: session.id, formID: form.id)
                    if state.status == "pending" { try await client.cancelV2Form(sessionID: session.id, formID: form.id) }
                } catch let OpenCodeAPIError.httpError(status, _) where status == 404 {
                    // The successful path deletes this session after observing its events.
                }
            }
            let asked = try await recorder.waitFor(type: "form.created", sessionID: session.id)
            XCTAssertEqual(asked.data.objectValue?["form"]?.objectValue?["id"]?.literalStringValue, form.id)
            XCTAssertEqual(recorder.directory.v2FormsByID[form.id]?.fields.first?["required"], .bool(true))
            let visible = try XCTUnwrap(recorder.directory.sessionFormStore.forms[form.backendForm.key])
            XCTAssertEqual(visible, form.backendForm)
            XCTAssertEqual(visible.fields.map(\.raw), [["key": .string("confirm"), "type": .string("boolean"), "required": .bool(true)]])
            XCTAssertEqual(try visible.contract.answer(values: ["confirm": .bool(false)]), ["confirm": .boolean(false)])
            XCTAssertEqual(SessionInteractionStore.forms(forSessionTreeRootID: session.id,
                sessions: recorder.directory.sessions, forms: Array(recorder.directory.sessionFormStore.forms.values)), [visible])
            XCTAssertTrue(recorder.directory.syncState.questionsBySessionID[session.id]?.isEmpty ?? true)

            let messageID = OpenCodeIdentifier.message()
            let text = "Paused SSE fixture \(UUID().uuidString)"
            _ = try await client.admitV2TextPrompt(sessionID: session.id, messageID: messageID, text: text, resume: false)
            let admitted = try await recorder.waitFor(type: "session.inbox.enqueued", sessionID: session.id)
            // Assert the current wire vocabulary and the boundary aliases consumed by stores.
            XCTAssertEqual(admitted.data.objectValue?["inboxID"]?.literalStringValue, messageID)
            XCTAssertEqual(admitted.data.objectValue?["item"]?.objectValue?["type"]?.literalStringValue, "user")
            XCTAssertEqual(admitted.data.objectValue?["item"]?.objectValue?["payload"]?.objectValue?["text"]?.literalStringValue, text)
            XCTAssertEqual(admitted.inputID, messageID)
            XCTAssertEqual(admitted.admittedInput?.type.rawValue, "user")
            XCTAssertEqual(admitted.admittedInput?.data.text, text)
            let pendingIDs = try await client.listV2PendingInputIDs(sessionID: session.id, endpoint: .inbox)
            XCTAssertTrue(pendingIDs.contains(messageID))
            let transcript = try await client.listV2Messages(sessionID: session.id)
            XCTAssertTrue(transcript.messages.isEmpty)

            try await client.cancelV2Form(sessionID: session.id, formID: form.id)
            let cancelled = try await recorder.waitFor(type: "form.cancelled", sessionID: session.id)
            XCTAssertEqual(cancelled.data.objectValue?["id"]?.literalStringValue, form.id)
            XCTAssertNil(recorder.directory.v2FormsByID[form.id])
            XCTAssertNil(recorder.directory.sessionFormStore.forms[visible.key])
            XCTAssertTrue(recorder.directory.syncState.questionsBySessionID[session.id]?.isEmpty ?? true)
            try await client.deleteV2Session(sessionID: session.id)
            _ = try await recorder.waitFor(type: "session.deleted", sessionID: session.id)
            XCTAssertFalse(recorder.directory.sessions.contains { $0.id == session.id })
            XCTAssertFalse(recorder.events.contains { $0.sessionID == session.id && $0.isExecutionStarted })
        } catch {
            let stopped = await recorder.stopAndWait(manager)
            XCTAssertTrue(stopped, "SSE shutdown exceeded five seconds after failure")
            throw error
        }

        let stopped = await recorder.stopAndWait(manager)
        XCTAssertTrue(stopped, "SSE shutdown exceeded five seconds")
        XCTAssertEqual(recorder.consumerStarts, 1)
        XCTAssertEqual(recorder.consumerEnds, 1, "The real AsyncBytes consumer must finish on cancellation")
        XCTAssertTrue(recorder.drops.isEmpty)
        let callbackCount = recorder.callbackCount
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recorder.callbackCount, callbackCount, "Callbacks continued after stopAndWait")
    }
}

@MainActor
private final class OpenCodeV2LiveSSERecorder {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    let directory = DirectoryStore()
    private(set) var events: [OpenCodeV2ManagedEvent] = []
    private(set) var drops: [String] = []
    private(set) var consumerStarts = 0
    private(set) var consumerEnds = 0
    private(set) var callbackCount = 0
    private var statuses: [String] = []
    private var rawPayloads: [String] = []
    private var streamFailure: String?

    func consumerStarted() { consumerStarts += 1 }
    func consumerEnded() { consumerEnds += 1 }

    func recordStatus(_ status: String) {
        callbackCount += 1
        if statuses.count < 16 { statuses.append(String(status.prefix(200))) }
        if status.contains("error") || status.contains("invalid") || status.contains("timeout") || status.hasPrefix("stream http ") {
            streamFailure = String(status.prefix(200))
        }
    }

    func recordDrop(_ message: String) {
        callbackCount += 1
        if drops.count < 8 { drops.append(String(message.prefix(200))) }
    }

    func recordRawLine(_ line: String) {
        #if DEBUG
        if line.hasPrefix("data:"), rawPayloads.count < 12 { rawPayloads.append(String(line.prefix(1_200))) }
        #endif
    }

    func recordEvent(_ event: OpenCodeV2ManagedEvent) {
        callbackCount += 1
        if events.count == 128 { events.removeFirst() }
        events.append(event)
        directory.applyV2Event(event)
    }

    func waitFor(type: String, sessionID: String? = nil) async throws -> OpenCodeV2ManagedEvent {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let streamFailure { throw Failure(description: streamFailure) }
            if let drop = drops.first { throw Failure(description: drop) }
            if let event = events.first(where: { $0.type == type && (sessionID == nil || $0.sessionID == sessionID) }) {
                return event
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let recentTypes = events.suffix(16).map { String($0.type.prefix(80)) }.joined(separator: ", ")
        throw Failure(description: "Timed out waiting for \(type); received \(recentTypes)")
    }

    func stopAndWait(_ manager: OpenCodeEventManager) async -> Bool {
        let stopped = XCTestExpectation(description: "real SSE consumer stopped")
        let shutdown = Task {
            await manager.stopAndWait()
            stopped.fulfill()
        }
        defer {
            shutdown.cancel()
            manager.stop()
        }
        // An unstructured waiter keeps a broken cancellation path from hanging
        // the whole test process, unlike a task-group timeout that must join it.
        return await XCTWaiter.fulfillment(of: [stopped], timeout: 5) == .completed
    }

    func debugReport() {
        #if DEBUG
        print("[OpenCodeV2LiveSSE] consumers=\(consumerStarts)/\(consumerEnds) statuses=\(statuses) drops=\(drops)")
        for payload in rawPayloads { print("[OpenCodeV2LiveSSE] payload=\(payload)") }
        #endif
    }
}

private func requestBodyString(for request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }

    return String(data: data, encoding: .utf8)
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
