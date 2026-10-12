import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum PresenterCLIEnvironment {
    static var defaults = SharedDefaults.store
    static var perform: (PresenterRuntimeOperation) -> PresenterRuntimeSnapshot = { operation in
        PresenterRuntimeOperationExecution.perform(operation, post: { _ in })
    }
}

@MainActor enum PresenterCLIExecution {
    static func help(_ request: ExtensionCLIRequest) async throws -> ExtensionCLIReply? {
        try request.validate()
        guard ["--help", "-h"].contains(request.arguments.last ?? "") else { return nil }
        guard
            let document = try JSONSerialization.jsonObject(
                with: Data(PresenterCommand._dumpHelp().utf8)) as? [String: Any],
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
        return try await ExtensionCLIExecution.run(PresenterCommand.self, request: request)
    }

    static func catalog(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8),
            let help = try JSONSerialization.jsonObject(
                with: Data(PresenterCommand._dumpHelp().utf8))
                as? [String: Any],
            let root = help["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        var commands: [[String: Any]] = []
        func append(_ command: [String: Any], prefix: [String]) throws {
            guard let name = command["commandName"] as? String,
                !name.isEmpty, name.utf8.count <= 80, prefix.count < 12,
                let summary = command["abstract"] as? String, !summary.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [name]
            guard route.first == "presenter" else { throw ExtensionPeerError.invalidRequest }
            if !route.isEmpty {
                let entry: [String: Any] = [
                    "route": route, "operation": "presenter.cli", "summary": summary,
                    "destructive": Set<String>(["start", "stop"]).contains(name), "timeout": 30,
                    "readsInput": false, "jsonOutput": false,
                ]
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
                "version": 1, "owner": "presenter", "commands": commands,
                "settings": [], "acceptsInput": false, "parserHelp": [help],
            ], options: [.sortedKeys])
    }

    static func run(
        _ request: ExtensionCLIRequest, defaults: UserDefaults,
        perform: @escaping (PresenterRuntimeOperation) -> PresenterRuntimeSnapshot
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let oldDefaults = PresenterCLIEnvironment.defaults
        let oldPerform = PresenterCLIEnvironment.perform
        PresenterCLIEnvironment.defaults = defaults
        PresenterCLIEnvironment.perform = perform
        defer {
            PresenterCLIEnvironment.defaults = oldDefaults
            PresenterCLIEnvironment.perform = oldPerform
        }
        return try await ExtensionCLIExecution.run(
            PresenterCommand.self, request: request)
    }
}
