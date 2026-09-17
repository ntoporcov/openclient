import XCTest
@testable import OpenClient

final class ComposerSuggestionSelectionTests: XCTestCase {
    func testCommandsRankExactThenPrefixThenOtherMatchesAlphabetically() {
        let commands = [
            command("misread"),
            command("read-zebra"),
            command("aardvark", description: "Read a document"),
            command("already-read"),
            command("read-file"),
            command("read"),
            command("unrelated"),
        ]

        XCTAssertEqual(
            ComposerSuggestionSelection.rankedCommands(commands, query: "read").map(\.name),
            ["read", "read-file", "read-zebra", "aardvark", "already-read", "misread"]
        )
    }

    func testCommandMatchingAndRankingAreCaseInsensitive() {
        let commands = [
            command("already-READ"),
            command("Read-File"),
            command("a-description", description: "READ a document"),
            command("READ"),
        ]

        XCTAssertEqual(
            ComposerSuggestionSelection.rankedCommands(commands, query: "rEaD").map(\.name),
            ["READ", "Read-File", "a-description", "already-READ"]
        )
    }

    func testEmptyQuerySortsAllCommandsAlphabetically() {
        let commands = [command("zebra"), command("Beta"), command("alpha")]
        XCTAssertEqual(
            ComposerSuggestionSelection.rankedCommands(commands, query: "").map(\.name),
            ["alpha", "Beta", "zebra"]
        )
    }

    func testNoMatchesAndEmptyCommandsReturnEmptyResults() {
        XCTAssertTrue(ComposerSuggestionSelection.rankedCommands([command("read")], query: "missing").isEmpty)
        XCTAssertTrue(ComposerSuggestionSelection.rankedCommands([], query: "read").isEmpty)
        XCTAssertTrue(ComposerSuggestionSelection.rankedCommands([], query: "").isEmpty)
    }

    func testAlphabeticalTiesRetainOriginalOrderInEveryTier() {
        let commands = [
            command("READ-file", description: "first prefix"),
            command("read-FILE", description: "second prefix"),
            command("READ", description: "first exact"),
            command("read", description: "second exact"),
            command("already-READ", description: "first substring"),
            command("ALREADY-read", description: "second substring"),
        ]

        XCTAssertEqual(
            ComposerSuggestionSelection.rankedCommands(commands, query: "read"),
            [commands[2], commands[3], commands[0], commands[1], commands[4], commands[5]]
        )
        XCTAssertEqual(
            ComposerSuggestionSelection.rankedCommands(commands, query: ""),
            [commands[4], commands[5], commands[2], commands[3], commands[0], commands[1]]
        )
    }

    func testSelectionDefaultsToFirstAndRetainsStableIDForEqualContext() {
        var selection = ComposerSuggestionSelection()
        let context = ComposerSuggestionSelection.Context(kind: .command, query: "r", ids: ["read", "read-file", "run"])
        XCTAssertEqual(selection.selectedID(in: context), "read")

        selection.move(by: 1, in: context)
        let equalContext = ComposerSuggestionSelection.Context(kind: .command, query: "r", ids: ["read", "read-file", "run"])
        XCTAssertEqual(selection.selectedID(in: equalContext), "read-file")
        selection.move(by: 0, in: equalContext)
        XCTAssertEqual(selection.selectedID(in: equalContext), "read-file")
    }

    func testMovementWrapsInBothDirectionsAndHandlesLargeOffsets() {
        var selection = ComposerSuggestionSelection()
        let context = ComposerSuggestionSelection.Context(kind: .agent, query: "", ids: ["build", "plan", "review"])

        selection.move(by: -1, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "review")
        selection.move(by: 1, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "build")
        selection.move(by: 7, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "plan")
        selection.move(by: -8, in: context)
        XCTAssertEqual(selection.selectedID(in: context), "review")

        selection.reset(to: context)
        selection.move(by: Int.max, in: context)
        XCTAssertEqual(selection.selectedID(in: context), context.ids[Int.max % context.ids.count])
        selection.reset(to: context)
        selection.move(by: Int.min, in: context)
        XCTAssertEqual(selection.selectedID(in: context), context.ids[(Int.min % context.ids.count + context.ids.count) % context.ids.count])
    }

    func testContextChangesFallBackToFirstAndMovementStartsThere() {
        let original = ComposerSuggestionSelection.Context(kind: .command, query: "r", ids: ["read", "run", "review"])
        let changedContexts = [
            ComposerSuggestionSelection.Context(kind: .command, query: "re", ids: original.ids),
            ComposerSuggestionSelection.Context(kind: .agent, query: original.query, ids: original.ids),
            ComposerSuggestionSelection.Context(kind: .command, query: original.query, ids: ["review", "run", "read"]),
            ComposerSuggestionSelection.Context(kind: .command, query: original.query, ids: ["read", "review"]),
            ComposerSuggestionSelection.Context(kind: .command, query: original.query, ids: original.ids + ["reset"]),
        ]

        for context in changedContexts {
            var selection = ComposerSuggestionSelection()
            selection.move(by: 1, in: original)
            XCTAssertEqual(selection.selectedID(in: original), "run")
            XCTAssertEqual(selection.selectedID(in: context), context.ids.first)
            selection.move(by: 1, in: context)
            XCTAssertEqual(selection.selectedID(in: context), context.ids[1])
        }
    }

    func testResetSelectsFirstEvenForUnchangedContext() {
        var selection = ComposerSuggestionSelection()
        let context = ComposerSuggestionSelection.Context(kind: .command, query: "", ids: ["read", "write"])
        selection.move(by: 1, in: context)
        selection.reset(to: context)
        XCTAssertEqual(selection.selectedID(in: context), "read")
    }

    func testSynchronizationPreservesNavigationAlreadyAppliedToTheNewContext() {
        var selection = ComposerSuggestionSelection()
        let previous = ComposerSuggestionSelection.Context(kind: .command, query: "re", ids: ["read", "read-file", "review"])
        let next = ComposerSuggestionSelection.Context(kind: .command, query: "read", ids: ["read", "read-file"])
        selection.synchronize(to: previous)
        selection.move(by: 1, in: next)
        selection.synchronize(to: next)
        XCTAssertEqual(selection.selectedID(in: next), "read-file")
        selection.synchronize(to: previous)
        XCTAssertEqual(selection.selectedID(in: previous), "read")
        selection.move(by: 1, in: previous)
        selection.synchronize(to: nil)
        selection.synchronize(to: previous)
        XCTAssertEqual(selection.selectedID(in: previous), "read")
    }

    func testClosedAndEmptyContextsClearSelection() {
        let context = ComposerSuggestionSelection.Context(kind: .command, query: "", ids: ["read", "write"])
        let empty = ComposerSuggestionSelection.Context(kind: .command, query: "missing", ids: [])
        let inactiveContexts: [ComposerSuggestionSelection.Context?] = [nil, empty]

        for inactiveContext in inactiveContexts {
            var selection = ComposerSuggestionSelection()
            selection.move(by: 1, in: context)
            XCTAssertNil(selection.selectedID(in: inactiveContext))
            selection.move(by: 1, in: inactiveContext)
            XCTAssertNil(selection.selectedID(in: inactiveContext))
            XCTAssertEqual(selection.selectedID(in: context), "read")

            selection.move(by: 1, in: context)
            selection.reset(to: inactiveContext)
            XCTAssertNil(selection.selectedID(in: inactiveContext))
            XCTAssertEqual(selection.selectedID(in: context), "read")
        }
    }

    func testSingleResultRemainsSelectedWhenMoving() {
        var selection = ComposerSuggestionSelection()
        let context = ComposerSuggestionSelection.Context(kind: .agent, query: "build", ids: ["build"])
        for offset in [-1, 1, Int.min, Int.max] {
            selection.move(by: offset, in: context)
            XCTAssertEqual(selection.selectedID(in: context), "build")
        }
    }

    private func command(_ name: String, description: String? = nil) -> OpenCodeCommand {
        OpenCodeCommand(
            name: name,
            description: description,
            agent: nil,
            model: nil,
            source: nil,
            template: "",
            subtask: nil,
            hints: []
        )
    }
}
