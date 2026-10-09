import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct PageScrollPositionTests {
    @Test func navigatingAwayAndBackRestoresTheNativeViewport() async throws {
        let owner = WindowSessionOwner()
        let host = NSHostingView(rootView: page(owner: owner))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await settle(host)
        let first = try #require(scrollView(in: host))
        first.contentView.scroll(to: CGPoint(x: 0, y: 1200))
        first.reflectScrolledClipView(first.contentView)
        let saved = first.contentView.bounds.origin.y
        #expect(saved > 1000)

        host.rootView = AnyView(Text("Another extension"))
        try await settle(host)
        #expect(owner.scrollPositions["sample/"].y == saved)
        host.rootView = page(owner: owner)
        try await settle(host)
        let restored = try #require(scrollView(in: host))
        #expect(abs(restored.contentView.bounds.origin.y - saved) < 2)
        #expect(WindowSessionOwner().scrollPositions["sample/"] == .zero)
    }

    @Test func shorterContentClampsTheRestoredViewport() async throws {
        let owner = WindowSessionOwner()
        owner.scrollPositions["sample/"] = CGPoint(x: 0, y: 50_000)
        let host = NSHostingView(rootView: page(owner: owner))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await settle(host)
        let scroll = try #require(scrollView(in: host))
        let document = try #require(scroll.documentView)
        let viewport = scroll.contentView.bounds
        #expect(viewport.origin.y > 0)
        #expect(viewport.maxY <= document.frame.maxY + scroll.contentInsets.bottom + 2)
        let bottom = scroll.contentView.constrainBoundsRect(
            NSRect(x: 0, y: 50_000, width: viewport.width, height: viewport.height))
        #expect(abs(viewport.origin.y - bottom.origin.y) <= UIScale.pt(PageMetrics.bottom))
    }

    @Test func changingSectionsRetainsSeparatePositionsAndStartsNewSectionsAtTheTop() async throws {
        let owner = WindowSessionOwner()
        let host = NSHostingView(rootView: page(owner: owner, identity: "first"))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await settle(host)
        let first = try #require(scrollView(in: host))
        first.contentView.scroll(to: CGPoint(x: 0, y: 900))
        first.reflectScrolledClipView(first.contentView)
        host.rootView = page(owner: owner, identity: "second")
        try await settle(host)
        let second = try #require(scrollView(in: host))
        #expect(second.contentView.bounds.origin.y < 2)
        host.rootView = page(owner: owner, identity: "first")
        try await settle(host)
        #expect(abs(try #require(scrollView(in: host)).contentView.bounds.origin.y - 900) < 2)
    }

    private func page(owner: WindowSessionOwner, identity: String = "") -> AnyView {
        AnyView(
            PageScaffold(pinnedHeader: true, scrollIdentity: identity) {
                Text("Sample library").padding(16)
            } content: {
                ForEach(0..<500, id: \.self) { index in
                    Text("Sample item \(index)").frame(height: 32)
                }
            }
            .environment(\.windowSessionOwner, owner)
            .environment(\.pageLocation, "sample"))
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }
}
