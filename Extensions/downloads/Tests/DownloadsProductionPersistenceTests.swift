import EdithExtensionSupport
import Foundation
import Testing
@testable import DownloadsExtension

@Suite struct DownloadsProductionPersistenceTests {
    @Test func savedOriginalMusicFolderRemainsTheDefaultAudioDestination() throws {
        let suite = "downloads-production-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let music = home.appendingPathComponent("Music/Selected")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defaults.set(music.path, forKey: AppStorageKeys.Music.folderPath)
        let root = home.appendingPathComponent("Edith/Data/downloads")
        var environment = [
            "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith",
            "EDITH_EXTENSION_ID": "downloads", "EDITH_EXTENSION_DATA_ROOT": root.path,
        ]
        #expect(
            DownloadsStorage.resolvedAudioDirectory(
                defaults: defaults, homeDirectory: home,
                environment: environment, root: root
            ).path == music.path)
        environment["EDITH_APPLICATION_IDENTIFIER"] = "com.pulkit.edith.tests.synthetic"
        #expect(
            DownloadsStorage.resolvedAudioDirectory(
                defaults: defaults, homeDirectory: home,
                environment: environment, root: root
            ).path == root.appendingPathComponent("library").path)
    }
}
