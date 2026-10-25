@testable import CodeStatsExtension
import EdithExtensionSupport
import Foundation

struct CodeStatsGitFixture {
    static let me = CodeStatsIdentity(substrings: ["octocat"], emails: ["you@example.com"])

    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "code-stats-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static var executable: URL {
        CLIToolEnvironment.executable(named: "git") ?? URL(fileURLWithPath: "/usr/bin/git")
    }

    static var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging([
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
        ]) { _, forced in forced }
    }

    var tool: CodeStatsGit {
        CodeStatsGit(executable: Self.executable, environment: Self.environment)
    }

    func blockingTool(
        on subcommand: String, networkTimeout: TimeInterval = CodeStatsGit.defaultNetworkTimeout
    ) throws -> (tool: CodeStatsGit, pidFile: URL) {
        let pidFile = root.appendingPathComponent("blocked-\(subcommand).pid")
        let script = root.appendingPathComponent("git-blocking-\(subcommand)")
        let body = """
            #!/bin/sh
            for argument in "$@"; do last="$argument"; done
            for argument in "$@"; do
                if [ "$argument" = "\(subcommand)" ]; then
                    if [ "\(subcommand)" = clone ]; then mkdir -p "$last"; fi
                    echo $$ > '\(pidFile.path)'
                    exec sleep 30
                fi
            done
            exec '\(Self.executable.path)' "$@"

            """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (
            CodeStatsGit(
                executable: script, environment: Self.environment,
                networkTimeout: networkTimeout),
            pidFile
        )
    }

    func waitForProcess(_ pidFile: URL, timeout: TimeInterval = 20) async throws -> pid_t? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    static func eventually(
        timeout: TimeInterval = 5, _ condition: () -> Bool
    ) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @discardableResult
    func git(
        _ arguments: [String], in directory: URL? = nil, author: (String, String) = ("x", "x@x"),
        date: String = "2026-06-01T12:00:00+00:00"
    ) async throws -> String {
        let environment = Self.environment.merging([
            "GIT_AUTHOR_NAME": author.0, "GIT_AUTHOR_EMAIL": author.1, "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_NAME": author.0, "GIT_COMMITTER_EMAIL": author.1,
            "GIT_COMMITTER_DATE": date,
        ]) { _, forced in forced }
        let result = try await CLICommandRunner.runLocalSeparated(
            CLICommandRequest(
                executableURL: Self.executable, arguments: arguments, environment: environment,
                currentDirectoryURL: directory ?? root, timeout: 60,
                terminatesProcessGroup: true),
            onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
        guard result.terminationStatus == 0 else {
            throw CodeStatsGitError.failed(
                status: result.terminationStatus, message: result.standardError)
        }
        return result.standardOutput
    }

    func makeRepository(_ relativePath: String) async throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: url)
        return url
    }

    func commit(
        _ files: [String: String], in repository: URL, author: (String, String),
        date: String, message: String = "change"
    ) async throws {
        for (path, contents) in files {
            let file = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        try await git(["add", "-A"], in: repository)
        try await git(["commit", "-q", "-m", message], in: repository, author: author, date: date)
    }
}
