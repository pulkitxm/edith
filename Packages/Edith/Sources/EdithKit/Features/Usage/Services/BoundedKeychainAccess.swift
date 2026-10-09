import Foundation

final class BoundedKeychainAccess<Value: Sendable>: @unchecked Sendable {
    private struct Request {
        let id: UUID
        var continuation: CheckedContinuation<Value, Never>?
    }

    private let lock = NSLock()
    private var request: Request?

    func run(
        timeout: TimeInterval = 3, fallback: Value,
        operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let started = lock.withLock {
                guard request == nil else { return false }
                request = Request(id: id, continuation: continuation)
                return true
            }
            guard started else {
                continuation.resume(returning: fallback)
                return
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                self.complete(id: id, value: fallback, finished: false)
            }
            DispatchQueue.global(qos: .utility).async {
                self.complete(id: id, value: operation(), finished: true)
            }
        }
    }

    private func complete(id: UUID, value: Value, finished: Bool) {
        let continuation = lock.withLock {
            guard request?.id == id else { return nil as CheckedContinuation<Value, Never>? }
            let continuation = request?.continuation
            if finished {
                request = nil
            } else {
                request?.continuation = nil
            }
            return continuation
        }
        continuation?.resume(returning: value)
    }
}
