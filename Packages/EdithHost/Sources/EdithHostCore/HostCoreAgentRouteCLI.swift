import EdithExtensionSupport
import Foundation

public enum HostCoreAgentRouteCLI {
    public static func execute(
        _ arguments: [String], input: Data = Data(),
        streamWrite: (@Sendable (Data, Bool) async throws -> Void)? = nil,
        invoke: @escaping HostCLIProviderRegistry.Invoke
    ) async throws -> ExtensionCLIReply {
        let domain = arguments.count > 1 ? arguments[1] : ""
        guard let owner = ["activity": "herdr"][domain]
        else {
            throw HostCLIError.usage("Unknown original agent route.")
        }
        let registry = try await HostCoreOwnerRegistry.load(invoke: invoke)
        guard let provider = registry.providers.first(where: { $0.state.id == owner }) else {
            return try HostCoreCommandFailure(
                "The original agent " + domain + " provider is unavailable.",
                hint: "Install and enable " + owner + " with original agent command hooks."
            ).reply()
        }
        let routes = (provider.catalog.routes ?? []).filter { arguments.starts(with: $0.route) }
            .sorted { $0.route.count > $1.route.count }
        guard let command = routes.first, input.isEmpty || command.readsInput == true else {
            return try HostCoreCommandFailure(
                "The original agent " + domain + " route is unavailable.",
                hint: "Update " + owner + " to a provider with original agent route metadata."
            ).reply()
        }
        try Task.checkCancellation()
        guard input.count <= HostCLIInvocationContext.maximumInputBytes else {
            throw HostCLIError.usage("Input exceeds 4 MiB.")
        }
        let context = try HostCLIInvocationContext(
            arguments: Array(arguments.dropFirst()),
            standardInput: input, workingDirectory: FileManager.default.currentDirectoryPath)
        if let operation = command.streamOperation {
            guard try await HostCLIProviderRegistry.states(invoke: invoke).contains(provider.state)
            else {
                throw HostCoreCommandFailure("The original agent provider was disabled or changed.")
            }
            let checkedInvoke: HostCLIProviderRegistry.Invoke = { request in
                try await registry.validateCurrent(provider)
                let data = try await invoke(request)
                try await registry.validateCurrent(provider)
                return data
            }
            let stream = try await HostCLIStream.start(
                owner: owner, operation: operation, request: context,
                maximumDuration: command.streamDeadline ?? 1800, invoke: checkedInvoke)
            if let streamWrite {
                let code = try await stream.consume(write: streamWrite)
                return try ExtensionCLIReply(stdout: "", stderr: "", exitCode: code)
            }
            let capture = HostCLIStreamCapture()
            let code = try await stream.consume(write: { try await capture.append($0, stderr: $1) })
            return try await capture.reply(code: code)
        }
        let reply = try await registry.call(
            ExtensionCLIReply.self, provider: provider,
            operation: command.operation, payload: JSONEncoder().encode(context),
            timeout: command.timeout)
        try reply.validate()
        return reply
    }
}
