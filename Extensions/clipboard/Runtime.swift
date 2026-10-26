import AppKit
import Carbon.HIToolbox
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithClipboardExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: ClipboardWorker?
    private var presentation: ClipboardPresentation?
    private var uiConfigured = false
    private var uiLocation: String?
    private var surface: ClipboardSurface?
    private var settingsObserver: NSObjectProtocol?
    private var backup: ClipboardBackupProvider?
    private var backupRestoreTask: Task<Void, Never>?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var commandsSuspended = false
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            request["hostedFunctionalFixture"] == nil
        else { completion(nil, "The functional fixture is unavailable."); return }
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let token else { throw ExtensionPeerError.invalidRequest }
            try Task.checkCancellation()
            return try await self.executeCommand(command, payload: payload)
        }
    }

    private func checkFixtureCurrent() throws {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil else {
            throw ExtensionPeerError.invalidRequest
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = worker
        let uiOwner = presentation
        let backupOwner = backup
        let restore = backupRestoreTask
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        uiOwner?.stop()
        restore?.cancel()
        owner?.cancelPendingCommands()
        HotKeyRegistrar.clear("clipboard")
        IPC.stopObserving(settingsObserver); settingsObserver = nil
        backupOwner?.cancelPendingCommands()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            await owner?.service.cancelPendingCommands()
            _ = await commands.suspendAndWait()
            await backupOwner?.cancelAndWait()
            await restore?.value
            await owner?.cancelAndWait()
            await uiOwner?.stopAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = worker
        let backupOwner = backup
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        retireUI()
        worker = nil; surface = nil; backup = nil; backupRestoreTask = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await backupOwner?.shutdown()
            await owner?.shutdown()
            HotKeyRegistrar.shutdown();
            ExtensionUIResources.cleanup(of: self, key: "textEditing") {
                TextEditingCommands.shutdown()
            }; ClipboardThumbnail.clear()
        }
        resourceStop = task
        return task
    }

    private func retireUI() {
        guard let owner = presentation else { return }
        owner.stop()
        let id = UUID()
        uiDrains[id] = Task { [self, owner] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
        }
        presentation = nil; uiLocation = nil
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        if ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || input["hostedFunctionalFixture"] != nil
        {
            let allowed = [
                "describe", "status", "stop", "stopUI", "prepareToStop", "cancelCommand",
            ]
            guard let operation = input["operation"] as? String, allowed.contains(operation) else {
                return ["ok": false] as NSDictionary
            }
        }
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "clipboard", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "clipboard"
            else { return ["ok": false] as NSDictionary }
            retireUI()
            if let engine = configuration.engineClient {
                presentation = ClipboardPresentation(engine: engine)
            } else {
                presentation = ClipboardPresentation(send: { _, _ in
                    throw ExtensionPeerError.unavailable
                })
            }
            uiConfigured = true
            uiLocation = input["location"] as? String
        case "stopUI":
            retireUI()
            return ["ok": true] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard !uiConfigured, !ExtensionHostRole.isInterfaceProcess else {
                return ["ok": false] as NSDictionary
            }
            do {
                guard let suite = input["defaultsSuite"] as? String,
                    suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                guard worker == nil else { return ["ok": true] as NSDictionary }
                let construct: (Bool) throws -> Void = { [self] fixture in
                    backup = try ClipboardBackupProvider.live()
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
                                id: "clipboard", carbonID: 7, prefix: "clipboardHotKey",
                                defaultCode: kVK_ANSI_C, defaultModifiers: controlKey | shiftKey))
                        registerHotKey()
                        settingsObserver = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                            MainActor.assumeIsolated { self?.registerHotKey() }
                        }
                        TextEditingCommands.install()
                    }
                }
                try construct(
                    ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil)
            } catch {
                return ["ok": false] as NSDictionary
            }
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let presentation, !presentation.stopped else {
                return ["ok": false] as NSDictionary
            }
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
        case "pick":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] == nil else {
                return ["ok": false] as NSDictionary
            }
            worker?.panel.show()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            do {
                try checkFixtureCurrent()
                registerHotKey(); backup?.preferencesChanged(); IPC.post(IPC.Name.settingsChanged)
            } catch { return ["ok": false] as NSDictionary }
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func registerHotKey() {
        guard let worker, !worker.isStopped else { return }
        HotKeyRegistrar.install("clipboard") { [weak worker] in worker?.panel.toggle() }
    }
}

#if !SWIFT_PACKAGE
@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
#endif
