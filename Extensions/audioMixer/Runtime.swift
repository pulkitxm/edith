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
    private var uiLocation: String?
    private var engine: AnyObject?
    private var surface: AnyObject?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
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
            if command.hasPrefix("audioMixer.ui."), let engine = self?.engine as? MixerEngine {
                if let reply = try AudioMixerUICommand.execute(
                    command, payload: payload, engine: engine)
                {
                    return reply
                }
                throw ExtensionPeerError.invalidRequest
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
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
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
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            if input["location"] as? String == "settings" {
                guard input["section"] as? String == "extension" else {
                    return ["ok": false] as NSDictionary
                }
                stopUI(); uiLocation = "settings"
                return ["ok": true] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client
            uiLocation = input["location"] as? String
            if #available(macOS 14.4, *) { uiModel = AudioMixerRemoteModel(client: client) }
        case "stopUI": stopUI()
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            if uiLocation == "settings" {
                return NSHostingController(rootView: ExtensionPageHost { AudioMixerSettingsPage() })
            }
            guard uiClient != nil else { return ["ok": false] as NSDictionary }
            if #available(macOS 14.4, *), let engine = uiModel as? AudioMixerRemoteModel {
                if uiLocation == "notch" {
                    return NSHostingController(
                        rootView: ExtensionPageHost {
                            AudioMixerView(engine: engine, notch: true)
                        })
                }
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
                    Text("Per-app volume needs macOS 14.4 or later")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            _ = beginResourceStop()
        case "status": return ["ok": true, "running": engine != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        if #available(macOS 14.4, *), let owner = uiModel as? AudioMixerRemoteModel {
            owner.stop()
            let id = UUID()
            uiDrains[id] = Task { [self] in
                defer { uiDrains[id] = nil }
                await owner.stopAndWait()
            }
        }
        uiModel = nil; uiClient?.invalidate(); uiClient = nil; uiLocation = nil
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = engine
        let uiOwner = uiModel
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        if #available(macOS 14.4, *) {
            (owner as? MixerEngine)?.cancelPendingCommands()
            (uiOwner as? AudioMixerRemoteModel)?.stop()
        }
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            if #available(macOS 14.4, *) {
                await (owner as? MixerEngine)?.cancelAndWait()
                await (uiOwner as? AudioMixerRemoteModel)?.stopAndWait()
            }
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = engine
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        stopUI()
        engine = nil; surface = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            if #available(macOS 14.4, *) { await (owner as? MixerEngine)?.shutdownAndWait() }
        }
        resourceStop = task
        return task
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
