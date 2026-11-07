import AppKit
import EdithExtensionTestSupport
import SwiftUI
import Testing

@testable import EdithExtensionUI

private final class TitlebarTestWindow: NSWindow {
    override var mouseLocationOutsideOfEventStream: NSPoint { NSPoint(x: -10_000, y: -10_000) }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
@Suite(.serialized)
struct HoverRouterTests {
    struct Fixture {
        let window: NSWindow
        let host: NSView
        let trackers: [EdithHoverTrackingView]
        let strip: CGRect

        func close() {
            window.contentView = nil
            window.close()
        }
    }

    private func fixture<Content: View>(
        dense: Bool = false, @ViewBuilder content: () -> Content
    ) async throws -> Fixture {
        _ = TestWindowHost.application
        let size = CGSize(width: 420, height: 220)
        let window = TitlebarTestWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.setFrameOrigin(NSPoint(x: -8_000, y: -8_000))
        let host = NSHostingView(
            rootView: VStack(spacing: 0) {
                HStack(spacing: 2) { content() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 16)
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .environment(\.edithDenseHover, dense)
            .transaction { $0.animation = nil })
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let layout = window.contentLayoutRect
        let strip = CGRect(
            x: 0, y: layout.maxY, width: host.bounds.width,
            height: host.bounds.height - layout.maxY)
        let trackers = (EdithHoverRouter.router(for: window)?.registered ?? [])
            .sorted { ($0.windowFrame?.minX ?? 0) < ($1.windowFrame?.minX ?? 0) }
        return Fixture(window: window, host: host, trackers: trackers, strip: strip)
    }

    private func move(_ fixture: Fixture, to point: NSPoint, windowNumber: Int? = nil) throws {
        let event = try #require(
            NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber ?? fixture.window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0))
        EdithHoverRouter.dispatch(event)
    }

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func changed(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, in windowRect: CGRect, host: NSView
    ) -> Int {
        let rect = host.convert(windowRect, from: nil)
        let scale = CGFloat(lhs.pixelsWide) / host.bounds.width
        let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
        var count = 0
        for x in max(0, Int(rect.minX * scale))..<min(lhs.pixelsWide, Int(rect.maxX * scale)) {
            for y in max(0, Int(top * scale))..<min(lhs.pixelsHigh, Int((top + rect.height) * scale))
            {
                guard let a = lhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let b = rhs.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let distance =
                    abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if distance > 0.02 { count += 1 }
            }
        }
        return count
    }

    private func toolbarPair() -> some View {
        Group {
            PageToolbarButton(action: {}, icon: .search, helperText: "Synthetic search")
            PageToolbarMenu(icon: .send, helperText: "Synthetic send") {
                Button("Synthetic item") {}
            }
        }
    }

    @Test func titlebarControlLightsWhenTheRouterSeesThePointerInside() async throws {
        let fixture = try await fixture { toolbarPair() }
        defer { fixture.close() }
        #expect(fixture.window.acceptsMouseMovedEvents)
        #expect(fixture.trackers.count == 2)
        let first = try #require(fixture.trackers.first?.windowFrame)
        #expect(fixture.strip.height > 0)
        #expect(fixture.strip.intersects(first), "\(first) \(fixture.strip)")
        #expect(fixture.trackers.allSatisfy { !$0.inside })
        let idle = try snapshot(fixture.host)

        try move(fixture, to: NSPoint(x: first.midX, y: first.midY))
        #expect(fixture.trackers.map(\.inside) == [true, false])
        try await Task.sleep(for: .milliseconds(300))
        fixture.host.layoutSubtreeIfNeeded()
        let lit = try snapshot(fixture.host)
        #expect(changed(idle, lit, in: first, host: fixture.host) > 200)

        try move(fixture, to: NSPoint(x: 40, y: first.midY))
        #expect(fixture.trackers.map(\.inside) == [false, false])
        try await Task.sleep(for: .milliseconds(300))
        fixture.host.layoutSubtreeIfNeeded()
        #expect(changed(idle, try snapshot(fixture.host), in: first, host: fixture.host) == 0)
    }

    @Test func sweepingAcrossAdjacentControlsHandsHoverOverWithoutADoubleLitState() async throws {
        let fixture = try await fixture { toolbarPair() }
        defer { fixture.close() }
        let frames = fixture.trackers.compactMap(\.windowFrame)
        try #require(frames.count == 2)
        #expect(frames[1].minX - frames[0].maxX < 4)
        var sequence: [Int] = []
        var x = frames[0].midX
        while x <= frames[1].midX {
            try move(fixture, to: NSPoint(x: x, y: frames[0].midY))
            let lit = fixture.trackers.enumerated().filter(\.element.inside).map(\.offset)
            #expect(lit.count <= 1, "x \(x) lit \(lit)")
            let state = lit.first ?? -1
            if sequence.last != state { sequence.append(state) }
            x += 0.5
        }
        #expect(sequence.first == 0)
        #expect(sequence.last == 1)
        #expect(sequence.filter { $0 >= 0 } == [0, 1], "\(sequence)")
    }

    @Test func eventsFromAnotherWindowAndResignationLeaveNoStaleHover() async throws {
        let fixture = try await fixture { toolbarPair() }
        defer { fixture.close() }
        let first = try #require(fixture.trackers.first?.windowFrame)
        let centre = NSPoint(x: first.midX, y: first.midY)
        try move(fixture, to: centre, windowNumber: fixture.window.windowNumber + 9_999)
        #expect(fixture.trackers.allSatisfy { !$0.inside })
        try move(fixture, to: centre)
        #expect(fixture.trackers.first?.inside == true)
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification, object: fixture.window)
        #expect(fixture.trackers.allSatisfy { !$0.inside })
        try move(fixture, to: centre)
        #expect(fixture.trackers.first?.inside == true)
        fixture.trackers.first?.superview?.isHidden = true
        try move(fixture, to: centre)
        #expect(fixture.trackers.allSatisfy { !$0.inside })
    }

    @Test func denseCellsStayOutOfTheRouter() async throws {
        let fixture = try await fixture(dense: true) {
            ForEach(0..<6, id: \.self) { index in
                Button("Cell \(index)") {}.buttonStyle(.edith(.borderless))
            }
        }
        defer { fixture.close() }
        #expect(fixture.trackers.isEmpty)
    }

    @Test func toolbarButtonsMenusAndTheGuideShareOnePlateFrame() async throws {
        let guide = PageGuideAction(id: "synthetic", title: "Synthetic") {}
        let fixture = try await fixture {
            PageToolbarButton(
                action: {}, icon: .link, helperText: "Synthetic link",
                font: .edithText(.headline))
            PageToolbarMenu(
                icon: .send, helperText: "Synthetic send", font: .edithText(.headline)
            ) {
                Button("Synthetic item") {}
            }
            PageToolbarMenu(icon: .more, helperText: "Synthetic more") {
                Button("Synthetic item") {}
            }
            PageToolbarButton(action: {}, icon: .plus, helperText: "Synthetic add")
            PageGuideButton(guide)
        }
        defer { fixture.close() }
        let frames = fixture.trackers.compactMap(\.windowFrame)
        #expect(frames.count == 5)
        for frame in frames {
            #expect(abs(frame.width - UIScale.pt(32)) <= 0.5, "\(frames)")
            #expect(abs(frame.height - UIScale.pt(32)) <= 0.5, "\(frames)")
            #expect(abs(frame.midY - frames[0].midY) <= 0.5, "\(frames)")
        }
    }

    @Test func closingTheWindowReleasesItsRouter() async throws {
        let fixture = try await fixture { toolbarPair() }
        #expect(EdithHoverRouter.router(for: fixture.window) != nil)
        fixture.close()
        #expect(EdithHoverRouter.router(for: fixture.window) == nil)
    }
}
