import Foundation

@MainActor
enum HostRemoteTaskRetirement {
    static func cancelAndJoin(
        cancel: () -> Void,
        joinLaunch: () async -> Void,
        joinConfiguration: () async -> Void
    ) async {
        cancel()
        await joinLaunch()
        await joinConfiguration()
    }
}

@MainActor
final class HostRemoteInvocationRetirement {
    private struct Work {
        let identity: UUID
        let task: Task<Void, Never>
    }
    private var work: [UUID: Work] = [:]
    private var closed = false
    var count: Int { work.count }

    func accepts(_ token: UUID) -> Bool {
        !closed && work.count < 8 && work[token] == nil
    }

    func retain(_ task: Task<Void, Never>, token: UUID) {
        precondition(accepts(token))
        let identity = UUID()
        work[token] = Work(identity: identity, task: task)
        Task { [self] in
            await task.value
            finish(token, identity: identity)
        }
    }

    func cancel(_ token: UUID) { work[token]?.task.cancel() }

    func close() {
        closed = true
        for item in work.values { item.task.cancel() }
    }

    func closeAndWait() async {
        close()
        for (token, item) in work {
            await item.task.value
            finish(token, identity: item.identity)
        }
    }

    private func finish(_ token: UUID, identity: UUID) {
        guard work[token]?.identity == identity else { return }
        work[token] = nil
    }
}

final class HostRemoteCallbackRetirement: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var pending = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    func schedule(_ action: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never>? {
        let accepted = lock.withLock { () -> Bool in
            guard !closed else { return false }
            pending += 1
            return true
        }
        guard accepted else { return nil }
        let actual = Task { @MainActor in await action() }
        Task { [self] in
            await actual.value; finish()
        }
        return actual
    }

    func close() { lock.withLock { closed = true } }

    func closeAndWait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                closed = true
                guard pending != 0 else { return true }
                waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func finish() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(pending > 0)
            pending -= 1
            guard closed, pending == 0 else { return [] }
            let ready = waiters
            waiters.removeAll()
            return ready
        }
        for waiter in ready { waiter.resume() }
    }
}
