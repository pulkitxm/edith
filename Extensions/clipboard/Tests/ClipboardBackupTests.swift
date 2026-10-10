import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@Suite struct ClipboardBackupTests {
    @Test func equalSizeAndTimestampIndexesStillExportTheCurrentHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = ClipboardArchive(root: fixture.root.appendingPathComponent("seed"))
        _ = try capture("cloud", in: seed)
        try seed.stageExport(to: fixture.cloud)
        let local = try capture("local", in: fixture.archive)
        let staging = fixture.root.appendingPathComponent("staging")
        try fixture.archive.stageExport(to: staging)
        let oldIndex = fixture.cloud.appendingPathComponent("index.jsonl")
        let newIndex = staging.appendingPathComponent("index.jsonl")
        let previous = try Data(contentsOf: oldIndex), current = try Data(contentsOf: newIndex)
        #expect(previous != current)
        #expect(previous.count == current.count)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: oldIndex.path)
        try FileManager.default.setAttributes(
            [.modificationDate: date], ofItemAtPath: newIndex.path)
        try await ClipboardBackupProvider.exportSnapshot(staging: staging, cloud: fixture.cloud)
        #expect(try Data(contentsOf: oldIndex) == current)
        #expect(try ClipboardArchive(root: fixture.cloud).payload(id: local.id).data == local.data)
    }

    @Test @MainActor func enableMergesVerifiedHistoryAndExportMirrorsTheFilteredSnapshot()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = ClipboardArchive(root: fixture.root.appendingPathComponent("seed"))
        let remote = try capture("cloud", in: seed)
        try seed.stageExport(to: fixture.cloud)
        let local = try capture("local", in: fixture.archive)
        let provider = fixture.provider()
        #expect(await provider.restoreOnEnable())
        #expect(try fixture.archive.snapshot(.init()).total == 2)
        #expect(try fixture.archive.payload(id: remote.id).data == remote.data)
        #expect(try fixture.archive.payload(id: local.id).data == local.data)
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.cloud.appendingPathComponent(".lock").path))
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        fixture.defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
        _ = try fixture.archive.mutate(.init(.delete, ids: [remote.id]))
        _ = try await provider.execute("backup.synchronize", payload: Data())
        let exported = ClipboardArchive(root: fixture.cloud)
        #expect(try exported.snapshot(.init()).total == 1)
        #expect(try exported.payload(id: local.id).data == local.data)
        #expect(fixture.defaults.double(forKey: AppStorageKeys.Clipboard.lastBackupAt) > 0)
        await provider.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute("backup.synchronize", payload: Data())
        }
    }

    @Test @MainActor func corruptCloudBlobNeverChangesTheExistingHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = ClipboardArchive(root: fixture.root.appendingPathComponent("seed"))
        let remote = try capture("cloud", in: seed)
        try seed.stageExport(to: fixture.cloud)
        let entry = try seed.entry(id: remote.id)
        try Data("corrupted".utf8).write(
            to: fixture.cloud.appendingPathComponent("blobs/" + entry.sha256 + "." + entry.ext))
        let local = try capture("local", in: fixture.archive)
        let provider = fixture.provider()
        #expect(!(await provider.restoreOnEnable()))
        #expect(try fixture.archive.snapshot(.init()).total == 1)
        #expect(try fixture.archive.payload(id: local.id).data == local.data)
        #expect(provider.failure != nil)
        await provider.shutdown()
    }

    @Test @MainActor func pendingCloudRestoreIsOwnedAndCancelledOnStop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.cloud, withIntermediateDirectories: true)
        try Data("placeholder".utf8).write(
            to: fixture.cloud.appendingPathComponent(".index.jsonl.icloud"))
        let provider = fixture.provider()
        let restore = Task { await provider.restoreOnEnable() }
        for _ in 0..<100 {
            let result = try await provider.execute("backup.status", payload: Data())
            if (try JSONSerialization.jsonObject(with: result) as? [String: Any])?["running"]
                as? Bool == true
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await provider.shutdown()
        #expect(!(await restore.value))
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.archive.root.appendingPathComponent("index.jsonl").path))
    }

    @Test @MainActor func optedOutBackupRejectsReceivedPathsAndForeignRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let provider = fixture.provider()
        #expect(
            String(
                decoding: try await provider.execute("backup.synchronize", payload: Data()),
                as: UTF8.self) == "{\"enabled\":false}")
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute(
                "backup.synchronize", payload: Data(#"{"path":"/foreign"}"#.utf8))
        }
        let data = fixture.root.appendingPathComponent("Data/clipboard")
        #expect(
            try ClipboardBackupProvider.cloudDirectory(
                identifier: "com.pulkit.edith.dev.synthetic", root: data)
                == fixture.root.appendingPathComponent("iCloud/clipboard"))
        #expect(throws: ExtensionPeerError.self) {
            try ClipboardBackupProvider.cloudDirectory(identifier: "foreign", root: data)
        }
        try FileManager.default.createSymbolicLink(
            at: fixture.cloud, withDestinationURL: fixture.root)
        #expect(!(await provider.restoreOnEnable()))
        await provider.shutdown()
    }

    @Test @MainActor func clipboardEventsDebounceOwnedHistoryAndSkipRestoreFeedback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try capture("first", in: fixture.archive)
        let provider = fixture.provider()
        provider.startScheduling(debounce: .milliseconds(20))
        IPC.post(IPC.Name.clipboardChanged)
        try await Task.sleep(for: .milliseconds(60))
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
        fixture.defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
        provider.preferencesChanged()
        await wait { (try? ClipboardArchive(root: fixture.cloud).snapshot(.init()).total) == 1 }
        _ = try capture("second", in: fixture.archive)
        IPC.post(IPC.Name.clipboardChanged, userInfo: ["backup": false])
        try await Task.sleep(for: .milliseconds(60))
        #expect(try ClipboardArchive(root: fixture.cloud).snapshot(.init()).total == 1)
        IPC.post(IPC.Name.clipboardChanged)
        await wait { (try? ClipboardArchive(root: fixture.cloud).snapshot(.init()).total) == 2 }
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        let seed = ClipboardArchive(root: fixture.root.appendingPathComponent("seed"))
        let remote = try capture("remote", in: seed)
        try seed.stageExport(to: fixture.cloud)
        fixture.defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        await wait {
            (try? fixture.archive.snapshot(.init()).total) == 3
                && (try? ClipboardArchive(root: fixture.cloud).snapshot(.init()).total) == 3
        }
        #expect(try fixture.archive.payload(id: remote.id).data == remote.data)
        await provider.shutdown()
        _ = try capture("after stop", in: fixture.archive)
        IPC.post(IPC.Name.clipboardChanged)
        provider.preferencesChanged()
        try await Task.sleep(for: .milliseconds(60))
        #expect(try ClipboardArchive(root: fixture.cloud).snapshot(.init()).total == 3)
    }

    @Test @MainActor func masterOptOutPreventsCloudHistoryRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let seed = ClipboardArchive(root: fixture.root.appendingPathComponent("seed"))
        _ = try capture("remote", in: seed)
        try seed.stageExport(to: fixture.cloud)
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        let provider = fixture.provider()
        #expect(await provider.restoreOnEnable())
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.archive.root.appendingPathComponent("index.jsonl").path))
        await provider.shutdown()
    }

    @Test @MainActor func unavailableCloudNeverCreatesASyntheticBackupDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try capture("local", in: fixture.archive)
        fixture.defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
        let provider = fixture.provider(cloudAvailable: { false })
        provider.startScheduling(debounce: .zero)
        IPC.post(IPC.Name.clipboardChanged)
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
        _ = try capture("local", in: fixture.archive)
        fixture.defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
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

    private func capture(_ value: String, in archive: ClipboardArchive) throws -> ClipboardCapture {
        let capture = ClipboardCapture(
            payload: .init(
                data: Data(value.utf8), types: ["public.utf8-plain-text"], ext: "txt",
                preview: value), sourceApp: nil, sourceBundleID: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try archive.capture(capture, maxItems: 200, maxBytes: 1000, maxAge: nil)
        return capture
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let archive: ClipboardArchive
        var cloud: URL { root.appendingPathComponent("cloud") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "clipboard-backup-synthetic-" + UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            suite = "com.pulkit.edith.tests.clipboard-backup-" + UUID().uuidString
            defaults = try #require(UserDefaults(suiteName: suite))
            archive = ClipboardArchive(root: root.appendingPathComponent("local"))
        }

        @MainActor func provider(cloudAvailable: @escaping () -> Bool = { true })
            -> ClipboardBackupProvider
        {
            ClipboardBackupProvider(
                archive: archive, cloud: cloud, applicationDefaults: defaults, defaults: defaults,
                cloudAvailable: cloudAvailable, onBattery: { false })
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
