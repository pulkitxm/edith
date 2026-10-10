import EdithStudio
import Foundation

struct StudioUIState: Codable, Sendable {
    struct Environment: Codable, Sendable {
        let ffmpeg: URL?
        let ffprobe: URL?
        let qpdf: URL?
        let appleIntelligenceAvailable: Bool

        init(_ environment: StudioEnvironment) {
            ffmpeg = environment.ffmpeg
            ffprobe = environment.ffprobe
            qpdf = environment.qpdf
            appleIntelligenceAvailable = environment.appleIntelligenceAvailable
        }

        var value: StudioEnvironment {
            StudioEnvironment(
                ffmpeg: ffmpeg, ffprobe: ffprobe, qpdf: qpdf,
                appleIntelligenceAvailable: appleIntelligenceAvailable)
        }
    }

    struct Project: Codable, Sendable {
        let url: URL
        let title: String
        let isOpenScreenLibrary: Bool
        let previewURL: URL?
        let modified: Date

        init(_ listing: VideoProject.Listing) {
            url = listing.url
            title = listing.title
            isOpenScreenLibrary = listing.isOpenScreenLibrary
            previewURL = listing.previewURL
            modified = listing.modified
        }

        var value: VideoProject.Listing {
            VideoProject.Listing(
                url: url, title: title, isOpenScreenLibrary: isOpenScreenLibrary,
                previewURL: previewURL, modified: modified)
        }
    }

    let files: [StudioMediaItem]
    let projects: [Project]
    let recent: [StudioRecentRun]
    let workflows: [StudioWorkflow]
    let environment: Environment
    var destinationMode: String = StudioDestinationMode.original.rawValue
    var destinationFolder: String = ""
    var installing: StudioEngine?
    var installLog: String?
    var message: String?
    var pendingOpen: VideoEditorService.OpenRequest?
}

struct StudioUIFileFacts: Codable, Sendable {
    let bytes: Int64
    let detail: String?
    let exists: Bool

    init(_ facts: StudioFileFacts) {
        bytes = facts.bytes
        detail = facts.detail
        exists = facts.exists
    }

    var value: StudioFileFacts { StudioFileFacts(bytes: bytes, detail: detail, exists: exists) }
}
