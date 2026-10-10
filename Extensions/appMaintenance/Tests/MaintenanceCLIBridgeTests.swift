import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing
@testable import AppMaintenanceExtension

@Suite(.serialized) @MainActor struct MaintenanceCLIBridgeTests {
    @Test func originalCommandTreeAndPolicyPreviewPreserveOutput() async throws {
        for args in [
            ["--help"], ["updates", "--help"], ["install", "--help"], ["remove", "--help"],
            ["scan", "--help"],
        ] {
            let help = try await MaintenanceCLIExecution.run(.init(arguments: args))
            #expect(help.exitCode == 0 && help.stdout.contains("USAGE:") && help.stderr.isEmpty)
        }
        let invalid = try await MaintenanceCLIExecution.run(
            .init(arguments: ["scan", "/synthetic/missing.app", "--json"]))
        #expect(invalid.exitCode != 0 && invalid.stdout.isEmpty && !invalid.stderr.isEmpty)
    }
    @Test func originalPreferencesValidateAndPersistInOwningDefaults() async throws {
        let suite = "synthetic.maintenance.preferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = AppMaintenanceModel(
            defaults: defaults, inventory: { _ in [] }, discover: { _, _, _, _ in [] })
        var settings = MaintenanceUISettings(); settings.notifications = false;
        settings.autoRefresh = true; settings.concurrency = 3
        let data = try await AppMaintenanceUICommands.execute(
            "maintenance.ui.preferences", payload: JSONEncoder().encode(settings), model: owner)
        let result = try JSONDecoder().decode(AppMaintenanceUISnapshot.self, from: data)
        #expect(
            result.preferences == settings
                && defaults.bool(forKey: MaintenancePreferences.updateAutoRefresh)
                && !defaults.bool(forKey: MaintenancePreferences.updateNotifications))
        settings.concurrency = 99
        await #expect(throws: ExtensionPeerError.self) {
            try await AppMaintenanceUICommands.execute(
                "maintenance.ui.preferences", payload: JSONEncoder().encode(settings), model: owner)
        }
        #expect(defaults.integer(forKey: MaintenancePreferences.updateConcurrency) == 3)
        await owner.shutdown()
        await #expect(throws: ExtensionPeerError.self) {
            try await AppMaintenanceUICommands.execute(
                "maintenance.ui.snapshot", payload: Data("{}".utf8), model: owner)
        }
    }
}
