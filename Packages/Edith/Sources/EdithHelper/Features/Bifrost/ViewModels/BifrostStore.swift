import AppKit
import EdithKit
import Foundation

@MainActor
@Observable
final class BifrostStore: FeatureModule {
    private(set) var applications: [BifrostApplication] = []
    private(set) var commands: [BifrostCommand] = []
    private(set) var indexedAt: Date?
    private(set) var isIndexing = false
    private(set) var revision = 0

    private var ledger: BifrostUsageLedger
    private var indexTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var isShutDown = false
    private let store: UserDefaults
    private let indexStore: BifrostIndexStore
    private let scan: @Sendable () -> [BifrostApplication]
    private let open: @MainActor (String) -> Bool
    private let copy: @MainActor (String) -> Void
    private let post: @MainActor (Notification.Name) -> Void

    required convenience init() {
        self.init(
            store: SharedDefaults.store, indexStore: .shared,
            scan: { BifrostApplicationScanner.scan(roots: BifrostApplicationScanner.defaultRoots) },
            open: { BifrostLauncher.open(path: $0) },
            copy: { BifrostLauncher.copy(text: $0) },
            post: { IPC.post($0) })
    }

    init(
        store: UserDefaults, indexStore: BifrostIndexStore,
        scan: @escaping @Sendable () -> [BifrostApplication],
        open: @escaping @MainActor (String) -> Bool,
        copy: @escaping @MainActor (String) -> Void,
        post: @escaping @MainActor (Notification.Name) -> Void = { IPC.post($0) }
    ) {
        self.store = store
        self.indexStore = indexStore
        self.scan = scan
        self.open = open
        self.copy = copy
        self.post = post
        ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        commands = BifrostCommandCatalog.available(in: store)
        if let cached = indexStore.load() {
            applications = cached.applications
            indexedAt = cached.generatedAt
        }
        observers = [
            IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                Task { @MainActor in self?.adoptSettings() }
            },
            IPC.observe(IPC.Name.requestBifrostReindex) { [weak self] in
                Task { @MainActor in self?.reindex() }
            },
        ]
        if applications.isEmpty { reindex() }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        indexTask?.cancel()
        indexTask = nil
        for observer in observers { IPC.stopObserving(observer) }
        observers = []
    }

    var resultLimit: Int { BifrostSummary.resultLimit(store: store) }

    func results(for query: String, now: Date = Date()) -> [BifrostResult] {
        BifrostQuery.results(
            query: query, applications: applications, commands: commands, ledger: ledger,
            now: now, limit: resultLimit)
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
            post(command.notification)
            record(result.action.targetKey, query: query, at: now)
            return true
        case .copy(let text):
            copy(text)
            return true
        }
    }

    func copy(_ result: BifrostResult) {
        copy(result.action.copyText)
    }

    func forget(_ targetKey: String) {
        ledger.forget(targetKey)
        persistLedger()
    }

    func reindex() {
        guard !isShutDown, !isIndexing else { return }
        isIndexing = true
        indexTask?.cancel()
        let scan = scan
        let indexStore = indexStore
        indexTask = Task.detached(priority: .utility) { [weak self] in
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
        guard !isShutDown, let index else { return }
        applications = index.applications
        indexedAt = index.generatedAt
        store.set(index.generatedAt.timeIntervalSince1970, forKey: AppStorageKeys.Bifrost.indexedAt)
        revision += 1
        IPC.post(IPC.Name.bifrostIndexChanged)
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
        ledger = BifrostUsageLedger.load(from: store, key: AppStorageKeys.Bifrost.usage)
        commands = BifrostCommandCatalog.available(in: store)
        revision += 1
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
