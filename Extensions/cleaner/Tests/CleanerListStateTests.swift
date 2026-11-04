import Foundation
import Testing

@testable import CleanerExtension

@MainActor
struct CleanerListStateTests {
    let now = Date()

    func state(
        _ categories: [JunkCategory], filters: CleanerFilters = CleanerFilters(),
        search: String = "", expanded: Set<String> = [], itemFilters: [String: String] = [:]
    ) -> CleanerListState {
        CleanerListState(
            categories: categories, filters: filters, search: search, expanded: expanded,
            itemFilters: itemFilters, now: now)
    }

    func itemRows(_ state: CleanerListState) -> [CleanerItemRow] {
        state.rows.compactMap {
            if case .item(let row) = $0.kind { return row }
            return nil
        }
    }

    @Test func collapsedCategoriesProduceOnlyHeaderRows() {
        let categories = CleanerSyntheticFixture.categories(items: 5_000, now: now)
        let state = state(categories)
        #expect(state.rows.count == categories.count * 2)
        #expect(itemRows(state).isEmpty)
        #expect(state.totalItemCount == 5_000)
    }

    @Test func expandedCategoryRowsHaveUniqueStableIDs() {
        let categories = CleanerSyntheticFixture.categories(items: 800, now: now)
        let expanded = Set(categories.map(\.id))
        let first = state(categories, expanded: expanded)
        let second = state(categories, expanded: expanded)
        #expect(Set(first.rows.map(\.id)).count == first.rows.count)
        #expect(first.rows.map(\.id) == second.rows.map(\.id))
        #expect(itemRows(first).count == 800)
        #expect(
            first.rows.filter {
                if case .itemFilter = $0.kind { return true }
                return false
            }.count == categories.count)
    }

    @Test func rowsCarryPrecomputedDisplayValues() throws {
        let categories = CleanerSyntheticFixture.categories(items: 64, now: now)
        let worktrees = try #require(categories.first { $0.id == Worktrees.categoryID })
        let state = state(categories, expanded: [worktrees.id])
        let rows = itemRows(state)
        let source = try #require(worktrees.items.first)
        let row = try #require(rows.first { $0.id == source.id })
        #expect(row.sizeText == JunkScanner.format(source.sizeBytes))
        #expect(row.ageText == CleanerAgeText.since(source.lastModified, now: now))
        #expect(row.branch == source.worktree?.branch)
        #expect(row.badges == CleanerListState.badges(try #require(source.worktree)))
    }

    @Test func selectionTotalsMatchSelectedItems() {
        let categories = CleanerSyntheticFixture.categories(items: 500, now: now)
        let state = state(categories)
        let selected = CleanerOperationExecution.selectedItems(in: categories)
        #expect(state.selectedItemCount == selected.count)
        #expect(state.selectedTotal == selected.reduce(0) { $0 + $1.sizeBytes })
        #expect(state.overallSelection == .some)
        for category in categories {
            let chosen = category.items.filter(\.selected)
            #expect(state.selectionByCategory[category.id]?.count == chosen.count)
        }
    }

    @Test func ageFilterHidesRecentItems() {
        let categories = CleanerSyntheticFixture.categories(items: 400, now: now)
        let state = state(categories, filters: CleanerFilters(minimumAge: 30 * 86_400))
        let admitted = categories.flatMap(\.items).filter {
            now.timeIntervalSince($0.lastModified ?? now) >= 30 * 86_400
        }
        #expect(state.totalItemCount == admitted.count)
        #expect(state.hiddenItemCount == 400 - admitted.count)
    }

    @Test func searchAndItemFilterNarrowRows() throws {
        let categories = CleanerSyntheticFixture.categories(items: 400, now: now)
        let expanded = Set(categories.map(\.id))
        let searched = state(categories, search: "ATLAS-", expanded: expanded)
        let names = itemRows(searched).map(\.name)
        #expect(!names.isEmpty)
        #expect(names.allSatisfy { $0.contains("atlas-") })

        let missing = state(categories, search: "no-such-project", expanded: expanded)
        #expect(!missing.matchesSearch)
        #expect(missing.rows.isEmpty)

        let category = try #require(categories.first)
        let filtered = state(
            categories, expanded: [category.id], itemFilters: [category.id: "beacon-"])
        let filteredRows = itemRows(filtered)
        #expect(!filteredRows.isEmpty)
        #expect(filteredRows.allSatisfy { $0.name.contains("beacon-") })
        #expect(filteredRows.count < category.items.count)
    }

    @Test func selectAllTogglesOffWhenSelectedFoldersAreNested() async throws {
        let worktree = URL(fileURLWithPath: "/synthetic/code/atlas-feature")
        let nested = worktree.appendingPathComponent("node_modules")
        let categories = [
            JunkCategory(
                id: Worktrees.categoryID, name: "Git worktrees", detail: "",
                items: [
                    JunkItem(
                        id: worktree.path, name: "atlas-feature", path: worktree,
                        sizeBytes: 8_192, selected: false)
                ]),
            JunkCategory(
                id: "nodeModules", name: "node_modules", detail: "",
                items: [
                    JunkItem(
                        id: nested.path, name: "atlas-feature/node_modules", path: nested,
                        sizeBytes: 4_096, selected: false)
                ]),
        ]
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.cleaner.nested." + UUID().uuidString))
        let model = CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] }, scan: { _, _, _ in CleanerScanResult(categories: categories) }))
        defer { Task { await model.shutdown() } }
        model.scan()
        await model.finishWork()

        model.toggleAll()
        #expect(model.overallSelection == .all)
        #expect(model.selectedItemCount == 1)

        model.toggleAll()
        #expect(model.overallSelection == .none)
        #expect(model.categories.allSatisfy { $0.items.allSatisfy { !$0.selected } })
    }

    @Test func modelRebuildsRowsWhenInputsChange() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "synthetic.cleaner.rows." + UUID().uuidString))
        let model = await CleanerSyntheticFixture.engine(items: 300, defaults: defaults)
        defer { Task { await model.shutdown() } }
        let category = try #require(model.categories.first)
        let collapsed = model.list.rows.count

        model.toggleExpand(category.id)
        #expect(model.list.rows.count == collapsed + 1 + category.items.count)

        let item = try #require(category.items.first)
        model.toggleItem(categoryID: category.id, itemID: item.id)
        let row = try #require(itemRows(model.list).first { $0.id == item.id })
        #expect(row.selected != item.selected)

        model.setItemFilter("no-such-folder", categoryID: category.id)
        #expect(model.list.rows.count == collapsed + 1)

        model.search = "no-such-project"
        #expect(model.list.rows.isEmpty)
    }
}
