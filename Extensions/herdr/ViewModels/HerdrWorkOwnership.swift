import Foundation

@MainActor enum HerdrWorkOwnership {
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
    static func enable() { stopped = false }
    static func shutdown() async {
        stopped = true
        let pending = tasks.values
        tasks.removeAll()
        for task in pending { task.cancel() }
        for task in pending { await task.value }
    }
}
