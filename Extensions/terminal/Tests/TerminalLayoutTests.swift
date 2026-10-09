import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalLayoutTests {
    @Test func inactiveWorkspacesFitCompactRegularAndZoomedWindowsWithoutStartingShells() throws {
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        for (size, scale, scheme) in [
            (NSSize(width: 540, height: 430), 1.0, ColorScheme.dark),
            (NSSize(width: 1000, height: 700), 1.0, ColorScheme.light),
            (NSSize(width: 760, height: 520), 1.35, ColorScheme.dark),
        ] {
            UIScale.apply(scale)
            let model = TerminalTabsModel()
            for _ in 0..<3 { _ = model.addTab() }
            let host = NSHostingView(
                rootView: TerminalTabsView(model: model, presented: false).environment(
                    \.colorScheme, scheme))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let minimum = host.fittingSize
            #expect(minimum.width <= size.width && minimum.height <= size.height)
            #expect(model.tabs.allSatisfy { !$0.holder.started && $0.holder.ghosttyLaunch == nil })
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            model.stopAll()
        }
    }
}
