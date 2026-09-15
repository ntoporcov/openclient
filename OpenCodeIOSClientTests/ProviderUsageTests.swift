import XCTest
@testable import OpenClient

final class ProviderUsageTests: XCTestCase {
    override func tearDown() {
        ProviderUsageURLProtocol.handler = nil
        ProviderUsageURLProtocol.stopHandler = nil
        super.tearDown()
    }

    func testCodexFetchUsesFixedEndpointAndMapsSubscriptionWindows() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expiresAt = Date(timeIntervalSince1970: 2_000_003_600)
        let transport = ProviderUsageTransportStub(response: .init(
            statusCode: 200,
            headers: [:],
            body: Data(Self.codexUsageResponse.utf8)
        ))
        let snapshot = try await CodexUsageAdapter(transport: transport, now: { now }).fetch(
            accessToken: "  fixture-access-token  ",
            accountID: " acct_fixture ",
            credentialExpiresAt: expiresAt
        )

        let recordedRequest = await transport.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct_fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        let allowedOrigin = await transport.lastAllowedOrigin
        XCTAssertEqual(allowedOrigin?.absoluteString, "https://chatgpt.com")

        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.accountID, "acct_fixture")
        XCTAssertEqual(snapshot.plan, "future_plan")
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.credentialExpiresAt, expiresAt)
        XCTAssertEqual(snapshot.metrics.count, 4)

        let primary = try XCTUnwrap(snapshot.metrics.first { $0.id == "codex.rate-limit.primary" })
        XCTAssertEqual(primary.kind, .quota)
        XCTAssertEqual(primary.period, .rolling(seconds: 18_000))
        XCTAssertEqual(primary.percentUsed, 25.5)
        XCTAssertEqual(primary.resetAt, Date(timeIntervalSince1970: 2_000_001_800))

        let additional = try XCTUnwrap(snapshot.metrics.first { $0.sourceLabel == "GPT Future" })
        XCTAssertTrue(additional.id.hasPrefix("codex.additional."))
        XCTAssertTrue(additional.id.hasSuffix(".primary"))
        XCTAssertEqual(additional.sourceLabel, "GPT Future")
        XCTAssertEqual(additional.period, .rolling(seconds: 3_600))
        XCTAssertEqual(additional.percentUsed, 120)

        let credits = try XCTUnwrap(snapshot.metrics.first { $0.id == "codex.credits.balance" })
        XCTAssertEqual(credits.kind, .balance)
        XCTAssertEqual(credits.remaining, Decimal(string: "12.75"))
        XCTAssertFalse(credits.isUnlimited)
    }

    func testCodexDropsMalformedWindowWithoutLosingValidSibling() async throws {
        let body = #"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":"bad","reset_at":2000,"limit_window_seconds":18000},"secondary_window":{"used_percent":42,"reset_at":3000,"limit_window_seconds":604800}},"additional_rate_limits":["bad",{"limit_name":"Valid","rate_limit":{"primary_window":{"used_percent":9,"reset_at":4000,"limit_window_seconds":3600}}}]}"#
        let snapshot = try await CodexUsageAdapter(
            transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(body.utf8))),
            now: { Date(timeIntervalSince1970: 1_000) }
        ).fetch(accessToken: "fixture", accountID: nil, credentialExpiresAt: nil)

        XCTAssertNil(snapshot.metrics.first { $0.id == "codex.rate-limit.primary" })
        XCTAssertEqual(snapshot.metrics.first { $0.id == "codex.rate-limit.secondary" }?.percentUsed, 42)
        XCTAssertNotNil(snapshot.metrics.first { $0.sourceLabel == "Valid" })
    }

    func testCodexAdditionalLimitIDsSurviveServerReordering() async throws {
        let firstBody = #"{"additional_rate_limits":[{"limit_name":"Alpha","metered_feature":"alpha","rate_limit":{"primary_window":{"used_percent":9,"reset_at":4000,"limit_window_seconds":3600}}},{"limit_name":"Beta","metered_feature":"beta","rate_limit":{"primary_window":{"used_percent":12,"reset_at":5000,"limit_window_seconds":7200}}}]}"#
        let secondBody = #"{"additional_rate_limits":[{"limit_name":"Beta","metered_feature":"beta","rate_limit":{"primary_window":{"used_percent":12,"reset_at":5000,"limit_window_seconds":7200}}},{"limit_name":"Alpha","metered_feature":"alpha","rate_limit":{"primary_window":{"used_percent":9,"reset_at":4000,"limit_window_seconds":3600}}}]}"#

        let first = try await CodexUsageAdapter(
            transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(firstBody.utf8)))
        ).fetch(accessToken: "fixture", accountID: nil, credentialExpiresAt: nil)
        let second = try await CodexUsageAdapter(
            transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(secondBody.utf8)))
        ).fetch(accessToken: "fixture", accountID: nil, credentialExpiresAt: nil)

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: first.metrics.compactMap { metric in
                metric.sourceLabel.map { ($0, metric.id) }
            }),
            Dictionary(uniqueKeysWithValues: second.metrics.compactMap { metric in
                metric.sourceLabel.map { ($0, metric.id) }
            })
        )
    }

    func testCodexRejectsExpiredCredentialAndAccountMismatch() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let unused = ProviderUsageTransportStub(response: .init(statusCode: 500, headers: [:], body: Data()))
        do {
            _ = try await CodexUsageAdapter(transport: unused, now: { now }).fetch(
                accessToken: "fixture",
                accountID: "acct_fixture",
                credentialExpiresAt: now
            )
            XCTFail("Expected expired credential")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .credentialExpired)
            let lastRequest = await unused.lastRequest
            XCTAssertNil(lastRequest)
        }

        let mismatch = ProviderUsageTransportStub(response: .init(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"account_id":"acct_other","plan_type":"pro"}"#.utf8)
        ))
        do {
            _ = try await CodexUsageAdapter(transport: mismatch, now: { now }).fetch(
                accessToken: "fixture",
                accountID: "acct_fixture",
                credentialExpiresAt: nil
            )
            XCTFail("Expected account mismatch")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .accountMismatch)
        }
    }

    func testCodexErrorsAreTypedAndSanitized() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for (status, expected) in [
            (301, ProviderUsageError.redirectRejected),
            (401, ProviderUsageError.unauthorized),
            (403, ProviderUsageError.forbidden),
            (500, ProviderUsageError.httpStatus(500)),
        ] {
            let transport = ProviderUsageTransportStub(response: .init(
                statusCode: status,
                headers: [:],
                body: Data("fixture-access-token-server-echo".utf8)
            ))
            do {
                _ = try await CodexUsageAdapter(transport: transport, now: { now }).fetch(
                    accessToken: "fixture-access-token",
                    accountID: nil,
                    credentialExpiresAt: nil
                )
                XCTFail("Expected status \(status) to fail")
            } catch let error as ProviderUsageError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(String(describing: error).contains("fixture-access-token"))
            }
        }

        let limited = ProviderUsageTransportStub(response: .init(
            statusCode: 429,
            headers: ["Retry-After": "60"],
            body: Data()
        ))
        do {
            _ = try await CodexUsageAdapter(transport: limited, now: { now }).fetch(
                accessToken: "fixture",
                accountID: nil,
                credentialExpiresAt: nil
            )
            XCTFail("Expected rate limit")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_060)))
        }
    }

    func testCodexRejectsHeaderInjectionAndMalformedResponse() async throws {
        let unused = ProviderUsageTransportStub(response: .init(statusCode: 500, headers: [:], body: Data()))
        for (token, accountID) in [("fixture\ntoken", nil), ("fixture", "acct\r\ninjected")] as [(String, String?)] {
            do {
                _ = try await CodexUsageAdapter(transport: unused).fetch(
                    accessToken: token,
                    accountID: accountID,
                    credentialExpiresAt: nil
                )
                XCTFail("Expected invalid credential")
            } catch let error as ProviderUsageError {
                XCTAssertEqual(error, .invalidCredential)
            }
        }
        let lastRequest = await unused.lastRequest
        XCTAssertNil(lastRequest)

        let malformed = ProviderUsageTransportStub(response: .init(
            statusCode: 200,
            headers: [:],
            body: Data("[]".utf8)
        ))
        do {
            _ = try await CodexUsageAdapter(transport: malformed).fetch(
                accessToken: "fixture",
                accountID: nil,
                credentialExpiresAt: nil
            )
            XCTFail("Expected malformed response")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .malformedResponse)
        }
    }

    func testOpenRouterFetchUsesFixedEndpointAndMapsKeyUsage() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let transport = ProviderUsageTransportStub(response: .init(
            statusCode: 200,
            headers: [:],
            body: Data(Self.openRouterKeyResponse.utf8)
        ))
        let snapshot = try await OpenRouterUsageAdapter(transport: transport, now: { now })
            .fetch(apiKey: "  fixture-secret  ")

        let recordedRequest = await transport.lastRequest
        let request = try XCTUnwrap(recordedRequest)
        let allowedOrigin = await transport.lastAllowedOrigin
        let maximumResponseBytes = await transport.lastMaximumResponseBytes
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/key")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(allowedOrigin?.absoluteString, "https://openrouter.ai")
        XCTAssertEqual(maximumResponseBytes, 1_048_576)

        XCTAssertEqual(snapshot.provider, .openRouter)
        XCTAssertEqual(snapshot.accountLabel, "Work key")
        XCTAssertEqual(snapshot.fetchedAt, now)
        XCTAssertEqual(snapshot.credentialExpiresAt, Date(timeIntervalSince1970: 1_830_297_599))
        XCTAssertEqual(snapshot.metrics.count, 9)
        XCTAssertEqual(snapshot.metrics.first { $0.id == "openrouter.spend.month" }?.used, Decimal(string: "12.5"))
        XCTAssertEqual(snapshot.metrics.first { $0.id == "openrouter.byok-spend.month" }?.used, Decimal(string: "3.5"))

        let limit = try XCTUnwrap(snapshot.metrics.first { $0.id == "openrouter.spending-limit" })
        XCTAssertEqual(limit.period, .month)
        XCTAssertEqual(limit.limit, 100)
        XCTAssertEqual(limit.remaining, Decimal(string: "74.5"))
        XCTAssertEqual(limit.used, Decimal(string: "25.5"))
        XCTAssertEqual(limit.percentUsed, 25.5)
    }

    func testOpenRouterDerivesLimitUsingMatchingResetWindowAndBYOK() async throws {
        let body = #"{"data":{"label":"Derived","limit":20,"limit_remaining":null,"limit_reset":"weekly","usage":99,"usage_daily":1,"usage_weekly":4,"usage_monthly":8,"byok_usage":90,"byok_usage_daily":2,"byok_usage_weekly":3,"byok_usage_monthly":6,"include_byok_in_limit":true}}"#
        let snapshot = try await OpenRouterUsageAdapter(
            transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(body.utf8)))
        ).fetch(apiKey: "fixture")
        let limit = try XCTUnwrap(snapshot.metrics.first { $0.id == "openrouter.spending-limit" })

        XCTAssertEqual(limit.period, .week)
        XCTAssertEqual(limit.used, 7)
        XCTAssertEqual(limit.remaining, 13)
        XCTAssertEqual(limit.percentUsed, 35)
    }

    func testOpenRouterNoLimitDoesNotInventLimitMetric() async throws {
        let body = #"{"data":{"label":"Unlimited","limit":null,"limit_remaining":null,"limit_reset":null,"usage":2,"usage_daily":1,"usage_weekly":2,"usage_monthly":2,"include_byok_in_limit":false}}"#
        let snapshot = try await OpenRouterUsageAdapter(
            transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(body.utf8)))
        ).fetch(apiKey: "fixture")

        XCTAssertNil(snapshot.metrics.first { $0.kind == .spendingLimit })
        XCTAssertFalse(snapshot.metrics.contains { $0.kind == .externalSpend })
    }

    func testOpenRouterUnknownResetAndMissingBYOKDoNotInventDerivedLimitUsage() async throws {
        for body in [
            #"{"data":{"label":"Future window","limit":20,"limit_remaining":null,"limit_reset":"fortnightly","usage":12,"usage_daily":1,"usage_weekly":4,"usage_monthly":8,"include_byok_in_limit":false}}"#,
            #"{"data":{"label":"Missing BYOK","limit":20,"limit_remaining":null,"limit_reset":"weekly","usage":12,"usage_daily":1,"usage_weekly":4,"usage_monthly":8,"include_byok_in_limit":true}}"#,
        ] {
            let snapshot = try await OpenRouterUsageAdapter(
                transport: ProviderUsageTransportStub(response: .init(statusCode: 200, headers: [:], body: Data(body.utf8)))
            ).fetch(apiKey: "fixture")
            let limit = try XCTUnwrap(snapshot.metrics.first { $0.id == "openrouter.spending-limit" })
            XCTAssertNil(limit.used)
            XCTAssertNil(limit.remaining)
            XCTAssertNil(limit.percentUsed)
        }
    }

    func testOpenRouterErrorsAreTypedAndDoNotContainResponseBodies() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        for (status, expected) in [
            (301, ProviderUsageError.redirectRejected),
            (401, ProviderUsageError.unauthorized),
            (403, ProviderUsageError.forbidden),
            (500, ProviderUsageError.httpStatus(500)),
        ] {
            let transport = ProviderUsageTransportStub(response: .init(
                statusCode: status,
                headers: [:],
                body: Data("fixture-secret-server-echo".utf8)
            ))
            do {
                _ = try await OpenRouterUsageAdapter(transport: transport, now: { now }).fetch(apiKey: "fixture-secret")
                XCTFail("Expected status \(status) to fail")
            } catch let error as ProviderUsageError {
                XCTAssertEqual(error, expected)
                XCTAssertFalse(String(describing: error).contains("fixture-secret"))
            }
        }

        let limited = ProviderUsageTransportStub(response: .init(
            statusCode: 429,
            headers: ["retry-after": "120"],
            body: Data("fixture-secret-server-echo".utf8)
        ))
        do {
            _ = try await OpenRouterUsageAdapter(transport: limited, now: { now }).fetch(apiKey: "fixture-secret")
            XCTFail("Expected rate limit")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_120)))
        }

        let httpDateLimited = ProviderUsageTransportStub(response: .init(
            statusCode: 429,
            headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
            body: Data()
        ))
        do {
            _ = try await OpenRouterUsageAdapter(transport: httpDateLimited, now: { now }).fetch(apiKey: "fixture-secret")
            XCTFail("Expected rate limit")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .rateLimited(retryAfter: Date(timeIntervalSince1970: 1_445_412_480)))
        }
    }

    func testOpenRouterRejectsMalformedResponseAndEmptyCredential() async throws {
        let malformed = ProviderUsageTransportStub(response: .init(
            statusCode: 200,
            headers: [:],
            body: Data(#"{"data":{"label":"Missing usage"}}"#.utf8)
        ))
        do {
            _ = try await OpenRouterUsageAdapter(transport: malformed).fetch(apiKey: "fixture")
            XCTFail("Expected malformed response")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .malformedResponse)
        }

        let unused = ProviderUsageTransportStub(response: .init(statusCode: 500, headers: [:], body: Data()))
        do {
            _ = try await OpenRouterUsageAdapter(transport: unused).fetch(apiKey: "   ")
            XCTFail("Expected invalid credential")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .invalidCredential)
            let lastRequest = await unused.lastRequest
            XCTAssertNil(lastRequest)
        }
    }

    func testHTTPClientRejectsInsecureAndCrossOriginRequestsBeforeLoading() async throws {
        let client = ProviderUsageHTTPClient()
        let allowed = try XCTUnwrap(URL(string: "https://openrouter.ai"))

        do {
            _ = try await client.send(
                URLRequest(url: try XCTUnwrap(URL(string: "http://openrouter.ai/api/v1/key"))),
                allowedOrigin: allowed,
                maximumResponseBytes: 100
            )
            XCTFail("Expected insecure transport rejection")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .insecureTransport)
        }

        do {
            _ = try await client.send(
                URLRequest(url: try XCTUnwrap(URL(string: "https://example.com/api/v1/key"))),
                allowedOrigin: allowed,
                maximumResponseBytes: 100
            )
            XCTFail("Expected cross-origin rejection")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .disallowedOrigin)
        }
    }

    func testHTTPClientBoundsStreamedResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUsageURLProtocol.self]
        ProviderUsageURLProtocol.handler = { protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            protocolInstance.client?.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            protocolInstance.client?.urlProtocol(protocolInstance, didLoad: Data(repeating: 65, count: 101))
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        do {
            _ = try await ProviderUsageHTTPClient(sessionConfiguration: configuration).send(
                URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!),
                allowedOrigin: URL(string: "https://openrouter.ai")!,
                maximumResponseBytes: 100
            )
            XCTFail("Expected bounded response rejection")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testHTTPClientRejectsRedirectWithoutLoadingDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUsageURLProtocol.self]
        let requests = ProviderUsageRequestCounter()
        ProviderUsageURLProtocol.handler = { protocolInstance in
            requests.increment()
            let destination = URL(string: "https://example.com/collect")!
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": destination.absoluteString]
            )!
            protocolInstance.client?.urlProtocol(
                protocolInstance,
                wasRedirectedTo: URLRequest(url: destination),
                redirectResponse: response
            )
            protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
        }

        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer fixture-secret", forHTTPHeaderField: "Authorization")
        do {
            _ = try await ProviderUsageHTTPClient(sessionConfiguration: configuration).send(
                request,
                allowedOrigin: URL(string: "https://openrouter.ai")!,
                maximumResponseBytes: 100
            )
            XCTFail("Expected redirect rejection")
        } catch let error as ProviderUsageError {
            XCTAssertEqual(error, .redirectRejected)
            XCTAssertEqual(requests.value, 1)
        }
    }

    func testHTTPClientCancellationStopsLoading() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderUsageURLProtocol.self]
        let signal = ProviderUsageRequestSignal()
        ProviderUsageURLProtocol.handler = { _ in
            Task { await signal.markStarted() }
        }
        ProviderUsageURLProtocol.stopHandler = {
            Task { await signal.markStopped() }
        }

        let requestTask = Task {
            try await ProviderUsageHTTPClient(sessionConfiguration: configuration).send(
                URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!),
                allowedOrigin: URL(string: "https://openrouter.ai")!,
                maximumResponseBytes: 100
            )
        }
        await signal.waitUntilStarted()
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
        await signal.waitUntilStopped()
    }

    private static let openRouterKeyResponse = #"""
    {
      "data": {
        "label": "Work key",
        "limit": 100,
        "limit_remaining": 74.5,
        "limit_reset": "monthly",
        "usage": 30,
        "usage_daily": 1.5,
        "usage_weekly": 8,
        "usage_monthly": 12.5,
        "byok_usage": 5,
        "byok_usage_daily": 0.5,
        "byok_usage_weekly": 2,
        "byok_usage_monthly": 3.5,
        "include_byok_in_limit": false,
        "expires_at": "2027-12-31T23:59:59.000Z",
        "is_free_tier": false,
        "is_management_key": false,
        "future_field": "ignored"
      }
    }
    """#

    private static let codexUsageResponse = #"""
    {
      "account_id": "acct_fixture",
      "plan_type": "future_plan",
      "rate_limit": {
        "primary_window": {
          "used_percent": 25.5,
          "reset_at": 2000001800,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 60,
          "reset_at": 2000604800,
          "limit_window_seconds": 604800
        }
      },
      "credits": {
        "has_credits": true,
        "unlimited": false,
        "balance": "12.75"
      },
      "additional_rate_limits": [
        {
          "limit_name": "GPT Future",
          "metered_feature": "future-model",
          "rate_limit": {
            "primary_window": {
              "used_percent": 120,
              "reset_at": 2000003600,
              "limit_window_seconds": 3600
            }
          }
        },
        "malformed sibling"
      ]
    }
    """#
}

private actor ProviderUsageTransportStub: ProviderUsageHTTPTransport {
    let response: ProviderUsageHTTPResponse
    private(set) var lastRequest: URLRequest?
    private(set) var lastAllowedOrigin: URL?
    private(set) var lastMaximumResponseBytes: Int?

    init(response: ProviderUsageHTTPResponse) {
        self.response = response
    }

    func send(
        _ request: URLRequest,
        allowedOrigin: URL,
        maximumResponseBytes: Int
    ) async throws -> ProviderUsageHTTPResponse {
        lastRequest = request
        lastAllowedOrigin = allowedOrigin
        lastMaximumResponseBytes = maximumResponseBytes
        return response
    }
}

private final class ProviderUsageRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor ProviderUsageRequestSignal {
    private var didStart = false
    private var didStop = false
    private var startContinuations: [CheckedContinuation<Void, Never>] = []
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        didStart = true
        startContinuations.forEach { $0.resume() }
        startContinuations.removeAll()
    }

    func markStopped() {
        didStop = true
        stopContinuations.forEach { $0.resume() }
        stopContinuations.removeAll()
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func waitUntilStopped() async {
        guard !didStop else { return }
        await withCheckedContinuation { stopContinuations.append($0) }
    }
}

private final class ProviderUsageURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((ProviderUsageURLProtocol) -> Void)?
    nonisolated(unsafe) static var stopHandler: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.handler?(self)
    }

    override func stopLoading() {
        Self.stopHandler?()
    }
}
