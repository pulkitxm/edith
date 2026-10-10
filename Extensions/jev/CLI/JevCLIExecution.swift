import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum JevCLIEnvironment {
    static var owner: JevCLIEngine?
    @TaskLocal static var streamOwner: JevCLIEngine?
    static var currentOwner: JevCLIEngine? { streamOwner ?? owner }
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
    private static var executing = false
    static func run(_ request: ExtensionCLIRequest, engine: JevEngine)
        async throws -> ExtensionCLIReply
    {
        try request.validate()
        while executing {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        executing = true
        defer { executing = false }
        let previous = JevCLIEnvironment.owner
        JevCLIEnvironment.owner = JevCLIEngine(engine: engine)
        defer { JevCLIEnvironment.owner = previous }
        return try await ExtensionCLIExecution.run(JevCommand.self, request: request)
    }
}
