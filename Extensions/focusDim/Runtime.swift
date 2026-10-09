import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: FocusDimEngine?
    private var observer: NSObjectProtocol?

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "focusDim", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            SharedDefaults.store.set(true, forKey: FocusDimState.enabledKey)
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: "focusDim", carbonID: 4, prefix: "focusDimHotKey", defaultCode: kVK_ANSI_F,
                    defaultModifiers: cmdKey | optionKey))
            if service == nil { service = FocusDimEngine() }
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.service?.applySettings() }
                }
            }
        case "view":
            UIScale.install(from: SharedDefaults.store)
            return NSHostingController(rootView: ExtensionPageHost { FocusDimSettings() })
        case "synchronize": service?.applySettings()
        case "stop":
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

private struct FocusDimSettings: View {
    @AppStorage(FocusDimState.activeKey, store: SharedDefaults.store) private var active = false
    @AppStorage(AppStorageKeys.FocusDim.intensity, store: SharedDefaults.store) private
        var intensity = FocusDimMath.defaultIntensity
    @AppStorage(AppStorageKeys.FocusDim.animationDuration, store: SharedDefaults.store) private
        var animationDuration = FocusDimMath.defaultAnimationDuration
    @AppStorage(AppStorageKeys.FocusDim.otherDisplaysMode, store: SharedDefaults.store) private
        var mode = FocusDimDisplayMode.perScreenFront.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Dim now", isOn: $active)
                LabeledContent("Intensity", value: "\(Int(intensity * 100))%")
                Slider(value: $intensity, in: FocusDimMath.intensityRange)
                LabeledContent("Animation", value: String(format: "%.2fs", animationDuration))
                Slider(value: $animationDuration, in: FocusDimMath.animationDurationRange)
                EdithSegmentedPicker(
                    "Other displays", selection: $mode,
                    options: FocusDimDisplayMode.allCases.map(\.rawValue),
                    label: {
                        $0 == FocusDimDisplayMode.perScreenFront.rawValue
                            ? "Highlight front window" : "Dim unfocused fully"
                    })
                LabeledContent("Toggle hotkey") {
                    HotKeyRecorderControl(keyPrefix: "focusDimHotKey", defaultLabel: "⌥⌘F")
                }
                Button("Allow Screen Recording") { _ = CGRequestScreenCaptureAccess() }
            } header: {
                Text("Focus Dim").font(.edithText(.title)).bold()
            }
        }
        .formStyle(.grouped)
        .onChange(of: active) { changed() }
        .onChange(of: intensity) { changed() }
        .onChange(of: animationDuration) { changed() }
        .onChange(of: mode) { changed() }
    }

    private func changed() { IPC.post(IPC.Name.settingsChanged) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
