import EdithExtensionSupport
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
    var export: StudioUIVideoExport?
    var presentation: StudioUIPresentation?
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

struct StudioUIPresentation: Codable, Sendable {
    let token: UUID
    let kind: String
    let urls: [URL]
    let project: URL?
    let mode: StudioPDFEditorMode?
    let tab: StudioTab
    let selection: [URL]

    init?(route: StudioRoute, tab: StudioTab, selection: Set<URL>) {
        token = UUID(); self.tab = tab; self.selection = selection.sorted { $0.path < $1.path }
        switch route {
        case .home: kind = "home"; urls = []; project = nil; mode = nil
        case let .imageEditor(url): kind = "image"; urls = [url]; project = nil; mode = nil
        case let .pdfEditor(url, mode): kind = "pdf"; urls = [url]; project = nil; self.mode = mode
        case let .videoEditor(urls, project):
            kind = "video"; self.urls = urls; self.project = project; mode = nil
        default: return nil
        }
    }

    var route: StudioRoute {
        get throws {
            guard urls.count <= StudioCommands.maximumPaths,
                selection.count <= StudioCommands.maximumPaths
            else { throw ExtensionPeerError.invalidRequest }
            for url in urls + selection + [project].compactMap({ $0 }) {
                guard url.isFileURL, url.host == nil || url.host == "localhost" else {
                    throw ExtensionPeerError.invalidRequest
                }
                _ = try StudioCommands.localPath(url.path)
            }
            switch kind {
            case "home":
                guard urls.isEmpty, project == nil, mode == nil else {
                    throw ExtensionPeerError.invalidRequest
                }; return .home
            case "image":
                guard urls.count == 1, project == nil, mode == nil else {
                    throw ExtensionPeerError.invalidRequest
                }; return .imageEditor(urls[0])
            case "pdf":
                guard urls.count == 1, project == nil, let mode else {
                    throw ExtensionPeerError.invalidRequest
                }; return .pdfEditor(urls[0], mode)
            case "video":
                guard mode == nil, project == nil || urls.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }; return .videoEditor(urls, project: project)
            default: throw ExtensionPeerError.invalidRequest
            }
        }
    }
}
