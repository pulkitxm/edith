import EdithCore
import EdithKit
import Foundation

public struct CodeStatsEnvironment: Sendable {
    public typealias EngineFactory =
        @Sendable ((any CodeStatsGitHubClient)?, CodeStatsGit, CodeStatsStore, CodeStatsFileProbe)
        -> CodeStatsEngine

    public var settings: @Sendable () -> CodeStatsSettings
    public var saveIdentity: @Sendable (CodeStatsIdentity) -> Void
    public var isEnabled: @Sendable () -> Bool
    public var git: @Sendable () async -> CodeStatsGit?
    public var github: @Sendable () -> (any CodeStatsGitHubClient)?
    public var probe: CodeStatsFileProbe
    public var store: CodeStatsStore
    public var calendar: Calendar
    public var now: @Sendable () -> Date
    public var isThermallyConstrained: @Sendable () -> Bool
    public var makeEngine: EngineFactory

    public init(
        settings: @escaping @Sendable () -> CodeStatsSettings,
        saveIdentity: @escaping @Sendable (CodeStatsIdentity) -> Void,
        isEnabled: @escaping @Sendable () -> Bool,
        git: @escaping @Sendable () async -> CodeStatsGit?,
        github: @escaping @Sendable () -> (any CodeStatsGitHubClient)?,
        probe: CodeStatsFileProbe = .live, store: CodeStatsStore = CodeStatsStore(),
        calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() },
        isThermallyConstrained: @escaping @Sendable () -> Bool = {
            [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        },
        makeEngine: @escaping EngineFactory = { github, git, store, probe in
            CodeStatsEngine(github: github, git: git, store: store, probe: probe)
        }
    ) {
        self.settings = settings
        self.saveIdentity = saveIdentity
        self.isEnabled = isEnabled
        self.git = git
        self.github = github
        self.probe = probe
        self.store = store
        self.calendar = calendar
        self.now = now
        self.isThermallyConstrained = isThermallyConstrained
        self.makeEngine = makeEngine
    }

    public static var live: CodeStatsEnvironment {
        CodeStatsEnvironment(
            settings: { CodeStatsPreferences.load() },
            saveIdentity: { CodeStatsPreferences.setIdentity($0, in: SharedDefaults.store) },
            isEnabled: {
                ExtensionRegistry.entry(CodeStatsWorkflow.abilityID)?.isEnabled(
                    in: SharedDefaults.store) ?? false
            },
            git: {
                await CodeStatsGit.resolve(
                    credentialHelper: CLIToolEnvironment.executable(named: "gh"))
            },
            github: { CodeStatsGitHubCLI.resolve() })
    }
}

public actor CodeStatsWorkflow {
    public static let abilityID = "codeStats"
    public static let scheduleJobID = CodeStatsAgentOperation.scheduleJob
    static let gitRecheckInterval: TimeInterval = 60
    static let storageRecheckInterval: TimeInterval = 10
    static let gitMissing = "git is not installed. Install it with ed tools install git."

    private let environment: CodeStatsEnvironment
    private let publish: @Sendable (CodeStatsStatus) async -> Void
    private var state: CodeStatsState
    private var progress: CodeStatsRunProgress?
    private var tasks: AgentTaskService?
    private var launching: UUID?
    private var executing: UUID?
    private var gitAvailable = false
    private var gitCheckedAt: Date?
    private var githubInstalled: (checkedAt: Date, available: Bool)?
    private var storage: (folder: String?, checkedAt: Date, status: CodeStatsStorageStatus)?
    private var authorsFlight: Task<[CodeStatsDiscoveredAuthor], Error>?
    private var revision: UInt64 = 0

    public init(
        environment: CodeStatsEnvironment = .live,
        publish: @escaping @Sendable (CodeStatsStatus) async -> Void = { _ in }
    ) {
        self.environment = environment
        self.publish = publish
        state = environment.store.loadState()
    }

    public func register(on tasks: AgentTaskService, runtime: AgentRuntime) async {
        self.tasks = tasks
        recoverInterruptedRun()
        for operation in CodeStatsAgentOperation.internalOperations {
            await runtime.register(operation: operation) { payload in
                try await self.perform(operation: operation, payload: payload)
            }
        }
        await tasks.register(operation: CodeStatsAgentOperation.run, concurrency: 1) {
            payload, context in
            let run = try AgentPayload.decode(CodeStatsActiveRun.self, from: payload)
            return try await self.execute(run, context: context)
        }
    }

    public func recoverInterruptedRun() {
        guard let active = state.active else { return }
        state.active = nil
        state.lastRun = CodeStatsRunResult(
            outcome: .interrupted, startedAt: active.startedAt, finishedAt: environment.now())
        persist()
    }

    public func perform(operation: String, payload: Data) async throws -> Data {
        switch operation {
        case CodeStatsAgentOperation.status:
            return try AgentPayload.encode(await status())
        case CodeStatsAgentOperation.report:
            let range = try AgentPayload.decode(CodeStatsRange.self, from: payload)
            let store = environment.store
            let report = await BlockingWork.value {
                store.loadReports().first { $0.range == range }
            }
            return try AgentPayload.encode(report)
        case CodeStatsAgentOperation.authors:
            return try AgentPayload.encode(await authors())
        case CodeStatsAgentOperation.profile:
            return try AgentPayload.encode(await profile())
        case CodeStatsAgentOperation.start:
            let trigger =
                payload.isEmpty
                ? .manual : try AgentPayload.decode(CodeStatsTrigger.self, from: payload)
            return try AgentPayload.encode(await start(trigger))
        case CodeStatsAgentOperation.cancel:
            try await cancel()
            return try AgentPayload.encode(await status())
        default:
            throw AgentError(.unknownOperation, "Unknown Code Stats operation.")
        }
    }

    public func status() async -> CodeStatsStatus {
        await reconcile()
        await refreshGitAvailability()
        return snapshot(probingStorage: true)
    }

    public func settingsChanged() async {
        guard environment.isEnabled() else { return }
        await announce()
    }

    public func start(_ trigger: CodeStatsTrigger) async throws -> CodeStatsActiveRun {
        await reconcile()
        if let active = state.active { return active }
        guard environment.isEnabled() else {
            throw AgentError(
                .refused, "Code Stats is off. Turn it on with ed extensions enable codeStats.")
        }
        guard tasks != nil else { throw AgentError(.unavailable, "The agent is still starting.") }
        if trigger == .manual {
            let storage = storageStatus(for: environment.settings().folder, probing: true)
            guard storage.isReady else { throw AgentError(.refused, storage.summary) }
            if !gitAvailable { await resolveGit() }
            guard gitAvailable else { throw AgentError(.refused, Self.gitMissing) }
            if let active = state.active { return active }
        }
        guard let tasks else { throw AgentError(.unavailable, "The agent is still starting.") }
        let started = environment.now().timeIntervalSince1970.rounded(.down)
        let run = CodeStatsActiveRun(
            trigger: trigger, startedAt: Date(timeIntervalSince1970: started))
        state.active = run
        state.waitingFor = nil
        state.firstAttemptAt = state.firstAttemptAt ?? run.startedAt
        progress = nil
        launching = run.taskID
        defer { launching = nil }
        persist()
        do {
            _ = try await tasks.submit(
                AgentTaskSubmission(
                    id: run.taskID, operation: CodeStatsAgentOperation.run,
                    title: "Code Stats refresh", payload: AgentPayload.encode(run)))
        } catch {
            if state.active?.taskID == run.taskID {
                state.active = nil
                persist()
            }
            await announce()
            throw error
        }
        await announce()
        return run
    }

    public func cancel() async throws {
        guard let active = state.active, let tasks else { return }
        let snapshot = try await tasks.cancel(active.taskID)
        guard snapshot.state.isTerminal, executing != active.taskID else { return }
        complete(
            CodeStatsRunResult(
                outcome: .cancelled, startedAt: active.startedAt, finishedAt: environment.now()),
            active)
        await announce()
    }

    public func scheduledCheck() async -> CodeStatsStatus {
        await reconcile()
        let settings = environment.settings()
        let storage = storageStatus(for: settings.folder, probing: true)
        if storage.isReady, state.waitingFor != nil {
            state.waitingFor = nil
            persist()
        }
        let due = settings.schedule.isDue(
            lastRun: state.scheduleBase, now: environment.now(), calendar: environment.calendar)
        if state.active == nil, due {
            switch storage {
            case .ready where !environment.isThermallyConstrained():
                _ = try? await start(.scheduled)
            case .volumeDisconnected(let name) where state.waitingFor != name:
                state.waitingFor = name
                persist()
            default:
                break
            }
        }
        await refreshGitAvailability()
        let status = snapshot()
        await publish(status)
        return status
    }

    public func authors() async throws -> [CodeStatsDiscoveredAuthor] {
        if let authorsFlight { return try await authorsFlight.value }
        let flight = Task { try await self.discoverAuthors() }
        authorsFlight = flight
        defer { authorsFlight = nil }
        return try await flight.value
    }

    public func profile() async -> CodeStatsProfileLookup {
        guard let github = environment.github() else {
            return CodeStatsProfileLookup(issue: .unavailable)
        }
        do {
            let profile = try await github.profile()
            let emails = await github.emails(for: profile)
            if state.profile != profile {
                state.profile = profile
                persist()
                await announce()
            }
            return CodeStatsProfileLookup(profile: profile, emails: emails)
        } catch let issue as CodeStatsGitHubError {
            return CodeStatsProfileLookup(issue: issue)
        } catch {
            return CodeStatsProfileLookup(issue: .failed(message: error.localizedDescription))
        }
    }

    private func discoverAuthors() async throws -> [CodeStatsDiscoveredAuthor] {
        let settings = environment.settings()
        let storage = storageStatus(for: settings.folder, probing: true)
        guard storage.isReady, let folder = settings.folder else {
            throw AgentError(.refused, storage.summary)
        }
        guard let git = await resolveGit() else {
            throw AgentError(.refused, Self.gitMissing)
        }
        let root = URL(fileURLWithPath: CodeStatsStorageEvaluator.standardized(folder))
        let concurrency = state.active == nil ? CodeStatsEngine.analysisLimit : 1
        return await CodeStatsEngine.authors(
            root: root, identity: settings.identity, git: git, concurrency: concurrency
        ).map {
            CodeStatsDiscoveredAuthor(
                name: $0.author.name, email: $0.author.email, commits: $0.author.commits,
                countedAsYou: $0.countedAsYou)
        }
    }

    private func execute(_ run: CodeStatsActiveRun, context: AgentTaskContext) async throws
        -> Data
    {
        if let active = state.active, active.taskID != run.taskID {
            throw AgentError(.refused, "A Code Stats run is already in progress.")
        }
        if state.active == nil {
            state.active = run
            persist()
        }
        executing = run.taskID
        defer { executing = nil }
        let result = await refresh(run, context: context)
        complete(result, run)
        await announce()
        let encoded = try AgentPayload.encode(result)
        switch result.outcome {
        case .cancelled:
            throw CancellationError()
        case .failed(let message):
            throw AgentTaskExecutionError(code: "failed", message: message, result: encoded)
        case .storageUnavailable(let storage):
            throw AgentTaskExecutionError(
                code: "storageUnavailable", message: storage.summary, result: encoded)
        default:
            return encoded
        }
    }

    private func refresh(_ run: CodeStatsActiveRun, context: AgentTaskContext) async
        -> CodeStatsRunResult
    {
        var settings = environment.settings()
        guard let git = await resolveGit() else {
            return CodeStatsRunResult(
                outcome: .failed(message: Self.gitMissing), startedAt: run.startedAt,
                finishedAt: environment.now())
        }
        let github = environment.github()
        if settings.identity.isEmpty, let github, let profile = try? await github.profile() {
            let seeded = CodeStatsIdentity.seeded(
                login: profile.login, emails: await github.emails(for: profile))
            let current = environment.settings().identity
            if current.isEmpty {
                environment.saveIdentity(seeded)
                settings.identity = seeded
                context.report("Counting commits by " + seeded.labels.joined(separator: ", "))
            } else {
                settings.identity = current
            }
        }
        let engine = environment.makeEngine(github, git, environment.store, environment.probe)
        let (updates, continuation) = AsyncStream.makeStream(
            of: CodeStatsRunProgress.self, bufferingPolicy: .bufferingNewest(1))
        async let observed: Void = observe(updates, context: context)
        var result = await engine.run(settings: settings) { continuation.yield($0) }
        continuation.finish()
        await observed
        result.startedAt = run.startedAt
        return result
    }

    private func observe(
        _ updates: AsyncStream<CodeStatsRunProgress>, context: AgentTaskContext
    ) async {
        var reported = ""
        for await update in updates {
            progress = update
            let line = Self.describe(update)
            if line != reported {
                context.report(line)
                reported = line
            }
            await announce()
        }
    }

    static func describe(_ progress: CodeStatsRunProgress) -> String {
        switch progress.phase {
        case .profile: "Reading the GitHub profile"
        case .listing: "Listing repositories"
        case .syncing: "Synced \(progress.completed) of \(progress.total) repositories"
        case .analyzing: "Analyzed \(progress.completed) of \(progress.total) repositories"
        case .reporting: "Building the report"
        }
    }

    private func complete(_ result: CodeStatsRunResult, _ run: CodeStatsActiveRun) {
        guard state.active?.taskID == run.taskID else { return }
        state.active = nil
        progress = nil
        state.lastRun = result
        if let profile = result.profile { state.profile = profile }
        switch result.outcome {
        case .completed:
            state.lastRunAt = run.startedAt
            state.reportedAt = result.finishedAt
        case .failed, .cancelled:
            state.lastRunAt = run.startedAt
        case .volumeDisconnected(let name):
            state.waitingFor = name
        case .interrupted, .storageUnavailable:
            break
        }
        persist()
    }

    private func reconcile() async {
        guard let active = state.active, active.taskID != launching,
            active.taskID != executing, let tasks
        else { return }
        let snapshot = try? await tasks.status(active.taskID).snapshot
        guard state.active?.taskID == active.taskID, active.taskID != executing,
            snapshot?.state.isTerminal ?? true
        else { return }
        let outcome: CodeStatsRunOutcome =
            snapshot?.state == .cancelled ? .cancelled : .interrupted
        complete(
            CodeStatsRunResult(
                outcome: outcome, startedAt: active.startedAt, finishedAt: environment.now()),
            active)
    }

    private func snapshot(probingStorage: Bool = false) -> CodeStatsStatus {
        let settings = environment.settings()
        let milliseconds = UInt64(max(environment.now().timeIntervalSince1970 * 1_000, 0))
        revision = max(revision + 1, milliseconds)
        return CodeStatsStatus(
            settings: settings,
            storage: storageStatus(for: settings.folder, probing: probingStorage),
            gitAvailable: gitAvailable, githubAvailable: githubAvailable(), state: state,
            nextRunAt: settings.schedule.nextRun(
                after: state.scheduleBase, calendar: environment.calendar),
            progress: state.active == nil ? nil : progress, revision: revision)
    }

    private func storageStatus(for folder: String?, probing: Bool) -> CodeStatsStorageStatus {
        let now = environment.now()
        if !probing, let storage, storage.folder == folder,
            now.timeIntervalSince(storage.checkedAt) < Self.storageRecheckInterval
        {
            return storage.status
        }
        let status = CodeStatsStorageEvaluator.status(for: folder, probe: environment.probe)
        storage = (folder, now, status)
        return status
    }

    private func githubAvailable() -> Bool {
        let now = environment.now()
        if let githubInstalled,
            now.timeIntervalSince(githubInstalled.checkedAt) < Self.gitRecheckInterval
        {
            return githubInstalled.available
        }
        let available = environment.github() != nil
        githubInstalled = (now, available)
        return available
    }

    private func refreshGitAvailability() async {
        if let gitCheckedAt,
            environment.now().timeIntervalSince(gitCheckedAt) < Self.gitRecheckInterval
        {
            return
        }
        await resolveGit()
    }

    @discardableResult
    private func resolveGit() async -> CodeStatsGit? {
        let git = await environment.git()
        gitAvailable = git != nil
        gitCheckedAt = environment.now()
        return git
    }

    private func announce() async {
        await publish(snapshot())
    }

    private func persist() {
        try? environment.store.saveState(state)
    }
}
