import AppKit
import EdithExtensionUI
import SwiftUI
import Testing

extension SurfaceGridRenderingTests {
    @Test func activityCalendarKeepsCellsWithinCompactWideAndZoomedSurfaces() async throws {
        let prior = UIScale.current
        defer { UIScale.apply(prior) }
        for (width, zoom) in [(360.0, 1.6), (560.0, 1.0), (1800.0, 1.0)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let weeks = (0..<28).map { week in
                    ActivityCalendarWeek(
                        id: week, monthLabel: week % 4 == 0 ? "Sep" : "",
                        cells: (0..<7).map { day in
                            ActivityCalendarDay(
                                id: "\(week)-\(day)", date: Date(timeIntervalSince1970: 0),
                                value: 10, level: 4)
                        })
                }
                let view = ActivityCalendarGrid(weeks: weeks, dark: scheme == .dark) { _ in
                    Text("Synthetic activity")
                }
                .frame(width: width, height: UIScale.pt(180), alignment: .leading)
                .environment(\.colorScheme, scheme)
                .environment(\.automaticViewActionsEnabled, false)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: UIScale.pt(180))
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
                var colored = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                            max(color.redComponent, color.greenComponent, color.blueComponent)
                                - min(color.redComponent, color.greenComponent, color.blueComponent)
                                > 0.15
                        else { continue }
                        colored += 1
                    }
                }
                #expect(colored > 100)
                #expect(bitmap.pixelsWide >= Int(width))
            }
        }
    }

    @Test func activityCalendarStartsAtTheLeadingEdgeForEveryRangeAndWidth() async throws {
        let prior = UIScale.current
        defer { UIScale.apply(prior) }
        UIScale.apply(1)
        for fills in [true, false] {
            for count in [1, 3, 6, 7, 8, 12, 20, 53] {
                for width in [480.0, 1000.0, 1500.0] {
                    let weeks = (0..<count).map { week in
                        ActivityCalendarWeek(
                            id: week, monthLabel: week % 4 == 0 ? "Sep" : "",
                            cells: (0..<7).map { day in
                                ActivityCalendarDay(
                                    id: "\(week)-\(day)", date: Date(timeIntervalSince1970: 0),
                                    value: 10, level: 4)
                            })
                    }
                    let view = ActivityCalendarGrid(
                        weeks: weeks, dark: true, fillsWidth: fills
                    ) { _ in
                        Text("Synthetic activity")
                    }
                    .frame(width: width, height: 300, alignment: .leading)
                    .environment(\.colorScheme, .dark)
                    .environment(\.automaticViewActionsEnabled, false)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                        defer: false)
                    window.isReleasedWhenClosed = false
                    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                    window.contentView = host
                    window.orderBack(nil)
                    defer { window.orderOut(nil); window.close() }
                    try await Task.sleep(for: .milliseconds(40))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(
                        host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let scale = CGFloat(bitmap.pixelsWide) / width
                    var leading = Int.max
                    for x in 0..<bitmap.pixelsWide where x < leading {
                        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                            guard
                                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(
                                    .deviceRGB),
                                max(color.redComponent, color.greenComponent, color.blueComponent)
                                    - min(
                                        color.redComponent, color.greenComponent,
                                        color.blueComponent) > 0.15
                            else { continue }
                            leading = x
                            break
                        }
                    }
                    let label = "fills \(fills) weeks \(count) width \(width)"
                    #expect(leading != .max, "\(label)")
                    #expect(CGFloat(leading) / scale <= 40, "\(label) starts at \(leading)")
                }
            }
        }
    }
}
