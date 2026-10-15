import XCTest
@testable import OpenClient

final class DSHSessionContextMetricsTests: XCTestCase {
    func testRingUsesProjectedContextNotCumulativeTokensOrEstimatedBreakdown() throws {
        let metrics = try metrics("""
        {"contextPressure":{"pressureTokens":250,"projectedTokens":400,"contextWindow":1000},
         "tokenUsage":{"uncachedInputTokens":900000,"outputTokens":500000,"cacheReadTokens":200000,"cacheWriteTokens":100000},
         "contextBreakdown":{"systemTokens":600,"toolsTokens":200,"messageTokens":800}}
        """)
        XCTAssertEqual(metrics.context?.total, 400)
        XCTAssertEqual(metrics.context?.usage, 40)
        XCTAssertEqual(metrics.context?.input, 250)
        XCTAssertEqual(value(metrics, "usage", "total"), .integer(1_700_000))
        XCTAssertTrue(metrics.breakdown.isEmpty, "Do not reuse transcript-length estimates for DSH")
    }

    func testReportedPressureIsFallbackAndZeroIsKnown() throws {
        let fallback = try metrics(#"{"contextPressure":{"pressureTokens":250,"contextWindow":1000}}"#)
        XCTAssertEqual(fallback.context?.total, 250)
        XCTAssertEqual(fallback.context?.usage, 25)
        let zero = try metrics(#"{"contextPressure":{"projectedTokens":0,"pressureTokens":500,"contextWindow":1000}}"#)
        XCTAssertEqual(zero.context?.total, 0)
        XCTAssertEqual(zero.context?.usage, 0)
    }

    func testUnknownCapacityAndUnknownUsageStayDistinct() throws {
        for pressure in [#"{"projectedTokens":100}"#, #"{"projectedTokens":100,"contextWindow":0}"#] {
            let result = try metrics("{\"contextPressure\":\(pressure)}")
            XCTAssertEqual(result.context?.total, 100)
            XCTAssertNil(result.context?.usage)
            XCTAssertNil(result.context?.limit)
        }
        let onlyLimit = try metrics(#"{"contextPressure":{"contextWindow":1000}}"#)
        XCTAssertNil(onlyLimit.context)
        XCTAssertEqual(value(onlyLimit, "context", "capacity"), .integer(1000))
        XCTAssertEqual(value(onlyLimit, "context", "used"), .unavailable)
        XCTAssertNil(try metrics(#"{"tokenUsage":{"uncachedInputTokens":500}}"#).context)
    }

    func testRingCapsPercentageLikeWebWithoutHidingActualTokenCount() throws {
        let result = try metrics(#"{"contextPressure":{"projectedTokens":1500,"contextWindow":1000}}"#)
        XCTAssertEqual(result.context?.usage, 100)
        XCTAssertEqual(result.context?.total, 1500)
    }

    func testMalformedNumbersDoNotBecomeZeroOrCrash() throws {
        for field in [#""123""#, "-1", "1.5", "null", "1e30"] {
            let result = try metrics("{\"contextPressure\":{\"projectedTokens\":\(field),\"contextWindow\":1000}}")
            XCTAssertNil(result.context)
            XCTAssertEqual(value(result, "context", "used"), .unavailable)
        }
        let partial = try metrics(#"{"tokenUsage":{"uncachedInputTokens":10,"outputTokens":5}}"#)
        XCTAssertEqual(value(partial, "usage", "input"), .unavailable)
        XCTAssertEqual(value(partial, "usage", "cache-read"), .unavailable)
        let overflow = try metrics(#"{"tokenUsage":{"uncachedInputTokens":8000000000000000000,"outputTokens":1,"cacheReadTokens":8000000000000000000,"cacheWriteTokens":0}}"#)
        XCTAssertEqual(value(overflow, "usage", "input"), .unavailable)
    }

    func testMissingCostMessageCountsAndReasoningNeverBecomeFakeZeroes() throws {
        let result = try metrics(#"{"contextPressure":{"pressureTokens":10,"contextWindow":100},"tokenUsage":{"uncachedInputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"outputTokens":0}}"#)
        XCTAssertNil(result.totalCost)
        XCTAssertNil(result.messageCount)
        XCTAssertNil(result.userMessageCount)
        XCTAssertNil(result.assistantMessageCount)
        XCTAssertNil(result.context?.reasoning)
        XCTAssertNil(result.context?.output)
        XCTAssertEqual(value(result, "usage", "total"), .integer(0))
        XCTAssertEqual(value(result, "usage", "cost"), .unavailable)
    }

    func testClosedStepStatisticsAndDerivedRates() throws {
        let result = try metrics(#"{"sessionStats":{"turns":3,"steps":5,"llmMs":10000,"toolMs":500,"ttftMs":3000,"ttftSteps":2,"decodeMs":2000,"decodeTokens":100}}"#)
        XCTAssertEqual(value(result, "statistics", "turns"), .integer(3))
        XCTAssertEqual(value(result, "statistics", "llm"), .durationMilliseconds(10000))
        XCTAssertEqual(value(result, "statistics", "ttft-average"), .durationMilliseconds(1500))
        XCTAssertEqual(value(result, "statistics", "decode-speed"), .decimal(50))
        let zeroDenominators = try metrics(#"{"sessionStats":{"ttftMs":1000,"ttftSteps":0,"decodeMs":0,"decodeTokens":10}}"#)
        XCTAssertEqual(value(zeroDenominators, "statistics", "ttft-average"), .unavailable)
        XCTAssertEqual(value(zeroDenominators, "statistics", "decode-speed"), .unavailable)
    }

    func testLastUsedAndNextModelsRemainSeparateFromContextCapacity() throws {
        let result = try metrics(#"{"contextPressure":{"pressureTokens":40,"contextWindow":100},"modelSelection":{"lastUsed":{"provider":"p1","model":"old","reasoningEffort":"high"},"next":{"provider":"p2","model":"new"}}}"#)
        XCTAssertEqual(result.context?.providerLabel, "p1")
        XCTAssertEqual(result.context?.modelLabel, "old")
        XCTAssertEqual(result.context?.limit, 100)
        XCTAssertEqual(value(result, "last-model", "reasoning"), .text("high"))
        XCTAssertEqual(value(result, "next-model", "model-id"), .text("new"))
        XCTAssertEqual(value(result, "next-model", "reasoning"), .unavailable)
    }

    func testDisconnectedMetadataDoesNotShowStaleUsage() throws {
        var session = try session(#"{"contextPressure":{"projectedTokens":100,"contextWindow":1000},"plan":{"active":true,"pending":false}}"#)
        session.backendMetadata?.isCurrent = false
        let result = DSHSessionContextMetricsBuilder.metrics(session: session, providers: [])
        XCTAssertNil(result.context)
        XCTAssertNotNil(result.metadataSections)
        XCTAssertEqual(value(result, "configuration", "plan-active"), .unavailable)
        XCTAssertEqual(value(result, "session", "id"), .text("s"))
        XCTAssertEqual(value(result, "session", "current"), .boolean(false))
    }

    func testAdditionalContributedMetadataIsAvailableWithoutInventingSchema() throws {
        let result = try metrics(#"{"pluginFacts":{"answer":42},"pluginLabel":"Custom data"}"#)
        let row = result.metadataSections?.first { $0.id == "additional" }?.rows.first { $0.id == "pluginFacts" }
        XCTAssertEqual(row?.rawLabel, "pluginFacts")
        guard case .text(let json) = row?.value else { return XCTFail("Expected inspectable JSON") }
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(json.utf8)), .object(["answer": .number(42)]))
        XCTAssertEqual(value(result, "additional", "pluginLabel"), .text("Custom data"))
    }

    func testSessionMergeCanInvalidateMetadataAndPreserveLegacyOptionalBehavior() throws {
        let original = try session(#"{"contextPressure":{"pressureTokens":100,"contextWindow":1000}}"#)
        var incoming = original
        incoming.backendMetadata = nil
        XCTAssertEqual(original.merged(with: incoming).backendMetadata, original.backendMetadata)
        incoming.backendMetadata = .init(projections: [:], isCurrent: false)
        let merged = original.merged(with: incoming)
        XCTAssertEqual(merged.backendMetadata?.isCurrent, false)
        XCTAssertTrue(merged.backendMetadata?.projections.isEmpty == true)
        XCTAssertNil(DSHSessionContextMetricsBuilder.metrics(session: merged, providers: []).context)
        XCTAssertEqual(try JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(merged)), merged)
    }

    private func session(_ projections: String) throws -> OpenCodeSession {
        let values = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data(projections.utf8))
        var session = OpenCodeSession(id: "s", title: "Chat", workspaceID: nil, directory: "/workspace", projectID: "w", parentID: nil)
        session.backendMetadata = .init(projections: values)
        return session
    }

    private func metrics(_ projections: String) throws -> OpenCodeSessionContextMetrics {
        DSHSessionContextMetricsBuilder.metrics(session: try session(projections), providers: [])
    }

    private func value(_ metrics: OpenCodeSessionContextMetrics, _ section: String, _ row: String) -> SessionMetadataValue? {
        metrics.metadataSections?.first { $0.id == section }?.rows.first { $0.id == row }?.value
    }
}
