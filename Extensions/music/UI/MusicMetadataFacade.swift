import AppKit
import EdithExtensionSupport
import Foundation

struct EmbeddedTrack: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    let title: String
    var id: URL { url }
    var isVideo: Bool {
        ["mp4", "m4v", "mov", "webm", "mkv"].contains(url.pathExtension.lowercased())
    }
    var hue: Double {
        var hash: UInt64 = 5381
        for byte in url.lastPathComponent.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return Double(hash % 360) / 360
    }
    init(url: URL, relativePath: String) {
        self.url = url; self.relativePath = relativePath
        title =
            url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct EmbeddedMusicFolder: Identifiable, Equatable, Sendable {
    let url: URL
    let relativePath: String
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor enum EmbeddedTrackMeta {
    static var root = URL(fileURLWithPath: "/")
    private static var images: [String: NSImage] = [:]
    private static var durations: [String: String] = [:]
    private static var counts: [String: Int] = [:]
    static func clear() { images.removeAll(); durations.removeAll(); counts.removeAll() }
    static func url(for path: String) -> URL { root.appendingPathComponent(path) }
    static func artworkCached(for track: EmbeddedTrack) -> NSImage? { images[track.relativePath] }
    static func cachedDurationLabel(for track: EmbeddedTrack) -> String? {
        durations[track.relativePath]
    }
    static func cachedTrackCount(under path: String) -> Int? { counts[path] }
    static func artwork(for track: EmbeddedTrack) async -> NSImage? {
        if let cached = images[track.relativePath] { return cached }
        guard
            let data = try? await EmbeddedMusicRemote.shared.request(
                "music.ui.artwork", action: .init(kind: .startTrack, path: track.relativePath)),
            let bytes = try? JSONDecoder().decode(Data.self, from: data), bytes.count <= 131_072,
            let image = NSImage(data: bytes), !Task.isCancelled
        else { return nil }
        images[track.relativePath] = image
        return image
    }
    static func durationLabel(for track: EmbeddedTrack) async -> String? {
        guard
            let data = try? await EmbeddedMusicRemote.shared.request(
                "music.ui.duration", action: .init(kind: .startTrack, path: track.relativePath)),
            let label = try? JSONDecoder().decode(String.self, from: data), !Task.isCancelled
        else { return nil }
        durations[track.relativePath] = label
        return label
    }
    static func remoteTrackCount(under path: String) async -> Int {
        guard
            let data = try? await EmbeddedMusicRemote.shared.request(
                "music.ui.count", action: .init(kind: .startFolder, path: path)),
            let count = try? JSONDecoder().decode(Int.self, from: data), !Task.isCancelled
        else { return counts[path] ?? 0 }
        counts[path] = count
        return count
    }
    static func timeLabel(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum EmbeddedMusicStorage {
    static let musicFolderStaleKey = "musicFolderStale"
}

@MainActor func remoteReveal(_ track: EmbeddedTrack) {
    EmbeddedMusicRemote.shared.send(.reveal, path: track.relativePath)
}
