import ArgumentParser
import EdithKit
import Foundation

struct MachinesDockerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docker",
        abstract: "Containers on a machine, parsed into stable fields.",
        discussion: """
            The machine name comes first: `ed machines tuf docker ps`. For anything
            this does not cover, the raw form sends a command through verbatim:
            `ed tuf docker buildx ls`.
            """,
        subcommands: [
            DockerPsCommand.self, DockerShellCommand.self, DockerImagesCommand.self,
            DockerVolumesCommand.self, DockerNetworksCommand.self, DockerDiskUsageCommand.self,
            DockerLogsCommand.self,
            DockerInspectCommand.self, DockerTopCommand.self,
            DockerStartCommand.self, DockerStopCommand.self,
            DockerRestartCommand.self, DockerRemoveCommand.self,
            DockerOpenCommand.self,
            DockerPauseCommand.self, DockerUnpauseCommand.self,
            DockerRemoveImageCommand.self, DockerRemoveVolumeCommand.self,
            DockerPruneCommand.self,
            DockerComposeCommand.self,
        ],
        defaultSubcommand: DockerPsCommand.self)
}

struct DockerOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open a published container port in the browser.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Published host or container port when more than one is available.")
    var port: Int?

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let output = try await runner.text(DockerCommands.containersWithStats(), timeout: 45)
            let containers = DockerParsing.containers(
                psOutput: output.components(separatedBy: DockerCommands.listSeparator).first ?? "")
            let found: DockerContainer
            do {
                found = try DockerBrowserOperationExecution.container(
                    named: container, in: containers)
            } catch {
                throw CLIFailure.notFound(error.localizedDescription)
            }
            let selected: DockerPortMapping
            do {
                selected = try DockerBrowserOperationExecution.publishedPort(
                    in: found, matching: port)
            } catch let error as MachineDetailOperationError {
                switch error {
                case .ambiguousPublishedPorts:
                    throw CLIFailure(
                        error.localizedDescription,
                        hint: "pass --port with a host or container port")
                default:
                    throw CLIFailure.notFound(error.localizedDescription)
                }
            }
            guard let hostPort = selected.hostPort else {
                throw CLIFailure.notFound("\(found.displayName) has no published TCP port")
            }
            guard let browserHost = DockerBrowserOperationExecution.browserHost(for: runner.machine)
            else {
                throw CLIFailure.unavailable(
                    "\(runner.machine.name) has no browser-reachable host")
            }
            guard
                let url = DockerBrowserOperationExecution.url(
                    for: selected, machine: runner.machine)
            else {
                let binding = selected.hostIP ?? browserHost
                throw CLIFailure.unavailable(
                    "\(found.displayName)'s \(binding):\(hostPort) binding is not reachable",
                    hint: "publish the port on a reachable address or add an SSH port forward")
            }
            guard
                RemoteFileOperationExecution.present(
                    [url], action: .open, using: CLIEnvironment.presentURLs)
            else { throw CLIFailure.unavailable("macOS could not open \(url.absoluteString)") }
            guard !json else {
                CLIOut.json(
                    .object([
                        "container": .string(found.displayName),
                        "machine": .string(runner.machine.name),
                        "opened": .bool(true),
                        "port": .int(hostPort),
                        "url": .string(url.absoluteString),
                    ]))
                return
            }
            CLIOut.out("opened \(url.absoluteString)")
        }
    }
}

struct DockerShellCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell", abstract: "Open an interactive shell in a container.")

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            try Task.checkCancellation()
            let runner = try await DockerBridge.runner(machine)
            try Task.checkCancellation()
            let command = MachineExecOperationExecution.dockerShellCommand(
                containerID: container)
            throw ExitCode(runner.interactive(command))
        }
    }
}

enum DockerBridge {
    static func runner(_ machine: String) async throws -> RemoteRunner {
        let runner = try await MachineResolver.runner(machine)
        let version = try await runner.run(DockerCommands.version(), timeout: 25)
        let availability = DockerParsing.availability(
            versionOutput: version.stdoutText, versionStderr: version.stderrText,
            status: version.status)
        guard availability.isAvailable else {
            throw CLIFailure.unavailable(
                "docker is not usable on \(runner.machine.name)",
                hint: describe(availability))
        }
        return runner
    }

    static func describe(_ availability: DockerAvailability) -> String {
        switch availability.status {
        case .missing: return "docker is not installed there"
        case .permissionDenied: return "this user cannot talk to the docker socket"
        case let .daemonDown(message): return message
        default: return "docker reported an unknown state"
        }
    }

    static func perform(
        _ operation: DockerLifecycleOperation, target: DockerLifecycleTarget,
        runner: RemoteRunner, failure: String
    ) async throws -> DockerLifecycleOperationResult {
        let result = await DockerLifecycleOperationExecution.perform(
            operation, target: target,
            using: { command, timeout in
                do {
                    let output = try await runner.run(command, timeout: timeout)
                    guard output.succeeded else {
                        return .failure(
                            CLIFailure(
                                failure,
                                hint: output.stderrText.trimmingCharacters(
                                    in: .whitespacesAndNewlines)))
                    }
                    return .success(output.stdoutText)
                } catch {
                    return .failure(error)
                }
            })
        switch result {
        case let .success(output): return output
        case let .failure(error): throw error
        }
    }
}

struct DockerPsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ps", abstract: "List containers with live stats.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: [.long, .short], help: "Include stopped containers.")
    var all = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let output = try await runner.text(DockerCommands.containersWithStats(), timeout: 45)
            let sections = output.components(separatedBy: DockerCommands.listSeparator)
            let parsed = DockerParsing.containers(psOutput: sections.first ?? "")
            var containers =
                sections.count > 1 ? DockerParsing.applyStats(sections[1], to: parsed) : parsed
            if !all { containers = containers.filter { $0.state.isRunning } }
            guard !json else {
                CLIOut.json(.array(containers.map(MachineReports.container)))
                return
            }
            let rows = containers.map { container in
                [
                    container.shortID, container.displayName, container.image,
                    container.state.rawValue,
                    container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "-",
                    container.ports.map(\.displayName).joined(separator: ","),
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "NAME", "IMAGE", "STATE", "CPU", "PORTS"], rows: rows))
        }
    }
}

struct DockerImagesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "images", abstract: "List images.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let images = DockerParsing.images(
                try await runner.text(DockerCommands.images(), timeout: 45))
            guard !json else {
                CLIOut.json(.array(images.map(MachineReports.image)))
                return
            }
            let rows = images.map { image in
                [image.shortID, image.displayName, ByteFormatter.string(image.sizeBytes)]
            }
            CLIOut.out(TextTable.render(headers: ["ID", "IMAGE", "SIZE"], rows: rows))
        }
    }
}

struct DockerVolumesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volumes", abstract: "List volumes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let volumes = DockerParsing.volumes(
                try await runner.text(DockerCommands.volumes(), timeout: 45))
            guard !json else {
                CLIOut.json(.array(volumes.map(MachineReports.volume)))
                return
            }
            let rows = volumes.map { [$0.name, $0.driver, $0.mountpoint] }
            CLIOut.out(TextTable.render(headers: ["NAME", "DRIVER", "MOUNTPOINT"], rows: rows))
        }
    }
}

struct DockerNetworksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "networks", abstract: "List networks.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let networks = DockerParsing.networks(
                try await runner.text(DockerCommands.networks(), timeout: 30))
            guard !json else {
                CLIOut.json(.array(networks.map(MachineReports.network)))
                return
            }
            let rows = networks.map { [$0.name, $0.driver, $0.scope] }
            CLIOut.out(TextTable.render(headers: ["NAME", "DRIVER", "SCOPE"], rows: rows))
        }
    }
}

struct DockerDiskUsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "df", abstract: "Disk usage by object type.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let usage = DockerParsing.diskUsage(
                try await runner.text(DockerCommands.diskUsage(), timeout: 45))
            guard !json else {
                CLIOut.json(
                    .array(
                        usage.map { entry in
                            .object([
                                "type": .string(entry.type),
                                "total": .int(entry.totalCount),
                                "active": .int(entry.active),
                                "sizeBytes": .number(entry.sizeBytes),
                                "reclaimableBytes": .number(entry.reclaimableBytes),
                            ])
                        }))
                return
            }
            let rows = usage.map { entry in
                [
                    entry.type, String(entry.totalCount), String(entry.active),
                    ByteFormatter.string(entry.sizeBytes),
                    ByteFormatter.string(entry.reclaimableBytes),
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"], rows: rows))
        }
    }
}

struct DockerLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Container logs.")

    @Option(help: "How many trailing lines to show.")
    var tail: Int = 200

    @Flag(name: [.long, .short], help: "Keep streaming.")
    var follow = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            let tail = try ArgumentChecks.nonNegative(self.tail, "--tail")
            let runner = try await DockerBridge.runner(machine)
            let status = await runner.passthrough(
                DockerCommands.logs(container, tail: tail, follow: follow))
            guard status == 0 else { throw ExitCode(status) }
        }
    }
}

struct DockerInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect", abstract: "Inspect a container with stable fields.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let result = await DockerDetailOperationExecution.inspect(containerID: container) {
                command, timeout in
                do {
                    return .success(try await runner.text(command, timeout: timeout))
                } catch {
                    return .failure(error)
                }
            }
            let summary = try result.get()
            guard !json else {
                CLIOut.json(MachineReports.inspect(summary))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["FIELD", "VALUE"], rows: MachineReports.inspectRows(summary)))
        }
    }
}

struct DockerTopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "top", abstract: "Read processes running in a container.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let result = await DockerDetailOperationExecution.processes(containerID: container) {
                command, timeout in
                do {
                    return .success(try await runner.text(command, timeout: timeout))
                } catch {
                    return .failure(error)
                }
            }
            let processes = try result.get()
            guard !json else {
                CLIOut.json(.array(processes.map(MachineReports.process)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["PID", "USER", "CPU", "MEMORY", "COMMAND"],
                    rows: processes.map {
                        [$0.pid, $0.user, $0.cpu, $0.memory, $0.command]
                    }))
        }
    }
}

protocol DockerLifecycleCommand: AsyncParsableCommand {
    static var action: String { get }
    static var isDestructive: Bool { get }
    var json: Bool { get }
    var confirmed: Bool { get }
    var machine: String { get }
    var containers: [String] { get }
}

extension DockerLifecycleCommand {
    static var isDestructive: Bool { false }
    var confirmed: Bool { true }
    static var operation: DockerLifecycleOperation? { DockerLifecycleOperation(cliVerb: action) }

    func apply() async throws {
        try await execute {
            let action = Self.action
            guard !containers.isEmpty else {
                throw CLIFailure("name at least one container")
            }
            let target = try MachineResolver.machine(machine)
            let plan =
                Self.isDestructive
                ? CLIDestructivePlan(
                    action: action,
                    targets: containers.map { "\(target.name):container:\($0)" },
                    confirmed: confirmed, json: json,
                    fields: [
                        "machine": .string(target.name),
                        "containers": .strings(containers),
                    ])
                : nil
            guard plan?.shouldApply() ?? true else { return }
            let runner = try await DockerBridge.runner(machine)
            if let operation = Self.operation {
                _ = try await DockerBridge.perform(
                    operation, target: .containers(containers), runner: runner,
                    failure: "docker \(action) failed on \(runner.machine.name)")
            } else if let operation = MachineDockerPauseOperation(rawValue: action) {
                let outcome = await MachineDockerPauseOperationExecution.perform(
                    operation, containerIDs: containers,
                    using: { command, timeout in
                        do {
                            let result = try await runner.run(command, timeout: timeout)
                            guard result.succeeded else {
                                return .failure(
                                    CLIFailure(
                                        "docker \(action) failed on \(runner.machine.name)",
                                        hint: result.stderrText.trimmingCharacters(
                                            in: .whitespacesAndNewlines)))
                            }
                            return .success(result.stdoutText)
                        } catch {
                            return .failure(error)
                        }
                    })
                if case let .failure(error) = outcome {
                    throw error
                }
            } else {
                let result = try await runner.run(
                    DockerCommands.lifecycle(action, ids: containers), timeout: 120)
                guard result.succeeded else {
                    throw CLIFailure(
                        "docker \(action) failed on \(runner.machine.name)",
                        hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if let plan {
                plan.finish(
                    changed: true, plain: "\(action) \(containers.joined(separator: " "))")
                return
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "containers": .strings(containers),
                        "action": .string(action),
                    ]))
                return
            }
            CLIOut.out("\(action) \(containers.joined(separator: " "))")
        }
    }
}

struct DockerStartCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a container.")
    static let action = "start"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerStopCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop a container.")
    static let action = "stop"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerRestartCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Restart a container.")
    static let action = "restart"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerRemoveCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove a container, forcing it down first.")
    static let action = "rm"
    static let isDestructive = true

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove them. Without this nothing is touched.")
    var yes = false

    var confirmed: Bool { yes }

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerPauseCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause", abstract: "Freeze a container's processes.")
    static let action = "pause"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerUnpauseCommand: DockerLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "unpause", abstract: "Let a frozen container run again.")
    static let action = "unpause"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container names or ids.")
    var containers: [String] = []

    func run() async throws { try await apply() }
}

struct DockerRemoveImageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmi", abstract: "Remove an image.", aliases: ["remove-image"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove it. Without this nothing is touched.")
    var yes = false

    @Flag(help: "Remove it even when a container still refers to it.")
    var force = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Image name or id.")
    var image: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let plan = CLIDestructivePlan(
                action: "remove docker image", targets: ["\(target.name):image:\(image)"],
                confirmed: yes, json: json,
                fields: [
                    "machine": .string(target.name),
                    "image": .string(image),
                    "forced": .bool(force),
                ])
            guard plan.shouldApply() else { return }
            let runner = try await DockerBridge.runner(machine)
            _ = try await DockerBridge.perform(
                .removeImage, target: .image(image, force: force), runner: runner,
                failure: "docker rmi failed on \(runner.machine.name)")
            plan.finish(changed: true, plain: "removed image \(image)")
        }
    }
}

struct DockerRemoveVolumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "volume-rm",
        abstract: "Remove a volume, and the data in it.",
        discussion: """
            A volume is where a container keeps the data it means to survive a restart, so
            this is not undoable. Nothing is removed without --yes.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually remove it. Without this nothing is touched.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Volume name.")
    var volume: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "machine": .string(runner.machine.name),
                            "volume": .string(volume),
                            "removed": .bool(false),
                        ]))
                    return
                }
                CLIOut.out("would remove volume \(volume) and everything in it")
                CLIOut.note("nothing was removed; pass --yes to go ahead")
                return
            }
            _ = try await DockerBridge.perform(
                .removeVolume, target: .volume(volume), runner: runner,
                failure: "docker volume rm failed on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "volume": .string(volume),
                        "removed": .bool(true),
                    ]))
                return
            }
            CLIOut.out("removed volume \(volume)")
        }
    }
}

struct DockerPruneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Reclaim space by removing unused docker objects.",
        discussion: """
            `what` is one of images, volumes, networks, builder or system. Nothing is
            removed without --yes, and volumes hold data, so that one is spelled out
            rather than folded into system.
            """)

    static let targets = DockerPruneTarget.allCases.map(\.rawValue)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually prune. Without it nothing is removed.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "images, volumes, networks, builder or system.")
    var what: String = "system"

    func run() async throws {
        try await execute {
            guard let target = DockerPruneTarget(rawValue: what) else {
                throw CLIFailure.notFound(
                    "docker cannot prune \(what)",
                    hint: "try: " + Self.targets.joined(separator: ", "))
            }
            let runner = try await DockerBridge.runner(machine)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "machine": .string(runner.machine.name),
                            "target": .string(what),
                            "applied": .bool(false),
                            "command": .string(DockerCommands.prune(what)),
                        ]))
                    return
                }
                CLIOut.out("would run: \(DockerCommands.prune(what))")
                CLIOut.note("pass --yes to do it")
                return
            }
            let result = try await DockerBridge.perform(
                .prune, target: .prune(target), runner: runner,
                failure: "docker prune \(what) failed on \(runner.machine.name)")
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "target": .string(what),
                        "applied": .bool(true),
                        "output": .string(
                            result.output.trimmingCharacters(in: .whitespacesAndNewlines)),
                    ]))
                return
            }
            CLIOut.raw(result.output)
        }
    }
}

struct DockerComposeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Compose projects on a machine.",
        subcommands: [
            ComposeListCommand.self, ComposeUpCommand.self, ComposeDownCommand.self,
            ComposeRestartCommand.self, ComposePullCommand.self, ComposeLogsCommand.self,
        ],
        defaultSubcommand: ComposeListCommand.self)
}

enum ComposeBridge {
    static func projects(_ runner: RemoteRunner) async throws -> [String] {
        DockerParsing.composeProjects(
            try await runner.text(DockerCommands.composeProjects(), timeout: 30))
    }

    static func require(_ runner: RemoteRunner, project: String) async throws {
        let known = try await projects(runner)
        guard known.contains(project) else {
            throw CLIFailure.notFound(
                "no compose project named \(project) on \(runner.machine.name)",
                hint: known.isEmpty
                    ? "run `ed machines \(runner.machine.name) docker compose ls` to look again"
                    : "projects: " + known.joined(separator: ", "))
        }
    }
}

struct ComposeListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List compose projects.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let projects = try await ComposeBridge.projects(runner)
            guard !json else {
                CLIOut.json(.strings(projects))
                return
            }
            guard !projects.isEmpty else {
                CLIOut.note("no compose projects on \(runner.machine.name)")
                return
            }
            for project in projects { CLIOut.out(project) }
        }
    }
}

protocol ComposeLifecycleCommand: AsyncParsableCommand {
    static var action: String { get }
    var json: Bool { get }
    var machine: String { get }
    var project: String { get }
}

extension ComposeLifecycleCommand {
    func apply(timeout: TimeInterval = 300) async throws {
        try await execute {
            let action = Self.action
            let runner = try await DockerBridge.runner(machine)
            try await ComposeBridge.require(runner, project: project)
            let result = try await runner.run(
                DockerCommands.composeAction(action, project: project, directory: nil),
                timeout: timeout)
            guard result.succeeded else {
                throw CLIFailure(
                    "docker compose \(action) failed for \(project)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "project": .string(project),
                        "action": .string(action),
                    ]))
                return
            }
            CLIOut.out("\(action) \(project)")
        }
    }
}

struct ComposeUpCommand: ComposeLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "up", abstract: "Bring a compose project up in the background.")
    static let action = "up -d"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Compose project name.")
    var project: String

    func run() async throws { try await apply() }
}

struct ComposeDownCommand: ComposeLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "down", abstract: "Take a compose project down.")
    static let action = "down"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Compose project name.")
    var project: String

    func run() async throws { try await apply() }
}

struct ComposeRestartCommand: ComposeLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Restart a compose project.")
    static let action = "restart"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Compose project name.")
    var project: String

    func run() async throws { try await apply() }
}

struct ComposePullCommand: ComposeLifecycleCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull", abstract: "Pull the images a compose project uses.")
    static let action = "pull"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Compose project name.")
    var project: String

    func run() async throws { try await apply(timeout: 900) }
}

struct ComposeLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Logs for a whole compose project.")

    @Option(help: "How many trailing lines to show.")
    var tail: Int = 200

    @Flag(name: [.long, .short], help: "Keep streaming.")
    var follow = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Compose project name.")
    var project: String

    func run() async throws {
        try await execute {
            let tail = try ArgumentChecks.nonNegative(self.tail, "--tail")
            let runner = try await DockerBridge.runner(machine)
            try await ComposeBridge.require(runner, project: project)
            let action = "logs --tail \(tail)" + (follow ? " -f" : "")
            let status = await runner.passthrough(
                DockerCommands.composeAction(action, project: project, directory: nil))
            guard status == 0 else { throw ExitCode(status) }
        }
    }
}
