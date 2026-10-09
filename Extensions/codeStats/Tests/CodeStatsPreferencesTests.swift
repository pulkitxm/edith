import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import Testing

@testable import CodeStatsExtension

@Suite struct CodeStatsPreferencesTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "test.edith.code-stats.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func unsetPreferencesFallBackToAManualScheduleWithArchivedRepositories() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CodeStatsPreferences.load(from: defaults)
        #expect(settings == CodeStatsSettings())
        #expect(settings.includeArchived)
        #expect(!settings.includeForks)
    }

    @Test func schedulesRoundTripThroughTheirKeys() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        CodeStatsPreferences.setSchedule(.weekly(weekday: 6, hour: 22), in: defaults)
        #expect(CodeStatsPreferences.schedule(in: defaults) == .weekly(weekday: 6, hour: 22))
        CodeStatsPreferences.setSchedule(.daily(hour: 7), in: defaults)
        #expect(CodeStatsPreferences.schedule(in: defaults) == .daily(hour: 7))
        #expect(defaults.integer(forKey: AppStorageKeys.CodeStats.scheduleWeekday) == 6)
        CodeStatsPreferences.setSchedule(.manual, in: defaults)
        #expect(CodeStatsPreferences.schedule(in: defaults) == .manual)
    }

    @Test func identitiesSortEmailsFromFragmentsAndIgnoreDuplicates() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(CodeStatsPreferences.addIdentity(" You@Example.com ", in: defaults))
        #expect(CodeStatsPreferences.addIdentity("octocat", in: defaults))
        #expect(!CodeStatsPreferences.addIdentity("you@example.com", in: defaults))
        #expect(!CodeStatsPreferences.addIdentity("OCTOCAT", in: defaults))
        #expect(!CodeStatsPreferences.addIdentity("   ", in: defaults))
        #expect(
            CodeStatsPreferences.identity(in: defaults)
                == CodeStatsIdentity(substrings: ["octocat"], emails: ["You@Example.com"]))
        #expect(CodeStatsPreferences.removeIdentity("you@example.com", in: defaults))
        #expect(!CodeStatsPreferences.removeIdentity("nobody", in: defaults))
        #expect(
            CodeStatsPreferences.identity(in: defaults)
                == CodeStatsIdentity(substrings: ["octocat"]))
    }

    @Test func aConfirmedExternalFolderSurvivesLaunchWhileItsDriveIsAbsent() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let path = "/Volumes/EdithAbsent-\(UUID().uuidString)/GitHub"
        CodeStatsPaths.setFolder(path, defaults: defaults)
        CodeStatsPaths.prepare(defaults: defaults)
        #expect(CodeStatsPaths.selectedFolder(defaults: defaults) == path)
        #expect(CodeStatsPreferences.load(from: defaults).folder == path)
        #expect(
            CodeStatsStorageEvaluator.status(for: path)
                == .volumeDisconnected(volumeName: URL(fileURLWithPath: path).pathComponents[2]))
    }

    @Test func anUnconfirmedExternalFolderIsDroppedAtLaunch() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("/Volumes/Restored/GitHub", forKey: AppStorageKeys.CodeStats.folder)
        #expect(CodeStatsPaths.selectedFolder(defaults: defaults) == nil)
        CodeStatsPaths.prepare(defaults: defaults)
        #expect(defaults.string(forKey: AppStorageKeys.CodeStats.folder) == nil)
    }

    @Test func selectingAFolderRequiresAnExistingDirectory() throws {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "code-stats-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(throws: CodeStatsFolderError.emptyPath) {
            try CodeStatsPreferences.selectFolder(" ", defaults: defaults)
        }
        #expect(throws: CodeStatsFolderError.self) {
            try CodeStatsPreferences.selectFolder(
                root.appendingPathComponent("missing").path, defaults: defaults)
        }
        #expect(throws: CodeStatsFolderError.self) {
            try CodeStatsPreferences.selectFolder(file.path, defaults: defaults)
        }
        let selection = try CodeStatsPreferences.selectFolder(root.path, defaults: defaults)
        #expect(selection.changed)
        #expect(!selection.external)
        #expect(CodeStatsPreferences.load(from: defaults).folder == selection.path)
        #expect(try !CodeStatsPreferences.selectFolder(root.path, defaults: defaults).changed)
    }
}
