import Foundation

@MainActor
final class RecentChatPreloadQueue {
    private struct Job {
        let token = UUID()
        let operation: @MainActor () async -> Void
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let concurrency: Int
    private var pending: [String] = []
    private var jobs: [String: Job] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(concurrency: Int = 2) {
        precondition(concurrency > 0)
        self.concurrency = concurrency
    }

    func enqueue(id: String, priority: Bool = false, operation: @escaping @MainActor () async -> Void) {
        if jobs[id] == nil {
            jobs[id] = Job(operation: operation)
            pending.append(id)
        }
        if priority, let index = pending.firstIndex(of: id) {
            pending.remove(at: index)
            pending.insert(id, at: 0)
        }
        drain()
    }

    func request(id: String, operation: @escaping @MainActor () async -> Void) async {
        await withCheckedContinuation { continuation in
            enqueue(id: id, priority: true, operation: operation)
            jobs[id]?.waiters.append(continuation)
        }
    }

    func waitUntilIdle() async {
        guard !jobs.isEmpty else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    func cancelAll() {
        for task in running.values { task.cancel() }
        let waiters = jobs.values.flatMap(\.waiters) + idleWaiters
        running = [:]
        jobs = [:]
        pending = []
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func drain() {
        while running.count < concurrency, !pending.isEmpty {
            let id = pending.removeFirst()
            guard let job = jobs[id] else { continue }
            running[id] = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                await job.operation()
                self?.finish(id: id, token: job.token)
            }
        }
    }

    private func finish(id: String, token: UUID) {
        guard let job = jobs[id], job.token == token else { return }
        jobs[id] = nil
        running[id] = nil
        for waiter in job.waiters { waiter.resume() }
        drain()
        if jobs.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }
}
