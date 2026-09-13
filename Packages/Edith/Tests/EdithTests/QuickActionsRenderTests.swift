import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct QuickActionsRenderTests {
    @Test func settingsRenderWithSyntheticSystemState() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.Tabs.quickActionsEnabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let center = QuickActionCenter(
            environment: QuickActionEnvironment(
                appearance: { .light }, toggleAppearance: {}, keyboardLight: { 0.5 },
                setKeyboardLight: { _ in true }, finderFlag: { _, fallback in fallback },
                setFinderFlag: { _, _ in },
                volumes: { [(URL(fileURLWithPath: "/Volumes/Sample"), "Sample Drive")] },
                eject: { _ in }, emptyTrash: {}, lockScreen: {}))
        let view = Form { QuickActionsRows(center: center) }
            .formStyle(.grouped)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 780)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 780)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 680)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("quick-actions.png"))
        }
    }
}
