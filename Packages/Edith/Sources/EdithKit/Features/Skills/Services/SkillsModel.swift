import Foundation
import Observation

@MainActor @Observable public final class SkillsModel {
    public static let shared = SkillsModel()
    public let skills = EdithSkillLibrary.skills
    public private(set) var agents: [SkillAgent] = []
    public private(set) var agentsLoaded = false
    public private(set) var isDiscovering = false
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
    private let detectAgents: @Sendable () -> [SkillAgent]
    private var discoveryTask: Task<([SkillAgent], Bool), Never>?
    private var discoveryID = UUID()
    private let installer: SkillInstaller

    public init(
        defaults: UserDefaults = SharedDefaults.store,
        installer: SkillInstaller = SkillInstaller(),
        detectAgents: @escaping @Sendable () -> [SkillAgent] = { SkillAgentCatalog.detected() }
    ) {
        self.defaults = defaults
        self.installer = installer
        self.detectAgents = detectAgents
    }

    public func discoverAgents() async {
        let task: Task<([SkillAgent], Bool), Never>
        if let existing = discoveryTask {
            task = existing
        } else {
            let detect = detectAgents
            task = Task { await Self.discover(using: detect) }
            discoveryID = UUID()
            discoveryTask = task
            isDiscovering = true
        }
        let token = discoveryID
        let result = await task.value
        guard token == discoveryID else { return }
        agents = result.0
        installerAvailable = result.1
        agentsLoaded = true
        isDiscovering = false
        discoveryTask = nil
    }

    private nonisolated static func discover(
        using detect: @escaping @Sendable () -> [SkillAgent]
    ) async -> ([SkillAgent], Bool) {
        await Task.detached(priority: .userInitiated) {
            (detect(), CLIToolEnvironment.executable(named: "npx") != nil)
        }.value
    }

    public func present(_ skill: EdithSkill, agentID: String? = nil) async {
        guard !isInstalling else { return }
        let token = UUID()
        installationID = token
        singleAgentOverride = agentID != nil
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        presentedSkill = skill
        await discoverAgents()
        guard installationID == token else { return }
        let preferences =
            defaults.dictionary(forKey: AppStorageKeys.Skills.agentSelections) as? [String: Bool]
            ?? [:]
        selectedAgentIDs = Set(agents.compactMap { (preferences[$0.id] ?? true) ? $0.id : nil })
        if let agentID { selectedAgentIDs = agents.contains { $0.id == agentID } ? [agentID] : [] }
    }

    public func setSelected(_ id: String, enabled: Bool) {
        guard !isInstalling, !isDiscovering, agents.contains(where: { $0.id == id }) else { return }
        if enabled { selectedAgentIDs.insert(id) } else { selectedAgentIDs.remove(id) }
        singleAgentOverride = false
        var preferences =
            defaults.dictionary(forKey: AppStorageKeys.Skills.agentSelections) as? [String: Bool]
            ?? [:]
        for agent in agents { preferences[agent.id] = selectedAgentIDs.contains(agent.id) }
        defaults.set(preferences, forKey: AppStorageKeys.Skills.agentSelections)
    }

    public func install() async {
        guard let skill = presentedSkill, !isInstalling, !isDiscovering, !selectedAgentIDs.isEmpty
        else { return }
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
