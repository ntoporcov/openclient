import XCTest
@testable import OpenClient

@MainActor
final class DesktopReactionRecordTests: XCTestCase {
    func testBestReactionSurvivesReopeningAndRejectsInvalidOrSlowerTimes() throws {
        let suite = "DesktopReactionRecordTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let record = DesktopReactionRecordStore(defaults: defaults)
        XCTAssertNil(record.bestMilliseconds)
        record.record(milliseconds: 350)
        record.record(milliseconds: 200)
        record.record(milliseconds: 600)
        record.record(milliseconds: 0)
        record.record(milliseconds: -1)
        XCTAssertEqual(record.bestMilliseconds, 200)
        XCTAssertEqual(DesktopReactionRecordStore(defaults: defaults).bestMilliseconds, 200)
    }
}
