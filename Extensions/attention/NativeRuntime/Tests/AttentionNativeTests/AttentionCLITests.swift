import EdithExtensionSupport_attention_native
import Foundation
import Testing

@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionCLITests {
    @Test func originalReadonlyCommandsAndFocusConsumeOwnedModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        var settings = AttentionSettings()
        settings.isEnabled = false
        try repository.saveSettings(settings)
        try repository.append(
            AttentionEvent(
                id: "fixture-editor", startedAt: Date().addingTimeInterval(-120), duration: 60,
                source: .application, appName: "Fixture Editor", bundleID: "example.editor"))
        func run(_ arguments: [String]) async throws -> ExtensionCLIReply {
            try await AttentionCLIExecution.run(.init(arguments: arguments), repository: repository)
        }
        let summary = try await run(["summary", "--range", "24h", "--json"])
        #expect(summary.exitCode == 0)
        #expect(summary.stderr.isEmpty)
        #expect(summary.stdout.contains("Fixture Editor"))
        for command in ["breakdown", "agents", "timeline", "music"] {
            let result = try await run([command, "--range", "24h", "--json"])
            #expect(result.exitCode == 0)
            #expect(result.stderr.isEmpty)
            #expect(!result.stdout.isEmpty)
        }
        let categories = try await run([
            "categories", "set", "app:example.editor", "focus", "--name", "Mock Editor", "--json",
        ])
        #expect(categories.exitCode == 0)
        #expect(repository.loadSettings().rules.contains { $0.name == "Mock Editor" })
        let exported = try await run(["rules", "export"])
        let document = root.appendingPathComponent("mock-rules.json")
        try Data(exported.stdout.utf8).write(to: document)
        let imported = try await run(["rules", "import", document.path, "--dry-run", "--json"])
        #expect(imported.exitCode == 0)
        #expect(
            (try JSONSerialization.jsonObject(with: Data(imported.stdout.utf8)) as? [String: Any])?[
                "saved"] as? Bool == false)
        let relative = try await AttentionCLIExecution.run(
            .init(
                arguments: ["rules", "import", "mock-rules.json", "--dry-run", "--json"],
                workingDirectory: root.path), repository: repository)
        #expect(relative.exitCode == 0)
        #expect(FileManager.default.currentDirectoryPath != root.path)
        let start = try await run(["focus", "start", "--for", "25m", "--name", "Mock focus"])
        #expect(start.stdout == "focus started: Mock focus, 25m\n")
        #expect(repository.activeFocus()?.plannedDuration == 1500)
        let status = try await run(["focus", "status"])
        #expect(status.stdout == "Mock focus, planned 25m\n")
        let end = try await run(["focus", "end", "--json"])
        #expect(end.exitCode == 0)
        #expect(repository.activeFocus() == nil)
        let token = try await run(["extension", "token"])
        #expect(token.stdout == settings.serverToken + "\n")
        let invalid = try await run(["summary", "--range", "invalid"])
        #expect(invalid.exitCode == 2)
        #expect(invalid.stdout.isEmpty)
        #expect(invalid.stderr.contains("not an attention range"))
        let missing = try await run(["categories", "set", "app:example.editor", "missing"])
        #expect(missing.exitCode == 3)
        let backup = try await run(["backup", "--json"])
        #expect(backup.exitCode == 4)
        let restore = try await run(["restore", "--json"])
        #expect(restore.exitCode == 0)
        #expect(
            (try JSONSerialization.jsonObject(with: Data(restore.stdout.utf8)) as? [String: Any])?[
                "applied"] as? Bool == false)
    }
}
