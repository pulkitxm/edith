import AppKit
import QuartzCore
import SwiftUI

struct HostScrollTiming: CustomStringConvertible {
    var frames: [Double]

    private var sorted: [Double] { frames.sorted() }
    var median: Double { sorted.isEmpty ? 0 : sorted[sorted.count / 2] }
    var p95: Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, sorted.count * 95 / 100)] }
    var worst: Double { sorted.last ?? 0 }
    var hitches: Int { frames.filter { $0 > 1000.0 / 60 }.count }
    var slowFrames: [Int] { frames.indices.filter { frames[$0] > 1000.0 / 60 } }

    var description: String {
        String(
            format: "frames=%d median=%.2fms p95=%.2fms max=%.2fms over16ms=%d slowFrames=%@",
            frames.count, median, p95, worst, hitches, slowFrames.description)
    }
}

@MainActor
enum HostScrollHarness {
    static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        return (window, host)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    static func settle(_ host: NSView, for duration: Duration = .milliseconds(400)) async {
        let clock = ContinuousClock()
        let end = clock.now + duration
        while clock.now < end {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()
            pump(0.01)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        var best: NSScrollView?
        var queue = [view]
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let scroll = next as? NSScrollView,
                (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? -1)
            {
                best = scroll
            }
            queue.append(contentsOf: next.subviews)
        }
        return best
    }

    static func scroll(_ host: NSView, step: CGFloat = 24, frames: Int = 300) async
        -> HostScrollTiming
    {
        guard let scroll = scrollView(in: host) else { return HostScrollTiming(frames: []) }
        var timings: [Double] = []
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
            pump(0)
            let elapsed = (CACurrentMediaTime() - start) * 1000
            timings.append(elapsed)
            let rest = 1000.0 / 120 - elapsed
            if rest > 0 { try? await Task.sleep(for: .microseconds(Int(rest * 1000))) }
        }
        return HostScrollTiming(frames: timings)
    }
}
