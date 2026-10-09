import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class BifrostWorker {
    let store: BifrostStore
    private var observer: NSObjectProtocol?
    private var hostObserver: NSObjectProtocol?
    private var stopped = false

    init() {
        if BifrostFixture.enabled {
            SharedDefaults.store.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            BifrostIndexStore.shared.save(
                .init(generatedAt: Date(), applications: BifrostFixture.applications))
        }
        store = BifrostStore()
        BifrostPanel.shared.store = store
        observer = BifrostIPC.observe(BifrostIPC.Name.requestBifrostPanel) {
            BifrostPanel.shared.toggle()
        }
        hostObserver = ExtensionSharedState.current?.observe { owner in
            guard owner == "host" else { return }
            Task { @MainActor in BifrostIPC.post(BifrostIPC.Name.settingsChanged) }
        }
        configureHotKey()
    }

    func configureHotKey() {
        guard !stopped, !BifrostFixture.enabled else { return }
        HotKeyRegistrar.configure(
            .init(
                id: "bifrost", carbonID: 3, prefix: "bifrostHotKey", defaultCode: 49,
                defaultModifiers: Int(optionKey)))
        HotKeyRegistrar.install("bifrost") { BifrostPanel.shared.toggle() }
    }

    func prepareDisable() async throws { try await store.prepareDisable() }

    func shutdown() {
        guard !stopped else { return }; stopped = true
        if let observer { BifrostIPC.stopObserving(observer) }; observer = nil
        ExtensionSharedState.current?.stopObserving(hostObserver); hostObserver = nil
        HotKeyRegistrar.shutdown()
        BifrostPanel.shared.shutdown()
        store.shutdown()
    }
}
