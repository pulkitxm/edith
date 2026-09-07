import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct DockToolsRenderTests {
    @Test func settingsRenderWithIsolatedPreferences() throws {
        _ = TestWindowHost.application
        let defaults = SharedDefaults.store
        let key = AppStorageKeys.DockTools.enabled
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let view = Form { DockToolsRows() }
            .formStyle(.grouped)
            .environment(\.automaticViewActionsEnabled, false)
            .environment(\.colorScheme, .light)
            .frame(width: 680, height: 700)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 700)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= 680)
        #expect(data.count > 15_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("dock-tools.png"))
        }
    }
    @Test func windowPreviewsRenderWithSyntheticTitles() throws {
        _ = TestWindowHost.application
        let windows = [
            DockToolsWindow(
                id: "sample:1", title: "Project notes", appName: "Sample Editor",
                bundleIdentifier: "com.example.editor", pid: 123, minimized: false),
            DockToolsWindow(
                id: "sample:2", title: "Reading list", appName: "Sample Editor",
                bundleIdentifier: "com.example.editor", pid: 123, minimized: true),
        ]
        let view = DockToolsPreviewView(
            applicationName: "Sample Editor", icon: nil, windows: windows, images: [:],
            selectedID: "sample:1", activate: { _ in }, move: { _ in }
        )
        .environment(\.colorScheme, .light)
        .padding(12)
        .frame(width: 470, height: 226)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 470, height: 226)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 10_000)
        if let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] {
            try data.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("dock-preview.png"))
        }
    }

}
