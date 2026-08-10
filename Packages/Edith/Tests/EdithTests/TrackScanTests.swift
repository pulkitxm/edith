import Foundation
import Testing

@testable import EdithKit

@Suite struct TrackScanTests {
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

    @Test func scanFindsNestedPlayableFilesOnly() {
        withLibrary(["top.mp3", "notes.txt", "Rock/b.m4a", "Rock/Live/a.mov", "Empty/.keep"]) {
            base in
            let paths = TrackMeta.tracks(under: "", base: base).map(\.relativePath)
            #expect(paths == ["Rock/b.m4a", "Rock/Live/a.mov", "top.mp3"])
        }
    }

    @Test func entriesListDirectChildren() {
        withLibrary(["top.mp3", "notes.txt", "Rock/b.m4a"]) { base in
            let entries = TrackMeta.entries(in: "", base: base)
            #expect(entries.folders.map(\.relativePath) == ["Rock"])
            #expect(entries.tracks.map(\.relativePath) == ["top.mp3"])
            #expect(TrackMeta.subfolders(in: "Rock", base: base).isEmpty)
        }
    }

    @Test func trackCountIsRecursiveAndCached() {
        withLibrary(["Rock/b.m4a", "Rock/Live/a.mov", "Rock/cover.jpg"]) { base in
            #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
            #expect(TrackMeta.trackCount(under: "", base: base) == 2)
            let extra = TrackMeta.url(for: "Rock/c.mp3", base: base)
            FileManager.default.createFile(atPath: extra.path, contents: Data())
            #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
            TrackMeta.invalidateCaches()
            #expect(TrackMeta.trackCount(under: "Rock", base: base) == 3)
        }
    }

    @Test func relativePathRoundTripsThroughURL() {
        withLibrary(["Rock/b.m4a"]) { base in
            let url = TrackMeta.url(for: "Rock/b.m4a", base: base)
            let root = TrackMeta.url(for: "", base: base)
            #expect(TrackMeta.relativePath(of: url, base: base) == "Rock/b.m4a")
            #expect(TrackMeta.relativePath(of: root, base: base) == "")
        }
    }
}
