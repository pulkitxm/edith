import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor @Suite(.serialized) struct SurfaceSampleRenderingTests {
    @Test func sampleDeveloperSelectionsUseStableSourcesAndRealProjections() throws {
        var github = SurfaceTile(.github)
        github.sourceIDs = ["sample/atlas"]
        github.contentKinds = ["review"]
        let review = SurfaceSampleData.snapshot(github)
        #expect(review.rows.count == 1)
        #expect(review.metrics.first { $0.id == "review" }?.value == "1")
        github.sourceIDs = []
        #expect(SurfaceSampleData.snapshot(github).rows.isEmpty)
        var database = SurfaceTile(.databases)
        let first = SurfaceSampleData.snapshot(database)
        let second = SurfaceSampleData.snapshot(database)
        #expect(first == second)
        database.sourceIDs = Set(first.sources.map(\.id))
        database.contentKinds = ["operations"]
        #expect(SurfaceSampleData.snapshot(database).rows.count == 1)
        #expect(SurfaceSampleData.snapshot(database).rows.first?.progress == 0.6)
    }

    @Test func actualHomeAndShelfRenderSampleDataInCompactZoomedAndRegularLayouts() throws {
        let defaults = SharedDefaults.store
        let previousHome = defaults.string(forKey: SurfaceTarget.home.key)
        let previousScale = UIScale.current
        defer {
            if let previousHome {
                defaults.set(previousHome, forKey: SurfaceTarget.home.key)
            } else {
                defaults.removeObject(forKey: SurfaceTarget.home.key)
            }
            SurfaceLayoutStore.shared.reload()
            UIScale.apply(previousScale)
        }
        let widgets: [SurfaceWidget] = [
            .agents, .limits, .codeStats, .github, .databases, .ability("companion"),
        ]
        var tiles = widgets.map { SurfaceTile($0) }
        for index in tiles.indices {
            tiles[index].span = 12; tiles[index].itemLimit = 3; tiles[index].showActions = false
        }
        let layout = SurfaceLayout(tiles: tiles)
        defaults.set(layout.encoded, forKey: SurfaceTarget.home.key)
        SurfaceLayoutStore.shared.reload()
        for compact in [false, true] {
            for dark in [true, false] {
                UIScale.apply(compact ? 1.25 : 1)
                let view = HomePage()
                    .environment(\.compactLayout, compact)
                    .environment(\.surfaceSampleContent, true)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let data = try render(
                    view, size: CGSize(width: compact ? 620 : 1200, height: compact ? 1500 : 900),
                    dark: dark)
                #expect(data.count > 10_000)
                try save(
                    data,
                    name: "home-\(compact ? "compact" : "regular")-\(dark ? "dark" : "light").png")
            }
        }
        UIScale.apply(1)
        let shelf = SurfaceShelf(layout: layout) { tile in
            SurfaceIntegrationCard(tile: tile, active: false, open: { _ in })
        }
        .environment(\.surfaceSampleContent, true)
        .environment(\.colorScheme, .dark)
        .background(Color.black)
        let data = try render(shelf, size: CGSize(width: 580, height: 360), dark: true)
        #expect(data.count > 10_000)
        try save(data, name: "shelf-sample-cards.png")
    }

    private func render(_ view: some View, size: CGSize, dark: Bool) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<5 {
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    @Test func actualMediaCardsRenderWithSampleControls() throws {
        let cards = HStack(alignment: .top, spacing: 12) {
            ForEach([SurfaceWidget.ability("audioMixer"), .ability("timeLapse")]) { widget in
                let tile = SurfaceTile(widget)
                SurfaceExtensionCard(
                    tile: tile, fixture: SurfaceSampleData.snapshot(tile), open: { _ in }
                )
                .frame(width: 280)
            }
        }.disabled(true).padding(12).environment(\.colorScheme, .dark).background(Color.black)
        let data = try render(cards, size: CGSize(width: 596, height: 430), dark: true)
        #expect(data.count > 10_000)
        try save(data, name: "media-sample-controls.png")
    }

    private func save(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_SURFACE_EVIDENCE_DIR"] else {
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }
}
