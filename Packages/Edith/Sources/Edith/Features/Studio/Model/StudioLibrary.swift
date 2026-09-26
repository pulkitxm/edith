import AVFoundation
import AppKit
import EdithKit
import EdithStudio
import Foundation
import PDFKit
import QuickLookThumbnailing

struct StudioFileItem: Identifiable, Hashable, Codable, Sendable {
    let url: URL
    var addedAt: Date

    var id: URL { url }
    var kind: StudioKind { url.studioKind }
    var name: String { url.lastPathComponent }
}

struct StudioFileFacts: Equatable, Sendable {
    var bytes: Int64
    var detail: String?
    var exists: Bool

    static let missing = StudioFileFacts(bytes: 0, detail: nil, exists: false)
}

struct StudioRecentRun: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var toolID: String
    var title: String
    var outputs: [URL]
    var date: Date
}

enum StudioDestinationMode: String, CaseIterable, Sendable {
    case original
    case downloads
    case folder

    var title: String {
        switch self {
        case .original: "Next to the original"
        case .downloads: "Downloads"
        case .folder: "A folder"
        }
    }
}

enum StudioLibraryStore {
    static let recentLimit = 40

    static func loadFiles(from defaults: UserDefaults) -> [StudioFileItem] {
        guard let data = defaults.data(forKey: AppStorageKeys.Studio.library),
            let items = try? JSONDecoder().decode([StudioFileItem].self, from: data)
        else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    static func saveFiles(_ items: [StudioFileItem], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: AppStorageKeys.Studio.library)
    }

    static var recentURL: URL { DataRoot.studio.appendingPathComponent("recent.json") }

    static var inbox: URL { DataRoot.studio.appendingPathComponent("inbox", isDirectory: true) }

    static var signatures: URL {
        DataRoot.studio.appendingPathComponent("signatures", isDirectory: true)
    }

    static func loadRecent() -> [StudioRecentRun] {
        guard let data = try? Data(contentsOf: recentURL),
            let runs = try? JSONDecoder().decode([StudioRecentRun].self, from: data)
        else { return [] }
        return runs
    }

    static func saveRecent(_ runs: [StudioRecentRun]) {
        try? FileManager.default.createDirectory(
            at: DataRoot.studio, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(Array(runs.prefix(recentLimit))) else { return }
        try? data.write(to: recentURL, options: .atomic)
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let manager = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                result.append(url.standardizedFileURL)
                continue
            }
            let enumerator = manager.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let item = enumerator?.nextObject() as? URL, result.count < 500 {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true { result.append(item.standardizedFileURL) }
            }
        }
        return result
    }

    static func saveToInbox(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let url = StudioNaming.unique(inbox.appendingPathComponent(name))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func pasteboardFiles(_ pasteboard: NSPasteboard) throws -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            return urls
        }
        let stamp = DateFormatter.localizedString(
            from: Date(), dateStyle: .short, timeStyle: .medium
        )
        .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if let pdf = pasteboard.data(forType: .pdf) {
            return [try saveToInbox(pdf, name: "Pasted \(stamp).pdf")]
        }
        if let png = pasteboard.data(forType: .png) {
            return [try saveToInbox(png, name: "Pasted \(stamp).png")]
        }
        if let tiff = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff),
            let png = image.representation(using: .png, properties: [:])
        {
            return [try saveToInbox(png, name: "Pasted \(stamp).png")]
        }
        return []
    }
}

enum StudioLibraryQuery {
    static func visible(_ files: [StudioFileItem], kind: StudioKind?) -> [StudioFileItem] {
        guard let kind else { return files }
        return files.filter { $0.kind == kind }
    }

    static func kinds(in files: [StudioFileItem]) -> [StudioKind] {
        let present = Set(files.map(\.kind))
        return StudioKind.allCases.filter(present.contains)
    }

    static func selected(_ files: [StudioFileItem], in selection: Set<URL>) -> [URL] {
        files.compactMap { selection.contains($0.url) ? $0.url : nil }
    }

    static func urls(_ files: [StudioFileItem]) -> Set<URL> {
        Set(files.map(\.url))
    }

    static func newItems(_ urls: [URL], existing: [StudioFileItem]) -> [StudioFileItem] {
        var known = Set(existing.map(\.url))
        var added: [StudioFileItem] = []
        for url in urls where known.insert(url).inserted {
            added.append(StudioFileItem(url: url, addedAt: Date()))
        }
        return added
    }

    static func accepted(_ urls: [URL], by tool: StudioTool) -> [URL] {
        urls.filter(tool.accepts)
    }

    static func outputURLs(_ result: StudioRunResult) -> [URL] {
        result.outputs.map(\.url)
    }

    static func count(_ urls: [URL], kind: StudioKind) -> Int {
        urls.filter { $0.studioKind == kind }.count
    }
}

enum StudioThumbnailFallback {
    static func handles(_ kind: StudioKind) -> Bool {
        kind == .image || kind == .pdf || kind == .video
    }

    static func render(_ url: URL, pixels: Int) async -> StudioImageSource? {
        switch url.studioKind {
        case .image:
            return (try? StudioImageIO.load(url, maxPixelSize: pixels)).map(StudioImageSource.init)
        case .pdf:
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let size = StudioPDF.displaySize(page)
            let dpi = 72 * Double(pixels) / max(size.width, size.height, 1)
            return (try? StudioPDF.render(page, dpi: dpi)).map(StudioImageSource.init)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixels, height: pixels)
            let time = CMTime(seconds: 0.5, preferredTimescale: 600)
            return (try? await generator.image(at: time).image).map(StudioImageSource.init)
        default:
            return nil
        }
    }
}

enum StudioInspector {
    static func facts(for url: URL) async -> StudioFileFacts {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return .missing }
        let bytes = StudioRunner.fileSize(url, fileManager: manager)
        return StudioFileFacts(bytes: bytes, detail: await detail(for: url), exists: true)
    }

    static func detail(for url: URL) async -> String? {
        switch url.studioKind {
        case .image:
            guard let info = StudioImageIO.info(url) else { return nil }
            let frames = info.frames > 1 ? " · \(info.frames) frames" : ""
            return "\(info.width)×\(info.height)" + frames
        case .pdf:
            guard let pages = StudioPDF.pageCount(url) else { return "Locked or damaged" }
            return pages == 1 ? "1 page" : "\(pages) pages"
        case .video, .audio:
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            var parts: [String] = []
            if seconds.isFinite, seconds > 0 { parts.append(StudioTime.format(seconds)) }
            if url.studioKind == .video,
                let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize)
            {
                parts.append("\(Int(abs(size.width)))×\(Int(abs(size.height)))")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        default:
            return url.pathExtension.uppercased()
        }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
final class StudioThumbnails {
    static let shared = StudioThumbnails()

    private let cache = NSCache<NSString, NSImage>()

    func cached(_ url: URL, side: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, side))
    }

    func thumbnail(for url: URL, side: CGFloat) async -> NSImage? {
        if let hit = cached(url, side: side) { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side), scale: scale,
            representationTypes: .thumbnail)
        let pixels = Int(side * scale)
        var image: NSImage?
        if StudioThumbnailFallback.handles(url.studioKind) {
            let rendered = await Task.detached(priority: .utility) {
                await StudioThumbnailFallback.render(url, pixels: pixels)
            }.value
            image = rendered.map { NSImage(cgImage: $0.image, size: .zero) }
        }
        if image == nil {
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                .nsImage
        }
        guard let image else { return nil }
        cache.setObject(image, forKey: key(url, side))
        return image
    }

    func forget(_ url: URL) {
        for side in [48.0, 64, 96, 120, 160, 220, 320] {
            cache.removeObject(forKey: key(url, side))
        }
    }

    private func key(_ url: URL, _ side: CGFloat) -> NSString {
        "\(url.path)#\(Int(side))" as NSString
    }
}
