import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithSocialManagerExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var started = false
    private var model: SocialManagerModel?
    private var settingsUI = false
    private var suspended = false
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { command, payload in
            guard command == "surface.snapshot" || command == "surface.perform" else {
                throw ExtensionPeerError.unavailable
            }
            return try await SurfaceCommandService.execute(
                providerID: "socialManager", command: command, payload: payload,
                snapshot: { _ in SurfaceSnapshot(providerID: "socialManager") },
                perform: { _ in throw ExtensionPeerError.invalidRequest })
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        suspended = true
        _ = commands.suspend()
        Task { [self] in
            _ = await commands.suspendAndWait()
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        suspended = true
        stopUI()
        commands.shutdown()
        Task { [self] in
            await commands.shutdownAndWait()
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "socialManager", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !suspended, let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            started = true
        case "configureUI":
            guard !suspended, model == nil, !settingsUI,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "socialManager"
            else { return ["ok": false] as NSDictionary }
            if input["location"] as? String == "settings" {
                settingsUI = true
            } else {
                model = SocialManagerModel()
            }
        case "stopUI": stopUI()
        case "view":
            if settingsUI {
                return NSHostingController(rootView: ExtensionPageHost { SocialManagerSettings() })
            }
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { SocialManagerPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            started = false
            suspendCommands(completion: {})
            commands.shutdown()
            stopUI()
        case "status": return ["ok": true, "running": started] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        settingsUI = false
        let stopping = model
        model = nil
        stopping?.shutdown()
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
