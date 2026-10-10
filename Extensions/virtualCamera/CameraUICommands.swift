import AVFoundation
import AppKit
import CoreImage
import EdithExtensionSupport
import Foundation
import ImageIO

struct CameraUISnapshot: Codable {
    let snapshot: VirtualCameraSnapshot
    let preview: Data?
    let reference: Data?
    let previewFailure: String?
}
struct CameraUIAsset: Codable { let path: String; let target: String }
struct CameraUIImage: Codable { let image: Data? }
struct CameraUISources: Codable {
    let displays: [TimeLapseDisplayChoice]; let windows: [TimeLapseWindowChoice]
    let revision: Int; let error: String?
}
struct CameraUIThumbnail: Codable { let mode: String; let id: UInt32 }

@MainActor final class CameraUICommands {
    private let engine: VirtualCameraEngine
    private let model: VirtualCameraPageModel
    private let defaults: UserDefaults
    private let sources = ScreenCaptureSourceCatalog()
    private var lease: Task<Void, Never>?
    private var previewVisible = false
    private var stopped = false
    private let context = CIContext()
    init(engine: VirtualCameraEngine, model: VirtualCameraPageModel, defaults: UserDefaults) {
        self.engine = engine; self.model = model; self.defaults = defaults
    }
    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        switch command {
        case "camera.ui.snapshot":
            try empty(payload)
            renewLease()
            var snapshot = engine.snapshot()
            snapshot.sourceWidth = model.previewStatistics.sourceWidth
            snapshot.sourceHeight = model.previewStatistics.sourceHeight
            return try JSONEncoder().encode(
                CameraUISnapshot(
                    snapshot: snapshot,
                    preview: model.display.current.flatMap {
                        context.createCGImage(
                            CIImage(cvPixelBuffer: $0), from: CIImage(cvPixelBuffer: $0).extent)
                    }.flatMap(Self.image),
                    reference: model.previewReference.flatMap(Self.image),
                    previewFailure: model.previewFailure))
        case "camera.ui.state":
            let state = try JSONDecoder().decode(VirtualCameraState.self, from: payload)
            guard state == state.sanitized(), state.output == .obs, state.scenes.count <= 64,
                state.media.path.map({ $0.hasPrefix("/") && !$0.utf8.contains(0) }) ?? true
            else { throw ExtensionPeerError.invalidRequest }
            let current = VirtualCameraStore.referencedAssets(in: engine.snapshot().state)
            let directory = VirtualCameraStore.assetsDirectory.standardizedFileURL.path + "/"
            guard
                VirtualCameraStore.referencedAssets(in: state).allSatisfy({ path in
                    !path.utf8.contains(0)
                        && (current.contains(path)
                            || URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(
                                directory))
                })
            else { throw ExtensionPeerError.invalidRequest }
            VirtualCameraStore.save(state, to: defaults); engine.syncSettings(state);
            model.reloadState(state)
            VirtualCameraStore.pruneAssets(keeping: state)
        case "camera.ui.importAsset":
            let input = try JSONDecoder().decode(CameraUIAsset.self, from: payload)
            guard input.path.hasPrefix("/"), !input.path.utf8.contains(0),
                ["logo", "background"].contains(input.target)
            else { throw ExtensionPeerError.invalidRequest }
            let stored = try VirtualCameraStore.importAsset(from: URL(fileURLWithPath: input.path))
            var state = engine.snapshot().state
            if input.target == "logo" {
                state.composition.overlays.logo.imagePath = stored.path;
                state.composition.overlays.logo.enabled = true
            } else {
                state.composition.background.imagePath = stored.path;
                state.composition.background.mode = .image
            }
            VirtualCameraStore.save(state, to: defaults); engine.syncSettings(state);
            model.reloadState(state)
        case "camera.ui.asset":
            let input = try JSONDecoder().decode([String: String].self, from: payload)
            guard Set(input.keys) == ["path"], let path = input["path"],
                VirtualCameraStore.referencedAssets(in: engine.snapshot().state).contains(path)
            else { throw ExtensionPeerError.invalidRequest }
            let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil).flatMap
            {
                CGImageSourceCreateThumbnailAtIndex(
                    $0, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1024,
                    ] as CFDictionary)
            }
            return try JSONEncoder().encode(CameraUIImage(image: image.flatMap(Self.image)))
        case "camera.ui.devices":
            try empty(payload)
            return try JSONEncoder().encode(MeetingAudioDevices.list())
        case "camera.ui.permission":
            try empty(payload); model.requestCameraAccess()
        case "camera.ui.screenSources":
            try empty(payload); await sources.refreshCaptureSources()
            return try JSONEncoder().encode(
                CameraUISources(
                    displays: sources.displays, windows: sources.windows,
                    revision: sources.sourceRevision, error: sources.sourceLoad.errorMessage))
        case "camera.ui.screenThumbnail":
            let input = try JSONDecoder().decode(CameraUIThumbnail.self, from: payload)
            guard ["windows", "displays"].contains(input.mode) else {
                throw ExtensionPeerError.invalidRequest
            }
            return try JSONEncoder().encode(
                CameraUIImage(
                    image: await sources.sourceThumbnail(mode: input.mode, id: input.id).flatMap(
                        Self.image)))
        default: throw ExtensionPeerError.invalidRequest
        }
        return try JSONEncoder().encode(engine.snapshot())
    }
    private static func image(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg, properties: [.compressionFactor: 0.8])
    }
    private func renewLease() {
        if !previewVisible { previewVisible = true; model.appear() }
        lease?.cancel()
        lease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self else { return }
            model.disappear(); previewVisible = false
        }
    }
    func shutdown() async {
        stopped = true; lease?.cancel(); lease = nil
        if previewVisible { model.disappear(); previewVisible = false }
        await sources.shutdown()
    }
    private func empty(_ data: Data) throws {
        guard data == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
    }
}
