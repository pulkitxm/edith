import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithKeepAwakeExtensionRuntime)
final class KeepAwakeRuntime: NSObject {
    private var store: KeepAwakeStore?
    private var defaults: UserDefaults?

    private var presentation: ControlPresentation?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command.hasPrefix("keepAwake.ui.") {
                guard let self, self.store != nil else { throw ExtensionPeerError.unavailable }
                let defaults = self.defaults ?? SharedDefaults.store
                switch command {
                case "keepAwake.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "keepAwake.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)
                    self.store?.syncPreventSleep()
                case "keepAwake.ui.action":
                    _ = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    throw ExtensionPeerError.invalidRequest
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults, state: ControlPresentationState())
            }
            guard let self, let store = self.store, let defaults = self.defaults else {
                throw ExtensionPeerError.unavailable
            }
            return try await KeepAwakeSurface.execute(
                command, payload: payload, store: store, defaults: defaults)
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
            return [
                "id": "keepAwake",
                "version": Bundle(for: KeepAwakeRuntime.self).object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                "hostABI": Bundle(for: KeepAwakeRuntime.self).object(
                    forInfoDictionaryKey: "EdithHostABI") as? String ?? "runtime-1",
                "role": "helper",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "keepAwake",
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
                let defaults = UserDefaults(suiteName: suite)
            else {
                return ["ok": false] as NSDictionary
            }
            self.defaults = defaults
            if store == nil { store = KeepAwakeStore(defaults: defaults) }
            defaults.set(true, forKey: KeepAwakeKeys.enabled)
            store?.syncPreventSleep()
            return ["ok": true] as NSDictionary
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        KeepAwakeSettings(
                            defaults: SharedDefaults.store, synchronize: { presentation.changed() })
                    }
                })
        case "synchronize":
            store?.syncPreventSleep()
            return ["ok": true] as NSDictionary
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
            presentation?.stop()
            presentation = nil
            commands.shutdown()
            store?.shutdown()
            store = nil
            defaults = nil
            return ["ok": true] as NSDictionary
        case "status":
            return [
                "ok": true, "running": store != nil,
                "preventingSleep": store?.preventingSleep ?? false,
            ] as NSDictionary
        default:
            return ["ok": false] as NSDictionary
        }
    }
}

private struct KeepAwakeSettings: View {
    @AppStorage private var preventSleep: Bool
    let synchronize: @MainActor () -> Void

    init(defaults: UserDefaults, synchronize: @escaping @MainActor () -> Void) {
        _preventSleep = AppStorage(wrappedValue: false, "preventSleep", store: defaults)
        self.synchronize = synchronize
    }

    var body: some View {
        Form {
            Section {
                Toggle("Keep awake", isOn: $preventSleep)
                Text(
                    "Keeps the Mac and display awake until turned off. Closing the lid still sleeps the Mac; use Lid Awake for that."
                )
                .foregroundStyle(.secondary)
            } header: {
                Text("Keep Awake").font(.title.bold())
            }
        }
        .formStyle(.grouped)
        .onChange(of: preventSleep) { synchronize() }
        .frame(minWidth: 400, minHeight: 200)
    }
}

@_cdecl("edith_extension_create")
public func createKeepAwakeExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(KeepAwakeRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}
