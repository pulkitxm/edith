import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import ClipboardExtension

@Suite(.serialized) @MainActor struct ClipboardScrollBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["EDITH_SCROLL_BENCHMARK"] != nil
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 12.0 : 1000.0 / 60

    @Test(.enabled(if: enabled)) func scrollingHistoryAndPanelWithSyntheticClipboard() async throws
    {
        let frames = Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let only = ProcessInfo.processInfo.environment["EDITH_SCROLL_CASE"]
        for surface in ClipboardSyntheticHistory.Surface.allCases {
            for pace in ClipboardScrollPace.allCases
            where only == nil || only == "\(surface.rawValue)-\(pace.rawValue)" {
                let timing = try await ClipboardSyntheticHistory.measure(
                    surface, count: 5000, frames: frames, pace: pace)
                print("clipboard-scroll \(surface.rawValue) \(pace.rawValue): \(timing)")
            }
        }
    }

    @Test func historyAndPanelScrollingStaySmoothWithSmallHistory() async throws {
        for surface in ClipboardSyntheticHistory.Surface.allCases {
            let timing = try await ClipboardSyntheticHistory.measure(
                surface, count: 400, frames: 60)
            #expect(timing.worst < 80)
            #expect(timing.median < Self.medianBudget)
        }
    }
}

enum ClipboardScrollPace: String, CaseIterable {
    case steady, fling, sweep

    func step(documentHeight: CGFloat, frames: Int) -> CGFloat {
        switch self {
        case .steady: 24
        case .fling: 100
        case .sweep: max(24, documentHeight / CGFloat(frames))
        }
    }

    var panelStep: CGFloat {
        switch self {
        case .steady: 24
        case .fling: 100
        case .sweep: 400
        }
    }
}

@MainActor
enum ClipboardSyntheticHistory {
    enum Surface: String, CaseIterable { case history, panel }

    static let thumbnail: Data = {
        let side = 96
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGradient(colors: [.systemTeal, .systemBlue])?.draw(
            in: NSRect(x: 0, y: 0, width: side, height: side), angle: 45)
        image.unlockFocus()
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }()

    static func entries(count: Int) -> [ClipboardEntry] {
        let now = Date()
        return (0..<count).map { index in
            let age = Double(index) * 420
            let common: (String, String, [String], String, String?, Int) =
                switch index % 10 {
                case 0, 1, 2:
                    (
                        "txt", "Meeting notes for item \(index) with a longer line of text",
                        ["public.utf8-plain-text"], "Notes", nil, 180
                    )
                case 3, 4:
                    (
                        "txt", "https://example.com/articles/\(index)/read",
                        ["public.utf8-plain-text"], "Safari", nil, 44
                    )
                case 5:
                    (
                        "png", "Screenshot \(index)", ["public.png"], "Preview", nil, 48_000
                    )
                case 6:
                    (
                        "txt", String(format: "#%06x", (index * 2_654_435) & 0xFFFFFF),
                        ["public.utf8-plain-text"], "Figma", nil, 7
                    )
                case 7:
                    (
                        "files", "Quarterly-report-\(index).pdf", ["public.file-url"], "Finder",
                        nil, 120
                    )
                case 8:
                    (
                        "txt", "person\(index)@example.com", ["public.utf8-plain-text"], "Mail",
                        nil, 24
                    )
                default:
                    (
                        "rtf", "Formatted paragraph number \(index)", ["public.rtf"], "Pages",
                        nil, 900
                    )
                }
            return ClipboardEntry(
                id: "mock-\(index)", sha256: "hash-\(index)", types: common.2, ext: common.0,
                sourceApp: common.3, sourceBundleID: nil,
                createdAt: now.addingTimeInterval(-age), size: common.5, preview: common.1,
                pinned: index % 97 == 0)
        }
    }

    static func client(entries: [ClipboardEntry]) -> ClipboardClient {
        let thumbnail = thumbnail
        return ClipboardClient(send: { operation, payload in
            switch operation {
            case ClipboardServiceOperation.snapshot:
                let request = try ClipboardMessage.decode(
                    ClipboardSnapshotRequest.self, from: payload)
                let start = min(request.offset, entries.count)
                let end = min(entries.count, start + request.limit)
                return try ClipboardMessage.encode(
                    ClipboardSnapshot(
                        entries: Array(entries[start..<end]), revision: "mock",
                        total: entries.count))
            case ClipboardServiceOperation.thumbnail:
                try await Task.sleep(for: .milliseconds(2))
                return try ClipboardMessage.encode(ClipboardThumbnailSnapshot(data: thumbnail))
            default:
                return try ClipboardMessage.encode(ClipboardMutationResult(changed: 0, total: 0))
            }
        })
    }

    static func measure(
        _ surface: Surface, count: Int, frames: Int, pace: ClipboardScrollPace = .steady
    )
        async throws
        -> ClipboardScrollTiming
    {
        let entries = entries(count: count)
        let client = client(entries: entries)
        ClipboardThumbnail.clear()
        let timing: ClipboardScrollTiming
        switch surface {
        case .history:
            let model = ClipboardHistoryModel(client: client, observesNotifications: false)
            model.reload()
            for _ in 0..<600 where model.entries.count != count {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(model.entries.count == count)
            let (window, host) = ClipboardScrollHarness.host(
                ClipboardHistoryView(model: model)
                    .environment(\.colorScheme, .dark)
                    .environment(\.automaticViewActionsEnabled, false),
                size: CGSize(width: 480, height: 520))
            await ClipboardScrollHarness.settle(host, for: .seconds(1))
            let height =
                ClipboardScrollHarness.scrollView(in: host)?.documentView?.frame.height ?? 0
            let step = pace.step(documentHeight: height, frames: frames)
            timing = await ClipboardScrollHarness.scroll(host, step: step, frames: frames)
            await ClipboardScrollHarness.settle(host)
            window.orderOut(nil)
            window.contentView = nil
            await model.shutdown()
        case .panel:
            let store = ClipboardStore(client: client, capturesPasteboard: false)
            for _ in 0..<600 where store.entries.count != count {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(store.entries.count == count)
            let (window, host) = ClipboardScrollHarness.host(
                ClipboardPanelView(store: store, onDismiss: {}, onHeightChange: { _ in })
                    .environment(\.colorScheme, .dark)
                    .transaction { $0.animation = nil },
                size: CGSize(
                    width: ClipboardPanelLayout.width, height: ClipboardPanelLayout.maxHeight))
            await ClipboardScrollHarness.settle(host, for: .seconds(1))
            timing = await ClipboardScrollHarness.scroll(
                host, step: pace.panelStep, frames: frames)
            await ClipboardScrollHarness.settle(host)
            window.orderOut(nil)
            window.contentView = nil
            await store.cancelAndWait()
        }
        ClipboardThumbnail.clear()
        return timing
    }
}
