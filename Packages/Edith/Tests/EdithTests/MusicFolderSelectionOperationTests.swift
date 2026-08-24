import Foundation
import Testing

@testable import EdithKit

@Suite struct MusicFolderSelectionOperationTests {
    @Test func descriptorDeclaresTheDedicatedMusicLibraryRoute() {
        let descriptor = MusicFolderSelectionOperation.select.descriptor

        #expect(descriptor.id.rawValue == "music.library.folder.select")
        #expect(descriptor.cli == ["music", "library"])
        #expect(descriptor.effect == .write)
        #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
        #expect(ConfigCatalog.definition(for: Repo.musicFolderPathKey) == nil)
    }

    @Test func selectionExpandsStandardizesPersistsAndAnnounces() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chosen = fixture.home.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        fixture.defaults.set(true, forKey: Repo.musicFolderStaleKey)
        var invalidations = 0
        var announcements = 0

        let result = try MusicFolderSelectionOperationExecution.select(
            "~/Music/../Music", defaults: fixture.defaults, homeDirectory: fixture.home,
            invalidate: { invalidations += 1 }, announce: { announcements += 1 })

        #expect(result.path == chosen.standardizedFileURL.path)
        #expect(result.changed)
        #expect(!result.confirmsExternalStorage)
        #expect(
            fixture.defaults.string(forKey: Repo.musicFolderPathKey)
                == chosen.standardizedFileURL.path)
        #expect(!fixture.defaults.bool(forKey: Repo.musicFolderStaleKey))
        #expect(
            Repo.selectedMusicDirectory(
                defaults: fixture.defaults, homeDirectory: fixture.home)
                == chosen.standardizedFileURL)
        #expect(invalidations == 1)
        #expect(announcements == 1)
    }

    @Test func selectingTheCurrentFolderStillRefreshesLiveConsumers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chosen = fixture.home.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        _ = try MusicFolderSelectionOperationExecution.select(
            chosen.path, defaults: fixture.defaults, homeDirectory: fixture.home,
            invalidate: {}, announce: {})
        var events: [String] = []

        let result = try MusicFolderSelectionOperationExecution.select(
            chosen.path, defaults: fixture.defaults, homeDirectory: fixture.home,
            invalidate: { events.append("invalidate") }, announce: { events.append("announce") })

        #expect(!result.changed)
        #expect(events == ["invalidate", "announce"])
    }

    @Test func externalSelectionSurvivesRestoredPathValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try MusicFolderSelectionOperationExecution.select(
            "/Volumes", defaults: fixture.defaults, homeDirectory: fixture.home,
            invalidate: {}, announce: {})
        Repo.prepareStoredPaths(defaults: fixture.defaults, homeDirectory: fixture.home)

        #expect(result.confirmsExternalStorage)
        #expect(
            Repo.selectedMusicDirectory(
                defaults: fixture.defaults, homeDirectory: fixture.home)?.path == "/Volumes")
        #expect(!fixture.defaults.bool(forKey: Repo.musicFolderStaleKey))
    }

    @Test func symlinkedExternalSelectionIsResolvedAndConfirmed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.home.appendingPathComponent("ExternalMusic")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/Volumes"))

        let result = try MusicFolderSelectionOperationExecution.select(
            link.path, defaults: fixture.defaults, homeDirectory: fixture.home,
            invalidate: {}, announce: {})

        #expect(result.path == "/Volumes")
        #expect(result.confirmsExternalStorage)
        #expect(fixture.defaults.string(forKey: Repo.musicFolderPathKey) == "/Volumes")
        #expect(
            Repo.selectedMusicDirectory(
                defaults: fixture.defaults, homeDirectory: fixture.home)?.path == "/Volumes")
    }

    @Test func rawSymlinkToExternalStorageDoesNotBypassConfirmation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let link = fixture.home.appendingPathComponent("RestoredMusic")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(fileURLWithPath: "/Volumes"))
        fixture.defaults.set(link.path, forKey: Repo.musicFolderPathKey)

        #expect(
            Repo.selectedMusicDirectory(
                defaults: fixture.defaults, homeDirectory: fixture.home) == nil)
        Repo.prepareStoredPaths(defaults: fixture.defaults, homeDirectory: fixture.home)
        #expect(fixture.defaults.string(forKey: Repo.musicFolderPathKey) == nil)
        #expect(fixture.defaults.bool(forKey: Repo.musicFolderStaleKey))
    }

    @Test func selectionRejectsMissingPathsAndFilesWithoutChangingState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.home.appendingPathComponent("song.mp3")
        try Data("music".utf8).write(to: file)
        let missing = fixture.home.appendingPathComponent("Missing")
        var announcements = 0

        #expect(throws: MusicFolderSelectionError.missing(missing.path)) {
            _ = try MusicFolderSelectionOperationExecution.select(
                missing.path, defaults: fixture.defaults, homeDirectory: fixture.home,
                announce: { announcements += 1 })
        }
        #expect(throws: MusicFolderSelectionError.notDirectory(file.path)) {
            _ = try MusicFolderSelectionOperationExecution.select(
                file.path, defaults: fixture.defaults, homeDirectory: fixture.home,
                announce: { announcements += 1 })
        }
        #expect(fixture.defaults.string(forKey: Repo.musicFolderPathKey) == nil)
        #expect(announcements == 0)
    }

    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let home: URL

        init() throws {
            suite = "edith.music.folder.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            home = FileManager.default.temporaryDirectory.appendingPathComponent(
                "edith-music-folder-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
    }
}
