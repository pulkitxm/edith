import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import PluginsExtension

@Suite(.serialized) @MainActor struct PluginsRenderingTests {
    @Test func catalogRendersAtCompactRegularZoomAndBothSchemesWithoutStartingDiscovery()
        async throws
    {
        let model = SkillsModel(detectAgents: { [] })
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for (name, width, zoom, scheme) in [
            ("regular-light", 1200.0, 1.0, ColorScheme.light),
            ("regular-dark", 1200.0, 1.0, ColorScheme.dark),
            ("compact", 620.0, 1.0, ColorScheme.light),
            ("zoomed", 1200.0, 1.5, ColorScheme.dark),
        ] {
            UIScale.apply(zoom)
            let host = NSHostingView(
                rootView: PluginsPage(model: model)
                    .environment(\.compactLayout, width < UIScale.pt(720))
                    .environment(\.colorScheme, scheme)
                    .environment(\.automaticViewActionsEnabled, false))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            let window = PluginTestWindowHost.window(contentRect: host.frame)
            window.contentView = host; window.orderBack(nil)
            for _ in 0..<5 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded();
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(!model.agentsLoaded)
            #expect(!model.isDiscovering)
            #expect(!PluginTestWindowHost.isExposedOnDesktop(window))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_PLUGINS"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("plugins-\(name).png"))
            }
            window.orderOut(nil)
        }
        await model.shutdown()
    }

    @Test func supportedAgentBrandsHavePackagedLogos() {
        for id in ["cursor", "codex", "claude-code", "command-code", "zed"] {
            #expect(SkillBrand.image(for: id) != nil)
            #expect(SkillBrand.menuImage(for: id) != nil)
        }
        SkillBrand.shutdown()
    }
}
