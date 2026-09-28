import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite struct QuinjetUsageTests {
    @Test func worktreeOrderTracksOpeningAndRefocusingWithMachineIsolation() async throws {
        let suite = "QuinjetUsageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let usage = LauncherUsage(defaults: defaults)
        let first = worktree("main")
        let second = worktree("feature")
        let projects = [
            QuinjetProject(name: "Demo", commonDir: "/demo/.git", worktrees: [first, second])
        ]
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(projects)
        let client = QuinjetClient { _ in data }
        let model = QuinjetPageModel(client: client, usage: usage)
        await model.refreshProjects()
        let firstTab = try #require(model.selectedTab)
        model.open(
            first, projectName: "Demo", available: [first, second], in: firstTab,
            launchEnabled: false)
        let secondTab = model.addPickerTab()
        model.open(
            second, projectName: "Demo", available: [first, second], in: secondTab,
            launchEnabled: false)
        #expect(
            model.filteredProjects.first?.availableWorktrees.map(\.path) == [
                second.path, first.path,
            ])
        #expect(model.recentWorktrees(for: firstTab).map(\.path) == [second.path, first.path])
        #expect(usage.lastUsed(["worktree", "remote", second.path]) == .distantPast)
        _ = try await model.performSessionOperation(
            QuinjetSessionRequest(operation: .focus, session: firstTab.id.uuidString))
        model.query = "demo"
        #expect(
            model.filteredProjects.first?.availableWorktrees.map(\.path) == [
                first.path, second.path,
            ])
        let reloaded = LauncherUsage(defaults: defaults)
        #expect(
            reloaded.lastUsed(["worktree", "local", first.path])
                > reloaded.lastUsed(["worktree", "local", second.path]))
    }

    private func worktree(_ branch: String) -> QuinjetWorktree {
        QuinjetWorktree(
            path: "/demo/\(branch)", head: "abc123", branch: branch, current: branch == "main",
            bare: false, detached: false, locked: nil, prunable: nil)
    }
}
