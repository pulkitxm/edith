import ArgumentParser
import Darwin
import DatabaseCore
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct DatabaseCLIResources: Sendable {
    let sender: any DatabaseBrokerCommandSending
    let credentials: @Sendable () throws -> any DatabaseSecretStore
    let runMCP: @Sendable () async throws -> Void
}

enum DatabaseCLIEnvironment {
    @TaskLocal static var resources: DatabaseCLIResources?

    static func makeSender() -> any DatabaseBrokerCommandSending {
        resources?.sender ?? DatabaseUnavailableCLISender()
    }

    static func makeSecretStore() throws -> any DatabaseSecretStore {
        guard let resources else { throw ExtensionPeerError.unavailable }
        return try resources.credentials()
    }

    static func runMCPServer() async throws {
        guard let resources else { throw ExtensionPeerError.unavailable }
        try await resources.runMCP()
    }

    static func readPassword() throws -> String {
        let value = try readQueryText(nil).trimmingCharacters(in: .newlines)
        guard !value.isEmpty, !value.utf8.contains(0),
            value.utf8.count <= DatabaseSecretStorageLimits.defaultMaximumBytes
        else { throw CLIFailure.usage("database password input must contain a bounded secret") }
        return value
    }

    static func readQueryText(_ path: String?) throws -> String {
        guard let request = ExtensionCLIContext.request else {
            throw ExtensionPeerError.unavailable
        }
        let data: Data
        if let path {
            let url = try ExtensionCLIContext.resolvePath(path)
            let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw CLIFailure.usage("database query file could not be opened")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                status.st_mode & S_IFMT == S_IFREG,
                status.st_size <= ExtensionCLIRequest.maximumInputBytes
            else { throw CLIFailure.usage("database query input must be a bounded regular file") }
            data = try handle.read(upToCount: ExtensionCLIRequest.maximumInputBytes + 1) ?? Data()
        } else {
            data = request.standardInput
        }
        guard data.count <= ExtensionCLIRequest.maximumInputBytes,
            let text = String(data: data, encoding: .utf8)
        else { throw CLIFailure.usage("database query input must be bounded UTF-8") }
        return text
    }
}

@MainActor enum DatabaseCLIExecution {
    static func catalog(_ payload: Data) throws -> Data {
        guard payload == Data("{}".utf8),
            var help = try JSONSerialization.jsonObject(
                with: Data(DatabaseCommand._dumpHelp().utf8))
                as? [String: Any], var root = help["command"] as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        root["subcommands"] = (root["subcommands"] as? [[String: Any]] ?? []).filter {
            $0["commandName"] as? String != "help"
        }
        help["command"] = root
        var commands: [[String: Any]] = []
        func append(_ command: [String: Any], prefix: [String]) throws {
            guard let name = command["commandName"] as? String, !name.isEmpty,
                name.utf8.count <= 80, prefix.count < 12,
                let summary = command["abstract"] as? String, !summary.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            let route = prefix + [name]
            guard route.first == "database" else { throw ExtensionPeerError.invalidRequest }
            if route.count >= 2 {
                let input =
                    route.contains("query") || route.contains("mutations")
                    || route.contains("mcp") || name == "add" || name == "save"
                commands.append([
                    "route": route, "operation": "database.cli", "summary": summary,
                    "destructive": [
                        "add", "edit", "save", "rename", "duplicate", "delete",
                        "apply", "cancel", "remove", "install",
                    ].contains(name),
                    "timeout": 120, "readsInput": input, "jsonOutput": name != "mcp",
                    "streamOperation": "database.cli.stream", "streamDeadline": 21_600,
                ])
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
                "version": 1, "owner": "database", "commands": commands, "settings": [],
                "acceptsInput": true, "parserHelp": [help],
            ], options: [.sortedKeys])
    }

    static func run(
        _ request: ExtensionCLIRequest, sender: any DatabaseBrokerCommandSending,
        credentials: @escaping @Sendable () throws -> any DatabaseSecretStore,
        runMCP: @escaping @Sendable () async throws -> Void = {
            try await DatabaseCLIMCP.run()
        }
    ) async throws -> ExtensionCLIReply {
        try await DatabaseCLIEnvironment.$resources.withValue(
            DatabaseCLIResources(sender: sender, credentials: credentials, runMCP: runMCP)
        ) {
            try await ExtensionCLIExecution.run(DatabaseCommand.self, request: request)
        }
    }
}

private struct DatabaseUnavailableCLISender: DatabaseBrokerCommandSending {
    func send(_ request: DatabaseBrokerCommandRequest) async throws
        -> DatabaseBrokerCommandResponse
    {
        throw DatabaseBrokerCommandClientError.unavailable
    }
}
