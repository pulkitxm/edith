import AppKit
import SwiftUI

private final class ScratchpadFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ScratchpadPanel: NSObject, NSWindowDelegate {
    static let shared = ScratchpadPanel()

    static let width: CGFloat = 340
    static let height: CGFloat = 88

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
        let p = panel ?? makePanel()
        hosting?.rootView = AnyView(ScratchpadView(onDismiss: { [weak self] in self?.hide() }))
        p.center()
        p.orderFrontRegardless()
        p.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let p = ScratchpadFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
        p.animationBehavior = .none
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
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
        Task { @MainActor in ScratchpadPanel.shared.hide() }
    }
}
