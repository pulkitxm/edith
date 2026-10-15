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
    let revision: String?
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
