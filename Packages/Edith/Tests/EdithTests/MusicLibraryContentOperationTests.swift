import Foundation
import Testing

@testable import EdithKit

@Suite struct MusicLibraryContentOperationTests {
    private let root = URL(fileURLWithPath: "/tmp/music-library")

    @Test func descriptorsCoverSixDistinctContentLeaves() {
        let descriptors = MusicLibraryContentOperation.allCases.map(\.descriptor)

        #expect(
            Set(descriptors.map(\.cli))
                == [
                    ["music", "ls"], ["music", "rescan"], ["music", "mkdir"],
                    ["music", "mv"], ["music", "rename"], ["music", "rm"],
                ])
        #expect(Set(descriptors.map(\.id)).count == 6)
        #expect(descriptors.filter(\.requiresPreview).map(\.cli) == [["music", "rm"]])
        #expect(descriptors.first { $0.cli == ["music", "ls"] }?.effect == .read)
        #expect(descriptors.first { $0.cli == ["music", "rm"] }?.effect == .destructive)
    }

    @Test func listingUsesTheNamedFolderAndChoosesRecursiveTracksOnlyWhenAsked() {
        let folder = MusicFolder(url: root.appendingPathComponent("Chill"), relativePath: "Chill")
        let child = MusicFolder(
            url: root.appendingPathComponent("Chill/Calm"), relativePath: "Chill/Calm")
        let direct = track("Chill/one.mp3")
        let nested = track("Chill/Calm/two.mp3")
        var paths: [String] = []

        let shallow = MusicLibraryContentOperationExecution.list(
            folder,
            entries: {
                paths.append("entries:\($0)")
                return ([child], [direct])
            },
            recursiveTracks: {
                paths.append("recursive:\($0)")
                return [direct, nested]
            })
        let recursive = MusicLibraryContentOperationExecution.list(
            folder, recursive: true, entries: { _ in ([child], [direct]) },
            recursiveTracks: {
                paths.append("recursive:\($0)")
                return [direct, nested]
            })

        #expect(shallow.folder == folder)
        #expect(shallow.folders == [child])
        #expect(shallow.tracks == [direct])
        #expect(recursive.tracks == [direct, nested])
        #expect(paths == ["entries:Chill", "recursive:Chill"])
    }

    @Test func rescanInvalidatesBeforeReading() {
        var events: [String] = []
        let tracks = MusicLibraryContentOperationExecution.rescan(
            invalidate: { events.append("invalidate") },
            scan: {
                events.append("scan")
                return [self.track("song.mp3")]
            })

        #expect(events == ["invalidate", "scan"])
        #expect(tracks.map(\.relativePath) == ["song.mp3"])
    }

    @Test func creationMovementAndRenameUseOnlyTheirTypedTargets() throws {
        let source = track("song.mp3")
        let folder = MusicFolder(url: root.appendingPathComponent("Chill"), relativePath: "Chill")
        var calls: [String] = []

        let made = try MusicLibraryContentOperationExecution.createFolder(
            named: "Calm", under: "Chill",
            create: { name, parent in
                calls.append("mkdir:\(parent)/\(name)")
                return MusicFolder(
                    url: self.root.appendingPathComponent("Chill/Calm"),
                    relativePath: "Chill/Calm")
            })
        let moved = try MusicLibraryContentOperationExecution.move(
            source, to: "Chill",
            move: { track, destination in
                calls.append("move:\(track.relativePath):\(destination)")
                return MusicLibrary.Move(from: track.relativePath, to: "Chill/song.mp3")
            })
        let renamedTrack = try MusicLibraryContentOperationExecution.rename(
            .track(source), to: "new",
            renameTrack: { track, name in
                calls.append("rename-track:\(track.relativePath):\(name)")
                return MusicLibrary.Move(from: track.relativePath, to: "new.mp3")
            },
            renameFolder: { _, _ in throw MusicLibraryContentTestError.wrongTarget })
        let renamedFolder = try MusicLibraryContentOperationExecution.rename(
            .folder(folder), to: "Calm",
            renameTrack: { _, _ in throw MusicLibraryContentTestError.wrongTarget },
            renameFolder: { folder, name in
                calls.append("rename-folder:\(folder.relativePath):\(name)")
                return MusicLibrary.Move(from: folder.relativePath, to: name)
            })

        #expect(made.relativePath == "Chill/Calm")
        #expect(moved.to == "Chill/song.mp3")
        #expect(renamedTrack.to == "new.mp3")
        #expect(renamedFolder.to == "Calm")
        #expect(
            calls
                == [
                    "mkdir:Chill/Calm", "move:song.mp3:Chill",
                    "rename-track:song.mp3:new", "rename-folder:Chill:Calm",
                ])
    }

    @Test func removalPlansDistinguishOneTrackFromAFolderTree() throws {
        let source = track("song.mp3")
        let folder = MusicFolder(url: root.appendingPathComponent("Chill"), relativePath: "Chill")
        var trashed: [String] = []
        let trackPlan = try MusicLibraryContentOperationExecution.remove(
            .track(source), trashTrack: { trashed.append("track:\($0.relativePath)") },
            trashFolder: { _ in throw MusicLibraryContentTestError.wrongTarget })
        let folderPlan = try MusicLibraryContentOperationExecution.remove(
            .folder(folder), trashTrack: { _ in throw MusicLibraryContentTestError.wrongTarget },
            trashFolder: { trashed.append("folder:\($0.relativePath)") },
            trackCount: { _ in 12 })

        #expect(trackPlan.path == "song.mp3")
        #expect(trackPlan.trackCount == 1)
        #expect(folderPlan.path == "Chill")
        #expect(folderPlan.trackCount == 12)
        #expect(trashed == ["track:song.mp3", "folder:Chill"])
    }

    @Test func filesystemFailuresPassThroughUnchanged() {
        #expect(throws: MusicLibraryContentTestError.refused) {
            _ = try MusicLibraryContentOperationExecution.move(
                track("song.mp3"), to: "Chill",
                move: { _, _ in throw MusicLibraryContentTestError.refused })
        }
    }

    @Test func removalExecutesTheExactTargetCapturedByItsPreviewPlan() throws {
        let folder = MusicFolder(url: root.appendingPathComponent("Chill"), relativePath: "Chill")
        let plan = MusicLibraryContentOperationExecution.removalPlan(folderTarget(folder)) { _ in 7
        }
        var removed: MusicFolder?

        let executed = try MusicLibraryContentOperationExecution.remove(
            plan, trashTrack: { _ in throw MusicLibraryContentTestError.wrongTarget },
            trashFolder: { removed = $0 })

        #expect(executed == plan)
        #expect(executed.path == "Chill")
        #expect(executed.trackCount == 7)
        #expect(removed == folder)
    }

    @Test func libraryRootCannotBeRenamed() {
        let folder = MusicFolder(url: root, relativePath: "")

        #expect(throws: MusicLibraryError.failed("the library root cannot be renamed")) {
            _ = try MusicLibrary.renameFolder(folder, to: "Elsewhere")
        }
    }

    private func track(_ path: String) -> Track {
        Track(url: root.appendingPathComponent(path), relativePath: path)
    }

    private func folderTarget(_ folder: MusicFolder) -> MusicLibraryRemovalTarget {
        .folder(folder)
    }
}

private enum MusicLibraryContentTestError: Error {
    case refused
    case wrongTarget
}
