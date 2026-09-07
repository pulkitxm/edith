import AppKit
import EdithKit
import SwiftUI

private final class EmojiFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class EmojiPanel: NSObject, NSWindowDelegate {
    static let shared = EmojiPanel()

    static let width: CGFloat = 364
    static let height: CGFloat = 396
    static let willShow = Notification.Name("emojiPanelWillShow")
    static let didHide = Notification.Name("emojiPanelDidHide")

    weak var store: EmojiStore? {
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

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard store != nil, let panel else { return }
        NotificationCenter.default.post(name: Self.willShow, object: nil)
        panel.setContentSize(NSSize(width: Self.width, height: Self.height))
        let position = PopupPosition.stored(forKey: AppStorageKeys.Emoji.popupAt)
        let size = panel.frame.size
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        showTask = Task.detached { [weak self] in
            let origin = await position.origin(
                size: size, statusItemFrame: nil, anchors: .emoji)
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
        NotificationCenter.default.post(name: Self.didHide, object: nil)
    }

    private func mountRootView() {
        guard let store else {
            hosting?.rootView = AnyView(EmptyView())
            return
        }
        if panel == nil { makePanel() }
        hosting?.rootView = AnyView(
            EmojiPanelView(store: store, onDismiss: { [weak self] in self?.hide() }))
        hosting?.layoutSubtreeIfNeeded()
    }

    private func makePanel() {
        let created = EmojiFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.level = .statusBar
        created.collectionBehavior = [
            .auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary,
        ]
        created.animationBehavior = .none
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        created.delegate = self

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
        created.contentView = effect
        hosting = host
        panel = created
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in EmojiPanel.shared.hide() }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = EmojiPanel.shared.panel, panel.isVisible,
                NSEvent.pressedMouseButtons & 1 == 1
            else { return }
            PopupPosition.saveLastPosition(
                frame: panel.frame, screen: panel.screen, anchors: .emoji)
        }
    }
}
