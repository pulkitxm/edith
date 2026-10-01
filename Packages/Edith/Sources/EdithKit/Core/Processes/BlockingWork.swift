import Foundation

public final class WorkCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { value } }

    public func cancel() { lock.withLock { value = true } }
}

public enum BlockingWork {
    public static func perform<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    public static func value<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: body())
            }
        }
    }
}
