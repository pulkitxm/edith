import Foundation
import Testing
@testable import EdithHelper
@testable import EdithKit

@Suite struct SettingsBackupTests {
    private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    private func usage(period: String, source: String) throws -> Data {
        let hours: [[String: Any]] = (0..<24).map {
            ["hour": $0, "cost": 0, "tokens": 0, "bySource": [:], "byPath": [:]]
        }
        return try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8,
                "generatedAt": "2026-08-25T00:00:00Z",
                "sources": [source],
                "defaultSources": [source],
                "sourceMeta": [source: ["label": source]],
                "machines": [],
                "sessions": [],
                "totals": [
                    "cost": 0, "tokens": 1, "inputTokens": 1, "outputTokens": 0,
                    "cacheCreationTokens": 0, "cacheReadTokens": 0,
                    "bySource": [source: ["cost": 0, "tokens": 1]],
                ],
                "daily": [
                    [
                        "period": period,
                        "bySource": [
                            source: [
                                [
                                    "modelName": "model", "inputTokens": 1,
                                    "outputTokens": 0, "cacheCreationTokens": 0,
                                    "cacheReadTokens": 0, "cost": 0,
                                ]
                            ]
                        ],
                        "hours": hours,
                        "projects": [],
                    ]
                ],
            ])
    }

    @Test func everyAppStoragePreferenceIsBackedUpOrDeviceLocal() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        let regex = try NSRegularExpression(pattern: #"@AppStorage\("([^"]+)""#)
        var keys = Set<String>()
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        let covered = Set(SettingsBackup.backedKeys).union(SettingsBackup.deviceLocalKeys)
        #expect(keys.subtracting(covered).isEmpty)
        #expect(
            keys.intersection(SettingsBackup.backedKeys).isSubset(of: SettingsBackup.sharedKeys))
    }

    static func sourceFiles() -> [String] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        var sources: [String] = []
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            sources.append(source)
        }
        return sources
    }

    static func matches(_ pattern: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        var keys = Set<String>()
        for source in sourceFiles() {
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(String(source[keyRange]))
            }
        }
        return keys
    }

    @Test func everyDirectlyWrittenPreferenceIsBackedUpOrDeviceLocal() throws {
        let keys = try Self.matches(#"store\.set\([^\n]*forKey:\s*"([^"]+)"\)"#)
            .filter { !$0.contains("\\(") }
        let covered = Set(SettingsBackup.backedKeys).union(SettingsBackup.deviceLocalKeys)
        #expect(!keys.isEmpty)
        #expect(keys.subtracting(covered).isEmpty)
        #expect(
            keys.intersection(SettingsBackup.backedKeys).isSubset(of: SettingsBackup.sharedKeys))
    }

    @Test func everyRecordedShortcutIsBackedUp() throws {
        let prefixes = try Self.matches(#"HotKeyRecorderControl\(keyPrefix:\s*"([^"]+)""#)
        #expect(prefixes.count >= 5)
        for prefix in prefixes {
            for suffix in ["Code", "Mods", "Label"] {
                let key = prefix + suffix
                #expect(
                    SettingsBackup.backedKeys.contains(key),
                    "\(key) is not backed up, so the shortcut is lost on reinstall")
                #expect(SettingsBackup.sharedKeys.contains(key), "\(key) reads the wrong suite")
            }
        }
    }

    @Test func backedKeysHasNoDuplicateEntries() {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for key in SettingsBackup.backedKeys where !seen.insert(key).inserted {
            duplicates.insert(key)
        }
        #expect(duplicates.isEmpty, "backedKeys repeats: \(duplicates)")
    }

    @Test func iCloudBackupIsOnOutOfTheBox() {
        let defaults = UserDefaults(suiteName: "test.icloud.default")!
        defaults.removePersistentDomain(forName: "test.icloud.default")
        defaults.register(defaults: SharedDefaults.registeredDefaults)
        #expect(defaults.bool(forKey: OnboardingFlow.iCloudBackupKey))
        #expect(OnboardingFlow.initialICloudBackup)
        OnboardingFlow.skip(defaults: defaults)
        #expect(defaults.bool(forKey: OnboardingFlow.iCloudBackupKey))
        defaults.removePersistentDomain(forName: "test.icloud.default")
    }

    @Test func finishingOnboardingWithoutACloudBackupStillEnablesIt() {
        let defaults = UserDefaults(suiteName: "test.icloud.finish")!
        defaults.removePersistentDomain(forName: "test.icloud.finish")
        OnboardingFlow.finish(selectedIDs: [], defaults: defaults)
        #expect(defaults.bool(forKey: OnboardingFlow.iCloudBackupKey))
        defaults.removePersistentDomain(forName: "test.icloud.finish")
    }

    @Test func sweepKeepsBackupsCurrentWithoutNotifications() {
        #expect(SettingsBackup.sweepInterval > 0)
        #expect(SettingsBackup.sweepInterval <= 60)
    }

    @Test func configurableNonAppStoragePreferencesAreBackedUp() {
        let expected: Set<String> = [
            "micHotKeyCode", "micHotKeyMods", "micHotKeyLabel", "notchAudioMixerEnabled",
        ]
        #expect(expected.isSubset(of: Set(SettingsBackup.backedKeys)))
        #expect(expected.isSubset(of: SettingsBackup.sharedKeys))
    }

    @Test func restoreProgressPreferencesAreDeviceLocal() {
        let expected: Set<String> = [
            "restorePending.usage", "restorePending.limits", "restorePending.music",
            "restorePending.clipboard", "restoreTimedOut.usage", "restoreTimedOut.limits",
            "restoreTimedOut.music", "restoreTimedOut.clipboard",
        ]
        #expect(expected.isSubset(of: SettingsBackup.deviceLocalKeys))
        #expect(expected.isDisjoint(with: SettingsBackup.backedKeys))
    }

    @Test func transferDecisionMatrix() {
        for dataClass in SettingsBackupDataClass.allCases {
            for masterEnabled in [false, true] {
                for subToggleEnabled in [false, true] {
                    for extensionEnabled in [false, true] {
                        let decision = settingsBackupTransferDecision(
                            for: dataClass,
                            masterEnabled: masterEnabled,
                            subToggleEnabled: subToggleEnabled,
                            extensionEnabled: extensionEnabled)
                        let shouldRestore = masterEnabled && subToggleEnabled
                        #expect(decision.shouldRestore == shouldRestore)
                        #expect(
                            decision.shouldExport == (shouldRestore && extensionEnabled))
                    }
                }
            }
        }
    }

    @Test func enableTimeRestoreDecisionMatrix() {
        let extensionDataClasses: [SettingsBackupDataClass] = [
            .usage, .limits, .music, .clipboard,
        ]
        for dataClass in extensionDataClasses {
            for cloudDataExists in [false, true] {
                for masterEnabled in [false, true] {
                    #expect(
                        settingsBackupEnableRestoreDecision(
                            for: dataClass, cloudDataExists: cloudDataExists,
                            masterEnabled: masterEnabled) == cloudDataExists)
                }
            }
        }
    }

    @Test func missingCloudNamesExcludeExistingLocalNames() {
        let missing = settingsBackupMissingNames(
            cloudNames: ["one.mp3", "two.mp3", "nested/three.m4a"],
            localNames: ["two.mp3", "local-only.mp3"])
        #expect(missing == ["one.mp3", "nested/three.m4a"])
    }

    @Test func pendingRestoreStateTracksUniqueCompletions() {
        var state = SettingsBackupPendingState(["one.mp3", "two.mp3"])
        #expect(state.remaining.count == 2)
        state.complete("one.mp3")
        #expect(state.remaining == ["two.mp3"])
        state.complete("one.mp3")
        #expect(state.remaining == ["two.mp3"])
        state.complete("two.mp3")
        #expect(state.remaining.isEmpty)
    }

    @Test func replacementRestoreInvalidatesEveryOlderContinuation() {
        var state = SettingsBackupRestoreGenerationState()
        let first = state.begin(.usage)
        let replacement = state.begin(.usage)
        #expect(!state.accepts(first, for: .usage))
        #expect(state.accepts(replacement, for: .usage))
        state.invalidate(.usage)
        #expect(!state.accepts(replacement, for: .usage))
    }

    @Test func settingsImportSurvivesLeftoverLocalFileOnReinstall() {
        let now = Date()
        let staleCloud = now.addingTimeInterval(-3600)

        #expect(
            settingsBackupShouldImport(
                localFileExists: false, freshInstall: true, cloudDate: staleCloud, localDate: now))
        #expect(
            settingsBackupShouldImport(
                localFileExists: true, freshInstall: true, cloudDate: staleCloud, localDate: now))
        #expect(
            !settingsBackupShouldImport(
                localFileExists: true, freshInstall: false, cloudDate: staleCloud, localDate: now))
        #expect(
            settingsBackupShouldImport(
                localFileExists: true, freshInstall: false, cloudDate: now,
                localDate: now.addingTimeInterval(-10)))
        #expect(
            !settingsBackupShouldImport(
                localFileExists: true, freshInstall: false, cloudDate: now,
                localDate: now.addingTimeInterval(-1)))
    }

    @Test func restoredPathValidationMatrix() {
        let home = URL(fileURLWithPath: "/Users/example")
        let cases: [(String, RestoredPathVerdict)] = [
            ("/", .keep),
            ("/Library/Application Support/Edith", .keep),
            ("/Users/example", .keep),
            ("/Users/example/Music", .keep),
            ("/Volumes/X", .drop),
            ("/Volumes/X/Music", .drop),
        ]
        for (path, expected) in cases {
            #expect(RestoredPathValidation.verdict(for: path, homeDirectory: home) == expected)
        }
    }

    @Test func limitsRestoreRereadsLocalHistoryInsideTheMutationLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("limits-history.jsonl")
        let cloud = root.appendingPathComponent("cloud/limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let localRow = LimitsHistory.row(
            session: LimitWindow(percent: 10, resetsAt: nil), week: nil, now: now)
        let cloudRow = LimitsHistory.row(
            session: LimitWindow(percent: 20, resetsAt: nil), week: nil,
            now: now.addingTimeInterval(60))
        try Data(localRow.line.utf8).write(to: local)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(cloudRow.line.utf8).write(to: cloud)
        let held = try UsageDataLock.acquire(dataDirectory: data)
        let reachedDataLock = DispatchSemaphore(value: 0)

        let restore = Task.detached {
            settingsBackupTransferLimits(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: false,
                willAcquireDataLock: { reachedDataLock.signal() })
        }
        #expect(await waitForSignal(reachedDataLock))
        let append = Task.detached {
            var history = LimitsHistory(url: local)
            history.append(
                session: LimitWindow(percent: 30, resetsAt: nil), week: nil,
                now: now.addingTimeInterval(120))
        }

        held.release()
        #expect(await restore.value)
        await append.value
        #expect(LimitsHistory.loadAll(url: local).map(\.s) == [10, 20, 30])
    }

    @Test func progressiveRestoreWaitsForAnActiveRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("limits-history.jsonl")
        let cloud = root.appendingPathComponent("cloud/limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let original = LimitsHistory.row(
            session: LimitWindow(percent: 10, resetsAt: nil), week: nil, now: Date())
        let incoming = LimitsHistory.row(
            session: LimitWindow(percent: 20, resetsAt: nil), week: nil, now: Date())
        try Data(original.line.utf8).write(to: local)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(incoming.line.utf8).write(to: cloud)
        let refresh = try #require(
            UsageRefreshLock.acquire(at: UsageRefreshRunner.transactionURL(dataDir: data)))
        defer { refresh.release() }

        #expect(
            !settingsBackupTransferLimits(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: false))
        #expect(LimitsHistory.loadAll(url: local).map(\.s) == [10])
    }

    @Test func malformedCloudUsageAndLimitsRemainPending() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let malformedUsage = Data(#"{"daily":[{}]}"#.utf8)
        let malformedLimits = Data("not json\n".utf8)
        let cloudUsage = root.appendingPathComponent("cloud/usage.json")
        let cloudLimits = root.appendingPathComponent("cloud/limits-history.jsonl")
        try FileManager.default.createDirectory(
            at: cloudUsage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try malformedUsage.write(to: cloudUsage)
        try malformedLimits.write(to: cloudLimits)

        #expect(
            !settingsBackupTransferUsage(
                localURL: data.appendingPathComponent("usage.json"),
                cloudURL: cloudUsage, shouldRestore: true, shouldExport: false))
        #expect(
            !settingsBackupTransferLimits(
                localURL: data.appendingPathComponent("limits-history.jsonl"),
                cloudURL: cloudLimits, shouldRestore: true, shouldExport: false))
        #expect(
            !FileManager.default.fileExists(atPath: data.appendingPathComponent("usage.json").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: data.appendingPathComponent("limits-history.jsonl").path))
    }

    @Test func validCloudUsageRepairsMalformedLocalUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("usage.json")
        let cloud = root.appendingPathComponent("cloud/usage.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"daily":[]}"#.utf8).write(to: local)
        try usage(period: "2026-08-20", source: "cloud").write(to: cloud)

        #expect(
            settingsBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: false))
        #expect(UsageHistory.isValidDocument(try Data(contentsOf: local)))
    }

    @Test func cloudTransferRereadsTheCoordinatedRevisionAfterWaitingForLocalData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("usage.json")
        let cloud = root.appendingPathComponent("cloud/usage.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try usage(period: "2026-08-20", source: "local").write(to: local)
        try usage(period: "2026-08-21", source: "cloud-one").write(to: cloud)
        let held = try UsageDataLock.acquire(dataDirectory: data)
        let reachedDataLock = DispatchSemaphore(value: 0)

        let transfer = Task.detached {
            settingsBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: true,
                willAcquireDataLock: { reachedDataLock.signal() })
        }
        #expect(await waitForSignal(reachedDataLock))
        try usage(period: "2026-08-22", source: "cloud-two").write(
            to: cloud, options: .atomic)

        held.release()
        #expect(await transfer.value)
        for url in [local, cloud] {
            let bytes = try Data(contentsOf: url)
            let object = try #require(
                try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            let daily = try #require(object["daily"] as? [[String: Any]])
            #expect(
                daily.compactMap { $0["period"] as? String }
                    == ["2026-08-20", "2026-08-22"])
        }
    }

    @Test func usageBackupLockContentionNeverBlocksTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("usage.json")
        let cloud = root.appendingPathComponent("cloud/usage.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try usage(period: "2026-08-20", source: "local").write(to: local)
        try usage(period: "2026-08-21", source: "cloud").write(to: cloud)
        let held = try UsageDataLock.acquire(dataDirectory: data)
        let reachedDataLock = DispatchSemaphore(value: 0)

        let transfer = Task { @MainActor in
            await SettingsBackupUsageWorker.shared.transferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: false,
                backupEnabled: true, requireCloudAvailability: false,
                willAcquireDataLock: { reachedDataLock.signal() })
        }
        #expect(await waitForSignal(reachedDataLock))
        let responsive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Task { @MainActor in true }.value
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(responsive)
        held.release()
        #expect(await transfer.value)
    }

    @Test func undownloadedCloudPlaceholderPreventsUsagePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("usage.json")
        let cloud = root.appendingPathComponent("cloud/usage.json")
        let placeholder = cloud.deletingLastPathComponent().appendingPathComponent(
            ".usage.json.icloud")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        try usage(period: "2026-08-20", source: "local").write(to: local)
        try Data("placeholder".utf8).write(to: placeholder)

        #expect(
            await SettingsBackupUsageWorker.shared.transferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: true,
                backupEnabled: true, requireCloudAvailability: false) == false)
        #expect(!FileManager.default.fileExists(atPath: cloud.path))
    }

    @Test func supersededUsageRestoreCannotCommitAfterWaitingForTheDataLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let local = data.appendingPathComponent("usage.json")
        let cloud = root.appendingPathComponent("cloud/usage.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloud.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try usage(period: "2026-08-20", source: "local")
        try original.write(to: local)
        try usage(period: "2026-08-21", source: "cloud").write(to: cloud)
        let held = try UsageDataLock.acquire(dataDirectory: data)
        let reachedDataLock = DispatchSemaphore(value: 0)
        let token = SettingsBackupRestoreToken()
        let transfer = Task.detached {
            settingsBackupTransferUsage(
                localURL: local, cloudURL: cloud, shouldRestore: true, shouldExport: false,
                willAcquireDataLock: { reachedDataLock.signal() }, restoreToken: token)
        }
        #expect(await waitForSignal(reachedDataLock))
        token.invalidate()
        held.release()
        #expect(await transfer.value == false)
        #expect(try Data(contentsOf: local) == original)
    }

    @Test func terminationPersistenceRetriesBothExportsAfterRefreshContention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let data = root.appendingPathComponent("data")
        let localUsage = data.appendingPathComponent("usage.json")
        let localLimits = data.appendingPathComponent("limits-history.jsonl")
        let cloudUsage = root.appendingPathComponent("cloud/usage.json")
        let cloudLimits = root.appendingPathComponent("cloud/limits-history.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try usage(period: "2026-08-25", source: "local").write(to: localUsage)
        let row = LimitsHistory.row(
            session: LimitWindow(percent: 10, resetsAt: nil), week: nil, now: Date())
        try Data(row.line.utf8).write(to: localLimits)
        let refresh = try #require(
            UsageRefreshLock.acquire(at: UsageRefreshRunner.transactionURL(dataDir: data)))
        defer { refresh.release() }
        let clock = ContinuousClock()
        let intents = SettingsBackupPersistenceIntents(limitsExport: true, usageExport: true)

        let flush = Task {
            await settingsBackupRetryPersistence(
                intents, deadline: clock.now.advanced(by: .seconds(2)),
                retryInterval: .milliseconds(20),
                transferLimits: { restore, export in
                    await SettingsBackupUsageWorker.shared.transferLimits(
                        localURL: localLimits, cloudURL: cloudLimits, shouldRestore: restore,
                        shouldExport: export, backupEnabled: true,
                        requireCloudAvailability: false)
                },
                transferUsage: { restore, export in
                    await SettingsBackupUsageWorker.shared.transferUsage(
                        localURL: localUsage, cloudURL: cloudUsage, shouldRestore: restore,
                        shouldExport: export, backupEnabled: true,
                        requireCloudAvailability: false)
                })
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: cloudLimits.path))
        #expect(!FileManager.default.fileExists(atPath: cloudUsage.path))

        refresh.release()
        #expect(await flush.value.isEmpty)
        #expect(LimitsHistory.loadAll(url: cloudLimits).map(\.s) == [10])
        #expect(UsageHistory.isValidDocument(try Data(contentsOf: cloudUsage)))
    }

    @Test func settingsComparisonRejectsFIFOWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let fifo = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let clock = ContinuousClock()
        let started = clock.now

        #expect(settingsBackupReadSettingsFile(at: fifo, maximumBytes: 64) == nil)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test func settingsComparisonNeverFollowsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target.json")
        let link = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("target".utf8).write(to: target)
        try #require(symlink(target.path, link.path) == 0)

        #expect(settingsBackupReadSettingsFile(at: link, maximumBytes: 64) == nil)
    }

    @Test func settingsComparisonRejectsOversizedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let file = root.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 65).write(to: file)

        #expect(settingsBackupReadSettingsFile(at: file, maximumBytes: 64) == nil)
    }

    @Test @MainActor func finalSettingsExportPublishesAfterCancelledOlderExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-settings-backup-\(UUID().uuidString)")
        let file = root.appendingPathComponent("settings.json")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let older = Data("older".utf8)
        let final = Data("final".utf8)
        defer {
            release.signal()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = Task.detached {
            started.signal()
            _ = await waitForSignal(release)
            try? older.write(to: file, options: .atomic)
        }
        #expect(await waitForSignal(started))
        let generation = 1

        let publication = Task { @MainActor in
            guard
                await settingsBackupAwaitFinalSettingsExport(
                    after: previous, generation: generation,
                    ownsGeneration: { $0 == generation })
            else { return false }
            var pending: Data? = final
            var published = false
            await settingsBackupDrainSettingsExports(
                generation: generation, ownsGeneration: { $0 == generation },
                takePending: {
                    defer { pending = nil }
                    return pending
                },
                publish: { data in
                    do {
                        try data.write(to: file, options: .atomic)
                        return true
                    } catch {
                        return false
                    }
                },
                didPublish: { published = $0 })
            return published
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(previous.isCancelled)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        release.signal()
        #expect(await publication.value)
        #expect(settingsBackupReadSettingsFile(at: file, maximumBytes: 64) == final)
    }

    @Test @MainActor func finalSettingsExportRepublishesSnapshotQueuedDuringWrite() async {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let initial = Data("initial".utf8)
        let newest = Data("newest".utf8)
        var pending: Data? = initial
        var published: [Data] = []
        let generation = 1
        defer { release.signal() }

        let publication = Task { @MainActor in
            await settingsBackupDrainSettingsExports(
                generation: generation, ownsGeneration: { $0 == generation },
                takePending: {
                    defer { pending = nil }
                    return pending
                },
                publish: { data in
                    published.append(data)
                    if published.count == 1 {
                        started.signal()
                        _ = await waitForSignal(release)
                    }
                    return true
                },
                didPublish: { _ in })
        }
        #expect(await waitForSignal(started))
        pending = newest
        release.signal()

        await publication.value
        #expect(published == [initial, newest])
        #expect(pending == nil)
    }

    @Test func terminationPersistenceDeadlineReturnsEveryUnfinishedIntent() async {
        let clock = ContinuousClock()
        let started = clock.now
        let intents = SettingsBackupPersistenceIntents(limitsExport: true, usageExport: true)

        let remaining = await settingsBackupRetryPersistence(
            intents, deadline: started.advanced(by: .milliseconds(50)),
            retryInterval: .milliseconds(10),
            transferLimits: { _, _ in false },
            transferUsage: { _, _ in false })

        #expect(remaining == intents)
        #expect(started.duration(to: clock.now) < .seconds(1))
    }

    @Test func cancellingTerminationPersistencePreservesItsIntent() async {
        let intents = SettingsBackupPersistenceIntents(usageExport: true)
        let task = Task {
            await settingsBackupRetryPersistence(
                intents, deadline: ContinuousClock().now.advanced(by: .seconds(2)),
                retryInterval: .seconds(1),
                transferLimits: { _, _ in false },
                transferUsage: { _, _ in false })
        }

        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()

        #expect(await task.value == intents)
    }
}
