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

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 46
    static let headerHeight: CGFloat = 52
    static let listPadding: CGFloat = 6
    static let willShow = Notification.Name("bifrostPanelWillShow")
    static let didHide = Notification.Name("bifrostPanelDidHide")
    static let prefillKey = "bifrostPanelPrefill"

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

    var isVisible: Bool { panel?.isVisible ?? false }

    static func height(forRows rows: Int) -> CGFloat {
        guard rows > 0 else { return headerHeight }
        return headerHeight + CGFloat(rows) * rowHeight + listPadding
    }

    func toggle(query: String = "") {
        if isVisible, query.isEmpty {
            hide()
        } else {
            show(query: query)
        }
    }

    func show(query: String = "") {
        guard store != nil, let panel else { return }
        NotificationCenter.default.post(
            name: Self.willShow, object: nil, userInfo: [Self.prefillKey: query])
        let position = PopupPosition.stored(forKey: AppStorageKeys.Bifrost.popupAt)
        let size = panel.frame.size
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        showTask = Task.detached { [weak self] in
            let origin = await position.origin(
                size: size, statusItemFrame: nil, anchors: .bifrost)
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

    func resize(rows: Int) {
        guard let panel else { return }
        let height = Self.height(forRows: rows)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: Self.width, height: height)
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
                onRowsChanged: { [weak self] rows in self?.resize(rows: rows) }))
        hosting?.layoutSubtreeIfNeeded()
    }

    private func makePanel() {
        let created = BifrostFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(forRows: 0)),
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
        effect.material = .hudWindow
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
        created.contentView = effect
        hosting = host
        panel = created
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in BifrostPanel.shared.hide() }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        Task { @MainActor in
            guard let panel = BifrostPanel.shared.panel, panel.isVisible,
                NSEvent.pressedMouseButtons & 1 == 1
            else { return }
            PopupPosition.saveLastPosition(
                frame: panel.frame, screen: panel.screen, anchors: .bifrost)
        }
    }
}
