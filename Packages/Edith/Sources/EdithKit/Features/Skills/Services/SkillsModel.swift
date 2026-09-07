import Foundation
import Observation

@MainActor @Observable public final class SkillsModel {
    public static let shared = SkillsModel()
    public let skills = EdithSkillLibrary.skills
    public private(set) var agents: [SkillAgent] = []
    public var presentedSkill: EdithSkill?
    public private(set) var selectedAgentIDs: Set<String> = []
    public private(set) var isInstalling = false
    public private(set) var installationError: String?
    public private(set) var installationLog = ""
    public private(set) var installedAgents: [String: Set<String>] = [:]
    public private(set) var installationSucceeded = false
    public private(set) var installerAvailable = false
    public private(set) var singleAgentOverride = false
    private var installationID = UUID()
    private let defaults: UserDefaults
    private let detectAgents: () -> [SkillAgent]
    private let installer: SkillInstaller

    public init(
        defaults: UserDefaults = SharedDefaults.store,
        installer: SkillInstaller = SkillInstaller(),
        detectAgents: @escaping () -> [SkillAgent] = { SkillAgentCatalog.detected() }
    ) {
        self.defaults = defaults
        self.installer = installer
        self.detectAgents = detectAgents
    }

    public func discoverAgents() {
        agents = detectAgents()
        installerAvailable = CLIToolEnvironment.executable(named: "npx") != nil
    }

    public func present(_ skill: EdithSkill, agentID: String? = nil) {
        guard !isInstalling else { return }
        installationID = UUID()
        discoverAgents()
        let preferences =
            defaults.dictionary(forKey: AppStorageKeys.Skills.agentSelections) as? [String: Bool]
            ?? [:]
        selectedAgentIDs = Set(agents.compactMap { (preferences[$0.id] ?? true) ? $0.id : nil })
        if let agentID { selectedAgentIDs = agents.contains { $0.id == agentID } ? [agentID] : [] }
        singleAgentOverride = agentID != nil
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        presentedSkill = skill
    }

    public func setSelected(_ id: String, enabled: Bool) {
        guard !isInstalling, agents.contains(where: { $0.id == id }) else { return }
        if enabled { selectedAgentIDs.insert(id) } else { selectedAgentIDs.remove(id) }
        singleAgentOverride = false
        var preferences =
            defaults.dictionary(forKey: AppStorageKeys.Skills.agentSelections) as? [String: Bool]
            ?? [:]
        for agent in agents { preferences[agent.id] = selectedAgentIDs.contains(agent.id) }
        defaults.set(preferences, forKey: AppStorageKeys.Skills.agentSelections)
    }

    public func install() async {
        guard let skill = presentedSkill, !isInstalling, !selectedAgentIDs.isEmpty else { return }
        let targets = selectedAgentIDs
        let token = UUID()
        installationID = token
        isInstalling = true
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        defer { isInstalling = false }
        do {
            try await installer.install(skill: skill, agentIDs: Array(targets)) {
                [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, self.installationID == token else { return }
                    self.installationLog = String(
                        (self.installationLog + line + "\n").suffix(24_000))
                }
            }
            installedAgents[skill.id, default: []].formUnion(targets)
            installationSucceeded = true
        } catch CLICommandRunnerError.timedOut {
            installationError =
                "Installation timed out after five minutes. Check the output before retrying."
        } catch {
            installationError = error.localizedDescription
        }
    }
}
