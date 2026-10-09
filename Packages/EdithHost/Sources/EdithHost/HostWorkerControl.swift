import EdithHostCore
import Foundation

final class HostWorkerControl: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle

    init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func send<T: Encodable>(_ value: T) throws {
        let bytes = try HostWorkerFrames.encode(value)
        try lock.withLock { try handle.write(contentsOf: bytes) }
    }

    func close() throws { try lock.withLock { try handle.close() } }
}
