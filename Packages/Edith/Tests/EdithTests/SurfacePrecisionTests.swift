import Foundation
import Testing

@testable import EdithKit

struct SurfacePrecisionTests {
    @Test @MainActor func widgetAppearanceSurvivesProfilesDuplicatesAndUndo() throws {
        let suite = "SurfaceAppearance-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SurfaceLayoutStore(defaults: defaults)
        let id = store.home.tiles[0].id
        store.update(.home) { layout in
            layout.tiles[0].accentHex = "d77958"
            layout.tiles[0].metricColumns = 3
        }
        #expect(store.home.tiles[0].accentHex == "D77958")
        #expect(store.saveProfile("Custom", target: .home))
        store.update(.home) { _ = $0.duplicate(id) }
        let copy = store.home.tiles[1]
        #expect(copy.accentHex == "D77958" && copy.metricColumns == 3)
        store.update(.home) {
            $0.tiles[0].accentHex = "not a color"; $0.tiles[0].metricColumns = Int.max
        }
        #expect(store.home.tiles[0].accentHex == nil && store.home.tiles[0].metricColumns == 6)
        #expect(store.home.tiles[1] == copy)
        store.undo(.home)
        #expect(store.home.tiles[0].accentHex == "D77958")
        let restored = SurfaceLayoutStore(defaults: defaults)
        #expect(restored.home.tiles[0].metricColumns == 3)
        #expect(restored.profiles(.home).first?.layout.tiles[0].accentHex == "D77958")
    }
    @Test func resamplingPreservesProportionsPositionsAndContent() {
        var tile = SurfaceTile(.github)
        tile.span = 8; tile.column = 16; tile.row = 80; tile.height = 240
        tile.locked = true; tile.sourceIDs = ["sample/app"]
        var layout = SurfaceLayout(tiles: [tile])
        layout.resampleGrid(columns: 192, snap: 1)
        #expect(layout.tiles[0].span == 64)
        #expect(layout.tiles[0].column == 128)
        #expect(layout.tiles[0].row == 640)
        #expect(layout.tiles[0].height == 240)
        #expect(layout.tiles[0].locked)
        #expect(layout.tiles[0].sourceIDs == ["sample/app"])
        layout.resampleGrid(columns: 24, snap: 8)
        #expect(layout.tiles == [tile])
        let id = layout.add(.machines)
        #expect(layout.tiles.first { $0.id == id }?.span == 12)
        layout.resampleGrid(columns: 192)
        let second = layout.add(.machines)
        #expect(layout.tiles.first { $0.id == second }?.span == 96)
    }
    @Test func nonfiniteGeometryIsNormalizedBeforeRenderingOrEncoding() {
        var tile = SurfaceTile(.music)
        tile.height = .nan; tile.shelfWidth = .infinity
        tile.paddingOverride = -.infinity; tile.cornerOverride = .nan
        tile.row = .max; tile.span = .max
        var layout = SurfaceLayout(tiles: [tile])
        layout.columns = .max; layout.gap = .nan; layout.padding = .infinity
        layout.cornerRadius = -.infinity; layout.rowHeight = .nan
        layout.notchWidth = .nan; layout.notchShelfHeight = .infinity
        let normalized = layout.normalized()
        #expect(normalized.columns == 192)
        #expect(normalized.tiles[0].height == nil)
        #expect(normalized.tiles[0].row == SurfaceLayout.maximumRow)
        #expect(normalized.gap == 12 && normalized.rowHeight == 8)
        #expect(normalized.notchWidth == 580 && normalized.notchShelfHeight == 240)
        #expect(!normalized.encoded.isEmpty)
        let positions = SurfaceGridPacking.pack(
            tiles: [tile], columns: .max, heights: [.nan], rowHeight: .nan, gap: .infinity)
        #expect(positions.count == 1 && positions[0].rows > 0)
    }
    @Test func finePackingKeepsLockedGeometryAndAvoidsAllCollisions() {
        var tiles = (0..<30).map { index in
            var tile = SurfaceTile(.machines)
            tile.instanceID = "sample-\(index)"; tile.span = 64
            return tile
        }
        tiles[0].locked = true; tiles[0].column = 64; tiles[0].row = 300
        let result = SurfaceGridPacking.pack(
            tiles: tiles, columns: 192, heights: Array(repeating: 600, count: 30), rowHeight: 1,
            gap: 12)
        #expect(result[0].column == 64 && result[0].row == 300)
        for i in result.indices {
            for j in result.indices where j > i { #expect(!result[i].overlaps(result[j])) }
        }
    }
    @Test @MainActor func savedLayoutsAreIndependentPersistentAndUndoable() throws {
        let suite = "SurfaceProfiles-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SurfaceLayoutStore(defaults: defaults)
        store.update(.home) { $0.resampleGrid(columns: 192, snap: 1) }
        #expect(store.saveProfile("Work", target: .home))
        #expect(store.saveProfile("Work", target: .notch))
        #expect(!store.saveProfile("work", target: .home))
        let profile = try #require(store.profiles(.home).first)
        store.update(.home) { $0.resampleGrid(columns: 24) }
        store.applyProfile(profile.id)
        #expect(store.home.columns == 192)
        store.undo(.home)
        #expect(store.home.columns == 24)
        #expect(store.renameProfile(profile.id, name: "Development"))
        #expect(store.profiles(.home).first?.layout.columns == 192)
        let restored = SurfaceLayoutStore(defaults: defaults)
        #expect(restored.profiles(.home).first?.name == "Development")
        store.removeProfile(profile.id)
        #expect(store.profiles(.home).isEmpty)
        restored.reload()
        #expect(restored.profiles(.home).isEmpty)
        #expect(store.restoreProfile(.home))
        #expect(store.profiles(.home).first?.id == profile.id)
        restored.reload()
        #expect(restored.profiles(.home).first?.id == profile.id)
        #expect(store.profiles(.notch).count == 1)
    }
    @Test @MainActor func savedLayoutLimitsDoNotOverwriteExistingEntries() throws {
        let suite = "SurfaceProfileBounds-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SurfaceLayoutStore(defaults: defaults)
        for index in 0..<20 { #expect(store.saveProfile("Layout \(index)", target: .home)) }
        #expect(
            store.profiles(.home).prefix(3).map(\.name) == ["Layout 0", "Layout 1", "Layout 2"])
        #expect(!store.saveProfile("Overflow", target: .home))
        #expect(!store.saveProfile("  ", target: .home))
        let profile = try #require(store.profiles(.home).first)
        store.removeProfile(profile.id)
        #expect(store.saveProfile(profile.name, target: .home))
        #expect(!store.restoreProfile(.home))
        #expect(store.profiles(.home).count == 20)
    }
}
