import AppKit
import EdithExtensionSupport
import EdithExtensionUI
@testable import HerdrUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct HerdrHeaderPlateTests {
    struct Plate: Equatable, CustomStringConvertible {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midY: Double { Double(minY + maxY) / 2 }
        var description: String { "(\(minX)...\(maxX), \(minY)...\(maxY))" }
    }

    struct Case {
        let name: String
        let size: CGSize
        let dark: Bool
        let compact: Bool
    }

    static let cases = [
        Case(name: "light", size: CGSize(width: 1100, height: 760), dark: false, compact: false),
        Case(name: "dark", size: CGSize(width: 1100, height: 760), dark: true, compact: false),
        Case(name: "compact-light", size: CGSize(width: 640, height: 700), dark: false, compact: true),
    ]

    static let controls = [
        "Agent connections", "Message", "Search", "New Agent", "Refresh", "About Agents",
    ]

    @Test(arguments: cases.indices)
    func everyHoveredHeaderPlateMatches(_ index: Int) async throws {
        let item = Self.cases[index]
        let idle = try await render(item, preview: nil)
        let hovered = try await render(item, preview: .hovered)
        let band = try #require(idle.band)
        let plates = Self.plates(idle.bitmap, hovered.bitmap, rows: band)
        try HerdrPageCaptureTests.capture(
            hovered.host, name: "herdr-header-all-hovered-\(item.name)")
        #expect(plates.count == Self.controls.count, "\(item.name) \(plates)")
        guard let first = plates.first else { return }
        for plate in plates {
            #expect(abs(plate.width - first.width) <= 1, "\(item.name) width \(plates)")
            #expect(abs(plate.height - first.height) <= 1, "\(item.name) height \(plates)")
            #expect(abs(plate.midY - first.midY) <= 1, "\(item.name) centre \(plates)")
        }
        let scale = idle.bitmap.pixelsWide / max(1, Int(idle.host.bounds.width))
        #expect(abs(first.width - 32 * scale) <= 1, "\(item.name) \(first)")
        #expect(abs(first.height - 32 * scale) <= 1, "\(item.name) \(first)")
    }

    struct Rendered {
        let host: NSView
        let bitmap: NSBitmapImageRep
        let band: ClosedRange<Int>?
    }

    private func render(_ item: Case, preview: EdithInteractionPreview?) async throws -> Rendered {
        let suite = "HerdrHeaderPlateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = HerdrStore(defaults: defaults, liveWatcher: { _ in }, machinesProvider: { [] })
        HerdrPageCaptureTests.prepare(store, .populated)
        let guide = PageGuideAction(id: "herdr", title: "Agents") {}
        let monitor = AgentActivityMonitor(defaults: defaults)
        let host = NSHostingView(
            rootView: AnyView(
                HerdrPage(store: store, drag: HerdrDragCoordinator(), activity: monitor)
                    .environment(\.pageGuide, guide)
                    .environment(\.automaticViewActionsEnabled, false)
                    .environment(\.terminalLaunchEnabled, false)
                    .environment(\.compactLayout, item.compact)
                    .environment(\.colorScheme, item.dark ? .dark : .light)
                    .environment(\.controlActiveState, .key)
                    .environment(\.edithInteractionPreview, preview)
                    .transaction { $0.animation = nil }))
        host.frame = CGRect(origin: .zero, size: item.size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: item.dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            store.closeAll()
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(40))
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let frames = HerdrIntroductionButtonTests.frames(host, labels: ["Search"])
        var band: ClosedRange<Int>?
        if let search = frames["Search"] {
            let inHost = host.convert(window.convertFromScreen(search), from: nil)
            let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let top = host.isFlipped ? inHost.minY : host.bounds.height - inHost.maxY
            let margin: CGFloat = 10
            band = max(0, Int((top - margin) * scale))...min(
                bitmap.pixelsHigh - 1, Int((top + inHost.height + margin) * scale))
        }
        return Rendered(host: host, bitmap: bitmap, band: band)
    }

    static func plates(
        _ idle: NSBitmapImageRep, _ hovered: NSBitmapImageRep, rows: ClosedRange<Int>
    ) -> [Plate] {
        let width = min(idle.pixelsWide, hovered.pixelsWide)
        var columns: [Int: (minY: Int, maxY: Int)] = [:]
        for x in 0..<width {
            for y in rows {
                guard let a = idle.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = hovered.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let distance =
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                guard distance > 0.02 else { continue }
                let current = columns[x] ?? (y, y)
                columns[x] = (min(current.minY, y), max(current.maxY, y))
            }
        }
        var plates: [Plate] = []
        var run: (start: Int, minY: Int, maxY: Int)?
        for x in 0...width {
            if let column = columns[x] {
                if let current = run {
                    run = (current.start, min(current.minY, column.minY), max(current.maxY, column.maxY))
                } else {
                    run = (x, column.minY, column.maxY)
                }
            } else if let current = run {
                if x - current.start >= 8 {
                    plates.append(
                        Plate(minX: current.start, maxX: x - 1, minY: current.minY, maxY: current.maxY))
                }
                run = nil
            }
        }
        return plates
    }
}
