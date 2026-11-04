import AppKit
import QuartzCore
import SwiftUI

struct UsageScrollTiming: CustomStringConvertible {
    var frames: [Double]
    var offsets: [CGFloat] = []
    var viewport: CGFloat = 0
    var document: CGFloat = 0

    var slowOffsets: [Int] {
        zip(frames, offsets).filter { $0.0 > 1000.0 / 60 }.map { Int($0.1) }
    }

    private var sorted: [Double] { frames.sorted() }
    var median: Double { sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
    var p95: Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)] }
    var worst: Double { sorted.last ?? 0 }
    var total: Double { frames.reduce(0, +) }
    var hitches: Int { frames.filter { $0 > 1000.0 / 60 }.count }

    var description: String {
        String(
            format:
                "frames=%d median=%.2fms p95=%.2fms max=%.2fms over16ms=%d total=%.0fms viewport=%.0f document=%.0f",
            frames.count, median, p95, worst, hitches, total, viewport, document)
    }
}

@MainActor
enum UsageScrollHarness {
    static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        return application
    }()

    static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        _ = application
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        let window = OffscreenWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        window.setFrameOrigin(NSPoint(x: minX - size.width - 1_000, y: minY - size.height - 1_000))
        window.contentView = host
        window.orderBack(nil)
        return (window, host)
    }

    static func settle(_ host: NSView, for duration: Duration = .milliseconds(400)) async {
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView { found.append(scroll) }
            queue.append(contentsOf: next.subviews)
        }
        return found
    }

    static func nested(_ scroll: NSScrollView) -> Bool {
        var parent = scroll.superview
        while let current = parent {
            if current is NSScrollView { return true }
            parent = current.superview
        }
        return false
    }

    static func scrollView(in view: NSView, inner: Bool = false) -> NSScrollView? {
        let height: (NSScrollView) -> CGFloat = { $0.documentView?.frame.height ?? 0 }
        return scrollViews(in: view)
            .filter { nested($0) == inner && (!inner || height($0) > 1_000) }
            .max { height($0) < height($1) }
    }

    static func revealNestedScroll(in host: NSView) async {
        guard let outer = scrollView(in: host) else { return }
        let clip = outer.contentView
        var y: CGFloat = 0
        while scrollView(in: host, inner: true) == nil {
            let maximum = max(0, (outer.documentView?.frame.height ?? 0) - clip.bounds.height)
            guard y <= maximum else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            outer.reflectScrolledClipView(clip)
            await settle(host, for: .milliseconds(120))
            y += 200
        }
        await settle(host, for: .milliseconds(300))
    }

    static func scroll(
        _ host: NSView, inner: Bool = false, step: CGFloat = 24, frames: Int = 240,
        frameBudget: Double = 1000.0 / 120
    ) async -> UsageScrollTiming {
        guard let scroll = scrollView(in: host, inner: inner) else {
            return UsageScrollTiming(frames: [])
        }
        var timings: [Double] = []
        var offsets: [CGFloat] = []
        var direction: CGFloat = 1
        for _ in 0..<frames {
            let start = CACurrentMediaTime()
            let clip = scroll.contentView
            let maximum = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            var y = clip.bounds.origin.y + step * direction
            if y >= maximum || y <= 0 {
                direction = -direction
                y = min(max(0, y), maximum)
            }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            CATransaction.flush()
            RunLoop.main.run(until: Date())
            let elapsed = (CACurrentMediaTime() - start) * 1000
            timings.append(elapsed)
            offsets.append(y)
            let rest = frameBudget - elapsed
            if rest > 0 { try? await Task.sleep(for: .microseconds(Int(rest * 1000))) }
        }
        return UsageScrollTiming(
            frames: timings, offsets: offsets, viewport: scroll.frame.height,
            document: scroll.documentView?.frame.height ?? 0)
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
