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

@MainActor final class HerdrWorkScope {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var stopped = false
    var pendingCount: Int { tasks.count }
    @discardableResult func start(_ operation: @escaping @MainActor () async -> Void)
        -> Task<Void, Never>
    {
        guard !stopped else { let task = Task {}; task.cancel(); return task }
        let id = UUID()
        let task = Task { [self] in
            defer { tasks.removeValue(forKey: id) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }
    func retain(_ task: Task<Void, Never>) {
        let id = UUID()
        tasks[id] = Task { [self] in
            await task.value
            tasks.removeValue(forKey: id)
        }
    }
    func enable() { stopped = false }
    func cancel() {
        stopped = true
        for task in tasks.values { task.cancel() }
    }
    func shutdown() async {
        cancel()
        let pending = Array(tasks.values)
        for task in pending { await task.value }
    }
}

@MainActor enum HerdrWorkOwnership {
    private nonisolated static let callbacks = HerdrCallbackWork()
    static let interface = HerdrWorkScope()
    static let worker = HerdrWorkScope()
    private static let interfaceStores = NSHashTable<AnyObject>.weakObjects()
    nonisolated static func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        callbacks.start(operation)
    }
    static var stopped: Bool { interface.stopped }
    static var pendingCount: Int { interface.pendingCount + worker.pendingCount }
    static var sharesProcessWithInterface: Bool { !interfaceStores.allObjects.isEmpty }
    @discardableResult static func start(_ operation: @escaping @MainActor () async -> Void)
        -> Task<Void, Never>
    {
        interface.start(operation)
    }
    static func retain(_ task: Task<Void, Never>) { interface.retain(task) }
    static func registerInterface(_ store: AnyObject) { interfaceStores.add(store) }
    static func unregisterInterface(_ store: AnyObject) { interfaceStores.remove(store) }
    static func enable() {
        worker.enable()
        interface.enable()
        callbacks.enable()
    }
    static func cancel() {
        worker.cancel()
        guard !sharesProcessWithInterface else { return }
        interface.cancel()
        callbacks.cancel()
    }
    static func shutdown() async {
        cancel()
        await worker.shutdown()
        guard !sharesProcessWithInterface else { return }
        await interface.shutdown()
        await callbacks.drain()
    }
}
