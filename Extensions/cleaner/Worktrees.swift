import EdithExtensionSupport
import Foundation

public struct WorktreeInfo: Codable, Equatable, Sendable {
    public var branch: String?
    public var repository: String?
    public var locked: Bool
    public var dirty: Bool?
    public var unpushed: Int?
    public var upstreamGone: Bool
    public var merged: Bool

    public init(
        branch: String?, repository: String?, locked: Bool = false, dirty: Bool? = nil,
        unpushed: Int? = nil, upstreamGone: Bool = false, merged: Bool = false
    ) {
        self.branch = branch
        self.repository = repository
        self.locked = locked
        self.dirty = dirty
        self.unpushed = unpushed
        self.upstreamGone = upstreamGone
        self.merged = merged
    }
}

public enum Worktrees {
    public static let categoryID = "worktrees"
    public static let containers: Set<String> = [".claude", ".codex", ".cursor", ".conductor"]

    public struct Link: Sendable {
        public let gitDirectory: URL
        public let commonDirectory: URL
    }

    public static func link(at directory: URL) -> Link? {
        let marker = directory.appendingPathComponent(".git")
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
            text.hasPrefix("gitdir:")
        else { return nil }
        let gitDirectory = resolve(
            text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines),
            from: directory)
        guard
            let common = try? String(
                contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8)
        else { return nil }
        return Link(
            gitDirectory: gitDirectory,
            commonDirectory: resolve(
                common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDirectory))
    }

    private static func resolve(_ path: String, from base: URL) -> URL {
        let url =
            path.hasPrefix("/")
            ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        return url.standardizedFileURL
    }

    public static func info(_ link: Link) -> WorktreeInfo {
        let head =
            (try? String(
                contentsOf: link.gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prefix = "ref: refs/heads/"
        let repository =
            link.commonDirectory.lastPathComponent == ".git"
            ? link.commonDirectory.deletingLastPathComponent() : link.commonDirectory
        return WorktreeInfo(
            branch: head.hasPrefix(prefix) ? String(head.dropFirst(prefix.count)) : nil,
            repository: repository.path,
            locked: FileManager.default.fileExists(
                atPath: link.gitDirectory.appendingPathComponent("locked").path))
    }

    public static func gitActivity(_ link: Link) -> Date? {
        ["index", "HEAD", "logs/HEAD"]
            .compactMap {
                try? link.gitDirectory.appendingPathComponent($0)
                    .resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            }
            .max()
    }

    struct Status: Equatable {
        var dirty = false
        var unpushed: Int?
        var upstreamGone = false
    }

    static func parseStatus(_ output: String) -> Status {
        var status = Status()
        var upstream = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.upstream ") {
                upstream = true
            } else if line.hasPrefix("# branch.ab ") {
                let ahead = line.split(separator: " ").dropFirst(2).first?.dropFirst()
                status.unpushed = ahead.flatMap { Int($0) }
            } else if !line.hasPrefix("#") {
                status.dirty = true
            }
        }
        status.upstreamGone = upstream && status.unpushed == nil
        return status
    }

    public static func inspect(_ items: [JunkItem], isCancelled: () -> Bool) -> [JunkItem] {
        guard let git = CLIToolEnvironment.executable(named: "git") else { return items }
        let environment = CLIToolEnvironment.sanitized().merging([
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
        ]) { _, forced in forced }
        let lock = NSLock()
        var inspected = items
        var next = 0
        DispatchQueue.concurrentPerform(iterations: min(6, items.count)) { _ in
            while true {
                let index: Int? = lock.withLock {
                    guard next < items.count, !isCancelled() else { return nil }
                    defer { next += 1 }
                    return next
                }
                guard let index else { return }
                let updated = inspect(items[index], git: git, environment: environment)
                lock.withLock { inspected[index] = updated }
            }
        }
        return inspected
    }

    private static func inspect(
        _ item: JunkItem, git: URL, environment: [String: String]
    ) -> JunkItem {
        guard var info = item.worktree else { return item }
        var copy = item
        if let output = run(
            git,
            ["status", "--porcelain=v2", "--branch", "--ignore-submodules=dirty"],
            in: item.path, environment: environment)
        {
            let status = parseStatus(output)
            info.dirty = status.dirty
            info.unpushed = status.unpushed
            info.upstreamGone = status.upstreamGone
        }
        info.merged = ["origin/HEAD", "main", "master"].contains { base in
            run(
                git, ["merge-base", "--is-ancestor", "HEAD", base], in: item.path,
                environment: environment) != nil
        }
        copy.worktree = info
        return copy
    }

    public static func prune(repositories: Set<String>) {
        guard !repositories.isEmpty, let git = CLIToolEnvironment.executable(named: "git")
        else { return }
        let environment = CLIToolEnvironment.sanitized()
        for repository in repositories.sorted() {
            _ = run(
                git, ["worktree", "prune"], in: URL(fileURLWithPath: repository),
                environment: environment)
        }
    }

    static func run(
        _ git: URL, _ arguments: [String], in directory: URL, environment: [String: String],
        timeout: TimeInterval = 20
    ) -> String? {
        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", directory.path] + arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
