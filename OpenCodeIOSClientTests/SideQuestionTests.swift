import XCTest
@testable import OpenClient

@MainActor
final class SideQuestionTests: XCTestCase {
    func testSlashCommandAcceptsBareAndInlineQuestionsButNotSimilarNames() {
        XCTAssertEqual(OpenClientChatCommands.sideQuestionPrompt(from: " /btw \n"), "")
        XCTAssertEqual(OpenClientChatCommands.sideQuestionPrompt(from: "/BTW Why did this fail?"), "Why did this fail?")
        XCTAssertEqual(OpenClientChatCommands.sideQuestionPrompt(from: "/btw\nExplain step 2"), "Explain step 2")
        for text in ["/btwextra question", "Explain /btw", "btw question", "/fork"] {
            XCTAssertNil(OpenClientChatCommands.sideQuestionPrompt(from: text))
        }
    }

    func testQuestionsAreIndependentAndErrorsKeepThePromptForRetry() async {
        let store = SideQuestionStore(prompt: "  Why did this fail?  ")
        var prompts: [String] = []
        var shouldFail = true
        let coordinator = SideQuestionCoordinator { prompt in
            prompts.append(prompt)
            if shouldFail { throw URLError(.notConnectedToInternet) }
            return "A temporary answer"
        }
        store.ask()
        await coordinator.answer(store: store)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.prompt, "  Why did this fail?  ")
        XCTAssertTrue(store.canAsk)

        shouldFail = false
        store.ask()
        await coordinator.answer(store: store)
        XCTAssertEqual(store.answer, "A temporary answer")
        XCTAssertNil(store.errorMessage)

        store.prompt = "Explain another step"
        store.ask()
        XCTAssertNil(store.answer)
        await coordinator.answer(store: store)
        XCTAssertEqual(prompts, ["Why did this fail?", "Why did this fail?", "Explain another step"])
    }

    func testDismissedRequestCannotOverwriteANewerQuestion() async throws {
        let store = SideQuestionStore(prompt: "First question")
        let started = expectation(description: "Generation started")
        var continuation: CheckedContinuation<String, Never>?
        let coordinator = SideQuestionCoordinator { _ in
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        store.ask()
        let task = Task { await coordinator.answer(store: store) }
        await fulfillment(of: [started], timeout: 2)
        store.cancel()
        store.prompt = "Second question"
        store.ask()
        let newerID = try XCTUnwrap(store.request?.id)
        continuation?.resume(returning: "Obsolete answer")
        await task.value
        XCTAssertNil(store.answer)
        XCTAssertEqual(store.request?.id, newerID)
        store.complete("Current answer", requestID: newerID)
        XCTAssertEqual(store.answer, "Current answer")
    }

    func testCancellationIsSilentAndDuplicateSubmitsAreIgnored() async {
        let store = SideQuestionStore(prompt: "Question")
        store.ask()
        let id = store.request?.id
        store.ask()
        XCTAssertEqual(store.request?.id, id)
        await SideQuestionCoordinator { _ in throw CancellationError() }.answer(store: store)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isGenerating)
        XCTAssertTrue(store.canAsk)
        store.prompt = " \n "
        store.ask()
        XCTAssertFalse(store.isGenerating)
    }
}
