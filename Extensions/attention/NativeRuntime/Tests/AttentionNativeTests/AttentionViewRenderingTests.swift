import AppKit
import Foundation
import SwiftUI
import Testing
import EdithExtensionUI

@testable import AttentionNative

@MainActor
@Suite(.serialized)
struct AttentionViewRenderingTests {
    @Test func completeActivityPageRendersAtCompactAndRegularSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "attention-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(.init(isEnabled: true, trackingEnabled: true))
        try repository.append(
            AttentionEvent(
                id: "fixture-render", startedAt: Date().addingTimeInterval(-600), duration: 300,
                source: .application, appName: "Fixture Editor",
                bundleID: "com.example.fixture.editor", windowTitle: "Sample workspace"))
        let model = AttentionPageModel(repository: repository)
        model.reload()
        await model.waitForReload()
        #expect(model.loaded && model.summary.activeDuration == 300)
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for (width, dark, zoom) in [
            (CGFloat(1180), true, 1.0), (CGFloat(1180), false, 1.0), (CGFloat(680), false, 1.0),
            (CGFloat(1180), true, 1.5),
        ] {
            UIScale.apply(zoom)
            let height = CGFloat(900)
            let view = NSHostingView(
                rootView: AttentionPage(model: model)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.compactLayout, width < 800)
                    .environment(\.automaticViewActionsEnabled, false)
                    .frame(width: width, height: height)
                    .transaction { $0.animation = nil })
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = AttentionTestWindowHost.window(contentRect: view.frame)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            window.orderBack(nil)
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            view.displayIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!AttentionTestWindowHost.isExposedOnDesktop(window))
            #expect(png.count > 10_000)
            #expect(bitmap.pixelsWide >= Int(width))
            window.contentView = nil
            window.orderOut(nil)
        }
        await model.shutdown()
    }
}
