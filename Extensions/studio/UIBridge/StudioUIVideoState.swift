import AVFoundation
import EdithExtensionSupport
import Foundation

struct VideoPreviewMetadata {
    let segments: [VideoRenderPipeline.Segment]
    let canvas: CGSize
    let frameDuration: CMTime
    var duration: Double { segments.last?.outputEnd ?? 0 }

    init(_ pipeline: VideoRenderPipeline) {
        segments = pipeline.segments
        canvas = pipeline.canvas
        frameDuration = pipeline.videoComposition.frameDuration
    }

    init(_ value: StudioUIVideoPreview, project: VideoProject) throws {
        canvas = value.canvas
        frameDuration = CMTime(value: value.frameValue, timescale: value.frameScale)
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0,
            value.frameScale > 0, value.frameValue > 0, value.segments.count <= 10_000
        else {
            throw StudioUIOperationFailure(message: "The video preview metadata is invalid.")
        }
        segments = try value.segments.map { segment in
            guard let clip = project.clips.first(where: { $0.id == segment.clipID }),
                segment.sourceScale > 0, segment.outputScale > 0, segment.sourceDurationScale > 0,
                segment.outputDurationScale > 0, segment.rate.isFinite,
                segment.rate > 0, segment.sourceDuration > 0, segment.outputDuration > 0
            else {
                throw StudioUIOperationFailure(message: "The video preview segment is invalid.")
            }
            return VideoRenderPipeline.Segment(
                clip: clip,
                sourceRange: CMTimeRange(
                    start: CMTime(value: segment.sourceStart, timescale: segment.sourceScale),
                    duration: CMTime(
                        value: segment.sourceDuration, timescale: segment.sourceDurationScale)),
                rate: segment.rate,
                outputRange: CMTimeRange(
                    start: CMTime(value: segment.outputStart, timescale: segment.outputScale),
                    duration: CMTime(
                        value: segment.outputDuration, timescale: segment.outputDurationScale))
            )
        }
    }
}

struct StudioUIVideoPreview: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let clipID: String
        let sourceStart: Int64
        let sourceDuration: Int64
        let sourceScale: Int32
        let sourceDurationScale: Int32
        let rate: Double
        let outputStart: Int64
        let outputDuration: Int64
        let outputScale: Int32
        let outputDurationScale: Int32

        init(_ segment: VideoRenderPipeline.Segment) {
            clipID = segment.clip.id
            sourceStart = segment.sourceRange.start.value
            sourceDuration = segment.sourceRange.duration.value
            sourceScale = segment.sourceRange.start.timescale
            sourceDurationScale = segment.sourceRange.duration.timescale
            rate = segment.rate
            outputStart = segment.outputRange.start.value
            outputDuration = segment.outputRange.duration.value
            outputScale = segment.outputRange.start.timescale
            outputDurationScale = segment.outputRange.duration.timescale
        }
    }
    let segments: [Segment]
    let canvas: CGSize
    let frameValue: Int64
    let frameScale: Int32

    init(_ pipeline: VideoRenderPipeline) {
        segments = pipeline.segments.map(Segment.init)
        canvas = pipeline.canvas
        frameValue = pipeline.videoComposition.frameDuration.value
        frameScale = pipeline.videoComposition.frameDuration.timescale
    }
}

struct StudioUIVideoProject: Codable, Sendable {
    let document: Data
    let fileURL: URL?

    init(_ project: VideoProject) throws {
        document = try JSONSerialization.data(
            withJSONObject: project.root, options: [.sortedKeys, .withoutEscapingSlashes])
        fileURL = project.fileURL
    }

    var value: VideoProject {
        get throws {
            guard document.count <= 32 * 1024 * 1024,
                let root = try JSONSerialization.jsonObject(with: document) as? [String: Any]
            else {
                throw StudioUIOperationFailure(message: "The video project is invalid.")
            }
            let project = VideoProject(root: root, fileURL: fileURL)
            try VideoEditorService.validateStructure(project)
            if let fileURL {
                guard fileURL.isFileURL, fileURL.host == nil || fileURL.host == "localhost" else {
                    throw ExtensionPeerError.invalidRequest
                }
                _ = try StudioCommands.localPath(fileURL.path)
            }
            return project
        }
    }
}

struct StudioUIVideoOpenInfo: Codable, Sendable {
    let project: StudioUIVideoProject
    let missingAssetIDs: [String]
    let revision: String
}

struct StudioUIVideoState: Codable, Sendable {
    let project: StudioUIVideoProject?
    let preview: StudioUIVideoPreview?
    let revision: String?
    let playhead: Double
    let rate: Float
    let preparing: Bool
    let error: String?
    let externalSyncMessage: String?
    let permissionSettingsURL: URL?
    let export: StudioUIVideoExport?
    let audioStatus: String?
    let transcribing: Bool
    let silenceClipID: String?
    let silentRanges: [ClosedRange<Double>]
    let recent: [StudioUIState.Project]
}

struct StudioUIVideoFrame: Codable, Sendable {
    let image: StudioUIImageData?
    let playhead: Double
    let rate: Float
}
