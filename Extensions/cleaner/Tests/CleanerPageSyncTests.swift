import EdithExtensionSupport
import Foundation
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized)
struct CleanerPageSyncTests {
    @MainActor struct Harness {
        let engine: CleanerModel
        let bridge: CleanerEngineBridge
        let ui: CleanerModel

        func settle() async throws {
            for _ in 0..<200 {
                if ui.categories == engine.categories { return }
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        func stop() async {
            await ui.shutdown()
            await engine.shutdown()
        }
    }

    static func harness(items: Int) async throws -> Harness {
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.cleaner.sync." + UUID().uuidString))
        let engine = await CleanerSyntheticFixture.engine(items: items, defaults: defaults)
        let bridge = CleanerEngineBridge(engine: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        CleanerModel.uiMemory = nil
        let ui = CleanerModel(engineClient: client, defaults: defaults)
        await ui.refreshRemote()
        return Harness(engine: engine, bridge: bridge, ui: ui)
    }

    @Test func unchangedPollsCarryNoSnapshot() async throws {
        let harness = try await Self.harness(items: 400)
        defer { Task { await harness.stop() } }
        #expect(harness.ui.categories == harness.engine.categories)
        let firstBytes = try #require(harness.bridge.replies.last?.bytes)
        harness.bridge.replies.removeAll()

        for _ in 0..<5 { await harness.ui.refreshRemote() }

        #expect(harness.bridge.replies.count == 5)
        #expect(harness.bridge.replies.allSatisfy { $0.bytes < 64 })
        #expect(firstBytes > 10_000)
    }

    @Test func snapshotIsResentAfterEngineChanges() async throws {
        let request = { (known: Int?) in
            try JSONEncoder().encode(CleanerUISnapshotRequest(known: known))
        }
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.cleaner.sync." + UUID().uuidString))
        let engine = await CleanerSyntheticFixture.engine(items: 40, defaults: defaults)
        defer { Task { await engine.shutdown() } }
        let stamp = engine.uiStamp

        let unchanged = try JSONDecoder().decode(
            CleanerUIReply.self,
            from: try await CleanerUICommands.execute(
                "cleaner.ui.snapshot", payload: try request(stamp), model: engine))
        #expect(unchanged.snapshot == nil)
        #expect(unchanged.stamp == stamp)

        engine.toggleAll()
        let changed = try JSONDecoder().decode(
            CleanerUIReply.self,
            from: try await CleanerUICommands.execute(
                "cleaner.ui.snapshot", payload: try request(stamp), model: engine))
        #expect(changed.stamp != stamp)
        #expect(changed.snapshot?.categories == engine.categories)
    }

    @Test func selectionClicksStayInSyncWithStampOnlyReplies() async throws {
        let harness = try await Self.harness(items: 400)
        defer { Task { await harness.stop() } }
        let ui = harness.ui
        harness.bridge.replies.removeAll()
        let category = try #require(ui.categories.first)

        for item in category.items.prefix(6) {
            ui.toggleItem(categoryID: category.id, itemID: item.id)
        }
        ui.toggleCategory(try #require(ui.categories.last).id)
        ui.toggleAll()
        try await harness.settle()

        #expect(ui.categories == harness.engine.categories)
        #expect(ui.selectedItemCount == harness.engine.selectedItemCount)
        let actions = harness.bridge.replies.filter { $0.operation == "cleaner.ui.action" }
        #expect(!actions.isEmpty)
        #expect(actions.allSatisfy { $0.bytes < 64 })

        harness.bridge.replies.removeAll()
        await ui.refreshRemote()
        #expect(harness.bridge.replies.allSatisfy { $0.bytes < 64 })
    }

    @Test func pageAdoptsEngineChangesMadeOutsideThePage() async throws {
        let harness = try await Self.harness(items: 200)
        defer { Task { await harness.stop() } }
        let ui = harness.ui
        let category = try #require(ui.categories.first)
        let outside = try #require(category.items.first)
        let inside = try #require(category.items.dropFirst().first)

        harness.engine.toggleItem(categoryID: category.id, itemID: outside.id)
        ui.toggleItem(categoryID: category.id, itemID: inside.id)
        try await harness.settle()

        #expect(ui.categories == harness.engine.categories)
        let items = try #require(ui.categories.first?.items)
        #expect(items[0].selected != outside.selected)
        #expect(items[1].selected != inside.selected)
    }
}
