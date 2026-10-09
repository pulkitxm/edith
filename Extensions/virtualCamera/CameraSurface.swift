import CryptoKit
import EdithExtensionSupport
import Foundation

@MainActor
final class CameraSurface {
    private let engine: VirtualCameraEngine
    private let privacyValues: @MainActor () -> [String: String]

    init(
        engine: VirtualCameraEngine,
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
            providerID: "virtualCamera", command: command, payload: payload,
            snapshot: { [self] tile in snapshot(tile) },
            perform: { [self] identifier in try await perform(identifier) },
            adjust: { [self] identifier, value in try adjust(identifier, value: value) },
            privacyValues: privacyValues)
    }

    func snapshot(_ tile: SurfaceTile) -> SurfaceSnapshot {
        guard !SurfacePrivacyState.hides(tile.widget, values: privacyValues()) else {
            return .init(providerID: "virtualCamera", message: "Hidden while presenting.")
        }
        let current = engine.snapshot()
        let cameras = Array(current.sources.prefix(100))
        let scenes = Array(current.state.scenes.prefix(100))
        var rows = cameras.map { camera in
            let identifier = Self.identity("source:" + camera.id)
            return SurfaceDataRow(
                identifier, sourceID: identifier, title: Self.text(camera.name),
                detail: "Camera source",
                value: current.state.sourceID == camera.id ? "Selected" : "Available",
                icon: "camera.fill",
                actions: [.init("source:" + identifier, "Use camera", "camera.fill")])
        }
        rows += scenes.map { scene in
            let identifier = Self.identity("scene:" + scene.id.uuidString)
            return SurfaceDataRow(
                identifier, sourceID: identifier, title: Self.text(scene.name),
                detail: "Camera scene", icon: "rectangle.stack.fill",
                actions: [.init("scene:" + identifier, "Apply scene", "rectangle.stack.fill")])
        }
        var actions: [SurfaceAction] = []
        if current.state.privacy != .live {
            actions.append(.init("resume", "Go live", "video.fill"))
        } else {
            actions.append(.init("pause", "Pause camera", "pause.fill"))
        }
        if current.state.privacy != .stopped, current.recordingPath == nil {
            actions.append(.init("stop", "Stop camera", "stop.fill"))
        }
        if current.recordingPath != nil {
            actions.append(.init("record-stop", "Finish recording", "record.circle"))
        }
        let zoom = VirtualCameraFraming.zoomRange
        return .init(
            providerID: "virtualCamera",
            metrics: [
                .init("scenes", "Scenes", String(scenes.count)),
                .init("status", "Camera", Self.text(current.headline)),
            ], rows: rows, actions: actions,
            sliders: [
                .init(
                    "zoom", "Zoom", "plus.magnifyingglass",
                    value: (current.state.composition.framing.zoom - zoom.lowerBound)
                        / (zoom.upperBound - zoom.lowerBound))
            ], sources: rows.map { .init($0.sourceID, $0.title) },
            message: current.message.map(Self.text), updatedAt: Date())
    }

    private func perform(_ identifier: String) async throws {
        let current = engine.snapshot()
        switch identifier {
        case "resume": _ = try engine.perform(.resume)
        case "pause": _ = try engine.perform(.pause(.card, message: nil))
        case "stop": _ = try engine.perform(.pause(.stopped, message: nil))
        case "record-stop": _ = try await engine.performRecording(.recordStop)
        default:
            for camera in current.sources
            where identifier == "source:" + Self.identity("source:" + camera.id) {
                _ = try engine.perform(.selectSource(camera.id)); return
            }
            for scene in current.state.scenes
            where identifier == "scene:" + Self.identity("scene:" + scene.id.uuidString) {
                _ = try engine.perform(.applyScene(scene.id.uuidString)); return
            }
            throw ExtensionPeerError.invalidRequest
        }
    }

    private func adjust(_ identifier: String, value: Double) throws {
        guard identifier == "zoom", value.isFinite, (0...1).contains(value) else {
            throw ExtensionPeerError.invalidRequest
        }
        let range = VirtualCameraFraming.zoomRange
        _ = try engine.perform(
            .zoom(range.lowerBound + value * (range.upperBound - range.lowerBound)))
    }

    static func identity(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func text(_ value: String) -> String {
        var bounded = String(value.filter { $0 != "\0" }.prefix(250))
        while bounded.utf8.count > 1024 { bounded.removeLast() }
        return bounded.isEmpty ? "Camera" : bounded
    }
}
