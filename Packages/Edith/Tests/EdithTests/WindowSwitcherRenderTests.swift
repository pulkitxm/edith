import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct WindowSwitcherRenderTests {
    @Test func settingsRenderWithEnabledActions() throws {
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.WindowSwitcher.enabled
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.set(true, forKey: key)
        let hosting = NSHostingView(
            rootView:
                Form { WindowSwitcherRows() }
                .formStyle(.grouped)
                .frame(width: 580, height: 670))
        hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 670)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 580)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("window-switcher.png"))
        }
    }
}
