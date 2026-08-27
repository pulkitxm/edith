import AppKit
import Foundation
import SwiftUI
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite @MainActor struct EmojiPanelRenderTests {
    private func render(_ view: some View, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(
            x: 0, y: 0, width: EmojiPanel.width, height: EmojiPanel.height)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private func dump(_ view: some View, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["EDITH_RENDER_DUMP"] else {
            return
        }
        let backed = ZStack {
            Color(nsColor: .windowBackgroundColor)
            view
        }
        .frame(width: EmojiPanel.width, height: EmojiPanel.height)
        guard let rep = render(backed),
            let data = rep.representation(using: .png, properties: [:])
        else { return }
        try? data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }

    private func distinctColours(in rep: NSBitmapImageRep) -> Int {
        var seen: Set<Int> = []
        let step = 4
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let packed =
                    Int(colour.redComponent * 255) << 16 | Int(colour.greenComponent * 255) << 8
                    | Int(colour.blueComponent * 255)
                seen.insert(packed)
            }
        }
        return seen.count
    }

    @Test func panelRendersTheRealCatalogWithoutCollapsing() throws {
        let store = EmojiStore(catalog: .shared, typeCharacter: { _ in })
        let rep = try #require(render(EmojiPanelView(store: store, onDismiss: {})))
        #expect(rep.pixelsWide >= Int(EmojiPanel.width))
        #expect(rep.pixelsHigh >= Int(EmojiPanel.height))
        #expect(distinctColours(in: rep) > 40)
        dump(EmojiPanelView(store: store, onDismiss: {}), named: "emoji-panel")
    }

    @Test func everyGridColumnStaysInsideThePanelEdges() throws {
        let store = EmojiStore(catalog: .shared, typeCharacter: { _ in })
        let rep = try #require(render(EmojiPanelView(store: store, onDismiss: {})))
        let rowRange = rep.pixelsHigh / 4..<rep.pixelsHigh / 2
        var leftMost = rep.pixelsWide
        var rightMost = 0
        for y in rowRange {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y), colour.alphaComponent > 0.1,
                    isColourful(colour)
                else { continue }
                leftMost = min(leftMost, x)
                rightMost = max(rightMost, x)
            }
        }
        let scale = CGFloat(rep.pixelsWide) / EmojiPanel.width
        #expect(CGFloat(leftMost) / scale >= 6)
        #expect(CGFloat(rightMost) / scale <= EmojiPanel.width - 6)
    }

    private func isColourful(_ colour: NSColor) -> Bool {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return false }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
        return (components.max() ?? 0) - (components.min() ?? 0) > 0.25
    }

    @Test func frequentlyUsedEmojiLeadThePanel() throws {
        let key = AppStorageKeys.Emoji.usage
        let store = SharedDefaults.store
        defer { store.removeObject(forKey: key) }
        var ledger = EmojiUsageLedger()
        let moment = Date()
        for (index, character) in ["🚀", "🎉", "👍\u{FE0F}", "🔥", "😂"].enumerated() {
            for _ in 0...(5 - index) { ledger.record(character, at: moment) }
        }
        ledger.save(to: store, key: key)
        let emoji = EmojiStore(catalog: .shared, typeCharacter: { _ in })
        #expect(emoji.frequent.map(\.character).prefix(2) == ["🚀", "🎉"])
        let sections = EmojiPanelView.sections(
            catalog: emoji.catalog, frequent: emoji.frequent, query: "")
        #expect(sections.first?.id == EmojiPanelView.frequentSectionID)
        dump(EmojiPanelView(store: emoji, onDismiss: {}), named: "emoji-panel-frequent")
    }

    @Test func panelKeepsRenderingWhenASearchFindsNothing() throws {
        let store = EmojiStore(catalog: .shared, typeCharacter: { _ in })
        let sections = EmojiPanelView.sections(
            catalog: store.catalog, frequent: store.frequent, query: "zzzznothing")
        #expect(sections.isEmpty)
        let rep = try #require(render(EmojiPanelView(store: store, onDismiss: {})))
        #expect(rep.pixelsWide >= Int(EmojiPanel.width))
    }
}
