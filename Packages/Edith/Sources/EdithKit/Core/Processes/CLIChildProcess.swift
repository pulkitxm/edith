import Darwin
import Foundation

final class CLIChildProcess: @unchecked Sendable {
    let processIdentifier: pid_t
    let ownsProcessGroup: Bool
    private let lock = NSLock()
    private var status: Int32?
    private var exitSource: DispatchSourceProcess?
    private let onExit: @Sendable () -> Void

    var isRunning: Bool { lock.withLock { status == nil } }
    var terminationStatus: Int32 { lock.withLock { status ?? 255 } }

    init(
        request: CLICommandRequest, input: Int32, output: Int32, error: Int32,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        ownsProcessGroup = request.terminatesProcessGroup
        self.onExit = onExit
        processIdentifier = try Self.spawn(request, input: input, output: output, error: error)
        let source = DispatchSource.makeProcessSource(
            identifier: processIdentifier,
            eventMask: .exit, queue: .global(qos: .utility))
        exitSource = source
        source.setEventHandler { [self] in reap() }
        source.activate()
    }

    deinit { exitSource?.cancel() }

    func signal(_ signal: Int32) {
        if ownsProcessGroup {
            _ = kill(-processIdentifier, signal)
        } else if isRunning {
            _ = kill(processIdentifier, signal)
        }
    }

    var groupIsAlive: Bool {
        guard ownsProcessGroup else { return isRunning }
        if kill(-processIdentifier, 0) == 0 { return true }
        return errno == EPERM
    }

    private func reap() {
        var raw: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(processIdentifier, &raw, 0) } while result == -1 && errno == EINTR
        let exitStatus: Int32
        if result == processIdentifier {
            let signal = raw & 0x7f
            exitStatus = signal == 0 ? (raw >> 8) & 0xff : signal
        } else {
            exitStatus = 255
        }
        let first = lock.withLock {
            guard status == nil else { return false }
            status = exitStatus
            return true
        }
        let source = exitSource
        exitSource = nil
        source?.cancel()
        if first { onExit() }
    }

    private static func spawn(
        _ request: CLICommandRequest, input: Int32,
        output: Int32, error: Int32
    ) throws -> pid_t {
        let executable = request.executableURL.path
        let arguments = [executable] + request.arguments
        let environment = request.environment
        guard request.executableURL.isFileURL,
            request.currentDirectoryURL.map(\.isFileURL) ?? true,
            arguments.allSatisfy({ !$0.utf8.contains(0) }),
            !executable.isEmpty,
            environment.allSatisfy({
                !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
            }),
            request.currentDirectoryURL.map({ !$0.path.utf8.contains(0) }) ?? true
        else { throw CLICommandRunnerError.launchFailed }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, destination) in [
            (input, STDIN_FILENO), (output, STDOUT_FILENO), (error, STDERR_FILENO),
        ] {
            if source < 0 {
                try check(
                    posix_spawn_file_actions_addopen(&actions, destination, "/dev/null", O_RDWR, 0))
            } else {
                try check(posix_spawn_file_actions_adddup2(&actions, source, destination))
            }
        }
        if let directory = request.currentDirectoryURL {
            try check(
                directory.path.withCString { path in
                    if #available(macOS 26, *) {
                        return posix_spawn_file_actions_addchdir(&actions, path)
                    } else {
                        return posix_spawn_file_actions_addchdir_np(&actions, path)
                    }
                })
        }
        var flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        if request.terminatesProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            try check(posix_spawnattr_setpgroup(&attributes, 0))
        }
        try check(posix_spawnattr_setflags(&attributes, flags))
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGCHLD] {
            sigaddset(&defaults, signal)
        }
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        let argv = arguments.map { strdup($0) }
        let env = environment.map { strdup($0.key + "=" + $0.value) }
        defer { for item in argv + env { if let item { free(item) } } }
        guard argv.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else {
            throw CLICommandRunnerError.launchFailed
        }
        var argvPointers = argv + [nil]
        var envPointers = env + [nil]
        var pid: pid_t = 0
        let code = executable.withCString { path in
            argvPointers.withUnsafeMutableBufferPointer { arguments in
                envPointers.withUnsafeMutableBufferPointer { environment in
                    posix_spawn(
                        &pid, path, &actions, &attributes, arguments.baseAddress,
                        environment.baseAddress)
                }
            }
        }
        try check(code)
        return pid
    }

    private static func check(_ code: Int32) throws {
        guard code == 0 else { throw CLICommandRunnerError.launchFailed }
    }
}
