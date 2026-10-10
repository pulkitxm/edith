import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageStatusLineCommandTests {
    @Test func recordAndConnectionCommandsUseOnlyOwnedFiles() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let history = root.appendingPathComponent("limits.jsonl")
        let defaults = try #require(UserDefaults(suiteName: "usage-command.\(UUID().uuidString)"))
        let service = UsageStatusLineCommands(
            settings: settings, history: history, executable: "/fixture/Edith", defaults: defaults)
        let change = try JSONDecoder().decode(
            UsageStatusLineChangeResponse.self,
            from: await service.execute("usage.statusline.install", payload: Data("{}".utf8)))
        #expect(change.change == "installed")
        #expect(
            ClaudeStatusLine.installedCommand(settings: settings)
                == "'/fixture/Edith' invoke usage usage.statusline.hook --json - --raw")
        let input = Data(
            #"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":4102444800}}}"#.utf8)
        let result = try JSONDecoder().decode(
            String.self,
            from: await service.execute(
                "usage.statusline.hook",
                payload: input))
        #expect(result == "5h 42%")
        #expect(LimitsHistory.latest(provider: .claude, url: history)?.session?.percent == 42)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(
            UsageStatusLineStatusResponse.self,
            from: await service.execute("usage.statusline.status", payload: Data("{}".utf8)))
        #expect(status.installed)
        #expect(status.recordedAt != nil)
        let removed = try JSONDecoder().decode(
            UsageStatusLineChangeResponse.self,
            from: await service.execute("usage.statusline.remove", payload: Data("{}".utf8)))
        #expect(removed.change == "removed")
        #expect(!ClaudeStatusLine.isInstalled(settings: settings))
    }

    @Test(arguments: [
        "usage.statusline.status", "usage.statusline.install", "usage.statusline.remove",
        "usage.statusline.hook",
    ])
    func arbitraryPathsAndCommandsAreRejected(command: String) async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("settings.json")
        let service = UsageStatusLineCommands(
            settings: settings, history: root.appendingPathComponent("limits.jsonl"))
        let forged = Data(
            #"{"settings":"/fixture/outside","executable":"/bin/sh","input":"e30="}"#.utf8)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(command, payload: forged)
        }
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    @Test func oversizedAndCancelledRequestsWriteNothing() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("limits.jsonl")
        let service = UsageStatusLineCommands(
            settings: root.appendingPathComponent("settings.json"), history: history)
        let oversized = Data(repeating: 32, count: 512 * 1_024 + 1)
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await service.execute(
                "usage.statusline.hook", payload: oversized)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.execute(
                "usage.statusline.hook", payload: Data(#"{"input":"e30="}"#.utf8))
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: history.path))
    }

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "usage-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
