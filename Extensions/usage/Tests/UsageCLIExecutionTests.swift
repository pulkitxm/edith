import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageCLIExecutionTests {
    private func run(_ arguments: [String], controller: UsageWorkerController, input: Data = Data())
        async throws -> ExtensionCLIReply
    {
        try await UsageCLIExecution.run(
            ExtensionCLIRequest(arguments: arguments), controller: controller, standardInput: input)
    }

    @Test func originalCommandTreeParsesEveryUsageLeaf() throws {
        let leaves = [
            ["summary"], ["daily"], ["models"], ["sources"], ["limits"], ["alerts"],
            ["projects", "list"], ["projects", "show", "sample"], ["projects", "open", "sample"],
            ["projects", "copy-link", "sample"], ["projects", "copy-chat", "sample"],
            ["attribution", "ls"], ["attribution", "reset", "--yes"],
            ["machines", "ls"], ["machines", "collect", "sample", "--once", "--timeout", "20"],
            ["machines", "enable", "sample"], ["machines", "disable", "sample"],
            ["machines", "forget", "sample"],
            ["refresh", "--follow"], ["refresh", "--machines"], ["refresh", "--no-machines"],
            ["export", "--card", "activity", "--output", "card.png"],
            ["statusline", "status"], ["statusline", "install"], ["statusline", "remove"],
            ["statusline", "record", "--then", "cat"],
        ]
        for arguments in leaves { _ = try UsageCommand.parseAsRoot(arguments) }
    }

    @Test func reportsReadOwnedDataAndPreserveJSONErrorsAndExitCodes() async throws {
        try FileManager.default.createDirectory(at: Repo.dataDir, withIntermediateDirectories: true)
        let data = Data(CLIUsageTests.document.utf8)
        try data.write(to: Repo.usageJSON)
        defer { try? FileManager.default.removeItem(at: Repo.usageJSON) }
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in data })
        let summary = try await run(
            ["summary", "--source", "codex", "--json"], controller: controller)
        #expect(summary.exitCode == 0 && summary.stderr.isEmpty)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(summary.stdout.utf8)) as? [String: Any])
        #expect((payload["totals"] as? [String: Any])?["tokens"] as? Int == 4)
        let invalid = try await run(
            ["summary", "--source", "unknown", "--json"], controller: controller)
        #expect(invalid.exitCode == 3)
        #expect(invalid.stdout.isEmpty && invalid.stderr.contains("no usage source named unknown"))
        let help = try await run(["--help"], controller: controller)
        #expect(help.exitCode == 0 && help.stdout.contains("statusline"))
        await controller.shutdown()
    }

    @Test func statuslineRecordsExactWindowsAndForwardsExactInput() async throws {
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir, collect: { _, _ in Data() })
        let input = Data(
            #"{"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":18}}}"#
                .utf8)
        let recorded = try await run(
            ["statusline", "record", "--json"], controller: controller, input: input)
        #expect(recorded.exitCode == 0)
        #expect(recorded.stdout.contains("5h 42%"))
        let wrapped = try await run(
            ["statusline", "record", "--then", "/bin/cat"], controller: controller, input: input)
        #expect(wrapped.exitCode == 0 && wrapped.stdout == String(decoding: input, as: UTF8.self))
        let conflict = try await run(
            ["statusline", "record", "--json", "--then", "/bin/cat"], controller: controller,
            input: input
        )
        #expect(conflict.exitCode == 2 && conflict.stdout.isEmpty)
        await controller.shutdown()
    }

    @Test func refreshConsumesOwningEngineAndCancellationStopsOwnedRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("home/.claude/projects/sample/session.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let project = root.appendingPathComponent("home/projects/sample")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n url = https://github.com/example/sample.git\n".utf8)
            .write(to: project.appendingPathComponent(".git/config"))
        let row = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-09T01:00:00Z", "sessionId": "sample-session",
            "requestId": "sample-request", "costUSD": 2, "cwd": project.path,
            "message": [
                "id": "sample-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 120, "output_tokens": 30],
                "content": "Sample fixture prompt",
            ],
        ])
        try (row + Data("\n".utf8)).write(to: journal)
        let controller = UsageWorkerController(
            dataDirectory: Repo.dataDir,
            collect: { _, event in
                try await UsageNativeCollector.collect(
                    home: root.appendingPathComponent("home"),
                    dataDirectory: root.appendingPathComponent("collector-data"),
                    environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: event)
            })
        let reply = try await run(["refresh", "--no-machines", "--json"], controller: controller)
        try #require(reply.exitCode == 0, Comment(rawValue: reply.stderr))
        #expect(reply.stdout.contains("completed"))
        let result = try #require(
            try JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any])
        #expect((result["summary"] as? [String: String])?["journals"] == "1")
        #expect((result["phases"] as? [[String: Any]])?.isEmpty == false)
        let data = try Data(contentsOf: Repo.usageJSON)
        #expect(UsageHistory.isValidDocument(data))
        await controller.shutdown()
        let waiting = UsageWorkerController(
            dataDirectory: Repo.dataDir,
            collect: { _, _ in
                try await Task.sleep(for: .seconds(60))
                return data
            })
        let request = Task { try await run(["refresh", "--json"], controller: waiting) }
        while !waiting.refreshing { await Task.yield() }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!waiting.refreshing)
        await waiting.shutdown()
    }
}
