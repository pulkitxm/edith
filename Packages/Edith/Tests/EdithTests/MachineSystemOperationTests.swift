import Foundation
import Testing

@testable import Edith
@testable import EdithCLI
@testable import EdithKit

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
                    ["machines", "exec"],
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
        let words = ["printf", "%s", "hello world", "$(touch /tmp/never)"]
        #expect(
            MachineExecOperationExecution.interactiveCommand(
                words: words, workingDirectory: nil)
                == ShellQuote.command(words))
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

    @MainActor @Test func terminalBroadcastIPCIsCorrelatedAndScopedByMachineIdentity() throws {
        let first = TerminalTabsModel()
        first.addTab(named: "One")
        first.addTab(named: "Two")
        let second = TerminalTabsModel()
        second.addTab(named: "Three")
        let other = TerminalTabsModel()
        other.addTab(named: "Other")
        let otherID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        TerminalTabRegistry.register(first, machineID: machine.id)
        TerminalTabRegistry.register(second, machineID: machine.id)
        TerminalTabRegistry.register(other, machineID: otherID)
        defer {
            TerminalTabRegistry.unregister(first, machineID: machine.id)
            TerminalTabRegistry.unregister(second, machineID: machine.id)
            TerminalTabRegistry.unregister(other, machineID: otherID)
        }
        var inputs: [String] = []
        let requestID = "request-1"
        let response = MachineTerminalBroadcastBridge.response(
            to: [
                MachineTerminalBroadcastIPC.requestIDKey: requestID,
                MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
                MachineTerminalBroadcastIPC.commandKey: " uptime ",
            ],
            send: { _, input in inputs.append(input) })

        #expect(response[MachineTerminalBroadcastIPC.requestIDKey] as? String == requestID)
        #expect(response[MachineTerminalBroadcastIPC.okKey] as? Bool == true)
        #expect(response[MachineTerminalBroadcastIPC.tabCountKey] as? Int == 3)
        #expect(response[MachineTerminalBroadcastIPC.commandKey] as? String == "uptime")
        #expect(inputs == ["uptime\n", "uptime\n", "uptime\n"])

        let missing = MachineTerminalBroadcastBridge.response(
            to: [
                MachineTerminalBroadcastIPC.requestIDKey: "request-2",
                MachineTerminalBroadcastIPC.machineIDKey: UUID().uuidString,
                MachineTerminalBroadcastIPC.commandKey: "uptime",
            ])
        #expect(missing[MachineTerminalBroadcastIPC.okKey] as? Bool == false)
        #expect(
            missing[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noOpenTabsCode)
    }

    @Test func terminalBroadcastCLIUsesCorrelatedMainAppIPC() async throws {
        await CLIProbe.inWorld { world in
            MachineRegistry.add(machine)
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.machineTerminalBroadcastResult,
                    let request = world.postedPayloads(
                        for: IPC.Name.requestMachineTerminalBroadcast
                    ).last,
                    let requestID = request[MachineTerminalBroadcastIPC.requestIDKey] as? String
                else { return nil }
                return [
                    MachineTerminalBroadcastIPC.requestIDKey: requestID,
                    MachineTerminalBroadcastIPC.okKey: true,
                    MachineTerminalBroadcastIPC.tabCountKey: 2,
                ]
            }

            let plain = await CLIProbe.capture([
                "machines", "terminal", "broadcast", "Box", "--", "uptime", "--pretty",
            ])
            let json = await CLIProbe.capture([
                "machines", "terminal", "broadcast", "Box", "uptime", "--json",
            ])

            #expect(plain.code == 0)
            #expect(plain.stdout == "sent to 2 open tabs on Box: uptime --pretty\n")
            #expect(plain.stderr.isEmpty)
            #expect(json.code == 0)
            #expect(json.object?["machine"] as? String == "Box")
            #expect(json.object?["machineID"] as? String == machine.id.uuidString)
            #expect(json.object?["command"] as? String == "uptime")
            #expect(json.object?["tabs"] as? Int == 2)
            #expect(
                world.postedPayloads(for: IPC.Name.requestMachineTerminalBroadcast)
                    .allSatisfy {
                        $0[MachineTerminalBroadcastIPC.machineIDKey] as? String
                            == machine.id.uuidString
                            && $0[MachineTerminalBroadcastIPC.requestIDKey] as? String != nil
                    })
        }
    }

    @Test func terminalBroadcastCLIReportsMissingOpenTabs() async {
        await CLIProbe.inWorld { world in
            MachineRegistry.add(machine)
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.machineTerminalBroadcastResult,
                    let requestID = world.postedPayloads(
                        for: IPC.Name.requestMachineTerminalBroadcast
                    ).last?[MachineTerminalBroadcastIPC.requestIDKey] as? String
                else { return nil }
                return [
                    MachineTerminalBroadcastIPC.requestIDKey: requestID,
                    MachineTerminalBroadcastIPC.okKey: false,
                    MachineTerminalBroadcastIPC.errorCodeKey:
                        MachineTerminalBroadcastIPC.noOpenTabsCode,
                    MachineTerminalBroadcastIPC.errorKey:
                        "That machine has no open terminal tabs.",
                ]
            }

            let result = await CLIProbe.capture([
                "machines", "terminal", "broadcast", "Box", "uptime",
            ])

            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("no open terminal tabs"))
            #expect(result.stderr.contains("open a terminal tab for Box"))
        }
    }

    @Test func terminalBroadcastCLIResolvesLocalMachineWithoutConfiguredFleet() async {
        await CLIProbe.inWorld { world in
            CLIEnvironment.isMainAppRunning = { true }
            world.answers { name in
                guard name == IPC.Name.machineTerminalBroadcastResult,
                    let requestID = world.postedPayloads(
                        for: IPC.Name.requestMachineTerminalBroadcast
                    ).last?[MachineTerminalBroadcastIPC.requestIDKey] as? String
                else { return nil }
                return [
                    MachineTerminalBroadcastIPC.requestIDKey: requestID,
                    MachineTerminalBroadcastIPC.okKey: true,
                    MachineTerminalBroadcastIPC.tabCountKey: 1,
                ]
            }

            let result = await CLIProbe.capture([
                "machines", "terminal", "broadcast", "local", "uptime", "--json",
            ])

            #expect(result.code == 0)
            #expect(result.object?["machine"] as? String == Machine.local.name)
            #expect(result.object?["machineID"] as? String == Machine.localID.uuidString)
            #expect(
                world.postedPayloads(for: IPC.Name.requestMachineTerminalBroadcast)
                    .last?[MachineTerminalBroadcastIPC.machineIDKey] as? String
                    == Machine.localID.uuidString)
        }
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

        let terminalBroadcast = try #require(
            try EdRoot.parseAsRoot([
                "machines", "terminal", "broadcast", "box", "--", "uptime", "--pretty",
            ]) as? MachinesTerminalBroadcastCommand)
        #expect(terminalBroadcast.machine == "box")
        #expect(terminalBroadcast.command == ["uptime", "--pretty"])
    }

    @Test func everySystemDescriptorIsAnExactCompletionLeaf() {
        let descriptors =
            MachineThermalOperation.allCases.map(\.descriptor)
            + MachineExecOperation.allCases.map(\.descriptor)
            + MachineMountOperation.allCases.map(\.descriptor)
            + MachineBroadcastOperation.allCases.map(\.descriptor)
            + MachineTerminalBroadcastOperation.allCases.map(\.descriptor)

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
                        "Docker window", "open a shell in a container", "machines", "exec",
                        "--tty", "box", "docker exec -it api sh",
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
