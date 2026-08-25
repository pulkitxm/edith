import Darwin
import Foundation

enum ClaudeShellProcessResult: Equatable, Sendable {
    case output(Data)
    case timedOut
    case oversized
    case failed
}

struct ClaudeShellInvocation: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
}

private final class ClaudeShellOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var rejected = false

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !rejected else { return }
        guard data.count + chunk.count <= maximumBytes else {
            data.removeAll(keepingCapacity: false)
            rejected = true
            return
        }
        data.append(chunk)
    }

    func result() -> ClaudeShellProcessResult {
        lock.lock()
        defer { lock.unlock() }
        return rejected ? .oversized : .output(data)
    }
}

enum ClaudeShellProcessRunner {
    private static let terminationGrace: TimeInterval = 0.25
    private static let processGroupScript = """
        set -m
        "$@" &
        child=$!
        set +m
        terminate_group() {
            if kill -TERM -"$child" 2>/dev/null; then
                sleep 0.1
                kill -KILL -"$child" 2>/dev/null || :
            fi
        }
        trap 'terminate_group; exit 124' TERM INT
        wait "$child"
        status=$?
        terminate_group
        trap - TERM INT
        exit "$status"
        """

    static func run(
        _ invocation: ClaudeShellInvocation, timeout: TimeInterval, maximumOutputBytes: Int
    ) -> ClaudeShellProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments =
            [
                "-c", processGroupScript, "credential-resolver", invocation.executable.path,
            ] + invocation.arguments
        process.environment = invocation.environment
        process.currentDirectoryURL = invocation.currentDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        let buffer = ClaudeShellOutputBuffer(maximumBytes: maximumOutputBytes)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = output.fileHandleForReading.readData(ofLength: 4_096)
                guard !chunk.isEmpty else { break }
                buffer.append(chunk)
            }
            readerFinished.signal()
        }

        let processFinished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in processFinished.signal() }
        do {
            try process.run()
            try? output.fileHandleForWriting.close()
        } catch {
            try? output.fileHandleForWriting.close()
            _ = readerFinished.wait(timeout: .now() + terminationGrace)
            return .failed
        }

        let deadline = DispatchTime.now() + max(0, timeout)
        guard processFinished.wait(timeout: deadline) == .success else {
            process.terminate()
            if processFinished.wait(timeout: .now() + terminationGrace) == .timedOut,
                process.isRunning
            {
                kill(process.processIdentifier, SIGKILL)
                _ = processFinished.wait(timeout: .now() + terminationGrace)
            }
            _ = readerFinished.wait(timeout: .now() + terminationGrace)
            return .timedOut
        }

        guard readerFinished.wait(timeout: .now() + terminationGrace) == .success else {
            return .failed
        }
        guard process.terminationStatus == 0 else { return .failed }
        return buffer.result()
    }
}

enum ClaudeShellCredentialResolution {
    case credential(ClaudeOAuthCredential)
    case missing
    case malformed
    case timedOut
    case oversized
    case failed
}

struct ClaudeShellCredentialResolver: Sendable {
    typealias Runner =
        @Sendable (
            ClaudeShellInvocation, TimeInterval, Int
        ) -> ClaudeShellProcessResult

    let shell: URL
    let home: URL
    let username: String
    let timeout: TimeInterval
    let maximumOutputBytes: Int
    let marker: String
    let runner: Runner

    init(
        shell: URL = Self.loginShell(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        username: String = NSUserName(),
        timeout: TimeInterval = 3,
        maximumOutputBytes: Int = 16_384,
        marker: String = UUID().uuidString,
        runner: @escaping Runner = { invocation, timeout, maximumOutputBytes in
            ClaudeShellProcessRunner.run(
                invocation, timeout: timeout, maximumOutputBytes: maximumOutputBytes)
        }
    ) {
        self.shell = shell
        self.home = home
        self.username = username
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.marker = marker
        self.runner = runner
    }

    func resolve() async -> ClaudeShellCredentialResolution {
        let invocation = ClaudeShellInvocation(
            executable: shell,
            arguments: ["-l", "-i", "-c", command],
            environment: minimalEnvironment,
            currentDirectory: home)
        let runner = runner
        let timeout = timeout
        let maximumOutputBytes = maximumOutputBytes
        let result = await Task.detached(priority: .utility) {
            runner(invocation, timeout, maximumOutputBytes)
        }.value
        switch result {
        case .output(let data):
            return parse(data)
        case .timedOut:
            return .timedOut
        case .oversized:
            return .oversized
        case .failed:
            return .failed
        }
    }

    private var minimalEnvironment: [String: String] {
        [
            "HOME": home.path,
            "LANG": "en_US.UTF-8",
            "LOGNAME": username,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": shell.path,
            "USER": username,
        ]
    }

    private var command: String {
        let body =
            "printf \"\\036\(startMarker)\\037%s\\036\(endMarker)\\037\" \"${CLAUDE_CODE_OAUTH_TOKEN-}\""
        return "exec /bin/sh -c '\(body)'"
    }

    private var startMarker: String { "EDITH_CLAUDE_TOKEN_\(marker)_BEGIN" }
    private var endMarker: String { "EDITH_CLAUDE_TOKEN_\(marker)_END" }

    private func parse(_ data: Data) -> ClaudeShellCredentialResolution {
        guard let output = String(data: data, encoding: .utf8) else { return .malformed }
        let start = "\u{1E}\(startMarker)\u{1F}"
        let end = "\u{1E}\(endMarker)\u{1F}"
        let startParts = output.components(separatedBy: start)
        guard startParts.count == 2 else { return .malformed }
        let endParts = startParts[1].components(separatedBy: end)
        guard endParts.count == 2 else { return .malformed }
        let token = endParts[0]
        guard !token.isEmpty else { return .missing }
        guard let credential = ClaudeOAuthCredential.transient(accessToken: token) else {
            return .malformed
        }
        return .credential(credential)
    }

    private static func loginShell() -> URL {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else {
            return URL(fileURLWithPath: "/bin/zsh")
        }
        let path = String(cString: shell)
        guard path.hasPrefix("/") else { return URL(fileURLWithPath: "/bin/zsh") }
        return URL(fileURLWithPath: path)
    }
}

@MainActor
final class ClaudeCredentialSession {
    typealias PersistedReader = () -> ClaudeOAuthCredential?
    typealias ShellReader = () async -> ClaudeShellCredentialResolution

    private var cached: ClaudeOAuthCredential?
    private let persistedReader: PersistedReader
    private let shellReader: ShellReader

    init(
        persistedReader: @escaping PersistedReader = ClaudeCredentialStore.read,
        shellReader: @escaping ShellReader = {
            await ClaudeShellCredentialResolver().resolve()
        }
    ) {
        self.persistedReader = persistedReader
        self.shellReader = shellReader
    }

    func current() async -> ClaudeOAuthCredential? {
        if let cached { return cached }
        return await load()
    }

    func reload() async -> ClaudeOAuthCredential? {
        cached = nil
        return await load()
    }

    func store(_ credential: ClaudeOAuthCredential) {
        cached = credential
    }

    private func load() async -> ClaudeOAuthCredential? {
        if let credential = persistedReader() {
            cached = credential
            return credential
        }
        guard case .credential(let credential) = await shellReader() else { return nil }
        cached = credential
        return credential
    }
}
