import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardPageRenderingTests {
    @Test func settingsRenderAtCompactRegularZoomAndBothSchemesWithoutReadingThePasteboard()
        async throws
    {
        let client = ClipboardClient(send: { operation, _ in
            guard operation == ClipboardServiceOperation.snapshot else {
                throw CocoaError(.featureUnsupported)
            }
            return try ClipboardMessage.encode(
                ClipboardSnapshot(entries: [], revision: "mock", total: 0))
        })
        let model = ClipboardHistoryModel(client: client)
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
                rootView: ClipboardPage(client: client, history: model, openPalette: {})
                    .environment(\.compactLayout, width < UIScale.pt(720))
                    .environment(\.colorScheme, scheme)
                    .environment(\.automaticViewActionsEnabled, false))
            host.frame = CGRect(x: 0, y: 0, width: width, height: 900)
            let window = ClipboardTestWindowHost.window(contentRect: host.frame)
            window.contentView = host; window.orderBack(nil)
            for _ in 0..<5 {
                window.layoutIfNeeded(); host.layoutSubtreeIfNeeded();
                try await Task.sleep(for: .milliseconds(30))
            }
            #expect(model.entries.isEmpty)
            #expect(!ClipboardTestWindowHost.isExposedOnDesktop(window))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_CLIPBOARD"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("clipboard-settings-\(name).png"))
            }
            window.orderOut(nil)
        }
        await model.shutdown()
    }

}
