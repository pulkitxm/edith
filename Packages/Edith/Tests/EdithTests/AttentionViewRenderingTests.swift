import AppKit
import SwiftUI
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized)
struct AttentionViewRenderingTests {
    @Test func mountedPageLoadsActivityAndResolvesDarkAppearance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionRendering.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)
        try repository.saveSettings(
            AttentionSettings(isEnabled: true, trackingEnabled: true))
        try repository.append(
            AttentionEvent(
                startedAt: Calendar.current.startOfDay(for: Date()).addingTimeInterval(-3_600),
                duration: 300,
                source: .application, appName: "Xcode", bundleID: "com.apple.dt.Xcode",
                windowTitle: "Sample workspace"), pulseTime: 0)
        let model = AttentionPageModel(repository: repository)
        model.select(.yesterday)
        #expect(!model.loaded)
        let host = NSHostingView(
            rootView: AttentionPage(model: model)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil })
        host.frame = NSRect(x: 0, y: 0, width: 1_180, height: 900)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.orderOut(nil)
        }
        window.orderBack(nil)
        for _ in 0..<100 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            if model.loaded { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(model.loaded)
        #expect(model.summary.activeDuration == 300)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let background = try #require(
            bitmap.colorAt(x: 12, y: 12)?.usingColorSpace(.deviceRGB))
        #expect(background.redComponent < 0.4)
        #expect(background.greenComponent < 0.4)
        #expect(background.blueComponent < 0.4)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10_000)
    }
}
