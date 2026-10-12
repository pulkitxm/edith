import Foundation

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
    func shutdown() {
        stopped = true
        for task in tasks.values { task.cancel() }
    }
    func shutdownAndWait() async {
        shutdown()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
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
