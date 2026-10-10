import AppKit
import EdithExtensionSupport
import ImageIO
import EdithExtensionUI
import Observation

@MainActor
protocol ScreenCaptureSourceProviding {
    var displays: [TimeLapseDisplayChoice] { get }
    var windows: [TimeLapseWindowChoice] { get }
    var sourceRevision: Int { get }
    var sourceLoad: ContentLoad { get }
    var captureSelectionBlocked: Bool { get }
    func refreshCaptureSources() async
    func sourceThumbnail(mode: String, id: UInt32) async -> CGImage?
}

@MainActor @Observable
final class ScreenCaptureSourceCatalog: ScreenCaptureSourceProviding {
    private final class WeakInstance {
        weak var value: ScreenCaptureSourceCatalog?
        init(_ value: ScreenCaptureSourceCatalog) { self.value = value }
    }
    private static var instances: [WeakInstance] = []
    private var stopped = false
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    private let engineClient: ExtensionEngineClient?
    init(engineClient: ExtensionEngineClient? = nil) {
        self.engineClient = engineClient
        Self.instances.removeAll { $0.value == nil }
        Self.instances.append(WeakInstance(self))
    }
    static func shutdownAll() async {
        let pending = instances.compactMap(\.value)
        for catalog in pending { await catalog.shutdown() }
        instances.removeAll()
    }
    func shutdown() async {
        if shutdownTask == nil {
            stopped = true; sourceLoad.cancel()
            let loader = thumbnailLoader
            shutdownTask = Task { await loader.shutdown() }
        }
        await shutdownTask?.value
        snapshot = nil; thumbnails.removeAll(); displays.removeAll(); windows.removeAll()
    }
    var displays: [TimeLapseDisplayChoice] = []
    var windows: [TimeLapseWindowChoice] = []
    var sourceRevision = 0
    let sourceLoad = ContentLoad()
    var captureSelectionBlocked: Bool { false }
    @ObservationIgnored private var snapshot: TimeLapseSources?
    @ObservationIgnored private var thumbnails: [String: CGImage] = [:]
    private let thumbnailLoader = TimeLapseThumbnailLoader()

    func refreshCaptureSources() async {
        guard !stopped else { return }
        if let engineClient {
            await sourceLoad.perform(operation: {
                let data = try await engineClient.invoke("camera.ui.screenSources")
                return try JSONDecoder().decode(CameraUISources.self, from: data)
            }) { [self] value in
                guard !stopped else { return }
                displays = value.displays; windows = value.windows; sourceRevision = value.revision;
                thumbnails.removeAll()
                if let error = value.error { sourceLoad.fail(sourceLoad.begin(), message: error) }
            }; return
        }
        await sourceLoad.perform(operation: { try await TimeLapseSources.load() }) {
            [self] sources in
            guard !stopped else { return }
            snapshot = sources
            displays = sources.displayChoices
            windows = sources.windowChoices
            thumbnails.removeAll()
            sourceRevision += 1
        }
    }

    func sourceThumbnail(mode: String, id: UInt32) async -> CGImage? {
        guard !stopped else { return nil }
        if let engineClient {
            let revision = sourceRevision
            guard let payload = try? JSONEncoder().encode(CameraUIThumbnail(mode: mode, id: id)),
                let data = try? await engineClient.invoke(
                    "camera.ui.screenThumbnail", payload: payload),
                !stopped, !Task.isCancelled, revision == sourceRevision,
                let value = try? JSONDecoder().decode(CameraUIImage.self, from: data),
                let image = value.image,
                let source = CGImageSourceCreateWithData(image as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let snapshot else { return nil }
        let key = "\(mode)-\(id)"
        if let image = thumbnails[key] { return image }
        let revision = sourceRevision
        let image = await thumbnailLoader.load { await snapshot.thumbnail(mode: mode, id: id) }
        guard !stopped, !Task.isCancelled, revision == sourceRevision else { return nil }
        if let image {
            if thumbnails.count >= 32 { thumbnails.removeAll() }
            thumbnails[key] = image
        }
        return image
    }
}
