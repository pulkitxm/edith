import EdithKit
import Foundation

@MainActor
final class AudioMixerActionBridge {
    static let shared = AudioMixerActionBridge()

    private var token: NSObjectProtocol?

    func install() {
        guard token == nil else { return }
        token = IPC.observe(
            IPC.Name.requestAudioMixerAction,
            info: { [weak self] info in
                MainActor.assumeIsolated { self?.receive(info) }
            })
    }

    private func receive(_ info: [AnyHashable: Any]) {
        let requestID = info[AudioMixerIPC.requestIDKey] as? String
        guard let runtime = AudioMixerRuntimeRequest(payload: info) else {
            guard let requestID else { return }
            reply(
                requestID: requestID, ok: false, snapshot: nil,
                error: "The audio request is invalid.")
            return
        }
        guard runtime.isLive(at: Date()) else {
            reply(
                requestID: runtime.requestID, ok: false, snapshot: nil,
                error: "The audio request expired before it ran.")
            return
        }
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.Notch.audioMixerEnabled) else {
            reply(
                requestID: runtime.requestID, ok: false, snapshot: nil,
                error: "Enable Audio Mixer in Extensions to use these controls.")
            return
        }
        guard #available(macOS 14.4, *) else {
            reply(
                requestID: runtime.requestID, ok: false, snapshot: nil,
                error: "Per-app volume needs macOS 14.4 or later.")
            return
        }
        let outcome = AudioMixerAction.perform(runtime)
        reply(
            requestID: runtime.requestID, ok: outcome.error == nil, snapshot: outcome.snapshot,
            error: outcome.error)
    }

    private func reply(
        requestID: String, ok: Bool, snapshot: AudioMixerListSnapshot?, error: String?
    ) {
        var payload: [String: Any] = [
            AudioMixerIPC.requestIDKey: requestID, AudioMixerIPC.okKey: ok,
        ]
        if let encoded = snapshot?.encoded() { payload[AudioMixerIPC.snapshotKey] = encoded }
        if let error { payload[AudioMixerIPC.errorKey] = error }
        IPC.post(IPC.Name.audioMixerActionResult, userInfo: payload)
    }
}

@available(macOS 14.4, *)
@MainActor
enum AudioMixerAction {
    static func perform(_ request: AudioMixerRuntimeRequest) -> (
        snapshot: AudioMixerListSnapshot, error: String?
    ) {
        let engine = MixerEngine.shared
        engine.refresh()
        if let discovery = engine.discoveryError, engine.apps.isEmpty {
            return (AudioMixerListSnapshot(apps: [], changed: false), discovery)
        }
        switch request.request {
        case .list:
            return (snapshot(engine, changed: false), nil)
        case .volume, .mute, .unmute:
            let records = records(engine)
            let match: AudioMixerAppRecord
            do {
                match =
                    try request.target?.match(in: records)
                    ?? AudioMixerSelector.match(request.app, in: records)
            } catch {
                return (snapshot(engine, changed: false), error.localizedDescription)
            }
            guard
                let app = engine.apps.first(where: {
                    $0.objectID == match.objectID && $0.pid == match.pid
                })
            else {
                return (
                    snapshot(engine, changed: false),
                    AudioMixerSelectionError.notFound(request.app).localizedDescription
                )
            }
            let value = gain(for: request)
            engine.setVolume(app, value)
            if let actionError = engine.actionError {
                return (snapshot(engine, changed: false), actionError)
            }
            return (snapshot(engine, changed: true), nil)
        }
    }

    private static func gain(for request: AudioMixerRuntimeRequest) -> Float {
        switch request.request {
        case .mute: 0
        case .unmute: 1
        case .volume: Float(max(0, min(1, request.volume)))
        case .list: 1
        }
    }

    private static func records(_ engine: MixerEngine) -> [AudioMixerAppRecord] {
        var records: [AudioMixerAppRecord] = []
        for app in engine.apps {
            records.append(
                AudioMixerAppRecord(
                    objectID: app.objectID, pid: app.pid, bundleID: app.bundleID, name: app.name,
                    volume: Double(app.volume)))
        }
        return records
    }

    private static func snapshot(_ engine: MixerEngine, changed: Bool) -> AudioMixerListSnapshot {
        AudioMixerListSnapshot(apps: records(engine), changed: changed)
    }
}
