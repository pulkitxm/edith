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

struct HistoryWriteGate {
    private var waitingForSeed = true
    private var pending: Set<LimitProvider> = []

    mutating func record(_ provider: LimitProvider) -> Bool {
        guard waitingForSeed else { return true }
        pending.insert(provider)
        return false
    }

    mutating func finish() -> [LimitProvider] {
        waitingForSeed = false
        let providers = LimitProvider.allCases.filter(pending.contains)
        pending = []
        return providers
    }

    mutating func cancel() {
        pending = []
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

struct CredentialLookupFailurePresentation: Equatable {
    let message: String
    let diagnostic: String
    let schedulesQuickRetry: Bool
    let notifiesExpiredSession: Bool
}

enum ClaudeLimitsFetchError: Error, Equatable {
    case unauthorized
    case permissionDenied
    case rateLimited(after: TimeInterval?)
    case http(Int)
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

    private var claudeCredentialSession = ClaudeCredentialSession()
    private var retryNotBefore: Date?
    private var usageMtime: Date?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var locked = false
    private var sleeping = false
    private var lockObservers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshEvents: [UsageRefreshEvent] = []
    private var refreshStartedAt: Date?
    private var wakeTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    private var refreshRequestObserver: NSObjectProtocol?
    private var refreshStartedObserver: NSObjectProtocol?
    private var limitsRefreshObserver: NSObjectProtocol?
    private var usageRestoreObserver: NSObjectProtocol?
    private var limitsRestoreObserver: NSObjectProtocol?
    private var hasLiveLimits = false
    private var hasLiveCodexLimits = false
    private var limitsRefreshStartedAt: Date?
    private var limitsRefreshGeneration = 0
    private var quickRetries = 0
    private var quickRetryTask: Task<Void, Never>?
    private var machineTask: Task<Void, Never>?
    private var historySeedJob: Task<Void, Never>?
    private var historySeedGeneration = 0
    private var historyWriteGate = HistoryWriteGate()
    private var pendingRefresh = false
    private var refreshGeneration = 0
    private var terminating = false
    private var terminationPendingHistory: [LimitProvider] = []
    private var usageRestoreReloadGeneration = UsageReloadGenerationState()
    private var limitsRestoreReloadGeneration = UsageReloadGenerationState()
    private var statsReloadGeneration = UsageReloadGenerationState()
    let notifier = LimitNotifier()
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
        [(LimitProvider.claude, claude), (.codex, codex)].compactMap { provider, enabled in
            enabled ? provider : nil
        }
    }

    nonisolated static func canPublishLimitsRefresh(
        generation: Int, currentGeneration: Int, terminating: Bool, cancelled: Bool
    ) -> Bool {
        !terminating && !cancelled && generation == currentGeneration
    }

    init() {
        historySeedGeneration += 1
        let generation = historySeedGeneration
        historySeedJob = Task { [weak self] in
            let latest = await LimitsHistory.loadLatestProviders()
            guard !Task.isCancelled, let self, self.historySeedGeneration == generation else {
                return
            }
            let pendingProviders = self.historyWriteGate.finish()
            self.seedFromHistory(latest, excluding: Set(pendingProviders))
            await self.flushPendingHistory(pendingProviders)
            guard !Task.isCancelled, self.historySeedGeneration == generation else { return }
            self.historySeedJob = nil
            self.startPolling()
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.lifecycle.notice("going to sleep - pausing usage poll")
                self?.diag("going to sleep - pausing usage poll")
                self?.sleeping = true
                self?.stopPolling()
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                let msg = "woke from sleep (locked=\(self.locked))"
                Log.lifecycle.notice("\(msg, privacy: .public)")
                self.diag(msg)
                guard Self.pollingAllowed(locked: self.locked, sleeping: self.sleeping) else {
                    return
                }
                self.wakeTask?.cancel()
                self.wakeTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self,
                        Self.pollingAllowed(locked: self.locked, sleeping: self.sleeping)
                    else { return }
                    self.startPolling()
                }
            }
        }

        let dnc = DistributedNotificationCenter.default()
        lockObservers = [
            dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in
                    Log.lifecycle.notice("screen locked - pausing usage poll")
                    self?.diag("screen locked - pausing usage poll")
                    self?.locked = true
                    self?.stopPolling()
                }
            },
            dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main)
            { [weak self] _ in
                Task { @MainActor in
                    Log.lifecycle.notice("screen unlocked - resuming usage poll")
                    self?.diag("screen unlocked - resuming usage poll")
                    self?.locked = false
                    if let self,
                        Self.pollingAllowed(locked: self.locked, sleeping: self.sleeping)
                    {
                        self.startPolling()
                    }
                }
            },
        ]

        if let app = NSApp, app.isRunning {
            syncStatusItem()
        } else {
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.syncStatusItem() }
            }
        }

        refreshRequestObserver = IPC.observe(IPC.Name.requestUsageRefresh) { [weak self] in
            self?.runUpdate()
            Task { @MainActor in await self?.refreshLimits(force: true) }
        }

        refreshStartedObserver = IPC.observe(IPC.Name.usageRefreshStarted) { [weak self] in
            Task { @MainActor in self?.adoptExternalRefresh() }
        }

        limitsRefreshObserver = IPC.observe(IPC.Name.requestLimitsRefresh) { [weak self] in
            Task { @MainActor in await self?.refreshLimits(force: true) }
        }
        usageRestoreObserver = NotificationCenter.default.addObserver(
            forName: .usageBackupRestored, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRestoredUsageReload()
            }
        }
        limitsRestoreObserver = NotificationCenter.default.addObserver(
            forName: .limitsBackupRestored, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRestoredLimitsReload()
            }
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

    private func startPolling() {
        guard !terminating, Self.pollingAllowed(locked: locked, sleeping: sleeping), timer == nil
        else { return }
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshLimits()
                self?.runUpdate()
            }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.lifecycle.notice("usage polling started (every 300s)")
        Task { @MainActor in
            runUpdate()
            await refreshLimits()
            await loadStats()
        }
    }

    nonisolated static func pollingAllowed(locked: Bool, sleeping: Bool) -> Bool {
        !locked && !sleeping
    }

    nonisolated static func acceptsExternalRefreshStart(updating: Bool) -> Bool {
        !updating
    }

    private func stopPolling() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        Log.lifecycle.notice("usage polling stopped")
    }

    func shutdown() {
        terminating = true
        limitsRefreshGeneration += 1
        usageRestoreReloadGeneration.invalidate()
        limitsRestoreReloadGeneration.invalidate()
        statsReloadGeneration.invalidate()
        stopPolling()
        for obs in lockObservers { DistributedNotificationCenter.default().removeObserver(obs) }
        lockObservers = []
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
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
        notifier.cancelReminders()
        wakeTask?.cancel()
        wakeTask = nil
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let refreshRequestObserver {
            IPC.stopObserving(refreshRequestObserver)
            self.refreshRequestObserver = nil
        }
        if let refreshStartedObserver {
            IPC.stopObserving(refreshStartedObserver)
            self.refreshStartedObserver = nil
        }
        if let limitsRefreshObserver {
            IPC.stopObserving(limitsRefreshObserver)
            self.limitsRefreshObserver = nil
        }
        if let usageRestoreObserver {
            NotificationCenter.default.removeObserver(usageRestoreObserver)
            self.usageRestoreObserver = nil
        }
        if let limitsRestoreObserver {
            NotificationCenter.default.removeObserver(limitsRestoreObserver)
            self.limitsRestoreObserver = nil
        }
        quickRetryTask?.cancel()
        quickRetryTask = nil
        machineTask?.cancel()
        machineTask = nil
        historySeedGeneration += 1
        historySeedJob?.cancel()
        historySeedJob = nil
        historyWriteGate.cancel()
    }

    func syncStatusItem() {
        guard NSApp?.isRunning == true else { return }
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

    var nextLimitsRefresh: Date? {
        guard let fire = timer?.fireDate else { return nil }
        if let gate = retryNotBefore, gate > fire { return gate }
        return fire
    }

    func refreshLimits(force: Bool = false) async {
        guard !terminating else { return }
        let now = Date()
        switch LimitsRefreshGate.decide(
            force: force, inFlightSince: limitsRefreshStartedAt, retryNotBefore: retryNotBefore,
            now: now)
        {
        case .skipInFlight, .skipBackoff:
            return
        case .recoverStalled:
            let msg = "previous limits refresh never finished - starting a new one"
            Log.usage.error("\(msg, privacy: .public)")
            diag(msg)
        case .start:
            break
        }

        limitsRefreshGeneration += 1
        let generation = limitsRefreshGeneration
        limitsRefreshStartedAt = now
        refreshingLimits = true
        defer {
            if generation == limitsRefreshGeneration {
                limitsRefreshStartedAt = nil
                refreshingLimits = false
            }
        }

        let providers = Self.enabledLimitProviders(
            claude: providerEnabled(.claude), codex: providerEnabled(.codex))
        for provider in providers {
            guard !Task.isCancelled, !terminating, generation == limitsRefreshGeneration else {
                return
            }
            switch provider {
            case .claude: await fetchLimitsOnce(generation: generation)
            case .codex: await fetchCodexLimitsOnce(generation: generation)
            }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }

    private func canPublishLimitsRefresh(_ generation: Int) -> Bool {
        Self.canPublishLimitsRefresh(
            generation: generation, currentGeneration: limitsRefreshGeneration,
            terminating: terminating, cancelled: Task.isCancelled)
    }

    private func fetchLimitsOnce(generation: Int) async {
        guard canPublishLimitsRefresh(generation) else { return }
        var credential: ClaudeOAuthCredential
        switch await currentClaudeCredential() {
        case .credential(let resolved):
            guard canPublishLimitsRefresh(generation) else { return }
            credential = resolved
        case .failure(let failure):
            await handleCredentialLookupFailure(failure, generation: generation)
            return
        case .cancelled:
            return
        }
        do {
            if credential.shouldRefresh(at: Date()) {
                credential = try await refreshClaudeCredential(credential)
                guard canPublishLimitsRefresh(generation) else { return }
            }
            let usage = try await Self.fetchUsage(token: credential.accessToken)
            guard await apply(usage, generation: generation) else { return }
            let msg =
                "usage ok: session=\(Int((session?.percent ?? 0).rounded()))% week=\(Int((week?.percent ?? 0).rounded()))% fable=\(fableWeek.map { "\(Int($0.percent.rounded()))%" } ?? "n/a")"
            Log.usage.notice("\(msg, privacy: .public)")
            diag(msg)
            return
        } catch ClaudeLimitsFetchError.unauthorized {
            guard canPublishLimitsRefresh(generation) else { return }
            diag("401 unauthorized - resolving credentials once more")
            Log.usage.error("401 unauthorized - resolving credentials once more")
        } catch {
            await report(error, generation: generation)
            return
        }

        let latest: ClaudeOAuthCredential
        switch await currentClaudeCredential(
            reload: true, rejectingAccessToken: credential.accessToken)
        {
        case .credential(let resolved):
            guard canPublishLimitsRefresh(generation) else { return }
            latest = resolved
        case .failure(let failure):
            await handleCredentialLookupFailure(failure, generation: generation)
            return
        case .cancelled:
            return
        }
        do {
            let fresh: ClaudeOAuthCredential
            if latest.source == .shell {
                fresh = latest
            } else if latest.accessToken != credential.accessToken,
                !latest.shouldRefresh(at: Date())
            {
                fresh = latest
            } else {
                fresh = try await refreshClaudeCredential(latest)
                guard canPublishLimitsRefresh(generation) else { return }
            }
            let usage = try await Self.fetchUsage(token: fresh.accessToken)
            guard await apply(usage, generation: generation) else { return }
            Log.usage.notice("recovered after token refresh")
            diag("recovered after token refresh")
        } catch {
            await report(error, generation: generation)
        }
    }

    private func report(_ error: Error, generation: Int) async {
        guard canPublishLimitsRefresh(generation) else { return }
        let msg: String
        switch error {
        case ClaudeLimitsFetchError.unauthorized:
            limitsError = "Claude session expired - run claude to re-login"
            notifier.notifyTokenExpired()
            msg = "token refresh unavailable or rejected"
        case ClaudeLimitsFetchError.permissionDenied:
            limitsError = "Claude token cannot read usage - run claude auth login --claudeai"
            msg = "Claude usage permission denied"
        case ClaudeLimitsFetchError.rateLimited(let after):
            let deadline = LimitsRefreshGate.backoffDeadline(retryAfter: after, now: Date())
            retryNotBefore = deadline
            limitsError =
                "Rate limited by Claude - retrying at \(deadline.formatted(date: .omitted, time: .shortened))"
            msg = "429 rate limited - backing off \(Int(deadline.timeIntervalSinceNow))s"
        default:
            limitsError = "Offline"
            msg = "fetch failed: \(error.localizedDescription)"
        }
        Log.usage.error("\(msg, privacy: .public)")
        diag(msg)
        await clearClaudeLimits(generation: generation)
        scheduleQuickRetry()
    }

    private func scheduleQuickRetry() {
        guard !hasLiveLimits, quickRetries < 6, retryNotBefore == nil else { return }
        quickRetries += 1
        diag("no live limits yet - quick retry \(quickRetries)/6 in 20s")
        quickRetryTask?.cancel()
        quickRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshLimits()
        }
    }

    private func handleCredentialLookupFailure(
        _ failure: ClaudeCredentialLookupFailure, generation: Int
    ) async {
        guard canPublishLimitsRefresh(generation) else { return }
        let presentation = Self.credentialLookupFailurePresentation(for: failure)
        limitsError = presentation.message
        Log.usage.error("\(presentation.diagnostic, privacy: .public)")
        diag(presentation.diagnostic)
        await clearClaudeLimits(generation: generation)
        if presentation.notifiesExpiredSession { notifier.notifyTokenExpired() }
        if presentation.schedulesQuickRetry { scheduleQuickRetry() }
    }

    private func clearClaudeLimits(generation: Int) async {
        guard canPublishLimitsRefresh(generation) else { return }
        session = nil
        week = nil
        fableWeek = nil
        updateStatusItem()
        await recordHistory(.claude, generation: generation)
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

    private func keepOrBlankMenuBar() {
        if availableProviders.isEmpty {
            statusItem?.showUnavailable()
        } else {
            updateStatusItem()
        }
    }

    private func updateStatusItem() {
        statusItem?.update(availableProviders.map(limits(for:)))
    }

    private func apply(_ usage: ClaudeUsageParser.Result, generation: Int) async -> Bool {
        guard canPublishLimitsRefresh(generation) else { return false }
        session = usage.session
        week = usage.week
        fableWeek = usage.fable
        limitsError = nil
        limitsUpdatedAt = Date()
        retryNotBefore = nil
        hasLiveLimits = true
        quickRetryTask?.cancel()
        quickRetryTask = nil
        notifier.evaluate(session: session, week: week)
        updateStatusItem()
        await recordHistory(.claude, generation: generation)
        return canPublishLimitsRefresh(generation)
    }

    private func fetchCodexLimitsOnce(generation: Int) async {
        guard canPublishLimitsRefresh(generation) else { return }
        do {
            let limits = try await Task.detached(priority: .utility) {
                try Self.readCodexLimits()
            }.value
            guard canPublishLimitsRefresh(generation) else { return }
            codexSession = limits.session
            codexWeek = limits.week
            hasLiveCodexLimits = true
            limitsUpdatedAt = Date()
            updateStatusItem()
            await recordHistory(.codex, generation: generation)
            guard canPublishLimitsRefresh(generation) else { return }
            diag(
                "codex usage ok: session=\(Int((codexSession?.percent ?? 0).rounded()))% week=\(Int((codexWeek?.percent ?? 0).rounded()))%"
            )
        } catch {
            guard canPublishLimitsRefresh(generation) else { return }
            diag("codex limits unavailable: \(error.localizedDescription)")
            keepOrBlankMenuBar()
        }
    }

    private func recordHistory(_ provider: LimitProvider, generation: Int) async {
        guard canPublishLimitsRefresh(generation) else { return }
        if historyWriteGate.record(provider) {
            guard await persistHistory([historyEntry(for: provider)]) else { return }
        }
        guard canPublishLimitsRefresh(generation) else { return }
        IPC.post(IPC.Name.limitsUpdated)
    }

    private func flushPendingHistory(_ providers: [LimitProvider]) async {
        guard !providers.isEmpty else { return }
        if await persistHistory(providers.map(historyEntry)) {
            IPC.post(IPC.Name.limitsUpdated)
        }
    }

    private func historyEntry(for provider: LimitProvider) -> UsageHistoryPersistenceEntry {
        switch provider {
        case .claude:
            return UsageHistoryPersistenceEntry(
                provider: provider, session: session, week: week, fable: fableWeek)
        case .codex:
            return UsageHistoryPersistenceEntry(
                provider: provider, session: codexSession, week: codexWeek, fable: nil)
        }
    }

    @discardableResult
    private func persistHistory(_ entries: [UsageHistoryPersistenceEntry]) async -> Bool {
        guard await UsageHistoryPersistenceWorker.shared.persist(entries) else { return false }
        _ = await SettingsBackup.shared.syncLimits()
        return true
    }

    func drainHistoryPersistence(syncLimitsAfterDrain: Bool = true) async {
        let pending = terminationPendingHistory.map(historyEntry)
        if !pending.isEmpty {
            _ = await UsageHistoryPersistenceWorker.shared.persist(pending)
        }
        let persisted = await UsageHistoryPersistenceWorker.shared.drain()
        guard persisted else { return }
        terminationPendingHistory = []
        if syncLimitsAfterDrain {
            _ = await SettingsBackup.shared.syncLimits()
        }
        if !pending.isEmpty { IPC.post(IPC.Name.limitsUpdated) }
    }

    func prepareForTermination() {
        terminationPendingHistory = historyWriteGate.finish()
        shutdown()
    }

    private func scheduleRestoredUsageReload() {
        guard !terminating else { return }
        let generation = usageRestoreReloadGeneration.begin()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadStats()
            guard !self.terminating,
                self.usageRestoreReloadGeneration.accepts(generation)
            else { return }
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
        let latest = await LimitsHistory.loadLatestProviders()
        guard !terminating, limitsRestoreReloadGeneration.accepts(generation) else { return }
        var protected: Set<LimitProvider> = []
        if hasLiveLimits { protected.insert(.claude) }
        if hasLiveCodexLimits { protected.insert(.codex) }
        seedFromHistory(latest, excluding: protected)
        await loadLimitHistory(provider: limitHistoryProvider)
        guard !terminating, limitsRestoreReloadGeneration.accepts(generation) else { return }
        updateStatusItem()
    }

    private struct CodexWindow: Decodable {
        let usedPercent: Double
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    private struct CodexSnapshot: Decodable {
        let primary: CodexWindow?
        let secondary: CodexWindow?
    }

    private struct CodexRateLimitsResult: Decodable {
        let rateLimits: CodexSnapshot?
    }

    private struct CodexResponse: Decodable {
        let id: Int?
        let result: CodexRateLimitsResult?
    }

    private enum CodexLimitsError: LocalizedError {
        case executableMissing
        case unavailable

        var errorDescription: String? {
            switch self {
            case .executableMissing: return "Codex is not installed"
            case .unavailable: return "Codex limits are unavailable"
            }
        }
    }

    private nonisolated static let codexReadTimeout: TimeInterval = 25

    private nonisolated static func readCodexLimits() throws -> ProviderLimits {
        guard let executable = codexExecutable() else { throw CodexLimitsError.executableMissing }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = CLIToolEnvironment.sanitized()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            Log.usage.error("codex app-server stopped responding - killing it")
            kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + codexReadTimeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object)
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }

        func response(id: Int) throws -> CodexResponse {
            var buffer = Data()
            while process.isRunning {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if let value = try? JSONDecoder().decode(CodexResponse.self, from: line),
                        value.id == id
                    {
                        return value
                    }
                }
            }
            throw CodexLimitsError.unavailable
        }

        try send([
            "method": "initialize", "id": 0,
            "params": [
                "clientInfo": ["name": "edith", "title": "Edith", "version": "1.0"]
            ],
        ])
        _ = try response(id: 0)
        try send(["method": "initialized", "params": [:]])
        try send(["method": "account/rateLimits/read", "id": 1, "params": [:]])
        guard let snapshot = try response(id: 1).result?.rateLimits else {
            throw CodexLimitsError.unavailable
        }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let mapped = windows.map { window in
            (
                duration: window.windowDurationMins ?? 0,
                value: LimitWindow(
                    percent: window.usedPercent,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            )
        }.sorted { $0.duration < $1.duration }
        let session = mapped.first { $0.duration > 0 && $0.duration < 7 * 24 * 60 }?.value
        let week = mapped.last { $0.duration >= 7 * 24 * 60 }?.value ?? mapped.last?.value
        return ProviderLimits(provider: .codex, session: session, week: week)
    }

    private nonisolated static func codexExecutable() -> URL? {
        CLIToolEnvironment.executable(named: "codex")
    }

    private nonisolated static let limitsSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private nonisolated static func fetchUsage(token: String) async throws
        -> ClaudeUsageParser.Result
    {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15
        let (data, resp) = try await limitsSession.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 { Log.usage.error("GET /oauth/usage -> HTTP \(code, privacy: .public)") }
        let after = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
            .flatMap(TimeInterval.init)
        if let error = fetchError(statusCode: code, retryAfter: after) { throw error }
        return try ClaudeUsageParser.parse(data)
    }

    nonisolated static func fetchError(
        statusCode: Int, retryAfter: TimeInterval? = nil
    ) -> ClaudeLimitsFetchError? {
        switch statusCode {
        case 200: return nil
        case 401: return .unauthorized
        case 403: return .permissionDenied
        case 429: return .rateLimited(after: retryAfter)
        default: return .http(statusCode)
        }
    }

    private func currentClaudeCredential(
        reload: Bool = false, rejectingAccessToken: String? = nil
    ) async -> ClaudeCredentialLookup {
        let lookup =
            reload
            ? await claudeCredentialSession.reload(rejectingAccessToken: rejectingAccessToken)
            : await claudeCredentialSession.current()
        guard case .credential(let credential) = lookup else { return lookup }
        switch credential.source {
        case .keychain:
            Log.usage.notice("token read from keychain (security CLI)")
        case .file:
            Log.usage.notice("token read from ~/.claude/.credentials.json")
        case .shell:
            Log.usage.notice("token read from login shell environment")
        }
        return lookup
    }

    static func credentialLookupFailurePresentation(
        for failure: ClaudeCredentialLookupFailure
    ) -> CredentialLookupFailurePresentation {
        switch failure {
        case .missing:
            CredentialLookupFailurePresentation(
                message: "Claude Code token not found",
                diagnostic: "token not found in keychain, credentials file, or login shell",
                schedulesQuickRetry: false, notifiesExpiredSession: false)
        case .rejected:
            CredentialLookupFailurePresentation(
                message: "Claude session expired - run claude to re-login",
                diagnostic: "rejected credential remained unchanged across available sources",
                schedulesQuickRetry: false, notifiesExpiredSession: true)
        case .malformed:
            CredentialLookupFailurePresentation(
                message: "Credential data is invalid",
                diagnostic: "credential data was malformed",
                schedulesQuickRetry: false, notifiesExpiredSession: false)
        case .timedOut:
            CredentialLookupFailurePresentation(
                message: "Credential lookup timed out",
                diagnostic: "credential lookup timed out",
                schedulesQuickRetry: true, notifiesExpiredSession: false)
        case .oversized:
            CredentialLookupFailurePresentation(
                message: "Credential data is too large",
                diagnostic: "credential data exceeded its safe limit",
                schedulesQuickRetry: false, notifiesExpiredSession: false)
        case .failed:
            CredentialLookupFailurePresentation(
                message: "Could not read credentials",
                diagnostic: "credential lookup failed",
                schedulesQuickRetry: true, notifiesExpiredSession: false)
        }
    }

    private func refreshClaudeCredential(_ credential: ClaudeOAuthCredential) async throws
        -> ClaudeOAuthCredential
    {
        let now = Date()
        guard let refreshToken = credential.usableRefreshToken(at: now) else {
            throw ClaudeLimitsFetchError.unauthorized
        }
        diag("refreshing Claude access token")
        let response = try await Self.fetchRefreshedClaudeToken(refreshToken: refreshToken)
        let data = try credential.updatedData(with: response, now: now)
        try await ClaudeCredentialStore.persist(data, source: credential.source)
        guard let refreshed = ClaudeOAuthCredential.decode(data, source: credential.source) else {
            throw ClaudeLimitsFetchError.unauthorized
        }
        claudeCredentialSession.store(refreshed)
        Log.usage.notice("Claude access token refreshed and saved")
        diag("Claude access token refreshed and saved")
        return refreshed
    }

    private nonisolated static func fetchRefreshedClaudeToken(refreshToken: String) async throws
        -> ClaudeOAuthRefreshResponse
    {
        var request = URLRequest(
            url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ])
        let (data, response) = try await limitsSession.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200:
            return try JSONDecoder().decode(ClaudeOAuthRefreshResponse.self, from: data)
        case 400, 401, 403:
            throw ClaudeLimitsFetchError.unauthorized
        case 429:
            let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init)
            throw ClaudeLimitsFetchError.rateLimited(after: after)
        default:
            throw ClaudeLimitsFetchError.http(code)
        }
    }

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
        if collectMachines { collectFromMachines(force: false) }
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
                if UsageRefreshRunner.isRunning {
                    _ = try await UsageRefreshFollower.follow { event in
                        Task { @MainActor in self.append(event) }
                    }
                } else {
                    _ = try await UsageRefreshRunner.run { event in
                        Task { @MainActor in self.append(event) }
                    }
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
        _ = await SettingsBackup.shared.syncUsage()
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

    private func collectFromMachines(force: Bool) {
        guard machineTask == nil else { return }
        machineTask = Task { [weak self] in
            let due = await Task.detached(priority: .utility) {
                MachineUsageRound.due(force: force)
            }.value
            guard !Task.isCancelled else { return }
            guard !due.isEmpty else {
                self?.finishedCollecting(changed: false)
                return
            }
            self?.diag("collecting usage from \(due.count) machine(s)")
            let result = await MachineUsageRound.collect(due) { event in
                let lines = UsageRefreshTranscript.lines(for: event)
                Task { @MainActor in
                    for line in lines { self?.noteMachine(line) }
                }
            }
            guard !Task.isCancelled else { return }
            self?.finishedCollecting(changed: result.changedAnything)
        }
    }

    private func noteMachine(_ message: String) {
        Log.usage.notice("machine usage \(message, privacy: .public)")
        diag("machine usage \(message)")
    }

    private func finishedCollecting(changed: Bool) {
        machineTask = nil
        guard changed else { return }
        guard !updating else {
            pendingRefresh = true
            return
        }
        runUpdate(collectMachines: false)
    }
}

extension Notification.Name {
    static let usageDataChanged = Notification.Name("usageDataChanged")
}
