import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct QuinjetClientTests {
    @Test func decodesRecentProjectsAndWorktrees() async throws {
        let client = QuinjetClient { arguments in
            #expect(arguments == ["project", "list", "--json"])
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
                        "-C", "/work/edith", "worktree", "list", "--json",
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
                        "--remote", "pulkit@build", "--ssh-control-path",
                        "/tmp/edith.sock", "-C", "/srv/project", "worktree", "list", "--json",
                    ])
            return Data(Self.worktreesJSON.utf8)
        }

        let worktrees = try await client.worktrees(at: "/srv/project", remote: remote)

        #expect(worktrees.filter(\.canOpen).count == 2)
    }

    @Test func hydratesRecentFoldersFromTheSelectedMachine() async throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")
        let client = QuinjetClient { arguments in
            if arguments == ["remote", "list", "--json"] {
                return Data(Self.remoteFoldersJSON.utf8)
            }
            #expect(
                arguments
                    == [
                        "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith.sock",
                        "-C", "/srv/edith", "worktree", "list", "--json",
                    ])
            return Data(Self.worktreesJSON.utf8)
        }

        let projects = try await client.recentProjects(remote: remote)

        #expect(projects.count == 1)
        #expect(projects[0].name == "edith")
        #expect(projects[0].availableWorktrees.count == 2)
    }

    @Test func boundsRemoteFolderProbesAndPreservesFolderOrder() async throws {
        let folders = ["/srv/one", "/srv/two", "/srv/three"]
        let folderData = try JSONEncoder().encode(
            QuinjetRemoteFolders(
                remotes: folders.map {
                    QuinjetRemoteFolder(
                        target: "pulkit@build", folder: $0, accessible: true, uses: 1)
                }))
        let worktreeData = try Dictionary(
            uniqueKeysWithValues: folders.map { folder in
                (
                    folder,
                    try JSONEncoder().encode([
                        QuinjetWorktree(
                            path: folder, head: "1234567890abcdef", branch: "main",
                            current: true, bare: false, detached: false, locked: nil,
                            prunable: nil)
                    ])
                )
            })
        let harness = RemoteProbeHarness(folderData: folderData, worktreeData: worktreeData)
        let client = QuinjetClient(remoteProbeLimit: 2) { arguments in
            await harness.execute(arguments)
        }
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")

        let request = Task { try await client.recentProjects(remote: remote) }
        await harness.waitUntilStarted(2)
        #expect(await harness.maximumActive == 2)
        #expect(Set(await harness.startedFolders) == Set(folders.prefix(2)))

        await harness.release("/srv/two")
        await harness.waitUntilStarted(3)
        #expect(await harness.maximumActive == 2)

        await harness.release("/srv/three")
        await harness.release("/srv/one")
        let projects = try await request.value

        #expect(projects.map(\.name) == ["one", "two", "three"])
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

    private static let remoteFoldersJSON = """
        {
          "remotes": [
            {
              "target": "pulkit@build",
              "folder": "/srv/edith",
              "accessible": true,
              "uses": 12
            },
            {
              "target": "other",
              "folder": "/srv/other",
              "accessible": true,
              "uses": 4
            }
          ]
        }
        """
}

private actor RemoteProbeHarness {
    let folderData: Data
    let worktreeData: [String: Data]
    private(set) var startedFolders: [String] = []
    private(set) var maximumActive = 0
    private var active = 0
    private var releases: [String: CheckedContinuation<Void, Never>] = [:]
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(folderData: Data, worktreeData: [String: Data]) {
        self.folderData = folderData
        self.worktreeData = worktreeData
    }

    func execute(_ arguments: [String]) async -> Data {
        if arguments == ["remote", "list", "--json"] { return folderData }
        guard let marker = arguments.firstIndex(of: "-C"),
            arguments.indices.contains(marker + 1)
        else { return Data() }
        let folder = arguments[marker + 1]
        active += 1
        maximumActive = max(maximumActive, active)
        startedFolders.append(folder)
        let ready = startedWaiters.filter { startedFolders.count >= $0.0 }
        startedWaiters.removeAll { startedFolders.count >= $0.0 }
        ready.forEach { $0.1.resume() }
        await withCheckedContinuation { releases[folder] = $0 }
        active -= 1
        return worktreeData[folder] ?? Data()
    }

    func waitUntilStarted(_ count: Int) async {
        if startedFolders.count >= count { return }
        await withCheckedContinuation { startedWaiters.append((count, $0)) }
    }

    func release(_ folder: String) {
        releases.removeValue(forKey: folder)?.resume()
    }
}

private actor ProjectRefreshHarness {
    private var requests: [CheckedContinuation<Data, Error>?] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func execute(_ arguments: [String]) async throws -> Data {
        if let marker = arguments.firstIndex(of: "-C"),
            arguments.indices.contains(marker + 1)
        {
            let path = arguments[marker + 1]
            return try JSONEncoder().encode([
                QuinjetWorktree(
                    path: path, head: "1234567890abcdef", branch: "main", current: true,
                    bare: false, detached: false, locked: nil, prunable: nil)
            ])
        }
        return try await withCheckedThrowingContinuation { continuation in
            requests.append(continuation)
            let ready = requestWaiters.filter { requests.count >= $0.0 }
            requestWaiters.removeAll { requests.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitUntilRequested(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func resolve(_ index: Int, with data: Data) {
        guard requests.indices.contains(index), let continuation = requests[index] else { return }
        requests[index] = nil
        continuation.resume(returning: data)
    }
}

@MainActor
@Suite struct QuinjetPageModelTests {
    @Test func newestLocalProjectRefreshWins() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })

        let first = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(1)
        let second = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(2)

        await harness.resolve(1, with: try Self.projectData(name: "new"))
        await second.value
        #expect(model.projects.map(\.name) == ["new"])

        await harness.resolve(0, with: try Self.projectData(name: "old"))
        await first.value
        #expect(model.projects.map(\.name) == ["new"])
        #expect(!model.loadingProjects)
        #expect(model.projectError == nil)
    }

    @Test func newestRemoteProjectRefreshWins() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")

        let first = Task { await model.refreshProjects(for: remote) }
        await harness.waitUntilRequested(1)
        let second = Task { await model.refreshProjects(for: remote) }
        await harness.waitUntilRequested(2)

        await harness.resolve(1, with: try Self.remoteFolderData(path: "/srv/new"))
        await second.value
        #expect(model.projects(for: remote).map(\.name) == ["new"])

        await harness.resolve(0, with: try Self.remoteFolderData(path: "/srv/old"))
        await first.value
        #expect(model.projects(for: remote).map(\.name) == ["new"])
        #expect(!model.isLoadingProjects(for: remote))
        #expect(model.projectError(for: remote) == nil)
    }

    @Test func cancelledProjectRefreshDoesNotApplyItsResult() async throws {
        let harness = ProjectRefreshHarness()
        let model = QuinjetPageModel(
            client: QuinjetClient { arguments in try await harness.execute(arguments) })

        let request = Task { await model.refreshProjects() }
        await harness.waitUntilRequested(1)
        request.cancel()
        await harness.resolve(0, with: try Self.projectData(name: "cancelled"))
        await request.value

        #expect(model.projects.isEmpty)
        #expect(!model.loadingProjects)
        #expect(model.projectError == nil)
    }

    @Test func embeddedLaunchUsesEdithRoutingAndSelectedTheme() throws {
        let configuration = QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .tokyoNight, appearance: .light)

        let request = QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: Self.main.path, remote: nil, configuration: configuration,
            managedByEdith: true, localHomeDirectory: "/Users/pulkit")

        #expect(
            request.arguments
                == [
                    "--client", "edith", "-C", "/work/edith", "tui", "--theme",
                    "tokyo-night", "--appearance", "light",
                ])
    }

    @Test func cmuxLaunchKeepsRemoteSessionWithoutEdithRouting() throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith socket")
        let configuration = QuinjetLaunchConfiguration(
            terminal: .cmux, theme: .gruvbox, appearance: .dark)

        let request = QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/quinjet"),
            worktreePath: Self.main.path, remote: remote, configuration: configuration,
            managedByEdith: false, localHomeDirectory: "/Users/pulkit")

        #expect(
            request.arguments
                == [
                    "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith socket",
                    "-C", "/work/edith", "tui", "--theme", "gruvbox", "--appearance", "dark",
                ])
        #expect(!request.arguments.contains("--client"))
        #expect(request.currentDirectory == "/Users/pulkit")
    }

    @Test func cmuxCommandQuotesEveryArgument() {
        let command = QuinjetShellCommand.make(
            executable: "/Applications/Quinjet Tools/quinjet",
            arguments: ["-C", "/work/it's ready"])

        #expect(
            command
                == "exec '/Applications/Quinjet Tools/quinjet' '-C' '/work/it'\\''s ready'")
    }

    @Test func cmuxLaunchEscapesAppleScriptText() {
        #expect(
            QuinjetCMUXLauncher.appleScriptQuote("a \"quoted\" folder\n")
                == "\"a \\\"quoted\\\" folder\\n\"")
    }

    @Test func cmuxOperationsLeaveTheMainThread() async throws {
        let ranOnMainThread = try await QuinjetBackgroundOperation.run { Thread.isMainThread }

        #expect(!ranOnMainThread)
    }

    @Test func themeCatalogMatchesQuinjetCapabilities() {
        #expect(
            QuinjetTheme.allCases.map(\.rawValue)
                == [
                    "quinjet", "catppuccin", "dracula", "everforest", "gruvbox", "nord",
                    "one", "rose-pine", "solarized", "tokyo-night", "ayu", "monokai",
                    "github",
                ])
    }

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

    @Test func changingTerminalSettingsReconfiguresTheOpenProject() throws {
        let model = QuinjetPageModel(client: client)
        let tab = try #require(model.selectedTab)
        model.open(
            Self.main, projectName: "edith", available: [Self.main, Self.feature], in: tab,
            launchEnabled: false)
        let configuration = QuinjetLaunchConfiguration(
            terminal: .cmux, theme: .dracula, appearance: .light)

        model.apply(configuration, launchEnabled: false)

        #expect(tab.worktree == Self.main)
        #expect(tab.worktrees == [Self.main, Self.feature])
        #expect(tab.launchConfiguration == configuration)
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

    @Test func resettingTerminalClearsMouseTrackingAndCreatesANewView() {
        let holder = TerminalSessionHolder()
        let original = holder.terminalView
        holder.terminalView.feed(text: "\u{1B}[?1003h")
        #expect(holder.terminalView.terminal.mouseMode == .anyEvent)

        holder.reset()

        #expect(holder.terminalView !== original)
        #expect(holder.terminalView.terminal.mouseMode == .off)
        #expect(holder.generation == 1)
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

    private static func projectData(name: String) throws -> Data {
        try JSONEncoder().encode([
            QuinjetProject(
                name: name, commonDir: "/work/\(name)/.git",
                worktrees: [
                    QuinjetWorktree(
                        path: "/work/\(name)", head: "1234567890abcdef", branch: "main",
                        current: true, bare: false, detached: false, locked: nil, prunable: nil)
                ])
        ])
    }

    private static func remoteFolderData(path: String) throws -> Data {
        try JSONEncoder().encode(
            QuinjetRemoteFolders(
                remotes: [
                    QuinjetRemoteFolder(
                        target: "pulkit@build", folder: path, accessible: true, uses: 1)
                ]))
    }
}
