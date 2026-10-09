import CryptoKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import Foundation

@MainActor
enum StudioSurface {
    static func identifier(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func snapshot(
        _ model: StudioModel, files: [StudioMediaItem], projects: [VideoProject.Listing],
        tile: SurfaceTile, now: Date = Date()
    ) -> SurfaceSnapshot {
        let selectedFiles = files.filter {
            tile.sourceIDs?.contains($0.url.studioKind.rawValue) ?? true
        }
        let showsFiles = tile.contentKinds?.contains("files") ?? true
        let showsProjects =
            (tile.contentKinds?.contains("projects") ?? true)
            && (tile.sourceIDs?.contains("video") ?? true)
        let showsJobs = tile.contentKinds?.contains("jobs") ?? true
        var rows: [SurfaceDataRow] = []
        var metrics: [SurfaceMetric] = []
        if showsFiles {
            metrics.append(.init("files", "Files", selectedFiles.count.description))
            rows += selectedFiles.prefix(100).map { file in
                let id = identifier(file.url)
                return .init(
                    id, sourceID: file.url.studioKind.rawValue,
                    title: bounded(file.name), detail: file.url.studioKind.title,
                    icon: file.url.studioKind.symbolName,
                    actions: [.init("open:" + id, "Open in Studio", "arrow.up.right")])
            }
        }
        if showsProjects {
            metrics.append(.init("projects", "Projects", projects.count.description))
            rows += projects.prefix(100).map { project in
                let id = identifier(project.url)
                return .init(
                    "project:" + id, sourceID: "video", title: bounded(project.title),
                    detail: "Video project", icon: "film.stack",
                    actions: [.init("project:" + id, "Open project", "arrow.up.right")])
            }
        }
        let selectedJobs = model.jobs.filter {
            tile.sourceIDs?.contains($0.tool.family.rawValue) ?? true
        }
        if showsJobs {
            metrics.append(
                .init("running", "Running", selectedJobs.filter(\.isRunning).count.description))
            rows += selectedJobs.prefix(100).map { job in
                .init(
                    "job:" + job.id.uuidString, sourceID: job.tool.family.rawValue,
                    title: bounded(job.tool.title),
                    detail: job.status.map { bounded($0) } ?? "",
                    value: job.isRunning ? "Running" : job.progress == 1 ? "Finished" : "Ready",
                    icon: job.tool.symbolName, progress: job.progress,
                    actions: job.isRunning
                        ? [.init("cancel:" + job.id.uuidString, "Cancel", "stop.fill")] : [])
            }
        }
        return .init(
            providerID: "studio", metrics: metrics, rows: Array(rows.prefix(100)),
            sources: StudioKind.allCases.map { .init($0.rawValue, $0.title) }, updatedAt: now)
    }

    static func perform(_ action: String, model: StudioModel) throws {
        if action.hasPrefix("open:"),
            let file = try StudioMediaLibrary.list(defaults: model.defaults).first(where: {
                "open:" + identifier($0.url) == action
            })
        {
            ExtensionPresentation.showWindow()
            model.add([file.url])
            let toolID: String?
            switch file.url.studioKind {
            case .image: toolID = "image.edit"
            case .pdf: toolID = "pdf.edit"
            case .video: toolID = "video.edit"
            default: toolID = nil
            }
            if let toolID {
                model.open(toolID: toolID, with: [file.url])
            } else {
                model.tab = .files; model.route = .home; model.selection = [file.url]
            }
        } else if action.hasPrefix("project:"),
            let project = VideoProject.listProjects().first(where: {
                "project:" + identifier($0.url) == action
            })
        {
            ExtensionPresentation.showWindow()
            model.openVideoProject(project.url)
        } else if action.hasPrefix("cancel:"),
            let job = model.jobs.first(where: {
                "cancel:" + $0.id.uuidString == action && $0.isRunning
            })
        {
            job.cancel()
        } else {
            throw ExtensionPeerError.invalidRequest
        }
    }
    private static func bounded(_ value: String) -> String {
        String(
            decoding: value.replacingOccurrences(of: "\u{0}", with: "").utf8.prefix(1021),
            as: UTF8.self)
    }

}
