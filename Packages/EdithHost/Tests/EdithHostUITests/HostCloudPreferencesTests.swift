import EdithExtensionSupport
import EdithHostCore
import Foundation
import Testing

@testable import EdithHost

@Suite @MainActor struct HostCloudPreferencesTests {
    @Test func automaticBackupWaitsForLocalOnboardingReviewAndHonorsBothOptOuts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = try fixture.preferences()
        #expect(!preferences.readyForSettingsBackup)
        fixture.application.set(true, forKey: HostSettingsCatalog.onboardingCompletedKey)
        #expect(preferences.readyForSettingsBackup)
        fixture.application.set(true, forKey: HostSettingsCatalog.onboardingReviewPendingKey)
        #expect(!preferences.readyForSettingsBackup)
        fixture.application.set(false, forKey: HostSettingsCatalog.onboardingReviewPendingKey)
        #expect(preferences.readyForSettingsBackup)
        preferences.set(.settings, enabled: false)
        #expect(!preferences.readyForSettingsBackup)
        preferences.set(.settings, enabled: true)
        preferences.set(.icloud, enabled: false)
        #expect(!preferences.readyForSettingsBackup)
    }

    @Test func originalBackupDefaultsKeepLargeExtensionBackupsOptIn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = try fixture.preferences()
        for option in [HostCloudPreferences.Option.icloud, .settings, .usage, .limits] {
            #expect(preferences.enabled(option))
        }
        #expect(!preferences.enabled(.music))
        #expect(!preferences.enabled(.clipboard))
        #expect(preferences.lastBackup(.settings) == nil)
    }

    @Test func extensionBackupControlsWriteOnlyTheOwningPreferencesSuite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = try fixture.preferences()
        preferences.set(.music, enabled: true)
        preferences.set(.clipboard, enabled: true)
        preferences.set(.settings, enabled: false)
        #expect(preferences.music.bool(forKey: AppStorageKeys.Music.backup))
        #expect(preferences.clipboard.bool(forKey: AppStorageKeys.Clipboard.backup))
        #expect(fixture.application.object(forKey: AppStorageKeys.Music.backup) == nil)
        #expect(fixture.application.object(forKey: AppStorageKeys.Clipboard.backup) == nil)
        #expect(!fixture.application.bool(forKey: AppStorageKeys.Backup.settings))
        #expect(
            fixture.control.stringArray(forKey: HostExtensionSessions.enabledExtensionsKey) == nil)
        #expect(preferences.enabled(.icloud))
    }

    @Test func timestampsComeFromActualOwningBackupsAndRejectInvalidDates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let preferences = try fixture.preferences()
        fixture.application.set(101, forKey: AppStorageKeys.Backup.lastBackupAt)
        preferences.music.set(202, forKey: AppStorageKeys.Music.lastBackupAt)
        preferences.clipboard.set(303, forKey: AppStorageKeys.Clipboard.lastBackupAt)
        #expect(preferences.lastBackup(.settings)?.timeIntervalSince1970 == 101)
        #expect(preferences.lastBackup(.music)?.timeIntervalSince1970 == 202)
        #expect(preferences.lastBackup(.clipboard)?.timeIntervalSince1970 == 303)
        preferences.music.set(Double.infinity, forKey: AppStorageKeys.Music.lastBackupAt)
        #expect(preferences.lastBackup(.music) == nil)
    }

    private struct Fixture {
        let identity: HostIdentity
        let application: UserDefaults
        let control: UserDefaults
        init() throws {
            identity = try HostIdentity(
                identifier: "com.pulkit.edith.tests.cloud-" + UUID().uuidString,
                supportDirectory: URL(fileURLWithPath: "/synthetic/support"))
            application = try #require(
                SharedDefaults.applicationStore(identifier: identity.identifier))
            control = try #require(UserDefaults(suiteName: identity.defaultsSuite))
        }
        @MainActor func preferences() throws -> HostCloudPreferences {
            try HostCloudPreferences(identity: identity, application: application)
        }
        func remove() {
            for name in [
                identity.identifier, identity.defaultsSuite,
                identity.extensionDefaultsSuite("music"),
                identity.extensionDefaultsSuite("clipboard"),
            ] {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
    }
}
