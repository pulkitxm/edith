import Darwin
import EdithExtensionSupport
import Foundation

final class MachinePTY {
    static let maximumBufferedBytes = 262_144
    static let maximumInputBytes = 16_384
    private let descriptor: Int32
    private let pid: pid_t
    private let identity: ExtensionProcessIdentity?
    private var closed = false
    private var closing: Task<Void, Never>?
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

    init(launch: MachinePTYLaunch, columns: UInt16 = 80, rows: UInt16 = 24) throws {
        guard columns > 0, rows > 0, launch.executable.hasPrefix("/"),
            !([launch.executable, launch.currentDirectory] + launch.arguments + launch.environment)
                .contains(where: { $0.utf8.contains(0) })
        else { throw POSIXError(.EINVAL) }
        let spawned = try Self.spawn(launch, columns: columns, rows: rows)
        descriptor = spawned.master
        pid = spawned.pid
        identity = ExtensionProcessIdentity.read(spawned.pid)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        do {
            try ExtensionCommandOwnership.register(pid)
        } catch {
            close()
            throw error
        }
        if let command = launch.startupCommand { try send(Data((command + "\n").utf8)) }
    }

    deinit { close() }

    var inputCapacity: Int { Self.maximumInputBytes - pendingInput.count }

    func send(_ bytes: Data) throws {
        guard !closed, exitCode == nil, !bytes.isEmpty,
            bytes.count <= Self.maximumInputBytes - pendingInput.count
        else { throw POSIXError(.EINVAL) }
        pendingInput.append(bytes)
        try flushInput()
    }

    func resize(columns: UInt16, rows: UInt16) throws {
        guard !closed, columns > 0, rows > 0 else { throw POSIXError(.EINVAL) }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
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
        let members = identity?.isAlive == true ? (Self.sessionMembers(pid) ?? []) : []
        for member in members where member.isAlive { _ = kill(member.pid, SIGHUP) }
        if identity?.isAlive == true, getpgid(pid) == pid { _ = kill(-pid, SIGHUP) }
        if identity?.isAlive == true { _ = kill(pid, SIGHUP) }
        for member in members where member.isAlive { _ = kill(member.pid, SIGKILL) }
        if identity?.isAlive == true, getpgid(pid) == pid { _ = kill(-pid, SIGKILL) }
        if identity?.isAlive == true { _ = kill(pid, SIGKILL) }
        let identifier = pid
        let identity = identity
        closing = Task.detached {
            while identity?.isAlive == true {
                guard let remaining = Self.sessionMembers(identifier) else {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                guard !remaining.isEmpty else { break }
                for member in remaining where member.isAlive { _ = kill(member.pid, SIGKILL) }
                try? await Task.sleep(for: .milliseconds(10))
            }
            var status: Int32 = 0
            while true {
                if waitpid(identifier, &status, 0) == identifier { break }
                if errno == ECHILD, identity?.isAlive != true { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            ExtensionCommandOwnership.release(identifier)
        }
    }

    func closeAndWait() async {
        close()
        await closing?.value
    }

    func poll() throws {
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
        var information = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
        } while result < 0 && errno == EINTR
        if result == 0, information.si_pid == pid {
            exitCode =
                information.si_code == CLD_EXITED
                ? information.si_status : 128 + information.si_status
        } else if result < 0 && errno == ECHILD {
            exitCode = 255
        }
    }

    private static func sessionMembers(_ pid: pid_t) -> [ExtensionProcessIdentity]? {
        var identifiers = [pid_t](repeating: 0, count: 65_536)
        let count = identifiers.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0, count < identifiers.count else { return nil }
        var members: [ExtensionProcessIdentity] = []
        for candidate in identifiers.prefix(Int(count)) {
            guard candidate > 1, candidate != pid, getsid(candidate) == pid else { continue }
            guard let identity = ExtensionProcessIdentity.read(candidate) else { return nil }
            members.append(identity)
        }
        return members
    }

    private static func error() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func spawn(_ launch: MachinePTYLaunch, columns: UInt16, rows: UInt16) throws
        -> (pid: pid_t, master: Int32)
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
        let maximumDescriptor = getdtablesize()
        let pid = launch.executable.withCString { executable in
            launch.currentDirectory.withCString { directory in
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
        return (pid, master)
    }
}
