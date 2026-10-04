import CryptoKit
import Foundation

public enum CodeStatsGitError: Error, Equatable, Sendable {
    case failed(status: Int32, message: String)
}

final class CodeStatsLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func update<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}

public struct CodeStatsAuthor: Codable, Equatable, Sendable {
    public var name: String
    public var email: String
    public var commits: Int

    public init(name: String, email: String, commits: Int) {
        self.name = name
        self.email = email
        self.commits = commits
    }
}

public struct CodeStatsGit: Sendable {
    public static let defaultNetworkTimeout: TimeInterval = 7_200
    public static let sshCommand =
        "ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15"
        + " -o ServerAliveCountMax=4"
    static let commandLineToolsShim = "/usr/bin/git"
    static let historyRefs = ["--branches", "--tags", "--remotes"]
    static let historyRefPrefixes = ["refs/heads", "refs/tags", "refs/remotes"]

    public let executable: URL
    public let environment: [String: String]
    public let credentialHelper: URL?
    public let networkTimeout: TimeInterval

    public init(
        executable: URL, environment: [String: String], credentialHelper: URL? = nil,
        networkTimeout: TimeInterval = CodeStatsGit.defaultNetworkTimeout
    ) {
        self.executable = executable
        self.environment = environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"]
        ) { _, forced in forced }
        self.credentialHelper = credentialHelper
        self.networkTimeout = networkTimeout
    }

    public static func resolve(credentialHelper: URL? = nil) async -> CodeStatsGit? {
        await resolve(
            candidate: CLIToolEnvironment.executable(named: "git"),
            environment: CLIToolEnvironment.sanitized(), credentialHelper: credentialHelper,
            developerDirectory: { await activeDeveloperDirectory() })
    }

    static func resolve(
        candidate: URL?, environment: [String: String], credentialHelper: URL? = nil,
        developerDirectory: @Sendable () async -> String?
    ) async -> CodeStatsGit? {
        guard let candidate else { return nil }
        if candidate.standardizedFileURL.path == commandLineToolsShim {
            guard let directory = await developerDirectory(),
                FileManager.default.isExecutableFile(atPath: directory + "/usr/bin/git")
            else { return nil }
        }
        let git = CodeStatsGit(
            executable: candidate, environment: environment, credentialHelper: credentialHelper)
        guard (try? await git.run(["--version"], timeout: 30)) != nil else { return nil }
        return git
    }

    static func activeDeveloperDirectory() async -> String? {
        if let configured = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
            !configured.isEmpty
        {
            return configured
        }
        let result = try? await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"],
                environment: CLIToolEnvironment.sanitized(), timeout: 30),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        guard let result, result.terminationStatus == 0 else { return nil }
        let directory = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return directory.isEmpty ? nil : directory
    }

    private var baseArguments: [String] {
        [
            "-c", "core.quotePath=false", "-c", "log.showSignature=false", "-c", "color.ui=false",
        ]
    }

    func networkArguments(in directory: String?) async -> [String] {
        var arguments = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=120"]
        if environment["GIT_SSH_COMMAND"] == nil, environment["GIT_SSH"] == nil,
            (try? await run(["config", "--get", "core.sshCommand"], in: directory, timeout: 30))
                == nil
        {
            arguments += ["-c", "core.sshCommand=" + Self.sshCommand]
        }
        if let credentialHelper {
            let quoted = "'" + credentialHelper.path.replacingOccurrences(of: "'", with: "'\\''")
            arguments += [
                "-c", "credential.https://github.com.helper=",
                "-c", "credential.https://github.com.helper=!" + quoted + "' auth git-credential",
            ]
        }
        return arguments
    }

    @discardableResult
    private func run(
        _ arguments: [String], in directory: String? = nil, network: Bool = false,
        timeout: TimeInterval? = nil, onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLICommandResult {
        let prefix = network ? await networkArguments(in: directory) : []
        let request = CLICommandRequest(
            executableURL: executable,
            arguments: baseArguments + prefix + arguments,
            environment: environment,
            currentDirectoryURL: directory.map { URL(fileURLWithPath: $0) },
            timeout: network ? networkTimeout : timeout,
            maximumOutputBytes: 1_048_576, terminatesProcessGroup: true)
        let result = try await CLICommandRunner.runLocalSeparated(
            request, retainsStandardOutput: onLine == nil,
            onStandardOutputLine: onLine ?? { _ in }, onStandardErrorLine: { _ in })
        guard result.terminationStatus == 0 else {
            throw CodeStatsGitError.failed(
                status: result.terminationStatus,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    public func refsFingerprint(_ repository: CodeStatsRepository) async throws -> String {
        let hasher = CodeStatsLocked(SHA256())
        try await run(
            ["for-each-ref", "--format=%(objectname) %(refname)"] + Self.historyRefPrefixes,
            in: repository.path,
            onLine: { line in hasher.update { $0.update(data: Data((line + "\n").utf8)) } })
        return hasher.update { $0.finalize() }.map { String(format: "%02x", $0) }.joined()
    }

    public func commits(
        in repository: CodeStatsRepository, identity: CodeStatsIdentity
    ) async throws -> [CodeStatsCommit] {
        guard !identity.isEmpty else { return [] }
        let parser = CodeStatsLocked(
            CodeStatsLogParser(repository: repository.fullName, isMine: identity.matcher()))
        let arguments =
            ["log"] + Self.historyRefs
            + ["--no-merges", "--regexp-ignore-case", "--extended-regexp"]
            + identity.authorPatterns.map { "--author=" + $0 }
            + [
                "--pretty=format:" + CodeStatsLogParser.prettyFormat, "-p", "-U0", "-M", "-C",
                "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/",
                "--dst-prefix=b/", "--", ".",
            ] + CodeStatsLanguage.excludedPathspecs
        try await run(
            arguments, in: repository.path,
            onLine: { line in parser.update { $0.push(line) } })
        return parser.update { $0.finish() }
    }

    public func authors(in repository: CodeStatsRepository) async throws -> [CodeStatsAuthor] {
        let counts = CodeStatsLocked([String: Int]())
        try await run(
            ["log"] + Self.historyRefs + ["--no-merges", "--pretty=format:%an%x09%ae"],
            in: repository.path,
            onLine: { line in counts.update { $0[line, default: 0] += 1 } })
        return counts.update { $0 }.map { key, count in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return CodeStatsAuthor(
                name: parts.first ?? "", email: parts.count > 1 ? parts[1] : "", commits: count)
        }
    }

    public func cloneMirror(from url: String, to destination: URL) async throws {
        let owner = destination.deletingLastPathComponent()
        let staging = CodeStatsRepositoryDiscovery.stagingURL(for: destination)
        try Self.ensureDirectory(owner)
        do {
            try await run(["clone", "--bare", "--quiet", url, staging.path], in: owner.path, network: true)
            try await run(
                ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], in: staging.path)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch {
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: staging)
            }
            throw error
        }
    }

    public func fetch(_ repository: CodeStatsRepository) async throws {
        try await run(["fetch", "--all", "--prune", "--quiet"], in: repository.path, network: true)
    }

    private static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { throw error }
        }
    }
}
