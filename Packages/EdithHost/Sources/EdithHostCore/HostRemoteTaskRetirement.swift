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
public final class HostRemoteInvocationAdmission {
    @TaskLocal public static var current: HostRemoteInvocationAdmission?
    private let token: UUID
    private let validate: @MainActor () -> Bool

    init(token: UUID, validate: @escaping @MainActor () -> Bool) {
        self.token = token
        self.validate = validate
    }

    public var isCurrent: Bool { validate() }
    public func authorizes(_ token: UUID) -> Bool { self.token == token && isCurrent }
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
    func contains(_ token: UUID) -> Bool { work[token] != nil }

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

    func admission(for token: UUID) -> HostRemoteInvocationAdmission? {
        guard let item = work[token] else { return nil }
        let identity = item.identity
        return HostRemoteInvocationAdmission(token: token) { [weak self] in
            self?.work[token]?.identity == identity
        }
    }

    func closeAdmission() { closed = true }

    func cancel(_ token: UUID) { work[token]?.task.cancel() }

    func close() {
        closed = true
        for item in work.values { item.task.cancel() }
    }

    func joinCurrent(excluding token: UUID? = nil) async {
        let snapshot = work.filter { $0.key != token }
        for (key, item) in snapshot {
            await item.task.value
            finish(key, identity: item.identity)
        }
    }

    func cancelAndJoin(excluding token: UUID? = nil) async {
        let snapshot = work.filter { $0.key != token }
        for item in snapshot.values { item.task.cancel() }
        for (key, item) in snapshot {
            await item.task.value
            finish(key, identity: item.identity)
        }
    }

    func closeAndWait() async {
        close()
        await cancelAndJoin()
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

    @discardableResult
    func resume() -> Bool {
        lock.withLock {
            guard closed, pending == 0 else { return false }
            closed = false
            return true
        }
    }

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

    func joinCurrent() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
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
            guard pending == 0 else { return [] }
            let ready = waiters
            waiters.removeAll()
            return ready
        }
        for waiter in ready { waiter.resume() }
    }
}
