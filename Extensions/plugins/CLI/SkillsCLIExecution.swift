import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

@MainActor enum SkillsCLIEnvironment {
    static var clipboard = NSPasteboard.general
    static var documents = SkillDocumentStore()
    static var detectAgents: () -> [SkillAgent] = { SkillAgentCatalog.detected() }
    static var installer = SkillInstaller(recordInstalled: { skill, document in
        try await documents.recordInstalled(document, for: skill)
    })
}

@MainActor enum SkillsCLIExecution {
    static func run(_ request: ExtensionCLIRequest, model: SkillsModel) async throws
        -> ExtensionCLIReply
    {
        try request.validate()
        guard !model.isStopped else { throw ExtensionPeerError.unavailable }
        await model.discoverAgents()
        let oldDocuments = SkillsCLIEnvironment.documents
        let oldAgents = SkillsCLIEnvironment.detectAgents
        let oldInstaller = SkillsCLIEnvironment.installer
        SkillsCLIEnvironment.documents = model.documents
        SkillsCLIEnvironment.detectAgents = { model.agents }
        SkillsCLIEnvironment.installer = model.ownedInstaller
        defer {
            SkillsCLIEnvironment.documents = oldDocuments
            SkillsCLIEnvironment.detectAgents = oldAgents
            SkillsCLIEnvironment.installer = oldInstaller
        }
        return try await ExtensionCLIExecution.run(SkillsCommand.self, arguments: request.arguments)
    }
}
