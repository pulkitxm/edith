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
    private let recoveryOnly: Bool

    init() {
        recoveryOnly = ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
        if !recoveryOnly { BifrostClipboardPreviewService.shared.resume() }
        if BifrostFixture.enabled && !recoveryOnly {
            SharedDefaults.store.set(true, forKey: AppStorageKeys.Bifrost.enabled)
            BifrostIndexStore.shared.save(
                .init(generatedAt: Date(), applications: BifrostFixture.applications))
        }
        store = BifrostStore()
        guard !recoveryOnly else { return }
        BifrostPanel.shared.store = store
        observer = BifrostIPC.observe(BifrostIPC.Name.requestBifrostPanel) {
            BifrostPanel.shared.toggle()
        }
        hostObserver = ExtensionSharedState.current?.observe { owner in
            guard owner == "host" || owner == "presenter" else { return }
            Task { @MainActor in BifrostIPC.post(BifrostIPC.Name.settingsChanged) }
        }
        configureHotKey()
    }

    func configureHotKey() {
        guard !stopped, !recoveryOnly, !BifrostFixture.enabled else { return }
        HotKeyRegistrar.configure(
            .init(
                id: "bifrost", carbonID: 3, prefix: "bifrostHotKey", defaultCode: 49,
                defaultModifiers: Int(optionKey)))
        HotKeyRegistrar.install("bifrost") { BifrostPanel.shared.toggle() }
    }

    func prepareDisable() async throws {
        try await store.prepareDisable()
        await BifrostClipboardPreviewService.shared.shutdown()
    }

    func shutdown() {
        guard !stopped else { return }; stopped = true
        if let observer { BifrostIPC.stopObserving(observer) }; observer = nil
        ExtensionSharedState.current?.stopObserving(hostObserver); hostObserver = nil
        HotKeyRegistrar.shutdown()
        if !recoveryOnly { BifrostPanel.shared.shutdown() }
        store.shutdown()
    }
}
