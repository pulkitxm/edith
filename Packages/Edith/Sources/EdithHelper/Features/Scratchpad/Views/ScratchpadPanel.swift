import AppKit
import EdithKit
import SwiftUI

private final class ScratchpadFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ScratchpadPanel: NSObject, NSWindowDelegate {
    static let shared = ScratchpadPanel()

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?
    private var store: ScratchpadStore?

    var isVisible: Bool { panel?.isVisible ?? false }

    func install() {
        if store == nil {
            store = ScratchpadStore()
        } else {
            store?.reload()
        }
        if panel == nil { makePanel() }
        applySettings()
    }

    func uninstall() {
        store?.flushSave()
        hide()
        store = nil
        panel?.delegate = nil
        panel?.close()
        panel = nil
        hosting = nil
    }

    func toggle() {
        guard SharedDefaults.store.bool(forKey: AppStorageKeys.Scratchpad.enabled) else { return }
        isVisible ? hide() : show()
    }

    func show() {
        install()
        guard let panel else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            panel.center()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        store?.flushSave()
        panel?.orderOut(nil)
    }

    func applySettings() {
        let alwaysOnTop =
            SharedDefaults.store.object(
                forKey: AppStorageKeys.Scratchpad.alwaysOnTop) as? Bool ?? true
        panel?.level = alwaysOnTop ? .floating : .normal
    }

    private func makePanel() {
        let created = ScratchpadFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered, defer: true)
        created.minSize = NSSize(width: 520, height: 360)
        created.isOpaque = false
        created.backgroundColor = .clear
        created.hasShadow = true
        created.collectionBehavior = [.auxiliary, .moveToActiveSpace, .fullScreenAuxiliary]
        created.animationBehavior = .utilityWindow
        created.isFloatingPanel = true
        created.hidesOnDeactivate = false
        created.isReleasedWhenClosed = false
        created.isMovableByWindowBackground = true
        created.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.45).cgColor

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
        panel = created
        hosting = host
        if let store {
            host.rootView = AnyView(
                ScratchpadPanelView(store: store, dismiss: { [weak self] in self?.hide() }))
        }
        created.center()
        applySettings()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            let dismiss =
                SharedDefaults.store.object(
                    forKey: AppStorageKeys.Scratchpad.dismissOnDeactivate) as? Bool ?? true
            if dismiss { ScratchpadPanel.shared.hide() }
        }
    }

    nonisolated func windowDidEndLiveResize(_ notification: Notification) {
        Task { @MainActor in ScratchpadPanel.shared.panel?.displayIfNeeded() }
    }
}
