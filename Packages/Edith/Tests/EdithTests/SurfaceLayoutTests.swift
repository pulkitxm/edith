import Foundation
import Testing

@testable import EdithKit

struct SurfaceLayoutTests {
    @Test func packingFillsSpaceBelowShorterWidgetsAndRespectsExactPositions() {
        let tiles = [SurfaceTile(.calendar), SurfaceTile(.usage), SurfaceTile(.music)]
        let frames = SurfaceGridPacking.pack(
            tiles: tiles, columns: 24, heights: [80, 240, 100], rowHeight: 8, gap: 8)
        #expect(frames[0].column == 0 && frames[0].row == 0)
        #expect(frames[1].column == 12 && frames[1].row == 0)
        #expect(frames[2].column == 0 && frames[2].row == 11)
        var pinned = SurfaceTile(.focus)
        pinned.column = 3
        pinned.row = 7
        pinned.span = 6
        let placed = SurfaceGridPacking.pack(
            tiles: [pinned], columns: 24, heights: [80], rowHeight: 8, gap: 0)
        #expect(placed == [.init(column: 3, row: 7, span: 6, rows: 10)])
    }

    @Test func packingNeverOverlapsAndUsesConfiguredHeight() {
        var tiles = SurfaceWidget.allCases.map { SurfaceTile($0) }
        for index in tiles.indices {
            tiles[index].span = [5, 8, 12, 24][index % 4]
            tiles[index].column = index % 2 == 0 ? 0 : nil
            tiles[index].row = index % 2 == 0 ? 0 : nil
        }
        tiles[0].height = 144
        let frames = SurfaceGridPacking.pack(
            tiles: tiles, columns: 24, heights: Array(repeating: 72, count: tiles.count),
            rowHeight: 8, gap: 8)
        #expect(frames[0].rows == 19)
        for index in frames.indices {
            #expect(frames[index].column + frames[index].span <= 24)
            for next in frames.indices where next > index {
                #expect(!frames[index].overlaps(frames[next]))
            }
        }
    }

    @Test func gridSettingsAndContentChoicesPersistAndNormalize() {
        var layout = SurfaceLayout.standard(.home)
        layout.columns = 0
        layout.gap = -10
        layout.padding = 200
        layout.rowHeight = 0
        layout.notchHorizontal = false
        layout.tiles[0].span = 100
        layout.tiles[0].height = 1
        layout.tiles[0].showDetails = false
        layout.tiles[0].itemLimit = 200
        let clean = layout.normalized()
        #expect(clean.columns == 4 && clean.tiles[0].span == 4)
        #expect(clean.gap == 0 && clean.padding == 32 && clean.rowHeight == 1)
        #expect(clean.tiles[0].height == 64 && clean.tiles[0].itemLimit == 20)
        #expect(!clean.tiles[0].showDetails)
        #expect(!clean.notchHorizontal)
        #expect(SurfaceLayout.decode(clean.encoded, target: .home) == clean)
        layout.tiles[0].column = 0
        layout.tiles[0].row = 10
        layout.arrangeAutomatically()
        #expect(layout.tiles.allSatisfy { $0.column == nil && $0.row == nil })
    }

    @Test func placementPreservesConfigurationAndHasStableInsertion() {
        var layout = SurfaceLayout.standard(.home)
        layout.tiles[0].title = "Across the world"
        layout.place(.clocks, before: SurfaceWidget.usage.id)
        #expect(
            layout.tiles.map(\.widget) == [
                .actions, .activity, .calendar, .clocks, .usage, .limits, .music, .codeStats,
            ])
        #expect(layout.tiles.first { $0.widget == .clocks }?.title == "Across the world")
        layout.place(.focus, before: SurfaceWidget.actions.id)
        #expect(layout.tiles.first?.widget == .focus)
        layout.place(.focus)
        #expect(layout.tiles.last?.widget == .focus)
        #expect(layout.tiles.filter { $0.widget == .focus }.count == 1)
    }

    @Test func normalizedLayoutRejectsDuplicatesAndBoundsSettings() {
        var tile = SurfaceTile(.focus)
        tile.focusMinutes = -100
        tile.title = String(repeating: "a", count: 200)
        tile.days = 0
        let layout = SurfaceLayout(tiles: [tile, tile]).normalized()
        #expect(layout.tiles.count == 1)
        #expect(layout.tiles[0].focusMinutes == 1)
        #expect(layout.tiles[0].days == 30)
        #expect(layout.tiles[0].title.count == 64)
        #expect(SurfaceLayout.decode(layout.encoded, target: .home) == layout)
        #expect(SurfaceLayout.decode("broken", target: .notch) == .standard(.notch))
        #expect(SurfaceLayout.decode(SurfaceLayout(tiles: []).encoded, target: .home).tiles.isEmpty)
    }

    @Test func tabsKeepHomeReachableAndRestoreHiddenWidgetsOnDrop() {
        var layout = SurfaceLayout.standard(.notch)
        layout.tabOrder = ["camera", "camera", "unknown"]
        layout.hiddenTabs = ["home", "camera", "unknown"]
        layout.tiles[0].hidden = true
        let normalized = layout.normalized()
        #expect(normalized.tabOrder.first == "camera")
        #expect(Set(normalized.tabOrder) == Set(SurfaceNotchTab.allCases.map(\.rawValue)))
        #expect(normalized.hiddenTabs == ["camera"])
        layout.place(.music)
        #expect(layout.visible.last?.widget == .music)
    }

    @MainActor @Test func titlesPreserveSpacesWhileTypingAndUseCleanDisplayLabels() throws {
        let domain = "test.surface-title.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SurfaceLayoutStore(defaults: defaults)
        for character in "Deep work " {
            store.update(.home) { $0.tiles[0].title.append(character) }
        }
        #expect(store.home.tiles[0].title == "Deep work ")
        #expect(store.home.tiles[0].displayTitle == "Deep work")
        #expect(SurfaceLayoutStore(defaults: defaults).home.tiles[0].title == "Deep work ")
        store.update(.home) { $0.tiles[0].title = "   " }
        #expect(store.home.tiles[0].displayTitle == SurfaceWidget.clocks.title)
    }

    @Test func rowsHonorOrderWideTilesAndHiddenTiles() {
        var hidden = SurfaceTile(.calendar)
        hidden.hidden = true
        let layout = SurfaceLayout(tiles: [
            .init(.music), .init(.limits), .init(.actions, size: .wide), hidden, .init(.focus),
        ])
        #expect(
            layout.rows(singleColumn: false).map { $0.map(\.widget) } == [
                [.music, .limits], [.actions], [.focus],
            ])
        #expect(
            layout.rows(singleColumn: true).map { $0.map(\.widget) } == [
                [.music], [.limits], [.actions], [.focus],
            ])
    }

    @MainActor @Test func historyAndExternalChangesStayIndependentAcrossSurfaces() throws {
        let domain = "test.surface-layout.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SurfaceLayoutStore(defaults: defaults)
        store.update(.notch) { $0.place(.focus) }
        store.update(.home) { $0.tiles = [] }
        store.undo(.notch)
        #expect(store.notch == .standard(.notch))
        #expect(store.home.tiles.isEmpty)
        store.redo(.notch)
        #expect(store.notch.tiles.last?.widget == .focus)
        #expect(SurfaceLayoutStore(defaults: defaults).notch == store.notch)
        defaults.set(
            SurfaceLayout(tiles: [.init(.agents)]).encoded, forKey: SurfaceTarget.notch.key)
        store.reload()
        #expect(store.notch.tiles.map(\.widget) == [.agents])
        #expect(!store.canUndo(.notch))
        #expect(store.canUndo(.home))
    }
}
