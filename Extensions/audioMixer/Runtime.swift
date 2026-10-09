import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithAudioMixerExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var engine: AnyObject?
    private var surface: AnyObject?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard #available(macOS 14.4, *), let surface = self?.surface as? AudioMixerSurface
            else {
                throw ExtensionPeerError.unavailable
            }
            if command == "audioMixer.request" {
                guard let engine = self?.engine as? MixerEngine,
                    let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    let request = AudioMixerRuntimeRequest(payload: raw), request.isLive(at: Date())
                else { throw ExtensionPeerError.invalidRequest }
                let outcome = AudioMixerAction.perform(request, engine: engine)
                if let error = outcome.error {
                    throw NSError(
                        domain: "AudioMixer", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error])
                }
                return try JSONEncoder().encode(outcome.snapshot)
            }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "audioMixer", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if #available(macOS 14.4, *), engine == nil {
                let mixer = makeEngine()
                engine = mixer
                surface = AudioMixerSurface(engine: mixer)
            }
        case "view":
            if #available(macOS 14.4, *), let engine = engine as? MixerEngine {
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        PageWorkspace {
                            PageHeader("Audio Mixer")
                        } content: {
                            AudioMixerView(engine: engine)
                        }
                    })
            }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    Text("Per-app volume needs macOS 14.4 or later.")
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            if #available(macOS 14.4, *) { (engine as? MixerEngine)?.shutdown() }
            engine = nil; surface = nil
        case "status": return ["ok": true, "running": engine != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    @available(macOS 14.4, *)
    private func makeEngine() -> MixerEngine {
        if ProcessInfo.processInfo.environment["EDITH_TEST_RUNTIME_ROOT"] != nil {
            return MixerEngine(
                snapshotLoader: {
                    .init(
                        apps: [
                            .init(
                                objectID: 41, pid: 900, bundleID: "org.example.synthetic.audio",
                                name: "Synthetic audio", icon: nil, volume: 1)
                        ], outputUID: "synthetic-output")
                }, tapFactory: { _, _, _ in .success(SyntheticMixerTap()) })
        }
        return MixerEngine()
    }
}

private final class SyntheticMixerTap: AudioMixerTapControlling {
    func setGain(_ value: Float) {}
    func destroy() {}
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
