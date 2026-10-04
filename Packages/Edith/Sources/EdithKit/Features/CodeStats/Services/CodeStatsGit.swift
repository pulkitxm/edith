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
    public let executable: URL
    public let environment: [String: String]
    public let credentialHelper: URL?

    public init(executable: URL, environment: [String: String], credentialHelper: URL? = nil) {
        self.executable = executable
        self.environment = environment.merging(
            ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"]
        ) { _, forced in forced }
        self.credentialHelper = credentialHelper
    }

    public static func resolve(credentialHelper: URL? = nil) -> CodeStatsGit? {
        CLIToolEnvironment.executable(named: "git").map {
            CodeStatsGit(
                executable: $0, environment: CLIToolEnvironment.sanitized(),
                credentialHelper: credentialHelper)
        }
    }

    private var baseArguments: [String] {
        [
            "-c", "core.quotePath=false", "-c", "log.showSignature=false", "-c", "color.ui=false",
        ]
    }

    private var networkArguments: [String] {
        var arguments = ["-c", "http.lowSpeedLimit=1000", "-c", "http.lowSpeedTime=120"]
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
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CLICommandResult {
        let request = CLICommandRequest(
            executableURL: executable,
            arguments: baseArguments + (network ? networkArguments : []) + arguments,
            environment: environment,
            currentDirectoryURL: directory.map { URL(fileURLWithPath: $0) },
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
            ["for-each-ref", "--format=%(objectname) %(refname)"], in: repository.path,
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
            ["log", "--all", "--no-merges", "--regexp-ignore-case", "--extended-regexp"]
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
            ["log", "--all", "--no-merges", "--pretty=format:%an%x09%ae"], in: repository.path,
            onLine: { line in counts.update { $0[line, default: 0] += 1 } })
        return counts.update { $0 }.map { key, count in
            let parts = key.split(separator: "\t", maxSplits: 1).map(String.init)
            return CodeStatsAuthor(
                name: parts.first ?? "", email: parts.count > 1 ? parts[1] : "", commits: count)
        }
    }

    public func cloneMirror(from url: String, to destination: URL) async throws {
        let fileManager = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(
            "." + destination.lastPathComponent + ".partial-" + UUID().uuidString)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try await run(["clone", "--bare", "--quiet", url, staging.path], network: true)
            try await run(
                ["config", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"], in: staging.path)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func fetch(_ repository: CodeStatsRepository) async throws {
        try await run(["fetch", "--all", "--prune", "--quiet"], in: repository.path, network: true)
    }
}
