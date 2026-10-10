import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CompanionCLIEnvironment {
    static var input: Data { ExtensionCLIContext.request?.standardInput ?? Data() }
    static var stopGenerations: () -> Int = { CompanionGeneration.stopAll() }
}
@MainActor enum CompanionCLIExecution {
    private static var streamingChats:
        [UUID: (String, ExtensionCLIStreamHandle, ExtensionCLIStreams)] = [:]
    private static var chats: [UUID: (String, Task<ExtensionCLIReply, Error>)] = [:]
    static func stopChats() -> [String] {
        let active = chats; for (_, task) in active.values { task.cancel() };
        let streamed = streamingChats; streamingChats.removeAll()
        for (_, handle, streams) in streamed.values { try? streams.cancel(handle) }
        return active.values.map { $0.0 } + streamed.values.map { $0.0 }
    }
    static func stream(_ streams: ExtensionCLIStreams, operation: String, payload: Data) throws
        -> Data
    {
        let result = try streams.invoke(
            CompanionCommand.self, operation: operation, prefix: "companion.cli", payload: payload)
        if operation == "companion.cli.start" {
            let request = try JSONDecoder().decode(ExtensionCLIStreamStart.self, from: payload)
            if request.request.arguments.first == "chat" {
                let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: result)
                let parsed =
                    try? CompanionCommand.parseAsRoot(request.request.arguments)
                    as? CompanionChatCommand
                streamingChats[handle.token] = (parsed?.conversation ?? "new", handle, streams)
            }
        } else if operation == "companion.cli.read" {
            let frame = try JSONDecoder().decode(ExtensionCLIStreamFrame.self, from: result)
            if frame.state != .running { streamingChats[frame.handle.token] = nil }
        } else if ["companion.cli.end", "companion.cli.cancel"].contains(operation) {
            let handle = try JSONDecoder().decode(ExtensionCLIStreamHandle.self, from: payload)
            streamingChats[handle.token] = nil
        }
        return result
    }

    static func run(_ request: ExtensionCLIRequest) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        if request.arguments.first == "stop" {
            return try ExtensionCLIContext.$request.withValue(request) {
                try CompanionStopCommand.reply(request.arguments)
            }
        }
        let task = Task {
            try await ExtensionCLIExecution.run(CompanionCommand.self, request: request)
        }
        let id = UUID()
        if request.arguments.first == "chat" {
            let parsed =
                try? CompanionCommand.parseAsRoot(request.arguments) as? CompanionChatCommand
            chats[id] = (parsed?.conversation ?? "new", task)
        }
        defer { chats[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
@MainActor enum CompanionHostProbing {
    static func hosts(only name: String?) async -> [CompanionHost] {
        let hosts = await CompanionHosts.all(deployment: CompanionDeploymentStore.load())
        guard let name else { return hosts }
        let query = name.lowercased()
        return hosts.filter {
            $0.name.lowercased().hasPrefix(query) || $0.target.lowercased().contains(query)
                || $0.id.uuidString.lowercased() == query
                || ($0.isLocal && ["local", "this mac"].contains(query))
        }
    }
}

@MainActor enum CompanionStackRunner {
    static func requireDeployment() throws -> CompanionDeployment {
        guard let deployment = CompanionDeploymentStore.load() else {
            throw CLIFailure.notFound(
                "the companion stack is not deployed anywhere",
                hint: "run `ed companion hosts` to see where it could run")
        }
        return deployment
    }
    static func run(
        _ command: String, on deployment: CompanionDeployment, stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> String {
        try await CompanionStackControl.run(command, on: deployment, stdin: stdin, timeout: timeout)
    }
    static func services(_ deployment: CompanionDeployment) async -> [CompanionServiceStatus] {
        await CompanionStackControl.services(deployment)
    }
    static func report(
        _ deployment: CompanionDeployment, json: Bool, verb: String, plan: CLIDestructivePlan? = nil
    ) async throws {
        let services = await services(deployment)
        let serviceJSON = services.map {
            JSONValue.object([
                "service": .string($0.service), "status": .string($0.status),
                "running": .bool($0.running),
            ])
        }
        let running = services.filter(\.running).count
        if let plan {
            plan.finish(
                changed: true,
                plain: "\(verb) on \(deployment.machineName), \(running) of \(services.count) up",
                fields: ["services": .array(serviceJSON)]);
            return
        }
        if json {
            CLIOut.json(
                .object([
                    "deployment": CompanionHostsCommand.deploymentJSON(deployment),
                    "services": .array(serviceJSON),
                ]));
            return
        }
        CLIOut.out("\(verb) on \(deployment.machineName), \(running) of \(services.count) up")
    }
}
extension String {
    func companionCLIPath() throws -> URL {
        try ExtensionCLIContext.resolvePath((self as NSString).expandingTildeInPath)
    }
}
