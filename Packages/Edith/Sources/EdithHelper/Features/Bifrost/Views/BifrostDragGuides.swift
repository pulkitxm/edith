import AppKit
import EdithKit
import SwiftUI

struct BifrostGuideOverlay: View {
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let style = StrokeStyle(lineWidth: 1, dash: [5, 6])
            let color = Color.white.opacity(0.35)
            for fraction in BifrostGuideLines.vertical {
                var path = Path()
                let x = (canvasSize.width * fraction).rounded()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                context.stroke(path, with: .color(color), style: style)
            }
            for fraction in BifrostGuideLines.horizontal {
                var path = Path()
                let y = (canvasSize.height * fraction).rounded()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                context.stroke(path, with: .color(color), style: style)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

@MainActor
final class BifrostDragGuides {
    private var window: NSWindow?
    private var monitor: Any?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(on screen: NSScreen?, onFinish: @escaping @MainActor () -> Void) {
        guard let screen = screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let overlay = window ?? makeWindow()
        window = overlay
        overlay.setFrame(frame, display: false)
        if let hosting = overlay.contentView as? NSHostingView<BifrostGuideOverlay> {
            hosting.rootView = BifrostGuideOverlay(size: frame.size)
        }
        overlay.orderFront(nil)
        watchForRelease(onFinish: onFinish)
    }

    func hide() {
        window?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func watchForRelease(onFinish: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide()
                onFinish()
            }
        }
    }

    private func makeWindow() -> NSWindow {
        let created = NSWindow(
            contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = false
        created.ignoresMouseEvents = true
        created.level = .statusBar
        created.collectionBehavior = [.stationary, .canJoinAllSpaces, .fullScreenAuxiliary]
        created.animationBehavior = .none
        created.contentView = NSHostingView(rootView: BifrostGuideOverlay(size: .zero))
        return created
    }
}
