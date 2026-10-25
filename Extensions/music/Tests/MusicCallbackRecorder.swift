import os

final class MusicCallbackRecorder<Value: Sendable>: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [Value]())

    func append(_ value: Value) {
        storage.withLock { $0.append(value) }
    }

    var values: [Value] {
        storage.withLock { $0 }
    }
}
