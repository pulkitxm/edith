import EdithExtensionSupport
import Foundation

struct PluginsUISnapshot: Codable {
    let agents: [SkillAgent]
    let presentedSkillID: String?
    let selectedAgentIDs: Set<String>
    let isInstalling: Bool
    let installationError: String?
    let installationLog: String
    let installedAgents: [String: Set<String>]
    let installationSucceeded: Bool
    let installerAvailable: Bool
    let singleAgentOverride: Bool

    @MainActor init(model: SkillsModel) {
        agents = model.agents; presentedSkillID = model.presentedSkill?.id
        selectedAgentIDs = model.selectedAgentIDs;
        isInstalling = model.isInstalling || model.remoteInstallIsPending
        installationError = model.installationError; installationLog = model.installationLog
        installedAgents = model.installedAgents; installationSucceeded = model.installationSucceeded
        installerAvailable = model.installerAvailable;
        singleAgentOverride = model.singleAgentOverride
    }
}

struct PluginsUIAction: Codable {
    let action: String
    var skillID: String? = nil
    var agentID: String? = nil
    var enabled: Bool? = nil
}

@MainActor struct PluginsUIBridge {
    let invoke: (String, Data) async throws -> Data

    init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1) }
    }
    init(invoke: @escaping (String, Data) async throws -> Data) { self.invoke = invoke }

    func perform(_ action: PluginsUIAction) async throws -> PluginsUISnapshot {
        let data = try await invoke("plugins.ui.action", JSONEncoder().encode(action))
        return try JSONDecoder().decode(PluginsUISnapshot.self, from: data)
    }
    func document(_ id: String) async throws -> SkillDocument {
        let data = try await invoke("plugins.ui.document", JSONEncoder().encode(id))
        return try JSONDecoder().decode(SkillDocument.self, from: data)
    }
    func copy(_ id: String) async throws -> Bool {
        let data = try await invoke("plugins.ui.copy", JSONEncoder().encode(id))
        return try JSONDecoder().decode(Bool.self, from: data)
    }

    static func execute(_ command: String, payload: Data, model: SkillsModel) async throws -> Data {
        guard !model.isStopped, payload.count <= 8192 else { throw ExtensionPeerError.unavailable }
        switch command {
        case "plugins.ui.document", "plugins.ui.copy":
            let id = try JSONDecoder().decode(String.self, from: payload)
            guard let skill = model.skills.first(where: { $0.id == id }) else {
                throw ExtensionPeerError.invalidRequest
            }
            if command == "plugins.ui.copy" {
                return try JSONEncoder().encode(try await model.documents.copy(skill))
            }
            return try JSONEncoder().encode(try await model.documents.load(skill))
        case "plugins.ui.action":
            let action = try JSONDecoder().decode(PluginsUIAction.self, from: payload)
            switch action.action {
            case "snapshot": break
            case "discover": await model.discoverAgents()
            case "present":
                guard let id = action.skillID,
                    let skill = model.skills.first(where: { $0.id == id }),
                    action.agentID == nil
                        || model.agents.contains(where: { $0.id == action.agentID })
                else { throw ExtensionPeerError.invalidRequest }
                await model.present(skill, agentID: action.agentID)
            case "select":
                guard let id = action.agentID, let enabled = action.enabled,
                    model.agents.contains(where: { $0.id == id }), !model.isInstalling,
                    !model.remoteInstallIsPending
                else { throw ExtensionPeerError.invalidRequest }
                model.setSelected(id, enabled: enabled)
            case "install":
                guard model.presentedSkill != nil, !model.selectedAgentIDs.isEmpty,
                    !model.isInstalling, !model.remoteInstallIsPending
                else { throw ExtensionPeerError.invalidRequest }
                model.beginRemoteInstall()
                await Task.yield()
            default: throw ExtensionPeerError.invalidRequest
            }
            try Task.checkCancellation()
            guard !model.isStopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(PluginsUISnapshot(model: model))
        default: throw ExtensionPeerError.invalidRequest
        }
    }
}
