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

    @Test func fastHistoryDatesRetainOriginalNormalizationAndInvalidInputs() {
        let samples = [
            "2026-10-09T01:00:00Z", "2026-10-09T01:00:00.123456Z",
            "2026-10-09T01:00:00+00:00", "2026-10-09T01:00:00-07:30",
            "2026-02-30T00:00:00Z", "2026-02-29T00:00:00Z",
            "2024-02-29T00:00:00Z", "2026-01-01T24:00:00Z",
            "2026-01-01T25:00:00Z", "2026-01-01T00:00:60Z",
            "2026-01-01T00:00:61Z", "2026-01-01T00:60:00Z",
            "2026-00-01T00:00:00Z", "2026-13-01T00:00:00Z",
            "2026-01-00T00:00:00Z", "2026-01-32T00:00:00Z",
            "2026-01-01 00:00:00Z", "2026-01-01T00:00:00z",
            "1582-10-04T00:00:00Z", "0001-01-01T00:00:00Z",
            "1969-12-31T23:59:59Z", "1970-01-01T00:00:00Z", "", "malformed",
        ]
        for value in samples {
            #expect(
                LimitsHistory.parseTimestamp(value) == EdithDate.parseISO(value),
                Comment(rawValue: value))
        }
        #expect(LimitsHistory.parseTimestamp(nil) == nil)
        #expect(LimitsHistory.parseTimestamp("2026-01-01T00:00:60Z") == nil)
    }

    @Test func fullHistoryPreparationProfilesDistinctOriginalRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let count = 115_000
        let (raw, date) = try historyFixture(root)
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
    @Test(arguments: [false, true])
    func historyCancellationAndDisableDrainRealPreparationAndRejectStaleReceipts(disabling: Bool)
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try historyFixture(root)
        let controller = UsageWorkerController(
            dataDirectory: root,
            collect: { _, _ in
                Issue.record("Limits history preparation must not collect usage")
                throw ExtensionPeerError.unavailable
            })
        let service = UsageUICommands(controller: controller, directory: root)
        var receipts: [UUID] = []
        var chunks = 0
        let client = UsageUIClient(invoke: { operation, payload in
            let data = try await service.execute(operation, payload: payload)
            if operation == "usage.ui.limits" {
                let object = try #require(
                    JSONSerialization.jsonObject(with: data) as? [String: Any])
                receipts.append(
                    try #require((object["id"] as? String).flatMap(UUID.init(uuidString:))))
                #expect(object["byteCount"] as? Int == 9_189_911)
            }
            if operation == "usage.ui.chunk" { chunks += 1 }
            return data
        })
        let request = Task { try await client.limits(provider: .claude) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.pendingHistoryPreparations == 0 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(service.pendingHistoryPreparations == 1)
        if disabling { await service.shutdownAndWait() } else { request.cancel() }
        await #expect(throws: (any Error).self) { try await request.value }
        #expect(service.pendingHistoryPreparations == 0 && receipts.isEmpty)
        if disabling {
            await #expect(throws: (any Error).self) { try await client.limits(provider: .claude) }
        } else {
            let value = try await client.limits(provider: .claude)
            #expect(value.points.count == 115_000 && chunks > 1)
            #expect(
                value.points.enumerated().allSatisfy {
                    $0.element.s == Double($0.offset % 101) && $0.element.w == 18
                })
            let id = try #require(receipts.last)
            let stale = try JSONSerialization.data(withJSONObject: [
                "id": id.uuidString, "offset": 0,
            ])
            await #expect(throws: (any Error).self) {
                try await service.execute("usage.ui.chunk", payload: stale)
            }
        }
        await client.stopAndWait(); await service.shutdownAndWait(); await controller.shutdown()
    }

    @Test func historyPreparationsAreBoundedAndShutdownDrainsEveryRealLoad() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try historyFixture(root)
        let controller = UsageWorkerController(
            dataDirectory: root, collect: { _, _ in throw ExtensionPeerError.unavailable })
        let service = UsageUICommands(controller: controller, directory: root)
        let payload = Data(#"{"provider":"claude"}"#.utf8)
        let tasks = (0..<8).map { _ in
            Task { try await service.execute("usage.ui.limits", payload: payload) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while service.pendingHistoryPreparations < 8 && ContinuousClock.now < deadline {
            await Task.yield()
        }
        try #require(service.pendingHistoryPreparations == 8)
        await #expect(throws: (any Error).self) {
            try await service.execute("usage.ui.limits", payload: payload)
        }
        await service.shutdownAndWait()
        for task in tasks { await #expect(throws: (any Error).self) { try await task.value } }
        #expect(service.pendingHistoryPreparations == 0)
        await controller.shutdown()
    }

    private func historyFixture(_ root: URL) throws -> (Data, Date) {
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
        let maximum = 16 * 1_024 * 1_024
        let padding = (maximum - rows.utf8.count) / count
        rows = rows.replacingOccurrences(
            of: "\n", with: String(repeating: " ", count: padding) + "\n")
        rows.insert(
            contentsOf: String(repeating: " ", count: maximum - rows.utf8.count),
            at: rows.startIndex)
        let raw = Data(rows.utf8)
        #expect(raw.count == maximum)
        try raw.write(to: root.appendingPathComponent("limits-history.jsonl"))
        return (raw, date)
    }
}
