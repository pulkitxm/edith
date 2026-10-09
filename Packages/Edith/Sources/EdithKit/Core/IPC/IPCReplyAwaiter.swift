import Foundation

public enum IPCReplyAwaiter {
    public static func awaitReply(
        _ name: Notification.Name, timeout: TimeInterval,
        matching: @escaping ([AnyHashable: Any]) -> Bool = { _ in true },
        waiting: @escaping @Sendable () -> Void = {},
        trigger: @escaping @Sendable () -> Void
    ) async -> [AnyHashable: Any]? {
        let waiter = IPCReplyWaiter()
        let token = IPC.observe(
            name,
            info: { payload in
                if matching(payload) { waiter.deliver(payload) }
            })
        defer { IPC.stopObserving(token) }
        trigger()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout.isFinite ? max(0, timeout) : 0))
            guard !Task.isCancelled else { return }
            waiter.cancel()
        }
        let noteTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, !waiter.isFinished else { return }
            waiting()
        }
        let value = await waiter.wait()
        timeoutTask.cancel()
        noteTask.cancel()
        return value
    }
}

private struct ReplyValue: @unchecked Sendable {
    let payload: [AnyHashable: Any]
}

public final class IPCReplyWaiter: @unchecked Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<ReplyValue?, Never>)
        case finished(ReplyValue?)
    }

    public init() {}

    private let lock = NSLock()
    private var state = State.idle

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        if case .finished = state { return true }
        return false
    }

    @discardableResult
    public func deliver(_ payload: [AnyHashable: Any]) -> Bool {
        finish(ReplyValue(payload: payload))
    }

    @discardableResult
    public func cancel() -> Bool {
        finish(nil)
    }

    public func wait() async -> [AnyHashable: Any]? {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            cancel()
        }
        return result?.payload
    }

    private func install(_ continuation: CheckedContinuation<ReplyValue?, Never>) {
        var completed: ReplyValue??
        lock.lock()
        switch state {
        case .idle:
            state = .waiting(continuation)
        case let .finished(value):
            completed = value
        case .waiting:
            completed = .some(nil)
        }
        lock.unlock()
        if let completed { continuation.resume(returning: completed) }
    }

    private func finish(_ value: ReplyValue?) -> Bool {
        var continuation: CheckedContinuation<ReplyValue?, Never>?
        lock.lock()
        switch state {
        case .idle:
            state = .finished(value)
        case let .waiting(waiter):
            state = .finished(value)
            continuation = waiter
        case .finished:
            lock.unlock()
            return false
        }
        lock.unlock()
        continuation?.resume(returning: value)
        return true
    }
}
