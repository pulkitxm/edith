import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import CodeStatsExtension

@MainActor @Suite(.serialized) struct CodeStatsPageRenderingTests {
    @Test func fullStatisticsPageRendersSyntheticContentAtCompactWideAndZoomedSizes() async throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (width, zoom) in [(360.0, 1.6), (900.0, 1.0)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                let suite = "test.edith.code-stats.render.\(UUID().uuidString)"
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let report = CodeStatsPageFixture.report()
                let service = CodeStatsFakeAgent(
                    status: CodeStatsPageFixture.status(
                        reportedAt: CodeStatsPageFixture.date("2026-10-05")),
                    reports: [.days(90): report])
                service.facts = CodeStatsFactBuilder.build(commits: CodeStatsPageFixture.commits)
                let model = CodeStatsModel(
                    service: service.service, defaults: defaults,
                    calendar: CodeStatsPageFixture.calendar,
                    today: { CodeStatsPageFixture.date("2026-10-05") })
                await model.refresh()
                #expect(model.report?.totals.commits == 4)
                let view = CodeStatsPage(model: model)
                    .frame(width: width, height: 800)
                    .environment(\.compactLayout, width < 600)
                    .environment(\.colorScheme, scheme)
                    .environment(\.automaticViewActionsEnabled, false)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.contentView = host
                window.orderBack(nil)
                defer { window.orderOut(nil); window.close(); model.cancelLoading() }
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                #expect(host.fittingSize.width <= width + 1)
                var colored = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                            color.redComponent > color.blueComponent + 0.1,
                            color.redComponent > color.greenComponent + 0.05
                        else { continue }
                        colored += 1
                    }
                }
                #expect(colored > 50)
            }
        }
    }
}
