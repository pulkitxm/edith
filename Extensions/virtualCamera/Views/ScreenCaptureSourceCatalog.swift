import AppKit
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
    var displays: [TimeLapseDisplayChoice] = []
    var windows: [TimeLapseWindowChoice] = []
    var sourceRevision = 0
    let sourceLoad = ContentLoad()
    var captureSelectionBlocked: Bool { false }
    @ObservationIgnored private var snapshot: TimeLapseSources?
    @ObservationIgnored private var thumbnails: [String: CGImage] = [:]
    private let thumbnailLoader = TimeLapseThumbnailLoader()

    func refreshCaptureSources() async {
        await sourceLoad.perform(operation: { try await TimeLapseSources.load() }) {
            [self] sources in
            snapshot = sources
            displays = sources.displayChoices
            windows = sources.windowChoices
            thumbnails.removeAll()
            sourceRevision += 1
        }
    }

    func sourceThumbnail(mode: String, id: UInt32) async -> CGImage? {
        guard let snapshot else { return nil }
        let key = "\(mode)-\(id)"
        if let image = thumbnails[key] { return image }
        let revision = sourceRevision
        let image = await thumbnailLoader.load { await snapshot.thumbnail(mode: mode, id: id) }
        guard !Task.isCancelled, revision == sourceRevision else { return nil }
        if let image {
            if thumbnails.count >= 32 { thumbnails.removeAll() }
            thumbnails[key] = image
        }
        return image
    }
}
