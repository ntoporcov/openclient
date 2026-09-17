import XCTest
@testable import OpenClient

@MainActor
final class RecentChatPreloadQueueTests: XCTestCase {
    func testConcurrencyTwoStartsTwoJobsAndRefillsOnlyReleasedSlots() async {
        let queue = RecentChatPreloadQueue(concurrency: 2)
        let gates = (0..<4).map { Gate("job \($0)") }
        var active = 0
        var maximumActive = 0
        var started: [Int] = []
        defer {
            queue.cancelAll()
            gates.forEach { $0.open() }
        }

        for (index, gate) in gates.enumerated() {
            queue.enqueue(id: "job-\(index)") {
                active += 1
                maximumActive = max(maximumActive, active)
                started.append(index)
                await gate.wait()
                active -= 1
            }
        }

        await fulfillment(of: [gates[0].entered, gates[1].entered], timeout: 1)
        XCTAssertEqual(Set(started), Set([0, 1]))
        XCTAssertEqual(active, 2)

        gates[0].open()
        await fulfillment(of: [gates[2].entered], timeout: 1)
        XCTAssertEqual(Set(started), Set([0, 1, 2]))
        XCTAssertEqual(active, 2)

        gates[2].open()
        await fulfillment(of: [gates[3].entered], timeout: 1)
        XCTAssertEqual(started.count, 4)
        XCTAssertEqual(active, 2)

        gates[1].open()
        gates[3].open()
        await assertIdle(queue)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(maximumActive, 2)
    }

    func testRequestsJoinEnqueuedJobAndAllWaitForItsCompletion() async {
        let queue = RecentChatPreloadQueue()
        let gate = Gate("enqueued job")
        var operationCalls = 0
        var returnedRequests = 0
        let registered = expectation(description: "Both requests registered")
        registered.expectedFulfillmentCount = 2
        let returned = expectation(description: "Both requests returned")
        returned.expectedFulfillmentCount = 2
        defer {
            queue.cancelAll()
            gate.open()
        }

        queue.enqueue(id: "shared") {
            operationCalls += 1
            await gate.wait()
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        for _ in 0..<2 {
            Task { @MainActor in
                // Registration cannot interleave with this test on MainActor before request suspends.
                registered.fulfill()
                await queue.request(id: "shared") {
                    XCTFail("A request must reuse the enqueued operation")
                }
                returnedRequests += 1
                returned.fulfill()
            }
        }
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(operationCalls, 1)
        XCTAssertEqual(returnedRequests, 0)

        gate.open()
        await fulfillment(of: [returned], timeout: 1)
        await assertIdle(queue)
        XCTAssertEqual(operationCalls, 1)
        XCTAssertEqual(returnedRequests, 2)
    }

    func testEnqueueJoinsRequestedJobWithoutReplacingItsOperation() async {
        let queue = RecentChatPreloadQueue()
        let gate = Gate("requested job")
        let returned = expectation(description: "Request returned")
        var operationCalls = 0
        var requestReturned = false
        defer {
            queue.cancelAll()
            gate.open()
        }

        Task { @MainActor in
            await queue.request(id: "shared") {
                operationCalls += 1
                await gate.wait()
            }
            requestReturned = true
            returned.fulfill()
        }
        await fulfillment(of: [gate.entered], timeout: 1)
        queue.enqueue(id: "shared") {
            XCTFail("Enqueue must reuse the requested operation")
        }
        XCTAssertFalse(requestReturned)

        gate.open()
        await fulfillment(of: [returned], timeout: 1)
        await assertIdle(queue)
        XCTAssertTrue(requestReturned)
        XCTAssertEqual(operationCalls, 1)
    }

    func testVisibleRequestPromotesPendingJobAheadOfEarlierBackgroundJob() async {
        let queue = RecentChatPreloadQueue(concurrency: 1)
        let blocker = Gate("running blocker")
        let visible = Gate("promoted visible job")
        let background = Gate("earlier background job")
        let registered = expectation(description: "Visible request registered")
        let returned = expectation(description: "Visible request returned")
        var started: [String] = []
        var requestReturned = false
        defer {
            queue.cancelAll()
            [blocker, visible, background].forEach { $0.open() }
        }

        queue.enqueue(id: "blocker") { await blocker.wait() }
        await fulfillment(of: [blocker.entered], timeout: 1)
        queue.enqueue(id: "background") {
            started.append("background")
            await background.wait()
        }
        queue.enqueue(id: "visible") {
            started.append("visible")
            await visible.wait()
        }
        Task { @MainActor in
            registered.fulfill()
            await queue.request(id: "visible") {
                XCTFail("Promotion must preserve the pending operation")
            }
            requestReturned = true
            returned.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertTrue(started.isEmpty)
        XCTAssertFalse(requestReturned)

        blocker.open()
        await fulfillment(of: [visible.entered], timeout: 1)
        XCTAssertEqual(started, ["visible"])
        XCTAssertFalse(requestReturned)

        visible.open()
        await fulfillment(of: [returned, background.entered], timeout: 1)
        XCTAssertEqual(started, ["visible", "background"])
        background.open()
        await assertIdle(queue)
    }

    func testCancelAllResumesRunningPendingAndIdleWaitersAndDropsPendingJobs() async {
        let queue = RecentChatPreloadQueue(concurrency: 1)
        let running = Gate("running job")
        let runningFinished = expectation(description: "Canceled operation finished")
        let registered = expectation(description: "Request and idle waiters registered")
        registered.expectedFulfillmentCount = 3
        let returned = expectation(description: "Request and idle waiters resumed")
        returned.expectedFulfillmentCount = 3
        var returnedWaiters = 0
        var pendingCalls = 0
        var operationFinished = false
        defer {
            queue.cancelAll()
            running.open()
        }

        queue.enqueue(id: "running") {
            await running.wait()
            XCTAssertTrue(Task.isCancelled)
            operationFinished = true
            runningFinished.fulfill()
        }
        await fulfillment(of: [running.entered], timeout: 1)
        queue.enqueue(id: "background") { pendingCalls += 1 }
        for id in ["running", "pending-request"] {
            Task { @MainActor in
                registered.fulfill()
                await queue.request(id: id) { pendingCalls += 1 }
                returnedWaiters += 1
                returned.fulfill()
            }
        }
        Task { @MainActor in
            registered.fulfill()
            await queue.waitUntilIdle()
            returnedWaiters += 1
            returned.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertEqual(returnedWaiters, 0)

        queue.cancelAll()
        await fulfillment(of: [returned], timeout: 1)
        XCTAssertEqual(returnedWaiters, 3)
        XCTAssertFalse(operationFinished, "Cancellation must resume waiters without waiting for operations")
        XCTAssertEqual(pendingCalls, 0)
        await assertIdle(queue)

        let freshStarted = expectation(description: "Fresh work started after cancellation")
        queue.enqueue(id: "fresh") { freshStarted.fulfill() }
        await fulfillment(of: [freshStarted], timeout: 1)
        await assertIdle(queue)
        running.open()
        await fulfillment(of: [runningFinished], timeout: 1)
        await assertIdle(queue)
        XCTAssertEqual(pendingCalls, 0)
    }

    func testStaleCanceledCompletionDoesNotEraseSameIDReplacementOrReleaseItsSlot() async {
        let queue = RecentChatPreloadQueue(concurrency: 1)
        let old = Gate("old job")
        let replacement = Gate("replacement job")
        let oldFinished = expectation(description: "Old canceled operation finished")
        let registered = expectation(description: "Replacement request registered")
        let returned = expectation(description: "Replacement request returned")
        let followerStarted = expectation(description: "Follower started")
        var replacementReturned = false
        var replacementFinished = false
        var followerCalls = 0
        var replacementCalls = 0
        defer {
            queue.cancelAll()
            old.open()
            replacement.open()
        }

        queue.enqueue(id: "shared") {
            await old.wait()
            XCTAssertTrue(Task.isCancelled)
            // There is no suspension between this signal, operation return, and the queue's finish.
            oldFinished.fulfill()
        }
        await fulfillment(of: [old.entered], timeout: 1)
        queue.cancelAll()

        Task { @MainActor in
            await queue.request(id: "shared") {
                replacementCalls += 1
                await replacement.wait()
                XCTAssertFalse(Task.isCancelled)
                replacementFinished = true
            }
            XCTAssertTrue(replacementFinished, "The replacement waiter must survive the stale completion")
            replacementReturned = true
            returned.fulfill()
        }
        await fulfillment(of: [replacement.entered], timeout: 1)
        old.open()
        await fulfillment(of: [oldFinished], timeout: 1)
        XCTAssertFalse(replacementReturned)

        queue.enqueue(id: "follower") {
            XCTAssertTrue(replacementFinished, "The replacement must retain its concurrency slot")
            followerCalls += 1
            followerStarted.fulfill()
        }
        let joined = expectation(description: "Joined replacement request returned")
        var joinedReturned = false
        Task { @MainActor in
            registered.fulfill()
            await queue.request(id: "shared") {
                XCTFail("Stale completion must not remove the replacement's deduplication entry")
            }
            XCTAssertTrue(replacementFinished)
            joinedReturned = true
            joined.fulfill()
        }
        await fulfillment(of: [registered], timeout: 1)
        XCTAssertFalse(replacementReturned)
        XCTAssertFalse(joinedReturned)
        XCTAssertEqual(followerCalls, 0)

        replacement.open()
        await fulfillment(of: [returned, joined, followerStarted], timeout: 1)
        await assertIdle(queue)
        XCTAssertEqual(replacementCalls, 1)
        XCTAssertEqual(followerCalls, 1)
    }

    private func assertIdle(_ queue: RecentChatPreloadQueue) async {
        let idle = expectation(description: "Queue became idle")
        Task { @MainActor in
            await queue.waitUntilIdle()
            idle.fulfill()
        }
        await fulfillment(of: [idle], timeout: 1)
    }

    @MainActor
    private final class Gate {
        let entered: XCTestExpectation
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        init(_ name: String) {
            entered = XCTestExpectation(description: "\(name) entered")
            entered.assertForOverFulfill = true
        }

        func wait() async {
            // Deliberately ignore task cancellation so tests control stale operation completion.
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
                entered.fulfill()
            }
        }

        func open() {
            isOpen = true
            let waiting = continuation
            continuation = nil
            waiting?.resume()
        }
    }
}
