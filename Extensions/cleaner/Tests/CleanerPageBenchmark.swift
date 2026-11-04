import AppKit
import EdithExtensionSupport
import Foundation
import SwiftUI
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CLEANER_BENCH"] != nil))
struct CleanerPageBenchmark {
    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView != nil,
            scroll.frame.height > 200
        {
            return scroll
        }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    @Test(arguments: [2_000, 5_000]) func pageCosts(items: Int) async throws {
        let suite = "synthetic.cleaner.bench." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = await CleanerSyntheticFixture.engine(items: items, defaults: defaults)
        let bridge = CleanerEngineBridge(engine: engine)
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        CleanerModel.uiMemory = nil
        let ui = CleanerModel(engineClient: client, defaults: defaults)
        let clock = ContinuousClock()

        let host = NSHostingView(
            rootView: CleanerPage(model: ui).environment(\.colorScheme, .dark).frame(
                width: 1_100, height: 800))
        host.frame = NSRect(x: 0, y: 0, width: 1_100, height: 800)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }

        func frame() {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        await ui.refreshRemote()
        let fullKB = (bridge.replies.last?.bytes ?? 0) / 1_024
        frame()
        for category in ui.categories { ui.toggleExpand(category.id) }
        let expandStart = clock.now
        frame()
        let expandMs = Self.ms(clock.now - expandStart)

        try await Task.sleep(for: .milliseconds(200))
        frame()
        bridge.replies.removeAll()
        var ticks: [Double] = []
        for _ in 0..<8 {
            let start = clock.now
            await ui.refreshRemote()
            frame()
            ticks.append(Self.ms(clock.now - start))
        }
        let pollKB = bridge.replies.map(\.bytes).max() ?? 0

        let scroll = try #require(Self.scrollView(in: host))
        var frames: [Double] = []
        let clip = scroll.contentView
        for step in 1...120 {
            let start = clock.now
            clip.scroll(to: NSPoint(x: 0, y: Double(step) * 60))
            scroll.reflectScrolledClipView(clip)
            frame()
            frames.append(Self.ms(clock.now - start))
        }
        frames.sort()

        bridge.replies.removeAll()
        let category = try #require(ui.categories.first)
        let item = try #require(category.items.first)
        let toggleStart = clock.now
        ui.toggleItem(categoryID: category.id, itemID: item.id)
        frame()
        let toggleMs = Self.ms(clock.now - toggleStart)
        while bridge.replies.isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        let roundTripMs = Self.ms(clock.now - toggleStart)
        let clickBytes = bridge.replies.map(\.bytes).max() ?? 0

        let tickMean = ticks.reduce(0, +) / Double(ticks.count)
        print(
            String(
                format:
                    "CLEANER_BENCH items=%d fullSnapshotKB=%d pollReplyBytes=%d clickReplyBytes=%d expandMs=%.1f idleTickMeanMs=%.1f scrollFrameP50Ms=%.2f scrollFrameP95Ms=%.2f scrollFrameMaxMs=%.1f toggleFrameMs=%.1f toggleRoundTripMs=%.1f",
                items, fullKB, pollKB, clickBytes, expandMs, tickMean, frames[frames.count / 2],
                frames[Int(Double(frames.count) * 0.95)], frames.last ?? 0, toggleMs,
                roundTripMs))
        await ui.shutdown()
        await engine.shutdown()
    }
}
