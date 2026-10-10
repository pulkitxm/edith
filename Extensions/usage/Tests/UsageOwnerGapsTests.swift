import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageOwnerGapsTests {
    @Test(arguments: [false, true], [false, true])
    func missingJournalContextRetainsMetricsAndOriginalPublicationBoundary(cwd: Bool, content: Bool)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("projects/fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let journal = home.appendingPathComponent(".claude/projects/fixture/session.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        var message: [String: Any] = [
            "id": "fixture-message", "model": "claude-sonnet-4-5",
            "usage": ["input_tokens": 10, "output_tokens": 5],
        ]
        if content { message["content"] = "Fixture prompt" }
        var row: [String: Any] = [
            "timestamp": "2026-10-09T01:00:00Z", "sessionId": "fixture-session",
            "requestId": "fixture-request", "costUSD": 3.25, "message": message,
        ]
        if cwd { row["cwd"] = project.path }
        try (JSONSerialization.data(withJSONObject: row) + Data("\n".utf8)).write(to: journal)
        let collect: @Sendable () async throws -> Data = {
            try await UsageNativeCollector.collect(
                home: home, dataDirectory: root.appendingPathComponent("archive"),
                environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: { _ in })
        }
        let data = try await collect()
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let totals = try #require(document["totals"] as? [String: Any])
        #expect(totals["tokens"] as? Double == 15 && totals["cost"] as? Double == 3.25)
        let day = try #require((document["daily"] as? [[String: Any]])?.first)
        #expect(day["period"] as? String == "2026-10-09")
        let projects = try #require(day["projects"] as? [[String: Any]])
        #expect(projects.count == 1 && projects[0]["path"] as? String == (cwd ? project.path : ""))
        let chat = try #require((projects[0]["chats"] as? [[String: Any]])?.first)
        #expect(chat["id"] as? String == "fixture-session" && chat["tokens"] as? Double == 15)
        #expect(chat["firstTs"] as? Double == 1_791_507_600_000)
        #expect(UsageHistory.isValidDocument(data) == cwd)
        let output = root.appendingPathComponent("publication")
        let controller = UsageWorkerController(
            dataDirectory: output, collect: { _, _ in try await collect() })
        let reply = try await UsageCLIExecution.run(
            ExtensionCLIRequest(
                arguments: ["refresh", "--no-machines", "--json"], workingDirectory: root.path),
            controller: controller)
        if cwd {
            #expect(reply.exitCode == 0)
            #expect(
                UsageHistory.isValidDocument(
                    try Data(contentsOf: output.appendingPathComponent("usage.json"))))
        } else {
            #expect(reply.exitCode != 0 && reply.stderr.contains("invalid"))
            #expect(
                !FileManager.default.fileExists(
                    atPath: output.appendingPathComponent("usage.json").path))
        }
        await controller.shutdown()
    }

    @Test func fullHistoryPreparationProfilesDistinctOriginalRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 115_000
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let style = Date.ISO8601FormatStyle()
        var rows = String()
        rows.reserveCapacity(16 * 1_024 * 1_024)
        for i in 0..<count {
            let stamp = date.addingTimeInterval(Double(i)).formatted(style)
            rows +=
                "{\"ts\":\"\(stamp)\",\"p\":\"claude\",\"s\":\(i % 101),\"w\":18,\"sr\":\"2027-02-01T13:00:00Z\",\"wr\":\"2027-02-02T12:00:00Z\"}\n"
        }
        let raw = Data(rows.utf8)
        #expect(raw.count > 8 * 1_024 * 1_024 && raw.count < 16 * 1_024 * 1_024)
        try raw.write(to: root.appendingPathComponent("limits-history.jsonl"))
        let begin = ContinuousClock.now
        let snapshot = await LimitsHistory.loadSnapshot(
            preferredProvider: .claude, url: root.appendingPathComponent("limits-history.jsonl"))
        let loaded = ContinuousClock.now
        let encoded = try JSONEncoder().encode(
            UsageUILimits(
                providers: snapshot.latest, points: snapshot.points, provider: snapshot.provider,
                current: nil))
        let end = ContinuousClock.now
        #expect(snapshot.points.count == count)
        #expect(
            snapshot.points.first?.date == date
                && snapshot.points.last?.date == date.addingTimeInterval(Double(count - 1)))
        #expect(
            snapshot.points.enumerated().allSatisfy {
                $0.element.s == Double($0.offset % 101) && $0.element.w == 18
            })
        #expect(encoded.count > ExtensionPeerEndpoint.maximumPayloadBytes)
        print(
            "usage-history-profile records=\(count) inputBytes=\(raw.count) outputBytes=\(encoded.count) load=\(begin.duration(to: loaded)) encode=\(loaded.duration(to: end))"
        )
    }
}
