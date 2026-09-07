import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct MouseControlsRenderTests {
    @Test func settingsRenderWithIsolatedPreferences() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.Mouse.enabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let view = Form { MouseControlsRows() }
            .formStyle(.grouped)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 620)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 620)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 680)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("mouse-controls.png"))
        }
    }
}
