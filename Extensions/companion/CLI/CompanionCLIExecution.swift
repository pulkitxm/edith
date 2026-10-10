import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum CompanionCLIEnvironment {
    static var input = Data()
    static var stopGenerations: () -> Int = { CompanionGeneration.stopAll() }
}
struct CompanionCLIInput: Decodable { var input: Data? }
@MainActor enum CompanionCLIExecution {
    private static var chats: [UUID: (String, Task<ExtensionCLIReply, Error>)] = [:]
    static func stopChats() -> [String] {
        let active = chats; for (_, task) in active.values { task.cancel() };
        return active.values.map { $0.0 }
    }
    static func run(_ request: ExtensionCLIRequest, input: Data = Data()) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard input.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        let old = CompanionCLIEnvironment.input
        CompanionCLIEnvironment.input = input
        defer { CompanionCLIEnvironment.input = old }
        let task = Task {
            try await ExtensionCLIExecution.run(CompanionCommand.self, arguments: request.arguments)
        }
        let id = UUID()
        if request.arguments.first == "chat" {
            chats[id] = (request.arguments.joined(separator: " "), task)
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
extension String { func expandingTilde() -> String { (self as NSString).expandingTildeInPath } }
