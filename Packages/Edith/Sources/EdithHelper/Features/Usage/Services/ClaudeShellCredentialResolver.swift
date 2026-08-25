import Darwin
import EdithKit
import Foundation

enum ClaudeShellProcessResult: Equatable, Sendable {
    case output(Data)
    case cancelled
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

enum ClaudeShellProcessRunner {
    static func run(
        _ invocation: ClaudeShellInvocation, timeout: TimeInterval, maximumOutputBytes: Int
    ) async -> ClaudeShellProcessResult {
        let request = CLICommandRequest(
            executableURL: invocation.executable,
            arguments: invocation.arguments,
            environment: invocation.environment,
            currentDirectoryURL: invocation.currentDirectory,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            discardsStandardError: true,
            terminatesProcessGroup: true)
        do {
            let result = try await CLICommandRunner.run(request) { _ in }
            guard result.terminationStatus == 0 else { return .failed }
            return .output(result.outputData)
        } catch is CancellationError {
            return .cancelled
        } catch CLICommandRunnerError.timedOut {
            return .timedOut
        } catch CLICommandRunnerError.outputLimitExceeded {
            return .oversized
        } catch {
            return .failed
        }
    }
}

enum ClaudeShellCredentialResolution {
    case credential(ClaudeOAuthCredential)
    case cancelled
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
        ) async -> ClaudeShellProcessResult

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
            await ClaudeShellProcessRunner.run(
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
        let result = await runner(invocation, timeout, maximumOutputBytes)
        switch result {
        case .output(let data):
            return parse(data)
        case .cancelled:
            return .cancelled
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

enum ClaudeCredentialLookupFailure: Equatable {
    case missing
    case rejected
    case malformed
    case timedOut
    case oversized
    case failed
}

enum ClaudeCredentialLookup {
    case credential(ClaudeOAuthCredential)
    case failure(ClaudeCredentialLookupFailure)
    case cancelled
}

@MainActor
final class ClaudeCredentialSession {
    typealias PersistedReader = () async -> ClaudeOAuthCredential?
    typealias ShellReader = () async -> ClaudeShellCredentialResolution

    private var cached: ClaudeOAuthCredential?
    private var rejectedAccessToken: String?
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

    func current() async -> ClaudeCredentialLookup {
        if let cached { return .credential(cached) }
        return await load()
    }

    func reload(rejectingAccessToken: String? = nil) async -> ClaudeCredentialLookup {
        cached = nil
        if let rejectingAccessToken { rejectedAccessToken = rejectingAccessToken }
        return await load()
    }

    func store(_ credential: ClaudeOAuthCredential) {
        rejectedAccessToken = nil
        cached = credential
    }

    private func load() async -> ClaudeCredentialLookup {
        if let credential = await persistedReader(), credential.accessToken != rejectedAccessToken {
            return accept(credential)
        }
        switch await shellReader() {
        case .credential(let credential):
            guard credential.accessToken != rejectedAccessToken else {
                return .failure(.rejected)
            }
            return accept(credential)
        case .cancelled:
            return .cancelled
        case .missing:
            return rejectedAccessToken == nil ? .failure(.missing) : .failure(.rejected)
        case .malformed:
            return .failure(.malformed)
        case .timedOut:
            return .failure(.timedOut)
        case .oversized:
            return .failure(.oversized)
        case .failed:
            return .failure(.failed)
        }
    }

    private func accept(_ credential: ClaudeOAuthCredential) -> ClaudeCredentialLookup {
        rejectedAccessToken = nil
        cached = credential
        return .credential(credential)
    }
}
