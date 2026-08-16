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
            DockerPsCommand.self, DockerImagesCommand.self, DockerVolumesCommand.self,
            DockerNetworksCommand.self, DockerDiskUsageCommand.self, DockerLogsCommand.self,
            DockerInspectCommand.self, DockerStartCommand.self, DockerStopCommand.self,
            DockerRestartCommand.self, DockerRemoveCommand.self,
            DockerPauseCommand.self, DockerUnpauseCommand.self,
            DockerRemoveImageCommand.self, DockerRemoveVolumeCommand.self,
            DockerPruneCommand.self,
            DockerComposeCommand.self,
        ],
        defaultSubcommand: DockerPsCommand.self)
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
        commandName: "inspect", abstract: "Raw docker inspect output.")

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Container name or id.")
    var container: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let output = try await runner.text(
                DockerCommands.inspectRaw(container), timeout: 30)
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.notFound("no container named \(container)")
            }
            CLIOut.raw(output)
        }
    }
}

protocol DockerLifecycleCommand: AsyncParsableCommand {
    static var action: String { get }
    var json: Bool { get }
    var machine: String { get }
    var containers: [String] { get }
}

extension DockerLifecycleCommand {
    func apply() async throws {
        try await execute {
            let action = Self.action
            guard !containers.isEmpty else {
                throw CLIFailure("name at least one container")
            }
            let runner = try await DockerBridge.runner(machine)
            let result = try await runner.run(
                DockerCommands.lifecycle(action, ids: containers), timeout: 120)
            guard result.succeeded else {
                throw CLIFailure(
                    "docker \(action) failed on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
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

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

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

    @Flag(help: "Remove it even when a container still refers to it.")
    var force = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Image name or id.")
    var image: String

    func run() async throws {
        try await execute {
            let runner = try await DockerBridge.runner(machine)
            let result = try await runner.run(
                DockerCommands.removeImage(image, force: force), timeout: 120)
            guard result.succeeded else {
                throw CLIFailure(
                    "docker rmi failed on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "image": .string(image),
                        "forced": .bool(force),
                    ]))
                return
            }
            CLIOut.out("removed image \(image)")
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
            let result = try await runner.run(DockerCommands.removeVolume(volume), timeout: 120)
            guard result.succeeded else {
                throw CLIFailure(
                    "docker volume rm failed on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
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

    static let targets = ["images", "volumes", "networks", "builder", "system"]

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
            guard Self.targets.contains(what) else {
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
            let result = try await runner.run(DockerCommands.prune(what), timeout: 300)
            guard result.succeeded else {
                throw CLIFailure(
                    "docker prune \(what) failed on \(runner.machine.name)",
                    hint: result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "target": .string(what),
                        "applied": .bool(true),
                        "output": .string(
                            result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)),
                    ]))
                return
            }
            CLIOut.raw(result.stdoutText)
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
