import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: KeystrokeHighlightRuntime?
    private var observer: NSObjectProtocol?

    private var presentation: ControlPresentation?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command.hasPrefix("keystrokeHighlight.ui.") {
                guard let self, self.observer != nil else { throw ExtensionPeerError.unavailable }
                let defaults = SharedDefaults.store
                switch command {
                case "keystrokeHighlight.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "keystrokeHighlight.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)
                    self.synchronize()
                case "keystrokeHighlight.ui.action":
                    let action = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    guard action.action == "inputMonitoring", action.value.isEmpty else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    _ = CGRequestListenEventAccess()
                    self.synchronize()
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults, state: ControlPresentationState())
            }
            guard let self, self.observer != nil else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "keystrokeHighlight", command: command,
                payload: payload,
                snapshot: { _ in
                    KeystrokeHighlightSurface.snapshot(
                        active: SharedDefaults.store.bool(
                            forKey: AppStorageKeys.KeystrokeHighlight.active))
                },
                perform: { action in
                    SharedDefaults.store.set(
                        action == "enable", forKey: AppStorageKeys.KeystrokeHighlight.active)
                    self.synchronize()
                    IPC.post(IPC.Name.settingsChanged)
                })
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "keystrokeHighlight", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "keystrokeHighlight",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            presentation?.stop()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            presentation?.stop()
            presentation = nil
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
            else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.keystrokeHighlight, carbonID: 9,
                    prefix: "keystrokeHighlightHotKey", defaultCode: kVK_ANSI_K,
                    defaultModifiers: controlKey | optionKey | cmdKey))
            SharedDefaults.store.set(true, forKey: AppStorageKeys.KeystrokeHighlight.enabled)
            if SharedDefaults.store.object(forKey: AppStorageKeys.KeystrokeHighlight.active) == nil
            {
                SharedDefaults.store.set(true, forKey: AppStorageKeys.KeystrokeHighlight.active)
            }
            synchronize()
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.synchronize() }
                }
            }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Keystroke Highlight")
                        } content: {
                            Form { KeystrokeHighlightRows(presentation: presentation) }.formStyle(
                                .grouped)
                        }
                    }
                })
        case "synchronize": synchronize()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            presentation?.stop()
            presentation = nil
            commands.shutdown()
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()

        case "status": return ["ok": true, "running": observer != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func synchronize() {
        HotKeyRegistrar.install(HotKeyCatalog.keystrokeHighlight) { [weak self] in
            let defaults = SharedDefaults.store
            defaults.set(
                !defaults.bool(forKey: AppStorageKeys.KeystrokeHighlight.active),
                forKey: AppStorageKeys.KeystrokeHighlight.active)
            self?.synchronize()
        }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.KeystrokeHighlight.active) {
            if service == nil { service = KeystrokeHighlightRuntime() }
            service?.syncSettings()
        } else {
            service?.shutdown()
            service = nil
        }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
