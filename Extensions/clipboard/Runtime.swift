import AppKit
import Carbon.HIToolbox
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class ClipboardExtensionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: ClipboardWorker?
    private var presentation: ClipboardPresentation?
    private var uiConfigured = false
    private var uiLocation: String?
    private var surface: ClipboardSurface?
    private var settingsObserver: NSObjectProtocol?
    private var backup: ClipboardBackupProvider?
    private var backupRestoreTask: Task<Void, Never>?
    private var workerCancellation: Task<Void, Never>?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { worker?.isStopped == false }
    var allowsUIDuringRetirement: Bool { true }

    private static var fixtureActive: Bool {
        ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !Self.fixtureActive else {
            throw ExtensionPeerError.rejected("The functional fixture is unavailable.")
        }
        try Task.checkCancellation()
        guard let worker = self.worker else { throw ExtensionPeerError.unavailable }
        if command == "clipboard.cli.catalog" {
            return try ExtensionCLICatalog.data(
                ClipboardCommand.self, owner: "clipboard", payload: payload, streaming: false)
        }
        if command == "clipboard.cli" {
            return try await worker.execute("cli.execute", payload: payload)
        }
        if command.hasPrefix("surface.") {
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        if command.hasPrefix("backup."), let backup = self.backup {
            if command == "backup.synchronize" { await self.backupRestoreTask?.value }
            try Task.checkCancellation()
            return try await backup.execute(command, payload: payload)
        }
        return try await worker.execute(command, payload: payload)
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !Self.fixtureActive, !context.isHostedFunctionalFixture, !uiConfigured,
            !ExtensionHostRole.isInterfaceProcess
        else { return false }
        guard worker == nil else { return true }
        let fixture = ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil
        do {
            backup = try ClipboardBackupProvider.live()
        } catch {
            return false
        }
        let backup = self.backup
        backupRestoreTask = Task {
            let restored = await backup?.restoreOnEnable()
            guard !Task.isCancelled else { return }
            backup?.startScheduling(restorePending: restored == false)
        }
        let worker = ClipboardWorker(
            capturesPasteboard: !fixture,
            copyRecord: { payload in
                guard !fixture else {
                    throw ExtensionPeerError.rejected(
                        "Pasteboard actions are unavailable in fixture mode.")
                }
                ClipboardRepository.copyToPasteboard(payload, pasteboard: .general)
            })
        self.worker = worker
        surface = ClipboardSurface(
            client: worker.client,
            isStopped: { [weak worker] in worker?.isStopped != false })
        if !fixture {
            HotKeyRegistrar.configure(
                .init(
                    id: "clipboard", prefix: "clipboardHotKey",
                    defaultCode: kVK_ANSI_C, defaultModifiers: controlKey | shiftKey))
            registerHotKey()
            settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.registerHotKey() }
            }
            TextEditingCommands.install()
        }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !(runtime.isSuspended || runtime.isStopping), !Self.fixtureActive,
            !context.isHostedFunctionalFixture
        else { return false }
        registerHotKey()
        backup?.preferencesChanged()
        IPC.post(IPC.Name.settingsChanged)
        return true
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !Self.fixtureActive, configuration.input["hostedFunctionalFixture"] == nil,
            uiDrains.count < 8
        else { return false }
        _ = retireUI()
        if let engine = configuration.engineClient {
            presentation = ClipboardPresentation(engine: engine)
        } else {
            presentation = ClipboardPresentation(send: { _, _ in
                throw ExtensionPeerError.unavailable
            })
        }
        uiConfigured = true
        uiLocation = configuration.location
        return true
    }

    func view(for presentationID: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !(runtime.isSuspended || runtime.isStopping), !Self.fixtureActive,
            !context.isHostedFunctionalFixture, let presentation, !presentation.stopped
        else { return nil }
        if uiLocation == "notch" {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ClipboardNotchList(
                        history: presentation.history, available: presentation.available)
                })
        }
        return NSHostingController(
            rootView: ExtensionPageHost {
                ClipboardPage(
                    client: presentation.client, history: presentation.history,
                    openPalette: { presentation.action("clipboard.ui.palette") },
                    presentation: presentation)
            })
    }

    func stopUI(for presentationID: UUID?) -> [Task<Void, Never>] {
        retireUI().map { [$0] } ?? []
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "pick", !(runtime.isSuspended || runtime.isStopping),
            !Self.fixtureActive,
            context["hostedFunctionalFixture"] == nil,
            ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] == nil
        else { return nil }
        worker?.panel.show()
        return ["ok": true] as NSDictionary
    }

    func cancelPendingWork() {
        presentation?.stop()
        backupRestoreTask?.cancel()
        let owner = worker
        owner?.cancelPendingCommands()
        HotKeyRegistrar.clear("clipboard")
        IPC.stopObserving(settingsObserver)
        settingsObserver = nil
        backup?.cancelPendingCommands()
        workerCancellation = Task { await owner?.service.cancelPendingCommands() }
    }

    func drain() async {
        await workerCancellation?.value
        await backup?.cancelAndWait()
        await backupRestoreTask?.value
        await worker?.cancelAndWait()
        await presentation?.stopAndWait()
        while let task = uiDrains.values.first { await task.value }
    }

    func teardown() async {
        let owner = worker
        let backupOwner = backup
        let retiring = retireUI()
        worker = nil
        surface = nil
        backup = nil
        backupRestoreTask = nil
        await retiring?.value
        await backupOwner?.shutdown()
        await owner?.shutdown()
        HotKeyRegistrar.shutdown()
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        ClipboardThumbnail.clear()
    }

    private func retireUI() -> Task<Void, Never>? {
        guard let owner = presentation else { return nil }
        owner.stop()
        let id = UUID()
        let task = Task { [self, owner] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
        }
        uiDrains[id] = task
        presentation = nil
        uiLocation = nil
        return task
    }

    private func registerHotKey() {
        guard let worker, !worker.isStopped else { return }
        HotKeyRegistrar.install("clipboard") { [weak worker] in worker?.panel.toggle() }
    }
}

@MainActor
func makeClipboardRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "clipboard", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { ClipboardExtensionService(runtime: $0) }
}

#if !SWIFT_PACKAGE
@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeClipboardRuntime()).toOpaque())
        })
}
#endif
