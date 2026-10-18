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
    private let maximumBytes: Int
    private let onOverflow: @Sendable () -> Void
    private var exceeded = false

    var exceededLimit: Bool { lock.withLock { exceeded } }
    private var waiters: [CheckedContinuation<Data, Never>] = []

    init(
        _ handle: FileHandle, maximumBytes: Int = 64 * 1_024 * 1_024,
        onOverflow: @escaping @Sendable () -> Void = {}
    ) {
        self.maximumBytes = maximumBytes
        self.onOverflow = onOverflow
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
        let overflow = lock.withLock { () -> Bool in
            guard !exceeded else { return false }
            guard chunk.count <= maximumBytes - data.count else {
                exceeded = true
                return true
            }
            data.append(chunk)
            return false
        }
        if overflow { onOverflow() }
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
