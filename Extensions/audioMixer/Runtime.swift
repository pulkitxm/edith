import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithAudioMixerExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var uiModel: AnyObject?
    private var uiClient: ExtensionEngineClient?
    private var engine: AnyObject?
    private var surface: AnyObject?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard #available(macOS 14.4, *), let surface = self?.surface as? AudioMixerSurface
            else {
                throw ExtensionPeerError.unavailable
            }
            if command == "audioMixer.cli.catalog" { return try AudioCLICatalog.data() }
            if command == "audioMixer.cli" {
                guard let engine = self?.engine as? MixerEngine else {
                    throw ExtensionPeerError.unavailable
                }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await AudioCLIExecution.run(request, engine: engine))
            }
            if command == "audioMixer.ui.snapshot" {
                guard payload == Data("{}".utf8), let engine = self?.engine as? MixerEngine else {
                    throw ExtensionPeerError.invalidRequest
                }
                engine.refresh()
                let apps = engine.apps.map {
                    AudioMixerAppRecord(
                        objectID: $0.objectID, pid: $0.pid, bundleID: $0.bundleID, name: $0.name,
                        volume: Double($0.volume))
                }
                let icons = Dictionary(
                    uniqueKeysWithValues: engine.apps.compactMap { app in
                        app.icon?.tiffRepresentation.map { (String(app.objectID), $0) }
                    })
                return try JSONEncoder().encode(
                    AudioMixerUISnapshot(apps: apps, icons: icons, error: engine.errorMessage))
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
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client
            if #available(macOS 14.4, *) { uiModel = AudioMixerRemoteModel(client: client) }
        case "stopUI": stopUI()
        case "view":
            guard uiClient != nil else { return ["ok": false] as NSDictionary }
            if #available(macOS 14.4, *), let engine = uiModel as? AudioMixerRemoteModel {
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

    private func stopUI() {
        if #available(macOS 14.4, *) { (uiModel as? AudioMixerRemoteModel)?.stop() }
        uiModel = nil; uiClient?.invalidate(); uiClient = nil
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            if #available(macOS 14.4, *) { (engine as? MixerEngine)?.shutdown() }
            completion()
        }
    }

    @available(macOS 14.4, *)
    private func makeEngine() -> MixerEngine {
        if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
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
