import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithClipboardExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: ClipboardWorker?
    private var presentation: ClipboardPresentation?
    private var uiConfigured = false
    private var surface: ClipboardSurface?
    private var settingsObserver: NSObjectProtocol?
    private var backup: ClipboardBackupProvider?
    private var backupRestoreTask: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
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
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        HotKeyRegistrar.shutdown()
        IPC.stopObserving(settingsObserver); settingsObserver = nil
        backupRestoreTask?.cancel()
        Task {
            await backup?.shutdown()
            await backupRestoreTask?.value
            await commands.shutdownAndWait()
            await worker?.shutdown(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
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
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "clipboard"
            else { return ["ok": false] as NSDictionary }
            presentation?.stop()
            if let engine = configuration.engineClient {
                presentation = ClipboardPresentation(engine: engine)
            } else {
                presentation = ClipboardPresentation(send: { _, _ in
                    throw ExtensionPeerError.unavailable
                })
            }
            uiConfigured = true
        case "stopUI":
            presentation?.stop(); presentation = nil
            return ["ok": true] as NSDictionary
        case "start":
            guard !uiConfigured, Bundle.main.bundleURL.pathExtension != "appex" else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            do { backup = try ClipboardBackupProvider.live() } catch {
                return ["ok": false, "error": error.localizedDescription] as NSDictionary
            }
            let backup = self.backup
            backupRestoreTask = Task { _ = await backup?.restoreOnEnable() }
            let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
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
                client: worker.client, isStopped: { [weak worker] in worker?.isStopped != false })
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
        case "view":
            guard let presentation, !presentation.stopped else {
                return ["ok": false] as NSDictionary
            }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ClipboardPage(
                        client: presentation.client, history: presentation.history,
                        openPalette: { presentation.action("clipboard.ui.palette") },
                        presentation: presentation)
                })
        case "pick": worker?.panel.show()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            registerHotKey(); IPC.post(IPC.Name.settingsChanged)
        case "stop":
            presentation?.stop(); presentation = nil
            commands.shutdown()
            worker?.panel.shutdown(); worker?.store.shutdown(); worker?.history.stop()
            worker = nil; surface = nil
            backup = nil; backupRestoreTask = nil
            IPC.stopObserving(settingsObserver); settingsObserver = nil
            HotKeyRegistrar.shutdown(); TextEditingCommands.shutdown(); ClipboardThumbnail.clear()
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

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
