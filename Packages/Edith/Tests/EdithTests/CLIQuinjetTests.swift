import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

private final class QuinjetRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var arguments: [[String]] = []
    private var launches: [QuinjetLaunchRequest] = []
    private var noninteractiveLaunches: [Bool] = []

    func record(_ value: [String]) {
        lock.lock()
        arguments.append(value)
        lock.unlock()
    }

    func record(_ value: QuinjetLaunchRequest, noninteractive: Bool) {
        lock.lock()
        launches.append(value)
        noninteractiveLaunches.append(noninteractive)
        lock.unlock()
    }

    func recordedArguments() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return arguments
    }

    func recordedLaunches() -> [QuinjetLaunchRequest] {
        lock.lock()
        defer { lock.unlock() }
        return launches
    }

    func recordedLaunchModes() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return noninteractiveLaunches
    }
}

@Suite struct CLIQuinjetTests {
    @Test func localProjectsHaveStableJSON() async throws {
        let result = await CLIProbe.runInWorld(["quinjet", "projects", "--json"]) { _ in
            QuinjetCLIEnvironment.client = { Self.client() }
        }

        #expect(result.code == 0)
        #expect(result.stderr.isEmpty)
        let object = try #require(result.object)
        #expect(object["local"] as? Bool == true)
        #expect(object["machine"] as? String == "This Mac")
        let projects = try #require(object["projects"] as? [[String: Any]])
        #expect(projects.first?["name"] as? String == "edith")
        let worktrees = try #require(projects.first?["worktrees"] as? [[String: Any]])
        #expect(worktrees.first?["canOpen"] as? Bool == true)
        #expect(worktrees.first?["displayName"] as? String == "main")
    }

    @Test func configuredMachineDiscoveryUsesItsSharedSocket() async throws {
        let recorder = QuinjetRequestRecorder()
        let remote = Self.remote
        let result = await CLIProbe.runInWorld([
            "quinjet", "projects", "--machine", "build", "--json",
        ]) { _ in
            QuinjetCLIEnvironment.resolveTarget = { query in
                #expect(query == "build")
                return QuinjetCommandTarget(
                    name: "build", local: false, remote: remote, connection: nil)
            }
            QuinjetCLIEnvironment.client = {
                QuinjetClient { arguments in
                    recorder.record(arguments)
                    if arguments == ["remote", "list", "--json"] {
                        return Data(Self.remoteFoldersJSON.utf8)
                    }
                    return Data(Self.worktreesJSON.utf8)
                }
            }
        }

        #expect(result.code == 0)
        #expect(result.object?["local"] as? Bool == false)
        #expect(result.object?["machine"] as? String == "build")
        #expect(
            recorder.recordedArguments()
                == [
                    ["remote", "list", "--json"],
                    [
                        "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith.sock",
                        "-C", "/srv/edith", "worktree", "list", "--json",
                    ],
                ])
    }

    @Test func worktreesTargetLocalAndConfiguredMachines() async {
        let localRecorder = QuinjetRequestRecorder()
        let local = await CLIProbe.runInWorld([
            "quinjet", "worktrees", "/work/edith", "--json",
        ]) { _ in
            QuinjetCLIEnvironment.client = {
                QuinjetClient { arguments in
                    localRecorder.record(arguments)
                    return Data(Self.worktreesJSON.utf8)
                }
            }
        }
        #expect(local.code == 0)
        #expect(
            localRecorder.recordedArguments()
                == [["-C", "/work/edith", "worktree", "list", "--json"]])

        let remoteRecorder = QuinjetRequestRecorder()
        let remote = await CLIProbe.runInWorld([
            "quinjet", "worktrees", "/srv/edith", "--machine", "build", "--json",
        ]) { _ in
            QuinjetCLIEnvironment.resolveTarget = { _ in
                QuinjetCommandTarget(
                    name: "build", local: false, remote: Self.remote, connection: nil)
            }
            QuinjetCLIEnvironment.client = {
                QuinjetClient { arguments in
                    remoteRecorder.record(arguments)
                    return Data(Self.worktreesJSON.utf8)
                }
            }
        }
        #expect(remote.code == 0)
        #expect(
            remoteRecorder.recordedArguments()
                == [
                    [
                        "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith.sock",
                        "-C", "/srv/edith", "worktree", "list", "--json",
                    ]
                ])
    }

    @Test func openPrintsWithoutLaunching() async throws {
        let recorder = QuinjetRequestRecorder()
        let result = await CLIProbe.runInWorld([
            "quinjet", "open", "/work/it's ready", "--theme", "tokyo-night",
            "--appearance", "light", "--json",
        ]) { _ in
            CLIEnvironment.executableNamed = { _ in
                URL(fileURLWithPath: "/Applications/Quinjet Tools/quinjet")
            }
            QuinjetCLIEnvironment.client = { Self.client(path: "/work/it's ready") }
            QuinjetCLIEnvironment.launch = { request, noninteractive in
                recorder.record(request, noninteractive: noninteractive)
                return 0
            }
        }

        #expect(result.code == 0)
        #expect(recorder.recordedLaunches().isEmpty)
        #expect(result.object?["launched"] as? Bool == false)
        #expect(result.object?["terminal"] as? String == "current")
        let arguments = try #require(result.object?["arguments"] as? [String])
        #expect(arguments.contains("tokyo-night"))
        #expect(arguments.contains("light"))
        #expect(
            (result.object?["command"] as? String)?.contains(
                "'/Applications/Quinjet Tools/quinjet'") == true)
    }

    @Test func launchUsesTheSameRemoteRequestAsTheApp() async throws {
        let recorder = QuinjetRequestRecorder()
        let result = await CLIProbe.runInWorld([
            "quinjet", "launch", "/srv/edith", "--machine", "build", "--theme", "gruvbox",
            "--json",
        ]) { world in
            world.shared.set("dark", forKey: AppStorageKeys.General.appearance)
            CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/opt/bin/quinjet") }
            QuinjetCLIEnvironment.resolveTarget = { _ in
                QuinjetCommandTarget(
                    name: "build", local: false, remote: Self.remote, connection: nil)
            }
            QuinjetCLIEnvironment.client = { Self.client(path: "/srv/edith") }
            QuinjetCLIEnvironment.launch = { request, noninteractive in
                recorder.record(request, noninteractive: noninteractive)
                return 0
            }
        }

        #expect(result.code == 0)
        #expect(result.object?["launched"] as? Bool == true)
        #expect(result.object?["machine"] as? String == "build")
        #expect(recorder.recordedLaunchModes() == [true])
        let request = try #require(recorder.recordedLaunches().first)
        #expect(
            request.arguments
                == [
                    "--remote", "pulkit@build", "--ssh-control-path", "/tmp/edith.sock",
                    "-C", "/srv/edith", "tui", "--theme", "gruvbox", "--appearance", "dark",
                ])
        #expect(!request.arguments.contains("--client"))
    }

    @Test func omittedLaunchOptionsUseAppPreferencesAndAllowExplicitTerminalOverride() async throws
    {
        let preferred = await CLIProbe.runInWorld([
            "quinjet", "open", "/work/edith", "--json",
        ]) { world in
            world.shared.set("cmux", forKey: AppStorageKeys.Quinjet.terminal)
            world.shared.set("dracula", forKey: AppStorageKeys.Quinjet.theme)
            world.shared.set("dark", forKey: AppStorageKeys.General.appearance)
            CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/opt/bin/quinjet") }
            QuinjetCLIEnvironment.client = { Self.client(path: "/work/edith") }
        }

        #expect(preferred.code == 0)
        #expect(preferred.object?["terminal"] as? String == "cmux")
        #expect((preferred.object?["arguments"] as? [String])?.contains("dracula") == true)
        #expect((preferred.object?["arguments"] as? [String])?.contains("dark") == true)

        let overridden = await CLIProbe.runInWorld([
            "quinjet", "open", "/work/edith", "--embedded", "--json",
        ]) { world in
            world.shared.set("cmux", forKey: AppStorageKeys.Quinjet.terminal)
            CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/opt/bin/quinjet") }
            QuinjetCLIEnvironment.client = { Self.client(path: "/work/edith") }
        }

        #expect(overridden.code == 0)
        #expect(overridden.object?["terminal"] as? String == "current")
    }

    @Test func conflictingTerminalOverridesAreRejected() async {
        let result = await CLIProbe.runInWorld([
            "quinjet", "open", "/work/edith", "--cmux", "--embedded",
        ]) { _ in }

        #expect(result.code == ExitCodes.usage)
        #expect(result.stderr.contains("cannot be used together"))
    }

    @Test func jsonLaunchKeepsChildOutputOffStdout() async throws {
        let result = await CLIProbe.runInWorld([
            "quinjet", "launch", "/tmp", "--json",
        ]) { _ in
            CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/bin/echo") }
            QuinjetCLIEnvironment.client = { Self.client(path: "/tmp") }
        }

        #expect(result.code == 0, "\(result.stderr)")
        #expect(try result.decoded() is [String: Any])
        #expect(!result.stdout.contains("--theme quinjet"))
        #expect(result.stderr.contains("--theme quinjet"))
    }

    @Test func malformedOutputIsAnActionableFailure() async {
        let result = await CLIProbe.runInWorld(["quinjet", "projects"]) { _ in
            QuinjetCLIEnvironment.client = { QuinjetClient { _ in Data("{}".utf8) } }
        }

        #expect(result.code == ExitCodes.failure)
        #expect(result.stderr.contains("malformed JSON"))
        #expect(result.stderr.contains("update Quinjet"))
    }

    @Test func missingAndBrokenToolsHaveDistinctDiagnostics() async {
        let missing = await CLIProbe.runInWorld(["quinjet", "projects"]) { _ in
            QuinjetCLIEnvironment.client = {
                QuinjetClient { _ in throw QuinjetClientError.notInstalled }
            }
        }
        #expect(missing.code == ExitCodes.unavailable)
        #expect(missing.stderr.contains("brew install pulkitxm/tap/quinjet"))

        let broken = await CLIProbe.runInWorld(["quinjet", "projects"]) { _ in
            QuinjetCLIEnvironment.client = {
                QuinjetClient { _ in throw QuinjetClientError.commandFailed("database corrupt") }
            }
        }
        #expect(broken.code == ExitCodes.failure)
        #expect(broken.stderr.contains("Quinjet command failed"))
        #expect(broken.stderr.contains("database corrupt"))
    }

    @Test func unavailableMachineFailsBeforeDiscovery() async {
        let result = await CLIProbe.runInWorld([
            "quinjet", "projects", "--machine", "sleeping",
        ]) { _ in
            QuinjetCLIEnvironment.resolveTarget = { _ in
                throw CLIFailure.unavailable(
                    "could not reach sleeping", hint: "check the machine is awake")
            }
        }

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("could not reach sleeping"))
        #expect(result.stderr.contains("machine is awake"))
    }

    @Test func cmuxMustBeAvailableBeforeLaunch() async {
        let result = await CLIProbe.runInWorld([
            "quinjet", "launch", "/work/edith", "--cmux",
        ]) { _ in
            CLIEnvironment.executableNamed = { _ in URL(fileURLWithPath: "/opt/bin/quinjet") }
            QuinjetCLIEnvironment.client = { Self.client() }
            QuinjetCLIEnvironment.cmuxExecutable = { nil }
        }

        #expect(result.code == ExitCodes.unavailable)
        #expect(result.stderr.contains("cmux is not installed"))
        #expect(result.stderr.contains("omit --cmux"))
    }

    private static func client(path: String = "/work/edith") -> QuinjetClient {
        QuinjetClient { arguments in
            guard arguments.contains("worktree") else { return Data(Self.projectsJSON.utf8) }
            let json = Self.worktreesJSON.replacingOccurrences(of: "/work/edith", with: path)
            return Data(json.utf8)
        }
    }

    private static let remote = QuinjetRemote(
        machineID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        machineName: "build", target: "pulkit@build", controlPath: "/tmp/edith.sock")

    private static let projectsJSON = """
        [{"name":"edith","commonDir":"/work/edith/.git","worktrees":\(worktreesJSON)}]
        """

    private static let worktreesJSON = """
        [{
          "path":"/work/edith","head":"1234567890abcdef","branch":"main",
          "current":true,"bare":false,"detached":false,"locked":null,"prunable":null
        }]
        """

    private static let remoteFoldersJSON = """
        {"remotes":[{
          "target":"pulkit@build","folder":"/srv/edith","accessible":true,"uses":12
        }]}
        """
}
