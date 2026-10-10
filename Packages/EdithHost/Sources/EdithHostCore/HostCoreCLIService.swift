import EdithExtensionSupport
import Foundation

public struct HostCoreCLIEnvelope: Codable, Sendable {
    public let arguments: [String]
    public let input: Data
    public let workingDirectory: String
    public init(
        arguments: [String], input: Data = Data(),
        workingDirectory: String = FileManager.default.currentDirectoryPath
    ) throws {
        _ = try ExtensionCLIRequest(arguments: arguments)
        guard input.count <= HostCLIInvocationContext.maximumInputBytes else {
            throw HostCLIError.usage("Input exceeds 4 MiB.")
        }
        self.arguments = arguments; self.input = input
        _ = try HostCLIInvocationContext(
            arguments: arguments, standardInput: input, workingDirectory: workingDirectory)
        self.workingDirectory = workingDirectory
    }
    public func validate() throws {
        _ = try Self(arguments: arguments, input: input, workingDirectory: workingDirectory)
    }
    public func request(timeout: Double = 30) throws -> HostCLIRequest {
        try validate()
        return try HostCLIRequest(
            action: .invoke, id: "host", operation: "host.cli", payload: JSONEncoder().encode(self),
            timeout: timeout)
    }
}

@MainActor public final class HostCoreCLIService {
    public typealias Action = @MainActor @Sendable ([String]) async throws -> ExtensionCLIReply
    private let configuration: HostConfigurationCLI
    private let action: Action
    private let commands: () -> [HostCLIProviderCommand]
    private let configurationCommands: [HostCLIProviderCommand]
    private let prepareConfiguration: @MainActor @Sendable ([String]) async throws -> Void
    private var stopped = false

    public init(
        configuration: HostConfigurationCLI, commands: [HostCLIProviderCommand] = [],
        commandProvider: (@MainActor () -> [HostCLIProviderCommand])? = nil,
        prepareConfiguration: @escaping @MainActor @Sendable ([String]) async throws -> Void = {
            _ in
        },
        action: @escaping Action
    ) {
        self.configuration = configuration; self.action = action
        self.prepareConfiguration = prepareConfiguration
        self.commands = commandProvider ?? { commands }
        configurationCommands =
            ["ls", "get", "set", "unset", "describe", "export", "import"].map {
                .init(
                    route: ["config", $0], operation: "host.cli",
                    summary: "Read and write application settings.", readsInput: $0 == "import",
                    jsonOutput: $0 != "export")
            }
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
                    owner: "host", commands: configurationCommands + commands(),
                    settings: HostConfigurationCLI.applicationSettings, acceptsInput: true))
        }
        let envelope = try JSONDecoder().decode(HostCoreCLIEnvelope.self, from: request.payload)
        try envelope.validate()
        try Task.checkCancellation()
        let reply: ExtensionCLIReply
        if envelope.arguments.first == "config" {
            try await prepareConfiguration(Array(envelope.arguments.dropFirst()))
            try Task.checkCancellation()
            reply = try configuration.execute(
                Array(envelope.arguments.dropFirst()), input: envelope.input)
        } else {
            guard
                [
                    "app", "permissions", "camera", "guide", "schema", "version", "status",
                    "install", "uninstall", "completions", "extensions",
                ].contains(envelope.arguments.first ?? ""),
                envelope.input.isEmpty
            else {
                throw HostCLIError.usage("Unknown core command.")
            }
            reply = try await HostCoreCLIContext.$workingDirectory.withValue(
                envelope.workingDirectory
            ) {
                try await action(envelope.arguments)
            }
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

public enum HostCoreCLIContext {
    @TaskLocal public static var workingDirectory = "/"
}
