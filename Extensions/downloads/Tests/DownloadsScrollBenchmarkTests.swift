import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import DownloadsExtension

@Suite(.serialized) @MainActor struct DownloadsScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60

    @Test(.enabled(if: enabled)) func scrollingLongDownloadHistory() async throws {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = try await Self.measure(records: 3000, frames: frames)
        print(
            "downloads-scroll history: \(timing) reach=\(Int(timing.offsets.max() ?? 0)) slowAt=\(timing.slowOffsets)"
        )
    }

    @Test func scrollingStaysSmoothWithLongHistory() async throws {
        let timing = try await Self.measure(records: 400, frames: 60)
        print("downloads-regression history: \(timing)")
        #expect(timing.frames.count == 60)
        #expect(timing.worst < 100)
        #expect(timing.median < Self.medianBudget)
    }

    static func measure(records count: Int, frames: Int) async throws -> ScrollTiming {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downloads-scroll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("queue.json")
        let now = Date()
        let records = (0..<count).map { index -> DownloadRecord in
            let status: DownloadStatus =
                index % 11 == 5
                ? .error("Synthetic failure \(index)")
                : index % 13 == 7
                    ? .interrupted("Paused")
                    : .done("Synthetic video \(index).mp4")
            return DownloadRecord(
                url: URL(string: "https://example.test/watch/\(index)")!, status: status,
                outputFilename: nil, createdAt: now.addingTimeInterval(Double(-index) * 30),
                kind: index.isMultiple(of: 3) ? .audio : .video)
        }
        try DownloadQueue.save(records, to: file)
        let queue = DownloadWorker(
            file: file, executable: { URL(fileURLWithPath: "/fixture/yt-dlp") })
        let model = YoutubeDownloader(
            client: DownloadsClient(worker: queue), start: false,
            toolStatus: { .init(executable: $0, version: "fixture1") })
        model.apply(await queue.snapshot())
        let (window, host) = ScrollHarness.host(
            DownloadSheet(isPage: true, downloader: model)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil },
            size: CGSize(width: 1120, height: 860))
        await ScrollHarness.settle(host, for: .seconds(1))
        let timing = await ScrollHarness.scroll(host, frames: frames)
        await ScrollHarness.settle(host)
        window.orderOut(nil)
        window.contentView = nil
        await model.shutdown()
        await queue.stop()
        return timing
    }
}
