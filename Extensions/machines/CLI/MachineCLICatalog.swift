import ArgumentParser
import Foundation

enum MachineCLICatalog {
    private struct Command: Encodable {
        let route: [String]
        let operation = "machines.cli"
        let summary: String
        let destructive: Bool
        let timeout = 30
        let streamOperation = "machines.cli.stream"
        let streamDeadline = 21_600
    }

    private struct Catalog: Encodable {
        let version = 1
        let owner = "machines"
        let commands: [Command]
        let settings: [String] = []
        let acceptsInput = true
        let completionOperation = "machines.cli.complete"
        let machineAliases: [String]
        let aliasOperation = "machines.cli"
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
                        destructive: route.contains(where: mutationNames.contains)))
                for child in configuration.subcommands { append(child, prefix: route) }
            }
        }
        append(MachinesCommand.self, prefix: [])
        let aliases = Array(
            Set(MachineDirectory.names(from: MachineDirectory.load()).filter(validAlias))
        ).sorted().prefix(128)
        return try JSONEncoder().encode(Catalog(commands: commands, machineAliases: Array(aliases)))
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

    static func complete(_ data: Data) throws -> Data {
        let request = try JSONDecoder().decode(CompletionRequest.self, from: data)
        guard request.words.count <= 128, (0...request.words.count).contains(request.index),
            request.words.allSatisfy({ $0.utf8.count <= 4_096 && !$0.utf8.contains(0) })
        else { throw MachineUIError.invalidRequest }
        let prefix = request.index < request.words.count ? request.words[request.index] : ""
        var words = Array(request.words.prefix(request.index))
        if words.first == "ed" { words.removeFirst() }
        if words.first == "machines" { words.removeFirst() }
        let names = MachineDirectory.names(from: MachineDirectory.load())
        var node = MachineCLIArguments(MachinesCommand.self)
        var candidates: [String] = []
        for word in words {
            if let child = node.child(word) {
                node = child
            } else if !names.contains(word) {
                candidates = []; break
            }
        }
        candidates += node.children.flatMap { [$0.name] + $0.aliases }
        if !words.contains(where: names.contains) { candidates += names }
        let wantsFiles =
            ["upload", "download", "mount"].contains(node.name)
            || ["--to", "--at"].contains(words.last ?? "")
        return try JSONEncoder().encode(
            CompletionReply(
                candidates: Array(Set(candidates.filter { $0.hasPrefix(prefix) })).sorted(),
                wantsFiles: wantsFiles))
    }
}
