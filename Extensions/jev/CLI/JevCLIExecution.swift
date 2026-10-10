import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum JevCLIEnvironment {
    static var owner: JevCLIEngine?
    static var stdin = Data()
}

struct JevCLIEngine {
    let engine: JevEngine
    func status(probe: Bool) async -> JevStatus { await engine.status(probe: probe) }
    func setKey(_ key: String?) async -> JevStatus {
        await engine.setKey(key)
        return await engine.status(probe: false)
    }
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        try await engine.decide(request, purpose: purpose)
    }
}

@MainActor enum JevCLIExecution {
    static func run(_ request: ExtensionCLIRequest, engine: JevEngine, stdin: Data = Data())
        async throws -> ExtensionCLIReply
    {
        try request.validate()
        guard stdin.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        let previous = JevCLIEnvironment.owner
        let previousInput = JevCLIEnvironment.stdin
        JevCLIEnvironment.owner = JevCLIEngine(engine: engine)
        JevCLIEnvironment.stdin = stdin
        defer { JevCLIEnvironment.owner = previous; JevCLIEnvironment.stdin = previousInput }
        return try await ExtensionCLIExecution.run(JevCommand.self, arguments: request.arguments)
    }
}
