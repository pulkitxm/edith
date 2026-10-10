import ArgumentParser
import Foundation

public enum ArgumentKind: Equatable, Sendable {
    case machine, machineOrLocal, onOff, pruneTarget, composeProject, historyIndex, localPath,
        remotePath,
        container, free
}

public enum DestructivePolicy: String, Equatable, Sendable {
    case previewThenYes
}

public struct PassthroughCompletion: Equatable, Sendable {
    public let afterPositionals: Int
    public let remoteMachinePosition: Int?

    public init(afterPositionals: Int, remoteMachinePosition: Int? = nil) {
        self.afterPositionals = afterPositionals
        self.remoteMachinePosition = remoteMachinePosition
    }
}

public struct CommandNode: Equatable, Sendable {
    public let name: String
    public let summary: String
    public let aliases: [String]
    public let options: [String]
    public let optionValues: [String: ArgumentKind]
    public let arguments: [ArgumentKind]
    public let repeatingArgument: ArgumentKind?
    public let children: [CommandNode]
    public let destructivePolicy: DestructivePolicy?
    public let passthroughCompletion: PassthroughCompletion?

    public init(
        _ name: String, _ summary: String, aliases: [String] = [], options: [String] = [],
        optionValues: [String: ArgumentKind] = [:], arguments: [ArgumentKind] = [],
        repeatingArgument: ArgumentKind? = nil, children: [CommandNode] = [],
        destructivePolicy: DestructivePolicy? = nil,
        passthroughCompletion: PassthroughCompletion? = nil
    ) {
        self.name = name
        self.summary = summary
        self.aliases = aliases
        self.options = options
        self.optionValues = optionValues
        self.arguments = arguments
        self.repeatingArgument = repeatingArgument
        self.children = children
        self.destructivePolicy = destructivePolicy
        self.passthroughCompletion = passthroughCompletion
    }

    public var names: [String] { [name] + aliases }

    public func child(_ name: String) -> CommandNode? {
        children.first { $0.names.contains(name) }
    }
}

public struct CommandSpec: Equatable, Sendable {
    public let options: [String]
    public let optionValues: [String: ArgumentKind]
    public let arguments: [ArgumentKind]
    public let repeatingArgument: ArgumentKind?
    public let destructivePolicy: DestructivePolicy?
    public let passthroughCompletion: PassthroughCompletion?

    public init(
        options: [String] = [], optionValues: [String: ArgumentKind] = [:],
        arguments: [ArgumentKind] = [], repeatingArgument: ArgumentKind? = nil,
        destructivePolicy: DestructivePolicy? = nil,
        passthroughCompletion: PassthroughCompletion? = nil
    ) {
        self.options = options
        self.optionValues = optionValues
        self.arguments = arguments
        self.repeatingArgument = repeatingArgument
        self.destructivePolicy = destructivePolicy
        self.passthroughCompletion = passthroughCompletion
    }
}

public enum CommandTree {
    public static let inherited = ["-h", "--help", "--version"]
    public static let common = ["--json"] + inherited

    typealias Spec = CommandSpec

    static let specs: [String: Spec] = [
        "ed machines": Spec(arguments: [.machine]),
        "ed machines ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines show": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines add": Spec(
            options: [
                "--json", "--help", "--host", "--port", "--user", "--key", "--alias", "--mac",
                "--password-stdin", "--key-passphrase-stdin",
            ], arguments: [.free]),
        "ed machines edit": Spec(
            options: [
                "--json", "--help", "--name", "--host", "--port", "--user", "--key", "--agent",
                "--mac", "--sudo-password-stdin", "--forget-sudo-password", "--password-stdin",
                "--key-passphrase-stdin",
            ], arguments: [.machine]),
        "ed machines rm": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines forwards ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines forwards add": Spec(
            options: ["--json", "--help", "--local", "--remote", "--remote-host", "--title"],
            arguments: [.machine]),
        "ed machines forwards on": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards off": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards open": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines forwards rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines snippets ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines snippets add": Spec(
            options: ["--json", "--help", "--shared"], arguments: [.machine, .free, .free],
            passthroughCompletion: PassthroughCompletion(afterPositionals: 2)),
        "ed machines snippets rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines snippets run": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .historyIndex]),
        "ed machines power status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines power reboot": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines power shutdown": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine],
            destructivePolicy: .previewThenYes),
        "ed machines power wake": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines thermal status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines thermal set": Spec(
            options: ["--json", "--help", "--minutes"], arguments: [.machine, .free]),
        "ed machines control status": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines control brightness": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines control volume": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines control mute": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control wifi": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .onOff],
            destructivePolicy: .previewThenYes),
        "ed machines control bluetooth": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control airplane": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .onOff],
            destructivePolicy: .previewThenYes),
        "ed machines control dnd": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control caffeinate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .onOff]),
        "ed machines control keyboard-light": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines workspace ls": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines workspace use": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace new": Spec(
            options: ["--json", "--help", "--screen", "--name"], arguments: [.machine]),
        "ed machines workspace rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace rm": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.free]),
        "ed machines workspace panes": Spec(options: ["--json", "--help", "--workspace"]),
        "ed machines workspace split": Spec(
            options: ["--json", "--help", "--workspace", "--side", "--screen"],
            arguments: [.historyIndex, .machine]),
        "ed machines workspace close": Spec(
            options: ["--json", "--help", "--workspace"], arguments: [.historyIndex]),
        "ed machines workspace point": Spec(
            options: ["--json", "--help", "--workspace", "--screen"],
            arguments: [.historyIndex, .machine]),
        "ed machines workspace equalize": Spec(options: ["--json", "--help", "--workspace"]),
        "ed machines broadcast": Spec(options: ["--json", "--help", "--only"], arguments: [.free]),
        "ed machines terminal broadcast": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machineOrLocal, .free]),
        "ed machines kill": Spec(
            options: ["--json", "--help", "--signal", "--yes"],
            arguments: [.machine, .historyIndex], destructivePolicy: .previewThenYes),
        "ed machines metrics": Spec(
            options: ["--json", "-f", "--follow", "--interval", "--processes"],
            arguments: [.machine]),
        "ed machines exec": Spec(
            options: ["-t", "--tty"], arguments: [.machine, .free],
            passthroughCompletion: PassthroughCompletion(
                afterPositionals: 1, remoteMachinePosition: 0)),
        "ed machines files ls": Spec(
            options: ["--json", "--help", "-a", "--all"], arguments: [.machine, .remotePath]),
        "ed machines files get": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath, .localPath], destructivePolicy: .previewThenYes),
        "ed machines files preview": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files launch": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files get-many": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes", "--to"],
            optionValues: ["--to": .localPath], arguments: [.machine, .remotePath],
            repeatingArgument: .remotePath, destructivePolicy: .previewThenYes),
        "ed machines files transfer": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes", "--into"],
            optionValues: ["--into": .remotePath], arguments: [.machine, .machine, .remotePath],
            repeatingArgument: .remotePath, destructivePolicy: .previewThenYes),
        "ed machines files put": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .localPath, .remotePath], destructivePolicy: .previewThenYes),
        "ed machines files cp": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath], repeatingArgument: .remotePath,
            destructivePolicy: .previewThenYes),
        "ed machines files mv": Spec(
            options: ["--json", "--help", "--dry-run", "--replace", "--yes"],
            arguments: [.machine, .remotePath], repeatingArgument: .remotePath,
            destructivePolicy: .previewThenYes),
        "ed machines files rename": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files mkdir": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files search": Spec(
            options: ["--json", "--help", "--limit"], arguments: [.machine, .remotePath, .free]),
        "ed machines files info": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files undo": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines files duplicate": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .remotePath]),
        "ed machines files rm": Spec(
            options: ["--json", "--help", "--delete", "--yes"], arguments: [.machine, .remotePath],
            destructivePolicy: .previewThenYes),
        "ed machines docker shell": Spec(arguments: [.machine, .container]),
        "ed machines docker ps": Spec(options: ["--json", "-a", "--all"], arguments: [.machine]),
        "ed machines docker images": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker volumes": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker networks": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker df": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker logs": Spec(
            options: ["--tail", "-f", "--follow", "--json"], arguments: [.machine, .container]),
        "ed machines docker inspect": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .container]),
        "ed machines docker top": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .container]),
        "ed machines docker open": Spec(
            options: ["--json", "--help", "--port"], arguments: [.machine, .container]),
        "ed machines docker start": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker stop": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker restart": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker rm": Spec(
            options: ["--json", "--yes"], arguments: [.machine, .container],
            destructivePolicy: .previewThenYes),
        "ed machines docker pause": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker unpause": Spec(options: ["--json"], arguments: [.machine, .container]),
        "ed machines docker rmi": Spec(
            options: ["--json", "--help", "--force", "--yes"], arguments: [.machine, .free],
            destructivePolicy: .previewThenYes),
        "ed machines docker volume-rm": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .free],
            destructivePolicy: .previewThenYes),
        "ed machines docker prune": Spec(
            options: ["--json", "--help", "--yes"], arguments: [.machine, .pruneTarget],
            destructivePolicy: .previewThenYes),
        "ed machines docker compose ls": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
        "ed machines docker compose up": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose down": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose restart": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose pull": Spec(
            options: ["--json"], arguments: [.machine, .composeProject]),
        "ed machines docker compose logs": Spec(
            options: ["--tail", "-f", "--follow", "--help", "--json"],
            arguments: [.machine, .composeProject]),
        "ed machines services ls": Spec(options: ["--json", "--failed"], arguments: [.machine]),
        "ed machines services start": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines services stop": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines services restart": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine, .free]),
        "ed machines connect": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines disconnect": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines mount": Spec(
            options: ["--json", "--help", "--at", "--read-only"],
            arguments: [.machine, .remotePath]),
        "ed machines unmount": Spec(options: ["--json"], arguments: [.machine]),
        "ed machines mounts": Spec(options: ["--json", "-h", "--help", "--version"]),
        "ed machines mount-reveal": Spec(
            options: ["--json", "-h", "--help", "--version"], arguments: [.machine]),
    ]

    public static let root = node(for: MachinesCommand.self, path: ["ed", "machines"])

    public static let help = CommandNode(
        "help", "Show detailed help for a command.",
        arguments: specs["help"]?.arguments ?? [])

    public static var topLevelNames: [String] {
        root.children.flatMap(\.names) + help.names
    }

    public static func node(at path: [String]) -> CommandNode? {
        var current = root
        for name in path {
            guard let next = current.child(name) else { return nil }
            current = next
        }
        return current
    }

    static func node(for command: ParsableCommand.Type, path: [String]) -> CommandNode {
        let configuration = command.configuration
        let spec = specs[path.joined(separator: " ")] ?? Spec()
        let children = configuration.subcommands.filter { $0.configuration.shouldDisplay }
            .map { child in
                let name =
                    child.configuration.commandName ?? String(describing: child).lowercased()
                return node(for: child, path: path + [name])
            }
        return CommandNode(
            path.last ?? "ed", configuration.abstract, aliases: configuration.aliases,
            options: spec.options, optionValues: spec.optionValues, arguments: spec.arguments,
            repeatingArgument: spec.repeatingArgument, children: children,
            destructivePolicy: spec.destructivePolicy,
            passthroughCompletion: spec.passthroughCompletion)
    }
}
