import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@MainActor @Suite(.serialized)
struct UsageSurfaceTests {
    @Test func selectedSourcesFieldsAndHeatmapsUseActualCachedData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let today = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let url = root.appendingPathComponent("usage.json")
        try JSONSerialization.data(withJSONObject: [
            "daily": [
                [
                    "period": today,
                    "bySource": [
                        "one": [["modelName": "Sample", "inputTokens": 123, "cost": 2.5]],
                        "two": [["modelName": "Other", "inputTokens": 456, "cost": 9]],
                    ],
                ]
            ], "sourceMeta": ["one": ["label": "First"], "two": ["label": "Second"]],
        ]).write(to: url)
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        let surface = UsageSurface(
            store: SurfaceUsageStore(url: url), controller: controller, privacy: { [:] })
        var tile = SurfaceTile(.usage); tile.sourceIDs = ["one"];
        tile.hiddenFields = ["models", "week"]
        let request = SurfaceSnapshotRequest(target: .home, tile: tile)
        let data = try await surface.execute(
            "surface.snapshot", payload: request.encoded(providerID: "usage"))
        let snapshot = try SurfaceSnapshot.decode(data, providerID: "usage")
        #expect(snapshot.rows.map(\.title) == ["First"])
        #expect(snapshot.metrics.first(where: { $0.id == "tokens" })?.value == "123")
        #expect(!snapshot.metrics.contains(where: { $0.id == "week" }))
        #expect(snapshot.charts?.first?.series.first?.points.last?.y == 2.5)
        tile.widget = .activity
        let activity = try await surface.snapshot(tile)
        #expect(activity.charts == nil)
        #expect(activity.calendars?.first?.days.last?.level ?? 0 > 0)
        _ = try activity.encoded()
        await controller.shutdown()
    }

    @Test func limitsRespectProviderWindowRemainingAndResetSelectionsWithoutFetching() async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        let surface = UsageSurface(
            store: SurfaceUsageStore(url: root.appendingPathComponent("missing")),
            controller: controller,
            limits: {
                .init(
                    refreshedAt: Date(),
                    providers: [
                        .init(
                            provider: .codex,
                            session: .init(percent: 42, resetsAt: Date().addingTimeInterval(300)),
                            week: .init(percent: 75, resetsAt: Date().addingTimeInterval(600)))
                    ], failure: nil)
            }, privacy: { [:] })
        var tile = SurfaceTile(.limits); tile.sourceIDs = ["codex"];
        tile.hiddenFields = ["weekly", "remaining", "resets"]
        let snapshot = try await surface.snapshot(tile)
        #expect(snapshot.rows.count == 1)
        #expect(snapshot.rows.first?.detail == "")
        #expect(snapshot.rows.first?.progress == 0.42)
        tile.sourceIDs = []
        #expect(try await surface.snapshot(tile).rows.isEmpty)
        await controller.shutdown()
    }

    @Test func staleDayActionsAndPrivateDiscoveryAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root) { _, _ in
            throw CancellationError()
        }
        var opened = false
        let surface = UsageSurface(
            store: SurfaceUsageStore(url: root.appendingPathComponent("missing")),
            controller: controller, open: { opened = true }, privacy: { [:] })
        let request = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: .init(.activity)), actionID: "day:2026-01-01")
        await #expect(throws: ExtensionPeerError.self) {
            _ = try await surface.execute(
                "surface.perform", payload: request.encoded(providerID: "usage"))
        }
        #expect(!opened)
        let hidden = UsageSurface(
            store: SurfaceUsageStore(url: root.appendingPathComponent("missing")),
            controller: controller, privacy: { ["active": "1", "blurMoney": "1"] })
        #expect(try await hidden.snapshot(.init(.ability("usage"))).sources.isEmpty)
        await controller.shutdown()
    }
}
