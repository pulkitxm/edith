import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithHelper
@testable import EdithKit

@MainActor
@Suite(.serialized) struct ClipboardPanelRenderTests {
    private final class HeightLog {
        var values: [CGFloat] = []
    }

    private func clip(
        _ id: String, _ preview: String, source: String, minutesAgo: Double, ext: String = "txt",
        pinned: Bool = false
    ) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: id, types: ["public.utf8-plain-text"], ext: ext, sourceApp: source,
            sourceBundleID: nil, createdAt: Date().addingTimeInterval(-minutesAgo * 60), size: 64,
            preview: preview, pinned: pinned)
    }

    private var syntheticHistory: [ClipboardEntry] {
        [
            clip(
                "pin", "ssh deploy@staging.example.com", source: "Terminal", minutesAgo: 4000,
                pinned: true),
            clip("color", "#ff26a1", source: "Figma", minutesAgo: 1),
            clip("link", "https://example.com/launch-notes", source: "Safari", minutesAgo: 3),
            clip("mail", "hello@example.com", source: "Mail", minutesAgo: 5),
            clip(
                "note", "Ship the copy stack before Friday's demo", source: "Notes", minutesAgo: 8),
            clip("rgb", "rgb(52, 120, 246)", source: "Xcode", minutesAgo: 12),
            clip("file", "Roadmap.pdf", source: "Finder", minutesAgo: 20, ext: "url"),
            clip(
                "sql", "SELECT id, email FROM users LIMIT 10;", source: "TablePlus",
                minutesAgo: 60 * 26),
            clip(
                "pr", "https://github.com/example/repo/pull/42", source: "Chrome",
                minutesAgo: 60 * 27),
        ]
    }

    private func store(_ entries: [ClipboardEntry]) async throws -> ClipboardStore {
        let client = AgentClipboardClient { operation, _ in
            guard operation == AgentClipboardOperation.snapshot else {
                throw CocoaError(.featureUnsupported)
            }
            return try AgentPayload.encode(
                ClipboardSnapshot(entries: entries, revision: "fixture", total: entries.count))
        }
        let store = ClipboardStore(client: client, capturesPasteboard: false)
        for _ in 0..<200 where store.entries.count != entries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.entries.count == entries.count)
        return store
    }

    private func render(
        _ store: ClipboardStore, appearance: NSAppearance.Name, log: HeightLog
    ) throws -> NSBitmapImageRep {
        let height = ClipboardPanelLayout.estimatedHeight(
            for: store.entries, pinToTop: true, showsFooter: true)
        let frame = NSRect(x: 0, y: 0, width: ClipboardPanelLayout.width, height: height)
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(
            rootView: ClipboardPanelView(
                store: store, onDismiss: {}, onHeightChange: { log.values.append($0) }
            )
            .transaction { $0.animation = nil })
        host.frame = frame
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        let window = TestWindowHost.window(contentRect: frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = effect
        window.orderBack(nil)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        }
        redraw(effect)
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let bitmap = try #require(effect.bitmapImageRepForCachingDisplay(in: effect.bounds))
        effect.cacheDisplay(in: effect.bounds, to: bitmap)
        return bitmap
    }

    private func redraw(_ view: NSView) {
        for child in view.subviews { redraw(child) }
        view.needsDisplay = true
        view.displayIfNeeded()
    }

    private func distinctColors(in bitmap: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let packed =
                    UInt32(color.redComponent * 31) << 10 | UInt32(color.greenComponent * 31) << 5
                    | UInt32(color.blueComponent * 31)
                seen.insert(packed)
            }
        }
        return seen.count
    }

    @Test func thePaletteRendersAndReportsItsEstimatedHeight() async throws {
        let store = try await store(syntheticHistory)
        defer { store.shutdown() }
        let log = HeightLog()

        let bitmap = try render(store, appearance: .darkAqua, log: log)

        let expected = ClipboardPanelLayout.estimatedHeight(
            for: store.entries, pinToTop: true, showsFooter: ClipboardPanelView.footerEnabled)
        #expect(log.values.last == expected)
        #expect(bitmap.pixelsWide >= Int(ClipboardPanelLayout.width))
        #expect(distinctColors(in: bitmap) > 12)
    }

    @Test func anEmptyStackStillRendersItsEmptyState() async throws {
        let store = try await store([])
        defer { store.shutdown() }
        let log = HeightLog()

        let bitmap = try render(store, appearance: .aqua, log: log)

        #expect(
            log.values.last
                == ClipboardPanelLayout.chrome(
                    showsChips: false, showsFooter: ClipboardPanelView.footerEnabled)
                + ClipboardPanelLayout.emptyHeight)
        #expect(distinctColors(in: bitmap) > 2)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["EDITH_CLIPBOARD_EVIDENCE_DIR"] != nil))
    func evidenceRendersTheCopyStackWithSyntheticClips() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(
            fileURLWithPath: try #require(environment["EDITH_CLIPBOARD_EVIDENCE_DIR"]),
            isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try await store(syntheticHistory)
        defer { store.shutdown() }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let bitmap = try render(store, appearance: appearance, log: HeightLog())
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("copy-stack-\(name).png"))
        }
    }
}
