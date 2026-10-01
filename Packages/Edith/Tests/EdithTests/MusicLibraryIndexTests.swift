import Foundation
import Testing

@testable import EdithKit

@Suite struct MusicLibraryIndexTests {
    @Test func openingAFolderDoesNotEnumerateSiblingTrees() {
        withLibrary(["A/one.mp3", "B/two.mp3", "B/nested/three.flac"]) { base in
            var walked: [String] = []
            MusicLibraryIndex.directoryWalk = { url in
                walked.append(TrackMeta.relativePath(of: url, base: base))
            }
            defer { MusicLibraryIndex.directoryWalk = nil }
            let listing = MusicLibraryContentOperationExecution.openFolder("A") {
                TrackMeta.entries(in: $0, base: base)
            }
            #expect(listing.tracks.map(\.relativePath) == ["A/one.mp3"])
            #expect(walked.isEmpty)
            let page = TrackMeta.searchPage(
                under: "A", base: base, query: "one", skip: 0,
                limit: MusicLibraryIndex.searchPageSize)
            #expect(page.tracks.map(\.relativePath) == ["A/one.mp3"])
            #expect(walked.allSatisfy { $0 == "A" || $0.hasPrefix("A/") })
        }
    }

    @Test func secondAppearanceReadsDurationFromTheIndex() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-music-duration-\(UUID().uuidString)")
        let file = root.appendingPathComponent("one.mp3")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data("audio".utf8))
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("index.json")
        MusicLibraryIndex.activate(fileURL: index)
        let previous = TrackMeta.loadAssetDuration
        let opens = OpenCount()
        TrackMeta.loadAssetDuration = { _ in
            opens.add()
            return 83
        }
        defer {
            TrackMeta.loadAssetDuration = previous
            TrackMeta.discardTransientDurations()
            MusicLibraryIndex.reset()
        }
        let track = Track(url: file, relativePath: "one.mp3")
        let first = await TrackMeta.durationLabel(for: track)
        TrackMeta.discardTransientDurations()
        MusicLibraryIndex.discardMemory()
        let second = await TrackMeta.durationLabel(for: track)
        #expect(first == "1:23")
        #expect(second == "1:23")
        #expect(opens.value == 1)
    }

    @Test func indexedTrackCountDoesNotWalkAgain() {
        withLibrary(["Rock/a.mp3", "Rock/Live/b.m4a"]) { base in
            let index = URL(fileURLWithPath: base).appendingPathComponent("index.json")
            MusicLibraryIndex.activate(fileURL: index)
            defer {
                MusicLibraryIndex.reset()
                TrackMeta.invalidateCaches()
            }
            #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
            TrackMeta.discardMemoryCounts()
            MusicLibraryIndex.discardMemory()
            var walks = 0
            MusicLibraryIndex.directoryWalk = { _ in walks += 1 }
            #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
            #expect(walks == 0)
        }
    }

    private final class OpenCount: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        func add() {
            lock.withLock { stored += 1 }
        }

        var value: Int {
            lock.withLock { stored }
        }
    }

    private func withLibrary(_ files: [String], _ body: (String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-music-\(UUID().uuidString)")
        for file in files {
            let url = root.appendingPathComponent(file)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        defer { try? FileManager.default.removeItem(at: root) }
        body(root.standardizedFileURL.path)
    }
}
