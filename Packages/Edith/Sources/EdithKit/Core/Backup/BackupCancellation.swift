import Foundation

final class BackupCancellation: @unchecked Sendable {
    @TaskLocal static var current: BackupCancellation?
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func register(_ value: NSFileCoordinator) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            coordinator = value
        }
    }

    func unregister() {
        lock.withLock { coordinator = nil }
    }

    func cancel() {
        let active = lock.withLock {
            cancelled = true
            return coordinator
        }
        active?.cancel()
    }

    func check() throws {
        try Task.checkCancellation()
        try lock.withLock {
            if cancelled { throw CancellationError() }
        }
    }
}

func settingsBackupWithCancellation<T: Sendable>(
    _ operation: @escaping @Sendable () async -> T
) async -> T {
    if BackupCancellation.current != nil { return await operation() }
    let cancellation = BackupCancellation()
    return await withTaskCancellationHandler {
        await BackupCancellation.$current.withValue(cancellation) { await operation() }
    } onCancel: {
        cancellation.cancel()
    }
}
