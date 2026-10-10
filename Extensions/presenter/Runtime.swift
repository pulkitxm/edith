import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithPresenterExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var service: PresenterDetector?
    private var state: PresenterState?
    private var observer: NSObjectProtocol?
    private var pauseObserver: NSObjectProtocol?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.state != nil else { throw ExtensionPeerError.unavailable }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "presenter", command: command, payload: payload,
                    snapshot: { _ in
                        PresenterSurface.snapshot(PresenterRuntimeOperationExecution.status())
                    },
                    perform: { action in
                        if action == "stop" { self.service?.pauseUntilShareEnds() }
                        _ = PresenterRuntimeOperationExecution.perform(
                            action == "stop" ? .stop : .start)
                        self.synchronize()
                    })
            }
            switch command {
            case "presenter.start": _ = PresenterRuntimeOperationExecution.perform(.start)
            case "presenter.stop": _ = PresenterRuntimeOperationExecution.perform(.stop)
            case "presenter.status": break
            default: throw ExtensionPeerError.rejected("Presenter does not support this command.")
            }
            self.synchronize()
            let snapshot = PresenterRuntimeOperationExecution.status()
            return try JSONSerialization.data(withJSONObject: [
                "enabled": snapshot.enabled, "manual": snapshot.manual,
                "autoActive": snapshot.autoActive, "active": snapshot.active,
                "autoReason": snapshot.autoReason ?? "",
            ])
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "presenter", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            SharedDefaults.store.set(true, forKey: AppStorageKeys.Presenter.enabled)
            SharedDefaults.store.set(false, forKey: AppStorageKeys.Presenter.autoActive)
            if state == nil { state = PresenterState() }
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.presenter, carbonID: 5, prefix: "presenterHotKey",
                    defaultCode: kVK_ANSI_P, defaultModifiers: shiftKey | optionKey | cmdKey))
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.synchronize() }
                }
                pauseObserver = IPC.observe(IPC.Name.presenterPauseAuto) { [weak self] in
                    MainActor.assumeIsolated { self?.service?.pauseUntilShareEnds() }
                }
            }
            synchronize()
        case "view":
            if let controller = PresenterSidebarScene.controller(input) { return controller }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Presenter")
                    } content: {
                        Form { PresenterRows() }.formStyle(.grouped)
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": synchronize()
        case "stop":
            commands.shutdown()
            service?.shutdown()
            service = nil
            state?.shutdown()
            state = nil
            IPC.stopObserving(observer)
            IPC.stopObserving(pauseObserver)
            observer = nil
            pauseObserver = nil
            HotKeyRegistrar.shutdown()
        case "pauseUntilShareEnds": service?.pauseUntilShareEnds()
        case "status": return ["ok": true, "running": state != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func synchronize() {
        guard state != nil else { return }
        HotKeyRegistrar.install(HotKeyCatalog.presenter) { [weak self] in
            let operation: PresenterRuntimeOperation =
                SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.mode) ? .stop : .start
            _ = PresenterRuntimeOperationExecution.perform(operation)
            self?.synchronize()
        }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.autoEnabled) {
            if service == nil { service = PresenterDetector() }
            service?.applySettings()
        } else {
            service?.shutdown()
            service = nil
            SharedDefaults.store.set(false, forKey: AppStorageKeys.Presenter.autoActive)
        }
        state?.refresh()
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
