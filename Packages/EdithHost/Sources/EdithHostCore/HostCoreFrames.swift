import Darwin
import Foundation

public struct HostCoreFrames: Sendable {
    public static let maximumBytes = 12 << 20
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        var start = data.startIndex
        for end in data.indices where data[end] == 10 {
            guard buffer.count + data.distance(from: start, to: end) < Self.maximumBytes,
                frames.count < 64
            else { throw HostWorkerError.invalidResponse }
            buffer.append(contentsOf: data[start..<end])
            guard !buffer.isEmpty else { throw HostWorkerError.invalidResponse }
            frames.append(buffer)
            buffer = Data()
            start = data.index(after: end)
        }
        guard buffer.count + data.distance(from: start, to: data.endIndex) < Self.maximumBytes
        else {
            throw HostWorkerError.invalidResponse
        }
        buffer.append(contentsOf: data[start...])
        return frames
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        guard data.count < maximumBytes else { throw HostWorkerError.invalidResponse }
        data.append(10)
        return data
    }
}

public final class HostCorePipeWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "edith.core.control")
    private let lock = NSLock()
    private var queuedBytes = 0
    private var stopped = false

    public init(descriptor: Int32) throws {
        let owned = dup(descriptor)
        guard owned >= 0 else { throw HostWorkerError.exited }
        let flags = fcntl(owned, F_GETFL)
        guard flags >= 0, fcntl(owned, F_SETFL, flags | O_NONBLOCK) == 0,
            fcntl(owned, F_SETFD, FD_CLOEXEC) == 0,
            fcntl(owned, F_SETNOSIGPIPE, 1) == 0
        else { Darwin.close(owned); throw HostWorkerError.exited }
        self.descriptor = owned
    }

    deinit { Darwin.close(descriptor) }

    public func send<T: Encodable>(_ value: T) async throws {
        try await send(HostCoreFrames.encode(value))
    }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= HostCoreFrames.maximumBytes,
            lock.withLock({
                guard !stopped, data.count <= HostCoreFrames.maximumBytes - queuedBytes else {
                    return false
                }
                queuedBytes += data.count
                return true
            })
        else { throw HostWorkerError.rejected }
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                defer { self.lock.withLock { self.queuedBytes -= data.count } }
                do { try self.write(data); continuation.resume() } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func shutdown() async {
        lock.withLock { stopped = true }
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func write(_ data: Data) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !lock.withLock({ stopped }), ContinuousClock.now < deadline else {
                    throw HostWorkerError.exited
                }
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    throw HostWorkerError.exited
                }
                var fd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let result = poll(&fd, 1, 100)
                guard result >= 0 || errno == EINTR else { throw HostWorkerError.exited }
                guard fd.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                    throw HostWorkerError.exited
                }
            }
        }
    }
}
