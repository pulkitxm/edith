import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithHelper

@MainActor
@Suite(.serialized) struct SurfaceEditorRenderingTests {
    @Test func editorRendersInBothAppearancesAndCompactZoomedWindows() throws {
        let defaults = SharedDefaults.store
        let keys = [
            AppStorageKeys.Surfaces.editorWidget, AppStorageKeys.Surfaces.editorTarget,
            SurfaceTarget.home.key,
        ]
        let original = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, defaults.string(forKey: $0)) })
        var tiles = [
            SurfaceWidget.agents, .limits, .codeStats, .github, .databases, .ability("companion"),
        ].map { SurfaceTile($0) }
        for index in tiles.indices { tiles[index].span = 12; tiles[index].itemLimit = 3 }
        defaults.set(SurfaceLayout(tiles: tiles).encoded, forKey: SurfaceTarget.home.key)
        defaults.set("home", forKey: AppStorageKeys.Surfaces.editorTarget)
        defaults.set(tiles[0].id, forKey: AppStorageKeys.Surfaces.editorWidget)
        SurfaceLayoutStore.shared.reload()
        defer {
            for key in keys {
                if let value = original[key] ?? nil {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            SurfaceLayoutStore.shared.reload()
        }
        let previousScale = UIScale.current
        defer { UIScale.apply(previousScale) }
        for dark in [true, false] {
            for compact in [true, false] {
                UIScale.apply(compact ? 1.25 : 1)
                let size = CGSize(width: compact ? 620 : 1200, height: 900)
                let view = SurfaceEditorPane()
                    .environment(\.compactLayout, compact)
                    .environment(\.surfaceSampleContent, true)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.automaticViewActionsEnabled, false)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .transaction { $0.animation = nil }
                let data = try render(view, size: size, dark: dark)
                #expect(data.count > 10_000)
                try save(
                    data,
                    name: "editor-\(compact ? "compact" : "regular")-\(dark ? "dark" : "light").png"
                )
            }
        }
    }

    @Test func liveNotchRendersSampleWidgetsWithEditingHandles() throws {
        let environment = ProcessInfo.processInfo.environment
        let runtime = try #require(environment["EDITH_TEST_RUNTIME_ROOT"])
        #expect(DataRoot.support.path.hasPrefix(runtime + "/"))
        guard DataRoot.support.path.hasPrefix(runtime + "/") else { return }
        let defaults = SharedDefaults.store
        let original = defaults.string(forKey: SurfaceTarget.notch.key)
        defaults.set(
            SurfaceLayout(tiles: [.init(.agents), .init(.limits), .init(.github)]).encoded,
            forKey: SurfaceTarget.notch.key)
        SurfaceLayoutStore.shared.reload()
        defer {
            if let original {
                defaults.set(original, forKey: SurfaceTarget.notch.key)
            } else {
                defaults.removeObject(forKey: SurfaceTarget.notch.key)
            }
            SurfaceLayoutStore.shared.reload()
        }
        let controller = NotchShelfController()
        defer { controller.shutdown() }
        if let screen = NSScreen.main,
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
        {
            controller.expand(on: id)
            controller.layoutEditing = true
            let view = NotchShelfContentView(controller: controller, displayID: id)
                .environment(\.surfaceSampleContent, true)
            _ = try render(
                view, size: NotchGeometry.panelSize(forShape: controller.expandedSize(on: id)),
                dark: true)
            let data = try render(
                view,
                size: NotchGeometry.panelSize(forShape: controller.expandedSize(on: id)), dark: true
            )
            #expect(data.count > 1000)
            try save(data, name: "notch-editor.png")
        }
    }

    private func save(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EDITH_SURFACE_EVIDENCE_DIR"] else {
            return
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    private func render(_ view: some View, size: CGSize, dark: Bool) throws -> Data {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
