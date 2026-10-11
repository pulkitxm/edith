import Foundation

final class MusicTaskOwner: Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var tasks: [UUID: Task<Void, Never>] = [:]
        var stopped = false

        func remove(_ id: UUID) { lock.withLock { _ = tasks.removeValue(forKey: id) } }
        func snapshot() -> [Task<Void, Never>] { lock.withLock { Array(tasks.values) } }
        func close() -> [Task<Void, Never>] {
            lock.withLock {
                stopped = true
                return Array(tasks.values)
            }
        }
    }
    private let state = State()

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        enqueue(operation)
    }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void)
        -> Task<Void, Never>?
    {
        state.lock.withLock {
            guard !state.stopped else { return nil }
            let id = UUID()
            let task = Task { @MainActor [state] in
                defer { state.remove(id) }
                guard !Task.isCancelled else { return }
                await operation()
            }
            state.tasks[id] = task
            return task
        }
    }

    @MainActor func shutdown() {
        let owned = state.close()
        for task in owned { task.cancel() }
    }

    @MainActor func shutdownAndWait() async {
        shutdown()
        let owned = state.snapshot()
        for task in owned { await task.value }
    }

    static func detached<Value: Sendable>(
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
