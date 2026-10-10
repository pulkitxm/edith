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

    @Test @MainActor func lifecycleKeepsStatusAndCancelAvailableDuringEnableRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        let placeholder = fixture.cloud.appendingPathComponent(".waiting.mp3.icloud")
        try Data("placeholder".utf8).write(to: placeholder)
        let lifecycle = MusicBackupLifecycle(provider: fixture.provider())
        for _ in 0..<100
        where fixture.defaults.integer(forKey: MusicBackupProvider.restorePendingKey) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let status =
            try JSONSerialization.jsonObject(
                with: await lifecycle.execute("backup.status", payload: Data())) as? [String: Any]
        #expect(status?["running"] as? Bool == true)
        #expect(status?["restorePending"] as? Int == 1)
        _ = try await lifecycle.execute("backup.cancel", payload: Data())
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        try FileManager.default.removeItem(at: placeholder)
        try FileManager.default.createDirectory(
            at: fixture.local, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: fixture.local.appendingPathComponent("track.mp3"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        _ = try await lifecycle.execute("backup.synchronize", payload: Data())
        #expect(
            try Data(contentsOf: fixture.cloud.appendingPathComponent("track.mp3"))
                == Data("selected".utf8))
        await lifecycle.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await lifecycle.execute("backup.status", payload: Data())
        }
    }

    @Test @MainActor func lifecycleShutdownDrainsRestoreAndQueuedExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(
            to: fixture.cloud.appendingPathComponent(".waiting.mp3.icloud"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        let lifecycle = MusicBackupLifecycle(provider: fixture.provider())
        for _ in 0..<100
        where fixture.defaults.integer(forKey: MusicBackupProvider.restorePendingKey) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let export = Task { try await lifecycle.execute("backup.synchronize", payload: Data()) }
        await Task.yield()
        await lifecycle.shutdown()
        await #expect(throws: ExtensionPeerError.self) { try await export.value }
        #expect(fixture.defaults.double(forKey: AppStorageKeys.Music.lastBackupAt) == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
    }

    @Test @MainActor func folderEventsRespectOptInAndReenableRestoresBeforeMirroring() async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.local, withIntermediateDirectories: true)
        let selected = fixture.local.appendingPathComponent("selected.mp3")
        try Data("selected".utf8).write(to: selected)
        let provider = fixture.provider()
        provider.startScheduling(debounce: .milliseconds(20))
        MusicEvents.post(MusicEvents.Name.musicFolderChanged)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        provider.preferencesChanged()
        await wait {
            FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("selected.mp3").path)
        }
        let added = fixture.local.appendingPathComponent("added.mp3")
        try Data("added".utf8).write(to: added)
        NotificationCenter.default.post(name: .musicFolderChangedLocally, object: nil)
        await wait {
            FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("added.mp3").path)
        }
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        try Data("remote".utf8).write(to: fixture.cloud.appendingPathComponent("remote.mp3"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        await wait {
            FileManager.default.fileExists(
                atPath: fixture.local.appendingPathComponent("remote.mp3").path)
        }
        #expect(
            try Data(contentsOf: fixture.cloud.appendingPathComponent("remote.mp3"))
                == Data("remote".utf8))
        fixture.defaults.set(false, forKey: AppStorageKeys.Music.backup)
        provider.preferencesChanged()
        try Data("private".utf8).write(to: fixture.local.appendingPathComponent("private.mp3"))
        MusicEvents.post(MusicEvents.Name.musicFolderChanged)
        try await Task.sleep(for: .milliseconds(60))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("private.mp3").path))
        await provider.shutdown()
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        MusicEvents.post(MusicEvents.Name.musicFolderChanged)
        provider.preferencesChanged()
        try await Task.sleep(for: .milliseconds(60))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("private.mp3").path))
    }

    @Test @MainActor func masterOptOutPreventsRestoreAndCustomFolderReenableNeverImportsCloud()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("remote".utf8).write(to: fixture.cloud.appendingPathComponent("remote.mp3"))
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        let disabled = fixture.provider()
        #expect(await disabled.restoreOnEnable())
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        await disabled.shutdown()
        let custom = fixture.root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try Data("chosen".utf8).write(to: custom.appendingPathComponent("chosen.mp3"))
        let provider = fixture.provider(directory: custom)
        provider.startScheduling(debounce: .milliseconds(20))
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        await wait {
            FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("chosen.mp3").path)
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: custom.appendingPathComponent("remote.mp3").path))
        await provider.shutdown()
    }

    @Test @MainActor func unavailableCloudNeverCreatesASyntheticBackupDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.local, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: fixture.local.appendingPathComponent("selected.mp3"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        let provider = fixture.provider(cloudAvailable: { false })
        provider.startScheduling(debounce: .zero)
        MusicEvents.post(MusicEvents.Name.musicFolderChanged)
        #expect(await provider.restoreOnEnable())
        #expect(
            String(
                decoding: try await provider.execute("backup.synchronize", payload: Data()),
                as: UTF8.self) == "{\"enabled\":false}")
        await provider.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
    }

    @Test @MainActor func cancelBeforeSchedulingPreventsLateBootstrapWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.local, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: fixture.local.appendingPathComponent("selected.mp3"))
        fixture.defaults.set(true, forKey: AppStorageKeys.Music.backup)
        let provider = fixture.provider()
        _ = try await provider.execute("backup.cancel", payload: Data())
        provider.startScheduling(debounce: .zero, restorePending: true)
        let status =
            try JSONSerialization.jsonObject(
                with: await provider.execute("backup.status", payload: Data())) as? [String: Any]
        #expect(status?["scheduled"] as? Bool == false)
        await provider.shutdown()
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
    }

    @MainActor private func wait(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready())
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

        @MainActor func provider(
            directory: URL? = nil, cloudAvailable: @escaping () -> Bool = { true }
        ) -> MusicBackupProvider {
            let directory = directory ?? local
            return MusicBackupProvider(
                directory: { directory }, ownedDirectory: local, cloud: cloud,
                applicationDefaults: defaults, defaults: defaults, cloudAvailable: cloudAvailable,
                onBattery: { false })
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
