import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SurfaceGridRenderingTests {
    @MainActor final class Frames {
        var values: [String: CGRect] = [:]
        var shelfHeight = 0.0
    }

    @Test func shelfAlignsCardsAndRetainsExplicitScrollingHeight() async throws {
        for explicit in [false, true] {
            let frames = Frames()
            var tile = SurfaceTile(.clocks)
            tile.shelfWidth = 200
            tile.height = explicit ? 220 : nil
            var layout = SurfaceLayout(tiles: [tile])
            layout.notchShelfHeight = 400
            let host = NSHostingView(
                rootView: SurfaceShelf(
                    layout: layout, measuredHeight: { frames.shelfHeight = $0 }
                ) { _ in
                    Text("Sample clock").frame(maxWidth: .infinity).frame(height: 80)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            frames.values["clock"] = $0
                        }
                })
            host.frame = CGRect(x: 0, y: 0, width: 580, height: 600)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<20 {
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            let bounds = try #require(frames.values["clock"])
            #expect(abs(bounds.width - 200) < 1)
            if explicit {
                #expect(frames.shelfHeight >= 220)
                #expect(frames.shelfHeight < 300)
            } else {
                #expect(frames.shelfHeight >= 400)
                #expect(frames.shelfHeight < 450)
            }
        }
    }

    @Test func nativeGridPacksBelowShortCardsWithoutOverlappingTallNeighbors() async throws {
        let frames = Frames()
        var layout = SurfaceLayout(tiles: [.init(.calendar), .init(.usage), .init(.music)])
        layout.balancedRows = false
        let host = NSHostingView(
            rootView: SurfaceCanvas(layout: layout, singleColumn: false) { tile in
                Text(tile.displayTitle)
                    .frame(maxWidth: .infinity)
                    .frame(height: tile.widget == .usage ? 260 : 100)
                    .onGeometryChange(for: CGRect.self) {
                        $0.frame(in: .named("gridTest"))
                    } action: {
                        frames.values[tile.id] = $0
                    }
            }.coordinateSpace(name: "gridTest"))
        host.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<10 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            if frames.values.count == 3 { break }
        }
        let short = try #require(frames.values[SurfaceWidget.calendar.id])
        let tall = try #require(frames.values[SurfaceWidget.usage.id])
        let next = try #require(frames.values[SurfaceWidget.music.id])
        #expect(abs(short.width - tall.width) < 1)
        #expect(next.minY >= short.maxY)
        #expect(next.minY < tall.maxY)
        #expect(next.minX == short.minX)
        #expect(!next.intersects(tall))
        #expect(tall.maxX <= 800)
    }

    @Test func automaticRowsFillWidthAndStretchShortNeighbors() async throws {
        for count in [3, 4, 5, 7] {
            let frames = Frames()
            var layout = SurfaceLayout(tiles: [])
            for _ in 0..<count { layout.add(.clocks) }
            let host = NSHostingView(
                rootView: SurfaceCanvas(
                    layout: layout, singleColumn: false,
                    measured: { frames.values[$0] = $1 }
                ) { tile in
                    Text("Sample widget").frame(maxWidth: .infinity)
                        .frame(height: tile.id == layout.tiles[1].id ? 240 : 100)
                })
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 1200, height: 1000)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            for _ in 0..<20 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(frames.values.count == count)
            let rows = Dictionary(grouping: frames.values.values, by: { $0.minY })
            for row in rows.values {
                #expect(abs((row.map(\.minX).min() ?? -1)) < 1)
                #expect(abs((row.map(\.maxX).max() ?? 0) - 1200) < 1)
                #expect(Set(row.map(\.height)).count == 1)
            }
            let first = try #require(frames.values[layout.tiles[0].id])
            let second = try #require(frames.values[layout.tiles[1].id])
            #expect(first.height == second.height)
            #expect(first.height >= 240)
        }
    }
}
