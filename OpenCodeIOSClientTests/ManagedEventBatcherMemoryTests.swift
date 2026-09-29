import XCTest
@testable import OpenClient

final class ManagedEventBatcherMemoryTests: XCTestCase {
    func testLargeBurstReleasesQueueCapacityAfterDrain() async throws {
        let seed = try delta("seed")
        let burst = try (0..<4_096).map { try delta(String($0)) }
        let gate = Gate()
        let recorder = Recorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            await recorder.append(event)
            if event.envelope.properties.delta == "seed" { await gate.wait() }
        }
        let delivery = Task { await batcher.enqueueAndFlush(seed) }
        await fulfillment(of: [gate.entered], timeout: 5)

        for event in burst { await batcher.enqueue(event) }
        let queued = await batcher.queueStats
        XCTAssertEqual(queued.count, burst.count)
        XCTAssertGreaterThanOrEqual(queued.capacity, burst.count)

        await gate.open()
        await delivery.value
        let drained = await batcher.queueStats
        XCTAssertEqual(drained.count, 0)
        XCTAssertEqual(drained.capacity, 0)
        let values = await recorder.values
        XCTAssertEqual(values, ["seed"] + (0..<burst.count).map(String.init))
        await batcher.stop()
    }

    func testSuspendedLastBatchAlreadyHasNoQueueBuffer() async throws {
        let seed = try delta("seed")
        let burst = try (0..<4_096).map { try delta(String($0)) }
        let seedGate = Gate()
        let lastBatchGate = Gate()
        let recorder = Recorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            await recorder.append(event)
            switch event.envelope.properties.delta {
            case "seed": await seedGate.wait()
            // 170 full batches of 24 precede the final 16 events.
            case "4080": await lastBatchGate.wait()
            default: break
            }
        }
        let delivery = Task { await batcher.enqueueAndFlush(seed) }
        await fulfillment(of: [seedGate.entered], timeout: 5)
        for event in burst { await batcher.enqueue(event) }
        let queued = await batcher.queueStats
        XCTAssertGreaterThanOrEqual(queued.capacity, burst.count)

        await seedGate.open()
        await fulfillment(of: [lastBatchGate.entered], timeout: 5)
        let suspended = await batcher.queueStats
        XCTAssertEqual(suspended.count, 0)
        XCTAssertEqual(suspended.capacity, 0, "Release before awaiting the final batch's callbacks")

        await lastBatchGate.open()
        await delivery.value
        let values = await recorder.values
        XCTAssertEqual(values, ["seed"] + (0..<burst.count).map(String.init))
        await batcher.stop()
    }

    func testReentrantEnqueuePreservesOrderAcross24EventBoundaryAndEmptyQueue() async throws {
        let events = try (0...52).map { try delta(String($0)) }
        let seedGate = Gate()
        let firstBatchGate = Gate()
        let lastBatchGate = Gate()
        let recorder = Recorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            await recorder.append(event)
            switch event.envelope.properties.delta {
            case "0": await seedGate.wait()
            case "1": await firstBatchGate.wait()
            case "49": await lastBatchGate.wait()
            default: break
            }
        }
        let delivery = Task { await batcher.enqueueAndFlush(events[0]) }
        await fulfillment(of: [seedGate.entered], timeout: 5)
        for event in events[1...49] { await batcher.enqueue(event) }
        await seedGate.open()

        await fulfillment(of: [firstBatchGate.entered], timeout: 5)
        let firstBatch = await batcher.queueStats
        XCTAssertEqual(firstBatch.count, 25, "Only 24 events leave the queue per batch")
        await batcher.enqueue(events[50])
        await batcher.enqueue(events[51])
        await batcher.flush()
        let stillSuspended = await recorder.values
        XCTAssertEqual(stillSuspended, ["0", "1"], "Reentrant flush must not overtake delivery")
        await firstBatchGate.open()

        await fulfillment(of: [lastBatchGate.entered], timeout: 5)
        let lastBatch = await batcher.queueStats
        XCTAssertEqual(lastBatch.count, 0)
        XCTAssertEqual(lastBatch.capacity, 0)
        await batcher.enqueue(events[52])
        await lastBatchGate.open()
        await delivery.value

        let values = await recorder.values
        XCTAssertEqual(values, (0...52).map(String.init))
        let drained = await batcher.queueStats
        XCTAssertEqual(drained.capacity, 0)
        await batcher.stop()
    }

    func testStopReleasesBurstAndDoesNotDeliverQueuedOrLaterEvents() async throws {
        let seed = try delta("seed")
        let pending = try delta("pending")
        let later = try delta("later")
        let seedGate = Gate()
        let batchGate = Gate()
        let recorder = Recorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            await recorder.append(event)
            switch event.envelope.properties.delta {
            case "seed": await seedGate.wait()
            case "pending": await batchGate.wait()
            default: break
            }
        }
        let delivery = Task { await batcher.enqueueAndFlush(seed) }
        await fulfillment(of: [seedGate.entered], timeout: 5)
        for _ in 0..<4_096 { await batcher.enqueue(pending) }
        let queued = await batcher.queueStats
        XCTAssertEqual(queued.count, 4_096)
        XCTAssertGreaterThanOrEqual(queued.capacity, 4_096)

        await seedGate.open()
        await fulfillment(of: [batchGate.entered], timeout: 5)
        let suspended = await batcher.queueStats
        XCTAssertEqual(suspended.count, 4_096 - 24)
        await batcher.stop()
        let stopped = await batcher.queueStats
        XCTAssertEqual(stopped.count, 0)
        XCTAssertEqual(stopped.capacity, 0)
        await batcher.enqueue(later)
        await batchGate.open()
        await delivery.value
        await batcher.flush()

        let values = await recorder.values
        XCTAssertEqual(values, ["seed", "pending"], "Stop also skips the remaining extracted events")
        let drained = await batcher.queueStats
        XCTAssertEqual(drained.count, 0)
        XCTAssertEqual(drained.capacity, 0)
    }

    func testStatusAndLSPCoalescingKeepsOrderAndRebuildsIndexesAcrossBatches() async throws {
        let seed = try delta("seed")
        let prefix = try (1...24).map { try delta(String($0)) }
        let busy = try event("session.status", #"{"sessionID":"ses_test","status":{"type":"busy"}}"#)
        let idle = try event("session.status", #"{"sessionID":"ses_test","status":{"type":"idle"}}"#)
        let lsp = try event("lsp.updated", "{}")
        let tail = try [
            busy,
            delta("between"),
            lsp,
            event("session.status", #"{"sessionID":"ses_other","status":{"type":"busy"}}"#),
            event("session.status", #"{"sessionID":"ses_test","status":{"type":"busy"}}"#, directory: "/tmp/other"),
            event("lsp.updated", "{}", directory: "/tmp/other"),
            delta("tail"),
        ]
        let seedGate = Gate()
        let firstBatchGate = Gate()
        let recorder = Recorder()
        let batcher = OpenCodeManagedEventBatcher { event in
            await recorder.append(event)
            switch event.envelope.properties.delta {
            case "seed": await seedGate.wait()
            case "1": await firstBatchGate.wait()
            default: break
            }
        }
        let delivery = Task { await batcher.enqueueAndFlush(seed) }
        await fulfillment(of: [seedGate.entered], timeout: 5)
        for event in prefix + tail { await batcher.enqueue(event) }
        await batcher.enqueue(busy)
        await batcher.enqueue(lsp)
        let queued = await batcher.queueStats
        XCTAssertEqual(queued.count, 31)
        await seedGate.open()

        await fulfillment(of: [firstBatchGate.entered], timeout: 5)
        await batcher.enqueue(idle)
        await batcher.enqueue(lsp)
        let remaining = await batcher.queueStats
        XCTAssertEqual(remaining.count, 7)
        await firstBatchGate.open()
        await delivery.value

        let values = await recorder.values
        XCTAssertEqual(values, ["seed"] + (1...24).map(String.init) + [
            "status:/tmp/project:ses_test:idle", "between", "lsp:/tmp/project",
            "status:/tmp/project:ses_other:busy", "status:/tmp/other:ses_test:busy",
            "lsp:/tmp/other", "tail",
        ])
        let drained = await batcher.queueStats
        XCTAssertEqual(drained.capacity, 0)
        await batcher.stop()
    }

    // Same legacy JSON shapes as OpenCodeStreamingTests, decoded through the production boundary.
    private func event(_ type: String, _ properties: String, directory: String = "/tmp/project") throws -> OpenCodeManagedEvent {
        let raw = #"{"directory":"\#(directory)","payload":{"type":"\#(type)","properties":\#(properties)}}"#
        let decoded: OpenCodeManagedEvent?
        if case let .event(event) = OpenCodeEventManager.decodeManagedEvent(from: raw) {
            decoded = event
        } else {
            decoded = nil
        }
        return try XCTUnwrap(decoded, "Invalid managed event fixture: \(raw)")
    }

    private func delta(_ value: String) throws -> OpenCodeManagedEvent {
        try event("message.part.delta",
            #"{"sessionID":"ses_test","messageID":"msg_assistant","partID":"part_text","field":"text","delta":"\#(value)"}"#)
    }

    private actor Recorder {
        private(set) var values: [String] = []

        func append(_ event: OpenCodeManagedEvent) {
            XCTAssertFalse(Task.isCancelled)
            switch event.typed {
            case let .messagePartDelta(_, _, _, _, delta): values.append(delta)
            case let .sessionStatus(sessionID, status): values.append("status:\(event.directory):\(sessionID):\(status)")
            case .lspUpdated: values.append("lsp:\(event.directory)")
            default: XCTFail("Unexpected fixture event: \(event.envelope.type)")
            }
        }
    }

    private actor Gate {
        nonisolated let entered = XCTestExpectation(description: "Delivery suspended")
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation {
                continuation = $0
                entered.fulfill()
            }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private extension OpenCodeManagedEventBatcher {
    // Start the explicit flush in the same actor turn as enqueue, without racing the timer.
    func enqueueAndFlush(_ event: OpenCodeManagedEvent) async {
        enqueue(event)
        await flush()
    }
}
