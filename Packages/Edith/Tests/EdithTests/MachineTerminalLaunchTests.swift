import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct MachineTerminalLaunchTests {
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

    @Test func windowsRemoteShellPrefersGitBashWithPowerShellFallbacks() throws {
        let machine = Machine(
            name: "Windows", host: "windows.example.com", username: "edith")
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        let launch = try #require(
            MachineTerminalLaunchPlan.make(
                isLocal: false, connection: connection, environment: [],
                context: MachineTerminalContext(startingDirectory: "C:\\Projects"),
                platform: .windows))
        let command = try #require(launch.arguments.last)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))

        #expect(script.contains("Git/bin/bash.exe"))
        #expect(script.contains("--login -i"))
        #expect(script.contains("Get-Command pwsh.exe"))
        #expect(script.contains("& powershell.exe -NoLogo"))
        #expect(script.contains("$directory = 'C:\\Projects'"))
        #expect(script.contains("$env:CHERE_INVOKING = '1'"))
    }

    private var nestedEnvironment: [String] {
        HerdrMachineTerminal.nestingVariables.map { "\($0)=nested" }
    }
}
