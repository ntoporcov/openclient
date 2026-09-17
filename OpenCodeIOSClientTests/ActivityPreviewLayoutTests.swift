import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class ActivityPreviewLayoutTests: XCTestCase {
    func testExactOutputMatchesBaselineAcrossLayouts() {
        let sources = [
            "",
            "Short answer.",
            String(repeating: "older words ", count: 90) + "the latest streaming sentence",
            String(repeating: "/Applications/LongUnbrokenPath/", count: 40) + " newest result",
            String(repeating: "line one\nline two\n\n", count: 40) + "last line\n",
            String(repeating: " .\u{00B7}\t ", count: 100) + "newest sentence",
        ]
        let fonts = [
            UIFont.systemFont(ofSize: 12),
            UIFont.preferredFont(forTextStyle: .subheadline),
            UIFont.monospacedSystemFont(ofSize: 19, weight: .medium),
            UIFont.systemFont(ofSize: 31, weight: .bold),
        ]
        for source in sources {
            for width: CGFloat in [1, 40, 180, 320, 768, 1_600] {
                for font in fonts {
                    for lines in [1, 2, 4] {
                        assertMatchesBaseline(source, width: width, font: font, maximumLines: lines)
                    }
                }
            }
        }
    }

    func testLongUnicodeTailsMatchBaselineWithoutSplittingGraphemes() {
        let tails = [
            "e\u{0301} cafe\u{0301} ",
            "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} \u{1F1E7}\u{1F1F7} ",
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} ",
            "\u{65E5}\u{672C}\u{8A9E}\u{4E2D}\u{6587} ",
            "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{05E9}\u{05DC}\u{05D5}\u{05DD} ",
        ]
        for tail in tails {
            let source = String(repeating: "old answer ", count: 2_000)
                + String(repeating: tail, count: 200)
            for width: CGFloat in [70, 180, 390, 900] {
                for lines in [1, 2, 5] {
                    assertMatchesBaseline(source, width: width, font: .systemFont(ofSize: 17), maximumLines: lines)
                }
            }
        }
    }

    func testShortFullFitIsUnchangedIncludingWhitespace() {
        let font = UIFont.systemFont(ofSize: 15)
        for source in ["Short answer.", " .\u{00B7} hello  ", "first\nsecond", "e\u{0301} \u{1F1E7}\u{1F1F7}"] {
            XCTAssertEqual(ActivityTailPreview.fittingText(source, width: 500, font: font), source)
            assertMatchesBaseline(source, width: 500, font: font)
        }
    }

    func testFittingSuffixCanBeLongerThanInitialWindow() {
        let source = String(repeating: "i", count: 10_000)
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let result = ActivityTailPreview.fittingText(source, width: 1_600, font: font, maximumLines: 4)
        XCTAssertGreaterThan(result.count, ActivityTailPreview.initialWindowCharacterCount + 1)
        XCTAssertEqual(result, baseline(source, width: 1_600, font: font, maximumLines: 4))
    }

    func testFullFitCanRequireMultipleWindowExpansions() {
        let source = String(repeating: "i", count: ActivityTailPreview.initialWindowCharacterCount * 3)
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        XCTAssertEqual(ActivityTailPreview.fittingText(source, width: 1_600, font: font, maximumLines: 4), source)
        assertMatchesBaseline(source, width: 1_600, font: font, maximumLines: 4)
    }

    func testWindowBoundariesAndEllipsisDoNotForceTruncation() {
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let advance = ("i" as NSString).size(withAttributes: [.font: font]).width
        for count in [255, 256, 257, 511, 512, 513] {
            let source = String(repeating: "i", count: count)
            for adjustment: CGFloat in [-1, 0, 1] {
                assertMatchesBaseline(source, width: advance * CGFloat(count) + adjustment, font: font, maximumLines: 1)
            }
        }
    }

    func testInvalidLayoutReturnsOriginalSource() {
        let source = String(repeating: "full source ", count: 500)
        for width: CGFloat in [-1, 0, 180] {
            for lines in [-1, 0] {
                XCTAssertEqual(ActivityTailPreview.fittingText(source, width: width, font: .systemFont(ofSize: 15), maximumLines: lines), source)
            }
        }
        XCTAssertEqual(ActivityTailPreview.fittingText(source, width: 0, font: .systemFont(ofSize: 15)), source)
    }

    func testCacheIncludesLayoutAndCompleteSourceFlag() {
        let cache = ActivityTailPreview.LayoutCache()
        let tail = String(repeating: "tail words ", count: 100)
        let sources = ["older prefix " + tail, "different older prefix " + tail, tail + "new", "Short", "Short\nanswer"]
        for source in sources {
            for width: CGFloat in [100, 320, 1_600] {
                for font in [UIFont.systemFont(ofSize: 13), UIFont.systemFont(ofSize: 27)] {
                    for lines in [1, 2, 5] {
                        let expected = baseline(source, width: width, font: font, maximumLines: lines)
                        for _ in 0..<2 {
                            XCTAssertEqual(ActivityTailPreview.fittingText(source, width: width, font: font, maximumLines: lines, cache: cache), expected)
                        }
                    }
                }
            }
        }

        let window = String(repeating: "i", count: ActivityTailPreview.initialWindowCharacterCount)
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for source in [window, String(repeating: "i", count: 5_000) + window, window] {
            XCTAssertEqual(
                ActivityTailPreview.fittingText(source, width: 1_600, font: font, cache: cache),
                baseline(source, width: 1_600, font: font)
            )
        }
    }

    func testExpandedResultsAreNotCachedByOnlyTheInitialTail() {
        let cache = ActivityTailPreview.LayoutCache()
        let tail = String(repeating: "i", count: ActivityTailPreview.initialWindowCharacterCount)
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        for prefix in ["a", "b", "c"] {
            let source = String(repeating: prefix, count: 3_000) + tail
            XCTAssertEqual(
                ActivityTailPreview.fittingText(source, width: 1_600, font: font, cache: cache),
                baseline(source, width: 1_600, font: font)
            )
        }
    }

    func testRowEqualityIncludesEveryInputAndFeedbackIdentity() {
        let snapshot = makeRowSnapshot(text: "answer")
        let row = ActivitySessionRow(row: snapshot, showsLastUserMessage: true)
        XCTAssertEqual(row, ActivitySessionRow(row: snapshot, showsLastUserMessage: true))
        XCTAssertNotEqual(row, ActivitySessionRow(row: makeRowSnapshot(text: "new answer"), showsLastUserMessage: true))
        XCTAssertNotEqual(row, ActivitySessionRow(row: snapshot, showsLastUserMessage: false))
        XCTAssertNotEqual(row, ActivitySessionRow(row: snapshot, showsLastUserMessage: true, isSelected: true))
        XCTAssertNotEqual(row, ActivitySessionRow(row: snapshot, showsLastUserMessage: true, presentation: .summary))
        let feedback = SessionSelectionFeedback()
        let withFeedback = ActivitySessionRow(row: snapshot, showsLastUserMessage: true, selectionFeedback: feedback)
        XCTAssertNotEqual(row, withFeedback)
        XCTAssertEqual(withFeedback, ActivitySessionRow(row: snapshot, showsLastUserMessage: true, selectionFeedback: feedback))
        XCTAssertNotEqual(withFeedback, ActivitySessionRow(row: snapshot, showsLastUserMessage: true, selectionFeedback: SessionSelectionFeedback()))
    }

    func testPerformanceLongGrowingAnswers() {
        let font = UIFont.systemFont(ofSize: 15)
        let prefix = String(repeating: "older answer text ", count: 10_000)
        let sources = (0..<20).map { prefix + String(repeating: "new text ", count: $0 + 40) }
        let expected = sources.map { baseline($0, width: 320, font: font) }
        measure {
            for (source, result) in zip(sources, expected) {
                XCTAssertEqual(ActivityTailPreview.fittingText(source, width: 320, font: font), result)
            }
        }
    }

    private func assertMatchesBaseline(
        _ source: String, width: CGFloat, font: UIFont, maximumLines: Int = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            ActivityTailPreview.fittingText(source, width: width, font: font, maximumLines: maximumLines),
            baseline(source, width: width, font: font, maximumLines: maximumLines),
            "width=\(width), font=\(font.fontName)/\(font.pointSize), lines=\(maximumLines)",
            file: file, line: line
        )
    }

    // Frozen pre-optimization fitter: compare exact suffixes, not just their heights.
    private func baseline(_ text: String, width: CGFloat, font: UIFont, maximumLines: Int = 2) -> String {
        guard width > 0, maximumLines > 0, !text.isEmpty else { return text }
        let maximumHeight = measuredHeight(
            Array(repeating: "Ag", count: maximumLines).joined(separator: "\n"), width: width, font: font
        )
        if measuredHeight(text, width: width, font: font) <= maximumHeight { return text }
        let characters = Array(text)
        var lowerBound = 0
        var upperBound = characters.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let candidate = "\u{2026}" + String(characters[midpoint...])
            if measuredHeight(candidate, width: width, font: font) <= maximumHeight {
                upperBound = midpoint
            } else {
                lowerBound = midpoint + 1
            }
        }
        let suffix = String(characters[lowerBound...]).drop(while: {
            $0.isWhitespace || $0 == "." || $0 == "\u{00B7}"
        })
        return "\u{2026}" + suffix
    }

    private func measuredHeight(_ text: String, width: CGFloat, font: UIFont) -> CGFloat {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        return (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle], context: nil
        ).height
    }

    private func makeRowSnapshot(text: String) -> ActivityFacade.RowSnapshot {
        let session = OpenCodeSession(id: "session", title: "Title", workspaceID: nil,
            directory: "/project", projectID: "project", parentID: nil)
        return ActivityFacade.RowSnapshot(
            recent: RecentProjectSession(session: session, projectTitle: "Project", preview: nil, isBusy: false),
            projectID: "project", projectIcon: nil, usesGlobalProjectAvatar: false,
            needsInput: false, isWorking: false, statusTitle: "Idle", latestUserText: nil,
            latestAssistantText: text, runningTools: [], updatedAt: nil, latestUserMessageAt: nil,
            pendingInteractionCount: 0, completedTodoCount: 0, todoCount: 0,
            isLiveActivityActive: false, isHydrating: false, hydrationGeneration: 0
        )
    }
}
