import Darwin
import Foundation

public final class HostMCPStdio: @unchecked Sendable {
    public static let maximumMessageBytes = 512 * 1024
    private let input: Int32
    private let output: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = NSLock()
    private let reader = NSLock()
    private let writer = NSLock()
    private var stopped = false
    private var buffer = Data()
    private var frameStarted: ContinuousClock.Instant?

    public init(input: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        let inputCopy = dup(input), outputCopy = dup(output)
        var wake: [Int32] = [-1, -1]
        guard inputCopy >= 0, outputCopy >= 0, pipe(&wake) == 0 else {
            if inputCopy >= 0 { Darwin.close(inputCopy) }
            if outputCopy >= 0 { Darwin.close(outputCopy) }
            throw HostCLIError.rejected("Could not open MCP stdio.")
        }
        self.input = inputCopy; self.output = outputCopy; wakeRead = wake[0]; wakeWrite = wake[1]
        for descriptor in [inputCopy, outputCopy, wake[0], wake[1]] {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        let inputFlags = fcntl(inputCopy, F_GETFL), outputFlags = fcntl(outputCopy, F_GETFL)
        guard inputFlags >= 0, outputFlags >= 0,
            fcntl(inputCopy, F_SETFL, inputFlags | O_NONBLOCK) == 0,
            fcntl(outputCopy, F_SETFL, outputFlags | O_NONBLOCK) == 0
        else { throw HostCLIError.rejected("Could not configure bounded MCP stdio.") }
        _ = fcntl(wake[1], F_SETFL, O_NONBLOCK)
        _ = signal(SIGPIPE, SIG_IGN)
    }
    deinit {
        Darwin.close(input); Darwin.close(output); Darwin.close(wakeRead); Darwin.close(wakeWrite)
    }

    public func cancel() {
        state.withLock {
            guard !stopped else { return }
            stopped = true
            var byte: UInt8 = 1
            _ = Darwin.write(wakeWrite, &byte, 1)
        }
    }

    public func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            let work = Task.detached { try self.readLine() }
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            self.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty, data.count <= Self.maximumMessageBytes, !data.contains(10),
            String(data: data, encoding: .utf8) != nil
        else { throw HostCLIError.rejected("Invalid MCP output frame.") }
        try await withTaskCancellationHandler {
            let work = Task.detached { try self.writeLine(data) }
            try await work.value
            try Task.checkCancellation()
        } onCancel: {
            self.cancel()
        }
    }

    private func readLine() throws -> Data? {
        try reader.withLock {
            while true {
                try checkCancellation()
                if let newline = buffer.firstIndex(of: 10) {
                    let count = buffer.distance(from: buffer.startIndex, to: newline)
                    guard count <= Self.maximumMessageBytes else {
                        throw HostCLIError.rejected("MCP input exceeds 512 KiB.")
                    }
                    var line = Data(buffer.prefix(count))
                    buffer.removeFirst(count + 1)
                    frameStarted = buffer.isEmpty ? nil : .now
                    if line.last == 13 { line.removeLast() }
                    if line.isEmpty { continue }
                    guard String(data: line, encoding: .utf8) != nil else {
                        throw HostCLIError.rejected("MCP input is not UTF-8.")
                    }
                    return line
                }
                guard buffer.count <= Self.maximumMessageBytes else {
                    throw HostCLIError.rejected("MCP input exceeds 512 KiB.")
                }
                if let started = frameStarted, started.duration(to: .now) >= .seconds(5) {
                    throw HostCLIError.timedOut
                }
                var events = [
                    pollfd(fd: input, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                ]
                let result = poll(&events, 2, frameStarted == nil ? -1 : 100)
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw HostCLIError.rejected("MCP input poll failed.") }
                try checkCancellation()
                if result == 0 { continue }
                guard events[0].revents & Int16(POLLNVAL | POLLERR) == 0 else {
                    throw HostCLIError.rejected("MCP input closed.")
                }
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(input, &bytes, bytes.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count >= 0 else { throw HostCLIError.rejected("Could not read MCP input.") }
                if count == 0 {
                    guard buffer.isEmpty else {
                        throw HostCLIError.rejected("MCP input ended inside a frame.")
                    }
                    return nil
                }
                if frameStarted == nil { frameStarted = .now }
                buffer.append(contentsOf: bytes.prefix(count))
            }
        }
    }

    private func writeLine(_ data: Data) throws {
        try writer.withLock {
            var frame = data; frame.append(10)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            try frame.withUnsafeBytes { bytes in
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
                        throw HostCLIError.rejected("MCP output poll failed.")
                    }
                    try checkCancellation()
                    if result == 0 { continue }
                    guard events[0].revents & Int16(POLLNVAL | POLLERR | POLLHUP) == 0 else {
                        throw HostCLIError.rejected("MCP output closed.")
                    }
                    let count = Darwin.write(
                        output, bytes.baseAddress!.advanced(by: offset),
                        min(4096, bytes.count - offset))
                    if count < 0, errno == EINTR || errno == EAGAIN { continue }
                    guard count > 0 else {
                        throw HostCLIError.rejected("Could not write MCP output.")
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
