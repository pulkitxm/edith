import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct HerdrAgentViewTests {
    @Test func defaultsToTheAgentSession() {
        let defaults = Self.defaults()
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(HerdrAgentViews.stored(defaults).isEmpty)
    }

    @Test func remembersDiffPerAgent() {
        let defaults = Self.defaults()
        HerdrAgentViews.set(.diff, for: "local|default|%1", defaults)
        HerdrAgentViews.set(.diff, for: "tuf|default|wN:p4", defaults)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .diff)
        #expect(HerdrAgentViews.view(for: "tuf|default|wN:p4", defaults) == .diff)
        #expect(HerdrAgentViews.view(for: "other|default|%9", defaults) == .agent)
    }

    @Test func returningToTheAgentClearsTheEntry() {
        let defaults = Self.defaults()
        HerdrAgentViews.set(.diff, for: "local|default|%1", defaults)
        HerdrAgentViews.set(.agent, for: "local|default|%1", defaults)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(defaults.dictionary(forKey: HerdrAgentViews.key) == nil)
    }

    @Test func ignoresUnknownStoredValues() {
        let defaults = Self.defaults()
        defaults.set(["local|default|%1": "sidebar"], forKey: HerdrAgentViews.key)
        #expect(HerdrAgentViews.view(for: "local|default|%1", defaults) == .agent)
        #expect(HerdrAgentViews.stored(defaults).isEmpty)
    }

    @Test func titlesMatchTheButtonPair() {
        #expect(HerdrAgentView.diff.title == "Open diff")
        #expect(HerdrAgentView.agent.title == "Open agent")
    }

    @Test func aNestedDirectoryPicksItsEnclosingWorktree() {
        let worktrees = [
            Self.worktree("/repo", branch: "main", current: true),
            Self.worktree("/repo-feature", branch: "feature"),
            Self.worktree("/repo-feature/nested", branch: "nested"),
        ]
        #expect(
            QuinjetOperationExecution.worktree(
                containing: "/repo-feature/nested/Sources/App", in: worktrees)?.branch == "nested")
        #expect(
            QuinjetOperationExecution.worktree(
                containing: "/repo-feature/Sources", in: worktrees)?.branch == "feature")
        #expect(
            QuinjetOperationExecution.worktree(containing: "/repo-feature", in: worktrees)?.branch
                == "feature")
    }

    @Test func anUnrelatedDirectoryFallsBackToTheCheckedOutWorktree() {
        let worktrees = [
            Self.worktree("/repo-feature", branch: "feature"),
            Self.worktree("/repo", branch: "main", current: true),
        ]
        #expect(
            QuinjetOperationExecution.worktree(containing: "/elsewhere", in: worktrees)?.branch
                == "main")
        #expect(QuinjetOperationExecution.worktree(containing: "/repo", in: []) == nil)
    }

    @Test func aSiblingPathPrefixIsNotTreatedAsEnclosing() {
        let worktrees = [
            Self.worktree("/repo", branch: "main", current: true),
            Self.worktree("/repo-feature", branch: "feature"),
        ]
        #expect(
            QuinjetOperationExecution.worktree(containing: "/repo-feature", in: worktrees)?.branch
                == "feature")
    }

    private static func worktree(_ path: String, branch: String, current: Bool = false)
        -> QuinjetWorktree
    {
        QuinjetWorktree(
            path: path, head: String(repeating: "0", count: 40), branch: branch, current: current,
            bare: false, detached: false, locked: nil, prunable: nil)
    }

    private static func defaults() -> UserDefaults {
        let suite = "HerdrAgentViewTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
