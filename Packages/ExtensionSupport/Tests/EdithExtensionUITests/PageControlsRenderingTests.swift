import AppKit
import SwiftUI
import Testing
@testable import EdithExtensionUI

extension SurfaceGridRenderingTests {
    @Test func pageControlsRenderAtCompactAndRegularWidths() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(360.0, 1.6), (900.0, 1.0)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let content = VStack(spacing: 16) {
                    AdaptiveChartLegend(
                        items: (0..<8).map {
                            ChartLegendItem(
                                id: "series-\($0)", label: "Synthetic series \($0)", color: .red)
                        })
                    WrapHStack {
                        ForEach(0..<8) { index in Text("Synthetic filter \(index)").padding(4) }
                    }
                    PageMetric(
                        title: "Commits", value: "1,234", detail: "Synthetic activity",
                        symbol: "arrow.triangle.branch", trend: "12%")
                    PageSkeletonControls()
                }
                .frame(width: width, height: 500)
                .environment(\.colorScheme, scheme)
                .environment(\.automaticViewActionsEnabled, false)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 500)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.contentView = host
                window.orderBack(nil)
                defer { window.orderOut(nil); window.close() }
                try await Task.sleep(for: .milliseconds(60))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(bitmap.pixelsWide >= Int(width))
                #expect(bitmap.pixelsHigh >= 500)
                var colored = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                            color.redComponent > color.greenComponent + 0.15,
                            color.redComponent > color.blueComponent + 0.15
                        else { continue }
                        colored += 1
                    }
                }
                #expect(colored > 10)
                #expect(host.fittingSize.width <= width + 1)
            }
        }
    }

    @Test func scrollPositionsKeepIndependentPageSelections() {
        let positions = PageScrollPositions()
        #expect(positions["overview"] == .zero)
        positions["overview"] = CGPoint(x: 0, y: 250)
        positions["repositories"] = CGPoint(x: 0, y: 900)
        #expect(positions["overview"].y == 250)
        #expect(positions["repositories"].y == 900)
        #expect(PageMetrics.tableNameWidth(viewport: 100, fixedWidth: 100, columnCount: 8) == 0)
    }

}
