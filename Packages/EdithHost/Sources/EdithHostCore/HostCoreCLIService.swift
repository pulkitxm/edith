import EdithExtensionSupport
import Foundation

public struct HostCoreCLIEnvelope: Codable, Sendable {
    public let arguments: [String]
    public let input: Data
    public init(arguments: [String], input: Data = Data()) throws {
        _ = try ExtensionCLIRequest(arguments: arguments)
        guard input.count <= HostCLIInvocationContext.maximumInputBytes else {
            throw HostCLIError.usage("Input exceeds 4 MiB.")
        }
        self.arguments = arguments; self.input = input
    }
    public func validate() throws { _ = try Self(arguments: arguments, input: input) }
    public func request() throws -> HostCLIRequest {
        try validate()
        return try HostCLIRequest(
            action: .invoke, id: "host", operation: "host.cli", payload: JSONEncoder().encode(self))
    }
}

@MainActor public final class HostCoreCLIService {
    public typealias Action = @MainActor @Sendable ([String]) async throws -> ExtensionCLIReply
    private let configuration: HostConfigurationCLI
    private let action: Action
    private let commands: [HostCLIProviderCommand]
    private var stopped = false

    public init(
        configuration: HostConfigurationCLI, commands: [HostCLIProviderCommand] = [],
        action: @escaping Action
    ) {
        self.configuration = configuration; self.action = action
        self.commands =
            ["ls", "get", "set", "unset", "describe", "export", "import"].map {
                .init(
                    route: ["config", $0], operation: "host.cli",
                    summary: "Read and write application settings.")
            } + commands
    }

    public static func handles(_ request: HostCLIRequest) -> Bool {
        request.action == .invoke && request.id == "host"
            && ["host.cli", "host.cli.catalog"].contains(request.operation ?? "")
    }

    public func execute(_ request: HostCLIRequest) async throws -> Data {
        guard !stopped, Self.handles(request) else {
            throw HostCLIError.rejected("The core CLI is unavailable.")
        }
        try request.validate()
        try Task.checkCancellation()
        if request.operation == "host.cli.catalog" {
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "host", commands: commands,
                    settings: HostConfigurationCLI.applicationSettings, acceptsInput: true))
        }
        let envelope = try JSONDecoder().decode(HostCoreCLIEnvelope.self, from: request.payload)
        try envelope.validate()
        try Task.checkCancellation()
        let reply: ExtensionCLIReply
        if envelope.arguments.first == "config" {
            reply = try configuration.execute(
                Array(envelope.arguments.dropFirst()), input: envelope.input)
        } else {
            guard ["app", "permissions"].contains(envelope.arguments.first ?? ""),
                envelope.input.isEmpty
            else {
                throw HostCLIError.usage("Unknown core command.")
            }
            reply = try await action(envelope.arguments)
        }
        try Task.checkCancellation()
        guard !stopped else {
            throw HostCLIError.rejected("The core CLI stopped during the command.")
        }
        try reply.validate()
        return try JSONEncoder().encode(reply)
    }

    public func shutdown() { stopped = true }
}
