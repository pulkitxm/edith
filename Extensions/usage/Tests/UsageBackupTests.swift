import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageBackupTests {
    @Test func mergedUsageAndLimitsAreDurableAndIdempotent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local"),
            cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let localUsage = local.appendingPathComponent("usage.json"),
            cloudUsage = cloud.appendingPathComponent("usage.json")
        try usage("2026-08-20", tokens: 23).write(to: localUsage)
        try usage("2026-08-21", tokens: 42).write(to: cloudUsage)
        let token = UsageBackupRestoreToken()
        #expect(
            usageBackupTransferUsage(
                localURL: localUsage, cloudURL: cloudUsage, shouldRestore: true, shouldExport: true,
                restoreToken: token))
        let merged = try Data(contentsOf: localUsage)
        #expect(try merged == Data(contentsOf: cloudUsage))
        let document = try #require(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let days = try #require(document["daily"] as? [[String: Any]])
        #expect(Set(days.compactMap { $0["period"] as? String }) == ["2026-08-20", "2026-08-21"])
        #expect(token.restoredNames == ["usage.json"])
        let unchanged = UsageBackupRestoreToken()
        #expect(
            usageBackupTransferUsage(
                localURL: localUsage, cloudURL: cloudUsage, shouldRestore: true, shouldExport: true,
                restoreToken: unchanged))
        #expect(unchanged.restoredNames.isEmpty)
        let localLimits = local.appendingPathComponent("limits-history.jsonl"),
            cloudLimits = cloud.appendingPathComponent("limits-history.jsonl")
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        try Data(
            LimitsHistory.row(
                session: LimitWindow(percent: 23, resetsAt: nil), week: nil, now: date
            ).line.utf8
        ).write(to: localLimits)
        try Data(
            LimitsHistory.row(
                session: LimitWindow(percent: 42, resetsAt: nil), week: nil,
                now: date.addingTimeInterval(60)
            ).line.utf8
        ).write(to: cloudLimits)
        #expect(
            usageBackupTransferLimits(
                localURL: localLimits, cloudURL: cloudLimits, shouldRestore: true,
                shouldExport: true))
        #expect(try Data(contentsOf: localLimits) == Data(contentsOf: cloudLimits))
        #expect(
            try String(contentsOf: localLimits, encoding: .utf8).split(separator: "\n").count == 2)
    }

    @Test func invalidCloudAndCancelledRestorePreserveLocalHistory() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("usage.json"),
            cloud = root.appendingPathComponent("cloud.json")
        let existing = try usage("2026-08-20", tokens: 23)
        try existing.write(to: local)
        try Data("not a usage document".utf8).write(to: cloud)
        #expect(
            !usageBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: true))
        #expect(try Data(contentsOf: local) == existing)
        try usage("2026-08-21", tokens: 42).write(to: cloud)
        let token = UsageBackupRestoreToken(); token.invalidate()
        #expect(
            !usageBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: true,
                restoreToken: token))
        #expect(try Data(contentsOf: local) == existing)
        try FileManager.default.removeItem(at: cloud)
        try FileManager.default.createSymbolicLink(at: cloud, withDestinationURL: local)
        #expect(
            !usageBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: true))
        #expect(try Data(contentsOf: local) == existing)
    }

    @Test @MainActor func disabledBackupNeverExportsAndEnableOnlyRestoresExistingCloud()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.pulkit.edith.tests.usage-backup-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = root.appendingPathComponent("local"),
            cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let existing = try usage("2026-08-21", tokens: 42)
        try existing.write(to: cloud.appendingPathComponent("usage.json"))
        defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        let provider = UsageBackupProvider(directory: local, cloud: cloud, defaults: defaults)
        let result = try await provider.execute("backup.synchronize", payload: Data())
        #expect(String(decoding: result, as: UTF8.self) == "{\"enabled\":false}")
        #expect(!FileManager.default.fileExists(atPath: local.path))
        #expect(await provider.restoreOnEnable())
        #expect(!FileManager.default.fileExists(atPath: local.path))
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        defaults.set(false, forKey: AppStorageKeys.Backup.usage)
        defaults.set(false, forKey: AppStorageKeys.Backup.limits)
        #expect(await provider.restoreOnEnable())
        #expect(try Data(contentsOf: local.appendingPathComponent("usage.json")) == existing)
        #expect(
            !FileManager.default.fileExists(
                atPath: cloud.appendingPathComponent("limits-history.jsonl").path))
        await provider.shutdown()
        #expect(!(await provider.restoreOnEnable()))
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute("backup.synchronize", payload: Data())
        }
    }

    @Test @MainActor func commandsCannotChoosePathsAndDevelopmentCloudIsIsolated() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.pulkit.edith.tests.usage-backup-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UsageBackupProvider(
            directory: root, cloud: root.appendingPathComponent("cloud"), defaults: defaults)
        await #expect(throws: ExtensionPeerError.self) {
            try await provider.execute(
                "backup.synchronize", payload: Data(#"{"path":"/foreign"}"#.utf8))
        }
        #expect(throws: ExtensionPeerError.self) {
            try UsageBackupProvider.live(environment: [
                "EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.tests.synthetic",
                "EDITH_EXTENSION_DATA_ROOT": "Data/usage",
            ])
        }
        let data = root.appendingPathComponent("Data/usage")
        #expect(
            try UsageBackupProvider.cloudDirectory(
                identifier: "com.pulkit.edith.dev.synthetic", root: data)
                == root.appendingPathComponent("iCloud/data"))
        #expect(throws: ExtensionPeerError.self) {
            try UsageBackupProvider.cloudDirectory(identifier: "foreign", root: data)
        }
        #expect(throws: ExtensionPeerError.self) {
            try UsageBackupProvider.cloudDirectory(identifier: "com.pulkit.edith", root: root)
        }
        await provider.shutdown()
    }

    @Test @MainActor func ownedCompletionEventsExportOnlyChosenClassesAndRestoreBeforeReenable()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.pulkit.edith.tests.usage-scheduling-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        defaults.set(true, forKey: AppStorageKeys.Backup.usage)
        defaults.set(false, forKey: AppStorageKeys.Backup.limits)
        let local = root.appendingPathComponent("local"),
            cloud = root.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let document = local.appendingPathComponent("usage.json")
        let exported = cloud.appendingPathComponent("usage.json")
        try usage("2026-08-20", tokens: 23).write(to: document)
        let provider = UsageBackupProvider(directory: local, cloud: cloud, defaults: defaults)
        provider.startScheduling(debounce: .milliseconds(20))
        await wait { FileManager.default.fileExists(atPath: exported.path) }
        #expect(
            !FileManager.default.fileExists(
                atPath: cloud.appendingPathComponent("limits-history.jsonl").path))
        try usage("2026-08-21", tokens: 42).write(to: document)
        UsageEvents.post(UsageEvents.usageUpdated)
        await wait { (try? Data(contentsOf: document)) == (try? Data(contentsOf: exported)) }
        let saved = try Data(contentsOf: exported)
        defaults.set(false, forKey: AppStorageKeys.Backup.usage)
        provider.preferencesChanged()
        try usage("2026-08-22", tokens: 51).write(to: document)
        UsageEvents.post(UsageEvents.usageUpdated)
        try await Task.sleep(for: .milliseconds(60))
        #expect(try Data(contentsOf: exported) == saved)
        #expect(
            String(
                decoding: try await provider.execute("backup.synchronize", payload: Data()),
                as: UTF8.self) == "{\"enabled\":false}")
        defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        try usage("2026-08-23", tokens: 64).write(to: exported)
        defaults.set(true, forKey: AppStorageKeys.Backup.usage)
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        provider.preferencesChanged()
        await wait {
            guard let data = try? Data(contentsOf: document),
                let cloudData = try? Data(contentsOf: exported)
            else { return false }
            return data == cloudData && String(decoding: data, as: UTF8.self).contains("2026-08-23")
        }
        await provider.shutdown()
        let finished = try Data(contentsOf: exported)
        try usage("2026-08-24", tokens: 80).write(to: document)
        UsageEvents.post(UsageEvents.usageUpdated)
        provider.preferencesChanged()
        try await Task.sleep(for: .milliseconds(60))
        #expect(try Data(contentsOf: exported) == finished)
    }

    @Test @MainActor func unavailableCloudCannotCreateAnAutomaticBackupDirectory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.pulkit.edith.tests.usage-unavailable-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        let cloud = root.appendingPathComponent("unavailable")
        let provider = UsageBackupProvider(
            directory: root, cloud: cloud, defaults: defaults, cloudAvailable: { false })
        provider.startScheduling(debounce: .zero)
        UsageEvents.post(UsageEvents.usageUpdated)
        #expect(await provider.restoreOnEnable())
        #expect(
            String(
                decoding: try await provider.execute("backup.synchronize", payload: Data()),
                as: UTF8.self) == "{\"enabled\":false}")
        await provider.shutdown()
        #expect(!FileManager.default.fileExists(atPath: cloud.path))
    }

    @MainActor private func wait(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(ready())
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-backup-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func usage(_ period: String, tokens: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 8, "generatedAt": "2026-08-25T00:00:00Z", "sources": ["cli"],
            "defaultSources": ["cli"], "sourceMeta": ["cli": ["label": "cli"]], "sessions": [],
            "totals": [
                "cost": 0, "tokens": tokens, "inputTokens": tokens, "outputTokens": 0,
                "cacheCreationTokens": 0, "cacheReadTokens": 0,
                "bySource": ["cli": ["cost": 0, "tokens": tokens]],
            ],
            "daily": [
                [
                    "period": period,
                    "bySource": [
                        "cli": [
                            [
                                "modelName": "fixture", "inputTokens": tokens, "outputTokens": 0,
                                "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": 0,
                            ]
                        ]
                    ],
                    "hours": (0..<24).map {
                        ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
                            as [String: Any]
                    }, "projects": [],
                ]
            ],
        ])
    }
}
