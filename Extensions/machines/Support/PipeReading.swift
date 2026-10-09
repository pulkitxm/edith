import Foundation

enum PipeReading {
    @discardableResult
    static func consume(_ handle: FileHandle, receive: (Data) -> Void) -> Bool {
        let data = handle.availableData
        guard !data.isEmpty else {
            handle.readabilityHandler = nil
            return false
        }
        receive(data)
        return true
    }
}

final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var ended = false
    private var waiters: [CheckedContinuation<Data, Never>] = []

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [self] handle in
            if !PipeReading.consume(handle, receive: append) { finish() }
        }
    }

    func collected() async -> Data {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Data? in
                guard ended else {
                    waiters.append(continuation)
                    return nil
                }
                return data
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    private func finish() {
        let (result, waiting) = lock.withLock {
            ended = true
            defer { waiters.removeAll() }
            return (data, waiters)
        }
        for waiter in waiting { waiter.resume(returning: result) }
    }
}
