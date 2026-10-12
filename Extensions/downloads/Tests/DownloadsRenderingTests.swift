import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import DownloadsExtension

extension DownloadsExtensionTests {
    @MainActor @Suite(.serialized) struct RenderingTests {
        @Test func fullQueueAndOptionsRenderAtCompactAndRegularWidths() async throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "downloads-render-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("queue.json")
            let record = DownloadRecord(
                url: URL(string: "https://example.test/fixture-video")!,
                status: .done("Synthetic video.mp4"), outputFilename: nil, createdAt: Date(),
                kind: .video)
            try DownloadQueue.save([record], to: file)
            let queue = DownloadWorker(
                file: file, executable: { URL(fileURLWithPath: "/fixture/yt-dlp") })
            let model = YoutubeDownloader(
                client: DownloadsClient(worker: queue), start: false,
                toolStatus: { .init(executable: $0, version: "fixture1") })
            model.apply(await queue.snapshot())
            for (width, dark) in [(CGFloat(1120), true), (CGFloat(640), false)] {
                let height = CGFloat(900)
                let host = NSHostingView(
                    rootView: DownloadSheet(isPage: true, downloader: model)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.compactLayout, width < 800)
                        .frame(width: width, height: height)
                        .transaction { $0.animation = nil })
                host.frame = NSRect(x: 0, y: 0, width: width, height: height)
                let window = NSWindow(
                    contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                window.orderBack(nil)
                window.layoutIfNeeded()
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                host.displayIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(png.count > 10_000)
                #expect(model.items.first?.resolvedTitle == "Synthetic video")
                window.contentView = nil
                window.orderOut(nil)
            }
            await model.shutdown()
            await queue.stop()
        }
    }
}
