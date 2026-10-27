import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

extension MusicExtensionTests {
    @Suite struct MusicLibraryIndexTests {
        @Test func openingAFolderDoesNotEnumerateSiblingTrees() {
            withLibrary(["A/one.mp3", "B/two.mp3", "B/nested/three.flac"]) { base in
                let walked = MusicCallbackRecorder<String>()
                let priorWalk = MusicLibraryIndex.directoryWalk
                MusicLibraryIndex.directoryWalk = { url in
                    walked.append(TrackMeta.relativePath(of: url, base: base))
                }
                defer { MusicLibraryIndex.directoryWalk = priorWalk }
                let listing = MusicLibraryContentOperationExecution.openFolder("A") {
                    TrackMeta.entries(in: $0, base: base)
                }
                #expect(listing.tracks.map(\.relativePath) == ["A/one.mp3"])
                #expect(walked.values.isEmpty)
                let page = TrackMeta.searchPage(
                    under: "A", base: base, query: "one", skip: 0,
                    limit: MusicLibraryIndex.searchPageSize)
                #expect(page.tracks.map(\.relativePath) == ["A/one.mp3"])
                #expect(walked.values.allSatisfy { $0 == "A" || $0.hasPrefix("A/") })
            }
        }

        @Test func storingAnUnchangedListingDoesNotRewriteTheIndexFile() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("edith-music-index-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                MusicLibraryIndex.reset()
                try? FileManager.default.removeItem(at: root)
            }
            let index = root.appendingPathComponent("index.json")
            MusicLibraryIndex.activate(fileURL: index)
            MusicLibraryIndex.storeListing("A", folders: ["A/B"], tracks: ["A/one.mp3"])
            let first = try FileManager.default.attributesOfItem(atPath: index.path)
            let identifier = first[.systemFileNumber] as? Int
            MusicLibraryIndex.storeListing("A", folders: ["A/B"], tracks: ["A/one.mp3"])
            let second = try FileManager.default.attributesOfItem(atPath: index.path)
            #expect(second[.systemFileNumber] as? Int == identifier)
            MusicLibraryIndex.storeListing("A", folders: [], tracks: ["A/one.mp3"])
            let third = try FileManager.default.attributesOfItem(atPath: index.path)
            #expect(third[.systemFileNumber] as? Int != identifier)
        }

        @Test func secondAppearanceReadsDurationFromTheIndex() async {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("edith-music-duration-\(UUID().uuidString)")
            let file = root.appendingPathComponent("one.mp3")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: file.path, contents: Data("audio".utf8))
            defer { try? FileManager.default.removeItem(at: root) }
            let index = root.appendingPathComponent("index.json")
            let priorWalk = MusicLibraryIndex.directoryWalk
            MusicLibraryIndex.activate(fileURL: index)
            let previous = TrackMeta.loadAssetDuration
            let opens = MusicCallbackRecorder<Int>()
            TrackMeta.loadAssetDuration = { _ in
                opens.append(1)
                return 83
            }
            defer {
                TrackMeta.loadAssetDuration = previous
                TrackMeta.discardTransientDurations()
                MusicLibraryIndex.reset()
                MusicLibraryIndex.directoryWalk = priorWalk
            }
            let track = Track(url: file, relativePath: "one.mp3")
            let first = await TrackMeta.durationLabel(for: track)
            TrackMeta.discardTransientDurations()
            MusicLibraryIndex.discardMemory()
            let second = await TrackMeta.durationLabel(for: track)
            #expect(first == "1:23")
            #expect(second == "1:23")
            #expect(opens.values.count == 1)
        }

        @Test func indexedTrackCountDoesNotWalkAgain() {
            withLibrary(["Rock/a.mp3", "Rock/Live/b.m4a"]) { base in
                let index = URL(fileURLWithPath: base).appendingPathComponent("index.json")
                MusicLibraryIndex.activate(fileURL: index)
                let priorWalk = MusicLibraryIndex.directoryWalk
                defer {
                    MusicLibraryIndex.reset()
                    MusicLibraryIndex.directoryWalk = priorWalk
                    TrackMeta.invalidateCaches()
                }
                #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
                TrackMeta.discardMemoryCounts()
                MusicLibraryIndex.discardMemory()
                let walks = MusicCallbackRecorder<Int>()
                MusicLibraryIndex.directoryWalk = { _ in walks.append(1) }
                #expect(TrackMeta.trackCount(under: "Rock", base: base) == 2)
                #expect(walks.values.isEmpty)
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
}
