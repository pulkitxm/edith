import AVFoundation
import AppKit

public struct Track: Identifiable, Equatable, Sendable {
    public let url: URL
    public var id: URL { url }

    public init(url: URL) {
        self.url = url
    }

    public var title: String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    public var relativePath: String { TrackMeta.relativePath(of: url) }

    public var hue: Double {
        var h: UInt64 = 5381
        for b in url.lastPathComponent.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }
}

public struct MusicFolder: Identifiable, Equatable, Sendable {
    public let url: URL
    public let trackCount: Int
    public var id: URL { url }

    public init(url: URL, trackCount: Int) {
        self.url = url
        self.trackCount = trackCount
    }

    public var name: String { url.lastPathComponent }
    public var relativePath: String { TrackMeta.relativePath(of: url) }
}

@MainActor
public enum TrackMeta {
    public static let playableExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac", "mp4", "mov"]

    private static let artworkCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 100
        return cache
    }()
    private static var durationCache: [URL: TimeInterval] = [:]

    nonisolated public static func relativePath(of url: URL) -> String {
        let base = Repo.musicDir.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == base { return "" }
        if path.hasPrefix(base + "/") { return String(path.dropFirst(base.count + 1)) }
        return url.lastPathComponent
    }

    public static func scanMusicFolder() -> [Track] {
        tracks(under: "")
    }

    public static func directory(for relativePath: String) -> URL {
        relativePath.isEmpty
            ? Repo.musicDir : Repo.musicDir.appendingPathComponent(relativePath)
    }

    public static func tracks(under relativePath: String) -> [Track] {
        let root = directory(for: relativePath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var result: [Track] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir, playableExtensions.contains(url.pathExtension.lowercased()) {
                result.append(Track(url: url))
            }
        }
        return result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    public static func entries(in relativePath: String) -> (
        folders: [MusicFolder], tracks: [Track]
    ) {
        let dir = directory(for: relativePath)
        let items =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        var folders: [MusicFolder] = []
        var tracks: [Track] = []
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                folders.append(
                    MusicFolder(
                        url: item,
                        trackCount: Self.tracks(
                            under: relativePathJoin(relativePath, item.lastPathComponent)
                        ).count))
            } else if playableExtensions.contains(item.pathExtension.lowercased()) {
                tracks.append(Track(url: item))
            }
        }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        tracks.sort {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        return (folders, tracks)
    }

    private static func relativePathJoin(_ base: String, _ component: String) -> String {
        base.isEmpty ? component : base + "/" + component
    }

    public static func duration(for track: Track) async -> TimeInterval? {
        if let hit = durationCache[track.url] { return hit }
        let asset = AVURLAsset(url: track.url)
        guard let time = try? await asset.load(.duration) else { return nil }
        durationCache[track.url] = time.seconds
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
        let asset = AVURLAsset(url: track.url)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                    artworkCache.setObject(image, forKey: track.url as NSURL)
                    return image
                }
            }
        }
        if let videoTracks = try? await asset.loadTracks(withMediaType: .video),
            !videoTracks.isEmpty
        {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 120)
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let at = CMTime(seconds: max(1, seconds * 0.2), preferredTimescale: 600)
            if let cg = try? await generator.image(at: at).image {
                let image = NSImage(cgImage: cg, size: .zero)
                artworkCache.setObject(image, forKey: track.url as NSURL)
                return image
            }
        }
        return nil
    }

    public static func artworkCached(for track: Track) -> NSImage? {
        artworkCache.object(forKey: track.url as NSURL)
    }
}
