import Foundation

private final class HerdrCallbackWork: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    func start(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        lock.withLock {
            guard !stopped else { return }
            let id = UUID()
            tasks[id] = Task { @MainActor [self] in
                defer { _ = lock.withLock { tasks.removeValue(forKey: id) } }
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    func enable() { lock.withLock { stopped = false } }

    func cancel() {
        let pending = lock.withLock {
            stopped = true
            return Array(tasks.values)
        }
        for task in pending { task.cancel() }
    }

    func drain() async {
        let pending = lock.withLock { Array(tasks.values) }
        for task in pending { await task.value }
    }
}

@MainActor enum HerdrWorkOwnership {
    private nonisolated static let callbacks = HerdrCallbackWork()
    nonisolated static func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        callbacks.start(operation)
    }
    private static var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) static var stopped = false
    static var pendingCount: Int { tasks.count }
    @discardableResult static func start(_ operation: @escaping @MainActor () async -> Void)
        -> Task<Void, Never>
    {
        guard !stopped else { let task = Task {}; task.cancel(); return task }
        let id = UUID()
        let task = Task {
            defer { tasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }
    static func enable() {
        stopped = false
        callbacks.enable()
    }
    static func cancel() {
        stopped = true
        callbacks.cancel()
        for task in tasks.values { task.cancel() }
    }
    static func shutdown() async {
        cancel()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
        await callbacks.drain()
    }
}
