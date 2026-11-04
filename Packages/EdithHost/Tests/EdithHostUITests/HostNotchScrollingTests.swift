import AppKit
import SwiftUI
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostNotchScrollingTests {
    private final class FlippedDocument: NSView {
        override var isFlipped: Bool { true }
    }

    private final class WheelView: NSView {
        override func scrollWheel(with event: NSEvent) {}
    }

    private struct Fixture {
        let window: NSWindow
        let container: HostNotchContainerController
        let chrome: NSScrollView
        let document: NSView
    }

    private func fixture(documentSize: CGSize = CGSize(width: 640, height: 1600)) -> Fixture {
        _ = TestWindowHost.application
        let container = HostNotchContainerController()
        container.loadViewIfNeeded()
        let window = TestWindowHost.window(contentRect: CGRect(x: 0, y: 0, width: 640, height: 320))
        window.contentView = container.view
        container.view.frame = CGRect(x: 0, y: 0, width: 640, height: 320)
        let chrome = NSScrollView(frame: container.view.bounds)
        chrome.hasVerticalScroller = true
        chrome.hasHorizontalScroller = true
        chrome.scrollerStyle = .overlay
        let document = FlippedDocument(frame: CGRect(origin: .zero, size: documentSize))
        chrome.documentView = document
        let controller = NSViewController()
        controller.view = chrome
        container.attach(controller, rectangle: nil, native: false)
        return Fixture(window: window, container: container, chrome: chrome, document: document)
    }

    private func card(_ view: NSView = NSView()) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private func windowPoint(_ point: CGPoint, in fixture: Fixture) -> CGPoint {
        fixture.container.view.convert(point, to: nil)
    }

    private func anchor(_ identifier: String, frame: CGRect, in document: NSView) -> NSView {
        let anchor = NSView(frame: frame)
        anchor.identifier = NSUserInterfaceItemIdentifier(identifier)
        document.addSubview(anchor)
        return anchor
    }

    private func scrollEvent(
        deltaX: Int32 = 0, deltaY: Int32 = 0, phase: CGScrollPhase? = nil,
        momentum: CGMomentumScrollPhase = .none
    ) throws -> NSEvent {
        let event = try #require(
            CGEvent(
                scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY,
                wheel2: deltaX, wheel3: 0))
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return try #require(NSEvent(cgEvent: event))
    }

    @Test func verticalScrollOverANativeCardReachesThePanelScroller() {
        let fixture = fixture()
        let slot = CGRect(x: 20, y: 60, width: 300, height: 200)
        fixture.container.attach(card(), rectangle: slot, native: true)
        let target = fixture.container.scrollTarget(
            at: windowPoint(CGPoint(x: slot.midX, y: slot.midY), in: fixture), axis: .vertical)
        #expect(target === fixture.chrome)
    }

    @Test func verticalScrollOverEmptyPanelSpaceReachesThePanelScroller() {
        let fixture = fixture()
        let target = fixture.container.scrollTarget(
            at: windowPoint(CGPoint(x: 600, y: 300), in: fixture), axis: .vertical)
        #expect(target === fixture.chrome)
    }

    @Test func swiftUIScrollWheelOverridesDoNotSwallowPanelScrolling() {
        let fixture = fixture()
        let slot = CGRect(x: 20, y: 60, width: 300, height: 200)
        let hosting = NSHostingView(rootView: Color.clear.frame(width: 300, height: 200))
        fixture.container.attach(card(hosting), rectangle: slot, native: true)
        let target = fixture.container.scrollTarget(
            at: windowPoint(CGPoint(x: slot.midX, y: slot.midY), in: fixture), axis: .vertical)
        #expect(target === fixture.chrome)
    }

    @Test func horizontalScrollInsideACardStaysWithTheCardsOwnScroller() {
        let fixture = fixture()
        let slot = CGRect(x: 20, y: 60, width: 300, height: 120)
        let strip = NSScrollView(frame: CGRect(origin: .zero, size: slot.size))
        strip.hasHorizontalScroller = true
        strip.scrollerStyle = .overlay
        strip.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 120))
        fixture.container.attach(card(strip), rectangle: slot, native: true)
        let point = windowPoint(CGPoint(x: slot.midX, y: slot.midY), in: fixture)
        #expect(fixture.container.scrollTarget(at: point, axis: .horizontal) === strip)
        #expect(fixture.container.scrollTarget(at: point, axis: .vertical) === fixture.chrome)
    }

    @Test func horizontalScrollOverACardWithoutAScrollerReachesAWideShelf() {
        let fixture = fixture(documentSize: CGSize(width: 2000, height: 300))
        let slot = CGRect(x: 20, y: 60, width: 200, height: 160)
        fixture.container.attach(card(), rectangle: slot, native: true)
        let point = windowPoint(CGPoint(x: slot.midX, y: slot.midY), in: fixture)
        #expect(fixture.container.scrollTarget(at: point, axis: .horizontal) === fixture.chrome)
        #expect(fixture.container.scrollTarget(at: point, axis: .vertical) == nil)
    }

    @Test func webAndTerminalContentKeepTheirOwnScrolling() {
        let fixture = fixture()
        let slot = CGRect(x: 20, y: 60, width: 300, height: 200)
        fixture.container.attach(
            card(WheelView(frame: CGRect(origin: .zero, size: slot.size))), rectangle: slot,
            native: true)
        let target = fixture.container.scrollTarget(
            at: windowPoint(CGPoint(x: slot.midX, y: slot.midY), in: fixture), axis: .vertical)
        #expect(target == nil)
    }

    @Test func anchoredCardsFollowThePanelScrollWithoutResizing() {
        let fixture = fixture()
        let identifier = HostNotchSlotAnchor.identifier(
            kind: "card", providerID: "keepAwake", tileID: "tile")
        let anchor = anchor(
            identifier, frame: CGRect(x: 20, y: 200, width: 300, height: 180), in: fixture.document)
        let controller = card()
        fixture.container.attach(
            controller, rectangle: CGRect(x: 0, y: 0, width: 300, height: 180), native: true,
            anchor: identifier)
        #expect(fixture.container.placedFrame(of: controller)?.minY == 200)

        fixture.chrome.contentView.scroll(to: CGPoint(x: 0, y: 120))
        #expect(fixture.container.placedFrame(of: controller)?.minY == 80)
        #expect(controller.view.frame.size == anchor.frame.size)

        fixture.chrome.contentView.scroll(to: CGPoint(x: 0, y: 300))
        let clip = controller.view.superview
        #expect(clip?.frame.minY == 0)
        #expect(clip?.frame.height == 80)
        #expect(controller.view.frame.size == anchor.frame.size)

        fixture.chrome.contentView.scroll(to: CGPoint(x: 0, y: 900))
        #expect(clip?.isHidden == true)
        fixture.chrome.contentView.scroll(to: .zero)
        #expect(clip?.isHidden == false)
        #expect(fixture.container.placedFrame(of: controller)?.minY == 200)
    }

    @Test func anchoredCardsDoNotGlideWhileScrolling() {
        let fixture = fixture()
        let identifier = HostNotchSlotAnchor.identifier(
            kind: "card", providerID: "keepAwake", tileID: "tile")
        _ = anchor(
            identifier, frame: CGRect(x: 20, y: 200, width: 300, height: 180), in: fixture.document)
        let controller = card()
        let rectangle = CGRect(x: 0, y: 0, width: 300, height: 180)
        fixture.container.attach(controller, rectangle: rectangle, native: true, anchor: identifier)
        fixture.chrome.contentView.scroll(to: CGPoint(x: 0, y: 60))
        fixture.container.attach(controller, rectangle: rectangle, native: true, anchor: identifier)
        #expect(!fixture.container.slotAnimating)
    }

    @Test func lateAnchorsAdoptTheirWaitingCard() {
        let fixture = fixture()
        let identifier = HostNotchSlotAnchor.identifier(
            kind: "card", providerID: "keepAwake", tileID: "late")
        let controller = card()
        fixture.container.attach(
            controller, rectangle: CGRect(x: 0, y: 0, width: 300, height: 180), native: true,
            anchor: identifier)
        let anchor = anchor(
            identifier, frame: CGRect(x: 20, y: 140, width: 300, height: 180), in: fixture.document)
        NotificationCenter.default.post(name: HostNotchSlotAnchor.appeared, object: anchor)
        #expect(fixture.container.placedFrame(of: controller)?.minY == 140)
    }

    @Test func gestureStaysWithItsFirstTargetThroughMomentum() throws {
        let router = HostNotchScrollRouter()
        let first = NSView()
        let second = NSView()
        var candidate = first
        var resolutions = 0
        var delivered: [NSView?] = []
        let resolve: HostNotchScrollRouter.Resolve = { _, _ in
            resolutions += 1
            return candidate
        }
        let deliver: HostNotchScrollRouter.Deliver = { delivered.append($1) }

        router.route(try scrollEvent(phase: .mayBegin), resolve: resolve, deliver: deliver)
        router.route(
            try scrollEvent(deltaY: -12, phase: .began), resolve: resolve, deliver: deliver)
        candidate = second
        router.route(
            try scrollEvent(deltaY: -30, phase: .changed), resolve: resolve, deliver: deliver)
        router.route(try scrollEvent(phase: .ended), resolve: resolve, deliver: deliver)
        router.route(
            try scrollEvent(deltaY: -20, momentum: .begin), resolve: resolve, deliver: deliver)
        router.route(
            try scrollEvent(deltaY: -4, momentum: .continuous), resolve: resolve, deliver: deliver)
        router.route(try scrollEvent(momentum: .end), resolve: resolve, deliver: deliver)

        #expect(resolutions == 1)
        #expect(delivered.count == 7)
        #expect(delivered.dropFirst().allSatisfy { $0 === first })
        #expect(delivered.first.map { $0 === first } == true)

        router.route(
            try scrollEvent(deltaY: -12, phase: .began), resolve: resolve, deliver: deliver)
        #expect(resolutions == 2)
        #expect(delivered.last.map { $0 === second } == true)
    }

    @Test func mouseWheelTicksResolvePerEvent() throws {
        let router = HostNotchScrollRouter()
        let target = NSView()
        var axes: [HostNotchScrollAxis] = []
        var delivered: [NSView?] = []
        let resolve: HostNotchScrollRouter.Resolve = { _, axis in
            axes.append(axis)
            return target
        }
        let deliver: HostNotchScrollRouter.Deliver = { delivered.append($1) }
        router.route(try scrollEvent(deltaY: -3), resolve: resolve, deliver: deliver)
        router.route(try scrollEvent(deltaX: 3), resolve: resolve, deliver: deliver)
        #expect(axes == [.vertical, .horizontal])
        #expect(delivered.count == 2)
        #expect(delivered.allSatisfy { $0 === target })
    }
}
