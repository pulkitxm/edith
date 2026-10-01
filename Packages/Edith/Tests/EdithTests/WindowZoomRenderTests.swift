import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithDocs
@testable import EdithKit

@MainActor @Suite(.serialized) struct WindowZoomRenderTests {
    init() {
        _ = TestWindowHost.application
    }

    @Test func docsPageRendersAtEveryZoomWithoutClipping() throws {
        defer { UIScale.apply(1) }
        let scales = [0.8, 1.0, 1.3, 1.6]
        let browser = Self.browser()
        let directory = URL(fileURLWithPath: "/tmp/edith-zoom-renders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var titleWidths: [CGFloat] = []
        var shots: [(String, NSImage)] = []
        for scale in scales {
            UIScale.apply(scale)
            let width = 1_180 * scale
            let height = 760 * scale
            let bitmap = try #require(
                Self.render(DocsScreen(browser: browser), width: width, height: height))
            #expect(TestWindowHost.exposedWindows.isEmpty)
            #expect(Self.inkFraction(bitmap) > 0.02)
            let title = Self.fittingWidth(
                "Harbor orders", size: DocsTypography.headings[1] ?? 26, weight: .semibold)
            let header = Self.fittingWidth("Docs", size: PageMetrics.titleSize, weight: .semibold)
            let sidebar = Self.fittingWidth("Harbor orders", size: 12, weight: .semibold)
            let content = Self.contentWidth(windowWidth: width)
            #expect(content >= 280)
            #expect(title < content)
            #expect(header < width - PageMetrics.gutter(false) * 2 - UIScale.pt(80))
            #expect(sidebar < UIScale.pt(DocsNavigation.navigationWidth) - UIScale.pt(54))
            titleWidths.append(title)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = String(format: "docs-%.1f.png", scale)
            try data.write(to: directory.appendingPathComponent(name))
            shots.append((String(format: "%.1f", scale), try #require(NSImage(data: data))))
        }
        #expect(titleWidths.count == scales.count)
        for pair in zip(titleWidths, titleWidths.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
        let unit = titleWidths[1]
        for (scale, width) in zip(scales, titleWidths) {
            #expect(abs(width / unit - scale) < 0.12)
        }
        try Self.writeGrid(shots, to: directory.appendingPathComponent("docs-zoom-grid.png"))
    }

    private static func browser() -> DocsBrowser {
        let library = DocsLibrary(sources: [
            DocsSource(
                path: "README.md",
                markdown: """
                    # Reference

                    Sample pages for the catalog.
                    """),
            DocsSource(
                path: "catalog/README.md",
                markdown: """
                    # Harbor orders

                    Browse the sample catalog. Columns stay on one line when the window scale changes.

                    ## Columns

                    | Field | Kind | Sample |
                    | --- | --- | --- |
                    | customer | text | Northwind Supply |
                    | status | text | active |
                    | total | numeric | 128.40 |
                    | created | timestamp | 2026-08-14 |

                    ## Notes

                    - Keep the customer column readable.
                    - Status stays on one line.
                    - Totals use a fixed sample of 128.40.

                    ```
                    select customer, status, total from orders
                    ```
                    """),
        ])
        let browser = DocsBrowser(library: library, filterDelay: .milliseconds(0))
        browser.expandedGroups.insert("catalog")
        browser.open(DocsLocation(path: "catalog/README.md"), reveal: false)
        return browser
    }

    private static func contentWidth(windowWidth: CGFloat) -> CGFloat {
        let outline = windowWidth >= UIScale.pt(DocsNavigation.outlineThreshold)
        let column =
            windowWidth - UIScale.pt(DocsNavigation.navigationWidth)
            - (outline ? UIScale.pt(DocsNavigation.outlineWidth) : 0)
        return min(
            column - PageMetrics.gutter(false) * 2, UIScale.pt(DocsNavigation.readableWidth))
    }

    private static func fittingWidth(
        _ text: String, size: CGFloat, weight: Font.Weight
    ) -> CGFloat {
        let host = NSHostingView(
            rootView: Text(text)
                .font(.system(size: UIScale.pt(size), weight: weight))
                .fixedSize()
                .environment(\.automaticViewActionsEnabled, false))
        host.frame = NSRect(x: 0, y: 0, width: 2_000, height: 240)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private static func render(
        _ view: some View, width: CGFloat, height: CGFloat
    ) -> NSBitmapImageRep? {
        let host = NSHostingView(
            rootView:
                view
                .environment(\.automaticViewActionsEnabled, false)
                .environment(\.colorScheme, .dark)
                .frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        return bitmap
    }

    private static func inkFraction(_ bitmap: NSBitmapImageRep) -> Double {
        guard let data = bitmap.bitmapData, bitmap.bitsPerPixel >= 24 else { return 0 }
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return 0 }
        let corner = (
            data[0], data[1], data[2]
        )
        var ink = 0
        var samples = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                if data[offset] != corner.0 || data[offset + 1] != corner.1
                    || data[offset + 2] != corner.2
                {
                    ink += 1
                }
                samples += 1
                x += 4
            }
            y += 4
        }
        return samples == 0 ? 0 : Double(ink) / Double(samples)
    }

    private static func writeGrid(_ shots: [(String, NSImage)], to url: URL) throws {
        let cell = NSSize(width: 720, height: 470)
        let canvas = NSSize(width: cell.width * 2, height: cell.height * 2)
        let image = NSImage(size: canvas)
        image.lockFocus()
        NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
        NSRect(origin: .zero, size: canvas).fill()
        for (index, shot) in shots.enumerated() {
            let column = CGFloat(index % 2)
            let row = CGFloat(index / 2)
            let rect = NSRect(
                x: cell.width * column, y: cell.height * (1 - row), width: cell.width,
                height: cell.height)
            let inset = rect.insetBy(dx: 16, dy: 18)
            let labelRect = NSRect(
                x: inset.minX, y: inset.maxY - 18, width: inset.width, height: 16)
            let imageRect = NSRect(
                x: inset.minX, y: inset.minY, width: inset.width, height: inset.height - 24)
            (shot.0 as NSString).draw(
                in: labelRect,
                withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
            shot.1.draw(
                in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: nil)
        }
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
