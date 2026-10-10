import EdithExtensionCommands
import ArgumentParser
import Foundation

enum MachineCLICatalog {
    private struct Command: Encodable {
        let route: [String]
        let operation = "machines.cli"
        let summary: String
        let destructive: Bool
        let timeout = 30
        let readsInput: Bool
        let streamOperation = "machines.cli.stream"
        let streamDeadline = 21_600
    }

    private struct Catalog: Encodable {
        let version = 1
        let owner = "machines"
        let commands: [Command]
        let settings: [Setting]
        let parserHelp: [ParserDocument]
        let configOperation = "machines.config.cli"
        let acceptsInput = true
        let completionOperation = "machines.cli.complete"
        let machineAliases: [String]
        let aliasOperation = "machines.cli"
    }

    private struct Setting: Encodable {
        let key: String
        let type: String
        let group: String
        let summary: String
        let scope: String
        let allowed: [String]
        let minimum: Int?
        let maximum: Int?
        let fallback: ParserDocument
        let readOnly: Bool
        init(_ value: SettingDefinition) throws {
            key = value.key; type = value.type.rawValue; group = value.group;
            summary = value.summary
            scope = value.scope.rawValue; allowed = value.allowed;
            minimum = value.integerRange?.lowerBound
            maximum = value.integerRange?.upperBound; readOnly = value.readOnly
            fallback = try JSONDecoder().decode(
                ParserDocument.self, from: Data(JSONSerializer.string(value.fallback).utf8))
        }
    }

    private enum ParserDocument: Codable {
        case null, bool(Bool), number(Double), string(String), array([Self]), object([String: Self])
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if value.decodeNil() {
                self = .null
            } else if let result = try? value.decode(Bool.self) {
                self = .bool(result)
            } else if let result = try? value.decode(Double.self) {
                self = .number(result)
            } else if let result = try? value.decode(String.self) {
                self = .string(result)
            } else if let result = try? value.decode([Self].self) {
                self = .array(result)
            } else {
                self = .object(try value.decode([String: Self].self))
            }
        }
        func encode(to encoder: Encoder) throws {
            var value = encoder.singleValueContainer()
            switch self {
            case .null: try value.encodeNil()
            case .bool(let result): try value.encode(result)
            case .number(let result): try value.encode(result)
            case .string(let result): try value.encode(result)
            case .array(let result): try value.encode(result)
            case .object(let result): try value.encode(result)
            }
        }
    }

    private static let mutationNames: Set<String> = [
        "add", "edit", "rm", "remove", "exec", "run", "kill", "broadcast", "connect",
        "disconnect", "mount", "unmount", "upload", "download", "rename", "mkdir", "trash",
        "delete", "duplicate", "undo", "start", "stop", "restart", "reboot", "shutdown", "sleep",
        "wake", "set", "new", "close", "move", "split", "equalize", "open", "shell", "pull",
        "prune", "pause", "unpause", "switch", "put", "get", "get-many", "transfer", "cp", "mv",
    ]

    static func encoded() throws -> Data {
        var commands: [Command] = []
        func append(_ type: ParsableCommand.Type, prefix: [String]) {
            let configuration = type.configuration
            let name = configuration.commandName ?? type._commandName
            for word in [name] + configuration.aliases {
                let route = prefix + [word]
                commands.append(
                    Command(
                        route: route,
                        summary: configuration.abstract.isEmpty ? name : configuration.abstract,
                        destructive: route.contains(where: mutationNames.contains),
                        readsInput: [
                            "exec", "run", "shell", "add", "edit", "put", "upload", "write",
                        ]
                        .contains(name)))
                for child in configuration.subcommands { append(child, prefix: route) }
            }
        }
        append(MachinesCommand.self, prefix: [])
        let aliases = Array(
            Set(MachineDirectory.names(from: MachineDirectory.load()).filter(validAlias))
        ).sorted().prefix(128)
        return try JSONEncoder().encode(
            Catalog(
                commands: commands, settings: try ConfigCatalog.settings.map(Setting.init),
                parserHelp: [
                    try JSONDecoder().decode(
                        ParserDocument.self, from: Data(MachinesCommand._dumpHelp().utf8))
                ], machineAliases: Array(aliases)))
    }

    private static func validAlias(_ value: String) -> Bool {
        let reserved: Set<String> = [
            "guide", "schema", "version", "status", "completions", "install", "uninstall", "config",
            "app", "permissions", "extensions", "invoke", "mcp",
            "machines", "calendar", "music", "usage", "herdr", "quinjet", "studio", "database",
            "docs", "latex", "companion", "bifrost", "skills", "download", "seo", "code-stats",
            "clipboard", "attention", "shelf", "browser", "color", "emoji", "presenter",
            "lid-awake", "system", "apps", "tools", "stats", "brew", "cleaner", "maintenance",
            "jev", "camera", "audio",
        ]
        return !value.isEmpty && value.utf8.count <= 80 && !reserved.contains(value.lowercased())
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46, 95].contains($0)
            }
    }

    private struct CompletionRequest: Decodable {
        let words: [String]
        let index: Int
    }

    private struct CompletionReply: Encodable {
        let candidates: [String]
        let wantsFiles: Bool
    }

    @MainActor static func complete(_ data: Data, session: (UUID) -> MachineSession) async throws
        -> Data
    {
        let request = try JSONDecoder().decode(CompletionRequest.self, from: data)
        guard request.words.count <= 128, (0...request.words.count).contains(request.index),
            request.words.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else { throw MachineUIError.invalidRequest }
        let machines = MachineDirectory.load()
        let plan = CompletionEngine.plan(
            .init(words: request.words, index: request.index),
            machines: MachineDirectory.names(from: machines))
        let candidates: [String]
        if let query = plan.remoteMachine, let remote = plan.remoteRequest,
            let machine = try? MachineDirectory.resolve(query, in: machines)
        {
            candidates = await RemoteCompletion.candidates(
                machine: machine, request: remote, session: session(machine.id))
        } else {
            candidates = plan.candidates
        }
        return try JSONEncoder().encode(
            CompletionReply(candidates: candidates, wantsFiles: plan.wantsFiles))
    }
}
