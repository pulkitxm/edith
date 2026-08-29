import EdithKit
import Testing

@testable import Edith

@Suite struct MachineTerminalLaunchTests {
    @Test func spaceTerminalsHideOnlyTheLiveRestartAction() {
        #expect(
            !MachineTerminalActionVisibility.shouldShow(
                .restart, showsRestartAction: false))
        #expect(
            MachineTerminalActionVisibility.shouldShow(
                .start, showsRestartAction: false))
        #expect(
            MachineTerminalActionVisibility.shouldShow(
                .connect, showsRestartAction: false))
    }

    @Test func localShellStartsInItsContextWithoutHerdrState() throws {
        let environment = nestedEnvironment + ["TERM=xterm-256color"]
        let launch = try #require(
            MachineTerminalLaunchPlan.make(
                isLocal: true, connection: nil, environment: environment,
                context: MachineTerminalContext(startingDirectory: "  /tmp/space project  ")))

        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-l"])
        #expect(launch.currentDirectory == "/tmp/space project")
        #expect(launch.environment.contains("TERM=xterm-256color"))
        for name in HerdrMachineTerminal.nestingVariables {
            #expect(launch.environment.filter { $0.hasPrefix("\(name)=") } == ["\(name)="])
        }
        #expect(!launch.arguments.joined(separator: " ").lowercased().contains("herdr"))
    }

    @Test func remoteShellUsesASafelyPrefixedLoginShellWithoutHerdrState() throws {
        let machine = Machine(
            name: "Build host", host: "build.example.com", username: "edith")
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        let launch = try #require(
            MachineTerminalLaunchPlan.make(
                isLocal: false, connection: connection,
                environment: nestedEnvironment + ["TERM=xterm-256color"],
                context: MachineTerminalContext(startingDirectory: "/srv/a b'c")))

        #expect(launch.executable == SSHConnection.executable.path)
        #expect(launch.currentDirectory == nil)
        #expect(
            launch.arguments.last
                == "cd '/srv/a b'\\''c' 2>/dev/null || cd; exec \"${SHELL:-/bin/sh}\" -l")
        for name in HerdrMachineTerminal.nestingVariables {
            #expect(launch.environment.filter { $0.hasPrefix("\(name)=") } == ["\(name)="])
        }
        #expect(!launch.arguments.joined(separator: " ").lowercased().contains("herdr"))
    }

    @Test func blankDirectoriesUseShellHomeAndRemoteNeedsAConnection() throws {
        let context = MachineTerminalContext(startingDirectory: " \n ")
        #expect(context.startingDirectory == nil)

        let local = try #require(
            MachineTerminalLaunchPlan.make(
                isLocal: true, connection: nil, environment: [], context: context))
        #expect(local.currentDirectory == nil)

        #expect(
            MachineTerminalLaunchPlan.make(
                isLocal: false, connection: nil, environment: [], context: context) == nil)
    }

    private var nestedEnvironment: [String] {
        HerdrMachineTerminal.nestingVariables.map { "\($0)=nested" }
    }
}
