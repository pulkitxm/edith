import Foundation
import Testing

@testable import Edith
@testable import EdithCLI
@testable import EdithKit

@Suite struct MachineSystemOperationTests {
    private let machine = Machine(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Box",
        host: "box.example", port: 2222, username: "dev")

    @Test func descriptorsCoverTheSixSystemRoutes() {
        let descriptors =
            MachineThermalOperation.allCases.map(\.descriptor)
            + MachineExecOperation.allCases.map(\.descriptor)
            + MachineMountOperation.allCases.map(\.descriptor)
            + MachineBroadcastOperation.allCases.map(\.descriptor)
        #expect(descriptors.count == 6)
        #expect(Set(descriptors.map(\.id)).count == 6)
        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["machines", "thermal", "status"],
                    ["machines", "thermal", "set"],
                    ["machines", "exec"],
                    ["machines", "mount"],
                    ["machines", "unmount"],
                    ["machines", "broadcast"],
                ])
        #expect(MachineThermalOperation.status.descriptor.effect == .read)
        #expect(MachineExecOperation.dockerShell.descriptor.effect == .interactive)
    }

    @Test func thermalStatusUsesTheSharedCommandAndParser() async throws {
        var request: (String, Data?, TimeInterval)?
        let result = await MachineThermalOperationExecution.status { command, stdin, timeout in
            request = (command, stdin, timeout)
            return .success("balanced\nquiet balanced performance\n")
        }

        #expect(
            try result.get()
                == MachinePlatformProfile(
                    current: "balanced", choices: ["quiet", "balanced", "performance"]))
        #expect(request?.0 == MachineThermalControls.statusCommand)
        #expect(request?.1 == nil)
        #expect(request?.2 == 15)
    }

    @Test func thermalSetBuildsThePrivilegedTimedCommand() async throws {
        let password = Data("secret\n".utf8)
        var request: (String, Data?, TimeInterval)?
        let result = await MachineThermalOperationExecution.set(
            profile: "performance", durationSeconds: 1_800, machineID: machine.id,
            sudoPassword: { id in
                #expect(id == machine.id)
                return password
            },
            using: { command, stdin, timeout in
                request = (command, stdin, timeout)
                return .success("performance\n")
            })

        let outcome = try result.get()
        #expect(outcome.profile == "performance")
        #expect(outcome.durationSeconds == 1_800)
        #expect(outcome.output == "performance\n")
        #expect(request?.0.contains("--on-active=1800s") == true)
        #expect(request?.0.hasPrefix("/usr/bin/sudo -S") == true)
        #expect(request?.1 == password)
        #expect(request?.2 == 30)
    }

    @Test func dockerShellBuildsTheSameInteractiveCommandAndLaunch() {
        let connection = SSHConnection(machine: machine)
        let command = MachineExecOperationExecution.dockerShellCommand(containerID: "api")
        let launch = MachineExecOperationExecution.dockerShellLaunch(
            containerID: "api", connection: connection, environment: ["TERM=xterm"])

        #expect(command == DockerCommands.execShell(containerID: "api"))
        #expect(launch.executable == SSHConnection.executable.path)
        #expect(launch.arguments == connection.terminalArguments(remoteCommand: command))
        #expect(launch.environment.first == "TERM=xterm")
        #expect(
            MachineExecOperationExecution.interactiveCommand(
                words: [command], workingDirectory: "/srv")
                == MachineWorkingDirectory.prefixed(command, directory: "/srv"))
    }

    @Test func mountAndUnmountChooseOneInjectedAdapter() async throws {
        let mounted = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/srv",
            mountPoint: "/tmp/Box", isReadOnly: true)
        var mountCalls = 0
        var unmountCalls = 0

        let mountResult = await MachineMountOperationExecution.perform(
            .mount, machine: machine, remotePath: "/srv",
            mountPoint: URL(fileURLWithPath: "/tmp/Box"), readOnly: true,
            mount: { candidate, path, destination, readOnly in
                mountCalls += 1
                #expect(candidate == machine)
                #expect(path == "/srv")
                #expect(destination?.path == "/tmp/Box")
                #expect(readOnly)
                return mounted
            },
            unmount: { _ in
                unmountCalls += 1
                return mounted
            })
        #expect(try mountResult.get().mount == mounted)
        #expect(mountCalls == 1)
        #expect(unmountCalls == 0)

        let unmountResult = await MachineMountOperationExecution.perform(
            .unmount, machine: machine,
            mount: { _, _, _, _ in
                mountCalls += 1
                return mounted
            },
            unmount: { candidate in
                unmountCalls += 1
                #expect(candidate == machine)
                return mounted
            })
        #expect(try unmountResult.get().operation == .unmount)
        #expect(mountCalls == 1)
        #expect(unmountCalls == 1)
    }

    @Test func defaultMountRestorationPrecedesANewMount() async throws {
        let restored = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/",
            mountPoint: "/tmp/Box")
        var mountCalls = 0
        let result = await MachineMountOperationExecution.perform(
            .mount, machine: machine, restoreDefault: true,
            restore: { candidate in
                #expect(candidate == machine)
                return .remounted(restored)
            },
            mount: { _, _, _, _ in
                mountCalls += 1
                return restored
            })

        let outcome = try result.get()
        #expect(outcome.mount == restored)
        #expect(outcome.restored)
        #expect(mountCalls == 0)
    }

    @Test func broadcastPlansNormalizeCLIAndTerminalInput() throws {
        let fromCLI = try MachineBroadcastOperationExecution.plan(
            words: ["--", "uptime", "--pretty"]
        ).get()
        let fromUI = try MachineBroadcastOperationExecution.plan(command: "  uptime  ").get()

        #expect(fromCLI.command == "uptime --pretty")
        #expect(fromUI.command == "uptime")
        #expect(fromUI.terminalInput == "uptime\n")
        #expect(
            throws: MachineBroadcastOperationError.emptyCommand,
            performing: { try MachineBroadcastOperationExecution.plan(command: "  ").get() })
    }

    @MainActor @Test func terminalBroadcastSendsTheSharedPlanToEveryTab() throws {
        let model = TerminalTabsModel()
        model.addTab(named: "One")
        model.addTab(named: "Two")
        var inputs: [String] = []

        let result = model.sendBroadcast(" uptime ") { _, input in
            inputs.append(input)
        }

        #expect(try result.get().command == "uptime")
        #expect(inputs == ["uptime\n", "uptime\n"])
    }

    @Test func cliParsersPreserveEverySystemRouteArgument() throws {
        let status = try #require(
            try EdRoot.parseAsRoot(["machines", "thermal", "status", "box", "--json"])
                as? MachinesThermalStatusCommand)
        #expect(status.machine == "box")
        #expect(status.json)

        let set = try #require(
            try EdRoot.parseAsRoot([
                "machines", "thermal", "set", "box", "performance", "--minutes", "30",
                "--json",
            ]) as? MachinesThermalSetCommand)
        #expect(set.machine == "box")
        #expect(set.profile == "performance")
        #expect(set.minutes == 30)
        #expect(set.json)

        let exec = try #require(
            try EdRoot.parseAsRoot([
                "machines", "exec", "--tty", "box", "docker exec -it api sh",
            ]) as? MachinesExecCommand)
        #expect(exec.machine == "box")
        #expect(exec.tty)
        #expect(exec.command == ["docker exec -it api sh"])

        let mount = try #require(
            try EdRoot.parseAsRoot([
                "machines", "mount", "box", "/srv", "--at", "/tmp/Box", "--read-only",
                "--json",
            ]) as? MachinesMountCommand)
        #expect(mount.machine == "box")
        #expect(mount.path == "/srv")
        #expect(mount.at == "/tmp/Box")
        #expect(mount.readOnly)
        #expect(mount.json)

        let unmount = try #require(
            try EdRoot.parseAsRoot(["machines", "unmount", "box", "--json"])
                as? MachinesUnmountCommand)
        #expect(unmount.machine == "box")
        #expect(unmount.json)

        let broadcast = try #require(
            try EdRoot.parseAsRoot([
                "machines", "broadcast", "--only", "box,tuf", "--json", "--", "uptime",
            ]) as? MachinesBroadcastCommand)
        #expect(broadcast.only == "box,tuf")
        #expect(broadcast.json)
        #expect(broadcast.command == ["uptime"])
    }

    @Test func everySystemDescriptorIsAnExactCompletionLeaf() {
        let descriptors =
            MachineThermalOperation.allCases.map(\.descriptor)
            + MachineExecOperation.allCases.map(\.descriptor)
            + MachineMountOperation.allCases.map(\.descriptor)
            + MachineBroadcastOperation.allCases.map(\.descriptor)

        for descriptor in descriptors {
            var node = CommandTree.root
            var walked: [String] = []
            for segment in descriptor.cli {
                guard let child = node.child(segment) else { break }
                node = child
                walked.append(segment)
            }
            #expect(walked == descriptor.cli)
            #expect(node.children.isEmpty)
        }
    }
}
