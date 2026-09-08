import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct RadialLauncherRenderTests {
    @Test func wheelRendersWithSyntheticActions() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = RadialLauncherPreferenceKeys.enabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let profile = RadialLauncherProfile(
            name: "Daily tools",
            items: [
                RadialLauncherItem(kind: .link, name: "Reading", payload: "https://example.com"),
                RadialLauncherItem(
                    kind: .media, name: "Play or pause",
                    payload: RadialLauncherMediaAction.playPause.rawValue),
                RadialLauncherItem(
                    kind: .edith, name: "Edith panel",
                    payload: RadialLauncherEdithAction.openPanel.rawValue),
                RadialLauncherItem(
                    kind: .media, name: "Next track",
                    payload: RadialLauncherMediaAction.next.rawValue),
            ])
        let view = RadialLauncherWheel(profile: profile, highlightedIndex: 1, select: { _ in })
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 440, height: 440)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 440)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 440)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("radial-launcher.png"))
        }
    }
}
