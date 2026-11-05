import AppKit
import EdithExtensionCore
import EdithExtensionUI
import SwiftUI
import Testing

@testable import EdithExtensionFiles

@MainActor @Suite(.serialized) struct FinderToolbarTests {
    private func trailingInk(
        _ bitmap: NSBitmapImageRep, width: Double, rows: Range<Int>
    ) -> Double? {
        let scale = Double(bitmap.pixelsWide) / width
        let luminance = { (x: Int, y: Int) -> Double in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                return 0
            }
            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
        }
        let background = luminance(bitmap.pixelsWide - 2, 4)
        let hit = stride(from: bitmap.pixelsWide - 1, through: 0, by: -1).first { x in
            rows.contains { abs(luminance(x, Int(Double($0) * scale)) - background) > 0.08 }
        }
        return hit.map { width - Double($0 + 1) / scale }
    }

    @Test(arguments: [false, true]) func theToolbarKeepsThePageGutter(compact: Bool) async throws {
        let finder = FinderModel(
            session: DirectFinderSession(id: UUID(), name: "fixture", isLocal: false), path: "/srv",
            directoryLoader: { _ in .success([]) },
            freeSpaceLoader: { _ in nil })
        defer { finder.stopLoading() }
        let width = 900.0
        let host = NSHostingView(
            rootView: FinderPane(model: finder, autoFocus: false)
                .environment(\.compactLayout, compact)
                .environment(\.colorScheme, .light)
                .environment(\.automaticViewActionsEnabled, false)
                .frame(width: width, height: 500))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 500)
        let window = FinderTestWindow.make(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let path = ProcessInfo.processInfo.environment["EDITH_TEST_CAPTURE_SURFACES"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: directory.appendingPathComponent("finder-toolbar-\(compact).png"))
        }
        let inset = try #require(trailingInk(bitmap, width: width, rows: 10..<34))
        #expect(inset >= PageMetrics.gutter(compact) - 1)
        #expect(inset <= PageMetrics.gutter(compact) + 8)
    }
}
