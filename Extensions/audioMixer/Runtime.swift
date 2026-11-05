import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class AudioMixerService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var uiModel: AnyObject?
    private var uiClient: ExtensionEngineClient?
    private var uiLocation: String?
    private var engine: AnyObject?
    private var surface: AnyObject?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { engine != nil }
    var allowsUIDuringRetirement: Bool { true }

    func start() -> Bool {
        guard SurfaceHostContext.current != nil else { return false }
        if #available(macOS 14.4, *), engine == nil {
            let mixer = makeEngine()
            engine = mixer
            surface = AudioMixerSurface(engine: mixer)
        }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard #available(macOS 14.4, *), let surface = self.surface as? AudioMixerSurface
        else {
            throw ExtensionPeerError.unavailable
        }
        if command == "audioMixer.cli.catalog" { return try AudioCLICatalog.data() }
        if command == "audioMixer.cli" {
            guard let engine = self.engine as? MixerEngine else {
                throw ExtensionPeerError.unavailable
            }
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await AudioCLIExecution.run(request, engine: engine))
        }
        if command.hasPrefix("audioMixer.ui."), let engine = self.engine as? MixerEngine {
            if let reply = try AudioMixerUICommand.execute(
                command, payload: payload, engine: engine)
            {
                return reply
            }
            throw ExtensionPeerError.invalidRequest
        }
        if command == "audioMixer.request" {
            guard let engine = self.engine as? MixerEngine,
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

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 8 else { return false }
        if configuration.isSettings {
            guard configuration.section == "extension" else { return false }
            configuration.engineClient?.invalidate()
            releaseUI()
            uiLocation = "settings"
            return true
        }
        guard let client = configuration.engineClient else { return false }
        releaseUI()
        uiClient = client
        uiLocation = configuration.location
        if #available(macOS 14.4, *) { uiModel = AudioMixerRemoteModel(client: client) }
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard !runtime.isSuspended else { return nil }
        if uiLocation == "settings" {
            return NSHostingController(rootView: ExtensionPageHost { AudioMixerSettingsPage() })
        }
        guard uiClient != nil else { return nil }
        if #available(macOS 14.4, *), let engine = uiModel as? AudioMixerRemoteModel {
            if uiLocation == "notch" {
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        AudioMixerView(engine: engine, notch: true)
                    })
            }
            return NSHostingController(
                rootView: ExtensionPageHost { AudioMixerPage(engine: engine) })
        }
        return NSHostingController(
            rootView: ExtensionPageHost {
                Text("Per-app volume needs macOS 14.4 or later")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        if #available(macOS 14.4, *) {
            (engine as? MixerEngine)?.cancelPendingCommands()
            (uiModel as? AudioMixerRemoteModel)?.stop()
        }
    }

    func drain() async {
        if #available(macOS 14.4, *) {
            await (engine as? MixerEngine)?.cancelAndWait()
            await (uiModel as? AudioMixerRemoteModel)?.stopAndWait()
        }
        while let task = uiDrains.values.first { await task.value }
    }

    func teardown() async {
        let owner = engine
        releaseUI()
        engine = nil
        surface = nil
        if #available(macOS 14.4, *) { await (owner as? MixerEngine)?.shutdownAndWait() }
        while let task = uiDrains.values.first { await task.value }
    }

    @discardableResult
    private func releaseUI() -> Task<Void, Never>? {
        var retirement: Task<Void, Never>?
        if #available(macOS 14.4, *), let owner = uiModel as? AudioMixerRemoteModel {
            owner.stop()
            let id = UUID()
            let task = Task { [self] in
                defer { uiDrains[id] = nil }
                await owner.stopAndWait()
            }
            uiDrains[id] = task
            retirement = task
        }
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
        uiLocation = nil
        return retirement
    }

    @available(macOS 14.4, *)
    private func makeEngine() -> MixerEngine {
        if ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] != nil {
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

@MainActor
func makeAudioMixerRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "audioMixer", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { AudioMixerService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeAudioMixerRuntime()).toOpaque())
        })
}
