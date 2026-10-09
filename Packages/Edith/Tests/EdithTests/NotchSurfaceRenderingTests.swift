import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithHelper

@MainActor @Suite(.serialized) struct NotchSurfaceRenderingTests {
    @Test func mediaAndAgentPresetsRenderTheActualNotch() async throws {
        let defaults = SharedDefaults.store
        let keys = [
            SurfaceTarget.notch.key, AppStorageKeys.Notch.shelfHaptics,
            AppStorageKeys.General.keepAwakeEnabled, AppStorageKeys.Presenter.enabled,
            AppStorageKeys.Tabs.systemEnabled, AppStorageKeys.Notch.shelfOpenOnHover,
            AppStorageKeys.Notch.shelfRequireOption,
        ]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            SurfaceLayoutStore.shared.reload()
        }
        defaults.set(false, forKey: AppStorageKeys.Notch.shelfHaptics)
        for key in keys.dropFirst(2) { defaults.set(true, forKey: key) }
        defaults.set(false, forKey: AppStorageKeys.Notch.shelfRequireOption)
        for preset in [SurfacePreset.media, .agents] {
            defaults.set(preset.layout(for: .notch).encoded, forKey: SurfaceTarget.notch.key)
            SurfaceLayoutStore.shared.reload()
            let controller = NotchShelfController(
                nowPlaying: NotchNowPlaying(
                    source: .external(.spotify), title: "Night drive", artist: "Sample artist",
                    isPlaying: false), startsServices: false)
            #expect(!controller.isExpanded(on: 0))
            let host = NSHostingView(
                rootView: NotchShelfContentView(controller: controller, isBuiltin: false)
                    .environment(\.surfaceSampleContent, true)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.colorScheme, .dark)
                    .allowsHitTesting(false)
                    .background(Color.gray.opacity(0.3)))
            host.sizingOptions = []
            host.frame = CGRect(x: 0, y: 0, width: 1280, height: 500)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            window.layoutIfNeeded(); host.layoutSubtreeIfNeeded()
            controller.hoverChanged(true, on: 0)
            #expect(controller.isHovering(on: 0))
            for _ in 0..<8 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(data.count > 10_000)
            #expect(controller.isExpanded(on: 0))
            #expect(controller.expandedSize(on: 0).width >= 960)
            if let path = ProcessInfo.processInfo.environment["EDITH_SURFACE_EVIDENCE_DIR"] {
                let root = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("notch-\(preset.rawValue).png"))
            }
        }
    }
}
