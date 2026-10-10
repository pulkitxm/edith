import Darwin
import Foundation

public final class HostCLIByteOutput: @unchecked Sendable {
    private let output: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = NSLock()
    private let writer = NSLock()
    private var stopped = false

    public init(descriptor: Int32) throws {
        let copy = dup(descriptor)
        var wake: [Int32] = [-1, -1]
        guard copy >= 0, pipe(&wake) == 0 else {
            if copy >= 0 { Darwin.close(copy) }
            throw HostCLIError.rejected("Could not open command output.")
        }
        let flags = fcntl(copy, F_GETFL)
        guard flags >= 0, fcntl(copy, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(copy); Darwin.close(wake[0]); Darwin.close(wake[1])
            throw HostCLIError.rejected("Could not configure command output.")
        }
        for fd in [copy, wake[0], wake[1]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(wake[1], F_SETFL, O_NONBLOCK)
        _ = signal(SIGPIPE, SIG_IGN)
        output = copy; wakeRead = wake[0]; wakeWrite = wake[1]
    }

    deinit { Darwin.close(output); Darwin.close(wakeRead); Darwin.close(wakeWrite) }

    public func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard data.count <= 4 * 1024 * 1024 else {
            throw HostCLIError.rejected("Command output exceeds 4 MiB.")
        }
        if data.isEmpty { return }
        try await withTaskCancellationHandler {
            let work = Task.detached { try self.write(data) }
            try await work.value
            try Task.checkCancellation()
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        state.withLock {
            guard !stopped else { return }
            stopped = true
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
        }
    }

    private func write(_ data: Data) throws {
        try writer.withLock {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try checkCancellation()
                    guard ContinuousClock.now < deadline else { throw HostCLIError.timedOut }
                    var events = [
                        pollfd(fd: output, events: Int16(POLLOUT), revents: 0),
                        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                    ]
                    let result = poll(&events, 2, 100)
                    if result < 0, errno == EINTR { continue }
                    guard result >= 0 else {
                        throw HostCLIError.rejected("Command output poll failed.")
                    }
                    try checkCancellation()
                    if result == 0 { continue }
                    guard events[0].revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                        throw HostCLIError.rejected("Command output closed.")
                    }
                    let count = Darwin.write(
                        output, bytes.baseAddress!.advanced(by: offset),
                        min(4096, bytes.count - offset))
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else {
                        throw HostCLIError.rejected("Could not write command output.")
                    }
                    offset += count
                }
            }
        }
    }

    private func checkCancellation() throws {
        if state.withLock({ stopped }) { throw CancellationError() }
    }
}
