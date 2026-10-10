import AppKit
import EdithExtensionSupport
import Foundation

@MainActor final class LidAwakeWorker {
    let engine: LidAwakeEngine
    let operations: LidAwakeOperationModel
    private var observer: NSObjectProtocol?
    private var stopped = false
    private let recoveryOnly: Bool
    private let defaults: UserDefaults
    private let confirm: @MainActor () -> Bool

    init(
        defaults: UserDefaults = SharedDefaults.store, engine: LidAwakeEngine? = nil,
        recoveryOnly: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"]
            == "1",
        confirm: @escaping @MainActor () -> Bool = LidAwakeWorker.confirmActivation
    ) {
        self.defaults = defaults; self.confirm = confirm; self.recoveryOnly = recoveryOnly
        if !recoveryOnly { defaults.set(true, forKey: LidAwakeState.enabledKey) }
        defaults.set(true, forKey: LidAwakeState.restoreOnQuitKey)
        let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        let created =
            engine
            ?? LidAwakeEngine(
                defaults: defaults,
                readSystemState: { defaults.bool(forKey: LidAwakeState.activeKey) },
                applySystemState: fixture
                    ? { value in
                        defaults.set(value, forKey: LidAwakeState.activeKey); return .applied
                    } : nil, startServices: !fixture && !recoveryOnly, recoveryOnly: recoveryOnly,
                systemStateReader: fixture
                    ? { false } : { try await LidAwakeSystemStateReader.read() })
        self.engine = created
        operations = LidAwakeOperationModel { request in
            try await Self.perform(request, engine: created, defaults: defaults)
        }
        guard !recoveryOnly else { return }
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("lidAwakeSettingsChanged"), object: nil, queue: .main
        ) { _ in Task { @MainActor in created.syncSettings() } }
    }

    func perform(_ request: LidAwakeRequest, requiresConfirmation: Bool = false) async throws
        -> LidAwakeSnapshot
    {
        guard !stopped, !recoveryOnly else { throw ExtensionPeerError.unavailable }
        if requiresConfirmation, !confirm() { throw CancellationError() }
        return try await Self.perform(request, engine: engine, defaults: defaults)
    }

    private static func perform(
        _ request: LidAwakeRequest, engine: LidAwakeEngine, defaults: UserDefaults
    ) async throws -> LidAwakeSnapshot {
        switch request {
        case .status: return engine.snapshot()
        case .setRestoreOnQuit(false):
            throw ExtensionPeerError.rejected(
                "Sleep restoration is required before disabling, updating, or quitting Edith.")
        case .setBatteryThreshold, .setRestoreOnQuit(true):
            guard LidAwakeOperationExecution.applySetting(request, defaults: defaults) else {
                throw ExtensionPeerError.invalidRequest
            }
            engine.syncSettings(); return engine.snapshot()
        case .enableExtension, .disableExtension:
            throw ExtensionPeerError.rejected(
                "Enable or disable Lid Awake from the extension marketplace.")
        case .on, .off:
            let outcome = await withCheckedContinuation { continuation in
                engine.execute(request) { continuation.resume(returning: $0) }
            }
            if case .failed(let message) = outcome { throw LidAwakeOperationFailure(message) }
            return engine.snapshot()
        }
    }

    func prepareDisable() async throws { try await engine.prepareDisable() }
    func requestApproval() throws { try engine.requestApproval() }
    func shutdown() {
        guard !stopped else { return }; stopped = true
        operations.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        engine.shutdown()
        defaults.set(false, forKey: LidAwakeState.enabledKey)
    }

    static func confirmActivation() -> Bool {
        let alert = NSAlert(); alert.messageText = "Keep running with the lid closed?"
        alert.informativeText =
            LidAwakeOperationExecution.preview(for: .on(.indefinite))?.warning ?? ""
        alert.addButton(withTitle: "Turn On"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
