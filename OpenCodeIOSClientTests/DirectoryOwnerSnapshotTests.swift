import XCTest
@testable import OpenClient

@MainActor
final class DirectoryOwnerSnapshotTests: XCTestCase {
    func testSnapshotMatchesSingleLookupForEverySourceOfOwnership() {
        let registry = DirectoryStoreRegistry()
        let other = registry.store(for: "/other")
        other.sessions = [session("listed")]
        other.selectedSession = session("inactive-selected-only")
        other.syncState.messagesBySessionID["messages"] = []
        other.syncState.todosBySessionID["todos"] = []
        other.syncState.permissionsBySessionID["permissions"] = []
        other.syncState.questionsBySessionID["questions"] = []
        other.applySessionStatus("busy", forSessionID: "status")
        other.syncState.sessionStatusesBySessionID["sync-status-only"] = "busy"
        registry.activeStore.selectedSession = session("active-selected-only")

        let ids = ["listed", "messages", "todos", "permissions", "questions", "status", "active-selected-only"]
        let owners = registry.ownerStoresBySessionID()
        XCTAssertEqual(Set(owners.keys), Set(ids + ["inactive-selected-only"]))
        XCTAssertTrue(owners["inactive-selected-only"] === other)
        for id in ids {
            XCTAssertTrue(owners[id] === registry.ownerStore(forSessionID: id), id)
        }
        for id in ["missing", "sync-status-only"] {
            XCTAssertNil(owners[id])
            XCTAssertNil(registry.ownerStore(forSessionID: id))
        }
    }

    func testSnapshotPreservesActivePrecedenceAndFallbackOrderForDuplicateIDs() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/active")
        let active = registry.activeStore
        let other = registry.store(for: "/other")
        let third = registry.store(for: "/third")
        let ids = ["listed", "messages", "selected", "fallback"]
        for store in [other, third] { store.sessions = ids.map(session) }
        active.sessions = [session("listed")]
        active.syncState.messagesBySessionID["messages"] = []
        active.selectedSession = session("selected")
        active.syncState.todosBySessionID["fallback"] = []

        let owners = registry.ownerStoresBySessionID()
        for id in ids { XCTAssertTrue(owners[id] === registry.ownerStore(forSessionID: id), id) }
        for id in ["listed", "messages", "selected"] { XCTAssertTrue(owners[id] === active) }
        XCTAssertFalse(owners["fallback"] === active, "Canonical inactive owners outrank active cached-only state")
        XCTAssertEqual(owners.count, ids.count)
    }

    func testFreshSnapshotsFollowActivationRemovalAndRegistryReset() {
        let registry = DirectoryStoreRegistry()
        let first = registry.activeStore
        let second = registry.store(for: "/second")
        first.sessions = [session("shared")]
        second.sessions = [session("shared")]
        XCTAssertTrue(registry.ownerStoresBySessionID()["shared"] === first)
        registry.activate("/second")
        XCTAssertTrue(registry.ownerStoresBySessionID()["shared"] === second)
        second.sessions = []
        XCTAssertTrue(registry.ownerStoresBySessionID()["shared"] === first)
        registry.reset()
        XCTAssertTrue(registry.ownerStoresBySessionID().isEmpty)
    }

    func testMeasureOwnerSnapshotForManyDirectoriesAndSessions() {
        let registry = DirectoryStoreRegistry()
        for directory in 0..<30 {
            registry.store(for: "/directory-\(directory)").sessions = (0..<50).map {
                session("session-\(directory)-\($0)")
            }
        }
        measure {
            for _ in 0..<10 {
                XCTAssertEqual(registry.ownerStoresBySessionID().count, 1_500)
            }
        }
    }

    private func session(_ id: String) -> OpenCodeSession {
        .init(id: id, title: id, workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
    }
}
