import Foundation
import Testing

@testable import CleanerExtension

@Suite(.serialized) struct WorktreeTests {
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_AUTHOR_NAME"] = "Fixture"
        environment["GIT_AUTHOR_EMAIL"] = "fixture@example.com"
        environment["GIT_COMMITTER_NAME"] = "Fixture"
        environment["GIT_COMMITTER_EMAIL"] = "fixture@example.com"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    private func repository() throws -> (root: URL, repo: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-worktrees-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try git(["init", "-q", "-b", "main"], in: repo)
        try Data("{}".utf8).write(to: repo.appendingPathComponent("package.json"))
        _ = try git(["add", "."], in: repo)
        _ = try git(["commit", "-q", "-m", "init"], in: repo)
        return (root, repo)
    }

    @Test func linkedWorktreesAreFoundWithTheirBranchAndArtifacts() throws {
        let (root, repo) = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let feature = root.appendingPathComponent("app-worktrees/feature")
        _ = try git(["worktree", "add", "-q", "-b", "feature", feature.path], in: repo)
        let modules = feature.appendingPathComponent("node_modules/dep")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64_000).write(to: modules.appendingPathComponent("a.js"))
        try Data("draft".utf8).write(to: feature.appendingPathComponent("notes.md"))

        let categories = JunkScanner.scanProjectJunk(roots: [root]) { _ in }
        let worktrees = try #require(categories.first { $0.id == Worktrees.categoryID })
        let item = try #require(worktrees.items.first)
        #expect(worktrees.items.count == 1)
        #expect(item.path.lastPathComponent == "feature")
        #expect(item.worktree?.branch == "feature")
        #expect(item.worktree?.repository == repo.path)
        #expect(item.worktree?.dirty == true)
        #expect(item.worktree?.merged == true)
        #expect(item.sizeBytes >= 64_000)
        #expect(item.lastModified.map { Date().timeIntervalSince($0) < 600 } == true)

        let modulesItem = try #require(categories.first { $0.id == "nodeModules" }?.items.first)
        #expect(JunkScanner.outermost([modulesItem, item]).map(\.id) == [item.id])
        #expect(JunkScanner.uniqueBytes([modulesItem, item]) == item.sizeBytes)
    }

    @Test func claudeWorktreesInsideHiddenFoldersAreFound() throws {
        let (root, repo) = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = repo.appendingPathComponent(".claude/worktrees/agent-1")
        _ = try git(["worktree", "add", "-q", "-b", "agent-1", agent.path], in: repo)

        let categories = JunkScanner.scanProjectJunk(roots: [root]) { _ in }
        let worktrees = categories.first { $0.id == Worktrees.categoryID }
        #expect(worktrees?.items.map(\.worktree?.branch) == ["agent-1"])
        #expect(worktrees?.items.first?.worktree?.dirty == false)
    }

    @Test func pruningAfterRemovalKeepsTheBranch() throws {
        let (root, repo) = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let feature = root.appendingPathComponent("feature")
        _ = try git(["worktree", "add", "-q", "-b", "keep-me", feature.path], in: repo)
        try FileManager.default.removeItem(at: feature)

        Worktrees.prune(repositories: [repo.path])

        #expect(!(try git(["worktree", "list"], in: repo)).contains(feature.path))
        #expect(try git(["branch", "--list", "keep-me"], in: repo).contains("keep-me"))
    }

    @Test func statusParsingReadsDirtAheadAndGoneUpstreams() {
        let clean = Worktrees.parseStatus(
            "# branch.oid abc\n# branch.head x\n# branch.upstream origin/x\n# branch.ab +2 -0\n")
        #expect(clean == .init(dirty: false, unpushed: 2, upstreamGone: false))
        let gone = Worktrees.parseStatus(
            "# branch.head x\n# branch.upstream origin/x\n1 .M N... 100644 100644 100644 a b f\n")
        #expect(gone == .init(dirty: true, unpushed: nil, upstreamGone: true))
        #expect(Worktrees.parseStatus("# branch.head x\n? new.txt\n").upstreamGone == false)
    }

    @Test func filtersHideRecentAndDirtyItems() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        func item(_ id: String, age: TimeInterval?, dirty: Bool? = nil) -> JunkItem {
            JunkItem(
                id: id, name: id, path: URL(fileURLWithPath: "/tmp/\(id)"), sizeBytes: 1,
                selected: false, lastModified: age.map { now.addingTimeInterval(-$0) },
                worktree: dirty.map { WorktreeInfo(branch: id, repository: "/r", dirty: $0) })
        }
        let category = JunkCategory(
            id: "worktrees", name: "", detail: "",
            items: [
                item("fresh", age: 60), item("stale", age: 90_000),
                item("staleDirty", age: 90_000, dirty: true), item("cache", age: nil),
            ])
        let filters = CleanerFilters(minimumAge: CleanerAge.day.seconds, protectDirty: true)
        #expect(filters.apply([category], now: now).first?.items.map(\.id) == ["stale", "cache"])
        let oldest = CleanerFilters(protectDirty: false, sort: .oldest)
        #expect(
            oldest.apply([category], now: now).first?.items.map(\.id)
                == ["stale", "staleDirty", "fresh", "cache"])
    }

    @Test func durationsParseCommonUnits() {
        #expect(CleanerAge.parse("90m") == 5_400)
        #expect(CleanerAge.parse("2d") == 172_800)
        #expect(CleanerAge.parse("1mo") == 2_592_000)
        #expect(CleanerAge.parse("soon") == nil)
    }
}
