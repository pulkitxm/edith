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

    @Test func requestsWorktreesThroughAnEdithMachineSession() async throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")
        let client = QuinjetClient { arguments in
            #expect(
                arguments
                    == [
                        "--client", "edith", "--remote", "pulkit@build", "--ssh-control-path",
                        "/tmp/edith.sock", "-C", "/srv/project", "worktree", "list", "--json",
                    ])
            return Data(Self.worktreesJSON.utf8)
        }

        let worktrees = try await client.worktrees(at: "/srv/project", remote: remote)

        #expect(worktrees.filter(\.canOpen).count == 2)
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

@MainActor
@Suite struct QuinjetPageModelTests {
    @Test func newTabPayloadCreatesAndSelectsPickerTab() throws {
        let model = QuinjetPageModel(client: client)
        let original = try #require(model.selectedTab)

        model.handleHostPayload("quinjet;open-new-tab", from: original)

        #expect(model.tabs.count == 2)
        #expect(model.selectedTab?.id != original.id)
        #expect(model.selectedTab?.worktree == nil)
    }

    @Test func remoteNewTabPayloadKeepsTheCurrentMachine() throws {
        let model = QuinjetPageModel(client: client)
        let original = try #require(model.selectedTab)
        let machineID = UUID()
        original.remote = QuinjetRemote(
            machineID: machineID, machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")

        model.handleHostPayload("quinjet;open-new-tab", from: original)

        #expect(model.selectedTab?.machineID == machineID)
        #expect(model.selectedTab?.worktree == nil)
    }

    @Test func worktreePayloadPresentsNativePicker() async throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        model.handleHostPayload("quinjet;open-worktree", from: tab)
        for _ in 0..<20 {
            if tab.showsWorktrees, !tab.loadingWorktrees, tab.worktrees.count == 2 { break }
            await Task.yield()
        }

        #expect(tab.showsWorktrees)
        #expect(tab.worktrees.map(\.branch) == ["main", "feat/quinjet"])
    }

    @Test func selectingWorktreeReusesCurrentTab() throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        model.open(
            Self.feature, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)

        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.id == tab.id)
        #expect(model.selectedTab?.worktree?.branch == "feat/quinjet")
        #expect(!tab.holder.started)
    }

    @Test func terminalRoutesManagedOSCSequence() async {
        let holder = TerminalSessionHolder()
        var action: QuinjetHostAction?
        holder.registerOSCHandler(code: QuinjetHostAction.oscCode) { payload in
            action = QuinjetHostAction(payload: payload)
        }

        holder.terminalView.feed(text: "\u{1B}]6973;quinjet;open-new-tab\u{1B}\\")
        for _ in 0..<10 {
            if action != nil { break }
            await Task.yield()
        }

        #expect(action == .openNewTab)
    }

    private var client: QuinjetClient {
        let data = (try? JSONEncoder().encode([Self.main, Self.feature])) ?? Data()
        return QuinjetClient { _ in data }
    }

    private static let main = QuinjetWorktree(
        path: "/work/edith", head: "1234567890abcdef", branch: "main", current: true,
        bare: false, detached: false, locked: nil, prunable: nil)
    private static let feature = QuinjetWorktree(
        path: "/work/edith-quinjet", head: "abcdef1234567890", branch: "feat/quinjet",
        current: false, bare: false, detached: false, locked: nil, prunable: nil)
}
