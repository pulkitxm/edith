import EdithExtensionSupport
import EdithExtensionUI
import CoreFoundation
import Foundation
import Observation

@MainActor @Observable public final class SkillsModel {
    public let skills = EdithSkillLibrary.skills
    public let documents: SkillDocumentStore
    public private(set) var agents: [SkillAgent] = []
    public let discoveryLoad = ContentLoad()
    public var agentsLoaded: Bool { discoveryLoad.hasContent }
    public var isDiscovering: Bool { discoveryLoad.isRunning }
    public var presentedSkill: EdithSkill?
    public private(set) var selectedAgentIDs: Set<String> = []
    public private(set) var isInstalling = false
    public private(set) var installationError: String?
    public private(set) var installationLog = ""
    public private(set) var installedAgents: [String: Set<String>] = [:]
    public private(set) var installationSucceeded = false
    public private(set) var installerAvailable = false
    public private(set) var singleAgentOverride = false
    public private(set) var isStopped = false
    @ObservationIgnored private var installationID = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let discoverInstaller: @Sendable () -> Bool
    @ObservationIgnored private let detectAgents: @Sendable () -> [SkillAgent]
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let installer: SkillInstaller
    var ownedInstaller: SkillInstaller { installer }
    private let remote: PluginsUIBridge?
    private var remoteGeneration = 0
    private var remoteRequests: [UUID: Task<Void, Never>] = [:]
    private var installationLogs: [UUID: SkillInstallationLogs] = [:]
    private static let agentSelectionsKey = AppStorageKeys.Skills.agentSelections

    init(
        remote: PluginsUIBridge? = nil,
        defaults: UserDefaults = SharedDefaults.store,
        documents: SkillDocumentStore? = nil,
        installer: SkillInstaller? = nil,
        detectAgents: @escaping @Sendable () -> [SkillAgent] = { SkillAgentCatalog.detected() },
        discoverInstaller: @escaping @Sendable () -> Bool = {
            CLIToolEnvironment.executable(named: "npx") != nil
        }
    ) {
        self.defaults = defaults
        self.remote = remote
        let store =
            documents ?? remote.map { bridge in
                SkillDocumentStore(
                    remoteLoad: { try await bridge.document($0.id) },
                    remoteCopy: { try await bridge.copy($0.id) })
            } ?? SkillDocumentStore()
        self.documents = store
        self.installer =
            installer
            ?? SkillInstaller(recordInstalled: { skill, document in
                try await store.recordInstalled(document, for: skill)
            })
        self.detectAgents = detectAgents
        self.discoverInstaller = discoverInstaller
    }

    public func discoverAgents() async {
        if remote != nil { await remoteAction(.init(action: "discover")); return }
        guard !isStopped, !Task.isCancelled else { return }
        if let existing = discoveryTask {
            await existing.value
            return
        }
        let detect = detectAgents
        let discoverInstaller = discoverInstaller
        let task = Task { [weak self] in
            guard let self else { return }
            defer { discoveryTask = nil }
            await discoveryLoad.perform(operation: {
                (detect(), discoverInstaller())
            }) { [weak self] result in
                guard let self, !isStopped else { return }
                agents = result.0
                installerAvailable = result.1
            }
        }
        discoveryTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func present(_ skill: EdithSkill, agentID: String? = nil) async {
        if remote != nil {
            guard !isStopped, !isInstalling, skills.contains(skill), !Task.isCancelled else {
                return
            }
            singleAgentOverride = agentID != nil
            installationSucceeded = false
            installationError = nil
            installationLog = ""
            presentedSkill = skill
            await remoteAction(.init(action: "present", skillID: skill.id, agentID: agentID))
            return
        }
        guard !isStopped, !isInstalling, skills.contains(skill), !Task.isCancelled else { return }
        let token = UUID()
        installationID = token
        singleAgentOverride = agentID != nil
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        presentedSkill = skill
        let task = Task { [weak self] in
            guard let self else { return }
            await discoverAgents()
            guard !isStopped, !Task.isCancelled, installationID == token else { return }
            let preferences =
                defaults.dictionary(forKey: Self.agentSelectionsKey) as? [String: Bool] ?? [:]
            selectedAgentIDs = Set(agents.compactMap { (preferences[$0.id] ?? true) ? $0.id : nil })
            if let agentID {
                selectedAgentIDs = agents.contains { $0.id == agentID } ? [agentID] : []
            }
        }
        jobs[token] = task
        defer { jobs[token] = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    public func dismissPresentation() async {
        if remote != nil {
            guard presentedSkill != nil, !isInstalling else { return }
            presentedSkill = nil
            installationSucceeded = false
            installationError = nil
            installationLog = ""
            await remoteAction(.init(action: "dismiss"))
            return
        }
        guard !isStopped, !isInstalling else { return }
        installationID = UUID()
        presentedSkill = nil
        installationSucceeded = false
        installationError = nil
        installationLog = ""
    }

    func savedAgentSelections() throws -> [String: Bool]? {
        guard defaults.synchronize() else { throw ExtensionPeerError.unavailable }
        guard let stored = defaults.object(forKey: Self.agentSelectionsKey) else { return nil }
        guard let fields = stored as? [String: Any], fields.count <= 128 else {
            throw ExtensionPeerError.invalidRequest
        }
        var selections: [String: Bool] = [:]
        for (key, value) in fields {
            guard !key.isEmpty, key.utf8.count <= 128,
                let value = value as? NSNumber,
                CFGetTypeID(value) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            selections[key] = value.boolValue
        }
        return selections
    }

    public func setSelected(_ id: String, enabled: Bool) {
        guard !isStopped, !Task.isCancelled else { return }
        if remote != nil {
            if enabled { selectedAgentIDs.insert(id) } else { selectedAgentIDs.remove(id) }
            singleAgentOverride = false
            ownRemoteAction(.init(action: "select", agentID: id, enabled: enabled))
            return
        }
        guard !isStopped, !isInstalling, !isDiscovering,
            agents.contains(where: { $0.id == id })
        else { return }
        if enabled { selectedAgentIDs.insert(id) } else { selectedAgentIDs.remove(id) }
        singleAgentOverride = false
        var preferences =
            defaults.dictionary(forKey: Self.agentSelectionsKey) as? [String: Bool] ?? [:]
        for agent in agents { preferences[agent.id] = selectedAgentIDs.contains(agent.id) }
        defaults.set(preferences, forKey: Self.agentSelectionsKey)
    }

    public func install() async {
        if remote != nil { await remoteAction(.init(action: "install")); return }
        guard !isStopped, let skill = presentedSkill, !isInstalling, !isDiscovering,
            !selectedAgentIDs.isEmpty, !Task.isCancelled
        else { return }
        let targets = selectedAgentIDs
        let token = UUID()
        installationID = token
        isInstalling = true
        installationSucceeded = false
        installationError = nil
        installationLog = ""
        let logs = SkillInstallationLogs { [weak self] line in
            guard let self, !isStopped, installationID == token else { return }
            installationLog = String((installationLog + line + "\n").suffix(24_000))
        }
        installationLogs[token] = logs
        let task = Task { [weak self] in
            guard let self else { await logs.finishAndWait(); return }
            defer { installationLogs[token] = nil }
            defer { if installationID == token { isInstalling = false } }
            await runInstallation(skill: skill, targets: targets, token: token, logs: logs)
            await logs.finishAndWait()
        }
        jobs[token] = task
        defer { jobs[token] = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            logs.stop()
        }
    }

    private func runInstallation(
        skill: EdithSkill, targets: Set<String>, token: UUID, logs: SkillInstallationLogs
    ) async {
        do {
            try await installer.install(skill: skill, agentIDs: Array(targets)) { line in
                logs.append(line)
            }
            try Task.checkCancellation()
            guard !isStopped, installationID == token else { return }
            installedAgents[skill.id, default: []].formUnion(targets)
            installationSucceeded = true
        } catch is CancellationError {
        } catch {
            guard !isStopped, installationID == token else { return }
            installationError =
                (error as? CLICommandRunnerError) == .timedOut
                ? "Installation timed out after five minutes. Check the output before retrying."
                : error.localizedDescription
        }
    }

    private var remoteInstallLaunch: Task<Void, Never>?
    var remoteInstallIsPending: Bool { remoteInstallLaunch != nil }
    func beginRemoteInstall() {
        guard !isStopped, remoteInstallLaunch == nil else { return }
        remoteInstallLaunch = Task { [weak self] in
            await self?.install(); self?.remoteInstallLaunch = nil
        }
    }

    private func ownRemoteAction(_ request: PluginsUIAction) {
        guard !isStopped, jobs.count < 8 else { return }
        let id = UUID()
        jobs[id] = Task { [weak self] in
            defer { self?.jobs[id] = nil }
            await self?.remoteAction(request)
        }
    }

    private func remoteAction(_ request: PluginsUIAction) async {
        guard !isStopped, !Task.isCancelled, remoteRequests.count < 8 else { return }
        let id = UUID()
        let task = Task { [self] in
            defer { remoteRequests[id] = nil }
            await performRemoteAction(request)
        }
        remoteRequests[id] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performRemoteAction(_ request: PluginsUIAction) async {
        guard let remote, !isStopped, !Task.isCancelled else { return }
        remoteGeneration &+= 1
        let generation = remoteGeneration
        let tracksDiscovery = request.action == "discover" || request.action == "present"
        let loading =
            tracksDiscovery ? discoveryLoad.begin(preservingContent: discoveryLoad.hasContent) : nil
        if request.action == "install" { isInstalling = true }
        do {
            var value = try await remote.perform(request)
            if request.action == "install" {
                while value.isInstalling, !Task.isCancelled, !isStopped {
                    try await Task.sleep(for: .milliseconds(100))
                    value = try await remote.perform(.init(action: "snapshot"))
                }
            }
            guard !isStopped, !Task.isCancelled, remoteGeneration == generation else { return }
            agents = value.agents; selectedAgentIDs = value.selectedAgentIDs
            if request.action == "present" {
                presentedSkill = skills.first { $0.id == value.presentedSkillID }
            }
            installedAgents = value.installedAgents
            isInstalling = value.isInstalling; installerAvailable = value.installerAvailable
            installationSucceeded = value.installationSucceeded
            installationLog = value.installationLog; installationError = value.installationError
            singleAgentOverride = value.singleAgentOverride
            if let loading { discoveryLoad.complete(loading) }
        } catch {
            guard !isStopped, !Task.isCancelled, remoteGeneration == generation else { return }
            isInstalling = false; installationError = error.localizedDescription
            if let loading { discoveryLoad.fail(loading, error: error) }
        }
    }

    public func stop() {
        isStopped = true
        documents.stop()
        remoteGeneration &+= 1
        installationID = UUID()
        discoveryLoad.reset()
        discoveryTask?.cancel()
        remoteInstallLaunch?.cancel()
        for task in jobs.values { task.cancel() }
        for task in remoteRequests.values { task.cancel() }
        for logs in installationLogs.values { logs.stop() }
    }

    public func stopAndWait() async {
        stop()
        let discovering = discoveryTask
        let tasks = Array(jobs.values)
        let remoteTasks = Array(remoteRequests.values)
        let logs = Array(installationLogs.values)
        await discovering?.value
        for task in tasks { await task.value }
        for task in remoteTasks { await task.value }
        for owner in logs { await owner.finishAndWait() }
        await remoteInstallLaunch?.value; remoteInstallLaunch = nil
        await documents.stopAndWait()
        discoveryTask = nil
        jobs.removeAll()
    }

    public func shutdown() async {
        await stopAndWait()
        await documents.shutdown()
        agents.removeAll()
        installedAgents.removeAll()
        selectedAgentIDs.removeAll()
        presentedSkill = nil
        installationLog = ""
        installationError = nil
        isInstalling = false
        installationSucceeded = false
        installerAvailable = false
    }
}

final class SkillInstallationLogs: Sendable {
    private let continuation: AsyncStream<String>.Continuation
    private let task: Task<Void, Never>

    @MainActor init(publish: @escaping @MainActor @Sendable (String) async -> Void) {
        let stream = AsyncStream<String>.makeStream()
        continuation = stream.continuation
        task = Task {
            for await line in stream.stream {
                guard !Task.isCancelled else { return }
                await publish(line)
            }
        }
    }

    func append(_ line: String) { continuation.yield(line) }

    func stop() {
        continuation.finish()
        task.cancel()
    }

    func finishAndWait() async {
        continuation.finish()
        await task.value
    }
}
