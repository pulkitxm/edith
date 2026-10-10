import EdithExtensionSupport
import Foundation
import Testing
@testable import CodeStatsExtension

@Suite(.serialized) @MainActor struct CodeStatsOriginalCLITests {
    @Test func originalStatusAndScheduleUseTheOwnedWorkflowAndDefaults() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        let old = CodeStatsWorkerOperations.workflow
        CodeStatsWorkerOperations.workflow = workflow
        defer { CodeStatsWorkerOperations.workflow = old }
        let bridge = CodeStatsUIBridge(invoke: {
            try await CodeStatsUIBridge.execute($0, payload: $1, workflow: workflow)
        })
        let suite = "codeStats.remote.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ui = CodeStatsModel(service: bridge.service, remote: bridge, defaults: defaults)
        await ui.loadStatus()
        #expect(ui.status?.settings.folder == harness.mirror.path)
        #expect(defaults.string(forKey: AppStorageKeys.CodeStats.folder) == harness.mirror.path)
        let status = try await CodeStatsCLIExecution.run(.init(arguments: ["status", "--json"]))
        #expect(status.exitCode == 0 && status.stdout.contains(harness.mirror.path))
        let scheduled = try await CodeStatsCLIExecution.run(
            .init(arguments: ["schedule", "weekly", "--weekday", "2", "--hour", "9", "--json"]))
        #expect(scheduled.exitCode == 0 && scheduled.stdout.contains("weekly"))
        #expect(
            CodeStatsPreferences.schedule(in: SharedDefaults.store) == .weekly(weekday: 2, hour: 9))
        let invalid = try await CodeStatsCLIExecution.run(
            .init(arguments: ["schedule", "daily", "--hour", "29"]))
        #expect(invalid.exitCode != 0 && invalid.stderr.contains("between 0 and 23"))
        let help = try await CodeStatsCLIExecution.run(.init(arguments: ["--help"]))
        #expect(
            help.exitCode == 0 && help.stdout.contains("export") && help.stdout.contains("authors"))
        ui.cancelLoading(); await workflow.shutdown()
    }
}
