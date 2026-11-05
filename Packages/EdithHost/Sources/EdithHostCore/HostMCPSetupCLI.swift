import EdithExtensionSupport
import Foundation

public struct HostMCPSetupCLI: Sendable {
    private let home: URL
    private let executable: URL
    private let codexHome: String?
    private let tools: HostMCPToolRunner

    public init(
        home: URL, executable: URL,
        codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"],
        tools: HostMCPToolRunner
    ) {
        self.home = home; self.executable = executable; self.codexHome = codexHome
        self.tools = tools
    }

    private static let clientNames = "claude, codex, cursor, vscode or all"

    public func execute(_ arguments: [String]) throws -> ExtensionCLIReply {
        guard let action = arguments.first else {
            throw HostCLIError.usage(
                "Run ed mcp install --client <name> to register Edith, or ed mcp status.")
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
            throw HostCLIError.usage(
                "Unknown mcp command \(action). Use ed mcp install or ed mcp status; ed mcp alone serves MCP over stdio."
            )
        }
    }

    private func installer(_ args: HostCLIArguments) throws -> (HostMCPInstaller, String) {
        let command = args.options["--command"] ?? executable.path
        guard command.hasPrefix("/"), !command.contains("\n") else {
            throw HostCLIError.usage("--command must be an absolute path to an ed executable.")
        }
        return (
            HostMCPInstaller(home: home, command: command, codexHome: codexHome, tools: tools),
            command
        )
    }

    private func display(_ path: String) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
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
                                "clientFound": .bool($0.clientFound),
                                "state": .string($0.state.rawValue),
                                "command": $0.command.map(HostCLIJSON.string) ?? .null,
                            ])
                        }),
                ]))
        }
        let rows = reports.map { [$0.client.rawValue, Self.label($0), display($0.path)] }
        let table = HostCLIOutput.table(headers: ["CLIENT", "STATE", "CONFIG"], rows: rows)
        let pending = reports.filter { $0.clientFound && $0.state != .registered }
        let hint: String
        if pending.count == 1 {
            hint = "Run ed mcp install --client \(pending[0].client.rawValue) to register Edith."
        } else if pending.count > 1 {
            hint = "Run ed mcp install --client all to register Edith with every client found."
        } else if reports.contains(where: { $0.state == .registered }) {
            hint = "Edith is registered with every agent client found on this Mac."
        } else {
            hint =
                "No agent client was found on this Mac. Install one, or run ed mcp install --client <name> --dry-run to see the entry."
        }
        return try HostCLIOutput.text(table + "\n\n" + hint)
    }

    private func install(_ args: HostCLIArguments) throws -> ExtensionCLIReply {
        guard let name = args.options["--client"] else {
            throw HostCLIError.usage("Pass --client with \(Self.clientNames).")
        }
        let clients: [HostMCPClient]
        if name == "all" {
            clients = HostMCPClient.allCases
        } else if let client = HostMCPClient(rawValue: name.lowercased()) {
            clients = [client]
        } else {
            throw HostCLIError.usage("Unknown client \(name). Use \(Self.clientNames).")
        }
        let dryRun = args.flags.contains("--dry-run")
        let explicit = name != "all"
        let (installer, command) = try installer(args)
        let outcomes = clients.map {
            installer.install($0, dryRun: dryRun, onlyIfPresent: !explicit)
        }
        let failed = outcomes.contains {
            $0.action == .skipped || explicit && $0.action == .manual
        }
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
                            "run": $0.run.map(HostCLIJSON.strings) ?? .null,
                            "note": $0.note.map(HostCLIJSON.string) ?? .null,
                            "backup": $0.backup.map(HostCLIJSON.string) ?? .null,
                        ])
                    }),
            ])
            return try ExtensionCLIReply(
                stdout: String(decoding: try value.encoded(), as: UTF8.self) + "\n", stderr: "",
                exitCode: failed ? 1 : 0)
        }
        var out = outcomes.map { describe($0, dryRun: dryRun) }
        let restart = outcomes.filter { $0.applied }.map(\.client.title)
        if dryRun, outcomes.contains(where: { [.created, .updated].contains($0.action) }) {
            out.append("Nothing was written. Run the same command without --dry-run to apply.")
        } else if !restart.isEmpty {
            out.append(
                "Restart \(Self.list(restart)) to load Edith, then ask the agent to call edith_catalog."
            )
        } else if outcomes.contains(where: { $0.action == .unchanged }),
            outcomes.allSatisfy({ [.unchanged, .notFound].contains($0.action) })
        {
            out.append("Nothing to change. Ask the agent to call edith_catalog to get started.")
        } else if outcomes.allSatisfy({ $0.action == .notFound }) {
            out.append(
                "No agent client was found on this Mac. Pass --client <name> to write an entry anyway."
            )
        }
        let err = outcomes.filter { $0.action == .skipped }.map {
            "error: \($0.client.title): \($0.note ?? "not written")\n"
        }
        return try ExtensionCLIReply(
            stdout: out.joined(separator: "\n\n") + "\n", stderr: err.joined(),
            exitCode: failed ? 1 : 0)
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    private static func label(_ report: HostMCPInstaller.Report) -> String {
        switch report.state {
        case .registered: "registered"
        case .outdated: "registered, different command"
        case .notRegistered: report.clientFound ? "not registered" : "client not found"
        case .unreadable: "config not readable"
        }
    }

    private func describe(_ outcome: HostMCPInstaller.Outcome, dryRun: Bool) -> String {
        let title = outcome.client.title
        let path = display(outcome.path)
        switch outcome.action {
        case .unchanged:
            return "\(title): already registered in \(path)"
        case .notFound:
            return "\(title): not found on this Mac, skipped"
        case .manual:
            return
                "\(title): \(outcome.note ?? "not registered.") Once \(title) is installed, run:\n  \(outcome.runLine ?? "")"
        case .created, .updated:
            let added = outcome.action == .created
            if let run = outcome.runLine {
                return dryRun
                    ? "\(title): would run\n  \(run)"
                    : "\(title): \(added ? "added" : "updated") Edith with\n  \(run)"
            }
            let entry = outcome.snippet.trimmingCharacters(in: .newlines)
            if dryRun {
                return
                    "\(title): would \(added ? "add Edith to" : "update Edith in") \(path):\n\n\(entry)"
            }
            let backup = outcome.backup.map { ", previous file saved as \(display($0))" } ?? ""
            return "\(title): \(added ? "added Edith to" : "updated Edith in") \(path)\(backup)"
        case .skipped:
            if let run = outcome.runLine, outcome.client.registrationTool != nil,
                !outcome.client.editsFileWithoutTool
            {
                return "\(title): not registered. Run it yourself:\n  \(run)"
            }
            return
                "\(title): not written. Add this to \(path) yourself:\n\n\(outcome.snippet.trimmingCharacters(in: .newlines))"
        }
    }
}
