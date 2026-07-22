import AVFoundation
import AppKit

public struct Track: Identifiable, Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public let title: String
    public var id: URL { url }

    public init(url: URL) {
        self.init(url: url, relativePath: TrackMeta.relativePath(of: url))
    }

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
        self.title =
            url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    public static func == (lhs: Track, rhs: Track) -> Bool { lhs.url == rhs.url }

    public var hue: Double {
        var h: UInt64 = 5381
        for b in url.lastPathComponent.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }
}

public struct MusicFolder: Identifiable, Equatable, Sendable {
    public let url: URL
    public let relativePath: String
    public var id: URL { url }

    public init(url: URL) {
        self.init(url: url, relativePath: TrackMeta.relativePath(of: url))
    }

    public init(url: URL, relativePath: String) {
        self.url = url
        self.relativePath = relativePath
    }

    public static func == (lhs: MusicFolder, rhs: MusicFolder) -> Bool { lhs.url == rhs.url }

    public var name: String { url.lastPathComponent }
}

public enum TrackMeta {
    public static let playableExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac", "mp4", "mov"]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedBasePath: String?
    nonisolated(unsafe) private static var trackCounts: [URL: Int] = [:]
    nonisolated(unsafe) private static var durationCache: [URL: TimeInterval] = [:]
    nonisolated(unsafe) private static var artworkMisses: Set<URL> = []
    private static let artworkCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    public static func invalidateCaches() {
        cacheLock.withLock {
            cachedBasePath = nil
            trackCounts.removeAll()
        }
    }

    static var basePath: String {
        cacheLock.withLock {
            if let cachedBasePath { return cachedBasePath }
            let base = Repo.musicDir.standardizedFileURL.path
            cachedBasePath = base
            return base
        }
    }

    public static func url(for relativePath: String) -> URL {
        url(for: relativePath, base: basePath)
    }

    static func url(for relativePath: String, base: String) -> URL {
        let root = URL(fileURLWithPath: base)
        return relativePath.isEmpty ? root : root.appendingPathComponent(relativePath)
    }

    public static func relativePath(of url: URL) -> String {
        relativePath(of: url, base: basePath)
    }

    static func relativePath(of url: URL, base: String) -> String {
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return url.lastPathComponent
    }

    public static func scanMusicFolder() -> [Track] {
        tracks(under: "")
    }

    public static func tracks(under relativePath: String) -> [Track] {
        tracks(under: relativePath, base: basePath)
    }

    static func tracks(under relativePath: String, base: String) -> [Track] {
        var result: [Track] = []
        forEachPlayableFile(in: url(for: relativePath, base: base)) { file in
            result.append(Track(url: file, relativePath: Self.relativePath(of: file, base: base)))
        }
        result.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return result
    }

    public static func trackCount(under relativePath: String) -> Int {
        trackCount(under: relativePath, base: basePath)
    }

    static func trackCount(under relativePath: String, base: String) -> Int {
        let root = url(for: relativePath, base: base)
        if let hit = cacheLock.withLock({ trackCounts[root] }) { return hit }
        var count = 0
        forEachPlayableFile(in: root) { _ in count += 1 }
        cacheLock.withLock { trackCounts[root] = count }
        return count
    }

    private static func forEachPlayableFile(in root: URL, _ body: (URL) -> Void) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let file as URL in enumerator {
            guard playableExtensions.contains(file.pathExtension.lowercased()),
                (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            body(file)
        }
    }

    public static func entries(in relativePath: String) -> (
        folders: [MusicFolder], tracks: [Track]
    ) {
        entries(in: relativePath, base: basePath)
    }

    static func entries(in relativePath: String, base: String) -> (
        folders: [MusicFolder], tracks: [Track]
    ) {
        var folders: [MusicFolder] = []
        var tracks: [Track] = []
        for item in children(of: url(for: relativePath, base: base)) {
            if isDirectory(item) {
                folders.append(
                    MusicFolder(url: item, relativePath: Self.relativePath(of: item, base: base)))
            } else if playableExtensions.contains(item.pathExtension.lowercased()) {
                tracks.append(
                    Track(url: item, relativePath: Self.relativePath(of: item, base: base)))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        tracks.sort {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        return (folders, tracks)
    }

    public static func subfolders(in relativePath: String) -> [MusicFolder] {
        subfolders(in: relativePath, base: basePath)
    }

    static func subfolders(in relativePath: String, base: String) -> [MusicFolder] {
        children(of: url(for: relativePath, base: base))
            .filter(isDirectory)
            .map { MusicFolder(url: $0, relativePath: Self.relativePath(of: $0, base: base)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func children(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    public static func duration(for track: Track) async -> TimeInterval? {
        if let hit = cacheLock.withLock({ durationCache[track.url] }) { return hit }
        let asset = AVURLAsset(url: track.url)
        guard let time = try? await asset.load(.duration), time.seconds.isFinite else { return nil }
        cacheLock.withLock { durationCache[track.url] = time.seconds }
        return time.seconds
    }

    public static func durationLabel(for track: Track) async -> String? {
        guard let seconds = await duration(for: track), seconds.isFinite, seconds > 0 else {
            return nil
        }
        return timeLabel(seconds)
    }

    public static func timeLabel(_ t: TimeInterval) -> String {
        guard t.isFinite, t > 0 else { return "0:00" }
        let s = Int(t)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    public static func artwork(for track: Track) async -> NSImage? {
        if let hit = artworkCache.object(forKey: track.url as NSURL) { return hit }
        if cacheLock.withLock({ artworkMisses.contains(track.url) }) { return nil }
        if let image = await loadArtwork(for: track.url) {
            artworkCache.setObject(image, forKey: track.url as NSURL)
            return image
        }
        cacheLock.withLock { _ = artworkMisses.insert(track.url) }
        return nil
    }

    private static func loadArtwork(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                    return image
                }
            }
        }
        guard !Task.isCancelled,
            let videoTracks = try? await asset.loadTracks(withMediaType: .video),
            !videoTracks.isEmpty, !Task.isCancelled
        else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let at = CMTime(seconds: 3, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: at).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    public static func artworkCached(for track: Track) -> NSImage? {
        artworkCache.object(forKey: track.url as NSURL)
    }
}
