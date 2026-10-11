import Darwin
import EdithExtensionSupport
import Foundation

final class TerminalPTY {
    static let maximumBufferedBytes = 262_144
    static let maximumInputBytes = 16_384
    private let descriptor: Int32
    private let pid: pid_t
    private let group: ExtensionOwnedProcessGroup
    private var closing: TerminalProcessRetirement?
    private var closed = false
    private var pendingInput = Data()
    private var output = Data()
    private(set) var offset: UInt64 = 0
    private(set) var exitCode: Int32?

    struct Output: Codable, Equatable {
        let bytes: Data
        let nextOffset: UInt64
        let exitCode: Int32?
        let canonical: Bool
        let echo: Bool
    }

    init(launch: TerminalLaunch, columns: UInt16 = 80, rows: UInt16 = 24) throws {
        guard columns > 0, rows > 0, launch.executable.hasPrefix("/"),
            !([launch.executable, launch.currentDirectory] + launch.arguments + launch.environment)
                .contains(where: { $0.utf8.contains(0) })
        else { throw POSIXError(.EINVAL) }
        let spawned = try Self.spawn(launch, columns: columns, rows: rows)
        descriptor = spawned.master
        pid = spawned.pid
        group = spawned.group
        defer { Darwin.close(spawned.permit) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        do {
            try ExtensionCommandOwnership.register(pid)
            var permit: UInt8 = 1
            guard Darwin.write(spawned.permit, &permit, 1) == 1 else { throw Self.error() }
        } catch {
            close()
            throw error
        }
        if let command = launch.startupCommand { try send(Data((command + "\n").utf8)) }
    }

    deinit { close() }

    func send(_ bytes: Data) throws {
        guard !closed, exitCode == nil, !bytes.isEmpty,
            bytes.count <= Self.maximumInputBytes - pendingInput.count
        else { throw POSIXError(.EINVAL) }
        pendingInput.append(bytes)
        try flushInput()
    }

    func resize(columns: UInt16, rows: UInt16, widthPixels: UInt16 = 0, heightPixels: UInt16 = 0)
        throws
    {
        guard !closed, columns > 0, rows > 0 else { throw POSIXError(.EINVAL) }
        var size = winsize(
            ws_row: rows, ws_col: columns, ws_xpixel: widthPixels, ws_ypixel: heightPixels)
        guard ioctl(descriptor, TIOCSWINSZ, &size) == 0 else { throw Self.error() }
    }

    func read(after cursor: UInt64, limit: Int = 32_768) throws -> Output {
        guard !closed, limit > 0, limit <= 32_768 else { throw POSIXError(.EINVAL) }
        try poll()
        let beginning = offset - UInt64(output.count)
        guard cursor >= beginning, cursor <= offset else { throw POSIXError(.EOVERFLOW) }
        let index = Int(cursor - beginning)
        let bytes = Data(output.dropFirst(index).prefix(limit))
        let next = cursor + UInt64(bytes.count)
        var mode = termios()
        guard tcgetattr(descriptor, &mode) == 0 else { throw Self.error() }
        return Output(
            bytes: bytes, nextOffset: next, exitCode: next == offset ? exitCode : nil,
            canonical: mode.c_lflag & tcflag_t(ICANON) != 0,
            echo: mode.c_lflag & tcflag_t(ECHO) != 0)
    }

    func close() {
        guard !closed else { return }
        closed = true
        Darwin.close(descriptor)
        pendingInput.removeAll()
        output.removeAll()
        reap()
        try? group.signal(SIGHUP)
        try? group.signal(SIGKILL)
        let identifier = pid
        let reaped = exitCode != nil
        let owner = Task.detached(priority: .utility) {
            guard !reaped else { return }
            var status: Int32 = 0
            while true {
                let result = waitpid(identifier, &status, 0)
                if result == identifier || (result < 0 && errno == ECHILD) { return }
                if result < 0 && errno == EINTR { continue }
                throw Self.error()
            }
        }
        let group = group
        closing = TerminalProcessRetirement(owner: owner) { join in
            try await group.retire(after: join)
        }
    }

    func closeAndWait() async throws {
        close()
        try await closing?.wait()
    }

    func poll() throws {
        guard !closed else { throw POSIXError(.EINVAL) }
        _ = try group.refreshObserved()
        reap()
        if exitCode == nil { try flushInput() } else { pendingInput.removeAll() }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<32 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
                offset += UInt64(count)
                if output.count > Self.maximumBufferedBytes {
                    output.removeFirst(output.count - Self.maximumBufferedBytes)
                }
            } else if count == 0 || (count < 0 && errno == EIO) {
                break
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                break
            } else {
                throw Self.error()
            }
        }
        reap()
    }

    private func flushInput() throws {
        while !pendingInput.isEmpty {
            let count = pendingInput.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                pendingInput.removeFirst(count)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                throw Self.error()
            }
        }
    }

    private func reap() {
        guard exitCode == nil else { return }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == pid {
            let signal = status & 0x7f
            exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        } else if result < 0 && errno == ECHILD {
            exitCode = 255
        }
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func spawn(_ launch: TerminalLaunch, columns: UInt16, rows: UInt16) throws
        -> (pid: pid_t, master: Int32, permit: Int32, group: ExtensionOwnedProcessGroup)
    {
        let argv = ([launch.executable] + launch.arguments).map { strdup($0) }
        let env = launch.environment.map { strdup($0) }
        defer { for pointer in argv + env { free(pointer) } }
        guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
            throw POSIXError(.ENOMEM)
        }
        var arguments = argv + [nil]
        var variables = env + [nil]
        var master: Int32 = -1
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var raw = termios()
        raw.c_cflag = tcflag_t(CS8 | CREAD)
        cfmakeraw(&raw)
        cfsetispeed(&raw, speed_t(B38400))
        cfsetospeed(&raw, speed_t(B38400))
        var mask = sigset_t()
        sigemptyset(&mask)
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_DFL
        var ready: [Int32] = [-1, -1]
        var permit: [Int32] = [-1, -1]
        guard pipe(&ready) == 0 else { throw error() }
        guard pipe(&permit) == 0 else {
            for descriptor in ready { Darwin.close(descriptor) }
            throw error()
        }
        var transferred = false
        defer {
            for descriptor in ready { Darwin.close(descriptor) }
            Darwin.close(permit[0])
            if !transferred { Darwin.close(permit[1]) }
        }
        guard fcntl(permit[1], F_SETNOSIGPIPE, 1) == 0 else { throw error() }
        let maximumDescriptor = getdtablesize()
        let pid = launch.executable.withCString { executable in
            launch.currentDirectory.withCString { directory in
                arguments.withUnsafeMutableBufferPointer { arguments in
                    variables.withUnsafeMutableBufferPointer { variables in
                        let pid = forkpty(&master, nil, &raw, &size)
                        if pid == 0 {
                            Darwin.close(ready[0])
                            Darwin.close(permit[1])
                            var byte: UInt8 = 1
                            guard Darwin.write(ready[1], &byte, 1) == 1 else { _exit(126) }
                            Darwin.close(ready[1])
                            var accepted: ssize_t
                            repeat {
                                accepted = Darwin.read(permit[0], &byte, 1)
                            } while accepted < 0 && errno == EINTR
                            guard accepted == 1, byte == 1 else { _exit(126) }
                            Darwin.close(permit[0])
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
                            guard chdir(directory) == 0 else { _exit(126) }
                            execve(executable, arguments.baseAddress!, variables.baseAddress!)
                            _exit(127)
                        }
                        return pid
                    }
                }
            }
        }
        guard pid > 0 else { throw error() }
        Darwin.close(ready[1])
        ready[1] = -1
        var byte: UInt8 = 0
        var received: ssize_t
        repeat { received = Darwin.read(ready[0], &byte, 1) } while received < 0 && errno == EINTR
        do {
            guard received == 1, byte == 1 else { throw error() }
            let group = try ExtensionCommandOwnership.captureGroup(pid: pid)
            transferred = true
            return (pid, master, permit[1], group)
        } catch {
            Darwin.close(permit[1])
            permit[1] = -1
            Darwin.close(master)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            throw error
        }
    }
}

final class TerminalProcessRetirement: @unchecked Sendable {
    typealias Join = @Sendable () async throws -> Void
    private let owner: Task<Void, Error>
    private let retire: @Sendable (@escaping Join) async throws -> Void
    private let lock = NSLock()
    private var draining: (id: UUID, task: Task<Void, Error>)?

    init(
        owner: Task<Void, Error>,
        retire: @escaping @Sendable (@escaping Join) async throws -> Void
    ) {
        self.owner = owner
        self.retire = retire
        draining = (
            id: UUID(),
            task: Task {
                try await retire { try await owner.value }
            }
        )
    }

    func wait() async throws {
        let pending = lock.withLock { () -> (id: UUID, task: Task<Void, Error>) in
            if let draining { return draining }
            let owner = owner, retire = retire
            let pending = (
                id: UUID(),
                task: Task {
                    try await retire { try await owner.value }
                }
            )
            draining = pending
            return pending
        }
        do {
            try await pending.task.value
        } catch {
            lock.withLock {
                if draining?.id == pending.id { draining = nil }
            }
            throw error
        }
    }
}
