import EdithExtensionSupport
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
            settings: {
                CodeStatsPreferences.load(homeDirectory: CodeStatsExecutionEnvironment.home)
            },
            saveIdentity: { CodeStatsPreferences.setIdentity($0, in: SharedDefaults.store) },
            isEnabled: {
                true
            },
            git: {
                await CodeStatsExecutionEnvironment.git()
            },
            github: {
                CodeStatsExecutionEnvironment.fixtureHome == nil
                    ? CodeStatsGitHubCLI.resolve() : nil
            })
    }
}

public actor CodeStatsWorkflow {
    public static let abilityID = "codeStats"
    static let gitRecheckInterval: TimeInterval = 60
    static let storageRecheckInterval: TimeInterval = 10
    static let gitMissing = "git is not installed. Install it with ed tools install git."

    private let environment: CodeStatsEnvironment
    private let publish: @Sendable (CodeStatsStatus) async -> Void
    private var state: CodeStatsState
    private var progress: CodeStatsRunProgress?
    private var runTask: Task<Void, Never>?
    private var profileFlight: Task<CodeStatsProfileLookup, Never>?
    private var subscribers: [UUID: AsyncStream<CodeStatsStatus>.Continuation] = [:]
    private var stopped = false
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

    public func shutdown() async {
        stopped = true
        runTask?.cancel(); authorsFlight?.cancel(); profileFlight?.cancel()
        await runTask?.value
        _ = try? await authorsFlight?.value
        _ = await profileFlight?.value
        runTask = nil; authorsFlight = nil; profileFlight = nil
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    public func updates() -> AsyncStream<CodeStatsStatus> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: CodeStatsStatus.self, bufferingPolicy: .bufferingNewest(1))
        if stopped { continuation.finish(); return stream }
        subscribers[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    public func recoverInterruptedRun() {
        guard let active = state.active else { return }
        state.active = nil
        state.lastRun = CodeStatsRunResult(
            outcome: .interrupted, startedAt: active.startedAt, finishedAt: environment.now())
        persist()
    }

    public func perform(operation: String, payload: Data) async throws -> Data {
        switch operation {
        case CodeStatsCommand.status:
            return try JSONEncoder().encode(await status())
        case CodeStatsCommand.report:
            let query = try JSONDecoder().decode(CodeStatsReportQuery.self, from: payload)
            let store = environment.store
            let now = environment.now()
            let calendar = environment.calendar
            let report = await BlockingWork.value { () -> CodeStatsReport? in
                if query.filter == .default,
                    let cached = store.loadReports().first(where: { $0.range == query.range })
                {
                    return cached
                }
                return store.loadFacts().map {
                    CodeStatsReportBuilder.build(
                        table: $0, filter: query.filter, range: query.range, today: now,
                        calendar: calendar)
                }
            }
            return try JSONEncoder().encode(report)
        case CodeStatsCommand.facts:
            let store = environment.store
            return try JSONEncoder().encode(await BlockingWork.value { store.loadFacts() })
        case CodeStatsCommand.audit:
            let filter =
                payload.isEmpty
                ? .default : try JSONDecoder().decode(CodeStatsFilter.self, from: payload)
            let store = environment.store
            let identity = environment.settings().identity
            let audit = await BlockingWork.value {
                store.loadFacts().map {
                    CodeStatsAuditBuilder.build(table: $0, filter: filter).matching(identity)
                }
            }
            return try JSONEncoder().encode(audit)
        case CodeStatsCommand.authors:
            return try JSONEncoder().encode(await authors())
        case CodeStatsCommand.profile:
            return try JSONEncoder().encode(await profile())
        case CodeStatsCommand.start:
            let trigger =
                payload.isEmpty
                ? .manual : try JSONDecoder().decode(CodeStatsTrigger.self, from: payload)
            return try JSONEncoder().encode(await start(trigger))
        case CodeStatsCommand.cancel:
            try await cancel()
            return try JSONEncoder().encode(await status())
        default:
            throw CodeStatsFailure(.unknownOperation, "Unknown Code Stats operation.")
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
            throw CodeStatsFailure(
                .refused, "Code Stats is off. Turn it on with ed extensions enable codeStats.")
        }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if trigger == .manual {
            let storage = storageStatus(for: environment.settings().folder, probing: true)
            guard storage.isReady else { throw CodeStatsFailure(.refused, storage.summary) }
            if !gitAvailable { await resolveGit() }
            guard gitAvailable else { throw CodeStatsFailure(.refused, Self.gitMissing) }
            if let active = state.active { return active }
        }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let active = state.active { return active }
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
        runTask = Task { await self.execute(run) }
        await announce()
        return run
    }

    public func cancel() async throws {
        guard let active = state.active, let task = runTask else { return }
        task.cancel()
        await task.value
        if state.active?.taskID == active.taskID {
            complete(
                CodeStatsRunResult(
                    outcome: .cancelled, startedAt: active.startedAt,
                    finishedAt: environment.now()), active)
        }
        await announce()
    }

    public func scheduledCheck() async -> CodeStatsStatus {
        guard !stopped, !Task.isCancelled else { return snapshot() }
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
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let authorsFlight { return try await authorsFlight.value }
        let flight = Task { try await self.discoverAuthors() }
        authorsFlight = flight
        defer { authorsFlight = nil }
        return try await withTaskCancellationHandler {
            try await flight.value
        } onCancel: {
            flight.cancel()
        }
    }

    public func profile() async -> CodeStatsProfileLookup {
        guard !stopped else { return CodeStatsProfileLookup(issue: .unavailable) }
        if let flight = profileFlight { return await flight.value }
        let flight = Task { await self.loadProfile() }
        profileFlight = flight
        defer { profileFlight = nil }
        return await withTaskCancellationHandler {
            await flight.value
        } onCancel: {
            flight.cancel()
        }
    }

    private func loadProfile() async -> CodeStatsProfileLookup {
        guard !stopped, let github = environment.github() else {
            return CodeStatsProfileLookup(issue: .unavailable)
        }
        do {
            let profile = try await github.profile()
            let emails = await github.emails(for: profile)
            try Task.checkCancellation()
            guard !stopped else { return CodeStatsProfileLookup(issue: .unavailable) }
            if state.profile != profile { state.profile = profile; persist(); await announce() }
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
            throw CodeStatsFailure(.refused, storage.summary)
        }
        guard let git = await resolveGit() else {
            throw CodeStatsFailure(.refused, Self.gitMissing)
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

    private func execute(_ run: CodeStatsActiveRun) async {
        guard !stopped, state.active?.taskID == run.taskID else { return }
        executing = run.taskID
        defer { executing = nil; runTask = nil }
        let result = await refresh(run)
        complete(result, run)
        await announce()
    }

    private func refresh(_ run: CodeStatsActiveRun) async
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
            } else {
                settings.identity = current
            }
        }
        let engine = environment.makeEngine(github, git, environment.store, environment.probe)
        let (updates, continuation) = AsyncStream.makeStream(
            of: CodeStatsRunProgress.self, bufferingPolicy: .bufferingNewest(1))
        async let observed: Void = observe(updates)
        var result = await engine.run(settings: settings) { continuation.yield($0) }
        continuation.finish()
        await observed
        result.startedAt = run.startedAt
        return result
    }

    private func observe(_ updates: AsyncStream<CodeStatsRunProgress>) async {
        var reported = ""
        for await update in updates {
            progress = update
            let line = Self.describe(update)
            if line != reported {
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
            active.taskID != executing, runTask == nil
        else { return }
        complete(
            CodeStatsRunResult(
                outcome: .interrupted, startedAt: active.startedAt,
                finishedAt: environment.now()), active)
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
        let value = snapshot()
        for continuation in subscribers.values { continuation.yield(value) }
        await publish(value)
    }

    private func persist() {
        try? environment.store.saveState(state)
    }
}
