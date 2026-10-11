import Foundation

@MainActor
final class MusicTaskOwner {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !stopped else { return nil }
        let id = UUID()
        let task = Task { [weak self] in
            defer { self?.tasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }
    func shutdown() {
        stopped = true
        for task in tasks.values { task.cancel() }
    }
    func shutdownAndWait() async {
        shutdown()
        let owned = Array(tasks.values)
        for task in owned { await task.value }
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
