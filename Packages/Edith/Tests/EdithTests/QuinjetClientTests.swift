import Foundation
import Testing

@testable import Edith

@Suite struct QuinjetClientTests {
    @Test func decodesRecentProjectsAndWorktrees() async throws {
        let client = QuinjetClient { arguments in
            #expect(arguments == ["--client", "edith", "project", "list", "--json"])
            return Data(Self.projectsJSON.utf8)
        }

        let projects = try await client.recentProjects()

        #expect(projects.count == 1)
        #expect(projects[0].name == "edith")
        #expect(projects[0].availableWorktrees.map(\.displayName) == ["main", "feat/quinjet"])
        #expect(projects[0].defaultWorktree?.branch == "main")
    }

    @Test func requestsWorktreesForCurrentPath() async throws {
        let client = QuinjetClient { arguments in
            #expect(
                arguments
                    == [
                        "--client", "edith", "-C", "/work/edith", "worktree", "list", "--json",
                    ])
            return Data(Self.worktreesJSON.utf8)
        }

        let worktrees = try await client.worktrees(at: "/work/edith")

        #expect(worktrees.filter(\.canOpen).map(\.branch) == ["main", "feat/quinjet"])
    }

    @Test func rejectsUnsupportedOutput() async {
        let client = QuinjetClient { _ in Data("{}".utf8) }

        await #expect(throws: QuinjetClientError.invalidResponse) {
            try await client.recentProjects()
        }
    }

    @Test func mapsManagedHostPayloads() {
        #expect(QuinjetHostAction.oscCode == 6973)
        #expect(QuinjetHostAction(payload: "quinjet;open-new-tab") == .openNewTab)
        #expect(QuinjetHostAction(payload: "quinjet;open-worktree") == .openWorktree)
        #expect(QuinjetHostAction(payload: "quinjet;unknown") == nil)
    }

    private static let projectsJSON = """
        [
          {
            "name": "edith",
            "commonDir": "/work/edith/.git",
            "worktrees": \(worktreesJSON)
          }
        ]
        """

    private static let worktreesJSON = """
        [
          {
            "path": "/work/edith",
            "head": "1234567890abcdef",
            "branch": "main",
            "current": true,
            "bare": false,
            "detached": false,
            "locked": null,
            "prunable": null
          },
          {
            "path": "/work/edith-quinjet",
            "head": "abcdef1234567890",
            "branch": "feat/quinjet",
            "current": false,
            "bare": false,
            "detached": false,
            "locked": null,
            "prunable": null
          },
          {
            "path": "/work/missing",
            "head": "0000000000000000",
            "branch": "old",
            "current": false,
            "bare": false,
            "detached": false,
            "locked": null,
            "prunable": "gitdir is missing"
          }
        ]
        """
}
