import EdithKit
import Foundation
import Testing

@Suite struct MusicFadeTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let store = UserDefaults(suiteName: "edith-fade-\(UUID().uuidString)")!
        for (key, value) in values { store.set(value, forKey: key) }
        return store
    }

    @Test func disabledMeansNoFade() {
        #expect(MusicFade.duration(from: defaults([MusicFade.enabledKey: false])) == 0)
    }

    @Test func enabledWithoutLengthUsesDefault() {
        let store = defaults([MusicFade.enabledKey: true])
        #expect(MusicFade.duration(from: store) == MusicFade.defaultSeconds)
    }

    @Test func lengthIsClampedToRange() {
        let low = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 0.1])
        let high = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 99.0])
        #expect(MusicFade.duration(from: low) == MusicFade.secondsRange.lowerBound)
        #expect(MusicFade.duration(from: high) == MusicFade.secondsRange.upperBound)
    }

    @Test func lengthInRangeIsKept() {
        let store = defaults([MusicFade.enabledKey: true, MusicFade.secondsKey: 3.5])
        #expect(MusicFade.duration(from: store) == 3.5)
    }

    @Test func crossfadeIsOnByDefaultInSharedStore() {
        #expect(SharedDefaults.registeredDefaults[MusicFade.enabledKey] as? Bool == true)
    }
}

@Suite struct MusicLibraryTests {
    private func inTemp(_ body: (URL) throws -> Void) rethrows {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-music-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeFile(_ name: String, in root: URL) -> URL {
        let url = root.appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("ID3".utf8))
        return url
    }

    @Test func aNameWithPathSeparatorsCannotEscapeItsFolder() {
        #expect(MusicLibrary.sanitized("../../etc/passwd") == "..-..-etc-passwd")
        #expect(!MusicLibrary.sanitized("../../etc/passwd").contains("/"))
        #expect(MusicLibrary.sanitized("a/b:c") == "a-b-c")
        #expect(MusicLibrary.sanitized("   ") == "")
    }

    @Test func aBlankNameIsRefusedRatherThanMakingAnUnnamedFolder() throws {
        #expect(throws: MusicLibraryError.self) {
            _ = try MusicLibrary.createFolder(named: "   ")
        }
    }

    @Test func movingAFileLeavesNothingBehind() throws {
        try inTemp { root in
            let source = makeFile("alpha-song.mp3", in: root)
            let destination = root.appendingPathComponent("Chill/alpha-song.mp3")
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try MusicLibrary.relocate(from: source, to: destination)
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func movingOntoSomethingThatExistsIsRefusedRatherThanOverwriting() throws {
        try inTemp { root in
            let source = makeFile("alpha-song.mp3", in: root)
            let destination = makeFile("Chill/alpha-song.mp3", in: root)
            #expect(throws: MusicLibraryError.self) {
                _ = try MusicLibrary.relocate(from: source, to: destination)
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func movingSomewhereItAlreadyIsIsRefusedRatherThanLosingTheFile() throws {
        try inTemp { root in
            let source = makeFile("alpha-song.mp3", in: root)
            #expect(throws: MusicLibraryError.self) {
                _ = try MusicLibrary.relocate(from: source, to: source)
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func aTrackThatIsNotThereIsNotFound() {
        #expect(throws: MusicLibraryError.self) {
            _ = try MusicLibrary.track(at: "definitely-not-here-\(UUID().uuidString).mp3")
        }
        #expect(throws: MusicLibraryError.self) {
            _ = try MusicLibrary.folder(at: "definitely-not-here-\(UUID().uuidString)")
        }
    }

    @Test func theLibraryRootItselfCannotBeTrashed() throws {
        let root = try MusicLibrary.folder(at: "")
        #expect(throws: MusicLibraryError.self) { try MusicLibrary.trashFolder(root) }
    }
}
