import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageCollectorDashboardIntegrationTests {
    @Test func nativeReceiptsPublishValidatedHistoryAndLoadAllDashboardProjections() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let directory = root.appendingPathComponent("data")
        let project = home.appendingPathComponent("projects/sample")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n url = https://github.com/example/sample.git\n".utf8).write(
            to: project.appendingPathComponent(".git/config"))
        let journal = home.appendingPathComponent(".claude/projects/sample/session.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        var row = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-09T01:00:00Z", "sessionId": "sample-session",
            "requestId": "sample-request", "cwd": project.path, "costUSD": 1,
            "message": [
                "id": "sample-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 10, "output_tokens": 2],
                "content": "Sample fixture prompt",
            ],
        ])
        row.append(10); try row.write(to: journal)
        let controller = UsageWorkerController(dataDirectory: directory) { _, event in
            try await UsageNativeCollector.collect(
                home: home, dataDirectory: directory,
                environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: event)
        }
        _ = try controller.requestRefresh(policy: .skip)
        await controller.waitForRefresh()
        #expect(controller.failure == nil)
        let data = try Data(contentsOf: directory.appendingPathComponent("usage.json"))
        #expect(UsageHistory.isValidDocument(data))
        let parsed = try JSONDecoder().decode(DashUsage.self, from: data)
        let model = DashboardModel()
        model.ingest(parsed)
        await model.awaitPendingComputation()
        #expect(model.loaded)
        #expect(model.homeUsage.calendarDays.reduce(0) { $0 + $1.tokens } == 12)
        #expect(model.calendarDays.contains(where: { $0.tokens == 12 }))
        let surface = UsageSurface(
            store: .init(url: directory.appendingPathComponent("usage.json")),
            controller: controller, privacy: { [:] })
        let snapshot = try await surface.snapshot(.init(.activity))
        #expect(snapshot.calendars?.first?.days.contains(where: { $0.level > 0 }) == true)
        _ = try snapshot.encoded()
        model.shutdown()
        await controller.shutdown()
    }
}
