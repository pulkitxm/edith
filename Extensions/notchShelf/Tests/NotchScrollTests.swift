import AppKit
import EdithExtensionTestSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchScrollTests {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private func mountScroller(in window: NSWindow) -> (NSScrollView, NSView) {
        let scroller = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = FlippedDocument(frame: CGRect(x: 0, y: 0, width: 400, height: 1500))
        scroller.documentView = document
        window.contentView = scroller
        return (scroller, document)
    }

    @Test func reportedSlotRectangleIgnoresScrollOffset() {
        let viewport = CGRect(x: 16, y: 70, width: 600, height: 260)
        let resting = NotchNativeSlotView.scrollInvariant(
            CGRect(x: 16, y: 420, width: 280, height: 180), in: viewport)
        let scrolled = NotchNativeSlotView.scrollInvariant(
            CGRect(x: 16, y: -90, width: 280, height: 180), in: viewport)
        let tall = NotchNativeSlotView.scrollInvariant(
            CGRect(x: 16, y: 0, width: 280, height: 900), in: viewport)
        #expect(resting == scrolled)
        #expect(viewport.contains(resting))
        #expect(resting.size == CGSize(width: 280, height: 180))
        #expect(tall.height == viewport.height)
    }

    @Test func slotAnchorsCarryTheirIdentifierAndAnnounceThemselves() {
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200))
        let anchor = NotchSlotAnchorView()
        anchor.anchorIdentifier = NotchSlotAnchorView.prefix + "card:keepAwake:tile"
        var announced: [NSView] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NotchSlotAnchorView.appeared, object: nil, queue: nil
        ) { note in
            if let view = note.object as? NSView { announced.append(view) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        window.contentView?.addSubview(anchor)
        #expect(anchor.identifier?.rawValue == "edith.notch.slot.card:keepAwake:tile")
        #expect(announced.contains { $0 === anchor })
        #expect(anchor.hitTest(.zero) == nil)
    }

    @Test func homeScrollPositionSurvivesCollapseAndReopen() async throws {
        let offset = NotchScrollOffset()
        let first = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        let (scroller, document) = mountScroller(in: first)
        document.addSubview(NotchScrollMemoryView(offset: offset))
        try await Task.sleep(for: .milliseconds(20))
        scroller.contentView.scroll(to: CGPoint(x: 0, y: 420))
        #expect(offset.origin.y == 420)
        first.contentView = nil

        let second = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        let (reopened, reopenedDocument) = mountScroller(in: second)
        reopenedDocument.addSubview(NotchScrollMemoryView(offset: offset))
        try await Task.sleep(for: .milliseconds(20))
        #expect(reopened.contentView.bounds.origin.y == 420)
    }

    @Test func restoredScrollPositionClampsToShorterContent() async throws {
        let offset = NotchScrollOffset()
        offset.origin = CGPoint(x: 0, y: 5000)
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300))
        let (scroller, document) = mountScroller(in: window)
        document.addSubview(NotchScrollMemoryView(offset: offset))
        try await Task.sleep(for: .milliseconds(20))
        #expect(scroller.contentView.bounds.origin.y == 1500 - scroller.contentView.bounds.height)
    }
}
