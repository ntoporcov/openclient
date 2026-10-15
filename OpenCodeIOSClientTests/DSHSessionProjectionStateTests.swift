import XCTest
@testable import OpenClient

final class DSHSessionProjectionStateTests: XCTestCase {
    func testDeltasUseIndependentPerKeyWatermarks() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(10, ["tokenUsage": .number(1)]))
        XCTAssertTrue(state.applyDelta(key: "tokenUsage", value: .number(20), sequence: 20))
        XCTAssertTrue(state.applyDelta(key: "contextPressure", value: .number(11), sequence: 11))
        XCTAssertFalse(state.applyDelta(key: "tokenUsage", value: .number(19), sequence: 19))
        XCTAssertFalse(state.applyDelta(key: "tokenUsage", value: .number(99), sequence: 20))
        XCTAssertEqual(state.values["tokenUsage"], .number(20))
        XCTAssertEqual(state.values["contextPressure"], .number(11))
    }

    func testStaleFullReadPreservesNewerKeysAndHydratesOthers() throws {
        var state = DSHSessionProjectionState()
        state.applyDelta(key: "contextPressure", value: .number(30), sequence: 30)
        try state.applyBaseline(baseline(20, ["contextPressure": .number(20), "tokenUsage": .number(12)]))
        XCTAssertEqual(state.values["contextPressure"], .number(30))
        XCTAssertEqual(state.values["tokenUsage"], .number(12))
        XCTAssertTrue(state.metadata.isCurrent)
    }

    func testFullBaselineOmissionRemovesOnlyOlderKeys() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(10, ["old": .number(1), "new": .number(2)]))
        state.applyDelta(key: "new", value: .number(3), sequence: 30)
        try state.applyBaseline(baseline(20, [:]))
        XCTAssertNil(state.values["old"])
        XCTAssertEqual(state.values["new"], .number(3))
        XCTAssertFalse(state.applyDelta(key: "old", value: .number(9), sequence: 19))
        XCTAssertFalse(state.applyDelta(key: "old", value: .number(9), sequence: 20))
        XCTAssertTrue(state.applyDelta(key: "old", value: .number(4), sequence: 21))
    }

    func testBaselineFencesKeysNeverPreviouslySeen() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(20, [:]))
        XCTAssertFalse(state.applyDelta(key: "absent", value: .number(9), sequence: 19))
        XCTAssertFalse(state.applyDelta(key: "absent", value: .number(9), sequence: 20))
        XCTAssertTrue(state.applyDelta(key: "absent", value: .number(9), sequence: 21))
    }

    func testExplicitNullIsPreservedAndCannotBeResurrectedByOlderDelta() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(10, ["plan": .object(["active": .bool(true)])]))
        XCTAssertTrue(state.applyDelta(key: "plan", value: .null, sequence: 12))
        XCTAssertEqual(state.values["plan"], .null)
        XCTAssertFalse(state.applyDelta(key: "plan", value: .object([:]), sequence: 11))
        try state.applyBaseline(baseline(13, ["plan": .null]))
        XCTAssertEqual(state.metadata.projections["plan"], .null)
        try state.applyBaseline(baseline(14, [:]))
        XCTAssertNil(state.values["plan"])
        XCTAssertFalse(state.applyDelta(key: "plan", value: .object([:]), sequence: 13))
    }

    func testOlderCompleteBaselineCannotRestoreOmittedKeys() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(10, ["old": .number(1)]))
        try state.applyBaseline(baseline(20, [:]))
        try state.applyBaseline(baseline(19, ["old": .number(3), "neverSeen": .number(4)]))
        XCTAssertTrue(state.values.isEmpty)
    }

    func testReconnectInvalidatesThenReplacementCanUseLowerCursor() throws {
        var state = DSHSessionProjectionState()
        state.applyHeader(.object(["createdAt": .number(100), "origin": .string("subagent")]))
        try state.applyBaseline(baseline(100, ["contextPressure": .number(99), "obsolete": .bool(true)]))
        state.invalidate()
        XCTAssertFalse(state.metadata.isCurrent)
        XCTAssertTrue(state.metadata.projections.isEmpty)
        XCTAssertEqual(state.metadata.createdAt, 100)
        try state.replaceGeneration(with: baseline(2, ["contextPressure": .number(1)]))
        XCTAssertTrue(state.isCurrent)
        XCTAssertEqual(state.values["contextPressure"], .number(1))
        XCTAssertNil(state.values["obsolete"])
        XCTAssertEqual(state.metadata.origin, "subagent")
    }

    func testFirstControlBaselinePreservesFreshFollowStateAfterReconnect() throws {
        var loaded = DSHSessionProjectionState()
        var cold = DSHSessionProjectionState()
        try loaded.applyBaseline(baseline(90, ["oldGeneration": .bool(true)]))
        try cold.applyBaseline(baseline(90, ["oldGeneration": .bool(true)]))
        loaded.invalidate()
        cold.invalidate()
        // Independently reopened follow snapshots arrive before control's baseline.
        try loaded.applyBaseline(baseline(20, ["tokenUsage": .number(20)]))
        try cold.applyBaseline(baseline(21, ["contextPressure": .number(21)]))
        let states = try DSHSessionProjectionState.applyingControlBaseline(
            ["loaded": baseline(18, ["tokenUsage": .number(18)])],
            to: ["loaded": loaded, "cold": cold], startsNewGeneration: false)
        XCTAssertEqual(states["loaded"]?.values["tokenUsage"], .number(20))
        XCTAssertEqual(states["cold"]?.values["contextPressure"], .number(21))
        XCTAssertEqual(states["cold"]?.isCurrent, true)
        XCTAssertNil(states["loaded"]?.values["oldGeneration"])
    }

    func testUnexpectedControlBaselineStartsNewGenerationAndInvalidatesOmittedSessions() throws {
        var previous = DSHSessionProjectionState()
        try previous.applyBaseline(baseline(90, ["tokenUsage": .number(90)]))
        let states = try DSHSessionProjectionState.applyingControlBaseline(
            ["loaded": baseline(18, ["tokenUsage": .number(18)])],
            to: ["loaded": previous, "cold": previous], startsNewGeneration: true)
        XCTAssertEqual(states["loaded"]?.values["tokenUsage"], .number(18))
        XCTAssertEqual(states["cold"]?.values.isEmpty, true)
        XCTAssertEqual(states["cold"]?.isCurrent, false)
    }

    func testForkLineageRemainsAvailableWithoutSubagentOrigin() throws {
        var state = DSHSessionProjectionState()
        state.applyHeader(.object(["parentSession": .string("fork-source"), "isSeeded": .bool(true)]))
        XCTAssertEqual(state.metadata.parentSession, "fork-source")
        XCTAssertEqual(state.metadata.isSeeded, true)
        XCTAssertNil(state.metadata.origin)
        let roundTrip = try JSONDecoder().decode(BackendSessionMetadata.self, from: JSONEncoder().encode(state.metadata))
        XCTAssertEqual(roundTrip.parentSession, "fork-source")
    }

    func testReplacementDirectlyDropsOldGenerationAndOtherSessionsAreIndependent() throws {
        var first = DSHSessionProjectionState()
        var second = DSHSessionProjectionState()
        try first.applyBaseline(baseline(90, ["old": .number(4)]))
        try second.applyBaseline(baseline(90, ["old": .number(5)]))
        try first.replaceGeneration(with: baseline(-1, [:]))
        XCTAssertTrue(first.values.isEmpty)
        XCTAssertTrue(first.isCurrent)
        XCTAssertEqual(second.values["old"], .number(5))
    }

    func testPermissionFailureInvalidatesOnlyPermissionAndReadAtSameCursorRestoresIt() throws {
        var state = DSHSessionProjectionState()
        let full: DSHJSON = .object(["currentValue": .string("danger-full-access")])
        let initial = baseline(10, ["permissions": full, "tokenUsage": .number(3)])
        try state.applyBaseline(initial)
        state.invalidate(key: "permissions")
        XCTAssertEqual(state.values["permissions"], .null)
        XCTAssertEqual(state.values["tokenUsage"], .number(3))
        XCTAssertFalse(state.applyDelta(key: "permissions", value: full, sequence: 9))
        try state.applyBaseline(initial)
        XCTAssertEqual(state.values["permissions"], full)
    }

    func testMalformedOptionalHeaderFieldsAreUnavailableWithoutLosingProjections() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(-1, ["futureKey": .object(["arbitrary": .array([.null])])]))
        state.applyHeader(.object([
            "createdAt": .string("bad"), "origin": .number(2), "isSeeded": .string("false"),
            "delegationDepth": .number(-1), "version": .number(1.5), "cwd": .bool(false)
        ]))
        XCTAssertNil(state.metadata.createdAt)
        XCTAssertNil(state.metadata.origin)
        XCTAssertNil(state.metadata.isSeeded)
        XCTAssertNil(state.metadata.delegationDepth)
        XCTAssertNil(state.metadata.version)
        XCTAssertNil(state.header.cwd)
        XCTAssertNotNil(state.metadata.projections["futureKey"])
        state.applyHeader(.object([
            "createdAt": .number(1000), "origin": .string("subagent"), "isSeeded": .bool(false),
            "delegationDepth": .number(2), "version": .number(3), "cwd": .string("/repo"),
            "parentSession": .string("parent")
        ]))
        XCTAssertEqual(state.metadata.createdAt, 1000)
        XCTAssertEqual(state.metadata.isSeeded, false)
        XCTAssertEqual(state.metadata.delegationDepth, 2)
        XCTAssertEqual(state.metadata.version, 3)
        XCTAssertEqual(state.header.parentSession, "parent")
    }

    func testInvalidBaselinesLeaveExistingStateUnchanged() throws {
        var state = DSHSessionProjectionState()
        try state.applyBaseline(baseline(10, ["valid": .bool(true)]))
        let invalidValues: [DSHJSON] = [.null, .object(["values": .object([:])]), baseline(-2, [:]),
                                        .object(["asOfSeq": .number(11), "values": .array([])])]
        for invalid in invalidValues {
            XCTAssertThrowsError(try state.applyBaseline(invalid))
            XCTAssertThrowsError(try state.replaceGeneration(with: invalid))
            XCTAssertEqual(state.values["valid"], .bool(true))
        }
    }

    func testMetadataDecodingDefaultsAndToleratesMalformedOptionalFields() throws {
        let value = try JSONDecoder().decode(BackendSessionMetadata.self, from: Data(#"{"projections":{"plan":null},"createdAt":"bad","origin":[],"isSeeded":3,"delegationDepth":"bad","version":{}}"#.utf8))
        XCTAssertTrue(value.isCurrent)
        XCTAssertEqual(value.projections["plan"], .null)
        XCTAssertNil(value.createdAt)
        XCTAssertNil(value.origin)
        XCTAssertNil(value.isSeeded)
        XCTAssertNil(value.delegationDepth)
        XCTAssertNil(value.version)
        XCTAssertEqual(try JSONDecoder().decode(BackendSessionMetadata.self, from: JSONEncoder().encode(value)), value)
    }

    private func baseline(_ sequence: Int, _ values: [String: DSHJSON]) -> DSHJSON {
        .object(["asOfSeq": .number(Double(sequence)), "values": .object(values)])
    }
}
