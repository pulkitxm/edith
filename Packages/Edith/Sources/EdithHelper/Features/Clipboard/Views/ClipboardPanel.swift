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
    nonisolated static let maxHeight: CGFloat = 800
    static let willShow = Notification.Name("clipboardPanelWillShow")

    weak var store: ClipboardStore? {
        didSet {
            guard store !== oldValue else { return }
            if store == nil { hide() }
            mountRootView()
        }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var showTask: Task<Void, Never>?
    private var showGeneration = 0

    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let store, let p = panel else { return }
        NotificationCenter.default.post(name: Self.willShow, object: nil)
        let height = min(
            ClipboardPanelView.estimatedHeight(entries: store.entries), Self.maxHeight)
        p.setContentSize(NSSize(width: Self.width, height: height))
        let position = PopupPosition.stored(forKey: AppStorageKeys.Clipboard.popupAt)
        let size = p.frame.size
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        showTask = Task.detached { [weak self] in
            let origin = await position.origin(
                size: size, statusItemFrame: nil, anchors: .clipboard)
            guard !Task.isCancelled else { return }
            await self?.finishShow(origin: origin, generation: generation)
        }
    }

    private func finishShow(origin: NSPoint, generation: Int) {
        guard generation == showGeneration, let panel else { return }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        showGeneration += 1
        showTask?.cancel()
        showTask = nil
        panel?.orderOut(nil)
    }

    private func mountRootView() {
        guard let store else {
            hosting?.rootView = AnyView(EmptyView())
            return
        }
        if panel == nil { makePanel() }
        hosting?.rootView = AnyView(
            ClipboardPanelView(
                store: store,
                onDismiss: { [weak self] in self?.hide() },
                onHeightChange: { [weak self] height in self?.resize(toFit: height) }
            ))
        hosting?.layoutSubtreeIfNeeded()
    }

    private func resize(toFit height: CGFloat) {
        guard let panel, panel.isVisible else { return }
        let clamped = min(height, Self.maxHeight)
        guard abs(panel.frame.height - clamped) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - clamped
        frame.size.height = clamped
        frame.origin = PopupPosition.clampedToScreen(frame.origin, frame.size)
        panel.setFrame(frame, display: true)
    }

    private func makePanel() {
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
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in ClipboardPanel.shared.hide() }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = ClipboardPanel.shared.panel, panel.isVisible,
                NSEvent.pressedMouseButtons & 1 == 1
            else { return }
            PopupPosition.saveLastPosition(
                frame: panel.frame, screen: panel.screen, anchors: .clipboard)
        }
    }
}
