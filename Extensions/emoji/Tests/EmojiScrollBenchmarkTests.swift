import AppKit
import SwiftUI
import Testing

@testable import EmojiExtension
import EdithExtensionSupport
import EdithExtensionUI

@Suite(.serialized) @MainActor struct EmojiScrollBenchmarkTests {
    static let medianBudget = ProcessInfo.processInfo.environment["CI"] == nil ? 10.0 : 1000.0 / 30
    private let fixture = EmojiDefaultsFixture()

    @Test func scrollingTheRealCatalogStaysWithinTheFrameBudget() async {
        let store = EmojiStore(
            defaults: fixture.defaults, writePasteboard: fixture.writePasteboard, catalog: .shared,
            typeCharacter: { _ in true })
        let (window, host) = EmojiScrollHarness.host(
            EmojiPanelView(store: store, onDismiss: {})
                .environment(\.colorScheme, .dark),
            size: CGSize(width: EmojiPanel.width, height: EmojiPanel.height))
        await EmojiScrollHarness.settle(host, for: .seconds(1))
        let frames =
            Int(ProcessInfo.processInfo.environment["EDITH_SCROLL_FRAMES"] ?? "") ?? 300
        let timing = await EmojiScrollHarness.scroll(host, step: 36, frames: frames)
        print(
            "emoji-scroll catalog=\(store.catalog.emoji.count): \(timing) slowAt=\(timing.slowOffsets)"
        )
        window.orderOut(nil)
        window.contentView = nil
        #expect(timing.frames.count == frames)
        #expect(timing.frames.filter { $0 > 80 }.isEmpty, "\(timing)")
        #expect(timing.median < Self.medianBudget, "\(timing)")
    }
}
