import EdithExtensionSupport
import AVFoundation
import AppKit
import CryptoKit

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

enum ThumbnailStore {
    static let maxPixels: CGFloat = 240

    private static let directory: URL = {
        let dir = ExtensionData.root.appendingPathComponent("thumbnails")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func key(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        let seed = "\(url.path)|\(stamp)|\(size)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func read(_ key: String) -> NSImage? {
        NSImage(contentsOf: directory.appendingPathComponent(key + ".jpg"))
    }

    static func store(_ image: NSImage, key: String) -> NSImage? {
        guard let data = jpeg(from: image) else { return nil }
        try? data.write(to: directory.appendingPathComponent(key + ".jpg"), options: .atomic)
        return NSImage(data: data)
    }

    private static func jpeg(from image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let longest = CGFloat(max(source.width, source.height))
        let scale = longest > maxPixels ? maxPixels / longest : 1
        let width = Int(CGFloat(source.width) * scale)
        let height = Int(CGFloat(source.height) * scale)
        guard width > 0, height > 0,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

public struct MusicSearchPage: Equatable, Sendable {
    public var tracks: [Track]
    public var folders: [MusicFolder]

    public init(tracks: [Track] = [], folders: [MusicFolder] = []) {
        self.tracks = tracks
        self.folders = folders
    }
}

struct MusicFileStamp: Codable, Equatable, Sendable {
    var identifier: String
    var modified: TimeInterval
}

struct MusicDurationRecord: Codable, Equatable, Sendable {
    var stamp: MusicFileStamp
    var seconds: TimeInterval
}

struct MusicCountRecord: Codable, Equatable, Sendable {
    var stamp: MusicFileStamp
    var count: Int
}

struct MusicArtworkRecord: Codable, Equatable, Sendable {
    var stamp: MusicFileStamp
    var key: String
}

struct MusicListingRecord: Codable, Equatable, Sendable {
    var folders: [String]
    var tracks: [String]
}

struct MusicLibraryIndexSnapshot: Codable, Equatable, Sendable {
    var durations: [String: MusicDurationRecord] = [:]
    var counts: [String: MusicCountRecord] = [:]
    var artwork: [String: MusicArtworkRecord] = [:]
    var listings: [String: MusicListingRecord] = [:]
}

public enum MusicLibraryIndex {
    public static let searchPageSize = 40
    private static let lock = NSLock()
    nonisolated(unsafe) static var fileURL: URL?
    nonisolated(unsafe) private static var memory: MusicLibraryIndexSnapshot?
    nonisolated(unsafe) static var directoryWalk: (@Sendable (URL) -> Void)?

    public static func activate(
        fileURL: URL = ExtensionData.root.appendingPathComponent("music-library-index.json")
    ) {
        lock.withLock {
            self.fileURL = fileURL
            memory = nil
        }
    }

    static func reset() {
        lock.withLock {
            fileURL = nil
            memory = nil
        }
        directoryWalk = nil
    }

    static func discardMemory() {
        lock.withLock { memory = nil }
    }

    static func stamp(of url: URL) -> MusicFileStamp {
        let values = try? url.resourceValues(forKeys: [
            .fileResourceIdentifierKey, .contentModificationDateKey,
        ])
        let identifier: String
        if let data = values?.fileResourceIdentifier as? Data {
            identifier = data.base64EncodedString()
        } else {
            identifier = url.standardizedFileURL.path
        }
        return MusicFileStamp(
            identifier: identifier,
            modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    public static func duration(for url: URL) -> TimeInterval? {
        let stamp = stamp(of: url)
        guard let record = snapshot().durations[stamp.identifier],
            record.stamp.modified == stamp.modified
        else { return nil }
        return record.seconds
    }

    static func store(duration seconds: TimeInterval, for url: URL) {
        let stamp = stamp(of: url)
        mutate {
            $0.durations[stamp.identifier] = MusicDurationRecord(stamp: stamp, seconds: seconds)
        }
    }

    static func count(of url: URL) -> Int? {
        let stamp = stamp(of: url)
        guard let record = snapshot().counts[stamp.identifier],
            record.stamp.modified == stamp.modified
        else { return nil }
        return record.count
    }

    static func store(count: Int, of url: URL) {
        let stamp = stamp(of: url)
        mutate { $0.counts[stamp.identifier] = MusicCountRecord(stamp: stamp, count: count) }
    }

    static func invalidateCounts() {
        mutate { $0.counts.removeAll() }
    }

    public static func artworkKey(for url: URL) -> String? {
        let stamp = stamp(of: url)
        guard let record = snapshot().artwork[stamp.identifier],
            record.stamp.modified == stamp.modified
        else { return nil }
        return record.key
    }

    static func store(artworkKey key: String, for url: URL) {
        let stamp = stamp(of: url)
        mutate { $0.artwork[stamp.identifier] = MusicArtworkRecord(stamp: stamp, key: key) }
    }

    public static func listing(_ path: String) -> MusicLibraryContentListing? {
        guard let record = snapshot().listings[path] else { return nil }
        let base = TrackMeta.basePath
        return MusicLibraryContentListing(
            folder: MusicFolder(url: TrackMeta.url(for: path, base: base), relativePath: path),
            folders: record.folders.map {
                MusicFolder(url: TrackMeta.url(for: $0, base: base), relativePath: $0)
            },
            tracks: record.tracks.map {
                Track(url: TrackMeta.url(for: $0, base: base), relativePath: $0)
            })
    }

    public static func storeListing(_ path: String, folders: [String], tracks: [String]) {
        mutate {
            $0.listings[path] = MusicListingRecord(folders: folders, tracks: tracks)
        }
    }

    private static func snapshot() -> MusicLibraryIndexSnapshot {
        lock.withLock {
            if let memory { return memory }
            let loaded = loadFromDisk()
            memory = loaded
            return loaded
        }
    }

    private static func loadFromDisk() -> MusicLibraryIndexSnapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(MusicLibraryIndexSnapshot.self, from: data)
        else { return MusicLibraryIndexSnapshot() }
        return decoded
    }

    private static func mutate(_ body: (inout MusicLibraryIndexSnapshot) -> Void) {
        lock.withLock {
            var current = memory ?? loadFromDisk()
            body(&current)
            memory = current
            guard let fileURL, let data = try? JSONEncoder().encode(current) else { return }
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

actor LoadGate {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            active -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

public enum TrackMeta {
    public static let playableExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac", "mp4", "mov"]

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedBasePath: String?
    nonisolated(unsafe) private static var trackCounts: [URL: Int] = [:]
    nonisolated(unsafe) private static var durationCache: [URL: TimeInterval] = [:]
    nonisolated(unsafe) private static var artworkMisses: Set<URL> = []
    private static let gate = LoadGate(limit: 3)
    nonisolated(unsafe) static var loadAssetDuration: @Sendable (URL) async -> TimeInterval? = {
        url in
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration), time.seconds.isFinite else { return nil }
        return time.seconds
    }
    private static let artworkCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 100
        return cache
    }()

    static func shutdown() {
        cacheLock.withLock {
            cachedBasePath = nil
            trackCounts.removeAll()
            durationCache.removeAll()
            artworkMisses.removeAll()
        }
        artworkCache.removeAllObjects()
    }

    public static func invalidateCaches() {
        cacheLock.withLock {
            cachedBasePath = nil
            trackCounts.removeAll()
        }
        MusicLibraryIndex.invalidateCounts()
    }

    static func discardTransientDurations() {
        cacheLock.withLock { durationCache.removeAll() }
    }

    static func discardMemoryCounts() {
        cacheLock.withLock { trackCounts.removeAll() }
    }

    static var basePath: String {
        cacheLock.withLock {
            if let cachedBasePath { return cachedBasePath }
            let base = MusicStorage.musicDir.standardizedFileURL.path
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
        if let indexed = MusicLibraryIndex.count(of: root) {
            cacheLock.withLock { trackCounts[root] = indexed }
            return indexed
        }
        var count = 0
        forEachPlayableFile(in: root) { _ in count += 1 }
        cacheLock.withLock { trackCounts[root] = count }
        MusicLibraryIndex.store(count: count, of: root)
        return count
    }

    private static func forEachPlayableFile(in root: URL, _ body: (URL) -> Void) {
        MusicLibraryIndex.directoryWalk?(root)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }
        for case let file as URL in enumerator {
            guard !Task.isCancelled else { return }
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

    public static func folders(under relativePath: String) -> [MusicFolder] {
        folders(under: relativePath, base: basePath)
    }

    static func folders(under relativePath: String, base: String) -> [MusicFolder] {
        let root = url(for: relativePath, base: base)
        MusicLibraryIndex.directoryWalk?(root)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var result: [MusicFolder] = []
        for case let item as URL in enumerator where isDirectory(item) {
            result.append(
                MusicFolder(url: item, relativePath: Self.relativePath(of: item, base: base)))
        }
        result.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return result
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
        let indexed = await Task.detached { MusicLibraryIndex.duration(for: track.url) }.value
        if let indexed {
            cacheLock.withLock { durationCache[track.url] = indexed }
            return indexed
        }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        guard let seconds = await loadAssetDuration(track.url) else { return nil }
        cacheLock.withLock { durationCache[track.url] = seconds }
        await Task.detached { MusicLibraryIndex.store(duration: seconds, for: track.url) }.value
        return seconds
    }

    public static func durationLabel(for track: Track) async -> String? {
        guard let seconds = await duration(for: track), seconds.isFinite, seconds > 0 else {
            return nil
        }
        return timeLabel(seconds)
    }

    public static func cachedDurationLabel(for track: Track) -> String? {
        guard let seconds = cacheLock.withLock({ durationCache[track.url] }), seconds > 0 else {
            return nil
        }
        return timeLabel(seconds)
    }

    public static func cachedTrackCount(under relativePath: String) -> Int? {
        let root = url(for: relativePath)
        return cacheLock.withLock { trackCounts[root] }
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
        let indexedKey = await Task.detached { MusicLibraryIndex.artworkKey(for: track.url) }.value
        let key = indexedKey ?? ThumbnailStore.key(for: track.url)
        if let stored = ThumbnailStore.read(key) {
            artworkCache.setObject(stored, forKey: track.url as NSURL)
            if indexedKey == nil {
                await Task.detached {
                    MusicLibraryIndex.store(artworkKey: key, for: track.url)
                }.value
            }
            return stored
        }
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard !Task.isCancelled else { return nil }
        if let image = await loadArtwork(for: track.url) {
            let thumbnail = ThumbnailStore.store(image, key: key) ?? image
            artworkCache.setObject(thumbnail, forKey: track.url as NSURL)
            await Task.detached { MusicLibraryIndex.store(artworkKey: key, for: track.url) }.value
            return thumbnail
        }
        cacheLock.withLock { _ = artworkMisses.insert(track.url) }
        return nil
    }

    public static func searchPage(
        under relativePath: String, base: String, query: String, skip: Int, limit: Int?
    ) -> MusicSearchPage {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return MusicSearchPage() }
        let root = url(for: relativePath, base: base)
        MusicLibraryIndex.directoryWalk?(root)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return MusicSearchPage() }
        var tracks: [Track] = []
        var folders: [MusicFolder] = []
        var matched = 0
        for case let item as URL in enumerator {
            if Task.isCancelled { break }
            if isDirectory(item) {
                MusicLibraryIndex.directoryWalk?(item)
                let folder = MusicFolder(
                    url: item, relativePath: Self.relativePath(of: item, base: base))
                guard folder.name.localizedCaseInsensitiveContains(needle) else { continue }
                matched += 1
                if matched <= skip { continue }
                folders.append(folder)
            } else if playableExtensions.contains(item.pathExtension.lowercased()),
                (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            {
                let track = Track(url: item, relativePath: Self.relativePath(of: item, base: base))
                guard track.title.localizedCaseInsensitiveContains(needle) else { continue }
                matched += 1
                if matched <= skip { continue }
                tracks.append(track)
            } else {
                continue
            }
            if let limit, matched - skip >= limit { break }
        }
        folders.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        tracks.sort {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
        return MusicSearchPage(tracks: tracks, folders: folders)
    }

    public static func searchPage(under relativePath: String, query: String, skip: Int, limit: Int?)
        -> MusicSearchPage
    {
        searchPage(under: relativePath, base: basePath, query: query, skip: skip, limit: limit)
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
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    public static func artworkCached(for track: Track) -> NSImage? {
        artworkCache.object(forKey: track.url as NSURL)
    }
}
