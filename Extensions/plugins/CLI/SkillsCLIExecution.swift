import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SkillsCLIEnvironment {
    static var clipboard = NSPasteboard.general
    @TaskLocal static var model: SkillsModel?
    static var documents: SkillDocumentStore {
        get throws {
            guard let model, !model.isStopped else { throw ExtensionPeerError.unavailable }
            return model.documents
        }
    }
    static func detectAgents() throws -> [SkillAgent] {
        guard let model, !model.isStopped else { throw ExtensionPeerError.unavailable }
        return model.agents
    }
    static var installer: SkillInstaller {
        get throws {
            guard let model, !model.isStopped else { throw ExtensionPeerError.unavailable }
            return model.ownedInstaller
        }
    }
}
@MainActor enum SkillsCLIExecution {
    static func run(_ request: ExtensionCLIRequest, model: SkillsModel) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        await model.discoverAgents()
        return try await SkillsCLIEnvironment.$model.withValue(model) {
            try await ExtensionCLIExecution.run(SkillsCommand.self, request: request)
        }
    }
    static func stream(
        _ streams: ExtensionCLIStreams, operation: String, payload: Data, model: SkillsModel
    ) async throws -> Data {
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        await model.discoverAgents()
        return try SkillsCLIEnvironment.$model.withValue(model) {
            try streams.invoke(
                SkillsCommand.self, operation: operation, prefix: "plugins.cli", payload: payload)
        }
    }
}
