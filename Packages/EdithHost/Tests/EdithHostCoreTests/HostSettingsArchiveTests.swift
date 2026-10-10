import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostSettingsArchiveTests {
    @Test func exportPreservesTypedPreferencesAndOmitsSecretsAndRuntimeState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.application.set("synthetic", forKey: AppStorageKeys.General.theme)
        fixture.application.set(Data([1, 3, 5]), forKey: "surfaceLayoutProfiles")
        fixture.application.set("private", forKey: "apiToken")
        fixture.application.set(true, forKey: AppStorageKeys.Permissions.cameraGranted)
        fixture.defaults("music").set(0.75, forKey: AppStorageKeys.Music.volume)
        fixture.defaults("music").set(123, forKey: AppStorageKeys.Music.lastBackupAt)
        fixture.control.set(["usage"], forKey: HostExtensionSessions.enabledExtensionsKey)
        let archive = try fixture.archive()
        let result = try await archive.synchronize()
        #expect(result.exported && !result.restored)
        let bytes = try Data(contentsOf: fixture.cloud.appendingPathComponent("settings.json"))
        let document = try HostSettingsDocument.decode(bytes, extensionIDs: ["usage", "music"])
        #expect(
            document.preferences["application"]?[AppStorageKeys.General.theme]?.value as? String
                == "synthetic")
        #expect(
            document.preferences["application"]?["surfaceLayoutProfiles"]?.value as? Data
                == Data([1, 3, 5]))
        #expect(document.preferences["application"]?["apiToken"] == nil)
        #expect(
            document.preferences["application"]?[AppStorageKeys.Permissions.cameraGranted] == nil)
        #expect(document.preferences["music"]?[AppStorageKeys.Music.lastBackupAt] == nil)
        #expect(document.enabledIDs == ["usage"])
        #expect(fixture.application.double(forKey: AppStorageKeys.Backup.lastBackupAt) > 0)
        var metadata = stat()
        #expect(lstat(fixture.local.path, &metadata) == 0 && metadata.st_mode & 0o777 == 0o600)
        await archive.shutdown()
    }

    @Test func freshRestoreUsesOwningSuitesWithoutEnablingExtensions() async throws {
        let source = try Fixture(), destination = try Fixture()
        defer { source.remove(); destination.remove() }
        source.application.set("ocean", forKey: AppStorageKeys.General.theme)
        source.defaults("music").set(0.4, forKey: AppStorageKeys.Music.volume)
        source.control.set(["music", "usage"], forKey: HostExtensionSessions.enabledExtensionsKey)
        let exporter = try source.archive()
        _ = try await exporter.synchronize()
        await exporter.shutdown()
        let restorer = try destination.archive(cloud: source.cloud)
        let result = try await restorer.synchronize(restoreOnly: true)
        #expect(result.restored && !result.exported)
        #expect(result.suggestedExtensionIDs == ["music", "usage"])
        #expect(destination.application.string(forKey: AppStorageKeys.General.theme) == "ocean")
        #expect(destination.defaults("music").double(forKey: AppStorageKeys.Music.volume) == 0.4)
        #expect(
            destination.control.stringArray(forKey: HostExtensionSessions.enabledExtensionsKey)
                == nil)
        await restorer.shutdown()
        let reopened = try destination.archive(cloud: source.cloud)
        #expect(!(try await reopened.synchronize()).restored)
        await reopened.shutdown()
    }

    @Test func disabledCloudAndCancelledWorkDoNotCreateArchives() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.application.set(false, forKey: AppStorageKeys.Backup.icloud)
        let archive = try fixture.archive()
        #expect(!(try await archive.synchronize()).exported)
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        fixture.application.set(true, forKey: AppStorageKeys.Backup.icloud)
        let task = Task {
            try Task.checkCancellation(); return try await archive.synchronize()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        await archive.shutdown()
        await #expect(throws: HostWorkerError.self) { try await archive.synchronize() }
    }

    @Test func malformedOversizedAndLinkedCloudArchivesFailWithoutChangingLocalPreferences()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.application.set("local", forKey: AppStorageKeys.General.theme)
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        let remote = fixture.cloud.appendingPathComponent("settings.json")
        let archive = try fixture.archive()
        for bytes in [
            Data("invalid".utf8), Data(repeating: 32, count: HostSettingsArchive.maximumBytes + 1),
        ] {
            try bytes.write(to: remote)
            do {
                _ = try await archive.synchronize(restoreOnly: true);
                Issue.record("Invalid archive was accepted")
            } catch {}
            #expect(fixture.application.string(forKey: AppStorageKeys.General.theme) == "local")
            #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        }
        try FileManager.default.removeItem(at: remote)
        let foreign = fixture.root.appendingPathComponent("foreign")
        try Data("foreign".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: remote, withDestinationURL: foreign)
        await #expect(throws: CocoaError.self) { try await archive.synchronize(restoreOnly: true) }
        #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
        await archive.shutdown()
    }

    @Test func unknownDomainsKeysAndUnsafeThresholdsAreRejectedBeforeAnyWrites() throws {
        for document in [
            HostSettingsDocument(version: 1, preferences: ["foreign": [:]], enabledIDs: []),
            HostSettingsDocument(
                version: 1, preferences: ["application": ["apiToken": .string("private")]],
                enabledIDs: []),
            HostSettingsDocument(
                version: 1, preferences: ["lidAwake": ["lidAwakeBatteryThreshold": .integer(101)]],
                enabledIDs: []),
            HostSettingsDocument(version: 1, preferences: [:], enabledIDs: ["foreign"]),
        ] {
            #expect(throws: HostWorkerError.self) {
                try HostSettingsDocument.decode(
                    document.encoded(), extensionIDs: ["usage", "lidAwake"])
            }
        }
        let nested = (0..<80).reduce("1") { value, _ in "[" + value + "]" }
        #expect(throws: HostWorkerError.self) {
            try HostSettingsDocument.decode(Data(nested.utf8), extensionIDs: [])
        }
    }

    @Test func newerCloudRestoresUnchangedSettingsAndLocalEditsWinBeforeExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.application.set("local", forKey: AppStorageKeys.General.theme)
        let archive = try fixture.archive()
        _ = try await archive.synchronize()
        let remote = fixture.cloud.appendingPathComponent("settings.json")
        func writeCloud(_ theme: String) throws {
            let document = HostSettingsDocument(
                version: 1,
                preferences: ["application": [AppStorageKeys.General.theme: .string(theme)]],
                enabledIDs: [])
            try document.encoded().write(to: remote)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: remote.path)
        }
        try writeCloud("newer")
        #expect((try await archive.synchronize()).restored)
        #expect(fixture.application.string(forKey: AppStorageKeys.General.theme) == "newer")
        fixture.application.set("user edit", forKey: AppStorageKeys.General.theme)
        try writeCloud("cloud edit")
        let result = try await archive.synchronize()
        #expect(!result.restored && result.exported)
        #expect(fixture.application.string(forKey: AppStorageKeys.General.theme) == "user edit")
        await archive.shutdown()
    }

    @Test func pendingCloudDownloadCannotBeOverwrittenByAnEmptyExport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        let placeholder = fixture.cloud.appendingPathComponent(".settings.json.icloud")
        try Data("synthetic placeholder".utf8).write(to: placeholder)
        let archive = try fixture.archive()
        await #expect(throws: HostWorkerError.self) { try await archive.synchronize() }
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent("settings.json").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.local.path))
        #expect(try Data(contentsOf: placeholder) == Data("synthetic placeholder".utf8))
        await archive.shutdown()
    }

    private struct Fixture {
        let root: URL
        let identity: HostIdentity
        let application: UserDefaults
        let control: UserDefaults
        var cloud: URL { root.appendingPathComponent("cloud") }
        var local: URL { identity.root.appendingPathComponent("Core/settings.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "settings-synthetic-" + UUID().uuidString)
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.settings-" + UUID().uuidString,
                supportDirectory: root)
            application = try #require(UserDefaults(suiteName: identity.identifier))
            control = try #require(UserDefaults(suiteName: identity.defaultsSuite))
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        }

        func defaults(_ id: String) -> UserDefaults {
            UserDefaults(suiteName: identity.extensionDefaultsSuite(id))!
        }
        @MainActor func archive(cloud: URL? = nil) throws -> HostSettingsArchive {
            try HostSettingsArchive(identity: identity, cloudDirectory: cloud ?? self.cloud)
        }

        func remove() {
            application.removePersistentDomain(forName: identity.identifier)
            control.removePersistentDomain(forName: identity.defaultsSuite)
            for id in (try? HostIndex.bundled().map(\.id)) ?? [] {
                defaults(id).removePersistentDomain(forName: identity.extensionDefaultsSuite(id))
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
