import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized) struct UsageUIPresentationTests {
    private func context(_ location: String, _ tile: SurfaceTile, id: UUID = UUID()) throws
        -> NSDictionary
    {
        [
            "location": location, "section": tile.widget.id, "target": location,
            "tile": try JSONEncoder().encode(tile), "presentationID": id.uuidString,
        ]
    }

    @Test func originalHomeAndNotchInteriorsRequireExactRoutesAndNormalizedTiles() throws {
        for location in ["home", "notch"] {
            for widget in [SurfaceWidget.usage, .activity, .limits] {
                let tile = SurfaceTile(widget)
                let input = try context(location, tile)
                let route = try #require(UsageUISceneRoute(context: input))
                #expect(
                    route.interior
                        == (widget == .limits
                            ? .limitsCard
                            : widget == .activity && location == "home"
                                ? .activityHeatmap : .usageCard))
                for replacement in ["section", "target", "location"] {
                    let changed = input.mutableCopy() as! NSMutableDictionary
                    changed[replacement] = "calendar"
                    #expect(UsageUISceneRoute(context: changed) == nil)
                }
                var hidden = tile; hidden.hidden = true
                #expect(UsageUISceneRoute(context: try context(location, hidden)) == nil)
                var bad = tile; bad.days = 366
                #expect(UsageUISceneRoute(context: try context(location, bad)) == nil)
            }
        }
        #expect(UsageUISceneRoute(context: ["location": "main"])?.interior == .dashboard)
        #expect(UsageUISceneRoute(context: ["location": "settings"])?.interior == .settings)
        #expect(
            UsageUISceneRoute(context: ["location": "main", "section": "dashboard"])?.interior
                == .dashboard)
        #expect(
            UsageUISceneRoute(context: ["location": "settings", "section": "usage"])?.interior
                == .settings)
        #expect(
            UsageUISceneRoute(context: [
                "location": "main", "section": "dashboard", "target": "home",
            ]) == nil)
        #expect(UsageUISceneRoute(context: try context("notch", SurfaceTile(.calendar))) == nil)
        let tooLarge = NSMutableDictionary(dictionary: [
            "location": "notch", "section": "usage", "target": "notch",
            "tile": Data(repeating: 0, count: 65_537),
        ])
        #expect(UsageUISceneRoute(context: tooLarge) == nil)
    }

    @Test func presentationCapacityReleaseAndLateResponseDrainStayOwned() async throws {
        let registry = UsageUIPresentations()
        let route = try #require(UsageUISceneRoute(context: context("notch", SurfaceTile(.usage))))
        var cancelled = 0
        var invoked = 0
        var clients: [UsageUIClient] = []
        for _ in 0..<16 {
            let client = UsageUIClient(invoke: { _, _ in
                invoked += 1
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1; throw error }
                throw ExtensionPeerError.unavailable
            })
            clients.append(client)
            #expect(
                registry.configure(UsageUIPresentation(id: UUID(), route: route, client: client)))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while invoked < 16, ContinuousClock.now < deadline { await Task.yield() }
        try #require(invoked == 16)
        let extra = UsageUIPresentation(id: UUID(), route: route, client: nil)
        #expect(!registry.configure(extra))
        let scene = try #require(registry.scenes.values.first)
        registry.release(scene.id)
        #expect(scene.stopping)
        #expect(!registry.configure(UsageUIPresentation(id: scene.id, route: route, client: nil)))
        await scene.shutdownAndWait()
        #expect(cancelled == 1 && scene.drained)
        #expect(clients.filter(\.stopped).count == 1)
        #expect(registry.configure(UsageUIPresentation(id: scene.id, route: route, client: nil)))
        await registry.stopAndWait()
        #expect(cancelled == 16 && clients.allSatisfy(\.stopped) && registry.isEmpty)
        await #expect(throws: (any Error).self) { try await scene.client?.document() }
    }

    @Test func realOwningEngineCardSnapshotsKeepSourceSelectionAndNoUICollector() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let project = home.appendingPathComponent("projects/fixture")
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n url = https://github.com/example/fixture.git\n".utf8).write(
            to: project.appendingPathComponent(".git/config"))
        let journal = home.appendingPathComponent(".claude/projects/fixture/session.jsonl")
        try FileManager.default.createDirectory(
            at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let row = try JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-10-09T01:00:00Z", "sessionId": "fixture-session",
            "requestId": "fixture-request",
            "costUSD": 1, "cwd": project.path,
            "message": [
                "id": "fixture-message", "model": "claude-sonnet-4-5",
                "usage": ["input_tokens": 10, "output_tokens": 5], "content": "Fixture prompt",
            ],
        ])
        try (row + Data("\n".utf8)).write(to: journal)
        let defaults = try #require(UserDefaults(suiteName: "usage-scenes-" + UUID().uuidString))
        let count = UsagePresentationCollectionCounter()
        let controller = UsageWorkerController(
            dataDirectory: root,
            collect: { _, event in
                await count.record()
                return try await UsageNativeCollector.collect(
                    home: home, dataDirectory: root.appendingPathComponent("collector"),
                    environment: ["EDITH_USAGE_OFFLINE": "1", "TZ": "UTC"], onEvent: event)
            })
        _ = try controller.requestRefresh(policy: .skip)
        await controller.waitForRefresh()
        try #require(controller.failure == nil)
        let service = UsageUICommands(controller: controller, directory: root, defaults: defaults)
        let client = UsageUIClient(invoke: { try await service.execute($0, payload: $1) })
        let model = DashboardModel(preferences: defaults, uiClient: client)
        await model.load()
        await model.awaitPendingComputation()
        #expect(model.loaded)
        #expect(await count.value == 1)
        var tile = SurfaceTile(.activity); tile.sourceIDs = ["cli"]
        tile.days = 365
        let card = try JSONDecoder().decode(
            SurfaceUsageSnapshot.self,
            from: await client.invoke("usage.ui.card", payload: JSONEncoder().encode(tile)))
        var empty = tile; empty.sourceIDs = []
        let nothing = try JSONDecoder().decode(
            SurfaceUsageSnapshot.self,
            from: await client.invoke("usage.ui.card", payload: JSONEncoder().encode(empty)))
        #expect(nothing.total.tokens == 0 && nothing.total.cost == 0)
        #expect(card.total.tokens == 15 && card.total.cost == 1)
        #expect(card.providers.allSatisfy { tile.sourceIDs?.contains($0.id) == true })
        await client.stopAndWait(); model.shutdown(); await service.shutdownAndWait();
        await controller.shutdown()
        #expect(await count.value == 1)
    }

    @Test func originalLimitsProjectionRetainsExpiredUnavailableCapacityAndFieldSelection() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: now,
            providers: [
                .init(
                    provider: .claude,
                    session: .init(percent: 25, resetsAt: now.addingTimeInterval(7200)),
                    week: .init(percent: 93, resetsAt: now.addingTimeInterval(-1))),
                .init(provider: .cursor, session: .init(percent: 110, resetsAt: nil), week: nil),
            ], failure: nil)
        var tile = SurfaceTile(.limits)
        let value = UsageCompactLimitsSnapshot.project(snapshot, tile: tile, now: now)
        #expect(value.metrics.first(where: { $0.id == "remaining" })?.value == "0%")
        #expect(value.rows.first(where: { $0.id == "claude:weekly" })?.value == "Expired")
        #expect(value.rows.first(where: { $0.id == "cursor:weekly" })?.value == "Unavailable")
        #expect(
            value.rows.first(where: { $0.id == "claude:session" })?.details.contains(
                .init("resets", "Resets in 2h 0m")) == true)
        tile.sourceIDs = ["claude"]
        let selected = UsageCompactLimitsSnapshot.project(snapshot, tile: tile, now: now)
        #expect(selected.metrics.first(where: { $0.id == "remaining" })?.value == "75%")
        #expect(selected.rows.allSatisfy { $0.source == "claude" })
        tile.sourceIDs = []
        #expect(UsageCompactLimitsSnapshot.project(snapshot, tile: tile, now: now).rows.isEmpty)
    }

    @Test func compactNavigationUsesExactOwningPresentationAndUnavailableHostFailsClosed()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = UsageWorkerController(dataDirectory: root, collect: { _, _ in Data() })
        var observed: UsageNavigationRequest?
        let service = UsageUICommands(
            controller: controller, directory: root, navigate: { observed = $0 })
        let client = UsageUIClient(invoke: { try await service.execute($0, payload: $1) })
        let id = UUID()
        let input = try context("notch", SurfaceTile(.usage), id: id)
        let route = try #require(UsageUISceneRoute(context: input))
        let scene = UsageUIPresentation(id: id, route: route, client: client)
        try await scene.open()
        #expect(observed == UsageNavigationRequest(presentationID: id, location: "notch"))
        let changed = input.mutableCopy() as! NSMutableDictionary
        changed["presentationID"] = UUID().uuidString
        #expect(!scene.matches(changed))
        changed["presentationID"] = id.uuidString
        changed["tile"] = try JSONEncoder().encode(SurfaceTile(.activity))
        #expect(!scene.matches(changed))
        await scene.shutdownAndWait()
        await #expect(throws: (any Error).self) { try await scene.open() }
        await #expect(throws: (any Error).self) {
            try await service.execute("usage.ui.open", payload: Data("{}".utf8))
        }
        await service.shutdownAndWait(); await controller.shutdown()
    }
}

private actor UsagePresentationCollectionCounter {
    private(set) var value = 0
    func record() { value += 1 }
}
