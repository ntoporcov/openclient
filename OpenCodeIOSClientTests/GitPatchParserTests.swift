import XCTest
@testable import OpenClient

final class GitPatchParserTests: XCTestCase {
    func testCollapsingPreservesChangesLineNumbersAndHunkBoundaries() {
        let patch = "@@ -1,11 +1,11 @@\n-old\n+new\n"
            + (2...11).map { " context \($0)" }.joined(separator: "\n")
            + "\n@@ -30,1 +30,1 @@\n-before\n+after\n\\ No newline at end of file"
        let lines = GitPatchParser.parse(patch)
        let rows = GitPatchParser.displayRows(lines, collapsingUnchangedLines: true)
        let visible = rows.compactMap { row -> GitPatchParser.Line? in
            if case let .line(line) = row { return line }
            return nil
        }
        XCTAssertEqual(visible.filter { $0.kind == .addition }.map(\.text), ["+new", "+after"])
        XCTAssertEqual(visible.filter { $0.kind == .deletion }.map(\.text), ["-old", "-before"])
        XCTAssertEqual(visible.filter { $0.kind == .hunk }.count, 2)
        XCTAssertEqual(visible.first { $0.text == " context 11" }?.newLineNumber, 11)
        XCTAssertEqual(visible.first { $0.text == "+after" }?.newLineNumber, 30)
        XCTAssertTrue(visible.contains { $0.text == "\\ No newline at end of file" })
        XCTAssertEqual(rows.compactMap { row -> Int? in
            if case let .collapsed(_, count) = row { return count }
            return nil
        }, [4])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertEqual(GitPatchParser.displayRows(lines, collapsingUnchangedLines: false).count, lines.count)
    }
}
