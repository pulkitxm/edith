import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SystemStatsCLIEnvironment {
    static var makeSampler: () -> any SystemStatsSampling = { LocalMachineSampler() }
}

@MainActor enum SystemStatsCLIExecution {
    static func run(
        _ request: ExtensionCLIRequest,
        makeSampler: @escaping () -> any SystemStatsSampling = { LocalMachineSampler() }
    ) async throws -> ExtensionCLIReply {
        try request.validate()
        let previous = SystemStatsCLIEnvironment.makeSampler
        SystemStatsCLIEnvironment.makeSampler = makeSampler
        defer { SystemStatsCLIEnvironment.makeSampler = previous }
        return try await ExtensionCLIExecution.run(SystemCommand.self, arguments: request.arguments)
    }
}
