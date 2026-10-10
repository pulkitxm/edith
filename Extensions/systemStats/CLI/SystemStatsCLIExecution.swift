import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SystemStatsCLIEnvironment {
    static var makeSampler: () -> any SystemStatsSampling = { LocalMachineSampler() }
}

@MainActor enum SystemStatsCLIExecution {
    static func help(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply? {
        try request.validate()
        guard ["--help", "-h"].contains(request.arguments.last ?? "") else { return nil }
        guard
            let document = try JSONSerialization.jsonObject(
                with: Data(SystemCommand._dumpHelp().utf8)) as? [String: Any],
            var command = document["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        for name in request.arguments.dropLast() {
            guard
                let child = (command["subcommands"] as? [[String: Any]] ?? []).first(where: {
                    $0["commandName"] as? String == name
                        || ($0["aliases"] as? [String] ?? []).contains(name)
                })
            else { throw ExtensionPeerError.invalidRequest }
            command = child
        }
        return try await ExtensionCLIExecution.run(SystemCommand.self, request: request)
    }

    static func catalog(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8),
            var help = try JSONSerialization.jsonObject(with: Data(SystemCommand._dumpHelp().utf8))
                as? [String: Any],
            var root = help["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        root["subcommands"] = (root["subcommands"] as? [[String: Any]] ?? []).filter {
            $0["commandName"] as? String != "help"
        }
        help["command"] = root
        var commands: [[String: Any]] = []
        func append(_ command: [String: Any], prefix: [String]) throws {
            guard let name = command["commandName"] as? String,
                !name.isEmpty, name.utf8.count <= 80, prefix.count < 12,
                let summary = command["abstract"] as? String, !summary.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [name]
            guard route.first == "system" else { throw ExtensionPeerError.invalidRequest }
            if route.count >= 2 {
                var entry: [String: Any] = [
                    "route": route, "operation": "systemStats.cli", "summary": summary,
                    "destructive": Set<String>([]).contains(name), "timeout": 30,
                    "readsInput": false, "jsonOutput": false,
                ]
                if route == ["system", "stats"] {
                    entry["streamOperation"] = "systemStats.cli.stream"
                    entry["streamDeadline"] = 1_800
                }
                commands.append(entry)
            }
            for child in command["subcommands"] as? [[String: Any]] ?? [] {
                try append(child, prefix: route)
            }
        }
        try append(root, prefix: [])
        guard !commands.isEmpty, commands.count <= 128 else {
            throw ExtensionPeerError.invalidRequest
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "version": 1, "owner": "systemStats", "commands": commands,
                "settings": [], "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys])
    }

    static func run(
        _ request: ExtensionCLIRequest,
        makeSampler: @escaping () -> any SystemStatsSampling = { LocalMachineSampler() }
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previous = SystemStatsCLIEnvironment.makeSampler
        SystemStatsCLIEnvironment.makeSampler = makeSampler
        defer { SystemStatsCLIEnvironment.makeSampler = previous }
        return try await ExtensionCLIExecution.run(SystemCommand.self, request: request)
    }
}
