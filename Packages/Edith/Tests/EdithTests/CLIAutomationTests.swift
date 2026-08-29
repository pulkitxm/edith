import Foundation
import Testing

@testable import EdithKit

@Suite(.serialized) struct CLIAutomationTests {
    @Test func listsPlansRunsAndRecordsScenes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-automation-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = AutomationScene(
            name: "System check", actions: [AutomationAction(operationID: "app.info")])
        try AutomationStorage(root: root).save(AutomationDocument(scenes: [scene]))
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_AUTOMATIONS_ROOT"] = root.path

        let list = try CLIProcessProbe.run(
            ["automations", "ls", "--json"], environment: environment)
        #expect(list.code == 0)
        #expect(
            (list.object?["scenes"] as? [[String: Any]])?.first?["name"] as? String == scene.name)

        let plan = try CLIProcessProbe.run(
            ["automations", "plan", scene.name, "--json"], environment: environment)
        #expect(plan.code == 0)
        #expect(plan.object?["runnable"] as? Bool == true)
        #expect(
            (plan.object?["steps"] as? [[String: Any]])?.first?["operation"] as? String
                == "app.info")

        let dryRun = try CLIProcessProbe.run(
            ["automations", "run", scene.name, "--dry-run", "--json"],
            environment: environment)
        #expect(dryRun.code == 0)
        #expect(dryRun.object?["dryRun"] as? Bool == true)

        let run = try CLIProcessProbe.run(
            ["automations", "run", scene.name, "--json"], environment: environment)
        #expect(run.code == 0)
        #expect(
            (run.object?["steps"] as? [[String: Any]])?.first?["state"] as? String == "succeeded")

        let history = try CLIProcessProbe.run(
            ["automations", "history", "--json"], environment: environment)
        #expect(history.code == 0)
        #expect((history.array?.first as? [String: Any])?["sceneName"] as? String == scene.name)
    }

    @Test func togglesAndImportsOnlyWithApproval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ed-automation-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = AutomationScene(
            name: "System check", actions: [AutomationAction(operationID: "app.info")])
        let storage = AutomationStorage(root: root)
        try storage.save(AutomationDocument(scenes: [scene]))
        let source = root.appendingPathComponent("source.json")
        try storage.export(to: source)
        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_AUTOMATIONS_ROOT"] = root.path

        let disable = try CLIProcessProbe.run(
            ["automations", "disable", scene.name, "--json"], environment: environment)
        #expect(disable.code == 0)
        #expect(try storage.load().scenes.first?.isEnabled == false)

        let rejected = try CLIProcessProbe.run(
            ["automations", "import", source.path, "--json"], environment: environment)
        #expect(rejected.code != 0)

        let dryRun = try CLIProcessProbe.run(
            ["automations", "import", source.path, "--dry-run", "--json"],
            environment: environment)
        #expect(dryRun.code == 0)
        #expect(try storage.load().scenes.first?.isEnabled == false)

        let imported = try CLIProcessProbe.run(
            ["automations", "import", source.path, "--yes", "--json"],
            environment: environment)
        #expect(imported.code == 0)
        #expect(try storage.load().scenes.first?.isEnabled == true)
    }
}
