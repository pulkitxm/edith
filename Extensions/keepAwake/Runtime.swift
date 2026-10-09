import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI

@MainActor
@objc(EdithKeepAwakeExtensionRuntime)
final class KeepAwakeRuntime: NSObject {
    private var store: KeepAwakeStore?
    private var defaults: UserDefaults?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let store = self.store else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "keepAwake", command: command, payload: payload,
                snapshot: { _ in
                    KeepAwakeSurface.snapshot(
                        preventingSleep: store.preventingSleep,
                        requested: self.defaults?.bool(forKey: "preventSleep") ?? false)
                },
                perform: { action in
                    self.defaults?.set(action == "enable", forKey: "preventSleep")
                    store.syncPreventSleep()
                })
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
        case "start":
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
            guard let suite = input["defaultsSuite"] as? String,
                let defaults = UserDefaults(suiteName: suite), let store
            else {
                return ["ok": false] as NSDictionary
            }
            return NSHostingController(
                rootView: KeepAwakeSettings(
                    defaults: defaults, synchronize: { [weak store] in store?.syncPreventSleep() }))
        case "synchronize":
            store?.syncPreventSleep()
            return ["ok": true] as NSDictionary
        case "cancelCommand":
            commands.cancel(input["token"] as? String ?? "")
            return ["ok": true] as NSDictionary
        case "stop":
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
