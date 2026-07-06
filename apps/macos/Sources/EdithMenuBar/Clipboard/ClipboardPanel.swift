import AppKit
import EdithKit
import SwiftUI

@MainActor
final class ClipboardPanel: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanel()

    weak var store: ClipboardStore?

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let store else { return }
        let p = panel ?? makePanel()
        hosting?.rootView = AnyView(
            ClipboardPanelView(store: store, onDismiss: { [weak self] in self?.hide() }))
        position(p)
        p.orderFrontRegardless()
        p.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
        else { return }
        let visible = screen.visibleFrame
        var origin = NSPoint(x: mouse.x + 6, y: mouse.y - panel.frame.height - 6)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.animationBehavior = .none
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovable = false
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        hosting = host
        panel = p
        return p
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in ClipboardPanel.shared.hide() }
    }
}
