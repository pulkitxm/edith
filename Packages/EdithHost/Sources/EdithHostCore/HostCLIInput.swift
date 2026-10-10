import Darwin
import Foundation

public final class HostCLIInput: @unchecked Sendable {
    private let descriptor: Int32
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let state = NSLock()
    private let reader = NSLock()
    private var stopped = false
    private var original: termios?
    private var dimensions: (Int, Int)?
    public let interactive: Bool

    public init(descriptor: Int32 = STDIN_FILENO, output: Int32 = STDOUT_FILENO) throws {
        let copy = dup(descriptor)
        var wake: [Int32] = [-1, -1]
        guard copy >= 0, pipe(&wake) == 0 else {
            if copy >= 0 { Darwin.close(copy) }
            throw HostCLIError.rejected("Could not open command stdin.")
        }
        self.descriptor = copy; wakeRead = wake[0]; wakeWrite = wake[1]
        for fd in [copy, wake[0], wake[1]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(wake[1], F_SETFL, O_NONBLOCK)
        interactive = isatty(descriptor) != 0 && isatty(output) != 0
        if interactive {
            var saved = termios()
            guard tcgetattr(copy, &saved) == 0 else {
                Darwin.close(copy); Darwin.close(wake[0]); Darwin.close(wake[1])
                throw HostCLIError.rejected("Could not read terminal settings.")
            }
            var raw = saved
            cfmakeraw(&raw)
            guard tcsetattr(copy, TCSANOW, &raw) == 0 else {
                Darwin.close(copy); Darwin.close(wake[0]); Darwin.close(wake[1])
                throw HostCLIError.rejected("Could not configure terminal input.")
            }
            original = saved
        }
    }

    deinit {
        restore()
        Darwin.close(descriptor); Darwin.close(wakeRead); Darwin.close(wakeWrite)
    }

    public var source: HostCLILiveInput {
        HostCLILiveInput(
            interactive: interactive, receive: { try await self.receive() },
            cancel: { self.cancel() })
    }

    public func cancel() {
        state.withLock {
            if !stopped {
                stopped = true
                var byte: UInt8 = 1
                _ = Darwin.write(wakeWrite, &byte, 1)
            }
        }
        reader.withLock { restore() }
    }

    public func receive() async throws -> HostCLIInputEvent? {
        try await withTaskCancellationHandler {
            let work = Task.detached { try self.readEvent() }
            let event = try await work.value
            try Task.checkCancellation()
            return event
        } onCancel: {
            self.cancel()
        }
    }

    private func restore() {
        if var saved = original {
            _ = tcsetattr(descriptor, TCSANOW, &saved)
            _ = tcflush(descriptor, TCIFLUSH)
            original = nil
        }
    }

    private func readEvent() throws -> HostCLIInputEvent? {
        try reader.withLock {
            while true {
                if state.withLock({ stopped }) { throw CancellationError() }
                if interactive {
                    var size = winsize()
                    if ioctl(descriptor, TIOCGWINSZ, &size) == 0 {
                        let columns = Int(size.ws_col), rows = Int(size.ws_row)
                        if (1...1000).contains(columns), (1...1000).contains(rows),
                            dimensions?.0 != columns || dimensions?.1 != rows
                        {
                            dimensions = (columns, rows)
                            return .resize(columns: columns, rows: rows)
                        }
                    }
                }
                var events = [
                    pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
                ]
                let ready = poll(&events, 2, 100)
                if ready < 0, errno == EINTR { continue }
                guard ready >= 0 else { throw HostCLIError.rejected("Command stdin poll failed.") }
                if state.withLock({ stopped }) { throw CancellationError() }
                if ready == 0 { continue }
                guard events[0].revents & Int16(POLLNVAL | POLLERR) == 0 else {
                    throw HostCLIError.rejected("Command stdin closed.")
                }
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                if count < 0, interactive, errno == EIO { return nil }
                guard count >= 0 else {
                    throw HostCLIError.rejected("Could not read command stdin.")
                }
                if count == 0 { return nil }
                return .bytes(Data(bytes.prefix(count)))
            }
        }
    }
}
