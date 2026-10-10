import CryptoKit
import EdithExtensionSupport
import Foundation

@available(macOS 14.4, *)
@MainActor
final class AudioMixerSurface {
    private let engine: MixerEngine
    private let privacyValues: @MainActor () -> [String: String]

    init(
        engine: MixerEngine,
        privacyValues: @escaping @MainActor () -> [String: String] = {
            ExtensionSharedState.current?.values(for: "presenter") ?? [:]
        }
    ) {
        self.engine = engine
        self.privacyValues = privacyValues
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !engine.isStopped else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "audioMixer", command: command, payload: payload,
            snapshot: { [self] tile in snapshot(tile) },
            perform: { [self] identifier in try perform(identifier) },
            adjust: { [self] identifier, value in try adjust(identifier, value: value) },
            privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) -> SurfaceSnapshot {
        guard !SurfacePrivacyState.hides(tile.widget, values: privacyValues()) else {
            return .init(providerID: "audioMixer", message: "Hidden while presenting.")
        }
        engine.refresh()
        let apps = Array(engine.apps.prefix(100))
        let sources = apps.map { SurfaceSourceChoice(Self.identity($0), Self.text($0.name)) }
        let selected = apps.filter { tile.sourceIDs?.contains(Self.identity($0)) ?? true }
        let rows = selected.prefix(min(32, tile.itemLimit)).map { app in
            let identity = Self.identity(app)
            return SurfaceDataRow(
                identity, sourceID: identity, title: Self.text(app.name),
                detail: Self.text(app.bundleID), value: String(Int(app.volume * 100)) + "%",
                icon: app.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                actions: [
                    .init(
                        (app.volume == 0 ? "restore:" : "mute:") + identity,
                        app.volume == 0 ? "Restore volume" : "Mute", "speaker.wave.2.fill",
                        field: "volume")
                ],
                sliders: [
                    .init(
                        "volume:" + identity, "Volume", "speaker.wave.2.fill",
                        value: Double(app.volume), field: "volume")
                ])
        }
        return .init(
            providerID: "audioMixer",
            metrics: [
                .init("apps", "Playing apps", String(selected.count)),
                .init("muted", "Muted apps", String(selected.filter { $0.volume == 0 }.count)),
            ],
            rows: rows, actions: [.init("refresh", "Refresh", "arrow.clockwise")],
            sources: sources, message: engine.errorMessage.map(Self.text), updatedAt: Date())
    }

    private func perform(_ identifier: String) throws {
        if identifier == "refresh" { engine.retry(); return }
        engine.refresh()
        for app in engine.apps {
            let identity = Self.identity(app)
            if identifier == "mute:" + identity {
                engine.setVolume(app, 0); return try checkResult()
            }
            if identifier == "restore:" + identity {
                engine.setVolume(app, 1); return try checkResult()
            }
        }
        throw ExtensionPeerError.invalidRequest
    }

    private func adjust(_ identifier: String, value: Double) throws {
        engine.refresh()
        guard value.isFinite, (0...1).contains(value),
            let app = engine.apps.first(where: { "volume:" + Self.identity($0) == identifier })
        else { throw ExtensionPeerError.invalidRequest }
        engine.setVolume(app, Float(value))
        try checkResult()
    }

    private func checkResult() throws {
        if let error = engine.actionError {
            throw NSError(
                domain: "AudioMixer", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
        }
    }

    static func identity(_ app: MixerApp) -> String {
        let value = "\(app.objectID):\(app.pid):\(app.bundleID)"
        return SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }
            .joined()
    }

    private static func text(_ value: String) -> String {
        var result = String(value.filter { $0 != "\0" }.prefix(250))
        while result.utf8.count > 1024 { result.removeLast() }
        return result.isEmpty ? "Audio app" : result
    }
}
