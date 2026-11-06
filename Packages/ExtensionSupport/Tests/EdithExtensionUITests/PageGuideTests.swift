import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

@MainActor
@Suite(.serialized)
struct PageGuideTests {
    static let variants = [
        RenderCapture.Variant(
            name: "regular-dark", width: 1100, height: 320, zoom: 1, scheme: .dark),
        RenderCapture.Variant(
            name: "regular-light", width: 1100, height: 320, zoom: 1, scheme: .light),
        RenderCapture.Variant(
            name: "compact-dark", width: 620, height: 320, zoom: 1, scheme: .dark),
        RenderCapture.Variant(
            name: "zoom-light", width: 1100, height: 420, zoom: 1.6, scheme: .light),
        RenderCapture.Variant(
            name: "zoom-dark", width: 1100, height: 420, zoom: 1.6, scheme: .dark),
    ]

    private func frames<V: View>(
        _ variant: RenderCapture.Variant, labels: [String], @ViewBuilder content: () -> V
    ) async throws -> [String: CGRect] {
        try await RenderCapture.render("page-guide", variant: variant, content: content)
        return try await RenderCapture.withAccessibility {
            let previous = UIScale.current
            UIScale.apply(variant.zoom)
            defer { UIScale.apply(previous) }
            let host = NSHostingView(
                rootView: content()
                    .frame(width: variant.width, height: variant.height, alignment: .topLeading)
                    .environment(\.compactLayout, variant.compact)
                    .environment(\.colorScheme, variant.scheme))
            host.frame = CGRect(origin: .zero, size: variant.size)
            let window = TestWindowHost.window(contentRect: host.frame)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            var result: [String: CGRect] = [:]
            for label in labels {
                let node = try #require(RenderCapture.find(host, label: label), "\(label)")
                result[label] = try #require((node as AnyObject).accessibilityFrame?())
            }
            return result
        }
    }

    private func header(_ guide: PageGuideAction?) -> some View {
        PageWorkspace {
            PageHeader(title: { Text("Synthetic agents") }) {
                HStack(spacing: UIScale.pt(2)) {
                    PageToolbarButton(action: {}, icon: .link, helperText: "Synthetic connections")
                    PageToolbarButton(action: {}, icon: .search, helperText: "Synthetic search")
                }
            }
        } content: {
            Color.clear
        }
        .pageGuideFallback()
        .environment(\.pageGuide, guide)
    }

    @Test func headerAppendsTheGuideAsItsLastAction() async throws {
        let guide = PageGuideAction(id: "synthetic", title: "Synthetic agents") {}
        for variant in Self.variants {
            let found = try await frames(
                variant, labels: ["About Synthetic agents", "Synthetic search"]
            ) { header(guide) }
            let about = try #require(found["About Synthetic agents"])
            let search = try #require(found["Synthetic search"])
            #expect(about.width > 1, "\(variant.name)")
            #expect(abs(about.midY - search.midY) <= 1, "\(variant.name)")
            #expect(about.minX >= search.maxX, "\(variant.name)")
            #expect(abs(about.width - search.width) <= 0.5, "\(variant.name)")
            #expect(abs(about.height - search.height) <= 0.5, "\(variant.name)")
        }
    }

    @Test func headerWithoutAGuideHasNoInfoButton() async throws {
        try await RenderCapture.withAccessibility {
            let rendered = try await RenderCapture.render(
                "page-guide-none", variant: Self.variants[0]
            ) { header(nil) }
            #expect(RenderCapture.find(rendered.host, label: "About Synthetic agents") == nil)
        }
    }

    @Test func pagesWithoutAHeaderShowTheGuideInATopRightRow() async throws {
        let guide = PageGuideAction(id: "synthetic", title: "Synthetic canvas") {}
        for variant in Self.variants {
            let found = try await frames(
                variant, labels: ["About Synthetic canvas", "Synthetic bounds", "Synthetic title"]
            ) {
                VStack {
                    Text("Synthetic canvas").font(.edithText(.title2))
                        .accessibilityLabel("Synthetic title")
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .pageGuideFallback()
                .environment(\.pageGuide, guide)
                .background {
                    Color.primary.opacity(0.001).accessibilityElement()
                        .accessibilityLabel("Synthetic bounds")
                }
            }
            let about = try #require(found["About Synthetic canvas"])
            let bounds = try #require(found["Synthetic bounds"])
            let gutter =
                (variant.compact ? PageMetrics.compactGutter : PageMetrics.gutter) * variant.zoom
            #expect(about.width > 1, "\(variant.name)")
            #expect(abs(bounds.maxX - about.maxX - gutter) <= 1, "\(variant.name)")
            #expect(abs(bounds.maxY - about.maxY - PageMetrics.guideRowTop * variant.zoom) <= 1)
            let title = try #require(found["Synthetic title"])
            #expect(title.maxY <= about.minY + 0.5, "\(variant.name)")
        }
    }

    @Test func bridgeCarriesTheGuideIntoANestedHostingView() async throws {
        _ = TestWindowHost.application
        var opened = 0
        let anchor = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let window = TestWindowHost.window(contentRect: anchor.frame)
        window.isReleasedWhenClosed = false
        window.contentView = anchor
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        final class Box { var guide: PageGuideAction? }
        let box = Box()
        let probe = NSHostingView(rootView: PageGuideProbe { box.guide = $0 })
        probe.frame = anchor.bounds
        PageGuideBridge.attach(
            PageGuideAction(id: "synthetic", title: "Synthetic") { opened += 1 }, to: anchor)
        anchor.addSubview(probe)
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(100))
        let first = try #require(box.guide)
        #expect(first.title == "Synthetic")
        first.perform()
        #expect(opened == 1)
        PageGuideBridge.attach(nil, to: anchor)
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.guide == nil)
        PageGuideBridge.attach(PageGuideAction(id: "next", title: "Later") {}, to: anchor)
        try await Task.sleep(for: .milliseconds(50))
        #expect(box.guide?.title == "Later")
    }
}
