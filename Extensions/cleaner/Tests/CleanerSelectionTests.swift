import EdithExtensionSupport
import Foundation
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized)
struct CleanerSelectionTests {
    static func nestedCategories(projects: Int) -> [JunkCategory] {
        var worktrees: [JunkItem] = []
        var modules: [JunkItem] = []
        var builds: [JunkItem] = []
        for index in 0..<projects {
            let word = CleanerSyntheticFixture.words[index % CleanerSyntheticFixture.words.count]
            let root = URL(fileURLWithPath: "/synthetic/code/\(word)-\(index)")
            let tree = root.appendingPathComponent("feature")
            worktrees.append(
                JunkItem(
                    id: tree.path, name: "\(word)-\(index)/feature", path: tree,
                    sizeBytes: 50_000, selected: index % 3 == 0,
                    worktree: WorktreeInfo(
                        branch: "feature/\(word)", repository: root.path, dirty: false,
                        unpushed: 0, merged: true)))
            let nested = tree.appendingPathComponent("node_modules")
            modules.append(
                JunkItem(
                    id: nested.path, name: "\(word)-\(index)/feature/node_modules", path: nested,
                    sizeBytes: 20_000, selected: index % 2 == 0))
            let deeper = nested.appendingPathComponent(".cache")
            builds.append(
                JunkItem(
                    id: deeper.path, name: "\(word)-\(index)/feature/node_modules/.cache",
                    path: deeper, sizeBytes: 3_000, selected: index % 5 == 0))
        }
        return [
            JunkCategory(
                id: Worktrees.categoryID, name: "Git worktrees", detail: "", items: worktrees),
            JunkCategory(id: "nodeModules", name: "node_modules", detail: "", items: modules),
            JunkCategory(id: "jsCaches", name: "JS caches", detail: "", items: builds),
        ]
    }

    static func expected(_ categories: [JunkCategory]) -> CleanerSelectionStats {
        var stats = CleanerSelectionStats()
        let selected = CleanerOperationExecution.selectedItems(in: categories)
        stats.itemCount = categories.reduce(0) { $0 + $1.items.count }
        stats.markedCount = categories.reduce(0) { $0 + $1.items.filter(\.selected).count }
        stats.selectedCount = selected.count
        stats.selectedBytes = selected.reduce(0) { $0 + $1.sizeBytes }
        for category in categories {
            let chosen = JunkScanner.outermost(category.items.filter(\.selected))
            stats.categories[category.id] = CleanerCategoryStats(
                itemCount: category.items.count,
                markedCount: category.items.filter(\.selected).count,
                selectedCount: chosen.count, selectedBytes: chosen.reduce(0) { $0 + $1.sizeBytes })
        }
        return stats
    }

    static func model(
        _ categories: [JunkCategory], defaults: UserDefaults
    ) async -> CleanerModel {
        let model = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in CleanerScanResult(categories: categories) }))
        model.scan()
        await model.finishWork()
        return model
    }

    static func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "synthetic.cleaner.selection." + UUID().uuidString))
    }

    @Test func incrementalTotalsMatchARecountAcrossNestedToggles() async throws {
        let categories = Self.nestedCategories(projects: 3_334)
        let model = await Self.model(categories, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        var generator = SystemRandomNumberGenerator()
        #expect(model.stats == Self.expected(model.visibleCategories))
        for step in 0..<300 {
            let category = categories[Int.random(in: 0..<categories.count, using: &generator)]
            switch step % 10 {
            case 0: model.toggleCategory(category.id)
            case 1: model.toggleAll()
            default:
                let item = category.items[
                    Int.random(in: 0..<category.items.count, using: &generator)]
                model.toggleItem(categoryID: category.id, itemID: item.id)
            }
            if step % 25 == 0 { #expect(model.stats == Self.expected(model.visibleCategories)) }
        }
        #expect(model.stats == Self.expected(model.visibleCategories))
    }

    @Test func nestedFoldersCountOnceInTheTotalButStayInTheirOwnCategory() async throws {
        let categories = Self.nestedCategories(projects: 1)
        let model = await Self.model(categories, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        if model.overallSelection != .all { model.toggleAll() }
        #expect(model.selectedItemCount == 1)
        #expect(model.selectedTotal == 50_000)
        #expect(model.selectedItemCount(categoryID: "nodeModules") == 1)
        #expect(model.selectedTotal(categoryID: "nodeModules") == 20_000)
        model.toggleCategory(Worktrees.categoryID)
        #expect(model.selectedItemCount == 1)
        #expect(model.selectedTotal == 20_000)
    }

    @Test func togglesAtTenThousandItemsLeaveRowsAndListUntouched() async throws {
        let model = await CleanerSyntheticFixture.engine(
            items: 10_000, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        for category in model.categories { model.toggleExpand(category.id) }
        let list = model.list
        let category = try #require(model.categories.first)
        model.toggleItem(categoryID: category.id, itemID: try #require(category.items.first).id)
        model.toggleCategory(category.id)
        model.toggleAll()
        #expect(model.list == list)
        #expect(model.list.rows.count > 10_000)
    }

    @Test func everyToggleFitsInOneFrameAtTenThousandItems() async throws {
        let model = await CleanerSyntheticFixture.engine(
            items: 10_000, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        let clock = ContinuousClock()
        let category = try #require(model.categories.max { $0.items.count < $1.items.count })
        let items = category.items.prefix(20)
        func slowest(_ action: () -> Void) -> Duration {
            (0..<20).map { _ in clock.measure(action) }.sorted()[17]
        }
        var itemCursor = items.startIndex
        let item = slowest {
            model.toggleItem(categoryID: category.id, itemID: items[itemCursor].id)
            itemCursor =
                itemCursor == items.index(before: items.endIndex)
                ? items.startIndex : items.index(after: itemCursor)
        }
        let group = slowest { model.toggleCategory(category.id) }
        let all = slowest { model.toggleAll() }
        model.search = "atlas-"
        let searched = slowest { model.toggleAll() }
        let frame = Duration.milliseconds(16)
        #expect(item < frame, "item toggle took \(item)")
        #expect(group < frame, "category toggle took \(group)")
        #expect(all < frame, "select all took \(all)")
        #expect(searched < frame, "searched select all took \(searched)")
    }

    @Test func selectAllWithASearchOnlyChangesMatchingRows() async throws {
        let model = await CleanerSyntheticFixture.engine(items: 400, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        let before = model.visibleCategories
        model.search = "ATLAS-"
        model.toggleAll()
        let after = model.visibleCategories
        let matches = { (item: JunkItem) in
            item.name.lowercased().contains("atlas-")
                || item.worktree?.branch?.lowercased().contains("atlas-") == true
        }
        let pairs = zip(before.flatMap(\.items), after.flatMap(\.items))
        #expect(pairs.contains { matches($0.0) && !$0.0.selected })
        #expect(pairs.allSatisfy { matches($0.0) ? $0.1.selected : $0.1.selected == $0.0.selected })
        #expect(model.overallSelection == .all)

        model.toggleAll()
        #expect(model.overallSelection == .none)
        let cleared = model.visibleCategories.flatMap(\.items)
        #expect(
            zip(before.flatMap(\.items), cleared).allSatisfy {
                matches($0.0) ? !$0.1.selected : $0.1.selected == $0.0.selected
            })

        model.search = "no-such-project"
        let untouched = model.selection
        model.toggleAll()
        #expect(model.selection == untouched)
    }

    @Test func categoryCheckboxWithASearchOnlyChangesMatchingRows() async throws {
        let model = await CleanerSyntheticFixture.engine(items: 400, defaults: try Self.defaults())
        defer { Task { await model.shutdown() } }
        let category = try #require(model.categories.first)
        let unmatched = try #require(category.items.first { !$0.name.contains("beacon-") })
        let before = model.isSelected(categoryID: category.id, itemID: unmatched.id)
        model.search = "beacon-"
        model.toggleCategory(category.id)
        #expect(model.categorySelection(category.id) != .none)
        #expect(model.isSelected(categoryID: category.id, itemID: unmatched.id) == before)
    }

    @Test func pageSendsItsSearchSoTheEngineMatchesItsSelection() async throws {
        let harness = try await CleanerPageSyncTests.harness(items: 400)
        defer { Task { await harness.stop() } }
        harness.ui.search = "Cobalt-"
        harness.ui.toggleAll()
        harness.ui.toggleCategory(try #require(harness.ui.categories.last).id)
        try await harness.settle()
        #expect(harness.ui.selection == harness.engine.selection)
        #expect(harness.engine.search.isEmpty)
        let actions = harness.bridge.replies.filter { $0.operation == "cleaner.ui.action" }
        #expect(actions.allSatisfy { $0.bytes < 64 })
    }

    @Test func selectionPersistsCompactlyAndDropsVanishedItems() async throws {
        let defaults = try Self.defaults()
        let categories = CleanerSyntheticFixture.categories(items: 10_000)
        defaults.set(["stale": true], forKey: "cleanerSelectionOverrides")
        let model = await Self.model(categories, defaults: defaults)
        #expect(defaults.object(forKey: "cleanerSelectionOverrides") == nil)
        if model.overallSelection != .all { model.toggleAll() }
        let category = try #require(categories.first)
        let kept = try #require(category.items.first)
        let vanished = try #require(category.items.last)
        model.toggleItem(categoryID: category.id, itemID: kept.id)
        model.toggleItem(categoryID: category.id, itemID: vanished.id)
        await model.shutdown()
        let stored = try #require(defaults.data(forKey: "cleanerSelection"))
        #expect(stored.count < 2_048)

        var shrunk = categories
        shrunk[0].items.removeLast()
        let restored = await Self.model(shrunk, defaults: defaults)
        defer { Task { await restored.shutdown() } }
        #expect(!restored.isSelected(categoryID: category.id, itemID: kept.id))
        #expect(restored.selection.choices[category.id]?.exceptions == [kept.id])
        #expect(restored.selectedItemCount == 9_998)
    }
}
