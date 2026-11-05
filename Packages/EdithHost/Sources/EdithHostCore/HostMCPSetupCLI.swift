import EdithExtensionSupport
import Foundation

public struct HostMCPSetupCLI: Sendable {
    private let home: URL
    private let executable: URL
    private let codexHome: String?

    public init(
        home: URL, executable: URL,
        codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]
    ) {
        self.home = home; self.executable = executable; self.codexHome = codexHome
    }

    public func execute(_ arguments: [String]) throws -> ExtensionCLIReply {
        guard let action = arguments.first else {
            throw HostCLIError.usage("Run ed mcp install --client <name> or ed mcp status.")
        }
        let args = try HostCLIArguments(
            Array(arguments.dropFirst()), flags: ["--json", "--dry-run"],
            options: ["--client", "--command"])
        switch action {
        case "status":
            try args.require(words: 0...0, flags: ["--json"], options: ["--command"])
            return try status(args)
        case "install":
            try args.require(
                words: 0...0, flags: ["--json", "--dry-run"], options: ["--client", "--command"])
            return try install(args)
        default:
            throw HostCLIError.usage("Unknown mcp command. Use install or status.")
        }
    }

    private func installer(_ args: HostCLIArguments) throws -> (HostMCPInstaller, String) {
        let command = args.options["--command"] ?? executable.path
        guard command.hasPrefix("/"), !command.contains("\n") else {
            throw HostCLIError.usage("--command must be an absolute path.")
        }
        return (HostMCPInstaller(home: home, command: command, codexHome: codexHome), command)
    }

    private func status(_ args: HostCLIArguments) throws -> ExtensionCLIReply {
        let (installer, command) = try installer(args)
        let reports = installer.status()
        if args.flags.contains("--json") {
            return try HostCLIOutput.json(
                .object([
                    "command": .string(command),
                    "clients": .array(
                        reports.map {
                            .object([
                                "client": .string($0.client.rawValue),
                                "title": .string($0.client.title),
                                "path": .string($0.path),
                                "configExists": .bool($0.exists),
                                "state": .string($0.state.rawValue),
                                "command": $0.command.map(HostCLIJSON.string) ?? .null,
                            ])
                        }),
                ]))
        }
        let rows = reports.map {
            [$0.client.rawValue, Self.label($0.state), $0.path]
        }
        let table = HostCLIOutput.table(headers: ["CLIENT", "STATE", "CONFIG"], rows: rows)
        let hint =
            reports.allSatisfy { $0.state == .registered }
            ? "Edith's MCP server is registered everywhere."
            : "Run ed mcp install --client <claude|codex|cursor|vscode|all> to register it."
        return try HostCLIOutput.text(table + "\n\n" + hint)
    }

    private func install(_ args: HostCLIArguments) throws -> ExtensionCLIReply {
        guard let name = args.options["--client"] else {
            throw HostCLIError.usage("Pass --client claude|codex|cursor|vscode|all.")
        }
        let clients: [HostMCPClient]
        if name == "all" {
            clients = HostMCPClient.allCases
        } else if let client = HostMCPClient(rawValue: name) {
            clients = [client]
        } else {
            throw HostCLIError.usage("Unknown client. Use claude, codex, cursor, vscode or all.")
        }
        let dryRun = args.flags.contains("--dry-run")
        let (installer, command) = try installer(args)
        let outcomes = clients.map { installer.install($0, dryRun: dryRun) }
        let failed = outcomes.contains { $0.action == .skipped }
        if args.flags.contains("--json") {
            let value = HostCLIJSON.object([
                "command": .string(command), "dryRun": .bool(dryRun),
                "clients": .array(
                    outcomes.map {
                        .object([
                            "client": .string($0.client.rawValue),
                            "path": .string($0.path),
                            "action": .string($0.action.rawValue),
                            "applied": .bool($0.applied),
                            "snippet": .string($0.snippet),
                            "note": $0.note.map(HostCLIJSON.string) ?? .null,
                            "backup": $0.backup.map(HostCLIJSON.string) ?? .null,
                        ])
                    }),
            ])
            return try ExtensionCLIReply(
                stdout: String(decoding: try value.encoded(), as: UTF8.self) + "\n", stderr: "",
                exitCode: failed ? 1 : 0)
        }
        var out: [String] = []
        var err: [String] = []
        for outcome in outcomes {
            out.append(Self.describe(outcome, dryRun: dryRun))
            if outcome.action == .skipped {
                err.append("error: \(outcome.client.title): \(outcome.note ?? "not written")")
            }
        }
        return try ExtensionCLIReply(
            stdout: out.joined(separator: "\n") + "\n",
            stderr: err.isEmpty ? "" : err.joined(separator: "\n") + "\n",
            exitCode: failed ? 1 : 0)
    }

    private static func label(_ state: HostMCPInstaller.State) -> String {
        switch state {
        case .registered: "registered"
        case .outdated: "registered, different command"
        case .notRegistered: "not registered"
        case .unreadable: "config not readable"
        }
    }

    private static func describe(_ outcome: HostMCPInstaller.Outcome, dryRun: Bool) -> String {
        let title = outcome.client.title
        switch outcome.action {
        case .unchanged:
            return "\(title): already registered in \(outcome.path)"
        case .created, .updated:
            let verb = outcome.action == .created ? "add" : "update"
            if dryRun {
                return
                    "\(title): would \(verb) Edith in \(outcome.path), nothing was written. Entry:\n\n\(outcome.snippet)"
            }
            let backup = outcome.backup.map { "\nprevious file saved as \($0)" } ?? ""
            return
                "\(title): \(outcome.action == .created ? "added" : "updated") Edith in \(outcome.path)\(backup)\nrestart \(title) to load it"
        case .skipped:
            return
                "\(title): not written. Add this to \(outcome.path) yourself:\n\n\(outcome.snippet)"
        }
    }
}
