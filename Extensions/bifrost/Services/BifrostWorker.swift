import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor protocol BifrostWorkerPanel: AnyObject {
    var store: BifrostStore? { get set }
    func toggle(query: String)
    func shutdown()
}

extension BifrostPanel: BifrostWorkerPanel {}

@MainActor final class BifrostWorkerPanelOwnership {
    private let makePanel: @MainActor () -> any BifrostWorkerPanel
    private var panel: (any BifrostWorkerPanel)?

    init(makePanel: @escaping @MainActor () -> any BifrostWorkerPanel = { BifrostPanel.shared }) {
        self.makePanel = makePanel
    }

    func attach(store: BifrostStore) {
        guard panel == nil else { return }
        let created = makePanel()
        panel = created
        created.store = store
    }

    func toggle() { panel?.toggle(query: "") }

    func shutdown() {
        let owned = panel
        panel = nil
        owned?.shutdown()
    }
}

@MainActor final class BifrostWorker {
    let store: BifrostStore
    private var observer: NSObjectProtocol?
    private var hostObserver: NSObjectProtocol?
    private var stopped = false
    private let recoveryOnly: Bool
    private let fixture: Bool
    private let panel: BifrostWorkerPanelOwnership
    private var ownsPreview = false
    private var ownsHotKey = false
    private var hostChanges: AsyncStream<Void>.Continuation?
    private var hostTask: Task<Void, Never>?

    init(
        fixture: Bool = BifrostFixture.enabled,
        recoveryOnly: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"]
            == "1",
        panel: BifrostWorkerPanelOwnership? = nil,
        seedFixture: (() -> Void)? = nil,
        makeStore: ((Bool) -> BifrostStore)? = nil
    ) {
        self.recoveryOnly = recoveryOnly
        self.fixture = fixture
        let panel = panel ?? BifrostWorkerPanelOwnership()
        self.panel = panel
        if fixture && !recoveryOnly {
            if let seedFixture {
                seedFixture()
            } else {
                SharedDefaults.store.set(true, forKey: AppStorageKeys.Bifrost.enabled)
                BifrostIndexStore.shared.save(
                    .init(generatedAt: Date(), applications: BifrostFixture.applications))
            }
        }
        if let makeStore {
            store = makeStore(fixture || recoveryOnly)
        } else if fixture {
            store = BifrostStore(
                store: SharedDefaults.store, indexStore: .shared, rateStore: .shared,
                startServices: false, scan: { BifrostFixture.applications },
                open: { _ in false }, copy: { _ in }, post: { _ in })
        } else {
            store = BifrostStore()
        }
        guard !recoveryOnly, !fixture else { return }
        BifrostClipboardPreviewService.shared.resume()
        ownsPreview = true
        panel.attach(store: store)
        observer = BifrostIPC.observe(BifrostIPC.Name.requestBifrostPanel) { [weak panel] in
            panel?.toggle()
        }
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        hostChanges = changes.continuation
        hostTask = Task { [self] in
            for await _ in changes.stream {
                guard !stopped, !Task.isCancelled else { return }
                BifrostIPC.post(BifrostIPC.Name.settingsChanged)
            }
        }
        hostObserver = ExtensionSharedState.current?.observe { owner in
            guard owner == "host" || owner == "presenter" else { return }
            changes.continuation.yield(())
        }
        configureHotKey()
    }

    func configureHotKey() {
        guard !stopped, !recoveryOnly, !fixture else { return }
        HotKeyRegistrar.configure(
            .init(
                id: "bifrost", carbonID: 3, prefix: "bifrostHotKey", defaultCode: 49,
                defaultModifiers: Int(optionKey)))
        HotKeyRegistrar.install("bifrost") { [weak panel] in panel?.toggle() }
        ownsHotKey = true
    }

    func prepareDisable() async throws {
        try await store.prepareDisable()
        if ownsPreview { await BifrostClipboardPreviewService.shared.shutdown() }
    }

    func cancelPendingCommands() {
        store.cancelPendingCommands()
        hostChanges?.finish()
        hostTask?.cancel()
        if let observer { BifrostIPC.stopObserving(observer) }; observer = nil
        if let hostObserver { ExtensionSharedState.current?.stopObserving(hostObserver) }
        hostObserver = nil
        if ownsHotKey { HotKeyRegistrar.shutdown(); ownsHotKey = false }
    }

    func drain() async {
        cancelPendingCommands()
        await store.drain()
        await hostTask?.value
        if ownsPreview { await BifrostClipboardPreviewService.shared.shutdown() }
    }

    func shutdown() {
        cancelPendingCommands()
        guard !stopped else { return }; stopped = true
        if let observer { BifrostIPC.stopObserving(observer) }; observer = nil
        if let hostObserver { ExtensionSharedState.current?.stopObserving(hostObserver) }
        hostObserver = nil
        if ownsHotKey { HotKeyRegistrar.shutdown(); ownsHotKey = false }
        panel.shutdown()
        store.shutdown()
    }
}
