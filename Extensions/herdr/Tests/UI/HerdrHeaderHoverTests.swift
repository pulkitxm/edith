import AppKit
import EdithExtensionSupport
import EdithExtensionUI
@testable import HerdrUI
import SwiftUI
import Testing

final class HerdrPointerWindow: NSWindow {
    var pointer = NSPoint(x: -10_000, y: -10_000)
    private var insideAreas = Set<ObjectIdentifier>()

    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func move(to point: NSPoint) {
        pointer = point
        guard let root = contentView else { return }
        let time = ProcessInfo.processInfo.systemUptime
        var pending: [NSView] = [root]
        var visited: [(view: NSView, area: NSTrackingArea)] = []
        while let view = pending.popLast() {
            pending += view.subviews
            for area in view.trackingAreas { visited.append((view, area)) }
        }
        var entered = Set<ObjectIdentifier>()
        for (view, area) in visited {
            let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
            let inside = rect.contains(view.convert(point, from: nil))
            let key = ObjectIdentifier(area)
            if inside { entered.insert(key) }
            guard let owner = area.owner as? NSResponder else { continue }
            if inside != insideAreas.contains(key), area.options.contains(.mouseEnteredAndExited),
                let crossing = NSEvent.enterExitEvent(
                    with: inside ? .mouseEntered : .mouseExited, location: point,
                    modifierFlags: [], timestamp: time, windowNumber: windowNumber, context: nil,
                    eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self),
                    userData: nil)
            {
                if inside {
                    owner.mouseEntered(with: crossing)
                } else {
                    owner.mouseExited(with: crossing)
                }
            }
            if inside, area.options.contains(.mouseMoved),
                let moved = NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [], timestamp: time,
                    windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 0,
                    pressure: 0)
            {
                owner.mouseMoved(with: moved)
            }
        }
        insideAreas = entered
    }
}

@MainActor
@Suite(.serialized) struct HerdrHeaderHoverTests {
    static let labels = ["Agent connections", "Search", "New Agent", "Refresh", "About Agents"]

    private func snapshot(_ host: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func changed(
        _ lhs: NSBitmapImageRep, _ rhs: NSBitmapImageRep, in rect: CGRect, scale: CGFloat
    ) -> Int {
        var count = 0
        let minX = max(0, Int((rect.minX - 6) * scale))
        let maxX = min(lhs.pixelsWide, Int((rect.maxX + 6) * scale))
        let minY = max(0, Int((rect.minY - 6) * scale))
        let maxY = min(lhs.pixelsHigh, Int((rect.maxY + 6) * scale))
        guard minX < maxX, minY < maxY else { return 0 }
        for x in minX..<maxX {
            for y in minY..<maxY {
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

    @Test(arguments: [false, true])
    func everyHeaderButtonShowsAPlateOnHover(dark: Bool) async throws {
        let suite = "HerdrHeaderHoverTests-\(UUID().uuidString)"
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
                    .environment(\.compactLayout, false)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .transaction { $0.animation = nil }))
        let size = CGSize(width: 1100, height: 760)
        host.frame = CGRect(origin: .zero, size: size)
        _ = TestWindowHost.application
        let window = HerdrPointerWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -6_000, y: -6_000))
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.acceptsMouseMovedEvents = true
        window.orderBack(nil)
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
        let frames = HerdrIntroductionButtonTests.frames(host, labels: Self.labels)
        let scale = window.backingScaleFactor
        let idle = try snapshot(host)
        var targets: [(String, CGRect)] = Self.labels.compactMap { label in
            frames[label].map { (label, window.convertFromScreen($0)) }
        }
        #expect(targets.count == Self.labels.count, "\(frames.keys.sorted())")
        if let connections = frames["Agent connections"], let search = frames["Search"] {
            let gap = window.convertFromScreen(
                CGRect(
                    x: connections.maxX, y: connections.minY,
                    width: search.minX - connections.maxX, height: connections.height))
            targets.insert(("Message", gap), at: 1)
        }
        for (label, inWindow) in targets {
            let inHost = host.convert(inWindow, from: nil)
            window.move(to: NSPoint(x: inWindow.midX, y: inWindow.midY))
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            let hovered = try snapshot(host)
            #expect(changed(idle, hovered, in: inHost, scale: scale) > 400, "\(label) hover")
            if label == "Search" {
                try HerdrPageCaptureTests.capture(
                    host, name: "herdr-header-search-hovered-\(dark ? "dark" : "light")")
            }
            window.move(to: NSPoint(x: -10_000, y: -10_000))
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded()
            #expect(
                changed(idle, try snapshot(host), in: inHost, scale: scale) == 0, "\(label) exit")
        }
    }
}
