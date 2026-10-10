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

    private var presentation: ControlPresentation?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command.hasPrefix("focusDim.ui.") {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                let defaults = SharedDefaults.store
                switch command {
                case "focusDim.ui.read":
                    guard payload == Data("{}".utf8) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                case "focusDim.ui.update":
                    try ControlPresentationContract.update(payload, defaults: defaults)
                    self.service?.applySettings()
                case "focusDim.ui.action":
                    let action = try JSONDecoder().decode(
                        ControlPresentationAction.self, from: payload)
                    guard action.action == "screenRecording", action.value.isEmpty else {
                        throw ExtensionPeerError.invalidRequest
                    }
                    _ = CGRequestScreenCaptureAccess()
                default: throw ExtensionPeerError.invalidRequest
                }
                return try ControlPresentationContract.snapshot(
                    defaults: defaults, state: ControlPresentationState())
            }
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "focusDim", command: command, payload: payload,
                snapshot: { _ in
                    FocusDimSurface.snapshot(
                        active: FocusDimState.isActive(),
                        intensity: SharedDefaults.store.object(
                            forKey: AppStorageKeys.FocusDim.intensity) as? Double
                            ?? FocusDimMath.defaultIntensity)
                },
                perform: { action in
                    FocusDimState.setActive(action == "enable")
                    service.applySettings()
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
                "id": "focusDim", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "focusDim",
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
            guard let presentation else { return ["ok": false] as NSDictionary }
            UIScale.install(from: SharedDefaults.store)
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        FocusDimSettings(presentation: presentation)
                    }
                })
        case "synchronize": service?.applySettings()
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
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

private struct FocusDimSettings: View {
    let presentation: ControlPresentation
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
                Button("Allow Screen Recording") { presentation.perform("screenRecording") }
                    .disabled(!presentation.active)
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
