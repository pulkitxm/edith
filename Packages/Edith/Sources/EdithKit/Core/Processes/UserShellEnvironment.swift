import Darwin
import Foundation

public final class UserShellEnvironment: @unchecked Sendable {
    public typealias Capture =
        @Sendable (_ shell: URL, _ home: URL, _ base: [String: String]) async -> [String: String]?

    public static let shared = UserShellEnvironment()

    static let maximumAge: TimeInterval = 3_600
    static let checkInterval: TimeInterval = 5
    static let failureRetryInterval: TimeInterval = 300
    static let captureTimeout: TimeInterval = 10
    static let maximumOutputBytes = 1 << 20

    static let sessionVariables: Set<String> = [
        "_", "PATH", "PWD", "OLDPWD", "SHLVL", "TMPDIR", "HOME", "USER", "LOGNAME", "SHELL",
        "TERM", "COLORTERM", "COLUMNS", "LINES", "TMUX", "TMUX_PANE", "STY", "WINDOWID",
        "PS1", "PS2", "PS3", "PS4", "PROMPT", "RPROMPT", "NO_COLOR", "LC_TERMINAL",
        "LC_TERMINAL_VERSION", "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier",
        "__CF_USER_TEXT_ENCODING", "SECURITYSESSIONID", "LaunchInstanceID",
    ]
    static let sessionPrefixes = [
        "EDITH_", "TERM_", "ITERM_", "GHOSTTY_", "VSCODE_", "P9K_", "_P9K_", "POWERLEVEL9K_",
    ]

    private struct Snapshot {
        let variables: [String: String]
        let fingerprint: [String]
        let capturedAt: Date
    }

    private let lock = NSLock()
    private var enabled = false
    private var snapshot: Snapshot?
    private var capturing = false
    private var lastCheck = Date.distantPast
    private var failure: (date: Date, fingerprint: [String])?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let shell: URL
    private let home: URL
    private let baseEnvironment: [String: String]
    private let capture: Capture
    private let now: @Sendable () -> Date

    public init(
        shell: URL = ClaudeShellCredentialResolver.loginShell(),
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init,
        capture: @escaping Capture = UserShellEnvironment.captureLoginEnvironment
    ) {
        self.shell = shell
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.now = now
        self.capture = capture
    }

    public func enable() {
        let started = lock.withLock { () -> Bool in
            guard !enabled else { return false }
            enabled = true
            return true
        }
        if started { startCapture() }
    }

    public func current() -> [String: String]? {
        let moment = now()
        let state = lock.withLock { () -> (Snapshot?, Bool)? in
            guard enabled else { return nil }
            let due = moment.timeIntervalSince(lastCheck) >= Self.checkInterval
            if due { lastCheck = moment }
            return (snapshot, due)
        }
        guard let (snapshot, due) = state else { return nil }
        if due, isStale(snapshot, at: moment) { startCapture() }
        return snapshot?.variables
    }

    public func refresh() async {
        await withCheckedContinuation { continuation in
            lock.withLock { waiters.append(continuation) }
            startCapture()
        }
    }

    public static func imports(_ key: String) -> Bool {
        !key.isEmpty && !sessionVariables.contains(key)
            && !sessionPrefixes.contains { key.hasPrefix($0) }
    }

    private func isStale(_ snapshot: Snapshot?, at moment: Date) -> Bool {
        let fingerprint = Self.fingerprint(
            Self.watchedPaths(home: home, zdotdir: snapshot?.variables["ZDOTDIR"]))
        if let failure = lock.withLock({ self.failure }), failure.fingerprint == fingerprint,
            moment.timeIntervalSince(failure.date) < Self.failureRetryInterval
        {
            return false
        }
        guard let snapshot else { return true }
        return snapshot.fingerprint != fingerprint
            || moment.timeIntervalSince(snapshot.capturedAt) >= Self.maximumAge
    }

    private func startCapture() {
        let start = lock.withLock { () -> Bool in
            guard !capturing else { return false }
            capturing = true
            return true
        }
        guard start else { return }
        let shell = shell
        let home = home
        let base = baseEnvironment
        let capture = capture
        let zdotdir = lock.withLock { snapshot?.variables["ZDOTDIR"] }
        Task(priority: .utility) { [weak self] in
            let before = Self.fingerprint(Self.watchedPaths(home: home, zdotdir: zdotdir))
            let variables = await capture(shell, home, base)
            let fingerprint =
                variables?["ZDOTDIR"] == zdotdir
                ? before
                : Self.fingerprint(
                    Self.watchedPaths(home: home, zdotdir: variables?["ZDOTDIR"]))
            self?.finishCapture(variables, fingerprint: fingerprint)
        }
    }

    private func finishCapture(_ variables: [String: String]?, fingerprint: [String]) {
        let moment = now()
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            capturing = false
            lastCheck = moment
            if let variables {
                snapshot = Snapshot(
                    variables: variables, fingerprint: fingerprint, capturedAt: moment)
                failure = nil
            } else {
                failure = (moment, fingerprint)
            }
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in waiting { waiter.resume() }
    }

    static func watchedPaths(home: URL, zdotdir: String?) -> [String] {
        let zsh = zdotdir.map { URL(fileURLWithPath: $0) } ?? home
        return [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map {
            zsh.appendingPathComponent($0).path
        }
            + [
                ".zshenv", ".bash_profile", ".bash_login", ".profile", ".bashrc",
                ".config/fish/config.fish", ".config/fish/conf.d",
                ".config/fish/fish_variables",
            ].map { home.appendingPathComponent($0).path }
            + [
                "/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/profile", "/etc/bashrc",
                "/etc/paths", "/etc/paths.d",
            ]
    }

    static func fingerprint(_ paths: [String]) -> [String] {
        paths.map { path in
            var info = stat()
            guard stat(path, &info) == 0 else { return "-" }
            return
                "\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_size):\(info.st_ino)"
        }
    }

    public static func captureLoginEnvironment(
        shell: URL, home: URL, base: [String: String]
    ) async -> [String: String]? {
        let marker = UUID().uuidString
        let begin = "EDITH_ENVIRONMENT_BEGIN_\(marker)"
        let end = "EDITH_ENVIRONMENT_END_\(marker)"
        var environment = base
        environment["HOME"] = home.path
        environment["SHELL"] = shell.path
        environment["TERM"] = "dumb"
        environment["EDITH_RESOLVING_ENVIRONMENT"] = "1"
        let request = CLICommandRequest(
            executableURL: shell,
            arguments: [
                "-l", "-i", "-c", "printf '%s' '\(begin)'; /usr/bin/env -0; printf '%s' '\(end)'",
            ],
            environment: environment, currentDirectoryURL: home, timeout: captureTimeout,
            maximumOutputBytes: maximumOutputBytes, discardsStandardError: true,
            terminatesProcessGroup: true)
        guard let result = try? await CLICommandRunner.run(request, onLine: { _ in }) else {
            return nil
        }
        return parse(result.outputData, begin: begin, end: end)
    }

    static func parse(_ output: Data, begin: String, end: String) -> [String: String]? {
        guard let start = output.range(of: Data(begin.utf8)),
            let finish = output.range(
                of: Data(end.utf8), in: start.upperBound..<output.endIndex)
        else { return nil }
        var variables: [String: String] = [:]
        for entry in output[start.upperBound..<finish.lowerBound].split(separator: 0) {
            guard let text = String(data: Data(entry), encoding: .utf8),
                let separator = text.firstIndex(of: "="), separator != text.startIndex
            else { continue }
            variables[String(text[..<separator])] = String(text[text.index(after: separator)...])
        }
        return variables["PATH"] == nil ? nil : variables
    }
}
