import Foundation
import os

@MainActor
final class MusicTaskOwner {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
    }
    func cancelAndRetain(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        let id = UUID()
        tasks[id] = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            await task.value
        }
    }
    func shutdown() {
        stopped = true
        for task in tasks.values { task.cancel() }
    }
    func shutdownAndWait() async {
        shutdown()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
    }
    nonisolated static func withJoinedCancellation<Value: Sendable>(
        operation: @escaping @Sendable () async -> Value,
        onCancel: @escaping @Sendable () async -> Void
    ) async -> Value {
        let cancellation = MusicCancellationTask()
        let result = await withTaskCancellationHandler {
            await operation()
        } onCancel: {
            cancellation.schedule(onCancel)
        }
        await cancellation.finish()
        return result
    }
    nonisolated static func detached<Value: Sendable>(
        _ operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        let task = Task.detached(operation: operation)
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

private struct MusicCancellationTask: Sendable {
    private struct State: Sendable {
        var closed = false
        var task: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func schedule(_ operation: @escaping @Sendable () async -> Void) {
        state.withLock {
            guard !$0.closed, $0.task == nil else { return }
            $0.task = Task(operation: operation)
        }
    }

    func finish() async {
        let task = state.withLock {
            $0.closed = true
            return $0.task
        }
        await task?.value
    }
}
