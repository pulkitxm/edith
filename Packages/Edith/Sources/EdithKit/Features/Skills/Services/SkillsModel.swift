import Foundation
import Observation

@MainActor @Observable public final class SkillsModel {
    public static let shared = SkillsModel()
    public var query = ""
    public var ranking: SkillRanking = .allTime
    public private(set) var skills: [CatalogSkill] = []
    public private(set) var total = 0
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public private(set) var catalogError: String?
    public private(set) var agents: [SkillAgent] = []
    public var presentedSkill: CatalogSkill?
    public private(set) var selectedAgentIDs: Set<String> = []
    public private(set) var isInstalling = false
    public private(set) var installationError: String?
    public private(set) var installationLog = ""
    public private(set) var installedAgents: [String: Set<String>] = [:]
    public private(set) var installationSucceeded = false
    public private(set) var installerAvailable = false
    public private(set) var singleAgentOverride = false
    private var page = 0
    private var generation = UUID()
    private let defaults: UserDefaults
    private let fetch: @Sendable (String, SkillRanking, Int) async throws -> SkillCatalogPage
    private let installer: SkillInstaller

    public init(
        defaults: UserDefaults = SharedDefaults.store,
        fetch: @escaping @Sendable (String, SkillRanking, Int) async throws -> SkillCatalogPage = {
            try await SkillCatalogClient.fetch(query: $0, ranking: $1, page: $2)
        }, installer: SkillInstaller = SkillInstaller()
    ) {
        self.defaults = defaults
        self.fetch = fetch
        self.installer = installer
    }

    public func refresh() async {
        let token = UUID()
        generation = token
        page = 0
        skills = []
        total = 0
        hasMore = false
        catalogError = nil
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.count != 1 else { isLoading = false; return }
        isLoading = true
        do {
            if !search.isEmpty { try await Task.sleep(for: .milliseconds(250)) }
            let result = try await fetch(search, ranking, 0)
            try Task.checkCancellation()
            guard generation == token else { return }
            skills = Self.unique(result.skills)
            total = result.total ?? skills.count
            hasMore = search.isEmpty && result.hasMore == true
        } catch {
            guard generation == token else { return }
            if !Task.isCancelled { catalogError = error.localizedDescription }
        }
        if generation == token { isLoading = false }
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        let token = generation
        isLoading = true
        catalogError = nil
        do {
            let result = try await fetch("", ranking, page + 1)
            try Task.checkCancellation()
            guard generation == token else { return }
            skills = Self.unique(skills + result.skills)
            page += 1
            hasMore = result.hasMore == true
        } catch {
            guard generation == token else { return }
            if !Task.isCancelled { catalogError = error.localizedDescription }
        }
        if generation == token { isLoading = false }
    }

    public func discoverAgents(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        agents = SkillAgentCatalog.agents.filter {
            $0.isDetected(home: home, environment: environment, exists: exists)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        installerAvailable = CLIToolEnvironment.executable(named: "npx") != nil
    }

    public func present(_ skill: CatalogSkill, agentID: String? = nil) {
        guard !isInstalling else { return }
        discoverAgents()
        let preferences =
            defaults.dictionary(forKey: AppStorageKeys.Skills.agentSelections) as? [String: Bool]
            ?? [:]
        selectedAgentIDs = Set(agents.filter { preferences[$0.id] ?? true }.map(\.id))
        if let agentID { selectedAgentIDs = Set(agents.filter { $0.id == agentID }.map(\.id)) }
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
        isInstalling = true
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        defer { isInstalling = false }
        do {
            try await installer.install(skill: skill, agentIDs: Array(targets)) {
                [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.installationLog = String(
                        (self.installationLog + line + "\n").suffix(24_000))
                }
            }
            installedAgents[skill.id, default: []].formUnion(targets)
            installationSucceeded = true
        } catch {
            installationError = error.localizedDescription
        }
    }

    private static func unique(_ skills: [CatalogSkill]) -> [CatalogSkill] {
        var seen = Set<String>()
        return skills.filter { seen.insert($0.id).inserted }
    }
}
