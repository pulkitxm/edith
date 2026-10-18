@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

@Suite struct MachineSystemOperationTests {
    private let machine = Machine(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Box",
        host: "box.example", port: 2222, username: "dev")

    @Test func descriptorsCoverTheSevenSystemRoutes() {
        let descriptors =
            MachineThermalOperation.allCases.map(\.descriptor)
            + MachineExecOperation.allCases.map(\.descriptor)
            + MachineMountOperation.allCases.map(\.descriptor)
            + MachineBroadcastOperation.allCases.map(\.descriptor)
            + MachineTerminalBroadcastOperation.allCases.map(\.descriptor)
        #expect(descriptors.count == 7)
        #expect(Set(descriptors.map(\.id)).count == 7)
        #expect(Set(descriptors.map(\.cli)).count == 7)
        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["machines", "thermal", "status"],
                    ["machines", "thermal", "set"],
                    ["machines", "docker", "shell"],
                    ["machines", "mount"],
                    ["machines", "unmount"],
                    ["machines", "broadcast"],
                    ["machines", "terminal", "broadcast"],
                ])
        #expect(MachineThermalOperation.status.descriptor.effect == .read)
        #expect(MachineExecOperation.dockerShell.descriptor.effect == .interactive)
        #expect(descriptors.allSatisfy(UserOperationCatalog.descriptors.contains))
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

    @Test func thermalStatusUsesWindowsPowerSchemes() async throws {
        var request: (String, Data?, TimeInterval)?
        let result = await MachineThermalOperationExecution.status(platform: .windows) {
            command, stdin, timeout in
            request = (command, stdin, timeout)
            return .success("Balanced\nPower saver\nBalanced\nHigh performance\n")
        }

        #expect(try result.get().current == "Balanced")
        #expect(request?.0 == WindowsPowerProfileCommands.status)
        #expect(request?.1 == nil)
    }

    @Test func thermalSetUsesWindowsWithoutSudoInput() async throws {
        var request: (String, Data?, TimeInterval)?
        let result = await MachineThermalOperationExecution.set(
            profile: "High performance", durationSeconds: 1_800, machineID: machine.id,
            platform: .windows,
            sudoPassword: { _ in Data("unused\n".utf8) },
            using: { command, stdin, timeout in
                request = (command, stdin, timeout)
                return .success("High performance\n")
            })

        #expect(try result.get().profile == "High performance")
        #expect(request?.0.contains("powershell.exe") == true)
        #expect(request?.1 == nil)
        #expect(request?.2 == 30)
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

        var invoked = false
        let invalid = await MachineThermalOperationExecution.set(
            profile: "performance", durationSeconds: 604_801, machineID: machine.id,
            using: { _, _, _ in
                invoked = true
                return .success("")
            })
        #expect(
            throws: MachineThermalOperationError.invalidDuration(604_801),
            performing: { try invalid.get() })
        #expect(!invoked)
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

    @Test func mountNormalizesAWindowsDriveBeforeCallingTheAdapter() async throws {
        let mounted = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/C:/Users/kpulk",
            mountPoint: "/tmp/Box")
        let result = await MachineMountOperationExecution.perform(
            .mount, machine: machine, remotePath: "C:\\Users\\kpulk", platform: .windows,
            mount: { _, path, _, _ in
                #expect(path == "/C:/Users/kpulk")
                return mounted
            })

        #expect(try result.get().mount == mounted)
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

    @Test func mountRestoreFailuresDoNotFallThroughToANewMount() async throws {
        let recorded = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/",
            mountPoint: "/tmp/Box")
        var mountCalls = 0
        let result = await MachineMountOperationExecution.perform(
            .mount, machine: machine, restoreDefault: true,
            restore: { _ in .failed(recorded, "connection refused") },
            mount: { _, _, _, _ in
                mountCalls += 1
                return recorded
            })

        #expect(
            throws: MachineMountOperationError.restoreFailed(recorded, "connection refused"),
            performing: { try result.get() })
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
        #expect(fromUI.remoteCommand(for: .linux) == "uptime")
        #expect(fromUI.remoteCommand(for: .windows).contains("-EncodedCommand"))
        #expect(
            throws: MachineBroadcastOperationError.emptyCommand,
            performing: { try MachineBroadcastOperationExecution.plan(command: "  ").get() })
    }

    @Test func productionUIPlacementsExactlyCoverTheSixSystemActions() {
        let descriptors =
            MachineThermalOperation.allCases.map(\.descriptor)
            + MachineExecOperation.allCases.map(\.descriptor)
            + MachineMountOperation.allCases.map(\.descriptor)
            + MachineBroadcastOperation.allCases.map(\.descriptor)
            + MachineTerminalBroadcastOperation.allCases.map(\.descriptor)
        let ids = Set(descriptors.map(\.id))
        let placements = UserOperationCatalog.userInterfaceActions.filter {
            ids.contains($0.operation.id)
        }

        #expect(
            placements.map {
                [$0.surface, $0.action] + $0.cli
            }
                == [
                    [
                        "Machine cooling", "inspect thermal profiles", "machines", "thermal",
                        "status", "box",
                    ],
                    [
                        "Machine cooling", "switch thermal profiles", "machines", "thermal",
                        "set", "box", "performance",
                    ],
                    [
                        "Docker window", "open a shell in a container", "machines", "docker",
                        "shell", "box", "api",
                    ],
                    [
                        "Machine tools", "mount the machine's disk on this Mac", "machines",
                        "mount", "box",
                    ],
                    [
                        "Machine tools", "unmount the machine's disk", "machines", "unmount",
                        "box",
                    ],
                    [
                        "Terminal broadcast bar", "send one line to every pane", "machines",
                        "terminal", "broadcast", "box", "--", "uptime",
                    ],
                ])
        #expect(
            UserOperationCatalog.commandLineOnly.map(\.descriptor.id).contains(
                MachineBroadcastOperation.fleet.descriptor.id))
    }
}
