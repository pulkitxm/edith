import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor
@Observable
final class BifrostStore: FeatureModule {
    private(set) var applications: [BifrostApplication] = []
    private(set) var commands: [BifrostCommand] = []
    private(set) var entries: [BifrostEntry] = []
    private(set) var rates: BifrostRates?
    private(set) var mode: BifrostMode = .launcher
    private(set) var scope: BifrostScope = BifrostScopeCatalog.clipboard()[0]
    private(set) var target: BifrostSearchTarget = .name
    private(set) var searchKind: BifrostSearchKind = .everything
    private(set) var machines: [String] = []
    private(set) var modeResults: [BifrostResult] = []
    private(set) var isLoadingMode = false
    private(set) var indexedAt: Date?
    private(set) var isIndexing = false
    private(set) var revision = 0

    private var ledger: BifrostUsageLedger
    private var indexTask: Task<Void, Never>?
    private var sourcesTask: Task<Void, Never>?
    private var shortcutNames: [String] = []
    private var runningApplications: [BifrostRunningApplication] = []
    private var openWindows: [BifrostWindowHandle] = []
    private var ratesTask: Task<Void, Never>?
    private var modeTask: Task<Void, Never>?
    private var actionTasks: [UUID: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var isShutDown = false
    private var suspending = false
    private var modeEpoch = UUID()
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private let store: UserDefaults
    private let indexStore: BifrostIndexStore
    private let rateStore: BifrostRateStore
    private let fetchRates: @Sendable () async -> BifrostRates?
    private let scan: @Sendable () -> [BifrostApplication]
    private let open: @MainActor (String) -> Bool
    private let copy: @MainActor (String) -> Void
    private let post: @MainActor (Notification.Name) -> Void

    required convenience init() {
        self.init(
            store: SharedDefaults.store, indexStore: .shared,
            rateStore: .shared,
            startServices: ExtensionEnvironment.values["EDITH_EXTENSION_RECOVERY_ONLY"]
                != "1",
            fetchRates: { BifrostFixture.enabled ? nil : await BifrostRateFeed.fetch() },
            scan: {
                BifrostFixture.enabled
                    ? BifrostFixture.applications
                    : BifrostApplicationScanner.scan(roots: BifrostApplicationScanner.defaultRoots)
            },
            open: { BifrostLauncher.open(path: $0) },
            copy: { BifrostLauncher.copy(text: $0) },
            post: { BifrostIPC.post($0) })
    }

    init(
        store: UserDefaults, indexStore: BifrostIndexStore,
        rateStore: BifrostRateStore = .shared,
        startServices: Bool = true,
        fetchRates: @escaping @Sendable () async -> BifrostRates? = { nil },
        scan: @escaping @Sendable () -> [BifrostApplication],
        open: @escaping @MainActor (String) -> Bool,
        copy: @escaping @MainActor (String) -> Void,
        post: @escaping @MainActor (Notification.Name) -> Void = { BifrostIPC.post($0) }
    ) {
        self.store = store
        self.indexStore = indexStore
        self.rateStore = rateStore
        self.fetchRates = fetchRates
        self.scan = scan
        self.open = open
        self.copy = copy
        self.post = post
        ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        commands = BifrostCommandCatalog.available(in: store)
        rates = rateStore.load()
        entries = BifrostEntryCatalog.entries(sources: BifrostSource.enabled(in: store))
        if let cached = indexStore.load() {
            applications = cached.applications
            indexedAt = cached.generatedAt
        }
        guard startServices else { return }
        observers = [
            BifrostIPC.observe(BifrostIPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.adoptSettings() }
            },
            BifrostIPC.observe(BifrostIPC.Name.requestBifrostReindex) { [weak self] in
                MainActor.assumeIsolated { self?.reindex() }
            },
        ]
        if applications.isEmpty { reindex() }
        refreshRates()
    }

    private func track(
        priority: TaskPriority = .userInitiated,
        _ work: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never>? {
        guard !suspending, !isShutDown, ownedTasks.count < 64 else { return nil }
        let id = UUID()
        let task = Task.detached(priority: priority) { [self] in
            await work()
            await retireTask(id)
        }
        ownedTasks[id] = task
        return task
    }

    private func retireTask(_ id: UUID) { ownedTasks[id] = nil }

    func cancelPendingCommands() {
        suspending = true
        modeEpoch = UUID()
        for task in ownedTasks.values { task.cancel() }
        for task in actionTasks.values { task.cancel() }
        for observer in observers { BifrostIPC.stopObserving(observer) }
        observers = []
    }

    func shutdown() {
        cancelPendingCommands()
        isShutDown = true
    }

    func drain() async {
        cancelPendingCommands()
        while let task = ownedTasks.values.first { await task.value }
        while let task = actionTasks.values.first { await task.value }
    }

    var resultLimit: Int { BifrostSummary.resultLimit(store: store) }

    func results(for query: String, now: Date = Date()) -> [BifrostResult] {
        BifrostQuery.results(
            query: query, applications: applications, commands: commands, entries: entries,
            ledger: ledger,
            rates: rates, now: now, limit: resultLimit)
    }

    var scopes: [BifrostScope] { BifrostScopeCatalog.scopes(for: mode, machines: machines) }

    func enter(_ mode: BifrostMode, query: String = "") {
        guard self.mode != mode else { return }
        self.mode = mode
        scope =
            BifrostScopeCatalog.scopes(for: mode).first
            ?? BifrostScope(id: "all", title: "All")
        modeResults = []
        loadMode(query: query)
    }

    func leaveMode() {
        guard mode != .launcher else { return }
        modeTask?.cancel()
        modeTask = nil
        mode = .launcher
        modeResults = []
        isLoadingMode = false
        revision += 1
    }

    func select(scope: BifrostScope, query: String) {
        guard scope != self.scope else { return }
        self.scope = scope
        loadMode(query: query)
    }

    func select(target: BifrostSearchTarget, query: String) {
        guard target != self.target else { return }
        self.target = target
        loadMode(query: query)
    }

    func select(searchKind: BifrostSearchKind, query: String) {
        guard searchKind != self.searchKind else { return }
        self.searchKind = searchKind
        loadMode(query: query)
    }

    func loadMode(query: String, now: Date = Date()) {
        guard !suspending, !isShutDown, mode != .launcher else { return }
        modeTask?.cancel()
        let epoch = UUID()
        modeEpoch = epoch
        isLoadingMode = true
        let mode = mode
        let scope = scope
        switch mode {
        case .launcher:
            return
        case .clipboard:
            modeTask = track(priority: .userInitiated) { [weak self] in
                let entries = (try? await BifrostPeers.clipboardEntries()) ?? []
                guard !Task.isCancelled else { return }
                let results = BifrostClipboardFeed.results(
                    entries: entries, query: query, scope: scope.id, now: now)
                await self?.publish(results, for: mode, epoch: epoch)
            }
        case .files:
            let plan = BifrostSearchPlan(
                query: query, root: scope.path, target: target, kind: searchKind,
                machine: scope.machine)
            modeTask = track(priority: .userInitiated) { [weak self] in
                let files = await BifrostFileSearch.search(plan: plan)
                guard !Task.isCancelled else { return }
                let results = BifrostFileSearch.results(files: files, now: now, query: query)
                await self?.publish(results, for: mode, epoch: epoch)
            }
        }
    }

    private func publish(_ results: [BifrostResult], for mode: BifrostMode, epoch: UUID) {
        guard !suspending, !isShutDown, !suspending, modeEpoch == epoch, self.mode == mode else {
            return
        }
        modeResults = results
        isLoadingMode = false
        modeTask = nil
        revision += 1
    }

    func refreshRates(now: Date = Date()) {
        guard !suspending, !isShutDown, ratesTask == nil else { return }
        if let rates, rates.isFresh(now: now) { return }
        let fetchRates = fetchRates
        let rateStore = rateStore
        ratesTask = track(priority: .utility) { [weak self] in
            let fetched = await fetchRates()
            guard !Task.isCancelled else {
                await self?.finishRates(nil)
                return
            }
            if let fetched { rateStore.save(fetched) }
            await self?.finishRates(fetched)
        }
    }

    private func ownAction(_ operation: @escaping @MainActor () async -> Void) {
        guard !suspending, !isShutDown, actionTasks.count < 64 else { return }
        let token = UUID()
        actionTasks[token] = Task { [weak self] in
            await operation()
            self?.actionTasks[token] = nil
        }
    }

    func prepareDisable() async throws {
        let tasks = Array(actionTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }

    private func finishRates(_ fetched: BifrostRates?) {
        ratesTask = nil
        guard !suspending, !isShutDown, let fetched else { return }
        rates = fetched
        revision += 1
    }

    @discardableResult
    func run(_ result: BifrostResult, query: String = "", now: Date = Date()) -> Bool {
        switch result.action {
        case .launch(let path):
            guard open(path) else { return false }
            record(result.action.targetKey, query: query, at: now)
            return true
        case .run(let commandID):
            guard let command = BifrostCommandCatalog.command(id: commandID) else { return false }
            if let mode = command.mode {
                enter(mode)
                record(result.action.targetKey, query: query, at: now)
                return true
            }
            if command.id == "panel.open" {
                ownAction { _ = try? await BifrostPeers.open(owner: "bifrost") }
            } else if let owner = command.abilityID, owner != "bifrost" {
                ownAction { _ = try? await BifrostPeers.pick(owner: owner) }
            } else {
                post(command.notification)
            }
            record(result.action.targetKey, query: query, at: now)
            return true
        case .copy(let text):
            copy(text)
            return true
        default:
            let argument = keywordArgument(for: result, query: query)
            let action = result.action
            let defaults = store
            ownAction {
                _ = await BifrostActionRunner.perform(
                    action, argument: argument, defaults: defaults)
            }
            record(result.action.targetKey, query: query, at: now)
            return true
        }
    }

    func keywordArgument(for result: BifrostResult, query: String) -> String {
        guard BifrostQuery.keywordRoute(query, entries: entries)?.id == result.id else {
            return ""
        }
        return BifrostQuery.keywordArgument(query)
    }

    func copy(_ result: BifrostResult) {
        copy(result.copyText)
    }

    func forget(_ targetKey: String) {
        ledger.forget(targetKey)
        persistLedger()
    }

    func reindex() {
        guard !suspending, !isShutDown, !isIndexing else { return }
        isIndexing = true
        indexTask?.cancel()
        let scan = scan
        let indexStore = indexStore
        indexTask = track(priority: .utility) { [weak self] in
            let scanned = scan()
            guard !Task.isCancelled else {
                await self?.finishIndexing(nil)
                return
            }
            let index = BifrostIndex(generatedAt: Date(), applications: scanned)
            indexStore.save(index)
            await self?.finishIndexing(index)
        }
    }

    private func finishIndexing(_ index: BifrostIndex?) {
        isIndexing = false
        indexTask = nil
        guard !suspending, !isShutDown, let index else { return }
        applications = index.applications
        indexedAt = index.generatedAt
        store.set(index.generatedAt.timeIntervalSince1970, forKey: AppStorageKeys.Bifrost.indexedAt)
        revision += 1
        BifrostIPC.post(BifrostIPC.Name.bifrostIndexChanged)
    }

    private func record(_ targetKey: String, query: String, at moment: Date) {
        ledger.record(targetKey, query: query, at: moment)
        persistLedger()
    }

    private func persistLedger() {
        ledger.save(to: store, key: AppStorageKeys.Bifrost.usage)
        revision += 1
    }

    private func adoptSettings() {
        guard !suspending, !isShutDown else { return }
        ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        commands = BifrostCommandCatalog.available(in: store)
        rebuildEntries()
        revision += 1
    }

    func refreshDynamicSources() {
        guard !suspending, !isShutDown else { return }
        let sources = BifrostSource.enabled(in: store)
        runningApplications =
            sources.contains(.runningApplications) ? BifrostRunningApps.applications() : []
        rebuildEntries()
        let wantsWindows = sources.contains(.openWindows)
        let wantsShortcuts = sources.contains(.appleShortcuts)
        guard wantsWindows || wantsShortcuts else { return }
        let hasShortcuts = !shortcutNames.isEmpty
        sourcesTask?.cancel()
        sourcesTask = track { [weak self] in
            var windows: [BifrostWindowHandle] = []
            if wantsWindows {
                windows = await Task.detached(priority: .utility) {
                    BifrostRunningApps.windows()
                }.value
            }
            var names: [String] = []
            if wantsShortcuts, !hasShortcuts { names = await BifrostShortcutsIndex.names() }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self, windows, names] in
                self?.adoptDynamicSources(windows: windows, shortcuts: names)
            }
        }
    }

    private func adoptDynamicSources(windows: [BifrostWindowHandle], shortcuts: [String]) {
        guard !suspending, !isShutDown else { return }
        openWindows = windows
        if !shortcuts.isEmpty { shortcutNames = shortcuts }
        rebuildEntries()
        revision += 1
    }

    private func rebuildEntries() {
        entries = BifrostEntryCatalog.entries(
            sources: BifrostSource.enabled(in: store),
            quicklinks: BifrostLibraryStore.quicklinks(store),
            snippets: BifrostLibraryStore.snippets(store),
            shellCommands: BifrostLibraryStore.shellCommands(store),
            shortcuts: shortcutNames, runningApplications: runningApplications,
            openWindows: openWindows)
    }
}

enum BifrostLauncher {
    @MainActor
    static func open(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        NSWorkspace.shared.openApplication(
            at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    @MainActor
    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
