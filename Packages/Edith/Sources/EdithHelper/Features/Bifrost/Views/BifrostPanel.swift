import AppKit
import EdithKit
import SwiftUI

private final class BifrostFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ TextEditingCommands.handle(event) }) { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control),
            !modifiers.contains(.option), let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        if let number = BifrostEditingAction.shortcutNumber(for: key),
            MainActor.assumeIsolated({ BifrostPanel.shared.runShortcut(number) })
        {
            return true
        }
        let shifted = modifiers.contains(.shift)
        guard let action = BifrostEditingAction.selector(for: key, shifted: shifted) else {
            return super.performKeyEquivalent(with: event)
        }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

enum BifrostEditingAction {
    static func shortcutNumber(for key: String) -> Int? {
        guard key.count == 1, let number = Int(key), (1...9).contains(number) else { return nil }
        return number
    }

    static func selector(for key: String, shifted: Bool) -> Selector? {
        let flags: NSEvent.ModifierFlags = shifted ? [.command, .shift] : .command
        return TextEditingCommands.selector(characters: key, keyCode: 0, modifiers: flags)
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
    private var dragMonitor: Any?
    private var dragOrigin: CGPoint?
    var shortcutHandler: ((Int) -> Bool)?

    func runShortcut(_ number: Int) -> Bool {
        guard isVisible else { return false }
        return shortcutHandler?(number) ?? false
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(query: String = "") {
        if isVisible, query.isEmpty {
            hide()
        } else {
            show(query: query)
        }
    }

    func show(query: String = "") {
        guard let store, let panel else { return }
        store.refreshDynamicSources()
        showGeneration += 1
        let generation = showGeneration
        showTask?.cancel()
        let position = PopupPosition.stored(forKey: AppStorageKeys.Bifrost.popupAt)
        if position == .center, let screen = panel.screen ?? NSScreen.main {
            present(
                anchorTop: BifrostPanelMetrics.defaultAnchorTop(in: screen.visibleFrame),
                generation: generation, query: query)
            return
        }
        let nominal = NSSize(
            width: BifrostPanelMetrics.width, height: BifrostPanelMetrics.nominalHeight)
        showTask = Task.detached { [weak self] in
            let placed = await position.origin(
                size: nominal, statusItemFrame: nil, anchors: .bifrost)
            guard !Task.isCancelled else { return }
            await self?.present(
                anchorTop: CGPoint(
                    x: placed.x, y: placed.y + BifrostPanelMetrics.nominalHeight),
                generation: generation, query: query)
        }
    }

    private func present(anchorTop top: CGPoint, generation: Int, query: String) {
        guard generation == showGeneration, let panel else { return }
        let wasVisible = panel.isVisible
        anchorTop = top
        if !wasVisible {
            panel.alphaValue = 0
            panel.setFrame(
                BifrostPanelMetrics.frame(
                    anchorTop: top, height: BifrostPanelMetrics.headerHeight),
                display: false)
        }
        NotificationCenter.default.post(
            name: Self.willShow, object: nil, userInfo: [Self.prefillKey: query])
        panel.orderFrontRegardless()
        panel.makeKey()
        startWatchingDrags()
        guard !wasVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BifrostPanelMetrics.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        showGeneration += 1
        showTask?.cancel()
        showTask = nil
        stopWatchingDrags()
        guides.hide()
        guard let panel, panel.isVisible else {
            panel?.orderOut(nil)
            NotificationCenter.default.post(name: Self.didHide, object: nil)
            return
        }
        let generation = showGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BifrostPanelMetrics.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.showGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
        NotificationCenter.default.post(name: Self.didHide, object: nil)
    }

    func resize(height: CGFloat) {
        guard let panel else { return }
        let top =
            anchorTop ?? CGPoint(x: panel.frame.minX, y: panel.frame.minY + panel.frame.height)
        anchorTop = top
        let frame = BifrostPanelMetrics.frame(anchorTop: top, height: height)
        guard
            abs(frame.height - panel.frame.height) > BifrostPanelMetrics.resizeThreshold
                || abs(frame.minX - panel.frame.minX) > BifrostPanelMetrics.resizeThreshold
        else { return }
        guard panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BifrostPanelMetrics.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
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

    private func startWatchingDrags() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            let result = MainActor.assumeIsolated {
                EventResult(event: self?.handle(event) ?? event)
            }
            return result.event
        }
    }

    private struct EventResult: @unchecked Sendable {
        let event: NSEvent
    }

    private func stopWatchingDrags() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        dragOrigin = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible else { return event }
        switch event.type {
        case .leftMouseDown:
            let point = NSEvent.mouseLocation
            guard BifrostPanelMetrics.isInDragHandle(point: point, frame: panel.frame) else {
                return event
            }
            dragOrigin = point
            return event
        case .leftMouseDragged:
            guard let origin = dragOrigin else { return event }
            let point = NSEvent.mouseLocation
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            guard abs(delta.width) + abs(delta.height) > 1 else { return nil }
            dragOrigin = point
            panel.setFrame(
                BifrostPanelMetrics.moved(panel.frame, by: delta), display: true)
            if !guides.isVisible {
                guides.show(on: panel.screen) { [weak self] in self?.finishDrag() }
            }
            return nil
        case .leftMouseUp:
            guard dragOrigin != nil else { return event }
            dragOrigin = nil
            guard guides.isVisible else { return event }
            guides.hide()
            finishDrag()
            return nil
        default:
            return event
        }
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

    nonisolated func windowDidMove(_ notification: Notification) {}
}
