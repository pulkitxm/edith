import Foundation

final class UsageBackupCancellation: @unchecked Sendable {
    @TaskLocal static var current: UsageBackupCancellation?
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

final class UsageBackupRestoreToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var changes: Set<String> = []

    var restoredNames: Set<String> { lock.withLock { changes } }
    func recordChange(_ name: String) { lock.withLock { _ = changes.insert(name) } }

    func invalidate() { lock.withLock { valid = false } }

    func performIfValid(_ operation: () throws -> Void) rethrows -> Bool {
        try lock.withLock {
            guard valid else { return false }
            try operation()
            return true
        }
    }
}
