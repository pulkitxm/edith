import AppKit
import EdithKit
import SwiftUI

private final class BifrostFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control),
            !modifiers.contains(.option), let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let shifted = modifiers.contains(.shift)
        guard let action = BifrostEditingAction.selector(for: key, shifted: shifted) else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

enum BifrostEditingAction {
    static func selector(for key: String, shifted: Bool) -> Selector? {
        switch key {
        case "a": #selector(NSText.selectAll(_:))
        case "c": #selector(NSText.copy(_:))
        case "v": #selector(NSText.paste(_:))
        case "x": #selector(NSText.cut(_:))
        case "z": shifted ? Selector(("redo:")) : Selector(("undo:"))
        default: nil
        }
    }
}

@MainActor
final class BifrostPanel: NSObject, NSWindowDelegate {
    static let shared = BifrostPanel()

    static let willShow = Notification.Name("bifrostPanelWillShow")
    static let didHide = Notification.Name("bifrostPanelDidHide")
    static let prefillKey = "bifrostPanelPrefill"

    let guides = BifrostDragGuides()

    weak var store: BifrostStore? {
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
    private var anchorTop: CGPoint?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(query: String = "") {
        if isVisible, query.isEmpty {
            hide()
        } else {
            show(query: query)
        }
    }

    func show(query: String = "") {
        guard store != nil, let panel else { return }
        let collapsed = NSSize(
            width: BifrostPanelMetrics.width, height: BifrostPanelMetrics.headerHeight)
        panel.setContentSize(collapsed)
        let position = PopupPosition.stored(forKey: AppStorageKeys.Bifrost.popupAt)
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        showTask = Task.detached { [weak self] in
            let origin = await position.origin(
                size: collapsed, statusItemFrame: nil, anchors: .bifrost)
            guard !Task.isCancelled else { return }
            await self?.finishShow(origin: origin, generation: generation, query: query)
        }
    }

    private func finishShow(origin: NSPoint, generation: Int, query: String) {
        guard generation == showGeneration, let panel else { return }
        panel.setFrameOrigin(origin)
        anchorTop = CGPoint(x: origin.x, y: origin.y + BifrostPanelMetrics.headerHeight)
        panel.orderFrontRegardless()
        panel.makeKey()
        NotificationCenter.default.post(
            name: Self.willShow, object: nil, userInfo: [Self.prefillKey: query])
    }

    func hide() {
        showGeneration += 1
        showTask?.cancel()
        showTask = nil
        guides.hide()
        panel?.orderOut(nil)
        NotificationCenter.default.post(name: Self.didHide, object: nil)
    }

    func resize(height: CGFloat) {
        guard let panel else { return }
        let top =
            anchorTop ?? CGPoint(x: panel.frame.minX, y: panel.frame.minY + panel.frame.height)
        anchorTop = top
        let frame = BifrostPanelMetrics.frame(anchorTop: top, height: height)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func mountRootView() {
        guard let store else {
            hosting?.rootView = AnyView(EmptyView())
            return
        }
        if panel == nil { makePanel() }
        hosting?.rootView = AnyView(
            BifrostPanelView(
                store: store, onDismiss: { [weak self] in self?.hide() },
                onHeightChanged: { [weak self] height in self?.resize(height: height) }))
        hosting?.layoutSubtreeIfNeeded()
    }

    private func makePanel() {
        let created = BifrostFloatingPanel(
            contentRect: NSRect(
                x: 0, y: 0, width: BifrostPanelMetrics.width,
                height: BifrostPanelMetrics.headerHeight),
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

        let container = NSView()
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        created.contentView = container
        hosting = host
        panel = created
    }

    private func beginDrag() {
        guard let panel, panel.isVisible else { return }
        guides.show(on: panel.screen) { [weak self] in self?.finishDrag() }
    }

    private func finishDrag() {
        guard let panel else { return }
        anchorTop = CGPoint(x: panel.frame.minX, y: panel.frame.minY + panel.frame.height)
        PopupPosition.saveLastPosition(
            frame: panel.frame, screen: panel.screen, anchors: .bifrost)
        SharedDefaults.store.set(
            PopupPosition.lastPosition.rawValue, forKey: AppStorageKeys.Bifrost.popupAt)
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            guard !BifrostPanel.shared.guides.isVisible else { return }
            BifrostPanel.shared.hide()
        }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = BifrostPanel.shared.panel, panel.isVisible,
                NSEvent.pressedMouseButtons & 1 == 1
            else { return }
            BifrostPanel.shared.beginDrag()
        }
    }
}
