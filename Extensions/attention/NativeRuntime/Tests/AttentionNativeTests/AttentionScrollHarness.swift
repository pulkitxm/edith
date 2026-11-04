import AppKit
import QuartzCore
import SwiftUI

struct AttentionScrollTiming: CustomStringConvertible {
    var frames: [Double]
    var offsets: [CGFloat] = []

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
            format: "frames=%d median=%.2fms p95=%.2fms max=%.2fms over16ms=%d total=%.0fms",
            frames.count, median, p95, worst, hitches, total)
    }
}

@MainActor
enum AttentionScrollHarness {
    static let application: NSApplication = {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        return application
    }()

    static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        _ = application
        let host = NSHostingView(rootView: view)
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

    static func scrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView, scroll.hasVerticalScroller || best == nil {
                if best == nil
                    || (scroll.documentView?.frame.height ?? 0)
                        > (best?.documentView?.frame.height ?? 0)
                {
                    best = scroll
                }
            }
            queue.append(contentsOf: next.subviews)
        }
        return best
    }

    static func scroll(
        _ host: NSView, step: CGFloat = 24, frames: Int = 240, frameBudget: Double = 1000.0 / 120
    ) async -> AttentionScrollTiming {
        guard let scroll = scrollView(in: host) else { return AttentionScrollTiming(frames: []) }
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
        return AttentionScrollTiming(frames: timings, offsets: offsets)
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
