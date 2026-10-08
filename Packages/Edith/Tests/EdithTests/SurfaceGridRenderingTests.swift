import AppKit
import EdithKit
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SurfaceGridRenderingTests {
    @MainActor final class Frames {
        var values: [String: CGRect] = [:]
    }

    @Test func nativeGridPacksBelowShortCardsWithoutOverlappingTallNeighbors() async throws {
        let frames = Frames()
        let layout = SurfaceLayout(tiles: [.init(.calendar), .init(.usage), .init(.music)])
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
}
