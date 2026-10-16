import EdithExtensionSupport
import Foundation

@available(macOS 14.4, *)
@MainActor
enum AudioMixerAction {
    static func perform(_ request: AudioMixerRuntimeRequest, engine: MixerEngine) -> (
        snapshot: AudioMixerListSnapshot, error: String?
    ) {
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

@available(macOS 14.4, *)
@MainActor
enum AudioMixerUICommand {
    static func execute(_ operation: String, payload: Data, engine: MixerEngine) throws -> Data? {
        switch operation {
        case "audioMixer.ui.snapshot":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            engine.refresh()
            return try JSONEncoder().encode(
                snapshot(engine, icons: true, error: engine.errorMessage))
        case "audioMixer.ui.retry":
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            engine.retry()
            return try JSONEncoder().encode(
                snapshot(engine, icons: false, error: engine.errorMessage))
        case "audioMixer.ui.volume":
            guard let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                let request = AudioMixerRuntimeRequest(payload: raw), request.isLive(at: Date()),
                request.request == .volume
            else { throw ExtensionPeerError.invalidRequest }
            let outcome = AudioMixerAction.perform(request, engine: engine)
            return try JSONEncoder().encode(
                snapshot(engine, icons: false, error: outcome.error ?? engine.discoveryError))
        default:
            return nil
        }
    }

    private static func snapshot(_ engine: MixerEngine, icons: Bool, error: String?)
        -> AudioMixerUISnapshot
    {
        let apps = engine.apps.map {
            AudioMixerAppRecord(
                objectID: $0.objectID, pid: $0.pid, bundleID: $0.bundleID, name: $0.name,
                volume: Double($0.volume))
        }
        let images =
            icons
            ? Dictionary(
                uniqueKeysWithValues: engine.apps.compactMap { app in
                    AudioMixerIcon.png(app.icon).map { (String(app.objectID), $0) }
                }) : [:]
        return AudioMixerUISnapshot(apps: apps, icons: images, error: error)
    }
}
