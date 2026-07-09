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

    public var hue: Double {
        var h: UInt64 = 5381
        for b in url.lastPathComponent.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360) / 360
    }
}

@MainActor
public enum TrackMeta {
    public static let playableExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac", "mp4", "mov", "webm"]

    private static var artworkCache: [URL: NSImage] = [:]
    private static var durationCache: [URL: TimeInterval] = [:]

    public static func scanMusicFolder() -> [Track] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: Repo.musicDir, includingPropertiesForKeys: nil
            )) ?? []
        return
            files
            .filter { playableExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Track.init)
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
        if let hit = artworkCache[track.url] { return hit }
        let asset = AVURLAsset(url: track.url)
        if let metadata = try? await asset.load(.metadata) {
            for item in metadata where item.commonKey == .commonKeyArtwork {
                if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                    artworkCache[track.url] = image
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
                artworkCache[track.url] = image
                return image
            }
        }
        return nil
    }

    public static func artworkCached(for track: Track) -> NSImage? {
        artworkCache[track.url]
    }
}
