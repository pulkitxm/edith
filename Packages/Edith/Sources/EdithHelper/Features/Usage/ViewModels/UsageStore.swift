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

@MainActor
@Observable
final class UsageStore: FeatureModule {
    private(set) var session: LimitWindow?
    private(set) var week: LimitWindow?
    private(set) var fableWeek: LimitWindow?
    private(set) var codexSession: LimitWindow?
    private(set) var codexWeek: LimitWindow?
    private(set) var cursorSession: LimitWindow?
    private(set) var cursorWeek: LimitWindow?
    private(set) var grokWeek: LimitWindow?
    private(set) var grokAllowance: GrokAllowance?
    private(set) var limitsError: String?
    private(set) var limitsUpdatedAt: Date?
    private(set) var refreshingLimits = false
    private(set) var claudeAccounts: [ClaudeAccountLimits] = []

    private var initialLimitsLoaded = false
    private var knownAccountConfiguration: [ClaudeAccount] = []
    private let accountsStorage: ClaudeAccountStorage
    private let accountLimits: ClaudeAccountLimitsCollector
    private var claudeUnavailable = false
    private var launchObserver: NSObjectProtocol?
    private var limitsUpdatedObserver: NSObjectProtocol?
    private var limitsTopicTask: Task<Void, Never>?
    private var limitsRequestTask: Task<Void, Never>?
    private var limitsRestoreObserver: NSObjectProtocol?
    private var terminating = false
    private var limitsRestoreReloadGeneration = UsageReloadGenerationState()
    private var statusItem: LimitsStatusItem?

    var enabledProviders: [LimitProvider] {
        Self.enabledLimitProviders(
            claude: providerEnabled(.claude), codex: providerEnabled(.codex),
            cursor: providerEnabled(.cursor), grok: providerEnabled(.grok))
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
        case .cursor:
            return ProviderLimits(
                provider: provider, session: Self.fresh(cursorSession),
                week: Self.fresh(cursorWeek))
        case .grok:
            let week = Self.fresh(grokWeek)
            return ProviderLimits(
                provider: provider, session: nil, week: week,
                grok: week == nil ? nil : grokAllowance)
        }
    }

    private nonisolated static func fresh(_ window: LimitWindow?) -> LimitWindow? {
        window.flatMap { ($0.resetsAt ?? .distantFuture) > Date() ? $0 : nil }
    }

    func providerEnabled(_ provider: LimitProvider) -> Bool {
        LimitsCollector.providerEnabled(provider)
    }

    nonisolated static func enabledLimitProviders(
        claude: Bool, codex: Bool, cursor: Bool, grok: Bool
    ) -> [LimitProvider] {
        UsageLimitProviders.enabled(claude: claude, codex: codex, cursor: cursor, grok: grok)
    }

    convenience init() {
        self.init(accountsDirectory: ClaudeAccountStorage.directory)
    }

    init(
        accountsDirectory: URL,
        accountLimits: ClaudeAccountLimitsCollector = .shared
    ) {
        accountsStorage = ClaudeAccountStorage(directory: accountsDirectory)
        self.accountLimits = accountLimits
        Task { @MainActor [weak self] in
            await self?.reloadLimitsFromHistory()
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

        limitsUpdatedObserver = IPC.observe(IPC.Name.limitsUpdated) { [weak self] in
            Task { @MainActor in await self?.reloadLimitsFromHistory() }
        }

        limitsTopicTask = Task { @MainActor [weak self] in
            for await snapshot in AgentTopicStream.values(LimitsTopicSnapshot.self, topic: .limits)
            {
                guard !Task.isCancelled else { return }
                await self?.receiveLimitsSnapshot(snapshot)
            }
        }

        limitsRestoreObserver = IPC.observe(BackgroundBackupSignal.limitsRestored) { [weak self] in
            Task { @MainActor in self?.scheduleRestoredLimitsReload() }
        }
    }

    private func seedFromHistory(_ latest: [LimitProvider: LimitsHistory.Latest]) {
        if !claudeUnavailable, let last = latest[.claude] {
            session = Self.fresh(last.session)
            week = Self.fresh(last.week)
            fableWeek = Self.fresh(last.fable)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if let last = latest[.codex] {
            codexSession = Self.fresh(last.session)
            codexWeek = Self.fresh(last.week)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if let last = latest[.cursor] {
            cursorSession = Self.fresh(last.session)
            cursorWeek = Self.fresh(last.week)
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
        if let last = latest[.grok] {
            grokWeek = Self.fresh(last.week)
            grokAllowance = grokWeek == nil ? nil : last.grok
            limitsUpdatedAt = max(limitsUpdatedAt ?? .distantPast, last.date)
        }
    }

    func shutdown() {
        terminating = true
        limitsRestoreReloadGeneration.invalidate()
        limitsTopicTask?.cancel()
        limitsRequestTask?.cancel()
        limitsTopicTask = nil
        limitsRequestTask = nil
        statusItem?.remove()
        statusItem = nil
        if let launchObserver {
            NotificationCenter.default.removeObserver(launchObserver)
            self.launchObserver = nil
        }
        if let limitsUpdatedObserver {
            IPC.stopObserving(limitsUpdatedObserver)
            self.limitsUpdatedObserver = nil
        }
        if let limitsRestoreObserver {
            IPC.stopObserving(limitsRestoreObserver)
            self.limitsRestoreObserver = nil
        }
    }

    func syncStatusItem() {
        guard initialLimitsLoaded, NSApp != nil else { return }
        let on =
            SharedDefaults.store.object(forKey: AppStorageKeys.Limits.inMenuBar) as? Bool ?? true
        if on, statusItem == nil {
            statusItem = LimitsStatusItem(store: self)
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

    func refreshLimits(force: Bool = false) async {
        guard !terminating else { return }
        refreshingLimits = true
        limitsError = nil
        limitsRequestTask?.cancel()
        do {
            try UsageAgentOperations.requestLimitsRefresh()
            limitsRequestTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(90)) } catch { return }
                guard !Task.isCancelled, let self, !self.terminating, self.refreshingLimits else {
                    return
                }
                self.refreshingLimits = false
                self.limitsError = "The background agent did not finish refreshing limits."
            }
        } catch {
            refreshingLimits = false
            limitsError = error.localizedDescription
        }
    }

    func receiveLimitsSnapshot(_ snapshot: LimitsTopicSnapshot) async {
        guard !terminating else { return }
        if let claude = snapshot.providers.first(where: { $0.provider == .claude }) {
            claudeUnavailable = claude.error != nil && claude.session == nil
            session = Self.fresh(claude.session)
            week = Self.fresh(claude.week)
            fableWeek = Self.fresh(claude.fable)
        }
        await reloadLimitsFromHistory(incomingAccounts: snapshot.claudeAccounts)
        limitsError =
            snapshot.failure
            ?? snapshot.providers.first {
                (claudeAccounts.isEmpty || $0.provider != .claude) && $0.error != nil
            }?.error
        refreshingLimits = false
        limitsRequestTask?.cancel()
        limitsRequestTask = nil
    }

    func reloadLimitsFromHistory(incomingAccounts: [ClaudeAccountLimits] = []) async {
        guard !terminating else { return }
        let configured: [ClaudeAccount]
        do {
            configured = providerEnabled(.claude) ? try await accountsStorage.load().accounts : []
        } catch {
            limitsError = "Could not load saved Claude accounts."
            return
        }
        let saved = await accountLimits.cachedSnapshots(accounts: configured)
        guard !terminating else { return }
        let incoming = Dictionary(
            incomingAccounts.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let unchanged = Set(configured.filter { knownAccountConfiguration.contains($0) }.map(\.id))
        let previous = Dictionary(
            claudeAccounts.filter { unchanged.contains($0.id) }.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last })
        knownAccountConfiguration = configured
        claudeAccounts = saved.map { account in
            guard let received = incoming[account.id] ?? previous[account.id] else {
                return account
            }
            let hasCachedReading =
                account.limits.session != nil || account.limits.week != nil
                || account.limits.fable != nil
            if incoming[account.id] == nil, hasCachedReading,
                account.refreshedAt > received.refreshedAt
            {
                return account
            }
            let limits = LimitsProviderSnapshot(
                provider: .claude, session: Self.fresh(received.limits.session),
                week: Self.fresh(received.limits.week), fable: Self.fresh(received.limits.fable),
                error: received.limits.error)
            return ClaudeAccountLimits(
                id: account.id, name: account.name, limits: limits,
                refreshedAt: received.refreshedAt, retryAt: received.retryAt)
        }
        initialLimitsLoaded = true
        if NSApp?.isRunning == true { syncStatusItem() }
        updateStatusItem()
        let latest = await LimitsHistory.loadLatestProviders()
        guard !terminating else { return }
        seedFromHistory(latest)
        updateStatusItem()
    }

    func prepareForTermination() {
        shutdown()
    }

    private func updateStatusItem() {
        statusItem?.update(availableProviders.map(limits(for:)))
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
