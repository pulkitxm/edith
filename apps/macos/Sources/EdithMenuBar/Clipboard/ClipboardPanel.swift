import AppKit
import EdithKit
import SwiftUI

private final class ClipboardFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardPanel: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanel()

    static let width: CGFloat = 450
    static let maxHeight: CGFloat = 800

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
            ClipboardPanelView(
                store: store,
                onDismiss: { [weak self] in self?.hide() },
                onHeightChange: { [weak self] height in self?.resize(toFit: height) }))
        let height = min(
            ClipboardPanelView.estimatedHeight(entries: store.entries), Self.maxHeight)
        p.setContentSize(NSSize(width: Self.width, height: height))
        p.setFrameOrigin(
            ClipboardPopupPosition.current.origin(
                size: p.frame.size, statusItemFrame: menuBarExtraStatusWindow()?.frame))
        p.orderFrontRegardless()
        p.makeKey()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func resize(toFit height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let clamped = min(height, Self.maxHeight)
        guard abs(panel.frame.height - clamped) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - clamped
        frame.size.height = clamped
        frame.origin = ClipboardPopupPosition.clampedToScreen(frame.origin, frame.size)
        panel.setFrame(frame, display: true)
    }

    private func makePanel() -> NSPanel {
        let p = ClipboardFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
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
        p.isMovableByWindowBackground = true
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 9
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

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = ClipboardPanel.shared.panel, panel.isVisible,
                NSEvent.pressedMouseButtons & 1 == 1
            else { return }
            ClipboardPopupPosition.saveLastPosition(frame: panel.frame, screen: panel.screen)
        }
    }
}
