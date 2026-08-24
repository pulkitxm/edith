import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIMusicLibrarySelectionTests {
    @Test func parserAndCompletionTreeExposeTheDedicatedRoute() throws {
        #expect(
            try EdRoot.parseAsRoot(["music", "library", "~/Music"])
                is MusicLibraryFolderCommand)
        let node = CommandTree.root.child("music")?.child("library")
        #expect(node?.arguments == [.localPath])
        #expect(node?.options.contains("--json") == true)
    }

    @Test func plainSelectionExpandsPersistsClearsStaleAndAnnounces() async throws {
        try await CLIProbe.inWorld { world in
            let folder = world.sandbox.appendingPathComponent("Music")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            world.shared.set(true, forKey: Repo.musicFolderStaleKey)

            let result = await CLIProbe.capture(["music", "library", "~/Music"])

            #expect(result.code == 0)
            #expect(result.stdout == "music library set to \(folder.path)\n")
            #expect(result.stderr.isEmpty)
            #expect(world.shared.string(forKey: Repo.musicFolderPathKey) == folder.path)
            #expect(!world.shared.bool(forKey: Repo.musicFolderStaleKey))
            #expect(world.postedNames() == [IPC.Name.musicFolderChanged.rawValue])
        }
    }

    @Test func jsonSelectionReportsIdempotenceAsOneDocument() async throws {
        try await CLIProbe.inWorld { world in
            let folder = world.sandbox.appendingPathComponent("Music")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = await CLIProbe.capture(["music", "library", folder.path])

            let result = await CLIProbe.capture([
                "music", "library", folder.appendingPathComponent("../Music").path, "--json",
            ])

            #expect(result.code == 0)
            #expect(result.stderr.isEmpty)
            #expect(result.object?["path"] as? String == folder.path)
            #expect(result.object?["changed"] as? Bool == false)
            #expect(result.object?["external"] as? Bool == false)
            #expect(
                Set(result.object?.keys.map { $0 } ?? []) == ["path", "changed", "external"])
        }
    }

    @Test func missingSelectionFailsWithoutPersistingOrAnnouncing() async throws {
        await CLIProbe.inWorld { world in
            let missing = world.sandbox.appendingPathComponent("Missing")

            let result = await CLIProbe.capture([
                "music", "library", missing.path, "--json",
            ])

            #expect(result.code == ExitCodes.notFound)
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("no folder exists at \(missing.path)"))
            #expect(world.shared.string(forKey: Repo.musicFolderPathKey) == nil)
            #expect(world.postedNames().isEmpty)
        }
    }

    @Test func unconfirmedExternalRawSettingDoesNotSatisfyLibraryCommands() async throws {
        await CLIProbe.inWorld { world in
            world.shared.set("/Volumes/Unconfirmed/Music", forKey: Repo.musicFolderPathKey)

            let result = await CLIProbe.capture(["music", "rescan"])

            #expect(result.code == ExitCodes.unavailable)
            #expect(result.stderr.contains("no music folder is set"))
            #expect(result.stderr.contains("ed music library ~/Music"))
        }
    }
}
