import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

@Suite struct MusicBackupTests {
    @Test @MainActor func enableRestoresMissingFilesAndExportMirrorsTheSelectedLibrary()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("local selection".utf8).write(
            to: fixture.local.appendingPathComponent("existing.mp3"))
        try Data("foreign copy".utf8).write(
            to: fixture.cloud.appendingPathComponent("existing.mp3"))
        try Data("restored track".utf8).write(to: fixture.cloud.appendingPathComponent("new.mp3"))
        let provider = fixture.provider()
        #expect(await provider.restoreOnEnable())
        #expect(
            try Data(contentsOf: fixture.local.appendingPathComponent("existing.mp3"))
                == Data("local selection".utf8))
        #expect(
            try Data(contentsOf: fixture.local.appendingPathComponent("new.mp3"))
                == Data("restored track".utf8))
        #expect(fixture.defaults.integer(forKey: MusicBackupProvider.restorePendingKey) == 0)
        try FileManager.default.removeItem(at: fixture.local.appendingPathComponent("new.mp3"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        _ = try await provider.execute("backup.synchronize", payload: Data())
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("new.mp3").path))
        #expect(
            try Data(contentsOf: fixture.cloud.appendingPathComponent("existing.mp3"))
                == Data("local selection".utf8))
        #expect(fixture.defaults.double(forKey: AppStorageKeys.Music.lastBackupAt) > 0)
        await provider.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute("backup.synchronize", payload: Data())
        }
    }

    @Test @MainActor func disabledBackupAndCustomEnableDestinationNeverWrite() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("cloud".utf8).write(to: fixture.cloud.appendingPathComponent("new.mp3"))
        let custom = fixture.root.appendingPathComponent("user-selected")
        let provider = fixture.provider(directory: custom)
        #expect(!(await provider.restoreOnEnable()))
        #expect(!FileManager.default.fileExists(atPath: custom.path))
        let result = try await provider.execute("backup.synchronize", payload: Data())
        #expect(String(decoding: result, as: UTF8.self) == "{\"enabled\":false}")
        #expect(!FileManager.default.fileExists(atPath: custom.path))
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute(
                "backup.synchronize", payload: Data(#"{"path":"/foreign"}"#.utf8))
        }
        await provider.shutdown()
    }

    @Test @MainActor func placeholderRestoreCanBeCancelledWithoutCopyingPlaceholderData()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(
            to: fixture.cloud.appendingPathComponent(".waiting.mp3.icloud"))
        let provider = fixture.provider()
        let restore = Task { await provider.restoreOnEnable() }
        for _ in 0..<100
        where fixture.defaults.integer(forKey: MusicBackupProvider.restorePendingKey) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.defaults.integer(forKey: MusicBackupProvider.restorePendingKey) == 1)
        await provider.shutdown()
        #expect(!(await restore.value))
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
    }

    @Test func foreignCloudRootsAreRejectedAndDevelopmentStorageIsIsolated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("Data/music")
        #expect(
            try MusicBackupProvider.cloudDirectory(
                identifier: "com.pulkit.edith.dev.synthetic", root: root)
                == fixture.root.appendingPathComponent("iCloud/music"))
        #expect(throws: ExtensionPeerError.self) {
            try MusicBackupProvider.cloudDirectory(identifier: "foreign", root: root)
        }
        try FileManager.default.createSymbolicLink(
            at: fixture.cloud, withDestinationURL: fixture.root)
        #expect(throws: ExtensionPeerError.self) {
            try MusicBackupProvider.missingFiles(source: fixture.cloud, destination: fixture.local)
        }
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        var local: URL { root.appendingPathComponent("library") }
        var cloud: URL { root.appendingPathComponent("cloud") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "music-backup-synthetic-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            suite = "com.pulkit.edith.tests.music-backup-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        @MainActor func provider(directory: URL? = nil) -> MusicBackupProvider {
            let directory = directory ?? local
            return MusicBackupProvider(
                directory: { directory }, ownedDirectory: local, cloud: cloud,
                applicationDefaults: defaults, defaults: defaults)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
