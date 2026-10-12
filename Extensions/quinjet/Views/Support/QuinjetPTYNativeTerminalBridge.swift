import Darwin
import EdithExtensionSupport
import Foundation

enum QuinjetPTYNativeTerminalBridge {
    static func run(
        specification: QuinjetPTYTerminalBridgeSpecification, observe: (Data) -> Void = { _ in }
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTTOU, SIG_IGN)
        let terminal = QuinjetPTYRawTerminal()
        try terminal.configure(mouse: specification.mouse, managesPresentation: false)
        defer { terminal.restore() }
        let status = try relay(
            specification: specification, input: .standardInput, output: .standardOutput,
            dimensions: QuinjetPTYTerminalDimensions.current, observe: observe)
        guard status == 0 else { throw QuinjetPTYBridgeExit(status) }
    }

    static func relay(
        specification: QuinjetPTYTerminalBridgeSpecification, input: FileHandle, output: FileHandle,
        dimensions: () -> QuinjetPTYTerminalDimensions, observe: (Data) -> Void = { _ in },
        cancelled: () -> Bool = {
            ExtensionCommandOwnership.isWorker && QuinjetPTYBridgeCancellation.isCancelled
        }
    ) throws -> Int32 {
        var geometry = dimensions()
        let child = try QuinjetPTYNativeTerminalProcess(
            request: specification.request(columns: geometry.columns, rows: geometry.rows),
            dimensions: geometry)
        defer { child.close() }
        let inputFlags = try nonblocking(input.fileDescriptor)
        defer { _ = fcntl(input.fileDescriptor, F_SETFL, inputFlags) }
        let outputFlags = try nonblocking(output.fileDescriptor)
        defer { _ = fcntl(output.fileDescriptor, F_SETFL, outputFlags) }
        _ = try nonblocking(child.terminal.fileDescriptor)
        var router = QuinjetPTYTerminalInputRouter(mouse: specification.mouse, transport: .terminal)
        var toChild = QuinjetPTYTerminalWriteQueue()
        var toOutput = QuinjetPTYTerminalWriteQueue()
        var inputEnded = false
        var childEnded = false
        let clock = ContinuousClock()
        var escapeDeadline: ContinuousClock.Instant?
        var inputCloseDeadline: ContinuousClock.Instant?
        let bufferLimit = 1024 * 1024
        while true {
            if cancelled() { return 130 }
            if let deadline = inputCloseDeadline, clock.now >= deadline { return 0 }
            if let deadline = escapeDeadline, clock.now >= deadline {
                for bytes in try router.flushEscapePrefix() { toChild.append(bytes) }
                escapeDeadline = nil
            }
            if childEnded, toOutput.count == 0 {
                if !child.waitForExit(milliseconds: 100) { child.close() }
                return child.terminationStatus ?? 255
            }
            if inputEnded, toChild.count == 0, toOutput.count == 0 { return 0 }
            let next = dimensions()
            if !childEnded, next != geometry {
                try child.resize(next)
                geometry = next
            }
            var descriptors = [
                pollfd(
                    fd: inputEnded || childEnded || toChild.count >= bufferLimit
                        ? -1 : input.fileDescriptor,
                    events: Int16(POLLIN), revents: 0),
                pollfd(
                    fd: childEnded ? -1 : child.terminal.fileDescriptor,
                    events: (toOutput.count < bufferLimit ? Int16(POLLIN) : 0)
                        | (toChild.count > 0 ? Int16(POLLOUT) : 0), revents: 0),
                pollfd(
                    fd: toOutput.count == 0 ? -1 : output.fileDescriptor,
                    events: Int16(POLLOUT), revents: 0),
            ]
            let ready = poll(
                &descriptors, nfds_t(descriptors.count), escapeDeadline == nil ? 100 : 40)
            if ready < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if ready == 0 { continue }
            if descriptors[1].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0,
                let bytes = try read(child.terminal.fileDescriptor, terminal: true)
            {
                if bytes.isEmpty {
                    childEnded = true
                } else {
                    observe(bytes)
                    toOutput.append(bytes)
                }
            }
            if !childEnded, descriptors[1].revents & Int16(POLLOUT) != 0 {
                try toChild.flush(to: child.terminal.fileDescriptor)
            }
            if descriptors[2].revents != 0 { try toOutput.flush(to: output.fileDescriptor) }
            if !childEnded, descriptors[0].revents != 0,
                let bytes = try read(input.fileDescriptor)
            {
                if bytes.isEmpty {
                    inputEnded = true
                    inputCloseDeadline = clock.now.advanced(by: .milliseconds(500))
                    for bytes in try router.finish() { toChild.append(bytes) }
                } else {
                    for bytes in try router.commands(for: bytes) { toChild.append(bytes) }
                }
                escapeDeadline =
                    router.hasPendingEscapePrefix
                    ? clock.now.advanced(by: .milliseconds(40)) : nil
            }
        }
    }

    private static func nonblocking(_ descriptor: Int32) throws -> Int32 {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return flags
    }

    private static func read(_ descriptor: Int32, terminal: Bool = false) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count >= 0 { return Data(bytes.prefix(count)) }
            if errno == EINTR { continue }
            if errno == EAGAIN { return nil }
            if terminal, errno == EIO { return Data() }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

private struct QuinjetPTYTerminalWriteQueue {
    private var bytes = Data()
    private var offset = 0

    var count: Int { bytes.count - offset }

    mutating func append(_ data: Data) {
        if offset > 0, offset >= bytes.count / 2 {
            bytes.removeFirst(offset)
            offset = 0
        }
        bytes.append(data)
    }

    mutating func flush(to descriptor: Int32) throws {
        guard count > 0 else { return }
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(
                descriptor, buffer.baseAddress!.advanced(by: offset), min(count, 64 * 1024))
        }
        if written > 0 {
            offset += written
        } else if written < 0, errno != EAGAIN, errno != EINTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

final class QuinjetPTYNativeTerminalProcess {
    let terminal: FileHandle
    private(set) var terminationStatus: Int32?
    private let pid: pid_t
    private var closed = false

    init(request: TerminalLaunchRequest, dimensions: QuinjetPTYTerminalDimensions) throws {
        let spawned = try Self.spawn(request, dimensions: dimensions)
        pid = spawned.pid
        terminal = FileHandle(fileDescriptor: spawned.master, closeOnDealloc: true)
        do { try ExtensionNativeTask.registerChild(pid) } catch { close(); throw error }
    }

    deinit { close() }

    func resize(_ dimensions: QuinjetPTYTerminalDimensions) throws {
        var size = Self.windowSize(dimensions)
        guard ioctl(terminal.fileDescriptor, TIOCSWINSZ, &size) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func waitForExit(milliseconds: Int64) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(milliseconds))
        repeat {
            if reap() { return true }
            usleep(10_000)
        } while clock.now < deadline
        return reap()
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? terminal.close()
        for signal in [SIGHUP, SIGTERM, SIGKILL] {
            if reap() { return }
            _ = kill(-pid, signal)
            _ = kill(pid, signal)
            if waitForExit(milliseconds: 200) { return }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        terminationStatus = 128 + SIGKILL
    }

    private func reap() -> Bool {
        if terminationStatus != nil { return true }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == pid {
            let signal = status & 0x7f
            terminationStatus = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        } else if result < 0, errno == ECHILD {
            terminationStatus = 255
        }
        return terminationStatus != nil
    }

    private static func windowSize(_ dimensions: QuinjetPTYTerminalDimensions) -> winsize {
        winsize(
            ws_row: dimensions.rows, ws_col: dimensions.columns,
            ws_xpixel: UInt16(clamping: UInt64(dimensions.columns) * UInt64(dimensions.cellWidth)),
            ws_ypixel: UInt16(clamping: UInt64(dimensions.rows) * UInt64(dimensions.cellHeight)))
    }

    private static func spawn(
        _ request: TerminalLaunchRequest, dimensions: QuinjetPTYTerminalDimensions
    ) throws -> (pid: pid_t, master: Int32) {
        let environment = ForegroundProcess.environment(
            assignments: request.environment, inheriting: true)
        let argv = ([request.executable] + request.arguments).map { strdup($0) }
        let env = environment.map { strdup($0.key + "=" + $0.value) }
        defer { for pointer in argv + env { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var arguments = argv + [nil]
        var variables = env + [nil]
        var master: Int32 = -1
        var size = windowSize(dimensions)
        var raw = termios()
        raw.c_cflag = tcflag_t(CS8 | CREAD)
        cfmakeraw(&raw)
        cfsetispeed(&raw, speed_t(B38400))
        cfsetospeed(&raw, speed_t(B38400))
        var mask = sigset_t()
        sigemptyset(&mask)
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        let maximumDescriptor = getdtablesize()
        let pid = request.executable.withCString { executable in
            arguments.withUnsafeMutableBufferPointer { arguments in
                variables.withUnsafeMutableBufferPointer { variables in
                    let pid = forkpty(&master, nil, &raw, &size)
                    if pid == 0 {
                        sigprocmask(SIG_SETMASK, &mask, nil)
                        sigaction(SIGHUP, &action, nil)
                        sigaction(SIGINT, &action, nil)
                        sigaction(SIGQUIT, &action, nil)
                        sigaction(SIGPIPE, &action, nil)
                        sigaction(SIGTERM, &action, nil)
                        var descriptor: Int32 = 3
                        while descriptor < maximumDescriptor {
                            Darwin.close(descriptor)
                            descriptor += 1
                        }
                        execve(executable, arguments.baseAddress!, variables.baseAddress!)
                        _exit(127)
                    }
                    return pid
                }
            }
        }
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }
}
