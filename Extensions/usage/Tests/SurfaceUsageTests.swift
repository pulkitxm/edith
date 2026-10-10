import EdithExtensionSupport
@testable import UsageExtension
import Foundation
import Testing

@Suite struct SurfaceUsageTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))!
    }
    private func document() throws -> SurfaceUsageDocument {
        let text = #"""
            {"defaultSources":["local"],"sourceMeta":{"local":{"label":"Local"}},"daily":[
                {"period":"2026-09-01","bySource":{"local":[{"cost":999,"inputTokens":999}]}},
                {"period":"2026-10-03","bySource":{"local":[{"modelName":"alpha","cost":2,"inputTokens":10}]}},
                {"period":"2026-10-08","bySource":{"local":[{"modelName":"alpha","cost":0,"inputTokens":1000000,"cacheReadTokens":2000000}]}},
                {"period":"2026-10-09","bySource":{
                    "local":[{"modelName":"beta","cost":3,"inputTokens":20,"outputTokens":5,"cacheCreationTokens":10}],
                    "remote":[{"modelName":"gamma","cost":700,"inputTokens":100}]}},
                {"period":"2026-10-10","bySource":{"local":[{"cost":800,"inputTokens":100}]}}
            ]}
            """#
        return try JSONDecoder().decode(SurfaceUsageDocument.self, from: Data(text.utf8))
    }

    @Test func periodTotalsExcludeOldFutureAndUnselectedSources() throws {
        var tile = SurfaceTile(.usage); tile.days = 7
        let value = SurfaceUsageSnapshot(
            document: try document(), tile: tile, now: now, calendar: calendar)
        #expect(value.total.cost == 5)
        #expect(value.today.cost == 3)
        #expect(value.week.cost == 5)
        #expect(value.total.tokens == 3_000_045)
        #expect(value.days.count == 7)
        #expect(value.activeDays == 3)
        #expect(value.providers.map(\.title) == ["Local"])
        #expect(value.models.map(\.title) == ["beta", "alpha"])
    }

    @Test func tokenOnlyUsageRemainsVisibleAndExplicitEmptySelectionStaysEmpty() throws {
        let source =
            #"{"daily":[{"period":"2026-10-09","bySource":{"local":[{"modelName":"alpha","inputTokens":775500000,"cost":0}]}}]}"#
        let document = try JSONDecoder().decode(SurfaceUsageDocument.self, from: Data(source.utf8))
        var tile = SurfaceTile(.usage); tile.days = 7
        let value = SurfaceUsageSnapshot(
            document: document, tile: tile, now: now, calendar: calendar)
        #expect(value.chartUsesTokens)
        #expect(value.activeDays == 1)
        #expect(value.models.first?.total.tokens == 775_500_000)
        tile.sourceIDs = []
        let empty = SurfaceUsageSnapshot(
            document: document, tile: tile, now: now, calendar: calendar)
        #expect(empty.total.tokens == 0)
        #expect(empty.providers.isEmpty)
    }

    @Test func cacheReadsReplacedRecordsAndPropagatesInvalidData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.json")
        let store = SurfaceUsageStore(url: url)
        try Data(#"{"daily":[]}"#.utf8).write(to: url)
        let first = try await store.snapshot(tile: SurfaceTile(.usage))
        #expect(first.total.cost == 0)
        try Data("broken".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        await #expect(throws: (any Error).self) {
            try await store.snapshot(tile: SurfaceTile(.usage))
        }
    }
}
