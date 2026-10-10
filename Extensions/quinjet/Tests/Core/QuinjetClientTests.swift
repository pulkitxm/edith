import Foundation
import Testing

@testable import QuinjetExtension
import EdithExtensionSupport

@Suite struct QuinjetClientTests {
    @Test func operationDescriptorsAreUniqueAndRegistered() {
        let descriptors =
            QuinjetOperation.allCases.map(\.descriptor)
            + QuinjetSessionOperation.allCases.map(\.descriptor)

        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { $0.cli.starts(with: ["quinjet"]) })
        #expect(QuinjetOperation.open.descriptor.effect == .read)
        #expect(QuinjetOperation.launch.descriptor.effect == .interactive)
        #expect(QuinjetSessionOperation.close.descriptor.effect == .destructive)
        #expect(QuinjetSessionOperation.close.descriptor.requiresPreview)
        #expect(descriptors.allSatisfy(QuinjetCommandCatalog.descriptors.contains))
    }

    @Test func nativeSessionVocabularyHasStableCommandPaths() {
        #expect(
            QuinjetSessionOperation.allCases.map(\.descriptor.cli)
                == [
                    ["quinjet", "status"], ["quinjet", "sessions"],
                    ["quinjet", "new"],
                    ["quinjet", "focus"], ["quinjet", "close"],
                    ["quinjet", "restart"], ["quinjet", "switch"],
                ])
    }

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

    @Test func discoversThemesFromQuinjetCapabilitiesInReportedOrder() async throws {
        let client = QuinjetClient { arguments in
            #expect(arguments == ["capabilities", "--json"])
            return Data(
                """
                {
                  "commands": [
                    {
                      "path": "quinjet tui",
                      "arguments": [
                        {
                          "id": "theme",
                          "possibleValues": ["quinjet", "new-theme", "quinjet"]
                        }
                      ]
                    }
                  ]
                }
                """.utf8)
        }

        let themes = try await client.themes()

        #expect(themes.map(\.rawValue) == ["quinjet", "new-theme"])
    }

    @Test func rejectsCapabilitiesWithoutTerminalThemes() async {
        let client = QuinjetClient { _ in Data(#"{"commands":[]}"#.utf8) }

        await #expect(throws: QuinjetClientError.invalidResponse) {
            try await client.themes()
        }
    }

    @Test func discoversQuinjetAcrossSupportedRemotePlatforms() throws {
        let darwin = QuinjetRemoteExecutable.command(for: .darwin)
        let linux = QuinjetRemoteExecutable.command(for: .linux)
        let windows = QuinjetRemoteExecutable.command(for: .windows)

        #expect(darwin.contains("$HOME/.local/bin/quinjet"))
        #expect(darwin.contains("/opt/homebrew/bin/quinjet"))
        #expect(linux.contains("/etc/os-release"))
        #expect(linux.contains("$HOME/.linuxbrew/bin/quinjet"))
        #expect(linux.contains("/home/linuxbrew/.linuxbrew/bin/quinjet"))
        let payload = try #require(windows.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(payload)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("Get-Command quinjet.exe"))
        #expect(script.contains(#"Microsoft\WinGet\Links\quinjet.exe"#))
        #expect(script.contains(#"Programs\Quinjet\bin\quinjet.exe"#))
    }

    @Test func parsesAbsoluteRemoteExecutablesAndDistribution() throws {
        #expect(
            QuinjetRemoteExecutable.parse(
                "noise\n@EDITH_QUINJET@ubuntu\t/home/pulkit/.local/bin/quinjet\n",
                platform: .linux)
                == QuinjetRemoteExecutableResolution(
                    path: "/home/pulkit/.local/bin/quinjet", distributionID: "ubuntu"))
        #expect(
            QuinjetRemoteExecutable.parse(
                "@EDITH_QUINJET@macos\t/opt/homebrew/bin/quinjet\n", platform: .darwin)
                == QuinjetRemoteExecutableResolution(
                    path: "/opt/homebrew/bin/quinjet", distributionID: "macos"))
        #expect(
            QuinjetRemoteExecutable.parse(
                "@EDITH_QUINJET@windows\tC:\\Users\\pulkit\\scoop\\shims\\quinjet.exe",
                platform: .windows)
                == QuinjetRemoteExecutableResolution(
                    path: #"C:\Users\pulkit\scoop\shims\quinjet.exe"#,
                    distributionID: "windows"))
        #expect(
            QuinjetRemoteExecutable.parse(
                "@EDITH_QUINJET@ubuntu\tquinjet\n", platform: .linux) == nil)
        #expect(
            QuinjetRemoteExecutable.parse(
                "@EDITH_QUINJET@debian\t\n", platform: .linux)
                == QuinjetRemoteExecutableResolution(path: nil, distributionID: "debian"))
    }

    @Test func distinguishesMissingQuinjetFromProbeFailures() async throws {
        let missing = try QuinjetRemoteExecutable.resolution(
            from: SSHExecResult(
                status: 0, stdout: Data("@EDITH_QUINJET@ubuntu\t\n".utf8), stderr: Data()),
            platform: .linux)

        #expect(missing == QuinjetRemoteExecutableResolution(path: nil, distributionID: "ubuntu"))
        #expect(throws: QuinjetRemoteExecutableError.probeFailed("permission denied")) {
            try QuinjetRemoteExecutable.resolution(
                from: SSHExecResult(
                    status: 126, stdout: Data(), stderr: Data("permission denied".utf8)),
                platform: .linux)
        }
        #expect(throws: QuinjetRemoteExecutableError.invalidResponse) {
            try QuinjetRemoteExecutable.resolution(
                from: SSHExecResult(status: 0, stdout: Data("unexpected".utf8), stderr: Data()),
                platform: .linux)
        }
        await #expect(throws: QuinjetRemoteExecutableError.probeFailed("connection reset")) {
            try await QuinjetRemoteExecutable.resolve(platform: .linux) { _ in
                throw RemoteQuinjetProbeFailure()
            }
        }
    }

    @Test func reportsMissingRemoteQuinjetBeforeReadingRecentFolders() async {
        let client = QuinjetClient { _ in
            Issue.record("recent folders were read before validating remote Quinjet")
            return Data()
        }
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock", platform: .linux, executablePath: nil,
            distributionID: "ubuntu")

        await #expect(
            throws: QuinjetClientError.remoteNotInstalled(
                machine: "build", platform: .linux, distributionID: "ubuntu")
        ) {
            try await client.recentProjects(remote: remote)
        }
    }

    @Test func unresolvedRemoteDoesNotAssumeQuinjetIsOnPath() {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")

        #expect(remote.executablePath == nil)
    }

    @Test func launchRequestRejectsAnUnresolvedRemote() {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock")

        #expect(
            throws: QuinjetClientError.remoteNotInstalled(
                machine: "build", platform: .linux, distributionID: "linux")
        ) {
            try QuinjetOperationExecution.launchRequest(
                executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/quinjet"),
                worktreePath: "/srv/project", remote: remote,
                configuration: .default, managedByEdith: false,
                localHomeDirectory: "/Users/pulkit")
        }
    }

    @Test func missingRemoteGuidanceMatchesThePlatform() {
        let macOS = QuinjetClientError.remoteNotInstalled(
            machine: "mac", platform: .darwin, distributionID: "macos")
        let ubuntu = QuinjetClientError.remoteNotInstalled(
            machine: "ubuntu", platform: .linux, distributionID: "ubuntu")
        let linux = QuinjetClientError.remoteNotInstalled(
            machine: "fedora", platform: .linux, distributionID: "fedora")
        let windows = QuinjetClientError.remoteNotInstalled(
            machine: "windows", platform: .windows, distributionID: "windows")

        #expect(macOS.localizedDescription.contains("brew install"))
        #expect(ubuntu.localizedDescription.contains("apt repository"))
        #expect(linux.localizedDescription.contains("shell installer"))
        #expect(windows.localizedDescription.contains("winget install"))
    }

    @Test func liveRequestsUseTheResolvedUnixRemoteExecutable() throws {
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "build", target: "pulkit@build",
            controlPath: "/tmp/edith.sock", platform: .linux,
            sshArguments: SSHConnection.masterOnlyOptions + [
                "-p", "2222", "-i", "/tmp/mock-key", "-S", "/tmp/edith.sock", "--", "pulkit@build",
            ],
            executablePath: "/home/pulkit/.local/bin/quinjet", distributionID: "ubuntu")

        let request = try QuinjetClient.liveRequest(
            arguments: ["-C", "/srv/project", "worktree", "list", "--json"],
            remote: remote, executable: URL(fileURLWithPath: "/opt/homebrew/bin/quinjet"))

        #expect(request.executableURL == SSHConnection.executable)
        #expect(Array(request.arguments.dropLast()) == ["-T"] + remote.sshArguments)
        #expect(
            request.arguments.last
                == "'/home/pulkit/.local/bin/quinjet' '-C' '/srv/project' 'worktree' 'list' '--json'"
        )
        #expect(request.arguments.contains("ProxyCommand=/usr/bin/false"))

    }

    @Test func liveRequestsRunResolvedWindowsQuinjetThroughPowerShell() throws {
        let executable = #"C:\Users\pulkit\scoop\shims\quinjet.exe"#
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "windows", target: "pulkit@windows",
            controlPath: "/tmp/edith.sock", platform: .windows,
            sshArguments: SSHConnection.masterOnlyOptions + [
                "-p", "2222", "-S", "/tmp/edith.sock", "--", "pulkit@windows",
            ],
            executablePath: executable, distributionID: "windows")

        let request = try QuinjetClient.liveRequest(
            arguments: ["-C", #"E:\work\project"#, "worktree", "list", "--json"],
            remote: remote, executable: URL(fileURLWithPath: "/opt/homebrew/bin/quinjet"))

        #expect(request.executableURL == SSHConnection.executable)
        #expect(Array(request.arguments.dropLast()) == ["-T"] + remote.sshArguments)
        let command = try #require(request.arguments.last)
        #expect(command.hasPrefix("powershell.exe "))
        let payload = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(payload)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("& '\(executable)' '-C' 'E:\\work\\project'"))
        #expect(script.contains("'worktree' 'list' '--json'"))
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
            controlPath: "/tmp/edith.sock", executablePath: "/usr/local/bin/quinjet")
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
            controlPath: "/tmp/edith.sock", executablePath: "/usr/local/bin/quinjet")
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

    @Test func hydratesWindowsFoldersEvenWhenLocalAccessibilityIsFalse() async throws {
        let folder = #"C:\Users\kpulk\Desktop\Crowdvolt\mono-volt"#
        let folderData = try JSONEncoder().encode(
            QuinjetRemoteFolders(remotes: [
                QuinjetRemoteFolder(
                    target: "win-lan", folder: folder, accessible: false, uses: 10)
            ]))
        let worktreeData = try JSONEncoder().encode([
            QuinjetWorktree(
                path: folder, head: "1234567890abcdef", branch: "main", current: true,
                bare: false, detached: false, locked: nil, prunable: nil)
        ])
        let client = QuinjetClient { arguments in
            if arguments == ["remote", "list", "--json"] { return folderData }
            #expect(arguments.contains(folder))
            return worktreeData
        }
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "win-lan", target: "win-lan",
            controlPath: "/tmp/edith.sock", platform: .windows,
            homeDirectory: #"C:\Users\kpulk"#,
            executablePath: #"C:\Users\kpulk\scoop\shims\quinjet.exe"#)

        let projects = try await client.recentProjects(remote: remote)

        #expect(projects.map(\.name) == ["mono-volt"])
        #expect(projects.first?.defaultWorktree?.path == folder)
    }

    @Test func resolvesWindowsHomeAndMatchesNestedWorktreePathsCaseInsensitively() async throws {
        let folder = #"C:\Users\kpulk\Desktop\Crowdvolt\mono-volt"#
        let client = QuinjetClient { arguments in
            #expect(
                arguments.contains(
                    #"C:\Users\kpulk\desktop\Crowdvolt\mono-volt\Sources"#))
            return try JSONEncoder().encode([
                QuinjetWorktree(
                    path: folder, head: "1234567890abcdef", branch: "main", current: true,
                    bare: false, detached: false, locked: nil, prunable: nil)
            ])
        }
        let remote = QuinjetRemote(
            machineID: UUID(), machineName: "win-lan", target: "win-lan",
            controlPath: "/tmp/edith.sock", platform: .windows,
            homeDirectory: #"C:\Users\kpulk"#,
            executablePath: #"C:\Users\kpulk\scoop\shims\quinjet.exe"#)

        let selection = try await QuinjetOperationExecution.openSelection(
            at: #"~\desktop\Crowdvolt\mono-volt\Sources"#, remote: remote, using: client)

        #expect(selection.projectName == "mono-volt")
        #expect(selection.worktree.path == folder)
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
            controlPath: "/tmp/edith.sock", executablePath: "/usr/local/bin/quinjet")

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

    @Test func explainsNonRepositoryFailures() {
        let error = QuinjetClientError.commandFailed(
            "error: Not a Git repository: fatal: not a git repository"
        )

        #expect(error.isNotGitRepository)
        #expect(
            error.localizedDescription
                == "This folder is not a Git repository. "
                + "Choose the project folder that contains .git."
        )
        #expect(!QuinjetClientError.commandFailed("permission denied").isNotGitRepository)
    }

    @Test func nonRepositoryLaunchUsesTheOriginalDirectory() throws {
        let request = try QuinjetOperationExecution.launchRequest(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/quinjet"),
            worktreePath: "/tmp/non-repository", remote: nil,
            configuration: .default, managedByEdith: false,
            localHomeDirectory: "/Users/pulkit")

        #expect(
            Array(request.arguments.prefix(3))
                == ["-C", "/tmp/non-repository", "tui"])
        #expect(request.currentDirectory == "/tmp/non-repository")
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

private struct RemoteQuinjetProbeFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? { "connection reset" }
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

private final class QuinjetWorkspaceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var focused: [String] = []
    private var closed: [String] = []

    func focus(_ id: String) {
        lock.lock()
        focused.append(id)
        lock.unlock()
    }

    func close(_ id: String) {
        lock.lock()
        closed.append(id)
        lock.unlock()
    }

    func values() -> (focused: [String], closed: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (focused, closed)
    }
}
