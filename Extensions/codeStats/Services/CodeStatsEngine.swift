import EdithExtensionSupport
import Foundation

public actor CodeStatsEngine {
    public static let syncLimit = 6
    public static var analysisLimit: Int {
        max(ProcessInfo.processInfo.activeProcessorCount - 1, 1)
    }
    public static let recentErrorLimit = 5
    public static let errorLimit = 50

    private let github: (any CodeStatsGitHubClient)?
    private let git: CodeStatsGit
    private let store: CodeStatsStore
    private let probe: CodeStatsFileProbe
    private let syncLimit: Int
    private let analysisLimit: Int
    private let progressInterval: TimeInterval
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var progress = CodeStatsRunProgress(startedAt: Date())
    private var lastEmission: TimeInterval = 0
    private var onProgress: (@Sendable (CodeStatsRunProgress) -> Void)?
    private var stop: CodeStatsRunOutcome?
    private var errors: [String] = []
    private var running = false
    private var repositoryCount = 0

    public init(
        github: (any CodeStatsGitHubClient)?, git: CodeStatsGit,
        store: CodeStatsStore = CodeStatsStore(), probe: CodeStatsFileProbe = .live,
        syncLimit: Int = CodeStatsEngine.syncLimit,
        analysisLimit: Int = CodeStatsEngine.analysisLimit, progressInterval: TimeInterval = 0.25,
        calendar: Calendar = .current, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.github = github
        self.git = git
        self.store = store
        self.probe = probe
        self.syncLimit = syncLimit
        self.analysisLimit = analysisLimit
        self.progressInterval = progressInterval
        self.calendar = calendar
        self.now = now
    }

    public func run(
        settings: CodeStatsSettings,
        onProgress: @escaping @Sendable (CodeStatsRunProgress) -> Void = { _ in }
    ) async -> CodeStatsRunResult {
        let startedAt = now()
        guard !running else {
            return result(.failed(message: "A run is already in progress"), startedAt, nil, nil)
        }
        running = true
        defer {
            running = false
            self.onProgress = nil
        }
        self.onProgress = onProgress
        progress = CodeStatsRunProgress(startedAt: startedAt)
        stop = nil
        errors = []
        repositoryCount = 0
        let status = CodeStatsStorageEvaluator.status(for: settings.folder, probe: probe)
        guard status.isReady, let folder = settings.folder else {
            return result(Self.outcome(for: status), startedAt, nil, nil)
        }
        let root = URL(fileURLWithPath: CodeStatsStorageEvaluator.standardized(folder))
        emit(force: true)

        var profile: CodeStatsProfile?
        var issue: CodeStatsGitHubError?
        var remote: [CodeStatsRemoteRepository] = []
        var excluded = Set<String>()
        var forks = Set<String>()
        if let github {
            do {
                profile = try await github.profile()
            } catch {
                issue = Self.issue(error)
            }
            enter(.listing)
            if issue == nil, !Task.isCancelled {
                do {
                    let listed = try await github.repositories()
                    forks = Set(listed.lazy.filter(\.isFork).map { $0.fullName.lowercased() })
                    remote = listed.filter(settings.includes)
                    excluded = Set(
                        listed.lazy.filter { !settings.includes($0) }.map {
                            $0.fullName.lowercased()
                        })
                    progress.skipped = listed.count - remote.count
                    progress.listedKilobytes = remote.reduce(0) { $0 + $1.sizeKilobytes }
                } catch {
                    issue = Self.issue(error)
                }
            }
        } else {
            issue = .unavailable
            enter(.listing)
        }
        if Task.isCancelled { return result(.cancelled, startedAt, profile, issue) }

        enter(.syncing, total: remote.count)
        let local = await BlockingWork.value {
            CodeStatsRepositoryDiscovery.removeAbandonedStaging(root: root)
            return Dictionary(
                CodeStatsRepositoryDiscovery.discover(root: root).map {
                    ($0.fullName.lowercased(), $0)
                }
            ) { first, _ in first }
        }
        _ = await CodeStatsTaskRunner.map(remote, limit: syncLimit) { _, repository in
            await self.sync(repository, root: root, existing: local)
        }
        if let interrupted = interruption() {
            return result(interrupted, startedAt, profile, issue)
        }

        let discovered = await BlockingWork.value {
            CodeStatsRepositoryDiscovery.discover(root: root)
        }
        let repositories = discovered.filter { !excluded.contains($0.fullName.lowercased()) }
        repositoryCount = repositories.count
        enter(.analyzing, total: repositories.count)
        let store = store
        let caches = await BlockingWork.value { store.loadCaches() }
        let identity = settings.identity
        let logins = Set(
            ([profile?.login].compactMap { $0 } + identity.substrings).map { $0.lowercased() })
        let plans = await CodeStatsTaskRunner.map(repositories, limit: analysisLimit) {
            _, repository in
            await self.plan(
                repository, root: root, cache: caches[repository.fullName], identity: identity,
                logins: logins, forks: forks)
        }
        let analyzed = await extract(plans, root: root)
        if let interrupted = interruption() {
            return result(interrupted, startedAt, profile, issue)
        }

        enter(.reporting)
        let entries = analyzed
        let today = now()
        let calendar = calendar
        let login = profile?.login
        let name = profile?.name
        do {
            try await BlockingWork.perform {
                let table = CodeStatsFactBuilder.build(
                    commits: entries.flatMap(\.commits),
                    integrated: Set(entries.flatMap(\.integrated)),
                    suggestions: CodeStatsIdentitySuggester.suggestions(
                        authors: entries.flatMap(\.authors), identity: identity, login: login,
                        name: name))
                try store.saveFacts(table)
                try store.saveReports(
                    CodeStatsRange.presets.map {
                        CodeStatsReportBuilder.build(
                            table: table, filter: .default, range: $0, today: today,
                            calendar: calendar)
                    })
                store.removeCaches(except: Set(discovered.map(\.fullName)))
            }
        } catch {
            return result(.failed(message: "\(error)"), startedAt, profile, issue)
        }
        progress.completed = 1
        progress.total = 1
        emit(force: true)
        return result(.completed, startedAt, profile, issue)
    }

    public static func authors(
        root: URL, identity: CodeStatsIdentity, git: CodeStatsGit, limit: Int = 60,
        concurrency: Int = analysisLimit
    ) async -> [(author: CodeStatsAuthor, countedAsYou: Bool)] {
        let repositories = CodeStatsRepositoryDiscovery.discover(root: root)
        let lists = await CodeStatsTaskRunner.map(repositories, limit: concurrency) {
            _, repository in
            (try? await git.authors(in: repository)) ?? []
        }
        var merged: [String: CodeStatsAuthor] = [:]
        for author in lists.joined() {
            merged[
                author.name + "\t" + author.email,
                default: CodeStatsAuthor(
                    name: author.name, email: author.email, commits: 0)
            ].commits += author.commits
        }
        let isMine = identity.matcher()
        return merged.values.sorted { ($0.commits, $1.email) > ($1.commits, $0.email) }
            .prefix(limit).map { ($0, isMine($0.name, $0.email)) }
    }

    private static func issue(_ error: Error) -> CodeStatsGitHubError? {
        if error is CancellationError { return nil }
        return error as? CodeStatsGitHubError ?? .failed(message: "\(error)")
    }

    private static func outcome(for status: CodeStatsStorageStatus) -> CodeStatsRunOutcome {
        if case .volumeDisconnected(let name) = status {
            return .volumeDisconnected(volumeName: name)
        }
        return .storageUnavailable(status)
    }

    private func interruption() -> CodeStatsRunOutcome? {
        stop ?? (Task.isCancelled ? .cancelled : nil)
    }

    private func storageReady(_ root: URL) -> Bool {
        guard stop == nil else { return false }
        let status = CodeStatsStorageEvaluator.status(for: root.path, probe: probe)
        if !status.isReady { stop = Self.outcome(for: status) }
        return stop == nil
    }

    private func sync(
        _ repository: CodeStatsRemoteRepository, root: URL,
        existing: [String: CodeStatsRepository]
    ) async {
        guard !Task.isCancelled, storageReady(root) else { return }
        begin(repository.fullName)
        do {
            if let local = existing[repository.fullName.lowercased()] {
                try await git.fetch(local)
            } else {
                try await git.cloneMirror(
                    from: repository.cloneURL,
                    to: CodeStatsRepositoryDiscovery.mirrorURL(
                        root: root, fullName: repository.fullName))
            }
            progress.synced += 1
            end(repository.fullName, error: nil, root: root)
        } catch {
            end(repository.fullName, error: error, root: root)
        }
    }

    private struct Plan: Sendable {
        var repository: CodeStatsRepository
        var attribution: CodeStatsAttribution
        var refs: CodeStatsRefState
        var base: [CodeStatsCommit]
        var shas: [CodeStatsCandidate]
        var integrated: [String]
        var authors: [CodeStatsAuthor]
        var done: CodeStatsRepositoryCache?
    }

    private struct Unit: Sendable {
        var plan: Int
        var shas: [CodeStatsCandidate]
    }

    private func plan(
        _ repository: CodeStatsRepository, root: URL, cache: CodeStatsRepositoryCache?,
        identity: CodeStatsIdentity, logins: Set<String>, forks: Set<String>
    ) async -> Plan? {
        guard !Task.isCancelled, storageReady(root) else { return finished(cache) }
        do {
            let refs = try await git.refState(repository)
            let unchanged = cache?.refsFingerprint == refs.fingerprint
            let authors: [CodeStatsAuthor]
            if unchanged, let cached = cache?.authors, !cached.isEmpty {
                authors = cached
            } else {
                authors = try await git.authors(in: repository)
            }
            let owned =
                CodeStatsAttribution.isOwned(repository.fullName, logins: logins)
                && !forks.contains(repository.fullName.lowercased())
                && CodeStatsAttribution.isPrimary(authors, identity: identity)
            let attribution = CodeStatsAttribution(identity: identity, owned: owned)
            let fingerprint = attribution.fingerprint
            if let cache, cache.freshCommits(refs: refs.fingerprint, identity: fingerprint) != nil {
                return finished(cache)
            }
            var base: [CodeStatsCommit] = []
            var exclusions: [String] = []
            if let cache, cache.extendable(identity: fingerprint),
                await git.canExtend(repository, from: cache.tips)
            {
                base = cache.commits
                exclusions = cache.tips
            }
            let known = Set(base.map(\.sha))
            let shas = try await git.candidateCommits(
                in: repository, attribution: attribution, excluding: exclusions
            ).filter { !known.contains($0.sha) }
            let integrated = try await git.integratedCommits(in: repository).sorted()
            var plan = Plan(
                repository: repository, attribution: attribution, refs: refs, base: base,
                shas: shas, integrated: integrated, authors: authors, done: nil)
            if shas.isEmpty {
                let entry = Self.entry(plan, commits: base)
                let store = store
                try await BlockingWork.perform { try store.save(entry) }
                plan.done = entry
                end(repository.fullName, error: nil, root: root)
            }
            return plan
        } catch {
            end(repository.fullName, error: error, root: root)
            return finished(cache)
        }
    }

    private func finished(_ cache: CodeStatsRepositoryCache?) -> Plan? {
        guard let cache else { return nil }
        progress.completed += 1
        emit()
        return Plan(
            repository: CodeStatsRepository(fullName: cache.repository, path: "", isBare: true),
            attribution: CodeStatsAttribution(identity: CodeStatsIdentity(), owned: false),
            refs: CodeStatsRefState(lines: []), base: [], shas: [], integrated: [], authors: [],
            done: cache)
    }

    private static func entry(_ plan: Plan, commits: [CodeStatsCommit]) -> CodeStatsRepositoryCache
    {
        CodeStatsRepositoryCache(
            repository: plan.repository.fullName, refsFingerprint: plan.refs.fingerprint,
            identityFingerprint: plan.attribution.fingerprint, tips: plan.refs.tips,
            integrated: plan.integrated, authors: plan.authors, commits: commits)
    }

    private var pendingUnits: [Int: Int] = [:]
    private var unitErrors: [Int: Error] = [:]
    private var unitCommits: [Int: [CodeStatsCommit]] = [:]
    private var activePlans: [Plan] = []
    private var completedEntries: [Int: CodeStatsRepositoryCache] = [:]

    private func extract(_ plans: [Plan?], root: URL) async -> [CodeStatsRepositoryCache] {
        let plans = plans.compactMap { $0 }
        activePlans = plans
        pendingUnits = [:]
        unitErrors = [:]
        unitCommits = [:]
        completedEntries = [:]
        var units: [Unit] = []
        for (index, plan) in plans.enumerated() {
            if let done = plan.done {
                completedEntries[index] = done
                continue
            }
            var start = 0
            while start < plan.shas.count {
                let end = min(start + CodeStatsGit.chunkSize, plan.shas.count)
                units.append(Unit(plan: index, shas: Array(plan.shas[start..<end])))
                start = end
            }
            pendingUnits[index] =
                (plan.shas.count + CodeStatsGit.chunkSize - 1) / CodeStatsGit.chunkSize
        }
        units.sort { plans[$0.plan].shas.count > plans[$1.plan].shas.count }
        let git = git
        _ = await CodeStatsTaskRunner.map(units, limit: analysisLimit) { _, unit in
            let plan = plans[unit.plan]
            guard !Task.isCancelled, await self.storageReady(root) else {
                await self.unitFinished(
                    unit.plan, commits: nil, error: CancellationError(), root: root)
                return
            }
            await self.unitStarted(unit.plan, name: plan.repository.fullName)
            do {
                let commits = try await git.commits(
                    in: plan.repository, candidates: unit.shas, attribution: plan.attribution)
                await self.unitFinished(unit.plan, commits: commits, error: nil, root: root)
            } catch {
                await self.unitFinished(unit.plan, commits: nil, error: error, root: root)
            }
        }
        let entries = completedEntries.sorted { $0.key < $1.key }.map(\.value)
        activePlans = []
        completedEntries = [:]
        unitCommits = [:]
        return entries
    }

    private func unitStarted(_ index: Int, name: String) {
        if !progress.inFlight.contains(name) { begin(name) }
    }

    private func unitFinished(
        _ index: Int, commits: [CodeStatsCommit]?, error: Error?, root: URL
    ) async {
        if let commits { unitCommits[index, default: []] += commits }
        if let error, unitErrors[index] == nil { unitErrors[index] = error }
        pendingUnits[index, default: 1] -= 1
        guard pendingUnits[index, default: 0] <= 0, activePlans.indices.contains(index) else {
            return
        }
        let plan = activePlans[index]
        let failure = unitErrors[index]
        if failure == nil {
            let known = Set(plan.base.map(\.sha))
            let entry = Self.entry(
                plan,
                commits: plan.base + (unitCommits[index] ?? []).filter { !known.contains($0.sha) })
            let store = store
            do {
                try await BlockingWork.perform { try store.save(entry) }
                completedEntries[index] = entry
            } catch {
                unitErrors[index] = error
            }
        }
        unitCommits[index] = nil
        let reported = unitErrors[index].flatMap { $0 is CancellationError ? nil : $0 }
        if progress.inFlight.contains(plan.repository.fullName) || reported != nil {
            end(plan.repository.fullName, error: reported, root: root)
        }
    }

    private func begin(_ name: String) {
        progress.inFlight.append(name)
        emit()
    }

    private func end(_ name: String, error: Error?, root: URL) {
        progress.inFlight.removeAll { $0 == name }
        progress.completed += 1
        if let error, !(error is CancellationError), !Task.isCancelled, storageReady(root) {
            progress.failed += 1
            errors.append(name + ": " + Self.describe(error))
            if errors.count > Self.errorLimit { errors.removeFirst(errors.count - Self.errorLimit) }
            progress.recentErrors = Array(errors.suffix(Self.recentErrorLimit))
        }
        emit()
    }

    private static func describe(_ error: Error) -> String {
        if case CodeStatsGitError.failed(let status, let message) = error {
            return message.isEmpty ? "git exited with status \(status)" : message
        }
        return "\(error)"
    }

    private func enter(_ phase: CodeStatsPhase, total: Int = 0) {
        progress.phase = phase
        progress.completed = 0
        progress.total = total
        progress.inFlight = []
        emit(force: true)
    }

    private func emit(force: Bool = false) {
        let phases = CodeStatsPhase.allCases
        progress.phaseFraction =
            progress.total == 0 ? 0 : min(Double(progress.completed) / Double(progress.total), 1)
        let index = phases.firstIndex(of: progress.phase) ?? 0
        let finished = phases.prefix(index).reduce(0) { $0 + $1.weight }
        progress.overallFraction = max(
            progress.overallFraction,
            min(finished + progress.phase.weight * progress.phaseFraction, 1))
        let uptime = ProcessInfo.processInfo.systemUptime
        guard force || uptime - lastEmission >= progressInterval else { return }
        lastEmission = uptime
        onProgress?(progress)
    }

    private func result(
        _ outcome: CodeStatsRunOutcome, _ startedAt: Date, _ profile: CodeStatsProfile?,
        _ issue: CodeStatsGitHubError?
    ) -> CodeStatsRunResult {
        CodeStatsRunResult(
            outcome: outcome, startedAt: startedAt, finishedAt: now(), profile: profile,
            github: issue, repositories: repositoryCount,
            synced: progress.synced, failed: progress.failed, errors: errors)
    }
}
