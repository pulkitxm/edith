@testable import EdithKit
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
