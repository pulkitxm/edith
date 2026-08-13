import Foundation
import Testing
@testable import EdithHelper
@testable import EdithKit

@Suite struct SettingsBackupTests {
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
}
