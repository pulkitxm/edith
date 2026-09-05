import AppKit
import EdithKit
import Foundation

struct UsageHistoryPersistenceEntry: Sendable {
    let provider: LimitProvider
    let session: LimitWindow?
    let week: LimitWindow?
    let fable: LimitWindow?
}

actor UsageHistoryPersistenceWorker {
    static let shared = UsageHistoryPersistenceWorker()
    private let resolveHistoryURL: @Sendable () -> URL
    private var pending: [UsageHistoryPersistenceEntry] = []

    init() {
        self.resolveHistoryURL = { LimitsHistory.url }
    }

    init(historyURL: URL) {
        self.resolveHistoryURL = { historyURL }
    }

    init(historyURLResolver: @escaping @Sendable () -> URL) {
        self.resolveHistoryURL = historyURLResolver
    }

    @discardableResult
    func persist(_ entries: [UsageHistoryPersistenceEntry]) -> Bool {
        pending.append(contentsOf: entries)
        return persistPendingOnce()
    }

    func drain(maxAttempts: Int = 3, retryNanoseconds: UInt64 = 50_000_000) async -> Bool {
        guard !pending.isEmpty else { return true }
        for attempt in 0..<max(0, maxAttempts) {
            guard !Task.isCancelled else { return false }
            if persistPendingOnce() { return true }
            guard attempt + 1 < maxAttempts else { break }
            do {
                try await Task.sleep(nanoseconds: retryNanoseconds)
            } catch {
                return false
            }
        }
        return pending.isEmpty
    }

    func pendingCount() -> Int {
        pending.count
    }

    private func persistPendingOnce() -> Bool {
        let historyURL = resolveHistoryURL()
        pending = pending.filter { entry in
            var history = LimitsHistory(url: historyURL)
            return !history.append(
                provider: entry.provider, session: entry.session, week: entry.week,
                fable: entry.fable)
        }
        return pending.isEmpty
    }
}

struct UsageReloadGenerationState: Sendable {
    private var generation = 0

    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    mutating func invalidate() {
        generation += 1
    }

    func accepts(_ generation: Int) -> Bool {
        self.generation == generation
    }
}

struct RangeStat: Identifiable {
    let id: String
    let label: String
    let tokens: Double
    let cost: Double
}

@MainActor
@Observable
final class UsageStore: FeatureModule {
    private(set) var session: LimitWindow?
    private(set) var week: LimitWindow?
    private(set) var fableWeek: LimitWindow?
    private(set) var codexSession: LimitWindow?
    private(set) var codexWeek: LimitWindow?
    private(set) var limitsError: String?
    private(set) var limitsUpdatedAt: Date?
    private(set) var refreshingLimits = false

    private(set) var stats: [RangeStat] = []
    private(set) var sources: [SourceInfo] = []
    var selectedSources: Set<String> = [] {
        didSet { recomputeStats() }
    }
    private(set) var statsGeneratedAt: Date?
    private(set) var statsError: String?
    private(set) var calendarDays: [DayPoint] = []

    private(set) var updating = false
    private(set) var log = ""
    private(set) var diagnostics = ""

    private var defaultSources: [String] = []
    private var knownSources: Set<String> = []
    private var daily: [DailyRow] = []
    private var billingDay = 26

    private var launchObserver: NSObjectProtocol?
    private var refreshStartedObserver: NSObjectProtocol?
    private var limitsUpdatedObserver: NSObjectProtocol?
    private var usageRestoreObserver: NSObjectProtocol?
    private var limitsRestoreObserver: NSObjectProtocol?
    private var pendingRefresh = false
    private var refreshGeneration = 0
    private var terminating = false
    private var usageMtime: Date?
    private var refreshTask: Task<Void, Never>?
    private var refreshEvents: [UsageRefreshEvent] = []
    private var refreshStartedAt: Date?
    private var usageRestoreReloadGeneration = UsageReloadGenerationState()
    private var limitsRestoreReloadGeneration = UsageReloadGenerationState()
    private var statsReloadGeneration = UsageReloadGenerationState()
    var notifier: LimitNotifier { .shared }
    private(set) var limitPoints: [LimitPoint] = []
    private var historyMtime: Date?
    private var limitHistoryProvider = LimitProvider.claude
    private var limitHistoryGeneration = 0
    private var statusItem: LimitsStatusItem?

    var enabledProviders: [LimitProvider] {
        Self.enabledLimitProviders(
            claude: providerEnabled(.claude), codex: providerEnabled(.codex))
    }

    var availableProviders: [LimitProvider] {
        let enabled = Set(enabledProviders)
        return LimitProvider.allCases.filter { enabled.contains($0) && limits(for: $0).isAvailable }
    }

    func limits(for provider: LimitProvider) -> ProviderLimits {
        switch provider {
        case .claude:
            return ProviderLimits(
                provider: provider, session: Self.fresh(session), week: Self.fresh(week),
                fable: Self.fresh(fableWeek))
        case .codex:
            return ProviderLimits(
                provider: provider, session: Self.fresh(codexSession), week: Self.fresh(codexWeek))
        }
    }

    private nonisolated static func fresh(_ window: LimitWindow?) -> LimitWindow? {
        window.flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
    }

    func providerEnabled(_ provider: LimitProvider) -> Bool {
        let key =
            provider == .claude
            ? AppStorageKeys.Limits.claudeEnabled : AppStorageKeys.Limits.codexEnabled
        return SharedDefaults.store.object(forKey: key) as? Bool ?? true
    }

    nonisolated static func enabledLimitProviders(claude: Bool, codex: Bool) -> [LimitProvider] {
        UsageLimitProviders.enabled(claude: claude, codex: codex)
    }

    init() {
        Task { @MainActor [weak self] in
            let latest = await LimitsHistory.loadLatestProviders()
            self?.seedFromHistory(latest, excluding: [])
            await self?.loadStats()
            self?.recomputeStats()
        }

        if let app = NSApp, app.isRunning {
            syncStatusItem()
        } else {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncStatusItem() }
            }
        }

        refreshStartedObserver = IPC.observe(IPC.Name.usageRefreshStarted) { [weak self] in
            Task { @MainActor in self?.adoptExternalRefresh() }
        }

        limitsUpdatedObserver = IPC.observe(IPC.Name.limitsUpdated) { [weak self] in
            Task { @MainActor in await self?.reloadLimitsFromHistory() }
        }

        usageRestoreObserver = IPC.observe(BackgroundBackupSignal.usageRestored) { [weak self] in
            Task { @MainActor in self?.scheduleRestoredUsageReload() }
        }
        limitsRestoreObserver = IPC.observe(BackgroundBackupSignal.limitsRestored) { [weak self] in
            Task { @MainActor in self?.scheduleRestoredLimitsReload() }
        }
    }

    private func seedFromHistory(
        _ latest: [LimitProvider: LimitsHistory.Latest], excluding: Set<LimitProvider>
    ) {
        if !excluding.contains(.claude), let last = latest[.claude] {
            session = Self.fresh(last.session)
            week = Self.fresh(last.week)
            fableWeek = Self.fresh(last.fable)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if !excluding.contains(.codex), let last = latest[.codex] {
            codexSession = Self.fresh(last.session)
            codexWeek = Self.fresh(last.week)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if let limitsUpdatedAt {
            diag("seeded last-known limits from history (\(limitsUpdatedAt.formatted()))")
        }
    }

    nonisolated static func acceptsExternalRefreshStart(updating: Bool) -> Bool {
        !updating
    }

    func shutdown() {
        terminating = true
        usageRestoreReloadGeneration.invalidate()
        limitsRestoreReloadGeneration.invalidate()
        statsReloadGeneration.invalidate()
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
        pendingRefresh = false
        updating = false
        refreshEvents = []
        daily = []
        stats = []
        calendarDays = []
        log = ""
        diagnostics = ""
        usageMtime = nil
        limitPoints = []
        statusItem?.remove()
        statusItem = nil
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let refreshStartedObserver {
            IPC.stopObserving(refreshStartedObserver)
            self.refreshStartedObserver = nil
        }
        if let limitsUpdatedObserver {
            IPC.stopObserving(limitsUpdatedObserver)
            self.limitsUpdatedObserver = nil
        }
        if let usageRestoreObserver {
            IPC.stopObserving(usageRestoreObserver)
            self.usageRestoreObserver = nil
        }
        if let limitsRestoreObserver {
            IPC.stopObserving(limitsRestoreObserver)
            self.limitsRestoreObserver = nil
        }
    }

    func syncStatusItem() {
        guard NSApp != nil else { return }
        let on =
            SharedDefaults.store.object(forKey: AppStorageKeys.Limits.inMenuBar) as? Bool ?? true
        if on, statusItem == nil {
            statusItem = LimitsStatusItem()
            updateStatusItem()
        }
        if !on, let item = statusItem {
            item.remove()
            statusItem = nil
        }
    }

    func refreshMenuBarItem() {
        updateStatusItem()
    }

    var nextLimitsRefresh: Date? { nil }

    func refreshLimits(force: Bool = false) async {
        guard !terminating else { return }
        refreshingLimits = true
        try? UsageAgentOperations.requestLimitsRefresh()
        diag("requested limits refresh from the background agent")
    }

    func reloadLimitsFromHistory() async {
        guard !terminating else { return }
        let latest = await LimitsHistory.loadLatestProviders()
        seedFromHistory(latest, excluding: [])
        await loadLimitHistory(provider: limitHistoryProvider)
        limitsError = nil
        updateStatusItem()
        refreshingLimits = false
    }

    func prepareForTermination() {
        shutdown()
    }

    private func updateStatusItem() {
        statusItem?.update(availableProviders.map(limits(for:)))
    }

    private func diag(_ message: String) {
        diagnostics += "\(Self.diagTimeFormatter.string(from: Date()))  \(message)\n"
        if diagnostics.count > 20_000 { diagnostics = String(diagnostics.suffix(16_000)) }
    }

    static let diagTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static let ymdParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func parseISO(_ s: String?) -> Date? { EdithDate.parseISO(s) }

    struct DailyRow: Decodable {
        let period: String
        let bySource: [String: [ModelRow]]
    }

    struct ModelRow: Decodable {
        let inputTokens: Double?
        let outputTokens: Double?
        let cacheCreationTokens: Double?
        let cacheReadTokens: Double?
        let cost: Double?
        var tokens: Double {
            (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheCreationTokens ?? 0)
                + (cacheReadTokens ?? 0)
        }
    }

    private struct UsageFile: Decodable {
        let generatedAt: String?
        let sources: [String]?
        let defaultSources: [String]?
        let sourceMeta: [String: Meta]?
        let daily: [DailyRow]
        struct Meta: Decodable { let label: String? }
    }

    func loadStats() async {
        guard !terminating else { return }
        let generation = statsReloadGeneration.begin()
        let url = Repo.usageJSON
        let mtime = await Task.detached(priority: .utility) {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
                as? Date
        }.value
        guard !Task.isCancelled, statsReloadGeneration.accepts(generation) else { return }
        if let mtime, mtime == usageMtime { return }

        let parsed: UsageFile
        do {
            parsed = try await Task.detached(priority: .utility) {
                guard
                    let data = try UsageDataFiles.readRegularFile(
                        at: url, maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
                else { throw CocoaError(.fileReadNoSuchFile) }
                return try JSONDecoder().decode(UsageFile.self, from: data)
            }.value
        } catch {
            guard !terminating, statsReloadGeneration.accepts(generation) else { return }
            statsError = "usage.json missing - hit reload"
            diag("usage.json decode failed: \(error.localizedDescription)")
            return
        }

        guard !terminating, statsReloadGeneration.accepts(generation) else { return }

        usageMtime = mtime
        statsError = nil
        daily = parsed.daily
        defaultSources = parsed.defaultSources ?? parsed.sources ?? []
        let meta = parsed.sourceMeta ?? [:]
        sources = (parsed.sources ?? []).map { SourceInfo(id: $0, label: meta[$0]?.label ?? $0) }
        statsGeneratedAt = Self.parseISO(parsed.generatedAt)
        let availableSources = Set(sources.map(\.id))
        selectedSources = UsageSourceSelection.reconcile(
            selected: selectedSources, known: knownSources, available: availableSources,
            defaults: Set(defaultSources))
        knownSources = availableSources
    }

    private func recomputeStats() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let ymd = { (d: Date) -> String in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        let dow = (cal.component(.weekday, from: today) + 5) % 7
        let weekStart = cal.date(byAdding: .day, value: -dow, to: today)!
        let cycleStart: Date = {
            let day = cal.component(.day, from: today)
            let anchor = min(billingDay, cal.range(of: .day, in: .month, for: today)!.count)
            if day >= anchor {
                return cal.date(
                    bySetting: .day, value: anchor,
                    of: cal.date(from: cal.dateComponents([.year, .month], from: today))!)!
            }
            let prev = cal.date(byAdding: .month, value: -1, to: today)!
            let prevAnchor = min(billingDay, cal.range(of: .day, in: .month, for: prev)!.count)
            return cal.date(
                from: DateComponents(
                    year: cal.component(.year, from: prev),
                    month: cal.component(.month, from: prev), day: prevAnchor))!
        }()
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        let ranges: [(String, String, String)] = [
            ("Today", ymd(today), ymd(today)),
            ("Yesterday", ymd(yesterday), ymd(yesterday)),
            ("This week", ymd(weekStart), ymd(today)),
            ("This cycle", ymd(cycleStart), ymd(today)),
        ]
        stats = ranges.map { label, from, to in
            var tokens = 0.0, cost = 0.0
            for row in daily where row.period >= from && row.period <= to {
                for (source, models) in row.bySource where selectedSources.contains(source) {
                    for m in models {
                        tokens += m.tokens
                        cost += m.cost ?? 0
                    }
                }
            }
            return RangeStat(id: label, label: label, tokens: tokens, cost: cost)
        }

        var costByDay: [String: Double] = [:]
        for row in daily {
            var cost = 0.0
            for (source, models) in row.bySource where selectedSources.contains(source) {
                for m in models { cost += m.cost ?? 0 }
            }
            costByDay[row.period] = cost
        }
        var points: [DayPoint] = []
        var day = weekStart
        if let first = daily.map(\.period).min(),
            let firstDate = Self.ymdParser.date(from: first)
        {
            let start = cal.startOfDay(for: firstDate)
            let dow = (cal.component(.weekday, from: start) + 5) % 7
            day = cal.date(byAdding: .day, value: -dow, to: start)!
        }
        while day <= today {
            let key = ymd(day)
            points.append(DayPoint(id: key, date: day, cost: costByDay[key] ?? 0))
            day = cal.date(byAdding: .day, value: 1, to: day)!
        }
        calendarDays = points
    }

    func loadLimitHistory(provider: LimitProvider = .claude) async {
        guard !terminating else { return }
        limitHistoryProvider = provider
        limitHistoryGeneration += 1
        let generation = limitHistoryGeneration
        let url = LimitsHistory.url
        let mtime = await Task.detached(priority: .utility) {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
                as? Date
        }.value
        guard !Task.isCancelled, limitHistoryGeneration == generation else { return }
        historyMtime = mtime
        let since = Date().addingTimeInterval(-24 * 3600)
        let points = await Task.detached(priority: .utility) {
            guard
                let data = try? UsageDataFiles.readRegularFile(
                    at: url, maximumBytes: UsageDataFiles.maximumLimitsHistoryBytes)
            else {
                return [LimitPoint]()
            }
            return LimitsHistory.parse(
                String(decoding: data, as: UTF8.self), since: since, provider: provider)
        }.value
        guard !terminating, limitHistoryGeneration == generation else { return }
        limitPoints = points
    }

    func runUpdate(collectMachines: Bool = true) {
        guard !terminating else { return }
        guard !updating else {
            pendingRefresh = true
            return
        }
        beginTranscript()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try? UsageAgentOperations.requestRefresh()
                _ = try await UsageRefreshFollower.follow { event in
                    Task { @MainActor in self.append(event) }
                }
            } catch let failure as UsageRefreshFailure {
                self.append(.failure(failure.description))
            } catch {
                self.append(.failure(error.localizedDescription))
            }
            await self.finishRefresh(generation: generation)
        }
    }

    private func beginTranscript() {
        updating = true
        refreshStartedAt = Date()
        refreshEvents = []
        log = UsageRefreshTranscript.render([], startedAt: refreshStartedAt ?? Date())
    }

    private func append(_ event: UsageRefreshEvent) {
        refreshEvents.append(event)
        log = UsageRefreshTranscript.render(
            refreshEvents, startedAt: refreshStartedAt ?? Date())
    }

    private func finishRefresh(generation: Int) async {
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        await loadStats()
        guard !Task.isCancelled, refreshGeneration == generation else { return }
        NotificationCenter.default.post(name: .usageDataChanged, object: nil)
        updating = false
        refreshTask = nil
        if pendingRefresh {
            pendingRefresh = false
            runUpdate(collectMachines: false)
        }
    }

    private func adoptExternalRefresh() {
        guard Self.acceptsExternalRefreshStart(updating: updating) else { return }
        beginTranscript()
        refreshGeneration += 1
        let generation = refreshGeneration
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await UsageRefreshFollower.follow { event in
                    Task { @MainActor in self.append(event) }
                }
            } catch let failure as UsageRefreshFailure {
                self.append(.failure(failure.description))
            } catch {
                self.append(.failure(error.localizedDescription))
            }
            await self.finishRefresh(generation: generation)
        }
    }

    private func scheduleRestoredUsageReload() {
        guard !terminating else { return }
        let generation = usageRestoreReloadGeneration.begin()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadStats()
            guard !self.terminating, self.usageRestoreReloadGeneration.accepts(generation) else {
                return
            }
            self.recomputeStats()
            NotificationCenter.default.post(name: .usageDataChanged, object: nil)
        }
    }

    private func scheduleRestoredLimitsReload() {
        guard !terminating else { return }
        let generation = limitsRestoreReloadGeneration.begin()
        Task { @MainActor [weak self] in
            await self?.reloadRestoredLimits(generation: generation)
        }
    }

    private func reloadRestoredLimits(generation: Int) async {
        await reloadLimitsFromHistory()
        guard !terminating, limitsRestoreReloadGeneration.accepts(generation) else { return }
        updateStatusItem()
    }

}

extension Notification.Name {
    static let usageDataChanged = Notification.Name("usageDataChanged")
}
