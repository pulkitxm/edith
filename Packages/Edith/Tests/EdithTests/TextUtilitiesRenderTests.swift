import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@Suite @MainActor struct TextUtilitiesRenderTests {
    @Test func settingsRenderWithIsolatedPreferences() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.TextUtilities.enabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        let snippetsKey = AppStorageKeys.TextUtilities.snippets
        let oldSnippets = defaults.object(forKey: snippetsKey)
        defaults.set(
            TextUtilitiesSupport.encode([
                TextSnippet(
                    name: "Greeting", trigger: ";hello", replacement: "Hello there!",
                    folder: "Daily"),
                TextSnippet(
                    name: "Sign-off", trigger: ";thanks", replacement: "Thank you", folder: "Daily"),
            ]), forKey: snippetsKey)
        defer {
            defaults.set(previous, forKey: key)
            defaults.set(oldSnippets, forKey: snippetsKey)
        }
        let view = Form { TextUtilitiesRows() }
            .formStyle(.grouped)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 1000)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 1000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 680)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("text-utilities.png"))
        }
    }
}
